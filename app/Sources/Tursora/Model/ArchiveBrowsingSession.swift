import Foundation
import Darwin
import UniformTypeIdentifiers

/// A mounted archive: its table of contents, and private storage its entries'
/// bytes are extracted into as they are needed. Its URLs never replace the
/// original archive, and every directory read or file launch rechecks the
/// resolved containment. Used from listing queues and workers as well as the
/// main thread: its own state is behind `stateLock`, the materializer's behind
/// its condition, and the tree never changes after mount.
final class ArchiveBrowsingSession: @unchecked Sendable {
    private static let preparationLock = NSLock()
    private static var pendingStorage: [URL: ArchivePreparationCancellation] = [:]
    private static var isShuttingDown = false

    /// Stop child writers before their workers reclaim private directories.
    /// ArchiveWorkspace's shutdown barrier waits for the resulting completions.
    static func shutdownPreparingSessions() {
        preparationLock.lock()
        isShuttingDown = true
        let pending = pendingStorage
        preparationLock.unlock()
        pending.values.forEach { $0.cancel() }
    }

    fileprivate static func registerPreparation(_ url: URL, cancellation: ArchivePreparationCancellation) -> Bool {
        preparationLock.lock(); defer { preparationLock.unlock() }
        guard !isShuttingDown else { return false }
        pendingStorage[url] = cancellation
        return true
    }

    fileprivate static func finishPreparation(_ url: URL) {
        preparationLock.lock(); defer { preparationLock.unlock() }
        pendingStorage[url] = nil
    }

    /// One row, built from the table of contents: nothing about it is read
    /// from disk except where a symbolic link leads (D97).
    struct Entry {
        let url: URL
        let name: String
        /// The tree path whose bytes this row reads: its own, or for a link
        /// the entry the link leads to. Nil for a link that leads nowhere this
        /// session can read.
        let contentPath: String?
        let isDirectory: Bool
        let isPackage: Bool
        let isSymbolicLink: Bool
        let canAccess: Bool
        let size: Int64
        /// The archive's own date for this entry (D93).
        var modificationDate: Date? = nil
        var contentType: UTType? = nil
        /// The Kind string, as the extracted item would show it.
        var kind: String? = nil
        var isNavigable: Bool { isDirectory && !isPackage && canAccess }
    }

    enum SessionError: LocalizedError {
        case closed, cancelled, outsideArchive, notDirectory, unavailableItem
        case insufficientSpace(needed: Int64, available: Int64)
        /// An entry that cannot be brought out of the archive, with the reason.
        case notExtracted(String)
        var errorDescription: String? {
            switch self {
            case .closed: return "This ZIP browsing session has ended."
            case .cancelled: return "Opening the ZIP was cancelled."
            case .outsideArchive: return "This link points outside the ZIP and cannot be opened here."
            case .notDirectory: return "This item is not a folder."
            case .unavailableItem: return "This item is unavailable in the ZIP snapshot."
            case .notExtracted(let reason): return "This item could not be read from the ZIP. \(reason)"
            case .insufficientSpace(let needed, let available):
                let format: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                return "Opening this ZIP needs about \(format(needed)) of temporary space and only \(format(available)) is free."
            }
        }
    }

    static let storagePrefix = "tursora-zip-session-"
    static let lockName = ".tursora-session-lock"

    let archiveURL: URL
    let storageURL: URL
    let rootURL: URL
    private let storageFileID: UInt64
    /// Held for the session's lifetime so another process's launch sweep can
    /// tell this storage apart from an orphan. Released when the session is
    /// closed, or by the kernel if the process dies — which is the point.
    private var lockDescriptor: Int32 = -1

    // MARK: - Lazy materialization

    /// The archive's shape, read at mount from its table of contents. Every
    /// row comes from here.
    let tree: ArchiveTree
    /// Kind strings and content types for rows whose bytes are not here yet.
    let typeCatalog: ArchiveTypeCatalog
    /// Every byte arrives through this: staging, per-member attribution and
    /// one exclusive, no-follow rename per member (D95). It also coalesces:
    /// two panes asking for one folder cause one run, and a member one batch is
    /// writing is waited for by another rather than written twice.
    let materializer: ArchiveMaterializer

    var isLazilyMounted: Bool { true }
    /// Decides whether a batch of this many bytes fits. Injectable so the suite
    /// can refuse one batch and then allow the retry, which a real disk cannot
    /// be made to do on demand.
    var spaceCheck: (Int64, URL) -> SessionError? {
        get { materializer.spaceCheck }
        set { materializer.spaceCheck = newValue }
    }

    /// What `entries(in:)` lists for a directory, counted from the tree rather
    /// than the disk: an unentered directory holds only its skeleton, so a
    /// count read from disk would say "0 items" for a folder full of files.
    /// Matches the listing exactly — the rows it shows, less dotfiles, which
    /// is also what Finder's "N items" counts. A folder reached through a link
    /// is counted where the link leads.
    func listedChildCount(of url: URL) -> Int? {
        guard let path = resolvedArchivePath(of: url), let children = tree.listedChildren(of: path) else { return nil }
        return children.filter { !$0.name.hasPrefix(".") }.count
    }

    /// The archive-relative path of a URL inside this session's root, as
    /// spelled: a link along it is not followed.
    func archivePath(of url: URL) -> String {
        let root = rootURL.standardizedFileURL.pathComponents
        let candidate = url.standardizedFileURL.pathComponents
        guard candidate.count > root.count, candidate.starts(with: root) else { return "" }
        return candidate.dropFirst(root.count).joined(separator: "/")
    }

    /// The entry a URL inside the root stands for, with every link along it
    /// followed through the tree. Nil when it leaves the archive, dangles or
    /// loops.
    func resolvedArchivePath(of url: URL) -> String? {
        // `archivePath` spells anything outside the root as the root itself.
        guard Self.containsPath(root: rootURL, candidate: url),
              case .inside(let path) = tree.resolve(archivePath(of: url), readLink: readLink) else { return nil }
        return path
    }

    /// A link's target, from the link bsdtar wrote at mount. Every component
    /// before it is a real directory — the tree resolves as it goes — so
    /// reading it never follows another link.
    private func readLink(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: rootURL.appendingPathComponent(path).path)
    }

    /// Whether the archive is read from this Mac's own disk: always for the
    /// private clone, and for an original that could not be cloned only when
    /// its volume is local. A prefetch never reads over the network.
    let sourceIsLocal: Bool
    private var prefetched: Int64 = 0
    /// Bytes this session has prefetched, against its budget.
    var prefetchedBytes: Int64 { stateLock.lock(); defer { stateLock.unlock() }; return prefetched }
    func notePrefetch(_ bytes: Int64) { stateLock.lock(); prefetched += bytes; stateLock.unlock() }

    /// Whether an entry's bytes are all on disk, judged from its state and
    /// never from the disk, where a file's existence says nothing about
    /// whether it is sound. A file or package is once it is published. A
    /// folder is once nothing below it is left to bring — everything that
    /// can be extracted is published or has failed — so it is never handed
    /// out half-filled; that answer is kept until some state changes.
    func isPublished(_ path: String) -> Bool {
        if let node = tree.node(at: path), !node.isDirectory || node.isPackage {
            return materializer.state(of: node.path) == .published
        }
        let generation = materializer.generation
        stateLock.lock()
        if let cached = completeFolders[path], cached.generation == generation {
            stateLock.unlock()
            return cached.complete
        }
        stateLock.unlock()
        let complete = tree.subtreePlan(for: path, skipping: materializer.settledPaths).isEmpty
        stateLock.lock()
        completeFolders[path] = (generation, complete)
        stateLock.unlock()
        return complete
    }

    private var completeFolders: [String: (generation: Int, complete: Bool)] = [:]

    private let stateLock = NSLock()
    private var closed = false
    var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    fileprivate init(archive: URL, storage: URL, root: URL, fileID: UInt64, lock: Int32 = -1,
                     tree: ArchiveTree, typeCatalog: ArchiveTypeCatalog, source: URL? = nil,
                     sourceIdentity: ArchiveMaterializer.SourceIdentity? = nil, sourceIsLocal: Bool = true,
                     runner: ArchiveToolRunning = SystemArchiveToolRunner.shared) {
        self.sourceIsLocal = sourceIsLocal
        archiveURL = archive.standardizedFileURL
        storageURL = storage
        rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        storageFileID = fileID
        lockDescriptor = lock
        self.tree = tree
        self.typeCatalog = typeCatalog
        // The file bsdtar reads is the physical archive, which is not the same
        // as `archiveURL` for an archive reached through another one.
        materializer = ArchiveMaterializer(tree: tree, source: source ?? archive,
                                           rootURL: root.resolvingSymlinksInPath().standardizedFileURL,
                                           storageURL: storage, runner: runner, sourceIdentity: sourceIdentity,
                                           spaceCheck: { FileOperations.requiredSpaceRefusal(forExtracting: $0, into: $1) })
    }

    static func releaseStorageLock(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    /// Taken the moment the storage directory exists, not when the session is
    /// built: staging can take seconds, and an unmarked directory reads as an
    /// orphan to another process's launch sweep. Non-blocking, and a failure
    /// only costs this storage that protection — it must never fail the open.
    /// The marker sits beside the published root, never inside it, so it can
    /// never appear in a listing.
    static func takeStorageLock(in storage: URL) -> Int32 {
        let marker = storage.appendingPathComponent(lockName)
        let descriptor = open(marker.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return -1 }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); return -1 }
        return descriptor
    }

    @discardableResult
    static func prepare(archive: URL, logicalArchiveURL: URL? = nil,
                        cancellation: ArchivePreparationCancellation = ArchivePreparationCancellation(),
                        completion: @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) -> ArchivePreparationCancellation {
        FileOperations.prepareArchiveBrowsingSession(archive: archive, logicalArchiveURL: logicalArchiveURL,
                                                      cancellation: cancellation, completion: completion)
        return cancellation
    }

    static func containsPath(root: URL, candidate: URL) -> Bool {
        candidate.isFileURL && candidate.standardizedFileURL.pathComponents
            .starts(with: root.standardizedFileURL.pathComponents)
    }

    func validatedURL(_ url: URL) throws -> URL {
        guard !isClosed else { throw SessionError.closed }
        guard Self.containsPath(root: rootURL, candidate: url),
              Self.containsPath(root: rootURL, candidate: url.resolvingSymlinksInPath()) else {
            throw SessionError.outsideArchive
        }
        return url.standardizedFileURL
    }

    /// A folder's rows, from the table of contents alone. Listing never
    /// extracts anything (D102): bytes arrive when something asks for them,
    /// or through the pane's background prefetch. Nothing about a row is read
    /// from disk save where a symbolic link leads; `beforeReadingEntry` runs
    /// before that one read, for the suite.
    func entries(in directory: URL, beforeReadingEntry: ((URL) throws -> Void)? = nil) throws -> [Entry] {
        let directory = try validatedURL(directory)
        guard let path = resolvedArchivePath(of: directory), let children = tree.listedChildren(of: path) else {
            throw SessionError.notDirectory
        }
        return try children.map { node -> Entry in
            let url = directory.appendingPathComponent(node.name)
            if node.kind == .symbolicLink {
                do { try beforeReadingEntry?(url) } catch {
                    // A link that vanished is read as leading nowhere; any
                    // other failure still surfaces rather than hiding a
                    // damaged snapshot.
                    let failure = error as NSError
                    guard (failure.domain == NSCocoaErrorDomain
                           && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code))
                        || (failure.domain == NSPOSIXErrorDomain && failure.code == ENOENT) else { throw error }
                }
            }
            return entry(for: node, at: url)
        }.sorted {
            if $0.isNavigable != $1.isNavigable { return $0.isNavigable }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func entry(for node: ArchiveTree.Node, at url: URL) -> Entry {
        let description = typeCatalog.describe(node)
        guard node.kind == .symbolicLink else {
            return Entry(url: url, name: node.name, contentPath: node.path, isDirectory: node.isDirectory,
                         isPackage: node.isPackage, isSymbolicLink: false, canAccess: !hasFailed(node.path),
                         size: size(of: node), modificationDate: node.modificationDate,
                         contentType: description.contentType, kind: description.kind)
        }
        // A link shows the shape, size and readability of where it leads, and
        // its own date and Kind — as a link in an ordinary folder does.
        var target: ArchiveTree.Node?
        var readable = false
        var contentPath: String?
        if case .inside(let path) = tree.resolve(node.path, readLink: readLink) {
            if path.isEmpty {
                readable = true
            } else if let reached = tree.node(at: path) {
                target = reached
                // Inside a package, bytes arrive only with the package whole.
                readable = reached.isExtractable && !reached.insidePackage && !hasFailed(reached.path)
            }
            if readable { contentPath = target?.path ?? "" }
        }
        return Entry(url: url, name: node.name, contentPath: contentPath,
                     isDirectory: readable && (target?.isDirectory ?? true), isPackage: target?.isPackage == true,
                     isSymbolicLink: true, canAccess: readable, size: readable ? target.map(size(of:)) ?? 0 : 0,
                     modificationDate: node.modificationDate,
                     contentType: description.contentType, kind: description.kind)
    }

    /// A file's own size; a package's is everything it holds, as Finder
    /// shows a package's size.
    private func size(of node: ArchiveTree.Node) -> Int64 {
        if node.isPackage { return tree.packageBytes(node.path) }
        return node.kind == .file ? node.uncompressedSize : 0
    }

    /// An attributed extraction failure is sticky until Reload, and the row
    /// reads as unavailable until then.
    private func hasFailed(_ path: String) -> Bool {
        if case .failed = materializer.state(of: path) { return true }
        return false
    }

    /// The archive was replaced after mount; the workspace mounts it again.
    var isSourceChanged: Bool { materializer.sourceChanged }

    func close() { close(onDrained: nil) }

    /// Never removes storage a child may still be writing into (D96). With
    /// nothing in flight it is immediate, as it always was. Otherwise it stops
    /// every run, waits for the children off the caller's thread — SIGKILL
    /// after 3 s, giving up at 10 s — and only then removes storage and calls
    /// `onDrained`, once, on the main queue.
    func close(onDrained: (() -> Void)?) {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); onDrained?(); return }
        closed = true
        let descriptor = lockDescriptor
        lockDescriptor = -1
        stateLock.unlock()
        let finish = { [storageURL, storageFileID] in
            Self.releaseStorageLock(descriptor)
            FileOperations.discardArchiveBrowsingSession(storageURL, fileID: storageFileID)
        }
        guard materializer.shutDown() else {
            finish()
            onDrained?()
            return
        }
        DispatchQueue.global(qos: .utility).async { [materializer] in
            if !materializer.waitForDrain(timeout: 3) {
                materializer.killActiveRuns()
                _ = materializer.waitForDrain(timeout: 7)
            }
            finish()
            DispatchQueue.main.async { onDrained?() }
        }
    }
}

extension FileOperations {
    /// Staging happens in the user's own temporary directory, so a large
    /// archive can fill the volume the whole system is running from. The
    /// listing gives the uncompressed total for the price of one central
    /// directory read (measured at 0.05 s for 4 000 entries, against 0.57 s to
    /// extract the same archive), so the cost of asking is small enough to
    /// always ask.
    static func requiredSpaceRefusal(forExtracting bytes: Int64, into directory: URL,
                                     headroom: Double = 1.15) -> ArchiveBrowsingSession.SessionError? {
        guard bytes > 0 else { return nil }
        // Capacity goes through FileManager rather than URL.resourceValues,
        // which caches for the run-loop pass (AGENTS.md rule 5).
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else { return nil }
        let needed = Int64(min(Double(bytes) * headroom, Double(Int64.max)))
        return needed > free ? .insufficientSpace(needed: needed, available: free) : nil
    }

    /// Storage directories left behind by a run that crashed or was killed.
    ///
    /// `$TMPDIR` is per-user, not per-process, so a second Tursora — a debug
    /// build beside the packaged app, or a smoke run — has its live sessions
    /// sitting right next to the orphans. Age is not a safe discriminator
    /// either: a session open for hours never touches its own directory. So
    /// ownership is advisory-locked instead. A live session holds an exclusive
    /// `flock` on a marker inside its storage for as long as it exists; the
    /// sweeper removes only what it can lock itself, which is exactly what no
    /// living process owns. Only this app's own prefix is ever considered.
    static func sweepOrphanedStorage(in root: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(ArchiveBrowsingSession.storagePrefix) {
            let url = root.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            let marker = url.appendingPathComponent(ArchiveBrowsingSession.lockName)
            // A directory with no marker predates the lock or was interrupted
            // before it was written; it cannot be owned, so it is an orphan.
            if fm.fileExists(atPath: marker.path) {
                let descriptor = open(marker.path, O_RDONLY)
                guard descriptor >= 0 else { continue }
                let acquired = flock(descriptor, LOCK_EX | LOCK_NB) == 0
                if acquired { flock(descriptor, LOCK_UN) }
                Darwin.close(descriptor)
                guard acquired else { continue }        // a live process owns it
            }
            // removeItem removes symlinks themselves; it never traverses them.
            try? fm.removeItem(at: url)
        }
    }

    /// Clones the archive into a session's storage. A seam so the suite can
    /// make it fail, which a real volume cannot be asked to do; production
    /// never changes it.
    static var cloneArchive: (URL, URL) -> Bool = { source, clone in
        clonefile(source.path, clone.path, UInt32(CLONE_NOFOLLOW)) == 0
    }

    static func prepareArchiveBrowsingSession(archive: URL, logicalArchiveURL: URL? = nil,
        listing: ArchiveListing = BSDTarArchiveListing(),
        runner: ArchiveToolRunning = SystemArchiveToolRunner.shared,
        cancellation: ArchivePreparationCancellation = ArchivePreparationCancellation(),
        completion: @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let storage = fm.temporaryDirectory.appendingPathComponent(ArchiveBrowsingSession.storagePrefix + UUID().uuidString)
            var storageID: UInt64?
            var storageLock: Int32 = -1
            do {
                try cancellation.checkCancellation()
                // Before a byte is staged: refuse an archive we cannot read and
                // one that is password-protected.
                try FileOperations.checkArchiveForBrowsing(archive)
                try cancellation.checkCancellation()
                try fm.createDirectory(at: storage, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                let id = (try fm.attributesOfItem(atPath: storage.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                storageID = id
                let lock = ArchiveBrowsingSession.takeStorageLock(in: storage)
                storageLock = lock
                guard ArchiveBrowsingSession.registerPreparation(storage, cancellation: cancellation) else {
                    throw ArchiveBrowsingSession.SessionError.closed
                }
                try cancellation.checkpoint(.storageCreated(storage))
                // Everything reads a private clone, so moving, renaming or
                // replacing the original cannot break a mounted session, and the
                // tree and the bytes bsdtar reads always come from one file. A
                // clone on APFS shares blocks and costs next to nothing, and it
                // carries the quarantine over. On another volume it cannot be
                // made; the original is read then, and checked before every run
                // against the identity it had at mount (D96).
                let clone = storage.appendingPathComponent("source.zip")
                let cloned = cloneArchive(archive, clone)
                let source = cloned ? clone : archive
                let identity = cloned ? nil : ArchiveMaterializer.SourceIdentity(of: archive)
                let sourceIsLocal = cloned
                    || (try? archive.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true
                let entries = try listing.entries(of: source)
                // Two names the volume holds as one are one row — `A.txt` and
                // `a.txt` extract to a single file — so the tree folds names
                // exactly when the volume the bytes land on does.
                let caseSensitive = (try? storage.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                    .volumeSupportsCaseSensitiveNames ?? false
                // Dates and per-member encryption come from the central
                // directory, joined by path; the listing stays the tool's own.
                let tree = ArchiveTree(entries: entries, records: ZIPCentralDirectory.records(of: source),
                                       caseInsensitive: !caseSensitive)
                // Mounting writes only the skeleton and the symbolic links, so
                // the whole archive's size is not what has to fit; each batch
                // is checked against free space as it runs.
                if let refusal = requiredSpaceRefusal(forExtracting: Int64(tree.directoryPaths.count) * 4096,
                                                      into: fm.temporaryDirectory) {
                    throw refusal
                }
                // Mount, rather than stage: the table of contents becomes a
                // directory skeleton, the symbolic links are written so
                // containment can be judged from the real links, and not one
                // file's bytes are read (D92). The same moment the eager path
                // reported as "before extraction".
                try cancellation.checkpoint(.beforeExtraction)
                let root = storage.appendingPathComponent("Contents", isDirectory: true)
                try fm.createDirectory(at: root, withIntermediateDirectories: false)
                for path in tree.directoryPaths {
                    try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
                }
                try cancellation.checkCancellation()
                // An escaping symbolic link must be on disk before any row
                // claims to be readable: `entries(in:)` derives `canAccess`
                // from `validatedURL` on the real link.
                try materializeArchiveMembers(archive: source, into: root, scratch: storage,
                                              members: tree.symbolicLinkMembers, noRecursion: true,
                                              cancellation: cancellation)
                try? propagateArchiveQuarantine(from: archive, to: root, cancellation: cancellation)
                // Kind strings for rows whose bytes are not here yet, asked of
                // the system through empty probes beside the root (D97).
                let catalog = ArchiveTypeCatalog.probing(tree, in: storage.appendingPathComponent(".tursora-kind-probes"))
                try cancellation.checkpoint(.beforePublication)
                let session = ArchiveBrowsingSession(archive: logicalArchiveURL ?? archive, storage: storage,
                                                     root: root, fileID: id, lock: lock, tree: tree,
                                                     typeCatalog: catalog, source: source,
                                                     sourceIdentity: identity, sourceIsLocal: sourceIsLocal,
                                                     runner: runner)
                ArchiveBrowsingSession.finishPreparation(storage)
                DispatchQueue.main.async { completion(.success(session)) }
            } catch {
                ArchiveBrowsingSession.finishPreparation(storage)
                ArchiveBrowsingSession.releaseStorageLock(storageLock)
                if let storageID { discardArchiveBrowsingSession(storage, fileID: storageID) }
                else { try? fm.removeItem(at: storage) }
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    fileprivate static func discardArchiveBrowsingSession(_ storage: URL, fileID: UInt64) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: storage.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == fileID else { return }
        // removeItem removes symlinks themselves; it does not traverse their targets.
        try? fm.removeItem(at: storage)
    }
}

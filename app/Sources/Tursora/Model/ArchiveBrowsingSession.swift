import Foundation
import Darwin

/// A private extracted snapshot. Its URLs never replace the original archive,
/// and every directory read or file launch rechecks the resolved containment.
final class ArchiveBrowsingSession {
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

    struct Entry {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isPackage: Bool
        let isSymbolicLink: Bool
        let canAccess: Bool
        let size: Int64
        /// The archive's own date for this entry, from the tree. Preferred over
        /// the file on disk, whose date for a directory is merely when the
        /// skeleton was created (D93).
        var modificationDate: Date? = nil
        var isNavigable: Bool { isDirectory && !isPackage && canAccess }
    }

    enum SessionError: LocalizedError {
        case closed, cancelled, outsideArchive, notDirectory, unavailableItem
        case insufficientSpace(needed: Int64, available: Int64)
        var errorDescription: String? {
            switch self {
            case .closed: return "This ZIP browsing session has ended."
            case .cancelled: return "Opening the ZIP was cancelled."
            case .outsideArchive: return "This link points outside the ZIP and cannot be opened here."
            case .notDirectory: return "This item is not a folder."
            case .unavailableItem: return "This item is unavailable in the ZIP snapshot."
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

    /// The archive's shape, read at mount from its table of contents. Nil when
    /// the session was staged whole, which is still the path for anything the
    /// lazy route cannot serve.
    private let tree: ArchiveTree?
    /// Directory paths whose own listing is complete on disk.
    private var materialized: Set<String> = []
    /// One batch per directory even when two panes ask at once: libarchive
    /// writes in place, so two writers on one path is a torn read.
    private var materializing: [String: NSCondition] = [:]
    private let materializeLock = NSLock()

    var isLazilyMounted: Bool { tree != nil }
    /// Visible to the smoke suite, which asserts what is and is not on disk.
    var archiveTree: ArchiveTree? { tree }

    /// What `entries(in:)` lists for a directory, counted from the tree rather
    /// than the disk: an unentered directory holds only its skeleton, so a
    /// count read from disk would say "0 items" for a folder full of files.
    /// Matches the listing exactly — extractable children, not dotfiles, which
    /// is also what Finder's "N items" counts.
    func listedChildCount(of url: URL) -> Int? {
        guard let tree, let children = tree.children(of: archivePath(of: url)) else { return nil }
        return children.filter { $0.isExtractable && !$0.name.hasPrefix(".") }.count
    }

    /// The archive-relative path of a URL inside this session's root.
    func archivePath(of url: URL) -> String {
        let root = rootURL.standardizedFileURL.pathComponents
        let candidate = url.standardizedFileURL.pathComponents
        guard candidate.count > root.count, candidate.starts(with: root) else { return "" }
        return candidate.dropFirst(root.count).joined(separator: "/")
    }

    /// Put one directory's own contents on disk. Idempotent, coalesced, and a
    /// no-op for an eagerly staged session.
    func materializeDirectory(containing url: URL) throws {
        guard let tree else { return }
        let path = archivePath(of: url)
        guard tree.children(of: path) != nil else { return }

        materializeLock.lock()
        if materialized.contains(path) { materializeLock.unlock(); return }
        if let inFlight = materializing[path] {
            // Another caller owns this directory; wait for its batch.
            materializeLock.unlock()
            inFlight.lock()
            while !isMaterialized(path) { inFlight.wait() }
            inFlight.unlock()
            return
        }
        let condition = NSCondition()
        materializing[path] = condition
        materializeLock.unlock()

        defer {
            materializeLock.lock()
            materialized.insert(path)
            materializing[path] = nil
            materializeLock.unlock()
            condition.lock(); condition.broadcast(); condition.unlock()
        }

        guard !isClosed else { throw SessionError.closed }
        let plan = tree.materializationPlan(for: path)
        guard !plan.leaves.isEmpty || !plan.packages.isEmpty else { return }
        // The whole archive never has to fit, but this directory's batch does.
        let batchBytes = (tree.children(of: path) ?? [])
            .filter { $0.isExtractable && ($0.kind == .file || $0.isPackage) }
            .reduce(Int64(0)) { $0 + $1.uncompressedSize }
        if let refusal = FileOperations.requiredSpaceRefusal(forExtracting: batchBytes, into: storageURL) {
            throw refusal
        }
        let destination = path.isEmpty ? rootURL : rootURL.appendingPathComponent(path)
        // Two invocations at most: `-n` is right for a leaf and wrong for a
        // package, and it is a switch rather than a per-member option.
        try materialize(plan.leaves, noRecursion: true)
        try materialize(plan.packages, noRecursion: false)
        try? FileOperations.propagateArchiveQuarantine(from: archiveURL, to: destination)
    }

    private func isMaterialized(_ path: String) -> Bool {
        materializeLock.lock(); defer { materializeLock.unlock() }
        return materialized.contains(path)
    }

    private func materialize(_ members: [String], noRecursion: Bool) throws {
        guard !members.isEmpty else { return }
        do {
            try FileOperations.materializeArchiveMembers(archive: archiveURL, into: rootURL,
                                                         scratch: storageURL, members: members,
                                                         noRecursion: noRecursion)
        } catch {
            // Exit status is archive-wide: some members may have been written
            // while others failed. The listing that follows reads the disk, so
            // whatever did land is shown and whatever did not simply is not —
            // which is the same inert row an escaping symlink already produces.
            // Reported rather than thrown, so one bad member cannot make a
            // whole directory unbrowsable.
            if SmokeTest.isRequested { print("ERROR materialize: \(error)") }
        }
    }
    private let stateLock = NSLock()
    private var closed = false
    var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    fileprivate init(archive: URL, storage: URL, root: URL, fileID: UInt64, lock: Int32 = -1,
                     tree: ArchiveTree? = nil) {
        archiveURL = archive.standardizedFileURL
        storageURL = storage
        rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        storageFileID = fileID
        lockDescriptor = lock
        self.tree = tree
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

    /// The directory's real contents. On a lazily mounted session this is also
    /// where its bytes arrive: reading the disk is only correct once the
    /// directory has been materialized, so the two belong together rather than
    /// leaving every caller to remember.
    func entries(in directory: URL, beforeReadingEntry: ((URL) throws -> Void)? = nil) throws -> [Entry] {
        let directory = try validatedURL(directory)
        try materializeDirectory(containing: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SessionError.notDirectory
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)
        return try urls.compactMap { url -> Entry? in
            let attributes: [FileAttributeKey: Any]
            do {
                try beforeReadingEntry?(url)
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                let failure = error as NSError
                // Editors commonly replace a temporary document atomically.
                // Only a vanished child is skipped; permissions/I/O errors
                // still surface instead of silently hiding a damaged snapshot.
                if (failure.domain == NSCocoaErrorDomain
                    && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code))
                    || (failure.domain == NSPOSIXErrorDomain && failure.code == ENOENT) { return nil }
                throw error
            }
            let link = attributes[.type] as? FileAttributeType == .typeSymbolicLink
            let contained = (try? validatedURL(url)) != nil
            // Do not inspect an escaped link's target, even just for its icon or size.
            let target = link ? url.resolvingSymlinksInPath() : url
            let values = contained ? try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey]) : nil
            return Entry(url: url, name: url.lastPathComponent, isDirectory: values?.isDirectory == true,
                         isPackage: values?.isPackage == true, isSymbolicLink: link,
                         canAccess: contained && values != nil, size: Int64(values?.fileSize ?? 0),
                         modificationDate: tree?.node(at: archivePath(of: url))?.modificationDate)
        }.sorted {
            if $0.isNavigable != $1.isNavigable { return $0.isNavigable }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func close() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        let descriptor = lockDescriptor
        lockDescriptor = -1
        stateLock.unlock()
        Self.releaseStorageLock(descriptor)
        FileOperations.discardArchiveBrowsingSession(storageURL, fileID: storageFileID)
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

    static func prepareArchiveBrowsingSession(archive: URL, logicalArchiveURL: URL? = nil,
        listing: ArchiveListing = BSDTarArchiveListing(),
        cancellation: ArchivePreparationCancellation = ArchivePreparationCancellation(),
        completion: @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let storage = fm.temporaryDirectory.appendingPathComponent(ArchiveBrowsingSession.storagePrefix + UUID().uuidString)
            var storageID: UInt64?
            var storageLock: Int32 = -1
            do {
                try cancellation.checkCancellation()
                // Before a byte is staged: refuse an archive we cannot read,
                // one that is password-protected, and one that will not fit.
                try FileOperations.checkArchiveForBrowsing(archive)
                let entries = try listing.entries(of: archive)
                // Dates come from the central directory, joined by path; the
                // listing stays the tool's own (D93).
                let tree = ArchiveTree(entries: entries,
                                       modificationDates: ZIPCentralDirectory.modificationDates(of: archive))
                // Mounting writes only the skeleton and the symbolic links, so
                // the whole archive's size is not what has to fit; each
                // directory's batch is checked against free space as it runs.
                // What must fit up front is the skeleton itself.
                if let refusal = requiredSpaceRefusal(forExtracting: Int64(tree.directoryPaths.count) * 4096,
                                                      into: fm.temporaryDirectory) {
                    throw refusal
                }
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
                // Mount, rather than stage: the table of contents becomes a
                // directory skeleton, the symbolic links are written so
                // containment can be judged from the real links, and not one
                // file's bytes are read. A directory's contents arrive when it
                // is listed (D92).
                // The same moment the eager path reported: storage exists and
                // nothing from the archive has been written yet.
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
                try materializeArchiveMembers(archive: archive, into: root, scratch: storage,
                                              members: tree.symbolicLinkMembers, noRecursion: true,
                                              cancellation: cancellation)
                try? propagateArchiveQuarantine(from: archive, to: root, cancellation: cancellation)
                try cancellation.checkpoint(.beforePublication)
                let session = ArchiveBrowsingSession(archive: logicalArchiveURL ?? archive, storage: storage,
                                                     root: root, fileID: id, lock: lock, tree: tree)
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

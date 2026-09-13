import Foundation
import Darwin

private struct TransferIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let flags: UInt32
    let modified: timespec
    let changed: timespec
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; mode = s.st_mode; size = s.st_size; flags = s.st_flags
        modified = s.st_mtimespec; changed = s.st_ctimespec
    }
    static func == (a: Self, b: Self) -> Bool {
        a.device == b.device && a.inode == b.inode && a.mode == b.mode && a.size == b.size && a.flags == b.flags &&
        a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec &&
        a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
    }
    func sameItem(as other: Self) -> Bool { device == other.device && inode == other.inode }
    var type: mode_t { mode & S_IFMT }
    static func directory(_ url: URL) throws -> Self {
        var value = stat()
        guard stat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw TransferError.destinationChanged(url) }
        return Self(value)
    }
    static func read(_ url: URL) throws -> Self {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw posixError(url) }
        return Self(value)
    }
}

private func posixError(_ url: URL) -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
}

/// Owns only private replacement directories this transfer created. Backups live
/// on their original volumes so undo/redo always use same-volume renames.
private final class TransferStorage {
    private(set) var roots: [URL] = []
    private var rootIdentities: [String: TransferIdentity] = [:]
    var preserveForRecovery = false
    func location(beside url: URL) throws -> URL {
        let parent = url.deletingLastPathComponent()
        let volume = try TransferIdentity.directory(parent).device
        let root: URL
        if let existing = roots.first(where: { rootIdentities[$0.path]?.device == volume }) { root = existing }
        else {
            // Foundation provides a private directory on the appropriate volume.
            // Keeping staging outside the displayed source/destination also avoids
            // polluting Show Hidden and survives a renamed parent during copying.
            root = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: parent, create: true).resolvingSymlinksInPath()
            let identity = try TransferIdentity.read(root)
            guard identity.device == volume else {
                try? FileManager.default.removeItem(at: root)
                throw TransferError.destinationChanged(parent)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            roots.append(root)
            rootIdentities[root.path] = identity
        }
        return root.appendingPathComponent(UUID().uuidString)
    }
    func cleanUnretained(keeping paths: Set<String>) -> [FileOperations.Failure] {
        // Foundation may enumerate a /var replacement directory using /private/var.
        // Compare canonical parents while keeping the leaf itself undereferenced.
        func key(_ url: URL) -> String { url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path }
        let retained = Set(paths.map { key(URL(fileURLWithPath: $0)) })
        var failures: [FileOperations.Failure] = []
        for root in roots {
            guard let expected = rootIdentities[root.path], let actual = try? TransferIdentity.read(root), actual.sameItem(as: expected) else { continue }
            do {
                for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !retained.contains(key(child)) {
                    try Self.removeOwnedItem(child)
                }
                if !retained.contains(where: { $0.hasPrefix(root.resolvingSymlinksInPath().path + "/") }) {
                    try FileManager.default.removeItem(at: root)
                    rootIdentities.removeValue(forKey: root.path)
                }
            } catch {
                preserveForRecovery = true
                failures.append(.init(url: root, error: NSError(domain: "Tursora.Transfer", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Temporary data could not be removed and is retained at \(root.path): \(error.localizedDescription)"])))
            }
        }
        roots.removeAll { rootIdentities[$0.path] == nil }
        return failures
    }
    deinit {
        guard !preserveForRecovery else { return }
        for root in roots {
            guard let expected = rootIdentities[root.path], let actual = try? TransferIdentity.read(root), actual.sameItem(as: expected) else { continue }
            try? Self.removeOwnedItem(root)
        }
    }

    /// Only private, disposable staging/backups come here. Symlinks are never
    /// followed, and originals keep their flags while undo can still restore them.
    static func removeOwnedItem(_ url: URL) throws {
        func prepare(_ item: URL) throws {
            let identity = try TransferIdentity.read(item)
            if identity.flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
                guard lchflags(item.path, identity.flags & ~UInt32(UF_IMMUTABLE | UF_APPEND)) == 0 else { throw posixError(item) }
            }
            if identity.type == S_IFDIR {
                guard chmod(item.path, identity.mode | 0o700) == 0 else { throw posixError(item) }
                for child in try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) { try prepare(child) }
            }
        }
        try prepare(url)
        try FileManager.default.removeItem(at: url)
    }
}

private struct TransferRename {
    let from: URL
    let to: URL
    let identity: TransferIdentity
    let fromParent: TransferIdentity?
    let toParent: TransferIdentity?
    let adjustsOwnedFlags: Bool
    let requiresEmptyDirectory: Bool
    init(from: URL, to: URL, identity: TransferIdentity, adjustsOwnedFlags: Bool = false, requiresEmptyDirectory: Bool = false) {
        self.from = from; self.to = to; self.identity = identity; self.adjustsOwnedFlags = adjustsOwnedFlags; self.requiresEmptyDirectory = requiresEmptyDirectory
        fromParent = try? TransferIdentity.directory(from.deletingLastPathComponent())
        toParent = try? TransferIdentity.directory(to.deletingLastPathComponent())
    }
    private init(from: URL, to: URL, identity: TransferIdentity, fromParent: TransferIdentity?, toParent: TransferIdentity?, adjustsOwnedFlags: Bool, requiresEmptyDirectory: Bool) {
        self.from = from; self.to = to; self.identity = identity; self.fromParent = fromParent; self.toParent = toParent; self.adjustsOwnedFlags = adjustsOwnedFlags; self.requiresEmptyDirectory = requiresEmptyDirectory
    }
    var reversed: Self { Self(from: to, to: from, identity: identity, fromParent: toParent, toParent: fromParent, adjustsOwnedFlags: adjustsOwnedFlags, requiresEmptyDirectory: requiresEmptyDirectory) }
    func relocated(_ url: URL) -> URL {
        if url.path == from.path { return to }
        if url.path.hasPrefix(from.path + "/") { return to.appendingPathComponent(String(url.path.dropFirst(from.path.count + 1))) }
        return url
    }
    func perform() throws {
        guard let fromParent, let toParent,
              try TransferIdentity.directory(from.deletingLastPathComponent()).sameItem(as: fromParent),
              try TransferIdentity.directory(to.deletingLastPathComponent()).sameItem(as: toParent) else { throw TransferError.destinationChanged(to) }
        let actual = try TransferIdentity.read(from)
        guard actual.sameItem(as: identity) else { throw TransferError.sourceChanged(from) }
        if requiresEmptyDirectory {
            guard actual.type == S_IFDIR, try FileManager.default.contentsOfDirectory(atPath: from.path).isEmpty else { throw TransferError.sourceChanged(from) }
        }
        let adjusted = adjustsOwnedFlags && actual.flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0
        if adjusted {
            guard lchflags(from.path, actual.flags & ~UInt32(UF_IMMUTABLE | UF_APPEND)) == 0 else { throw posixError(from) }
        }
        // RENAME_EXCL is essential: a concurrent task or external process may
        // create the target after the conflict decision. Never overwrite it.
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            let error = posixError(to)
            if adjusted && lchflags(from.path, actual.flags) != 0 { throw TransferError.recovery([from]) }
            throw error
        }
        if adjusted && lchflags(to.path, actual.flags) != 0 {
            let error = posixError(to)
            guard renamex_np(to.path, from.path, UInt32(RENAME_EXCL)) == 0,
                  lchflags(from.path, actual.flags) == 0 else { throw TransferError.recovery([from, to]) }
            throw error
        }
    }
}

private struct TransferTreeFingerprint: Equatable {
    let entries: [String: TransferIdentity]
    init(_ root: URL) throws {
        var items: [String: TransferIdentity] = [:]
        func visit(_ url: URL) throws {
            let identity = try TransferIdentity.read(url)
            items[url.path] = identity
            if identity.type == S_IFDIR {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try visit(child) }
            }
        }
        try visit(root)
        entries = items
    }
}

struct TransferReplayError: LocalizedError {
    let underlyingError: Error
    let recoveryDirectories: [URL]
    var errorDescription: String? {
        "The transfer could not be undone or redone: \(underlyingError.localizedDescription) " +
        "Recovery data is retained at: " + recoveryDirectories.map(\.path).joined(separator: ", ")
    }
}

final class TransferJournal {
    fileprivate let storage: TransferStorage
    fileprivate let steps: [TransferRename]
    private let strictRoots: [URL]
    private let fingerprints: [TransferTreeFingerprint?]
    var affectedDirectories: [URL] { steps.flatMap { [$0.from.deletingLastPathComponent(), $0.to.deletingLastPathComponent()] } }
    fileprivate init(storage: TransferStorage, steps: [TransferRename], strictRoots: [URL] = [], capturedFingerprints: [TransferTreeFingerprint?]? = nil) {
        self.storage = storage; self.steps = steps; self.strictRoots = strictRoots
        fingerprints = capturedFingerprints ?? strictRoots.map { try? TransferTreeFingerprint($0) }
    }
    func replay() throws -> TransferJournal {
        TransferEngine.commitLock.lock(); defer { TransferEngine.commitLock.unlock() }
        do {
            // Cross-volume moves keep two replicas for atomic undo. If either was
            // edited, refuse rather than restoring stale bytes over those edits.
            for (root, expected) in zip(strictRoots, fingerprints) {
                guard let expected, try TransferTreeFingerprint(root) == expected else { throw TransferError.sourceChanged(root) }
            }
            try TransferEngine.performTransaction(steps, storage: storage)
            var relocatedRoots = strictRoots
            for step in steps { relocatedRoots = relocatedRoots.map(step.relocated) }
            return TransferJournal(storage: storage, steps: steps.reversed().map(\.reversed), strictRoots: relocatedRoots)
        } catch {
            // NSUndoManager consumes a failed action too. Preserve its backups
            // independently of the journal's lifetime and expose their locations
            // before the last reference can disappear from the undo stack.
            storage.preserveForRecovery = true
            throw TransferReplayError(underlyingError: error, recoveryDirectories: storage.roots)
        }
    }
}

/// FileOperations owns this worker. Individual files/directories are copied to
/// a private same-volume directory and become successful only after exclusive publication.
final class TransferEngine {
    fileprivate static let commitLock = NSLock()
    let task: TransferTask
    let options: TransferOptions
    private let handler: FileOperations.ConflictHandler
    private let asyncHandler: FileOperations.AsyncConflictHandler?
    private let storage = TransferStorage()
    private var undoSteps: [TransferRename] = []
    private var strictUndoRoots: [URL] = []
    private var strictUndoFingerprints: [TransferTreeFingerprint?] = []
    private var result = FileOperations.TransferResult()
    private var remaining = 0
    private var applyAll: FileOperations.ConflictResolution?
    private var fingerprints: [String: TransferIdentity] = [:]
    private var sizes: [String: Int64] = [:]
    private var directoryPins: [String: TransferIdentity] = [:]

    init(task: TransferTask, options: TransferOptions, conflict: @escaping FileOperations.ConflictHandler,
         asyncConflict: FileOperations.AsyncConflictHandler?) {
        self.task = task; self.options = options; handler = conflict; asyncHandler = asyncConflict
    }
    func run() -> FileOperations.TransferResult {
        var total: Int64 = 0
        var scanFailed = Set<String>()
        do {
            if !options.duplicateInPlace { try pinDirectory(task.destination) }
            for source in task.sources { try pinDirectory(source.deletingLastPathComponent()) }
        } catch {
            result.failures.append(.init(url: task.destination, error: error))
            task.finished(result)
            return result
        }
        for source in task.sources {
            do {
                try boundary(.preparing, source)
                let amount = try scan(source, recursively: !canMoveAtomically(source, to: task.destination))
                total += streamContribution(source, size: amount)
            } catch TransferError.cancelled { result.cancelled = true; break }
            catch { result.failures.append(.init(url: source, error: error)); scanFailed.insert(source.path) }
        }
        task.setTotal(result.cancelled ? nil : total)
        remaining = task.sources.filter { FileOperations.itemExists(task.destination.appendingPathComponent($0.lastPathComponent)) }.count
        if !result.cancelled {
            for source in task.sources where !scanFailed.contains(source.path) {
                let destination = options.duplicateInPlace ? FileOperations.duplicateURL(for: source) : task.destination.appendingPathComponent(source.lastPathComponent)
                transferOne(source, to: destination)
                if result.cancelled { break }
            }
        }
        if !undoSteps.isEmpty { result.journal = TransferJournal(storage: storage, steps: undoSteps.reversed(), strictRoots: strictUndoRoots, capturedFingerprints: strictUndoFingerprints) }
        if !storage.preserveForRecovery {
            let retainedPaths = Set(undoSteps.flatMap { [$0.from.path, $0.to.path] })
            result.failures.append(contentsOf: storage.cleanUnretained(keeping: retainedPaths))
        }
        task.finished(result)
        return result
    }

    private func streamContribution(_ source: URL, size: Int64) -> Int64 {
        let destination = options.duplicateInPlace ? source.deletingLastPathComponent() : task.destination
        return canMoveAtomically(source, to: destination) ? 0 : size
    }

    private func canMoveAtomically(_ source: URL, to directory: URL) -> Bool {
        guard task.kind == .move, !options.forceCrossVolumeMove,
              let sourceIdentity = try? TransferIdentity.read(source),
              let destinationIdentity = try? TransferIdentity.directory(directory) else { return false }
        return sourceIdentity.device == destinationIdentity.device
    }

    private func boundary(_ stage: TransferCheckpoint, _ source: URL) throws {
        try task.checkpoint()
        try options.checkpoint?(stage, source, task.snapshot.completedBytes)
        try task.checkpoint()
    }

    private func pinDirectory(_ url: URL, expected: TransferIdentity? = nil) throws {
        let actual = try TransferIdentity.directory(url)
        if let previous = directoryPins[url.path] {
            guard actual.sameItem(as: previous) else { throw TransferError.destinationChanged(url) }
        }
        if let expected {
            guard actual.sameItem(as: expected) else { throw TransferError.destinationChanged(url) }
        }
        directoryPins[url.path] = actual
    }

    private func scan(_ url: URL, recursively: Bool = true) throws -> Int64 {
        task.setPhase(.preparing, item: url, detail: "Calculating transfer size…")
        try boundary(.preparing, url)
        let identity = try TransferIdentity.read(url)
        fingerprints[url.path] = identity
        // A same-volume rename preserves every descendant without reading it.
        // FIFOs, sockets and unreadable directories are valid move operands.
        if !recursively {
            sizes[url.path] = 0
            return 0
        }
        var amount: Int64 = 0
        switch identity.type {
        case S_IFDIR:
            try pinDirectory(url, expected: identity)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                amount += try scan(child)
            }
        case S_IFREG: amount = identity.size
        case S_IFLNK: break
        default: throw TransferError.unsupported(url)
        }
        sizes[url.path] = amount
        return amount
    }

    private func validateSource(_ url: URL, recursively: Bool = false, controllable: Bool = true) throws {
        if controllable { try task.checkpoint() }
        else if task.isCancellationRequested { throw TransferError.cancelled }
        guard let expected = fingerprints[url.path], try TransferIdentity.read(url) == expected else { throw TransferError.sourceChanged(url) }
        if recursively && expected.type == S_IFDIR {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try validateSource(child, recursively: true, controllable: controllable)
            }
        }
    }

    private func transferOne(_ source: URL, to requested: URL) {
        var destination = requested
        do {
            try task.checkpoint()
            try pinDirectory(source.deletingLastPathComponent())
            try pinDirectory(destination.deletingLastPathComponent())
            // Atomic moves are scanned only at their root. Merge enumerates
            // children on demand and each child gets its own fixed identity.
            if fingerprints[source.path] == nil {
                _ = try scan(source, recursively: !canMoveAtomically(source, to: destination.deletingLastPathComponent()))
            }
            task.setPhase(.running, item: source, detail: "Preparing item…")
            if source.standardizedFileURL == destination.standardizedFileURL {
                if task.kind == .move { return }
                destination = FileOperations.duplicateURL(for: source)
            }
            // Resolve the parent, never the leaf: symlinks themselves are files.
            let realSource = source.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(source.lastPathComponent)
            let realDestination = destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent)
            if fingerprints[source.path]?.type == S_IFDIR && (realDestination.path == realSource.path || realDestination.path.hasPrefix(realSource.path + "/")) {
                throw TransferError.nestedDestination
            }
            var existing = try? TransferIdentity.read(destination)
            if existing != nil {
                let conflict = FileOperations.Conflict(source: source, destination: destination, kind: task.kind, remaining: max(1, remaining))
                remaining = max(0, remaining - 1)
                switch try decide(conflict) {
                case .cancel: throw TransferError.cancelled
                case .skip: task.skip(bytes: streamContribution(source, size: sizes[source.path] ?? 0)); return
                case .keepBoth: destination = FileOperations.uniqueURL(for: destination); existing = nil
                case .replace: break
                case .merge:
                    if conflict.bothFolders {
                        try merge(source, into: destination, expectedDestination: existing!)
                        return
                    }
                    destination = FileOperations.uniqueURL(for: destination); existing = nil
                }
            }
            try transferItem(source, to: destination, replacing: existing)
        } catch TransferError.cancelled { result.cancelled = true }
        catch { result.failures.append(.init(url: source, error: error)) }
    }

    private final class DecisionBox {
        let condition = NSCondition()
        var value: FileOperations.ConflictDecision?
        func resolve(_ decision: FileOperations.ConflictDecision) {
            condition.lock(); defer { condition.unlock() }
            if value == nil { value = decision }; condition.broadcast()
        }
    }
    private func decide(_ conflict: FileOperations.Conflict) throws -> FileOperations.ConflictResolution {
        if let applyAll { return applyAll }
        task.setPhase(.waitingForConflict, item: conflict.source, detail: "Waiting for a conflict decision")
        let box = DecisionBox()
        DispatchQueue.main.async { [task, handler, asyncHandler] in
            guard !task.isCancellationRequested else { box.resolve(.init(resolution: .cancel)); return }
            if let asyncHandler { asyncHandler(conflict, box.resolve) }
            else { box.resolve(handler(conflict)) }
        }
        while true {
            try task.checkpoint()
            box.condition.lock()
            if let decision = box.value {
                box.condition.unlock()
                if decision.applyToAll { applyAll = decision.resolution }
                task.setPhase(.running, item: conflict.source, detail: "Preparing item…")
                return decision.resolution
            }
            _ = box.condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            box.condition.unlock()
        }
    }

    private func transferItem(_ source: URL, to destination: URL, replacing existing: TransferIdentity?) throws {
        try validateSource(source)
        let parent = destination.deletingLastPathComponent()
        try pinDirectory(source.deletingLastPathComponent())
        try pinDirectory(parent)
        let parentIdentity = try TransferIdentity.directory(parent)
        let atomicMove = canMoveAtomically(source, to: parent)
        let staged = try storage.location(beside: destination)
        if !atomicMove {
            try boundary(.beforeCopy, source)
            do { try copyTree(source, to: staged); try validateSource(source, recursively: true) }
            catch { try? TransferStorage.removeOwnedItem(staged); throw error }
        }
        defer { if FileOperations.itemExists(staged) && !storage.preserveForRecovery { try? TransferStorage.removeOwnedItem(staged) } }
        try boundary(.beforePublish, source)
        if task.kind == .move { try boundary(.beforeSourceRemoval, source) }
        try validateSource(source, recursively: !atomicMove)
        let stagedIdentity = atomicMove ? try TransferIdentity.read(source) : try TransferIdentity.read(staged)
        var changes: [TransferRename] = []
        var retiredSource: URL?
        if let existing {
            let backup = try storage.location(beside: destination)
            changes.append(TransferRename(from: destination, to: backup, identity: existing))
        }
        changes.append(TransferRename(from: atomicMove ? source : staged, to: destination, identity: stagedIdentity, adjustsOwnedFlags: !atomicMove))
        if task.kind == .move && !atomicMove {
            let retirementRoot = task.sources.first { source.path == $0.path || source.path.hasPrefix($0.path + "/") } ?? source
            let retired = try storage.location(beside: retirementRoot)
            changes.append(TransferRename(from: source, to: retired, identity: try TransferIdentity.read(source)))
            retiredSource = retired
        }
        try task.checkpoint()
        task.setPhase(.finishing, item: source, detail: atomicMove ? "Moving atomically on the same volume…" : "Publishing the completed item…")
        Self.commitLock.lock()
        do {
            guard try TransferIdentity.directory(parent).sameItem(as: parentIdentity) else { throw TransferError.destinationChanged(parent) }
            if let existing {
                guard try TransferIdentity.read(destination) == existing else { throw TransferError.destinationChanged(destination) }
            }
            // Recheck after acquiring the publication lock: another task or an
            // external editor may have changed source data while we waited.
            try validateSource(source, recursively: !atomicMove, controllable: false)
            if task.isCancellationRequested { throw TransferError.cancelled }
            prepareStrictRelocation(changes)
            try Self.performTransaction(changes, storage: storage)
            // Append inverses in forward commit order; the completed batch reverses them.
            undoSteps.append(contentsOf: changes.map(\.reversed))
            relocateStrictRoots(changes)
            if let retiredSource {
                let roots = [destination, retiredSource]
                strictUndoRoots += roots
                // Capture at this commit, before afterPublish can pause or later
                // batch items run; subsequent external edits must stay detectable.
                strictUndoFingerprints += roots.map { try? TransferTreeFingerprint($0) }
            }
            Self.commitLock.unlock()
        } catch { Self.commitLock.unlock(); throw error }
        if task.kind == .copy { result.created.append(destination) }
        else { result.moved.append((source, destination)) }
        try boundary(.afterPublish, source)
    }

    private func prepareStrictRelocation(_ changes: [TransferRename]) {
        for index in strictUndoRoots.indices {
            let root = strictUndoRoots[index]
            if changes.contains(where: { $0.relocated(root).path != root.path }) {
                guard let expected = strictUndoFingerprints[index],
                      let actual = try? TransferTreeFingerprint(root), actual == expected else {
                    strictUndoFingerprints[index] = nil
                    continue
                }
            }
        }
    }
    private func relocateStrictRoots(_ changes: [TransferRename]) {
        for index in strictUndoRoots.indices {
            let old = strictUndoRoots[index]
            var relocated = old
            for change in changes { relocated = change.relocated(relocated) }
            if relocated.path != old.path {
                strictUndoRoots[index] = relocated
                if strictUndoFingerprints[index] != nil { strictUndoFingerprints[index] = try? TransferTreeFingerprint(relocated) }
            }
        }
    }

    fileprivate static func performTransaction(_ changes: [TransferRename], storage: TransferStorage) throws {
        var completed: [TransferRename] = []
        do {
            for change in changes { try change.perform(); completed.append(change) }
        } catch {
            if case TransferError.recovery = error { storage.preserveForRecovery = true }
            for change in completed.reversed() {
                do { try change.reversed.perform() }
                catch {
                    // Never remove a backup whose restoration failed. The error
                    // explicitly gives the retained recovery paths.
                    storage.preserveForRecovery = true
                }
            }
            if storage.preserveForRecovery {
                throw NSError(domain: "Tursora.Transfer", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The operation could not be rolled back safely. Original data is retained in: " + storage.roots.map(\.path).joined(separator: ", ")])
            }
            throw error
        }
    }

    private func merge(_ source: URL, into destination: URL, expectedDestination: TransferIdentity) throws {
        guard let expectedSource = fingerprints[source.path] else { throw TransferError.sourceChanged(source) }
        try pinDirectory(source, expected: expectedSource)
        try pinDirectory(destination, expected: expectedDestination)
        let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
        remaining += children.filter { FileOperations.itemExists(destination.appendingPathComponent($0.lastPathComponent)) }.count
        for child in children {
            try pinDirectory(source, expected: expectedSource)
            try pinDirectory(destination, expected: expectedDestination)
            transferOne(child, to: destination.appendingPathComponent(child.lastPathComponent))
            if result.cancelled { return }
        }
        try task.checkpoint()
        try pinDirectory(source, expected: expectedSource)
        try pinDirectory(destination, expected: expectedDestination)
        if task.kind == .move, try FileManager.default.contentsOfDirectory(atPath: source.path).isEmpty {
            let retirementRoot = task.sources.first { source.path == $0.path || source.path.hasPrefix($0.path + "/") } ?? source
            let retired = try storage.location(beside: retirementRoot)
            let change = TransferRename(from: source, to: retired, identity: try TransferIdentity.read(source), requiresEmptyDirectory: true)
            Self.commitLock.lock(); defer { Self.commitLock.unlock() }
            prepareStrictRelocation([change])
            try Self.performTransaction([change], storage: storage)
            // Restore the empty source directory before restoring its children.
            undoSteps.append(change.reversed)
            relocateStrictRoots([change])
        }
    }

    private func copyTree(_ source: URL, to destination: URL) throws {
        try validateSource(source)
        guard let identity = fingerprints[source.path] else { throw TransferError.sourceChanged(source) }
        switch identity.type {
        case S_IFDIR:
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                try task.checkpoint()
                try copyTree(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
            try metadata(source, to: destination)
        case S_IFREG: try copyRegular(source, to: destination)
        case S_IFLNK:
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: link)
            try metadata(source, to: destination)
        default: throw TransferError.unsupported(source)
        }
    }

    private func copyRegular(_ source: URL, to destination: URL) throws {
        task.setPhase(.running, item: source, detail: "Transferring file data…")
        let input = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw posixError(source) }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw posixError(destination) }
        defer { close(output) }
        var initial = stat()
        guard fstat(input, &initial) == 0 else { throw posixError(source) }
        guard TransferIdentity(initial) == fingerprints[source.path] else { throw TransferError.sourceChanged(source) }
        var buffer = [UInt8](repeating: 0, count: max(4096, min(options.blockSize, 4 * 1024 * 1024)))
        while true {
            try task.checkpoint()
            let count = read(input, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw posixError(source) }
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset < count {
                    try task.checkpoint()
                    let written = write(output, raw.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 { if errno == EINTR { continue }; throw posixError(destination) }
                    guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                    offset += written
                    task.addBytes(Int64(written))
                }
            }
            try boundary(.chunk, source)
            if options.chunkDelay > 0 {
                let end = ProcessInfo.processInfo.systemUptime + options.chunkDelay
                while ProcessInfo.processInfo.systemUptime < end {
                    try task.checkpoint()
                    Thread.sleep(forTimeInterval: min(0.01, max(0, end - ProcessInfo.processInfo.systemUptime)))
                }
            }
        }
        task.setPhase(.finishing, item: source, detail: "Preserving permissions and extended metadata…")
        try task.checkpoint()
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw posixError(destination) }
        try preserveQuarantine(source, to: destination, input: input, output: output)
        guard fsync(output) == 0 else { throw posixError(destination) }
        try task.checkpoint()
        var final = stat()
        guard fstat(input, &final) == 0, TransferIdentity(initial) == TransferIdentity(final) else { throw TransferError.sourceChanged(source) }
    }
    private func metadata(_ source: URL, to destination: URL) throws {
        try task.checkpoint()
        task.setPhase(.finishing, item: source, detail: "Preserving permissions and extended metadata…")
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else { throw posixError(destination) }
        try preserveQuarantine(source, to: destination)
        try task.checkpoint()
    }

    /// copyfile preserves quarantine enforcement but synthesizes a new origin
    /// and timestamp. Retain the source's complete quarantine record as well.
    private func preserveQuarantine(_ source: URL, to destination: URL, input: Int32? = nil, output: Int32? = nil) throws {
        let name = "com.apple.quarantine"
        func readAttribute(_ buffer: UnsafeMutableRawPointer?, _ size: Int) -> Int {
            if let input { return fgetxattr(input, name, buffer, size, 0, 0) }
            return getxattr(source.path, name, buffer, size, 0, XATTR_NOFOLLOW)
        }
        let size = readAttribute(nil, 0)
        if size < 0 {
            if errno == ENOATTR || errno == ENOTSUP { return }
            throw posixError(source)
        }
        var bytes = [UInt8](repeating: 0, count: max(1, size))
        let count = bytes.withUnsafeMutableBytes { readAttribute($0.baseAddress, size) }
        guard count == size else { throw TransferError.sourceChanged(source) }
        let flags: UInt32
        if let output {
            var info = stat()
            guard fstat(output, &info) == 0 else { throw posixError(destination) }
            flags = info.st_flags
        } else { flags = try TransferIdentity.read(destination).flags }
        func setFlags(_ value: UInt32) -> Int32 {
            if let output { return fchflags(output, value) }
            return lchflags(destination.path, value)
        }
        let adjusted = flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0
        if adjusted && setFlags(flags & ~UInt32(UF_IMMUTABLE | UF_APPEND)) != 0 { throw posixError(destination) }
        let status = bytes.withUnsafeBytes { raw -> Int32 in
            if let output { return fsetxattr(output, name, raw.baseAddress, size, 0, 0) }
            return setxattr(destination.path, name, raw.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        let error = status == 0 ? nil : posixError(destination)
        if adjusted && setFlags(flags) != 0 { throw posixError(destination) }
        if let error { throw error }
    }
}

import Foundation
import Darwin

/// One bsdtar run's raw result. Nothing is interpreted here: success is
/// decided per member from the log (`ArchiveToolVerdict`), never from the exit
/// status alone, which is archive-wide, and never from `fileExists`.
struct ArchiveToolRun {
    let status: Int32
    let log: String
}

/// Runs bsdtar. A protocol so the suite can count invocations — "eight
/// concurrent requests cause one run" is a claim about this seam.
protocol ArchiveToolRunning: AnyObject {
    func run(_ arguments: [String], scratch: URL, cancellation: ArchivePreparationCancellation?) throws -> ArchiveToolRun
}

final class SystemArchiveToolRunner: ArchiveToolRunning {
    static let shared = SystemArchiveToolRunner()
    /// A log larger than this is truncated: a batch over a very large folder
    /// names every entry once, and the verdict needs every line it can get.
    static let maximumLogBytes = 16 * 1024 * 1024

    private let lock = NSLock()
    private var count = 0
    private var mainThreadCount = 0
    /// Every run started, and those started on the main thread — which must
    /// stay zero once listing no longer extracts.
    var invocations: Int { lock.lock(); defer { lock.unlock() }; return count }
    var mainThreadInvocations: Int { lock.lock(); defer { lock.unlock() }; return mainThreadCount }
    private var gate: (() -> Void)?
    /// Runs on the worker before each run starts, so the suite can hold a real
    /// pane's request mid-flight. Never set outside the smoke test.
    var beforeRunForTesting: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return gate }
        set { lock.lock(); gate = newValue; lock.unlock() }
    }

    func run(_ arguments: [String], scratch: URL, cancellation: ArchivePreparationCancellation?) throws -> ArchiveToolRun {
        lock.lock()
        count += 1
        if Thread.isMainThread { mainThreadCount += 1 }
        let gate = self.gate
        lock.unlock()
        gate?()
        try cancellation?.checkCancellation()
        let log = scratch.appendingPathComponent("tool-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // `-v` writes to stderr. A regular file cannot fill and deadlock
        // waitUntilExit(); a pipe can.
        process.standardError = errors
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        if let cancellation { try cancellation.runProcess(process) } else { try process.run() }
        defer { cancellation?.finishProcess(process) }
        process.waitUntilExit()
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: Self.maximumLogBytes)) ?? Data()
        let status = process.terminationReason == .exit ? process.terminationStatus : -1
        return ArchiveToolRun(status: status, log: String(decoding: data, as: UTF8.self))
    }
}

/// Every byte of a lazily mounted archive arrives through here (D95).
///
/// bsdtar writes into a private staging directory beside the root, never into
/// the tree being browsed. Its log is attributed per member, and only a member
/// the log confirms is quarantined and then published by one exclusive,
/// no-follow rename. A member whose bytes are corrupt, encrypted, refused or
/// merely unconfirmed never reaches the tree — so there is no debris to clean
/// up, and nothing half-written is ever visible to a reader. Called from any
/// thread: every piece of mutable state is behind `condition`.
final class ArchiveMaterializer: @unchecked Sendable {
    enum State: Equatable {
        case absent
        case inFlight
        case published
        /// bsdtar's own reason. Sticky until the folder is reloaded, and only
        /// ever set from an attributed member error: a refusal for space, a
        /// cancellation or a source that could not be read go back to absent.
        case failed(String)
    }

    enum MaterializeError: LocalizedError {
        case sourceUnreadable(String)
        /// The archive on disk is no longer the one that was mounted. Never
        /// sticky: the session is replaced, and the entry is read again.
        case sourceChanged
        var errorDescription: String? {
            switch self {
            case .sourceUnreadable(let detail): return "The ZIP could not be read. \(detail)"
            case .sourceChanged: return "This ZIP has changed since it was opened. Open it again to see its current contents."
            }
        }
    }

    /// What identifies the archive when it could not be cloned at mount — it is
    /// on another volume — so a replacement is noticed before bsdtar reads a
    /// different file than the tree describes.
    struct SourceIdentity: Equatable {
        let device: Int
        let inode: Int
        let size: Int64
        let modified: Date?

        init?(of url: URL) {
            // Through FileManager: URL.resourceValues caches for the run-loop
            // pass, and a replaced file must be seen as replaced (rule 5).
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let device = (attributes[.systemNumber] as? NSNumber)?.intValue,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.intValue else { return nil }
            self.device = device
            self.inode = inode
            size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            modified = attributes[.modificationDate] as? Date
        }
    }

    let tree: ArchiveTree
    private let source: URL
    private let rootURL: URL
    /// `realpath(3)` of the root. `$TMPDIR` lives under `/var`, which is itself
    /// a symbolic link, so a no-follow rename on the `/var` spelling would
    /// refuse every publication.
    private let rootRealPath: String
    private let storageURL: URL
    private let runner: ArchiveToolRunning
    /// Read once at mount and stamped on every staged item before it is
    /// published, so an app from a downloaded archive keeps its quarantine.
    private let quarantine: Data?
    var spaceCheck: (Int64, URL) -> ArchiveBrowsingSession.SessionError?

    private let condition = NSCondition()
    private var states: [String: State] = [:] { didSet { stateGeneration &+= 1 } }
    private var stateGeneration = 0
    /// Set by `shutDown`: no new batch starts.
    private var closed = false
    /// Every run in flight, so `shutDown` can stop each child.
    private var activeRuns: [UUID: ArchivePreparationCancellation] = [:]
    var activeRequestCountForTesting: Int {
        condition.lock(); defer { condition.unlock() }
        return activeRuns.count
    }
    private let drain = DispatchGroup()
    private let sourceIdentity: SourceIdentity?
    private var changedSource = false
    /// The archive was replaced after mount. The session is discarded and the
    /// archive mounted again, rather than read from a file it no longer is.
    var sourceChanged: Bool { condition.lock(); defer { condition.unlock() }; return changedSource }

    init(tree: ArchiveTree, source: URL, rootURL: URL, storageURL: URL,
         runner: ArchiveToolRunning = SystemArchiveToolRunner.shared,
         sourceIdentity: SourceIdentity? = nil,
         spaceCheck: @escaping (Int64, URL) -> ArchiveBrowsingSession.SessionError?) {
        self.tree = tree
        self.source = source
        self.sourceIdentity = sourceIdentity
        self.rootURL = rootURL
        self.rootRealPath = Self.realPath(rootURL.path)
        self.storageURL = storageURL
        self.runner = runner
        self.quarantine = Self.readQuarantine(source)
        self.spaceCheck = spaceCheck
    }

    func state(of path: String) -> State {
        condition.lock(); defer { condition.unlock() }
        return states[path] ?? .absent
    }

    /// Changes whenever any entry's state does, so an answer computed from
    /// many states — whether a folder is complete — can be kept until then.
    var generation: Int {
        condition.lock(); defer { condition.unlock() }
        return stateGeneration
    }

    var publishedPaths: Set<String> {
        condition.lock(); defer { condition.unlock() }
        return Set(states.compactMap { $0.value == .published ? $0.key : nil })
    }

    /// Published or failed: nothing a new batch should ask for again.
    var settledPaths: Set<String> {
        condition.lock(); defer { condition.unlock() }
        return Set(states.compactMap { entry -> String? in
            switch entry.value {
            case .published, .failed: return entry.key
            case .absent, .inFlight: return nil
            }
        })
    }

    /// Where a published entry's bytes are, or nil. Judged from state, never
    /// from the disk: an existing file is not evidence that it is sound.
    func publishedURL(for path: String) -> URL? {
        state(of: path) == .published ? rootURL.appendingPathComponent(path) : nil
    }

    /// Forget sticky failures under a folder, for Reload.
    func forgetFailures(under directory: String) {
        condition.lock(); defer { condition.unlock() }
        let prefix = directory.isEmpty ? "" : directory + "/"
        for (path, state) in states where path.hasPrefix(prefix) {
            if case .failed = state { states[path] = nil }
        }
    }

    // MARK: - Materializing

    /// Bring a batch's members to disk. Blocks, so it runs off the main thread.
    /// A member already published or failed is left alone; one another batch
    /// is already writing is waited for rather than written twice — libarchive
    /// writes in place, so two writers on one path is a torn read.
    func materialize(_ plan: ArchiveTree.BatchPlan, cancellation: ArchivePreparationCancellation? = nil) throws {
        try materialize(plan, cancellation: cancellation, retryingOthers: true)
    }

    private func materialize(_ plan: ArchiveTree.BatchPlan, cancellation provided: ArchivePreparationCancellation?,
                             retryingOthers: Bool) throws {
        try provided?.checkCancellation()
        guard !plan.isEmpty else { return }
        // Every batch is cancellable, so closing can stop its child, and every
        // batch is counted, so closing can wait for it before storage goes.
        let cancellation = provided ?? ArchivePreparationCancellation()
        let token = UUID()
        condition.lock()
        guard !closed else { condition.unlock(); throw ArchiveBrowsingSession.SessionError.closed }
        activeRuns[token] = cancellation
        drain.enter()
        condition.unlock()
        defer {
            condition.lock()
            activeRuns[token] = nil
            condition.unlock()
            drain.leave()
        }
        // Claim what nobody else is doing; note what someone else is.
        var mine = Set<String>()
        var others = Set<String>()
        condition.lock()
        for path in plan.publishes {
            switch states[path] ?? .absent {
            case .published, .failed: continue
            case .inFlight: others.insert(path)
            case .absent: states[path] = .inFlight; mine.insert(path)
            }
        }
        condition.unlock()

        var outcome: [String: State] = [:]
        defer {
            // Anything claimed and not settled goes back to absent, so an
            // error or a cancellation never strands an entry in flight.
            condition.lock()
            for path in mine { states[path] = outcome[path] ?? .absent }
            condition.broadcast()
            condition.unlock()
        }

        if !mine.isEmpty {
            let owned = Self.restricted(plan, to: mine)
            if let refusal = spaceCheck(owned.bytes, storageURL) { throw refusal }
            outcome = try run(owned, cancellation: cancellation)
        }

        // Wait for another batch's members rather than writing them twice.
        guard !others.isEmpty else { return }
        condition.lock()
        while others.contains(where: { states[$0] == .inFlight }) {
            if cancellation.isCancelled {
                condition.unlock()
                throw ArchiveBrowsingSession.SessionError.cancelled
            }
            // This subscriber must be able to leave without stopping the
            // owner of the shared bytes or waiting for that owner's tool.
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        let leftover = others.filter { (states[$0] ?? .absent) == .absent }
        condition.unlock()
        try cancellation.checkCancellation()
        // The other batch did not settle them — refused for space, cancelled —
        // so this caller tries once itself and sees the real outcome, rather
        // than listing a folder that was never filled.
        if retryingOthers, !leftover.isEmpty {
            try materialize(Self.restricted(plan, to: Set(leftover)), cancellation: cancellation, retryingOthers: false)
        }
    }

    private func run(_ plan: ArchiveTree.BatchPlan,
                     cancellation: ArchivePreparationCancellation?) throws -> [String: State] {
        try checkSource()
        let staging = storageURL.appendingPathComponent(".tursora-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }

        var outcome: [String: State] = [:]
        var confirmed = Set<String>()
        func absorb(_ verdict: ArchiveToolVerdict, members: Set<String>) throws {
            if let failure = verdict.sourceFailure { throw MaterializeError.sourceUnreadable(failure) }
            for path in verdict.extracted where members.contains(path) { confirmed.insert(path) }
            for (path, reason) in verdict.failed where members.contains(path) {
                outcome[path] = .failed(reason)
                confirmed.remove(path)
            }
            if !verdict.unrecognized.isEmpty, SmokeTest.isRequested {
                print("NOTE materialize: unplaced tool lines \(verdict.unrecognized.prefix(3))")
            }
        }

        // Leaves, one by one with -n.
        if !plan.leaves.isEmpty {
            let list = staging.appendingPathComponent(".members-leaves")
            try Data((plan.leaves.map(\.escaped).joined(separator: "\n") + "\n").utf8).write(to: list)
            let result = try runner.run(ArchiveTool.extractionArguments(source: source, output: staging, noRecursion: true,
                                                                          memberList: list), scratch: storageURL,
                                        cancellation: cancellation)
            try cancellation?.checkCancellation()
            try absorb(ArchiveToolVerdict.attribute(log: result.log, members: plan.leaves),
                       members: Set(plan.leaves.map(\.path)))
        }
        // Packages whole, less their inert members.
        if !plan.packages.isEmpty {
            let list = staging.appendingPathComponent(".members-packages")
            // A member spelled differently from its package is named too:
            // matching is case-sensitive, the volume is not.
            let members = plan.packages.flatMap { tree.packageMembers($0.path) }
            try Data((members.joined(separator: "\n") + "\n").utf8).write(to: list)
            let result = try runner.run(ArchiveTool.extractionArguments(source: source, output: staging, noRecursion: false,
                                                                          memberList: list, excludes: plan.packageExcludes),
                                        scratch: storageURL, cancellation: cancellation)
            try cancellation?.checkCancellation()
            let spellings = plan.packages.flatMap { tree.packageSpellings($0.path) }
            try absorb(ArchiveToolVerdict.attribute(log: result.log, members: spellings,
                                                    packages: plan.packages.map(\.path)),
                       members: Set(plan.packages.map(\.path)))
        }
        // One directory selection.
        if let selection = plan.selection, !plan.selected.isEmpty {
            let includes = selection.include.map { [$0] } ?? []
            let result = try runner.run(ArchiveTool.extractionArguments(source: source, output: staging, noRecursion: false,
                                                                          excludes: selection.excludes, includes: includes),
                                        scratch: storageURL, cancellation: cancellation)
            try cancellation?.checkCancellation()
            // Anything the selection may announce is a known name, directory
            // records included, so none of it reads as an unplaced line.
            let scope = selection.include.map { ArchiveTree.unescape($0) } ?? ""
            let recursive = !selection.excludes.contains((scope.isEmpty ? "" : ArchiveTree.escapeMember(scope) + "/") + "*/*")
            // The selected folder announces its own record too (`x F/`).
            let own = tree.node(at: scope).map { [tree.spelling(of: $0)] } ?? []
            try absorb(ArchiveToolVerdict.attribute(log: result.log,
                                                    members: own + tree.spellings(within: scope, recursive: recursive)),
                       members: Set(plan.selected.map(\.path)))
        }

        // Publish only what the log confirmed, one exclusive rename each.
        // Both spellings go through realpath: no-follow refuses a link in
        // *either* path, and staging sits under `$TMPDIR`, which is under
        // `/var` — itself a symbolic link.
        let stagingRealPath = Self.realPath(staging.path)
        for path in confirmed.sorted() {
            try cancellation?.checkCancellation()
            outcome[path] = publish(path, fromStaging: stagingRealPath)
        }
        return outcome
    }

    /// Quarantine, then one `renamex_np(RENAME_EXCL | RENAME_NOFOLLOW_ANY)` on
    /// `realpath` spellings. No-follow is what stops a staged file being
    /// published through a symbolic link into somewhere outside the root —
    /// extracting into empty staging bypassed bsdtar's own check (measured).
    private func publish(_ path: String, fromStaging stagingRealPath: String) -> State {
        guard tree.isReachable(path) else { return .failed("It sits under a link or inside a package.") }
        let staged = URL(fileURLWithPath: stagingRealPath).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: staged.path) else { return .absent }
        if let quarantine, !Self.stamp(quarantine, on: staged) {
            // An app from a downloaded archive that cannot carry the
            // quarantine is not published at all.
            return .failed("Its download quarantine could not be applied.")
        }
        let destination = rootRealPath + "/" + path
        let rc = staged.withUnsafeFileSystemRepresentation { from in
            destination.withCString { to in renamex_np(from!, to, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) }
        }
        if rc == 0 { return .published }
        switch errno {
        case EEXIST: return .published      // another batch got there first
        case ELOOP: return .failed("It would be written through a symbolic link.")
        default: return .absent
        }
    }

    // MARK: - Transient extraction

    struct TransientExtraction {
        /// Holds the extracted members under their paths. The caller removes it.
        let directory: URL
        let extracted: Set<String>
        /// A member bsdtar named in an error, with its reason.
        let failed: [String: String]
    }

    /// Extracts files into a fresh directory beside the root, to be read once
    /// — for a thumbnail — and removed, never published: thumbnails for a
    /// folder of photos must not leave the folder's bytes behind (D100). Only
    /// what the log confirms counts as extracted. Registered like any batch,
    /// so closing the session stops it and waits for it.
    func extractTransient(_ members: [ArchiveMemberSpelling]) throws -> TransientExtraction {
        let cancellation = ArchivePreparationCancellation()
        let token = UUID()
        condition.lock()
        guard !closed else { condition.unlock(); throw ArchiveBrowsingSession.SessionError.closed }
        activeRuns[token] = cancellation
        drain.enter()
        condition.unlock()
        defer {
            condition.lock()
            activeRuns[token] = nil
            condition.unlock()
            drain.leave()
        }
        try checkSource()
        let bytes = members.reduce(Int64(0)) { $0 + (tree.node(at: $1.path)?.uncompressedSize ?? 0) }
        if let refusal = spaceCheck(bytes, storageURL) { throw refusal }
        let directory = storageURL.appendingPathComponent(".tursora-thumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let list = storageURL.appendingPathComponent(".tursora-thumbs-members-\(token.uuidString)")
            defer { try? FileManager.default.removeItem(at: list) }
            try Data((members.map(\.escaped).joined(separator: "\n") + "\n").utf8).write(to: list)
            let result = try runner.run(ArchiveTool.extractionArguments(source: source, output: directory, noRecursion: true,
                                                                          memberList: list),
                                        scratch: storageURL, cancellation: cancellation)
            try cancellation.checkCancellation()
            let verdict = ArchiveToolVerdict.attribute(log: result.log, members: members)
            if let failure = verdict.sourceFailure { throw MaterializeError.sourceUnreadable(failure) }
            return TransientExtraction(directory: directory, extracted: verdict.extracted.subtracting(verdict.failed.keys),
                                       failed: verdict.failed)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    // MARK: - Lifecycle

    /// Stop accepting batches and ask every running child to stop. Returns
    /// whether anything was in flight, so the caller knows whether to wait.
    @discardableResult
    func shutDown() -> Bool {
        condition.lock()
        closed = true
        let running = Array(activeRuns.values)
        condition.unlock()
        running.forEach { $0.cancel() }
        return !running.isEmpty
    }

    func waitForDrain(timeout: TimeInterval) -> Bool {
        drain.wait(timeout: .now() + timeout) == .success
    }

    /// The last resort before storage a child may be writing into is removed.
    func killActiveRuns() {
        condition.lock()
        let running = Array(activeRuns.values)
        condition.unlock()
        running.forEach { $0.kill() }
    }

    private func checkSource() throws {
        guard let sourceIdentity else { return }
        guard SourceIdentity(of: source) == sourceIdentity else {
            condition.lock(); changedSource = true; condition.unlock()
            throw MaterializeError.sourceChanged
        }
    }

    // MARK: - Helpers

    static func restricted(_ plan: ArchiveTree.BatchPlan, to paths: Set<String>) -> ArchiveTree.BatchPlan {
        var owned = plan
        owned.leaves = plan.leaves.filter { paths.contains($0.path) }
        owned.packages = plan.packages.filter { paths.contains($0.path) }
        owned.selected = plan.selected.filter { paths.contains($0.path) }
        if owned.selected.isEmpty { owned.selection = nil }
        return owned
    }

    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer) != nil ? String(cString: buffer) : path
    }

    private static func readQuarantine(_ archive: URL) -> Data? {
        let attribute = "com.apple.quarantine"
        let length = getxattr(archive.path, attribute, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(archive.path, attribute, $0.baseAddress, length, 0, 0) }
        return read == length ? data : nil
    }

    /// Stamp an item and, for a package, everything inside it. Never follows a
    /// link: a link's own metadata is left alone.
    private static func stamp(_ quarantine: Data, on item: URL) -> Bool {
        func mark(_ url: URL) -> Bool {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return true }
            return quarantine.withUnsafeBytes {
                setxattr(url.path, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, XATTR_NOFOLLOW)
            } == 0
        }
        guard mark(item) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let walker = FileManager.default.enumerator(at: item, includingPropertiesForKeys: nil) else { return true }
        for case let url as URL in walker where !mark(url) { return false }
        return true
    }
}

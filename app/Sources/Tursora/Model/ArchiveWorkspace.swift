import Foundation

/// A pane cancels its own request without cancelling another pane's request
/// for the same ZIP. Cancellation suppresses even an already queued delivery.
final class ArchivePreparationSubscription {
    private let lock = NSLock()
    private var cancelled = false
    private var delivered = false
    private var cancellation: (() -> Void)?

    func cancel() {
        lock.lock()
        guard !cancelled, !delivered else { lock.unlock(); return }
        cancelled = true
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    fileprivate func onCancel(_ action: @escaping () -> Void) {
        lock.lock()
        let runNow = cancelled
        if !cancelled, !delivered { cancellation = action }
        lock.unlock()
        if runNow { action() }
    }

    fileprivate func deliver(_ result: Result<ArchiveBrowsingSession, Error>,
                             to completion: (Result<ArchiveBrowsingSession, Error>) -> Void) {
        lock.lock()
        guard !cancelled, !delivered else { lock.unlock(); return }
        delivered = true
        cancellation = nil
        lock.unlock()
        completion(result)
    }
}

/// What a request for an archive's bytes would cost, roughly.
struct ArchiveMaterializationEstimate {
    var bytes: Int64 = 0
    var seconds: Double = 0
    /// Past a second or 128 MiB a request earns a row in File Operations,
    /// with Cancel; anything smaller only shows the pane busy (D98).
    var warrantsProgressRow: Bool { seconds > 1 || bytes > 128 << 20 }
}

/// What a request for an archive's bytes brought.
struct ArchiveMaterializationResult {
    /// Each requested location now readable, as the physical URL to read it
    /// through, in the order requested.
    var urls: [URL] = []
    /// What could not be brought: a requested entry, or a member of a
    /// requested folder or package.
    var failures: [FileOperations.Failure] = []
}

/// When a ZIP folder's own files are extracted. Rows never depend on it: they
/// come from the table of contents either way (D97).
enum ArchiveMaterializationPolicy {
    /// While the folder is listed, as since Stage 1. A background prefetch
    /// replaces this (stage2 C5).
    case onListing
    /// Only when something asks for an entry's bytes. Lets the suite prove a
    /// listing needs no extraction at all.
    case never
}

/// Keeps read-only snapshots alive while navigation uses paths under the
/// original ZIP. The registry is safe to query from directory-loading queues.
final class ArchiveWorkspace {
    typealias Preparer = (URL, URL, @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) -> ArchivePreparationCancellation
    static let shared = ArchiveWorkspace()
    private let lock = NSLock()
    private var sessions: [URL: ArchiveBrowsingSession] = [:]
    private struct Waiter {
        let subscription: ArchivePreparationSubscription
        let completion: (Result<ArchiveBrowsingSession, Error>) -> Void
    }
    private final class Job {
        let id = UUID()
        let archive: URL
        var waiters: [UUID: Waiter] = [:]
        var cancellation: ArchivePreparationCancellation?
        var cancelled = false
        var finished = false
        init(archive: URL) { self.archive = archive }
    }
    private var pending: [URL: Job] = [:]
    private var inFlight: [UUID: Job] = [:]
    private var shutdownCompletions: [() -> Void] = []
    /// Sessions closed by `shutdownAll` that are still stopping their children.
    /// Quitting waits for these as well as for preparations (D96).
    private var pendingDrains = 0
    private let preparer: Preparer
    private var closed = false
    private var policy: ArchiveMaterializationPolicy
    /// Read on the listing queue, so it is guarded; the suite switches the
    /// shared workspace to `.never` while it proves rows need no bytes.
    var materializationPolicy: ArchiveMaterializationPolicy {
        get { lock.lock(); defer { lock.unlock() }; return policy }
        set { lock.lock(); policy = newValue; lock.unlock() }
    }

    init(materializationPolicy: ArchiveMaterializationPolicy = .onListing,
         preparer: @escaping Preparer = { source, logical, completion in
        ArchiveBrowsingSession.prepare(archive: source, logicalArchiveURL: logical, completion: completion)
    }) {
        policy = materializationPolicy
        self.preparer = preparer
    }

    @discardableResult
    func prepare(archive: URL, completion: @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) -> ArchivePreparationSubscription {
        let logical = URL(fileURLWithPath: logicalURL(for: archive).standardizedFileURL.path, isDirectory: false)
        let subscription = ArchivePreparationSubscription()
        let waiterID = UUID()
        let waiter = Waiter(subscription: subscription, completion: completion)
        lock.lock()
        if closed {
            lock.unlock()
            DispatchQueue.main.async { subscription.deliver(.failure(ArchiveBrowsingSession.SessionError.closed), to: completion) }
            return subscription
        }
        if let existing = sessions[logical], existing.isSourceChanged {
            // The archive was replaced after mount: discard that session off
            // the main thread and mount the archive again below.
            sessions[logical] = nil
            DispatchQueue.global(qos: .utility).async { existing.close() }
        }
        if let existing = sessions[logical], !existing.isClosed {
            lock.unlock()
            DispatchQueue.main.async { [self] in
                lock.lock(); let ended = closed; lock.unlock()
                subscription.deliver(ended ? .failure(ArchiveBrowsingSession.SessionError.closed) : .success(existing), to: completion)
            }
            return subscription
        }
        let existingJob = pending[logical]
        let job = existingJob ?? Job(archive: logical)
        job.waiters[waiterID] = waiter
        pending[logical] = job
        inFlight[job.id] = job
        lock.unlock()
        subscription.onCancel { [weak self, weak job] in
            guard let self, let job else { return }
            self.cancel(waiterID, in: job, archive: logical)
        }
        if existingJob != nil { return subscription }

        // A nested ZIP can itself live in an already prepared snapshot; it is
        // read only once its bytes are there, never extracted from here, which
        // is the main thread.
        let source: URL
        do {
            if record(for: logical) != nil {
                guard let published = publishedURL(for: logical) else {
                    throw ArchiveBrowsingSession.SessionError.unavailableItem
                }
                source = published
            } else {
                source = try physicalURL(for: logical)
            }
        } catch { finish(logical, job: job, result: .failure(error)); return subscription }
        let cancellation = preparer(source, logical) { [self, job] result in
            finish(logical, job: job, result: result)
        }
        lock.lock()
        job.cancellation = cancellation
        let shouldCancel = job.cancelled && !job.finished
        lock.unlock()
        if shouldCancel { cancellation.cancel() }
        return subscription
    }

    /// Includes cancelled workers until their child and private storage have
    /// finished cleanup, which makes cancellation observable without sleeps.
    func hasPendingPreparation(for archive: URL) -> Bool {
        let path = logicalURL(for: archive).standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return inFlight.values.contains { $0.archive.path == path }
    }

    private func cancel(_ waiter: UUID, in job: Job, archive: URL) {
        lock.lock()
        guard pending[archive] === job else { lock.unlock(); return }
        job.waiters[waiter] = nil
        guard job.waiters.isEmpty else { lock.unlock(); return }
        pending[archive] = nil
        job.cancelled = true
        let cancellation = job.cancellation
        lock.unlock()
        cancellation?.cancel()
    }

    private func finish(_ archive: URL, job: Job, result: Result<ArchiveBrowsingSession, Error>) {
        lock.lock()
        guard !job.finished else { lock.unlock(); return }
        job.finished = true
        lock.unlock()
        // Keep the subscriptions pending until the main-thread delivery. A
        // final cancellation after extraction but before this turn still owns
        // the new snapshot and must discard it instead of leaving it cached.
        DispatchQueue.main.async { [self] in settle(archive, job: job, result: result) }
    }

    private func settle(_ archive: URL, job: Job, result: Result<ArchiveBrowsingSession, Error>) {
        lock.lock()
        let discarded = closed || job.cancelled || pending[archive] !== job
        let waiters = discarded ? [] : Array(job.waiters.values)
        job.waiters.removeAll()
        if pending[archive] === job { pending[archive] = nil }
        if !discarded, case .success(let session) = result { sessions[archive] = session }
        lock.unlock()
        // A cancelled old job can finish after a same-URL retry. Its private
        // result must be cleaned without touching the new pending job/session.
        if discarded, case .success(let session) = result {
            session.close(onDrained: { [self] in complete(job) })
        } else { complete(job) }
        // Publish and deliver in the same main-thread turn, so a pane cannot
        // cancel between registration and receiving its prepared session.
        for waiter in waiters {
            lock.lock(); let ended = closed; lock.unlock()
            let delivered: Result<ArchiveBrowsingSession, Error> = ended
                ? .failure(ArchiveBrowsingSession.SessionError.closed) : result
            waiter.subscription.deliver(delivered, to: waiter.completion)
        }
    }

    private func complete(_ job: Job) {
        lock.lock()
        inFlight[job.id] = nil
        lock.unlock()
        fireShutdownCompletionsIfSettled()
    }

    /// Quitting may proceed once no preparation is running and every closed
    /// session has stopped its children and removed its storage.
    private func fireShutdownCompletionsIfSettled() {
        lock.lock()
        let settled = closed && inFlight.isEmpty && pendingDrains == 0
        let completions = settled ? shutdownCompletions : []
        if !completions.isEmpty { shutdownCompletions.removeAll() }
        lock.unlock()
        if !completions.isEmpty { DispatchQueue.main.async { completions.forEach { $0() } } }
    }

    private struct Record {
        let archive: URL
        let session: ArchiveBrowsingSession
        /// The lexical path inside this snapshot, before following member links.
        let physical: URL
    }

    private func record(for location: URL) -> Record? {
        guard location.isFileURL else { return nil }
        lock.lock()
        let retained = sessions.filter { !$0.value.isClosed }
            .sorted { $0.key.pathComponents.count > $1.key.pathComponents.count }
        lock.unlock()
        guard !retained.isEmpty else { return nil }
        let location = location.standardizedFileURL
        // Lexical ownership wins over a member link's eventual target. A link
        // from snapshot A into snapshot B must still pass A's containment check.
        for (archive, session) in retained {
            if ArchiveBrowsingSession.containsPath(root: archive, candidate: location) {
                return Record(archive: archive, session: session,
                              physical: Self.remap(location, from: archive, to: session.rootURL))
            }
            if ArchiveBrowsingSession.containsPath(root: session.rootURL, candidate: location) {
                return Record(archive: archive, session: session, physical: location)
            }
            if ArchiveBrowsingSession.containsPath(root: session.storageURL, candidate: location) {
                return Record(archive: archive, session: session,
                              physical: Self.remap(location, from: session.storageURL,
                                                   to: session.storageURL.resolvingSymlinksInPath()))
            }
        }
        // Resolve ancestors from the outside inward. Resolving only the final
        // URL loses ownership when alias/escape points outside the snapshot.
        // Once an ancestor enters private storage, preserve all remaining path
        // components and let validatedURL reject any subsequent escaping link.
        let archiveParents = retained.map { archive, session in
            (archive: archive, session: session,
             parent: archive.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL)
        }
        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in location.pathComponents.dropFirst() {
            ancestor.appendPathComponent(component)
            let resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
            for (archive, session) in retained {
                let storage = session.storageURL.resolvingSymlinksInPath().standardizedFileURL
                if ArchiveBrowsingSession.containsPath(root: session.rootURL, candidate: resolved)
                    || ArchiveBrowsingSession.containsPath(root: storage, candidate: resolved) {
                    return Record(archive: archive, session: session,
                                  physical: Self.remap(location, from: ancestor, to: resolved))
                }
            }
            // An existing ZIP can standardize /private/tmp to /tmp while its
            // virtual child cannot. Match aliases of its containing directory,
            // then keep the ZIP name and member components lexical. Resolving
            // the ZIP itself would wrongly claim ordinary symlinks to the file.
            let suffix = location.pathComponents.dropFirst(ancestor.pathComponents.count)
            for record in archiveParents where resolved.path == record.parent.path
                && suffix.first == record.archive.lastPathComponent {
                let physical = suffix.dropFirst().reduce(record.session.rootURL) {
                    $0.appendingPathComponent($1)
                }.standardizedFileURL
                return Record(archive: record.archive, session: record.session, physical: physical)
            }
        }
        return nil
    }

    func session(for location: URL) -> ArchiveBrowsingSession? { record(for: location)?.session }

    func containsArchiveLocation(_ location: URL) -> Bool { session(for: location) != nil }

    func logicalURL(for url: URL) -> URL {
        guard let record = record(for: url),
              ArchiveBrowsingSession.containsPath(root: record.session.rootURL, candidate: record.physical) else {
            return url
        }
        // Logical archive folders do not exist on disk. Drop the directory hint
        // so Up, aliases and typed paths share history and selection identity.
        let logical = Self.remap(record.physical, from: record.session.rootURL, to: record.archive)
        return URL(fileURLWithPath: logical.path, isDirectory: false)
    }

    /// The physical URL a location stands for, contained and validated, and
    /// without bringing any bytes: inside a mounted archive, where its bytes
    /// are or will be; anywhere else, the location itself.
    func physicalURL(for location: URL) throws -> URL {
        lock.lock()
        let ended = closed
        lock.unlock()
        guard !ended else { throw ArchiveBrowsingSession.SessionError.closed }
        if let record = record(for: location) { return try record.session.validatedURL(record.physical) }
        if let archive = archiveURL(containing: location),
           archive.standardizedFileURL != location.standardizedFileURL {
            throw ArchiveBrowsingSession.SessionError.unavailableItem
        }
        return location.standardizedFileURL
    }

    /// The session and entry a location inside a mounted archive stands for,
    /// every link along it followed. Nil anywhere else, and for a location
    /// that leads nowhere.
    func archiveEntry(for location: URL) -> (session: ArchiveBrowsingSession, path: String)? {
        guard let record = record(for: location), let physical = try? record.session.validatedURL(record.physical),
              let path = record.session.resolvedArchivePath(of: physical) else { return nil }
        return (record.session, path)
    }

    /// Whether a location is a folder that can be entered, from the table of
    /// contents alone. It never extracts, so the address bar and the tab bar
    /// can ask on every keystroke and every drag update.
    func isNavigableFolder(_ location: URL) -> Bool {
        guard let entry = archiveEntry(for: location) else { return false }
        guard let node = entry.session.tree.node(at: entry.path) else { return entry.path.isEmpty }
        return node.isDirectory && !node.isPackage && node.isExtractable
    }

    /// Where a location's bytes are when all of them are on disk already, and
    /// nil otherwise. Never extracts.
    func publishedURL(for location: URL) -> URL? {
        guard let record = record(for: location), let physical = try? record.session.validatedURL(record.physical),
              let path = record.session.resolvedArchivePath(of: physical),
              record.session.isPublished(path) else { return nil }
        return physical
    }

    /// Roughly what bringing these locations in would cost, from the measured
    /// model of the archive tool (stage2 plan §2): a fixed cost per run that
    /// grows with the archive's entry count, plus the bytes written.
    func estimate(for locations: [URL]) -> ArchiveMaterializationEstimate {
        var estimate = ArchiveMaterializationEstimate()
        for (session, paths) in grouped(locations.compactMap(archiveEntry(for:))) {
            let settled = session.materializer.settledPaths
            let plan = paths.contains("") ? session.tree.subtreePlan(for: "", skipping: settled)
                : session.tree.batchPlan(for: paths, skipping: settled)
            let runs = [!plan.leaves.isEmpty, !plan.packages.isEmpty, plan.selection != nil].filter { $0 }.count
            estimate.bytes += plan.bytes
            estimate.seconds += Double(runs) * (0.01 + 3.3e-6 * Double(session.tree.count)) + Double(plan.bytes) / 450e6
        }
        return estimate
    }

    /// Brings every location's bytes to disk — a file, a package whole, a
    /// folder with everything below it — in one batch per archive, through
    /// each session's materializer. Blocks, so it never runs on the main
    /// thread. Returns each location's physical URL where it is now readable,
    /// and whatever could not be brought, down to a member of a folder.
    func materializeBlocking(_ locations: [URL],
                             cancellation: ArchivePreparationCancellation? = nil) throws -> ArchiveMaterializationResult {
        struct Request { let physical: URL; let session: ArchiveBrowsingSession?; let path: String? }
        var requests: [Request] = []
        for location in locations {
            let physical = try physicalURL(for: location)
            if let record = record(for: location) {
                requests.append(Request(physical: physical, session: record.session,
                                        path: record.session.resolvedArchivePath(of: physical)))
            } else {
                requests.append(Request(physical: physical, session: nil, path: nil))
            }
        }
        let entries = requests.compactMap { request in request.session.flatMap { session in request.path.map { (session, $0) } } }
        for (session, paths) in grouped(entries) {
            try cancellation?.checkCancellation()
            guard !session.isClosed else { throw ArchiveBrowsingSession.SessionError.closed }
            let settled = session.materializer.settledPaths
            let plan = paths.contains("") ? session.tree.subtreePlan(for: "", skipping: settled)
                : session.tree.batchPlan(for: paths, skipping: settled)
            try session.materializer.materialize(plan, cancellation: cancellation)
        }

        var result = ArchiveMaterializationResult()
        var failedMembers: [URL] = []
        func fail(_ url: URL, _ reason: String, sticky: Bool = false) {
            result.failures.append(.init(url: url, error: ArchiveBrowsingSession.SessionError.notExtracted(reason)))
            if sticky { failedMembers.append(url) }
        }
        for request in requests {
            guard let session = request.session else { result.urls.append(request.physical); continue }
            guard let path = request.path else {
                result.failures.append(.init(url: request.physical, error: ArchiveBrowsingSession.SessionError.outsideArchive))
                continue
            }
            let tree = session.tree, materializer = session.materializer
            let node = tree.node(at: path)
            if let node, !node.isDirectory || node.isPackage {
                switch materializer.state(of: node.path) {
                case .published: result.urls.append(request.physical)
                case .failed(let reason): fail(request.physical, reason, sticky: true)
                case .absent, .inFlight:
                    if let reason = node.inertReason { fail(request.physical, reason.explanation) }
                    else { result.failures.append(.init(url: request.physical, error: ArchiveBrowsingSession.SessionError.unavailableItem)) }
                }
                guard node.isPackage else { continue }
            } else {
                result.urls.append(request.physical)
            }
            // What a copy of this folder or package goes without.
            let prefix = path.isEmpty ? 0 : path.count + 1
            for member in tree.descendants(of: path) {
                let url = request.physical.appendingPathComponent(String(member.path.dropFirst(prefix)))
                if let reason = member.inertReason { fail(url, reason.explanation) }
                else if case .failed(let reason) = materializer.state(of: member.path) { fail(url, reason, sticky: true) }
            }
        }
        // A failure is sticky and turns its row unavailable; tell the panes
        // showing its folder so they list it again (M54).
        if !failedMembers.isEmpty {
            let folders = failedMembers.map { logicalURL(for: $0).deletingLastPathComponent() }
            DispatchQueue.main.async { DirectoryChanges.post(folders) }
        }
        return result
    }

    /// The same, off the main thread, delivering on the main queue. Cancel
    /// through the returned token: the running child is stopped and nothing
    /// half-written is published.
    @discardableResult
    func materialize(_ locations: [URL],
                     completion: @escaping (Result<ArchiveMaterializationResult, Error>) -> Void) -> ArchivePreparationCancellation {
        let cancellation = ArchivePreparationCancellation()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try materializeBlocking(locations, cancellation: cancellation) }
            DispatchQueue.main.async { completion(result) }
        }
        return cancellation
    }

    /// Forget the extraction failures in and below a folder, so the next
    /// request tries them again. For Reload.
    func forgetFailures(in location: URL) {
        guard let entry = archiveEntry(for: location) else { return }
        entry.session.materializer.forgetFailures(under: entry.path)
    }

    /// Requests grouped per session, in first-seen order.
    private func grouped(_ entries: [(session: ArchiveBrowsingSession, path: String)]) -> [(ArchiveBrowsingSession, [String])] {
        var order: [ObjectIdentifier] = []
        var groups: [ObjectIdentifier: (ArchiveBrowsingSession, [String])] = [:]
        for (session, path) in entries {
            let id = ObjectIdentifier(session)
            if groups[id] == nil { order.append(id); groups[id] = (session, []) }
            groups[id]!.1.append(path)
        }
        return order.map { groups[$0]! }
    }

    /// A directory called something.zip remains an ordinary directory. Once
    /// registered, the snapshot remains usable even if its source was moved.
    func archiveURL(containing location: URL) -> URL? {
        if let record = record(for: location) { return record.archive }
        guard location.isFileURL else { return nil }
        var candidate = location.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "zip" {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory), !directory.boolValue {
                    // Walking up a URL marks each parent as a directory. ZIP
                    // roots are files: discard that trailing-slash hint before
                    // returning their identity or using them as registry keys.
                    return URL(fileURLWithPath: candidate.path, isDirectory: false)
                }
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func remap(_ url: URL, from root: URL, to destination: URL) -> URL {
        // The matched ancestor and candidate use the same lexical spelling.
        // Standardizing them independently is unsafe: Foundation can shorten
        // /private/var for an existing ancestor but not for a dangling member,
        // changing the prefix component count and leaking its temporary path.
        url.pathComponents.dropFirst(root.pathComponents.count)
            .reduce(destination) { $0.appendingPathComponent($1) }.standardizedFileURL
    }

    /// Called at app exit. Late preparation callbacks discard their snapshots;
    /// test-owned registries can also close without affecting the shared one.
    func shutdownAll(completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread, "Archive workspace shutdown must run on the main thread")
        lock.lock()
        closed = true
        let retained = Array(sessions.values)
        sessions.removeAll()
        let jobs = Array(inFlight.values)
        jobs.forEach { $0.cancelled = true }
        let cancellations = jobs.compactMap(\.cancellation)
        let waiters = pending.values.flatMap { $0.waiters.values }
        pending.values.forEach { $0.waiters.removeAll() }
        pending.removeAll()
        if let completion { shutdownCompletions.append(completion) }
        pendingDrains += retained.count
        lock.unlock()
        cancellations.forEach { $0.cancel() }
        if self === Self.shared { ArchiveBrowsingSession.shutdownPreparingSessions() }
        // Waiters hear that the workspace closed before any quit completion
        // runs, as they always did; queued first, so they are delivered first.
        DispatchQueue.main.async {
            waiters.forEach { $0.subscription.deliver(.failure(ArchiveBrowsingSession.SessionError.closed), to: $0.completion) }
        }
        // Each session stops its own children before its storage goes; a
        // session with nothing in flight reports drained at once.
        for session in retained {
            session.close(onDrained: { [self] in
                lock.lock(); pendingDrains -= 1; lock.unlock()
                fireShutdownCompletionsIfSettled()
            })
        }
        fireShutdownCompletionsIfSettled()
    }
}

final class ArchiveFileProvider: FileProvider {
    let base: FileProvider
    let workspace: ArchiveWorkspace
    init(base: FileProvider, workspace: ArchiveWorkspace = .shared) {
        self.base = base
        self.workspace = workspace
    }
    var homeURL: URL { base.homeURL }
    func displayName(for url: URL) -> String {
        workspace.archiveURL(containing: url) == nil ? base.displayName(for: url) : workspace.logicalURL(for: url).lastPathComponent
    }
    func listDirectory(_ url: URL) throws -> [FileItem] {
        guard let session = workspace.session(for: url) else { return try base.listDirectory(url) }
        let physical = try workspace.physicalURL(for: url)
        // Each row's logical URL is the folder's plus its name: resolving
        // every row's physical URL back would touch the disk once per row.
        let logical = workspace.logicalURL(for: physical)
        // `entries(in:)` still brings the folder's own files in first. It runs
        // on the listing queue, never the main thread (DirectoryModel.load).
        return try session.entries(in: physical, materializing: workspace.materializationPolicy == .onListing).map { entry in
            FileItem(archiveEntry: entry, logicalURL: logical.appendingPathComponent(entry.name, isDirectory: false),
                     session: session)
        }
    }
}

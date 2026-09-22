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
    private let preparer: Preparer
    private var closed = false

    init(preparer: @escaping Preparer = { source, logical, completion in
        ArchiveBrowsingSession.prepare(archive: source, logicalArchiveURL: logical, completion: completion)
    }) { self.preparer = preparer }

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

        // A nested ZIP can itself live in an already prepared snapshot.
        let source: URL
        do { source = try readableURL(for: logical) }
        catch { finish(logical, job: job, result: .failure(error)); return subscription }
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
            DispatchQueue.global(qos: .utility).async { [self] in
                session.close()
                complete(job)
            }
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
        let completions = closed && inFlight.isEmpty ? shutdownCompletions : []
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

    func readableURL(for location: URL) throws -> URL {
        lock.lock()
        let ended = closed
        lock.unlock()
        guard !ended else { throw ArchiveBrowsingSession.SessionError.closed }
        if let record = record(for: location) {
            let safe = try record.session.validatedURL(record.physical)
            if !FileManager.default.fileExists(atPath: safe.path) {
                // A lazily mounted session has only the skeleton and the
                // symbolic links until a directory is listed, so something
                // addressing a file straight by URL — a restored session, a
                // typed path, a nested archive — has to bring it in first.
                // Tried only on a miss: a directory is always in the skeleton,
                // so listing one never drags in its siblings.
                try record.session.materializeDirectory(containing: safe.deletingLastPathComponent())
                guard FileManager.default.fileExists(atPath: safe.path) else {
                    throw ArchiveBrowsingSession.SessionError.unavailableItem
                }
            }
            return safe
        }
        if let archive = archiveURL(containing: location),
           archive.standardizedFileURL != location.standardizedFileURL {
            throw ArchiveBrowsingSession.SessionError.unavailableItem
        }
        return location.standardizedFileURL
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
        let completed = inFlight.isEmpty ? shutdownCompletions : []
        if !completed.isEmpty { shutdownCompletions.removeAll() }
        lock.unlock()
        cancellations.forEach { $0.cancel() }
        if self === Self.shared { ArchiveBrowsingSession.shutdownPreparingSessions() }
        retained.forEach { $0.close() }
        DispatchQueue.main.async {
            waiters.forEach { $0.subscription.deliver(.failure(ArchiveBrowsingSession.SessionError.closed), to: $0.completion) }
            completed.forEach { $0() }
        }
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
        let physical = try workspace.readableURL(for: url)
        // `entries(in:)` materializes the directory itself. It runs on the
        // listing queue, never the main thread (DirectoryModel.load).
        return try session.entries(in: physical).map { entry in
            FileItem(archiveEntry: entry, logicalURL: workspace.logicalURL(for: entry.url), session: session)
        }
    }
}

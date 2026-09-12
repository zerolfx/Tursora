import Foundation

/// Keeps read-only snapshots alive while navigation uses paths under the
/// original ZIP. The registry is safe to query from directory-loading queues.
final class ArchiveWorkspace {
    static let shared = ArchiveWorkspace()
    private let lock = NSLock()
    private var sessions: [URL: ArchiveBrowsingSession] = [:]
    private var pending: [URL: [(Result<ArchiveBrowsingSession, Error>) -> Void]] = [:]
    private var closed = false

    func prepare(archive: URL, completion: @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) {
        let logical = URL(fileURLWithPath: logicalURL(for: archive).standardizedFileURL.path, isDirectory: false)
        lock.lock()
        if closed {
            lock.unlock()
            DispatchQueue.main.async { completion(.failure(ArchiveBrowsingSession.SessionError.closed)) }
            return
        }
        if let existing = sessions[logical], !existing.isClosed {
            lock.unlock()
            DispatchQueue.main.async { completion(.success(existing)) }
            return
        }
        if pending[logical] != nil {
            pending[logical]!.append(completion)
            lock.unlock()
            return
        }
        pending[logical] = [completion]
        lock.unlock()

        // A nested ZIP can itself live in an already prepared snapshot.
        let source: URL
        do { source = try readableURL(for: logical) }
        catch { finish(logical, result: .failure(error)); return }
        ArchiveBrowsingSession.prepare(archive: source, logicalArchiveURL: logical) { [self] result in
            finish(logical, result: result)
        }
    }

    private func finish(_ archive: URL, result: Result<ArchiveBrowsingSession, Error>) {
        lock.lock()
        let callbacks = pending.removeValue(forKey: archive) ?? []
        let discarded = closed
        if !discarded, case .success(let session) = result { sessions[archive] = session }
        lock.unlock()
        if discarded, case .success(let session) = result { session.close() }
        let delivered: Result<ArchiveBrowsingSession, Error> = discarded
            ? .failure(ArchiveBrowsingSession.SessionError.closed) : result
        DispatchQueue.main.async { callbacks.forEach { $0(delivered) } }
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
            guard FileManager.default.fileExists(atPath: safe.path) else {
                throw ArchiveBrowsingSession.SessionError.unavailableItem
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
    func shutdownAll() {
        lock.lock()
        closed = true
        let retained = Array(sessions.values)
        sessions.removeAll()
        let callbacks = pending.values.flatMap { $0 }
        pending.removeAll()
        lock.unlock()
        if self === Self.shared { ArchiveBrowsingSession.shutdownPreparingSessions() }
        retained.forEach { $0.close() }
        DispatchQueue.main.async { callbacks.forEach { $0(.failure(ArchiveBrowsingSession.SessionError.closed)) } }
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
        return try session.entries(in: physical).map { entry in
            FileItem(archiveEntry: entry, logicalURL: workspace.logicalURL(for: entry.url), session: session)
        }
    }
}

import Foundation

/// Thumbnails for ZIP entries that are not extracted yet (D100).
///
/// Every cell on screen asks for its thumbnail as it is drawn, so a page of
/// icons is dozens of requests in one run-loop pass. They are gathered for
/// that pass and sent to the archive tool as one transient extraction per
/// archive: 40 visible cells cost one run, not 40. A request withdrawn in the
/// same pass — a cell scrolled away, a view reloaded — is never extracted.
/// The bytes land in a directory beside the archive's root, are read for the
/// thumbnail and removed, so scrolling through a folder of photos does not
/// leave the folder extracted.
final class ArchiveThumbnailQueue {
    static let shared = ArchiveThumbnailQueue()
    /// Per run: `-T` matching grows with names × entries, and this keeps a
    /// run's transient bytes bounded (stage2 plan §2).
    static let maximumMembersPerRun = 128
    static let maximumBytesPerRun: Int64 = 128 << 20

    struct Request {
        let key: String
        let session: ArchiveBrowsingSession
        /// The entry's tree path.
        let path: String
        let bytes: Int64
        /// Makes the thumbnail from the extracted file, then calls `done`, after
        /// which the file is removed. Runs off the main thread.
        let generate: (_ file: URL, _ done: @escaping () -> Void) -> Void
        /// No file to read. True when the archive tool named the member in an
        /// error — damaged, say — so there will never be a thumbnail for it.
        let failed: (_ attributed: Bool) -> Void
    }

    private var waiting: [Request] = []
    private var flushScheduled = false
    /// One run at a time across the app: thumbnails never queue behind each
    /// other's archive tool, and at most one run of transient bytes is on disk.
    private let worker = DispatchQueue(label: "org.tursora.archive-thumbnails", qos: .utility)

    /// Asks for a thumbnail's bytes; sent at the end of this run-loop pass.
    func request(_ request: Request) {
        dispatchPrecondition(condition: .onQueue(.main))
        waiting.append(request)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [self] in flush() }
    }

    /// Withdraws a request not yet sent. False once its run has started: the
    /// thumbnail is then made anyway and kept, since the next scroll back
    /// usually wants it.
    func withdraw(key: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = waiting.firstIndex(where: { $0.key == key }) else { return false }
        waiting.remove(at: index)
        return true
    }

    private func flush() {
        flushScheduled = false
        let batch = waiting
        waiting.removeAll()
        var order: [ObjectIdentifier] = []
        var bySession: [ObjectIdentifier: [Request]] = [:]
        for request in batch {
            let id = ObjectIdentifier(request.session)
            if bySession[id] == nil { order.append(id) }
            bySession[id, default: []].append(request)
        }
        for id in order {
            var run: [Request] = []
            var bytes: Int64 = 0
            for request in bySession[id] ?? [] {
                if !run.isEmpty, run.count >= Self.maximumMembersPerRun || bytes + request.bytes > Self.maximumBytesPerRun {
                    let full = run
                    worker.async { Self.perform(full) }
                    run = []
                    bytes = 0
                }
                run.append(request)
                bytes += request.bytes
            }
            if !run.isEmpty { worker.async { Self.perform(run) } }
        }
    }

    private static func perform(_ run: [Request]) {
        if SmokeTest.isRequested { shared.record(run.map(\.key)) }
        let session = run[0].session
        let tree = session.tree
        let members = run.compactMap { tree.node(at: $0.path) }.map(tree.spelling(of:))
        let transient: ArchiveMaterializer.TransientExtraction
        do { transient = try session.materializer.extractTransient(members) }
        catch { run.forEach { $0.failed(false) }; return }
        defer { try? FileManager.default.removeItem(at: transient.directory) }
        let generated = DispatchGroup()
        for request in run {
            guard let node = tree.node(at: request.path), transient.extracted.contains(node.path) else {
                request.failed(tree.node(at: request.path).map { transient.failed[$0.path] != nil } ?? false)
                continue
            }
            generated.enter()
            request.generate(transient.directory.appendingPathComponent(node.path)) { generated.leave() }
        }
        // The files have to outlive the thumbnailers reading them.
        _ = generated.wait(timeout: .now() + 30)
    }

    var isIdleForTesting: Bool { waiting.isEmpty && !flushScheduled }
    private let recordLock = NSLock()
    private var recordedRuns: [[String]] = []
    private func record(_ keys: [String]) { recordLock.lock(); recordedRuns.append(keys); recordLock.unlock() }
    /// The keys of every run so far, for the suite's diagnostics.
    var runsForTesting: [[String]] { recordLock.lock(); defer { recordLock.unlock() }; return recordedRuns }
}

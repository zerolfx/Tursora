import Foundation

/// A filename search always walks the filesystem, including unindexed folders.
/// A content search goes to the system index or reads the files itself,
/// whichever the request asks for (D85).
final class LocalSearchBackend: SearchBackend {
    static let maximumResults = 50_000
    /// A content scan is bounded by files read, not by matches: the result
    /// cap never fires for a needle that is not there, and a user who typed
    /// a rare word should not silently start reading an entire volume.
    static let maximumScannedFiles = 20_000

    func start(_ request: SearchRequest, event: @escaping (SearchEvent) -> Void) -> SearchCancellable {
        if request.usesSpotlight {
            let task = SpotlightSearchTask(request: request, event: event)
            task.start()
            return task
        }
        let cancellation = SearchCancellationToken()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.walk(request, cancellation: cancellation, event: event)
        }
        return cancellation
    }

    private static func walk(_ request: SearchRequest, cancellation: SearchCancellationToken,
                             event: @escaping (SearchEvent) -> Void) {
        guard !cancellation.isCancelled else { return }
        let root: URL
        do { root = try SearchRoot.validate(request) }
        catch { if !cancellation.isCancelled { event(.failed(error.localizedDescription)) }; return }
        var skipped = 0
        var firstError: String?
        let manager = FileManager()
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: FileItem.resourceKeys,
                                                 options: [.skipsPackageDescendants], errorHandler: { _, error in
            skipped += 1
            if firstError == nil { firstError = error.localizedDescription }
            return !cancellation.isCancelled
        }) else {
            if !cancellation.isCancelled { event(.failed("The search folder could not be read.")) }
            return
        }
        var batch: [FileItem] = []
        var count = 0
        var limited = false
        var lastBatch = Date()
        // A content scan reads bytes, so it needs bounds a metadata walk does
        // not: the result cap counts matches and cannot stop a rare needle
        // from walking a whole volume.
        let needle = request.trimmedContent
        let scanning = request.scansContent
        var tally = ContentScanner.Tally()
        var examined = 0
        var examinedLimit = false
        while !cancellation.isCancelled, let url = enumerator.nextObject() as? URL {
            autoreleasepool {
                let parent = url.deletingLastPathComponent().standardizedFileURL
                guard parent.resolvingSymlinksInPath().path == parent.path else { return }
                guard manager.fileExists(atPath: url.path), let item = FileItem(url: url) else { skipped += 1; return }
                // The URL enumerator never follows symlinks, and its options
                // exclude package descendants. Do not call skipDescendants()
                // on a link leaf: Darwin defers that skip to the next directory,
                // silently hiding an unrelated sibling's children.
                guard request.matchesMetadata(item) else { return }
                guard scanning else { batch.append(item); count += 1; return }
                // Folders hold no text of their own, and a package is a
                // directory: opening one as a file fails and would be
                // reported to the user as an unreadable item.
                guard !item.isNavigable, !item.isDirectory else { return }
                examined += 1
                let outcome = ContentScanner.scanFile(at: item.contentURL, for: needle)
                tally.record(outcome)
                switch outcome {
                case .match, .truncated(matched: true):
                    batch.append(item); count += 1
                default: break
                }
            }
            if batch.count >= 128 || (!batch.isEmpty && Date().timeIntervalSince(lastBatch) >= 0.15) {
                guard !cancellation.isCancelled else { return }
                event(.batch(batch))
                batch.removeAll(keepingCapacity: true)
                lastBatch = Date()
            }
            if count >= maximumResults { limited = true; break }
            if scanning, examined >= maximumScannedFiles { examinedLimit = true; break }
        }
        guard !cancellation.isCancelled else { return }
        if !batch.isEmpty { event(.batch(batch)) }
        var message: String
        if limited {
            message = "Showing the first \(maximumResults) results. Narrow the conditions to search further."
        } else if examinedLimit {
            message = "Stopped after reading \(maximumScannedFiles) files with \(count) result\(count == 1 ? "" : "s"). Narrow the folder or add a name condition."
        } else if scanning {
            message = "Scanned \(examined) file\(examined == 1 ? "" : "s"): \(count) result\(count == 1 ? "" : "s")."
        } else {
            message = "Recursive search complete: \(count) result\(count == 1 ? "" : "s")."
        }
        if scanning, !tally.summary.isEmpty { message += " " + tally.summary }
        if skipped > 0 {
            message += " \(skipped) unreadable item\(skipped == 1 ? "" : "s") skipped."
            if let firstError { message += " " + firstError }
        }
        message += " Packages, linked folders and ZIP contents are not searched."
        event(.finished(message))
    }
}

/// Cancellation is checked between filesystem calls; an OS read already in
/// flight cannot be interrupted, but it can never publish after cancellation.
private final class SearchCancellationToken: SearchCancellable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private enum SearchRoot {
    static func validate(_ request: SearchRequest) throws -> URL {
        if let message = request.validationError { throw Failure(message: message) }
        let root = request.effectiveRootURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values.isDirectory == true, values.isPackage != true else {
            throw Failure(message: "Search requires an ordinary folder. ZIP and package contents are not supported.")
        }
        guard FileManager.default.isReadableFile(atPath: root.path) else {
            throw Failure(message: "The search folder is not readable. Check its access permissions.")
        }
        return root
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// All NSMetadataQuery operations run on the main run loop as required by the
/// native API. Result metadata is copied in small turns; disk stat and matching
/// run on a serial background queue, which preserves batch/finish ordering.
private final class SpotlightSearchTask: SearchCancellable {
    private let request: SearchRequest
    private let event: (SearchEvent) -> Void
    private let cancellation = SearchCancellationToken()
    private let processing = DispatchQueue(label: "com.tursora.search.spotlight-results", qos: .userInitiated)
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var timeout: DispatchWorkItem?
    private var root: URL?
    private var didGather = false
    // Only the processing queue touches these counters.
    private var matchedCount = 0
    private var skippedCount = 0
    private var allowedParents: [URL: Bool] = [:]

    init(request: SearchRequest, event: @escaping (SearchEvent) -> Void) {
        self.request = request
        self.event = event
    }

    deinit {
        cancellation.cancel()
        timeout?.cancel()
        let query = query
        let observer = observer
        let cleanup = {
            query?.stop()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        if Thread.isMainThread { cleanup() } else { DispatchQueue.main.async(execute: cleanup) }
    }

    func start() {
        processing.async { [self] in
            guard !cancellation.isCancelled else { return }
            do {
                let root = try SearchRoot.validate(request)
                DispatchQueue.main.async { [self] in beginQuery(root: root) }
            } catch {
                if !cancellation.isCancelled { event(.failed(error.localizedDescription)) }
            }
        }
    }

    func cancel() {
        cancellation.cancel()
        if Thread.isMainThread { cleanUpQuery() }
        else { DispatchQueue.main.async { [weak self] in self?.cleanUpQuery() } }
    }

    private func beginQuery(root: URL) {
        guard !cancellation.isCancelled else { return }
        self.root = root
        let query = NSMetadataQuery()
        self.query = query
        query.searchScopes = [root]
        query.predicate = request.metadataPredicate
        query.notificationBatchingInterval = 0.2
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                           object: query, queue: .main) { [weak self] _ in
            self?.gathered()
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.didGather, !self.cancellation.isCancelled else { return }
            self.cleanUpQuery()
            self.event(.failed("Spotlight did not finish within 30 seconds. Try again or search by name. " + SearchRequest.contentLimitMessage))
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        if !query.start() {
            cleanUpQuery()
            event(.failed("Spotlight could not start this search. " + SearchRequest.contentLimitMessage))
        }
    }

    private func gathered() {
        guard !didGather, !cancellation.isCancelled, let query else { return }
        didGather = true
        timeout?.cancel()
        timeout = nil
        // Static query: stop before reading; results remain available until the
        // query is released. Do not use `results`, whose proxy has side effects.
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        copyPaths(startingAt: 0, total: min(query.resultCount, LocalSearchBackend.maximumResults),
                  limited: query.resultCount > LocalSearchBackend.maximumResults)
    }

    private func copyPaths(startingAt start: Int, total: Int, limited: Bool) {
        guard !cancellation.isCancelled, let query, let root else { return }
        let end = min(start + 128, total)
        var paths: [String] = []
        for index in start..<end {
            if let path = query.value(ofAttribute: "kMDItemPath", forResultAt: index) as? String { paths.append(path) }
        }
        processing.async { [self, paths] in
            guard !cancellation.isCancelled else { return }
            var items: [FileItem] = []
            for path in paths {
                guard !cancellation.isCancelled else { return }
                autoreleasepool {
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    // Defend against stale/out-of-scope index entries. Preserve
                    // the result's URL rather than reconstructing a basename.
                    guard url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { return }
                    guard isAllowedParent(of: url, root: root) else { return }
                    guard FileManager.default.fileExists(atPath: url.path), let item = FileItem(url: url) else {
                        skippedCount += 1
                        return
                    }
                    guard request.matchesMetadata(item) else { return }
                    items.append(item)
                    matchedCount += 1
                }
            }
            if !items.isEmpty, !cancellation.isCancelled { event(.batch(items)) }
            if end == total, !cancellation.isCancelled {
                var message = "Spotlight search complete: \(matchedCount) result\(matchedCount == 1 ? "" : "s"). "
                if limited { message += "Only the first \(LocalSearchBackend.maximumResults) indexed matches were checked; narrow the conditions. " }
                if skippedCount > 0 { message += "\(skippedCount) unavailable indexed items skipped. " }
                message += SearchRequest.contentLimitMessage
                event(.finished(message))
            }
        }
        if end < total {
            DispatchQueue.main.async { [weak self] in self?.copyPaths(startingAt: end, total: total, limited: limited) }
        } else {
            cleanUpQuery()
        }
    }

    /// Spotlight may return indexed paths inside packages or linked folders.
    /// Apply the same traversal boundary as filename search before publishing.
    /// This cache is query-local and confined to the serial processing queue.
    private func isAllowedParent(of url: URL, root: URL) -> Bool {
        var parent = url.deletingLastPathComponent().standardizedFileURL
        // Recheck links for every item even when package decisions are cached;
        // a directory can be replaced with a symlink while a query is running.
        guard parent.resolvingSymlinksInPath().path == parent.path else { return false }
        var checked: [URL] = []
        var allowed = true
        while parent.path != root.path {
            if let cached = allowedParents[parent] { allowed = cached; break }
            guard parent.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { allowed = false; break }
            checked.append(parent)
            guard let values = try? parent.resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey, .isDirectoryKey]),
                  values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else {
                allowed = false
                break
            }
            parent = parent.deletingLastPathComponent().standardizedFileURL
        }
        for parent in checked { allowedParents[parent] = allowed }
        return allowed
    }

    private func cleanUpQuery() {
        timeout?.cancel()
        timeout = nil
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

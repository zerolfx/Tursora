import Foundation

/// Folder item counts and, when "Calculate all sizes" is on, recursive byte
/// sizes for the folders one `DirectoryModel` is showing.
///
/// All state lives on the main thread (the model's thread); only the two
/// filesystem walks run on a serial background queue. Every result carries the
/// generation and the cancellation token it was started with, so navigating
/// away drops in-flight work instead of delivering it into another directory.
///
/// Results are cached by (path, modification date): a folder whose own listing
/// changed gets a new key and recomputes by itself, while a change *inside* a
/// subtree — which does not touch an ancestor's modification date — is dropped
/// explicitly when `DirectoryChanges` reports it.
final class FolderSizes {

    /// What is known about one folder. Either half may still be missing:
    /// the count arrives first, the recursive size only when asked for.
    struct Metrics: Equatable {
        var itemCount: Int?
        var byteSize: Int64?
    }

    private struct CacheKey: Hashable {
        let path: String
        let modified: Date?
    }

    private struct Request {
        let key: CacheKey
        let contentURL: URL
        let wantsCount: Bool
        let wantsSize: Bool
    }

    /// One recursive walk stops here rather than measuring an unbounded tree;
    /// the folder then keeps its item count and reports no size.
    static let entryLimit = 500_000
    /// Cached folders kept before the whole cache is dropped. Browsing is
    /// local and repetitive, so a plain cap beats per-entry bookkeeping.
    static let cacheLimit = 4096

    /// Finder's wording for a folder's contents (`I_ITEMS_V2` "^0 item" and
    /// `I_ITEMS_V1` / `I_ITEMS_V3` "^0 items" in Finder's string table).
    static func itemCountText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// The same formatter files use, so a folder's size reads like a file's.
    static func byteSizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Cancellation shared with the worker; checked inside the recursive walk
    /// so a long enumeration stops shortly after the user navigates away.
    private final class Token {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    /// Fired on the main queue, coalesced, after new values land.
    var onUpdate: (() -> Void)?

    /// "Calculate all sizes" — Finder's own wording (ViewOptionsWindow.nib).
    /// Off by default; turning it on re-asks for the folders last listed.
    var calculatesAllSizes = false {
        didSet {
            guard calculatesAllSizes != oldValue else { return }
            rerequest()
            // What the Size column shows and what a Size sort compares both
            // change immediately, even before any new value arrives.
            scheduleNotify()
        }
    }

    /// False where a recursive walk would be meaningless or expensive for what
    /// the pane shows: an extracted ZIP listing. Search results are refused by
    /// `request` itself, and archive entries item by item.
    var allowsRecursiveSizes = true {
        didSet {
            guard allowsRecursiveSizes != oldValue else { return }
            rerequest()
        }

    }

    private var cache: [CacheKey: Metrics] = [:]
    private var inFlight: [CacheKey: Int] = [:]
    private var generation = 0
    private var token = Token()
    private var notifyScheduled = false
    private var lastItems: [FileItem] = []
    private var lastAllowsRecursiveSizes = true
    private var observer: NSObjectProtocol?
    private let queue = DispatchQueue(label: "com.tursora.folder-sizes", qos: .utility)

    init() {
        // A file operation anywhere under a measured folder changes its size
        // without changing its modification date, so the cache key alone
        // cannot notice it.
        observer = NotificationCenter.default.addObserver(
            forName: .tursoraDirectoriesChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let dirs = note.userInfo?["directories"] as? [URL] else { return }
            self?.invalidate(dirs)
        }
    }

    deinit {
        token.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Reading

    func metrics(for item: FileItem) -> Metrics? {
        guard item.isNavigable else { return nil }
        return cache[key(for: item)]
    }

    /// The Size column's text. Files keep their own formatting; a folder shows
    /// its item count, or its recursive size once one has been calculated.
    func displaySize(for item: FileItem) -> String {
        guard item.isNavigable else { return item.displaySize }
        let metrics = self.metrics(for: item)
        if calculatesAllSizes, let bytes = metrics?.byteSize { return Self.byteSizeText(bytes) }
        if let count = metrics?.itemCount { return Self.itemCountText(count) }
        return "--"
    }

    /// What sorting by Size compares for a folder: its recursive size when one
    /// is being calculated and known, else its item count, else nothing yet.
    func sortValue(for item: FileItem) -> Int64? {
        guard item.isNavigable else { return item.size }
        guard let metrics = self.metrics(for: item) else { return nil }
        if calculatesAllSizes, let bytes = metrics.byteSize { return bytes }
        return metrics.itemCount.map(Int64.init)
    }

    // MARK: - Scheduling

    /// Ask for the folders a listing is showing. Idempotent: cached folders and
    /// folders already being measured are skipped, so every re-sort can call it.
    func request(_ items: [FileItem], allowsRecursiveSizes recursive: Bool) {
        lastItems = items
        lastAllowsRecursiveSizes = recursive
        let wantsSize = calculatesAllSizes && recursive && allowsRecursiveSizes
        var seeded = false
        for item in items where item.isNavigable {
            // A lazily mounted archive folder is counted from its tree, never
            // from disk: until it is entered it holds only its skeleton. It is
            // never walked for a size either, so nothing needs scheduling.
            if let count = item.archiveChildCount {
                let key = self.key(for: item)
                if cache[key]?.itemCount != count {
                    cache[key, default: Metrics()].itemCount = count
                    seeded = true
                }
                continue
            }
            // An archive folder that could not be counted from its tree is not
            // counted from disk either, where it is only a skeleton.
            if item.isArchiveEntry { continue }
            let itemWantsSize = wantsSize
            guard let contentURL = item.publishedContentURL else { continue }
            let key = self.key(for: item)
            let cached = cache[key]
            let wantsCount = cached?.itemCount == nil
            let needsSize = itemWantsSize && cached?.byteSize == nil
            guard wantsCount || needsSize else { continue }
            guard inFlight[key] == nil else { continue }
            inFlight[key] = generation
            schedule(Request(key: key, contentURL: contentURL, wantsCount: wantsCount, wantsSize: needsSize))
        }
        if seeded { scheduleNotify() }
    }

    /// Navigation, a fresh listing or a new search: stop measuring. Results
    /// already in flight are dropped when they land.
    func cancel() {
        token.cancel()
        token = Token()
        generation &+= 1
        inFlight.removeAll()
    }

    /// Drop what a change under these directories invalidates: the folder
    /// itself and every measured ancestor of it.
    func invalidate(_ directories: [URL]) {
        let changed = directories.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard !changed.isEmpty else { return }
        let removed = cache.keys.filter { key in
            let resolved = URL(fileURLWithPath: key.path).resolvingSymlinksInPath().path
            return changed.contains { $0 == resolved || $0.hasPrefix(resolved == "/" ? "/" : resolved + "/") }
        }
        guard !removed.isEmpty else { return }
        for key in removed { cache.removeValue(forKey: key) }
        rerequest()
        scheduleNotify()
    }

    /// Forget everything measured so far (a provider swap in tests, a reload
    /// that must not reuse stale numbers).
    func reset() {
        cancel()
        cache.removeAll()
        lastItems = []
    }

    // MARK: - Private

    private func key(for item: FileItem) -> CacheKey {
        CacheKey(path: item.url.standardizedFileURL.path, modified: item.modificationDate)
    }

    private func rerequest() {
        guard !lastItems.isEmpty else { return }
        request(lastItems, allowsRecursiveSizes: lastAllowsRecursiveSizes)
    }

    private func schedule(_ request: Request) {
        let token = self.token
        let generation = self.generation
        queue.async { [weak self] in
            let metrics = token.isCancelled ? nil : Self.measure(request, token: token)
            DispatchQueue.main.async {
                self?.finish(request.key, metrics, generation)
            }
        }
    }

    private func finish(_ key: CacheKey, _ metrics: Metrics?, _ generation: Int) {
        if inFlight[key] == generation { inFlight.removeValue(forKey: key) }
        guard generation == self.generation, let metrics else { return }
        var merged = cache[key] ?? Metrics()
        if let count = metrics.itemCount { merged.itemCount = count }
        if let bytes = metrics.byteSize { merged.byteSize = bytes }
        guard merged != cache[key] else { return }
        if cache.count >= Self.cacheLimit { cache.removeAll() }
        cache[key] = merged
        scheduleNotify()
    }

    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.onUpdate?()
        }
    }

    /// The background half: one directory read for the count, then — only when
    /// asked — one bounded enumeration for the recursive size. Errors are
    /// ignored: an unreadable subtree leaves the folder without a number
    /// rather than failing the listing.
    private static func measure(_ request: Request, token: Token) -> Metrics {
        var metrics = Metrics()
        let manager = FileManager.default
        if request.wantsCount {
            // Finder's "N items" counts what the folder shows, not its dotfiles.
            let entries = try? manager.contentsOfDirectory(
                at: request.contentURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            if let entries { metrics.itemCount = entries.count }
        }
        guard request.wantsSize, !token.isCancelled else { return metrics }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = manager.enumerator(
            at: request.contentURL, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, _ in true }) else { return metrics }
        var total: Int64 = 0
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            // Checking a lock on every entry would cost more than the walk;
            // once per block is prompt enough for a user who navigated away.
            if visited % 256 == 0, token.isCancelled { return metrics }
            if visited > Self.entryLimit { return metrics }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // Darwin's enumerator does not descend into symbolic links; their
            // own bytes belong to the target's folder, not to this one.
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        guard !token.isCancelled else { return metrics }
        metrics.byteSize = total
        return metrics
    }
}

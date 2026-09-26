import Foundation

/// Main-queue interface, with completion always delivered asynchronously there.
protocol PathCompletionProviding: AnyObject {
    func request(for text: String, cwd: URL, home: URL, completion: @escaping ([String]) -> Void)
    func cancel()
}

/// A navigator owns one service. Typing is debounced; all path resolution and
/// enumeration runs on at most two workers. A blocked volume cannot cause an
/// unbounded number of worker threads, and obsolete queued requests are dropped.
final class PathCompletionService: PathCompletionProviding {
    typealias Loader = (PathCompleter.DirectoryQuery) -> [PathCompleter.DirectoryEntry]
    typealias Matcher = ([PathCompleter.DirectoryEntry], String) -> [String]
    private struct Cached {
        let entries: [PathCompleter.DirectoryEntry]
        let expires: TimeInterval
        var use: Int
    }
    private final class Token {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    private let loader: Loader
    private let matcher: Matcher
    private let queue: OperationQueue
    private let debounce: TimeInterval
    private let lifetime: TimeInterval
    private let cacheLimit: Int
    private let now: () -> TimeInterval
    private var cache: [PathCompleter.DirectoryQuery: Cached] = [:]
    private var use = 0
    private var generation = 0
    private var scheduled: DispatchWorkItem?
    private var token: Token?

    init(debounce: TimeInterval = 0.12, cacheLifetime: TimeInterval = 1,
         cacheLimit: Int = 8, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         loader: @escaping Loader = { PathCompleter.directoryEntries(for: $0) },
         matcher: @escaping Matcher = { PathCompleter.completions(in: $0, partial: $1) }) {
        self.debounce = debounce
        lifetime = cacheLifetime
        self.cacheLimit = max(0, cacheLimit)
        self.now = now
        self.loader = loader
        self.matcher = matcher
        queue = OperationQueue()
        queue.name = "com.tursora.path-completion"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
    }

    deinit { scheduled?.cancel(); token?.cancel(); queue.cancelAllOperations() }

    func cancel() {
        precondition(Thread.isMainThread)
        generation += 1
        scheduled?.cancel()
        scheduled = nil
        token?.cancel()
        token = nil
        queue.cancelAllOperations()
    }

    func request(for text: String, cwd: URL, home: URL, completion: @escaping ([String]) -> Void) {
        precondition(Thread.isMainThread)
        cancel()
        let current = generation
        let (directoryText, partial) = PathCompleter.splitLastComponent(text)
        let query = PathCompleter.DirectoryQuery(directoryText: directoryText, cwd: cwd, home: home)
        use += 1
        cache = cache.filter { $0.value.expires > now() }
        let cachedEntries: [PathCompleter.DirectoryEntry]?
        if var cached = cache[query] {
            cached.use = use
            cache[query] = cached
            cachedEntries = cached.entries
        } else { cachedEntries = nil }
        let requestToken = Token()
        token = requestToken
        let loader = self.loader
        let matcher = self.matcher
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current, !requestToken.isCancelled else { return }
            self.scheduled = nil
            self.queue.addOperation { [weak self] in
                guard !requestToken.isCancelled else { return }
                let entries = cachedEntries ?? loader(query)
                guard !requestToken.isCancelled else { return }
                // Filtering and localized sorting are work too: a large
                // directory must not move that cost back onto the UI thread.
                // Cache hits take the same worker path, without another read.
                let candidates = matcher(entries, partial)
                guard !requestToken.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == current, !requestToken.isCancelled else { return }
                    // A very large directory may still be completed, but it
                    // does not stay resident in the short-lived cache.
                    if cachedEntries == nil, self.cacheLimit > 0, entries.count <= 4096,
                       entries.reduce(0, { $0 + $1.name.utf8.count }) <= 1_048_576 {
                        if self.cache.count >= self.cacheLimit,
                           let oldest = self.cache.min(by: { $0.value.use < $1.value.use })?.key {
                            self.cache[oldest] = nil
                        }
                        self.cache[query] = Cached(entries: entries, expires: self.now() + self.lifetime, use: self.use)
                    }
                    completion(candidates)
                }
            }
        }
        if cachedEntries != nil { work.perform() }
        else {
            scheduled = work
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
        }
    }
}

import Foundation

protocol SearchCancellable: AnyObject {
    func cancel()
}

enum SearchEvent {
    case batch([FileItem])
    case finished(String)
    case failed(String)
}

protocol SearchBackend {
    /// Events may arrive on any queue, including synchronously during start.
    @discardableResult
    func start(_ request: SearchRequest, event: @escaping (SearchEvent) -> Void) -> SearchCancellable
}

enum SearchStatus: Equatable {
    case idle, searching, finished(String), cancelled, failed(String)

    var isSearching: Bool { self == .searching }
    var message: String {
        switch self {
        case .idle: return "Set conditions, then Search."
        case .searching: return "Searching…"
        case .finished(let message), .failed(let message): return message
        case .cancelled: return "Search cancelled. Results shown may be incomplete."
        }
    }
}

/// Pane-owned, main-thread state. Advancing the generation invalidates every
/// queued callback before cancellation can synchronously call back into us.
final class SearchSession {
    private let backend: SearchBackend
    private var operation: SearchCancellable?
    private var resultURLs = Set<URL>()
    private(set) var request: SearchRequest?
    private(set) var results: [FileItem] = []
    private(set) var status: SearchStatus = .idle
    private(set) var generation = 0
    var onChange: (() -> Void)?

    init(backend: SearchBackend = LocalSearchBackend()) { self.backend = backend }

    deinit { operation?.cancel() }

    func start(_ request: SearchRequest) {
        precondition(Thread.isMainThread)
        invalidate()
        let token = generation
        self.request = request
        results = []
        resultURLs = []
        if let error = request.validationError {
            status = .failed(error)
            onChange?()
            return
        }
        status = .searching
        onChange?()
        // Always enqueue, even for an injected synchronous backend: the handle
        // must be installed before a terminal event is allowed to release it.
        let started = backend.start(request) { [weak self] event in
            DispatchQueue.main.async { [weak self] in self?.receive(event, token: token) }
        }
        if generation == token, status.isSearching { operation = started }
        else { started.cancel() }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        guard status.isSearching else { return }
        invalidate()
        status = .cancelled
        onChange?()
    }

    func clear() {
        precondition(Thread.isMainThread)
        invalidate()
        request = nil
        results = []
        resultURLs = []
        status = .idle
        onChange?()
    }

    private func invalidate() {
        generation += 1
        let previous = operation
        operation = nil
        previous?.cancel()
    }

    private func receive(_ event: SearchEvent, token: Int) {
        guard generation == token, status.isSearching else { return }
        switch event {
        case .batch(let items):
            for item in items where resultURLs.insert(item.url.standardizedFileURL).inserted {
                results.append(item)
            }
        case .finished(let message):
            status = .finished(message)
            operation = nil
        case .failed(let message):
            status = .failed(message)
            operation = nil
        }
        onChange?()
    }
}

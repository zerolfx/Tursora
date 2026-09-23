import Foundation

/// A transfer's immutable context and synchronized worker controls. AppKit only
/// reads snapshots; acknowledging Paused happens on the worker at a checkpoint.
final class TransferTask {
    enum State: String {
        case preparing, running, paused, waitingForConflict, finishing
        case completed, cancelled, partial, failed
        var isTerminal: Bool { [.completed, .cancelled, .partial, .failed].contains(self) }
    }
    struct Snapshot {
        let id: UUID
        let state: State
        /// False for a worker with no pause checkpoint of its own — extraction
        /// drives an external tool, and a paused one would hold its whole
        /// staging tree open inside the user's folder (D90).
        let supportsPause: Bool
        let currentItem: URL?
        let totalBytes: Int64?
        let completedBytes: Int64
        let bytesPerSecond: Double?
        let estimatedTimeRemaining: TimeInterval?
        let phaseDetail: String
        let successfulItems: Int
        let skippedItems: Int
        let failures: [FileOperations.Failure]
        let isCancellationRequested: Bool
        let isPauseRequested: Bool
        var isTerminal: Bool { state.isTerminal }
        var canPause: Bool { supportsPause && [.preparing, .running, .waitingForConflict].contains(state) }
    }
    let id = UUID()
    let sources: [URL]
    let destination: URL
    let kind: FileOperations.Kind
    private let condition = NSCondition()
    private var state: State = .preparing
    private var resumedState: State = .preparing
    private var pauseRequested = false
    private var cancelRequested = false
    private var item: URL?
    private var total: Int64?
    private var bytes: Int64 = 0
    private var detail = "Preparing…"
    private var successes = 0
    private var skipped = 0
    private var errors: [FileOperations.Failure] = []
    private var activeDuration: TimeInterval = 0
    private var activeSince: TimeInterval?
    private var pausable = true
    private var cancellationActions: [() -> Void] = []

    init(sources: [URL], destination: URL, kind: FileOperations.Kind) {
        self.sources = FileOperations.mutationSources(sources.map(\.standardizedFileURL))
        self.destination = destination.standardizedFileURL
        self.kind = kind
    }

    var snapshot: Snapshot {
        condition.lock(); defer { condition.unlock() }
        let elapsed = activeDuration + (activeSince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
        let speed = state == .running && elapsed > 0.1 && bytes > 0 ? Double(bytes) / elapsed : nil
        let eta = total.flatMap { total in speed.map { max(0, Double(total - bytes)) / $0 } }
        return Snapshot(id: id, state: state, supportsPause: kind != .extract && pausable, currentItem: item, totalBytes: total,
                        completedBytes: bytes, bytesPerSecond: speed, estimatedTimeRemaining: eta,
                        phaseDetail: detail, successfulItems: successes, skippedItems: skipped, failures: errors,
                        isCancellationRequested: cancelRequested, isPauseRequested: pauseRequested)
    }
    var isCancellationRequested: Bool {
        condition.lock(); defer { condition.unlock() }; return cancelRequested
    }
    func pause() {
        condition.lock(); defer { condition.unlock() }
        guard !state.isTerminal else { return }; pauseRequested = true; condition.broadcast()
    }
    func resume() {
        condition.lock(); defer { condition.unlock() }
        pauseRequested = false; condition.broadcast()
    }
    func cancel() {
        condition.lock()
        guard !state.isTerminal else { condition.unlock(); return }
        cancelRequested = true; pauseRequested = false; condition.broadcast()
        let actions = cancellationActions
        cancellationActions.removeAll()
        condition.unlock()
        actions.forEach { $0() }
    }
    /// Runs when the task is cancelled — at once if it already has been — so
    /// work the task does not drive itself, such as bytes being extracted from
    /// an archive for it, stops with it.
    func onCancel(_ action: @escaping () -> Void) {
        condition.lock()
        let now = cancelRequested
        if !now, !state.isTerminal { cancellationActions.append(action) }
        condition.unlock()
        if now { action() }
    }
    /// Pause needs a checkpoint of the task's own between data writes. While a
    /// transfer waits on an archive tool it has none, so Pause is offered only
    /// around that wait (D98).
    func setPausable(_ value: Bool) {
        condition.lock(); defer { condition.unlock() }
        pausable = value
        if !value { pauseRequested = false; condition.broadcast() }
    }
    /// All data writes are between checkpoints. Paused is published only here.
    func checkpoint() throws {
        condition.lock(); defer { condition.unlock() }
        while pauseRequested && !cancelRequested {
            if state != .paused { resumedState = state; transition(.paused) }
            condition.wait()
        }
        if state == .paused { transition(resumedState) }
        if cancelRequested { throw TransferError.cancelled }
    }
    func setPhase(_ phase: State, item: URL? = nil, detail: String) {
        condition.lock(); defer { condition.unlock() }
        if let item { self.item = item }
        self.detail = detail
        transition(phase)
    }
    func setTotal(_ value: Int64?) {
        condition.lock(); defer { condition.unlock() }; total = value
    }
    func addBytes(_ value: Int64) {
        condition.lock(); defer { condition.unlock() }; bytes += value
        // Source contents can grow after scanning; never claim an impossible total.
        if let total, bytes > total { self.total = nil }
    }
    /// An absolute figure, for a worker that measures progress rather than
    /// accumulating it. Clamped and monotonic: `addBytes` would drop the total
    /// permanently on a single overshoot, which a size sampled from a file
    /// still being written can easily produce.
    func setCompleted(_ value: Int64) {
        condition.lock(); defer { condition.unlock() }
        let ceiling = total ?? value
        bytes = max(bytes, min(max(value, 0), ceiling))
    }
    func skip(bytes value: Int64) {
        condition.lock(); defer { condition.unlock() }
        skipped += 1
        if let total { self.total = max(bytes, total - value) }
    }
    func finished(_ result: FileOperations.TransferResult) {
        condition.lock(); defer { condition.unlock() }
        successes = result.created.count + result.moved.count
        errors = result.failures
        let partial = (successes > 0 && (result.cancelled || !errors.isEmpty)) || (skipped > 0 && !result.cancelled && errors.isEmpty)
        let terminal: State = partial ? .partial : result.cancelled ? .cancelled : !errors.isEmpty ? .failed : .completed
        let noun = kind == .extract ? "Extraction" : "Transfer"
        detail = terminal == .completed ? "\(noun) complete" : terminal == .partial ? "Some items were completed"
            : terminal == .cancelled ? "\(noun) cancelled" : "\(noun) failed"
        if successes == 0 && skipped > 0 && errors.isEmpty && !result.cancelled { detail = "All items were skipped" }
        transition(terminal)
        condition.broadcast()
    }
    private func transition(_ next: State) {
        let now = ProcessInfo.processInfo.systemUptime
        if state == .running, let start = activeSince { activeDuration += now - start; activeSince = nil }
        state = next
        if next == .running { activeSince = now }
    }
}

enum TransferCheckpoint {
    case preparing, beforeCopy, chunk, beforePublish, beforeSourceRemoval, afterPublish
}

/// Internal seams keep adversarial transfer tests deterministic without changing
/// production scheduling or requiring a second mounted writable volume.
struct TransferOptions {
    var blockSize = 256 * 1024
    var chunkDelay: TimeInterval = 0
    var forceCrossVolumeMove = false
    var duplicateInPlace = false
    var checkpoint: ((TransferCheckpoint, URL, Int64) throws -> Void)?
    /// Runs on the worker before any source is pinned or scanned, to bring
    /// sources that are not on disk yet — entries of a mounted archive — to
    /// disk. Returns what could not be brought; throwing `TransferError.cancelled`
    /// cancels the transfer.
    var prepareSources: ((TransferTask) throws -> [FileOperations.Failure])?
}

enum TransferError: LocalizedError {
    case cancelled, sourceChanged(URL), destinationChanged(URL), unsupported(URL), nestedDestination, recovery([URL])
    var errorDescription: String? {
        switch self {
        case .cancelled: return "The transfer was cancelled."
        case .recovery(let urls): return "File metadata could not be restored safely. Data is retained at: " + urls.map(\.path).joined(separator: ", ")
        case .sourceChanged(let url): return "The source changed during transfer: \(url.path)"
        case .destinationChanged(let url): return "The destination changed during transfer: \(url.path)"
        case .unsupported(let url): return "This file type cannot be transferred: \(url.path)"
        case .nestedDestination: return "A folder cannot be transferred into itself."
        }
    }
}

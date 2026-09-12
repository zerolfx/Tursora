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
        var canPause: Bool { [.preparing, .running, .waitingForConflict].contains(state) }
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
    private var detail = "Calculating transfer size…"
    private var successes = 0
    private var skipped = 0
    private var errors: [FileOperations.Failure] = []
    private var activeDuration: TimeInterval = 0
    private var activeSince: TimeInterval?

    init(sources: [URL], destination: URL, kind: FileOperations.Kind) {
        self.sources = sources.map(\.standardizedFileURL)
        self.destination = destination.standardizedFileURL
        self.kind = kind
    }

    var snapshot: Snapshot {
        condition.lock(); defer { condition.unlock() }
        let elapsed = activeDuration + (activeSince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
        let speed = state == .running && elapsed > 0.1 && bytes > 0 ? Double(bytes) / elapsed : nil
        let eta = total.flatMap { total in speed.map { max(0, Double(total - bytes)) / $0 } }
        return Snapshot(id: id, state: state, currentItem: item, totalBytes: total,
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
        condition.lock(); defer { condition.unlock() }
        guard !state.isTerminal else { return }
        cancelRequested = true; pauseRequested = false; condition.broadcast()
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
        detail = terminal == .completed ? "Transfer complete" : terminal == .partial ? "Some items were completed" : terminal == .cancelled ? "Transfer cancelled" : "Transfer failed"
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

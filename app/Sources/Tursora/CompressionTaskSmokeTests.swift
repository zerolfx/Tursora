import AppKit
import Darwin

enum CompressionTaskSmokeTests: SmokeSuite {
    static let checkPrefix = "compression task: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            var fixture: URL?
            defer { if let fixture { try? FileManager.default.removeItem(at: fixture) }; completion() }
            do {
                let root = try SmokeFixtures.temporaryDirectory("compression-task")
                fixture = root
                progressChecks(root)
                try await stagingChecks(root)
                try await cancellationChecks(root)
                try await sharedCancellationChecks(root)
                try await browserChecks(root)
            } catch { check("unexpected error", false, "\(error)") }
        }
    }

    private static func progressChecks(_ root: URL) {
        let task = TransferTask(sources: [root], destination: root, kind: .compress)
        task.setTotal(100)
        task.setCompleted(80)
        task.setPhase(.running, detail: "Preparing files…")
        check("compression never offers Pause", !task.snapshot.supportsPause && !task.snapshot.canPause)
        task.resetProgress()
        check("the ZIP phase cannot reuse the staging byte percentage or speed",
              task.snapshot.totalBytes == nil && task.snapshot.completedBytes == 0 && task.snapshot.bytesPerSecond == nil)
        var result = FileOperations.TransferResult()
        result.cancelled = true
        task.finished(result)
        check("the terminal state names compression", task.snapshot.phaseDetail == "Compression cancelled")
    }

    private static func paths(_ urls: [URL]) -> [String] { urls.map { $0.standardizedFileURL.path } }

    @MainActor private static func browserState(_ pane: BrowserViewController, source: URL) -> String {
        let snapshot = pane.lastCompressionTask?.snapshot
        return "expected=\(source.standardizedFileURL.path) generation=\(pane.model.generation) mode=\(pane.viewMode) "
            + "location=\(pane.currentURL?.absoluteString ?? "nil") model=\(pane.model.url?.absoluteString ?? "nil") "
            + "listingError=\(pane.hasListingError) rows=\(paths(pane.model.items.map(\.url))) "
            + "selected=\(paths(pane.selectedURLs)) task=\(String(describing: snapshot?.state)) "
            + "failures=\(snapshot?.failures.map { $0.error.localizedDescription } ?? [])"
    }

    @MainActor private static func compress(_ source: URL, to destination: URL, task: TransferTask,
                                            options: ArchiveCompressionOptions) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            FileOperations.compress(urls: [source], to: destination, task: task, options: options) {
                continuation.resume(returning: $0)
            }
        }
    }

    private final class StagingSamples {
        private let lock = NSLock()
        private var stored: [(Int64, Int64?)] = []
        func record(_ task: TransferTask) {
            let snapshot = task.snapshot
            lock.lock(); stored.append((snapshot.completedBytes, snapshot.totalBytes)); lock.unlock()
        }
        var values: [(Int64, Int64?)] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    @MainActor private static func stagingChecks(_ root: URL) async throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent("Locked.txt")
        let bytes = Data(repeating: 71, count: 24 * 1024)
        try bytes.write(to: source)
        try require("the locked input fixture is prepared", chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(source.path, 0) }
        let destination = root.appendingPathComponent("measured")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let task = TransferTask(sources: [source], destination: destination, kind: .compress)
        let samples = StagingSamples()
        var options = ArchiveCompressionOptions()
        options.staging.blockSize = 4096
        options.checkpoint = { phase, task in if phase == .staging { samples.record(task) } }
        let output = try await compress(source, to: destination, task: task, options: options).get()
        let measured = samples.values.filter { $0.1 != nil }
        try require("staging reports the complete uncompressed input total",
                    !measured.isEmpty && measured.allSatisfy { $0.1 == Int64(bytes.count) }
                    && measured.last?.0 == Int64(bytes.count))
        try require("staging reports intermediate copied blocks without exceeding the total",
                    measured.contains { $0.0 > 0 && $0.0 < Int64(bytes.count) }
                    && measured.allSatisfy { $0.0 <= ($0.1 ?? 0) })
        try require("locked input staging is removed after success", fm.contentsOfDirectory(atPath: destination.path) == [output.lastPathComponent])
        try require("the original's lock and bytes remain unchanged",
                    (fm.attributesOfItem(atPath: source.path)[.immutable] as? Bool) == true && Data(contentsOf: source) == bytes)
        let extracted: URL = try await withCheckedThrowingContinuation { continuation in
            FileOperations.extract(archive: output, to: destination) { continuation.resume(with: $0) }
        }
        try require("the completed ZIP contains the exact input bytes", Data(contentsOf: extracted) == bytes)
    }

    @MainActor private static func cancellationChecks(_ root: URL) async throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent("source.bin")
        let bytes = Data(repeating: 37, count: 64 * 1024)
        try bytes.write(to: source)
        for phase in [ArchiveCompressionOptions.Phase.staging, .compressing, .publishing] {
            let destination = root.appendingPathComponent("cancel-\(phase)")
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            let task = TransferTask(sources: [source], destination: destination, kind: .compress)
            var options = ArchiveCompressionOptions()
            options.staging.blockSize = 4096
            options.checkpoint = { point, task in
                if point == phase && (point != .staging || task.snapshot.completedBytes > 0) { task.cancel() }
            }
            let result = await compress(source, to: destination, task: task, options: options)
            try require("\(phase): cancellation is acknowledged", task.snapshot.state == .cancelled, "\(result)")
            try require("\(phase): cancellation leaves no ZIP or private staging tree", fm.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
        try require("cancellation in every phase preserves source bytes", Data(contentsOf: source) == bytes)

        // A real owned child ignores TERM. Cancellation must escalate, reap
        // it, then remove its staging directory before completing the task.
        let destination = root.appendingPathComponent("cancel-child")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let pidFile = root.appendingPathComponent("compression.pid")
        let task = TransferTask(sources: [source], destination: destination, kind: .compress)
        var options = ArchiveCompressionOptions()
        options.tool = { _, _ in
            ("/bin/sh", ["-c", "trap '' TERM; echo $$ > \"$1\"; while :; do :; done", "compression-fixture", pidFile.path])
        }
        var result: Result<URL, Error>?
        FileOperations.compress(urls: [source], to: destination, task: task, options: options) { result = $0 }
        try await requireEventually("the owned compression child is running") { fm.fileExists(atPath: pidFile.path) }
        let pid = Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))!
        task.cancel()
        try await requireEventually("a TERM-resistant child is cancelled and reaped") { result != nil }
        try require("the task reports cancellation after its child exits", task.snapshot.state == .cancelled)
        try require("the cancelled process is no longer alive", Darwin.kill(pid, 0) == -1 && errno == ESRCH)
        try require("child cancellation removes its private files", fm.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    private final class HeldRunner: ArchiveToolRunning {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func release() { gate.signal() }
        func run(_ arguments: [String], scratch: URL, cancellation: ArchivePreparationCancellation?) throws -> ArchiveToolRun {
            lock.lock(); calls += 1; let first = calls == 1; lock.unlock()
            if first, gate.wait(timeout: .now() + 10) == .timedOut { throw SmokeFailure("shared extraction gate timed out") }
            return try SystemArchiveToolRunner.shared.run(arguments, scratch: scratch, cancellation: cancellation)
        }
    }

    @MainActor private static func sharedCancellationChecks(_ root: URL) async throws {
        let archive = root.appendingPathComponent("shared.zip")
        try SmokeFixtures.zip([("one.txt", "shared bytes")]).write(to: archive)
        let runner = HeldRunner()
        let workspace = ArchiveWorkspace(materializationPolicy: .never, preparer: { source, logical, completion in
            let cancellation = ArchivePreparationCancellation()
            FileOperations.prepareArchiveBrowsingSession(archive: source, logicalArchiveURL: logical,
                runner: runner, cancellation: cancellation, completion: completion)
            return cancellation
        })
        defer { runner.release(); workspace.shutdownAll() }
        let session: ArchiveBrowsingSession = try await withCheckedThrowingContinuation { continuation in
            workspace.prepare(archive: archive) { continuation.resume(with: $0) }
        }
        let member = archive.appendingPathComponent("one.txt")
        var ownerResult: Result<ArchiveMaterializationResult, Error>?
        var waiterResult: Result<ArchiveMaterializationResult, Error>?
        _ = workspace.materialize([member]) { ownerResult = $0 }
        try await requireEventually("the first subscriber owns the shared extraction") { runner.count == 1 }
        let waiter = workspace.materialize([member]) { waiterResult = $0 }
        try await requireEventually("the second subscriber waits on the same member") { session.materializer.activeRequestCountForTesting == 2 }
        waiter.cancel()
        try await requireEventually("a cancelled subscriber completes before the owner is released") { waiterResult != nil }
        var wasCancelled = false
        if case .failure(ArchiveBrowsingSession.SessionError.cancelled)? = waiterResult { wasCancelled = true }
        try require("the cancelled subscriber receives no bytes", wasCancelled && ownerResult == nil)
        runner.release()
        try await requireEventually("the unaffected owner finishes") { ownerResult != nil }
        let owner = try ownerResult!.get()
        try require("one extraction serves the surviving subscriber", runner.count == 1 && owner.failures.isEmpty
                    && owner.urls.first.flatMap { try? String(contentsOf: $0) } == "shared bytes")
        await withCheckedContinuation { continuation in workspace.shutdownAll { continuation.resume() } }
    }

    @MainActor private static func browserChecks(_ root: URL) async throws {
        let fm = FileManager.default
        let folder = root.appendingPathComponent("browser")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let source = folder.appendingPathComponent("Payload.txt")
        try Data(repeating: 42, count: 32 * 1024).write(to: source)
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: folder, viewPropertiesStore: store)
        defer {
            for pane in wc.tabs.pages.flatMap(\.panes) { pane.model.folderSizes.cancel(); pane.model.onChange = nil }
            wc.close(); try? store.flush()
        }
        wc.window?.makeKeyAndOrderFront(nil)
        try await requireEventually("browser fixture is listed", detail: { browserState(wc.browser, source: source) }) {
            paths(wc.browser.model.items.map(\.url)).contains(source.standardizedFileURL.path)
        }
        wc.tabs.newTab(at: folder)
        wc.tabs.selectTab(at: 0)
        wc.tabs.toggleSplit()
        wc.tabs.focusOtherPane()
        let pane = wc.tabs.current
        for mode in ViewMode.allCases {
            pane.setViewMode(mode)
            pane.setGroupKey(.kind)
            pane.nameFilter = "Payload"
            try await requireEventually("\(mode): the selected source is visible", detail: { browserState(pane, source: source) }) {
                paths(pane.model.items.map(\.url)).contains(source.standardizedFileURL.path)
            }
            pane.fileView.select(urls: [source])
            try require("\(mode): the exact source is selected", paths(pane.selectedURLs) == paths([source]), browserState(pane, source: source))
            await withCheckedContinuation { continuation in pane.compress(pane.selectedURLs) { continuation.resume() } }
            let task = pane.lastCompressionTask
            try require("\(mode): compression completes as a task", task?.kind == .compress && task?.snapshot.state == .completed,
                        browserState(pane, source: source))
            try require("\(mode): the actual task row is titled Compress",
                        task.flatMap { TransferTasksWindowController.shared.row(for: $0.id)?.titleLabel.stringValue }?.hasPrefix("Compress") == true)
            try require("\(mode): the ZIP phase has no invented percent", task?.snapshot.totalBytes == nil && task?.snapshot.completedBytes == 0)
            let output = folder.appendingPathComponent("Payload.txt.zip")
            try require("\(mode): only the completed ZIP is published", fm.fileExists(atPath: output.path)
                        && !fm.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".tursora-archive-") })
            try require("\(mode): undo belongs to the originating window", wc.window?.undoManager?.undoActionName == "Compress")
            wc.window?.undoManager?.undo()
            try await requireEventually("\(mode): Undo removes the created ZIP") { !fm.fileExists(atPath: output.path) }
            wc.window?.undoManager?.redo()
            try await requireEventually("\(mode): Redo restores the created ZIP") { fm.fileExists(atPath: output.path) }
            try fm.removeItem(at: output)
            try require("\(mode): split panes and the second tab remain open", wc.tabs.count == 2 && wc.tabs.currentPage.panes.count == 2)
            pane.nameFilter = ""
            pane.setGroupKey(.none)
        }
        pane.compressionOptions.checkpoint = { phase, task in if phase == .compressing { task.cancel() } }
        await withCheckedContinuation { continuation in pane.compress([source]) { continuation.resume() } }
        try require("the browser's cancelled task publishes no archive", pane.lastCompressionTask?.snapshot.state == .cancelled
                    && !fm.fileExists(atPath: folder.appendingPathComponent("Payload.txt.zip").path))
        try require("headless compression never opens the task window", TransferTasksWindowController.shared.window?.isVisible != true)
    }
}

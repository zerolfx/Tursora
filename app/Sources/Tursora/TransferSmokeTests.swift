import AppKit
import Darwin

/// Deterministic transfer checks exercise the worker first, then the same
/// browser entry points used by both file views. All waits yield the main loop.
enum TransferSmokeTests {
    @MainActor private final class Running {
        let task: TransferTask
        var result: FileOperations.TransferResult?
        var callbackCount = 0
        init(_ task: TransferTask) { self.task = task }
    }

    /// Blocks only the transfer worker at a destructive boundary. The main
    /// actor observes `entered`, requests cancellation, and releases the gate.
    private final class Gate: @unchecked Sendable {
        private let condition = NSCondition()
        private var hasEntered = false
        private var isReleased = false
        var entered: Bool {
            condition.lock(); defer { condition.unlock() }
            return hasEntered
        }
        func arrive() {
            condition.lock()
            hasEntered = true
            condition.broadcast()
            while !isReleased { condition.wait() }
            condition.unlock()
        }
        func release() {
            condition.lock()
            isReleased = true
            condition.broadcast()
            condition.unlock()
        }
    }

    static func run(_ existingWindow: MainWindowController, completion: @escaping () -> Void) {
        Task { @MainActor in
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("tursora-transfer-" + UUID().uuidString)
                .resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: fixture) }
            do {
                try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                print("== transfer task lifecycle and publication safety ==")
                print("   transfer fixture: \(fixture.path)")
                await registryLifecycle(in: fixture)
                try await pauseAndResume(in: fixture)
                try await cancellationAndFailure(in: fixture)
                try await independentTasks(in: fixture)
                try await metadataAndLinks(in: fixture)
                try await lockedMetadata(in: fixture)
                try await conflictsAndJournal(in: fixture)
                try await boundaryCancellation(in: fixture)
                try await crossVolumeMoves(in: fixture)
                try await replayGuardBoundaries(in: fixture)
                try await changedIdentityBoundaries(in: fixture)
                try await browserPaths(in: fixture, provider: existingWindow.provider)
                completion()
            } catch {
                check("transfer smoke fixtures and async operations succeed", false, "\(error as NSError), userInfo=\((error as NSError).userInfo)")
            }
        }
    }

    @MainActor private static func registryLifecycle(in fixture: URL) async {
        let registry = TransferTasksWindowController()
        defer { registry.close() }
        let first = TransferTask(sources: [fixture.appendingPathComponent("first")], destination: fixture, kind: .copy)
        let second = TransferTask(sources: [fixture.appendingPathComponent("second")], destination: fixture, kind: .copy)
        registry.track(first)
        registry.track(second)
        var callbacks = 0
        registry.cancelAll { callbacks += 1 }
        check("cancel-all waits asynchronously for every selected task", callbacks == 0 && registry.hasActiveTasks)
        var cancelled = FileOperations.TransferResult()
        cancelled.cancelled = true
        first.finished(cancelled)
        registry.refresh()
        registry.clearFinished(nil)
        check("Clear Finished can remove one task while cancellation waits for another", !registry.taskIDs.contains(first.id) && registry.taskIDs.contains(second.id) && callbacks == 0)
        second.finished(cancelled)
        registry.refresh()
        await waitUntil("cancel-all completes after a finished row was cleared") { callbacks == 1 }
        registry.refresh()
        check("clearing an earlier finished row cannot strand lifecycle waiters", callbacks == 1 && !registry.hasActiveTasks)
        var emptyCallbacks = 0
        registry.cancelAll { emptyCallbacks += 1 }
        check("empty cancel-all defers application termination reply", emptyCallbacks == 0)
        await waitUntil("empty cancellation completes asynchronously") { emptyCallbacks == 1 }

        registry.clearFinished(nil)
        let waiting = TransferTask(sources: [fixture.appendingPathComponent("waiting")], destination: fixture, kind: .copy)
        registry.track(waiting)
        for index in 0..<8 {
            let historical = TransferTask(sources: [fixture.appendingPathComponent("history-\(index)")], destination: fixture, kind: .copy)
            historical.finished(FileOperations.TransferResult())
            registry.track(historical)
        }
        let failed = TransferTask(sources: [fixture.appendingPathComponent("quick-failure")], destination: fixture, kind: .copy)
        registry.track(failed)
        let presentationsBeforeFailure = registry.taskPresentationCount
        var failure = FileOperations.TransferResult()
        failure.failures = [.init(url: failed.sources[0], error: POSIXError(.EIO))]
        failed.finished(failure)
        registry.refresh()
        check("a quick failure requests its task presentation before the delayed progress window", registry.taskPresentationCount == presentationsBeforeFailure + 1 && registry.lastPresentedTaskID == failed.id)
        check("newest task appears first in the actual rendered row order", registry.displayedTaskIDs.first == failed.id && registry.displayedTaskIDs.last == waiting.id)
        registry.refresh()
        check("repeated refresh does not repeatedly present the same failure", registry.taskPresentationCount == presentationsBeforeFailure + 1)
        waiting.setPhase(.waitingForConflict, item: waiting.sources[0], detail: "Waiting for a conflict decision")
        registry.resolveConflict(for: waiting, conflict: .init(source: waiting.sources[0], destination: fixture.appendingPathComponent("existing"), kind: .copy, remaining: 1)) { _ in }
        check("an older task's conflict requests reveal despite newer completed rows", registry.taskPresentationCount == presentationsBeforeFailure + 2 && registry.lastPresentedTaskID == waiting.id && registry.row(for: waiting.id)?.hasPendingConflict == true)
        waiting.finished(cancelled)
        registry.refresh()
    }

    @MainActor private static func start(_ sources: [URL], to destination: URL,
                                        kind: FileOperations.Kind = .copy,
                                        options: TransferOptions = TransferOptions(),
                                        task supplied: TransferTask? = nil,
                                        conflict: @escaping FileOperations.ConflictHandler = { _ in .init(resolution: .keepBoth) },
                                        asyncConflict: ((FileOperations.Conflict, @escaping (FileOperations.ConflictDecision) -> Void) -> Void)? = nil) -> Running {
        let task = supplied ?? TransferTask(sources: sources, destination: destination, kind: kind)
        let running = Running(task)
        FileOperations.transfer(sources, to: destination, kind: kind, conflict: conflict,
                                task: task, options: options, asyncConflict: asyncConflict) { result in
            check("transfer completion is delivered on the main thread", Thread.isMainThread)
            running.callbackCount += 1
            running.result = result
        }
        return running
    }

    @MainActor private static func finished(_ running: Running) async -> FileOperations.TransferResult {
        await waitUntil("transfer completion", detail: { "state=\(running.task.snapshot.state), bytes=\(running.task.snapshot.completedBytes)" }) {
            running.result != nil
        }
        check("transfer finishes exactly once with a terminal snapshot", running.callbackCount == 1 && running.task.snapshot.isTerminal)
        for failure in running.result!.failures {
            print("   transfer diagnostic: \(failure.url.path): \(failure.error)")
        }
        return running.result!
    }

    @MainActor private static func pauseAndResume(in fixture: URL) async throws {
        let (source, destination) = try folders("pause", in: fixture)
        let bytes = payload()
        let file = source.appendingPathComponent("large.bin")
        try bytes.write(to: file)
        var options = slowOptions()
        options.blockSize = 32 * 1024
        let running = start([file], to: destination, options: options)
        await waitUntil("single-file transfer reaches an interior block") {
            running.task.snapshot.completedBytes >= 1024 * 1024 && !running.task.snapshot.isTerminal
        }
        let active = running.task.snapshot
        check("prepared transfer reports real byte total and current item", active.totalBytes == Int64(bytes.count) && active.completedBytes < Int64(bytes.count) && active.currentItem != nil)
        check("running transfer reports finite measured speed and remaining time", (active.bytesPerSecond ?? 0) > 0 && active.bytesPerSecond?.isFinite == true && (active.estimatedTimeRemaining ?? -1) >= 0 && active.estimatedTimeRemaining?.isFinite == true)
        running.task.pause()
        await waitUntil("worker acknowledges pause") { running.task.snapshot.state == .paused }
        // Allow an already-issued kernel write to reach its next checkpoint.
        try await Task.sleep(nanoseconds: 40_000_000)
        let pausedBytes = running.task.snapshot.completedBytes
        try await Task.sleep(nanoseconds: 160_000_000)
        check("pause stops bytes in the middle of one large file", running.task.snapshot.state == .paused && running.task.snapshot.completedBytes == pausedBytes && pausedBytes > 0 && pausedBytes < Int64(bytes.count))
        check("paused transfer does not publish its incomplete destination", !exists(destination.appendingPathComponent(file.lastPathComponent)))
        running.task.resume()
        let result = await finished(running)
        let output = destination.appendingPathComponent(file.lastPathComponent)
        check("resume preserves every byte and source content", try Data(contentsOf: output) == bytes && Data(contentsOf: file) == bytes)
        check("completed copy records only the published output", result.created == [output] && result.moved.isEmpty && result.failures.isEmpty && !result.cancelled)
        check("completed byte count equals the known total", running.task.snapshot.state == .completed && running.task.snapshot.completedBytes == Int64(bytes.count) && running.task.snapshot.totalBytes == Int64(bytes.count))
        running.task.pause(); running.task.resume(); running.task.cancel()
        check("late controls cannot change a completed task", running.task.snapshot.state == .completed)
    }

    @MainActor private static func cancellationAndFailure(in fixture: URL) async throws {
        let bytes = payload()
        for replacing in [false, true] {
            let (source, destination) = try folders(replacing ? "cancel-replace" : "cancel", in: fixture)
            let file = source.appendingPathComponent("large.bin")
            let output = destination.appendingPathComponent("large.bin")
            try bytes.write(to: file)
            if replacing { try Data("original target".utf8).write(to: output) }
            let before = try visibleNames(destination)
            let running = start([file], to: destination, options: slowOptions(), conflict: { _ in .init(resolution: .replace) })
            await waitUntil("cancel transfer reaches interior bytes") { running.task.snapshot.completedBytes >= 64 * 1024 }
            running.task.cancel()
            let result = await finished(running)
            check("mid-file cancellation reports no successful mutation (replace=\(replacing))", result.cancelled && result.created.isEmpty && result.moved.isEmpty && running.task.snapshot.state == .cancelled)
            check("mid-file cancellation preserves source and previous destination (replace=\(replacing))", try Data(contentsOf: file) == bytes && (replacing ? String(contentsOf: output) == "original target" : !exists(output)))
            check("mid-file cancellation removes private partial files (replace=\(replacing))", try visibleNames(destination) == before)
        }

        let (source, destination) = try folders("failure", in: fixture)
        let file = source.appendingPathComponent("large.bin")
        let output = destination.appendingPathComponent("large.bin")
        try bytes.write(to: file)
        try Data("original target".utf8).write(to: output)
        let before = try visibleNames(destination)
        var options = slowOptions()
        options.checkpoint = { point, _, count in
            if point == .chunk && count >= 64 * 1024 { throw POSIXError(.EIO) }
        }
        let running = start([file], to: destination, options: options, conflict: { _ in .init(resolution: .replace) })
        let result = await finished(running)
        check("injected block failure has failed status and no success items", result.failures.count == 1 && !result.cancelled && result.created.isEmpty && result.moved.isEmpty && running.task.snapshot.state == .failed)
        check("injected block failure preserves both original files", try Data(contentsOf: file) == bytes && String(contentsOf: output) == "original target")
        check("injected block failure leaves no staged partial output", try visibleNames(destination) == before)
    }

    @MainActor private static func independentTasks(in fixture: URL) async throws {
        let (source, firstDestination) = try folders("parallel", in: fixture)
        let secondDestination = source.deletingLastPathComponent().appendingPathComponent("second-destination")
        try FileManager.default.createDirectory(at: secondDestination, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("large.bin")
        let bytes = payload()
        try bytes.write(to: file)
        let first = start([file], to: firstDestination, options: slowOptions())
        let second = start([file], to: secondDestination, options: slowOptions())
        await waitUntil("both tasks transfer independently") { first.task.snapshot.completedBytes > 0 && second.task.snapshot.completedBytes > 0 }
        first.task.pause()
        await waitUntil("first parallel task pauses") { first.task.snapshot.state == .paused }
        try await Task.sleep(nanoseconds: 40_000_000)
        let pausedBytes = first.task.snapshot.completedBytes
        let secondResult = await finished(second)
        check("a paused task does not block another task", secondResult.created.count == 1 && first.task.snapshot.state == .paused && first.task.snapshot.completedBytes == pausedBytes)
        first.task.cancel()
        let firstResult = await finished(first)
        check("cancelling one task cannot cancel another", firstResult.cancelled && second.task.snapshot.state == .completed && (try? Data(contentsOf: secondDestination.appendingPathComponent("large.bin"))) == bytes)
        check("parallel task cancellation removes only its own partial file", try visibleNames(firstDestination).isEmpty && exists(secondDestination.appendingPathComponent("large.bin")))
    }

    @MainActor private static func metadataAndLinks(in fixture: URL) async throws {
        let fm = FileManager.default
        let (source, destination) = try folders("metadata", in: fixture)
        let folder = source.appendingPathComponent("Project.app")
        let contents = folder.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let file = contents.appendingPathComponent("payload.txt")
        try Data("metadata and package payload".utf8).write(to: file)
        let modified = Date(timeIntervalSince1970: 1_650_000_000)
        try fm.setAttributes([.posixPermissions: 0o751, .modificationDate: modified], ofItemAtPath: file.path)
        try fm.setAttributes([.posixPermissions: 0o750, .modificationDate: modified], ofItemAtPath: contents.path)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read,readattr,readextattr,readsecurity", file.path]
        try chmod.run()
        chmod.waitUntilExit()
        let sourceACL = accessControlList(at: file)
        check("metadata fixture has an explicit extended ACL", chmod.terminationStatus == 0 && sourceACL?.contains("allow") == true)
        try FileInfo.setComment("copied comment", for: file)
        let resource = Data("transfer-resource-fork".utf8)
        let quarantine = Data("0083;65000000;TursoraTransferSmokeTest;".utf8)
        try setAttribute("com.apple.ResourceFork", data: resource, at: file)
        try setAttribute("com.apple.quarantine", data: quarantine, at: file)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        try fm.createSymbolicLink(atPath: contents.appendingPathComponent("relative").path, withDestinationPath: "payload.txt")
        try fm.createSymbolicLink(atPath: contents.appendingPathComponent("dangling").path, withDestinationPath: "missing-target")
        let outside = source.appendingPathComponent("outside.txt")
        try Data("outside must not be traversed".utf8).write(to: outside)
        try fm.createSymbolicLink(atPath: contents.appendingPathComponent("outside-link").path, withDestinationPath: outside.path)
        let result = await finished(start([folder], to: destination))
        let copied = destination.appendingPathComponent("Project.app/Contents/payload.txt")
        check("directory and package contents transfer as one published item", result.created.map(\.standardizedFileURL.path) == [destination.appendingPathComponent("Project.app").standardizedFileURL.path] && result.failures.isEmpty && (try? String(contentsOf: copied)) == "metadata and package payload", "created=\(result.created), failures=\(result.failures.map { $0.error.localizedDescription })")
        let attributes = try fm.attributesOfItem(atPath: copied.path)
        check("copy preserves executable permissions and modification time", (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o751 && abs((attributes[.modificationDate] as! Date).timeIntervalSince(modified)) < 0.01)
        check("copy preserves the explicit extended ACL", accessControlList(at: copied) == sourceACL)
        let copiedComment = FileInfo.comment(for: copied)
        let copiedResource = attribute("com.apple.ResourceFork", at: copied)
        let copiedQuarantine = attribute("com.apple.quarantine", at: copied)
        check("copy preserves Finder comments", copiedComment == "copied comment", "actual=\(copiedComment.debugDescription)")
        check("copy preserves resource fork bytes", copiedResource == resource, "actual=\(String(describing: copiedResource?.base64EncodedString())), expected=\(resource.base64EncodedString())")
        check("copy preserves quarantine provenance and flags", copiedQuarantine == quarantine, "actual=\(String(describing: copiedQuarantine.flatMap { String(data: $0, encoding: .utf8) })), expected=\(String(data: quarantine, encoding: .utf8)!)")
        let copiedContents = copied.deletingLastPathComponent()
        check("copy preserves directory permissions", ((try fm.attributesOfItem(atPath: copiedContents.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o750)
        check("copy preserves relative and dangling symlink text", try fm.destinationOfSymbolicLink(atPath: copiedContents.appendingPathComponent("relative").path) == "payload.txt" && fm.destinationOfSymbolicLink(atPath: copiedContents.appendingPathComponent("dangling").path) == "missing-target")
        check("copy does not dereference an external symlink", try fm.destinationOfSymbolicLink(atPath: copiedContents.appendingPathComponent("outside-link").path) == outside.path && String(contentsOf: outside) == "outside must not be traversed")

        let dangling = source.appendingPathComponent("dangling-root")
        try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing-root")
        let danglingResult = await finished(start([dangling], to: destination))
        check("standalone dangling symlinks are copyable items", danglingResult.created.count == 1 && (try? fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("dangling-root").path)) == "missing-root")
        let duplicate = await finished(start([dangling], to: destination))
        check("dangling destination symlink participates in Keep Both conflicts", duplicate.created.map(\.lastPathComponent) == ["dangling-root 2"] && (try? fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("dangling-root").path)) == "missing-root")
    }

    @MainActor private static func lockedMetadata(in fixture: URL) async throws {
        let (source, destination) = try folders("locked-metadata", in: fixture)
        let file = source.appendingPathComponent("locked.txt"), output = destination.appendingPathComponent("locked.txt")
        try Data("locked source contents".utf8).write(to: file)
        try FileInfo.setLocked(true, file)
        defer {
            try? FileInfo.setLocked(false, file)
            try? FileInfo.setLocked(false, output)
        }
        let result = await finished(start([file], to: destination))
        let sourceIntact = result.created.map(\.path) == [output.path] && result.failures.isEmpty && FileInfo.isLocked(file) && (try? String(contentsOf: file)) == "locked source contents"
        let copyIntact = FileInfo.isLocked(output) && (try? String(contentsOf: output)) == "locked source contents"
        var undoWorked = false
        var redoWorked = false
        if let journal = result.journal {
            let redo = try FileOperations.replay(journal)
            undoWorked = !exists(output) && FileInfo.isLocked(file)
            _ = try FileOperations.replay(redo)
            redoWorked = FileInfo.isLocked(output) && (try? String(contentsOf: output)) == "locked source contents"
        }
        // `check` exits the process on failure, so release fixture flags first.
        try? FileInfo.setLocked(false, file)
        try? FileInfo.setLocked(false, output)
        check("a locked source can be copied without unlocking or modifying it", sourceIntact)
        check("copy preserves the locked flag and complete destination contents", copyIntact)
        check("undo handles a completed locked copy without changing its source", undoWorked)
        check("redo restores the completed copy with its locked flag", redoWorked)
    }

    @MainActor private static func conflictsAndJournal(in fixture: URL) async throws {
        let fm = FileManager.default
        let (source, destination) = try folders("conflicts", in: fixture)
        let sources = ["one.txt", "two.txt"].map { source.appendingPathComponent($0) }
        for file in sources {
            try Data(("new " + file.lastPathComponent).utf8).write(to: file)
            try Data(("old " + file.lastPathComponent).utf8).write(to: destination.appendingPathComponent(file.lastPathComponent))
        }
        var decisions = 0
        let result = await finished(start(sources, to: destination, conflict: { conflict in
            decisions += 1
            check("conflict callbacks run on main with accurate remaining count", Thread.isMainThread && conflict.remaining == 2)
            return .init(resolution: .replace, applyToAll: true)
        }))
        check("Replace Apply to all prompts once and publishes both sources", decisions == 1 && result.created.count == 2 && result.failures.isEmpty && sources.allSatisfy { (try? String(contentsOf: destination.appendingPathComponent($0.lastPathComponent))) == "new " + $0.lastPathComponent })
        if let journal = result.journal {
            let redo = try FileOperations.replay(journal)
            check("replacement journal undo restores the exact original targets", sources.allSatisfy { (try? String(contentsOf: destination.appendingPathComponent($0.lastPathComponent))) == "old " + $0.lastPathComponent })
            _ = try FileOperations.replay(redo)
            check("replacement journal redo restores both completed copies", sources.allSatisfy { (try? String(contentsOf: destination.appendingPathComponent($0.lastPathComponent))) == "new " + $0.lastPathComponent })
        } else { check("completed replacements supply an undo journal", false) }

        decisions = 0
        let skipped = await finished(start(sources, to: destination, conflict: { _ in decisions += 1; return .init(resolution: .skip, applyToAll: true) }))
        check("Skip Apply to all records no mutation or failure", decisions == 1 && skipped.created.isEmpty && skipped.moved.isEmpty && skipped.failures.isEmpty && !skipped.cancelled)

        let mergeSource = source.appendingPathComponent("Folder")
        let mergeDestination = destination.appendingPathComponent("Folder")
        try fm.createDirectory(at: mergeSource, withIntermediateDirectories: true)
        try fm.createDirectory(at: mergeDestination, withIntermediateDirectories: true)
        try Data("new child".utf8).write(to: mergeSource.appendingPathComponent("new.txt"))
        try Data("incoming conflict".utf8).write(to: mergeSource.appendingPathComponent("conflict.txt"))
        try Data("old child".utf8).write(to: mergeDestination.appendingPathComponent("old.txt"))
        try Data("existing conflict".utf8).write(to: mergeDestination.appendingPathComponent("conflict.txt"))
        let merged = await finished(start([mergeSource], to: destination, kind: .move, conflict: { conflict in
            .init(resolution: conflict.bothFolders ? .merge : .replace)
        }))
        check("move merge preserves preexisting sibling contents", (try? String(contentsOf: mergeDestination.appendingPathComponent("old.txt"))) == "old child" && (try? String(contentsOf: mergeDestination.appendingPathComponent("new.txt"))) == "new child" && (try? String(contentsOf: mergeDestination.appendingPathComponent("conflict.txt"))) == "incoming conflict")
        check("move merge success does not claim the preexisting destination folder", !merged.moved.contains { $0.to == mergeDestination } && merged.failures.isEmpty)
        if let journal = merged.journal {
            let redo = try FileOperations.replay(journal)
            check("move merge undo restores source children and destination conflicts", (try? String(contentsOf: mergeSource.appendingPathComponent("new.txt"))) == "new child" && (try? String(contentsOf: mergeSource.appendingPathComponent("conflict.txt"))) == "incoming conflict" && (try? String(contentsOf: mergeDestination.appendingPathComponent("conflict.txt"))) == "existing conflict")
            check("move merge undo leaves unrelated destination children in place", (try? String(contentsOf: mergeDestination.appendingPathComponent("old.txt"))) == "old child" && !exists(mergeSource.appendingPathComponent("old.txt")) && !exists(mergeDestination.appendingPathComponent("new.txt")))
            _ = try FileOperations.replay(redo)
            check("move merge redo reapplies completed child mutations", (try? String(contentsOf: mergeDestination.appendingPathComponent("new.txt"))) == "new child" && (try? String(contentsOf: mergeDestination.appendingPathComponent("old.txt"))) == "old child")
        } else { check("completed merge supplies an undo journal", false) }

        let (partialSource, partialDestination) = try folders("partial", in: fixture)
        let first = partialSource.appendingPathComponent("first.txt"), last = partialSource.appendingPathComponent("last.bin")
        try Data("successful item".utf8).write(to: first)
        try payload().write(to: last)
        var options = slowOptions()
        options.checkpoint = { point, url, count in
            if point == .chunk && url.lastPathComponent == last.lastPathComponent && count >= 64 * 1024 { throw POSIXError(.EIO) }
        }
        let partialRun = start([first, last], to: partialDestination, options: options)
        let partial = await finished(partialRun)
        check("partial failure distinguishes committed items from a failed partial", partialRun.task.snapshot.state == .partial && partial.created == [partialDestination.appendingPathComponent("first.txt")] && partial.failures.count == 1 && !exists(partialDestination.appendingPathComponent("last.bin")))
        if let journal = partial.journal {
            _ = try FileOperations.replay(journal)
            check("partial failure undo includes only the completed item", !exists(partialDestination.appendingPathComponent("first.txt")) && exists(first) && exists(last))
        } else { check("partially successful task supplies an undo journal", false) }
    }

    @MainActor private static func boundaryCancellation(in fixture: URL) async throws {
        for point: TransferCheckpoint in [.preparing, .beforeCopy, .beforePublish] {
            let (source, destination) = try folders("boundary-\(point)", in: fixture)
            let file = source.appendingPathComponent("source.bin")
            try payload().write(to: file)
            let gate = Gate()
            var options = TransferOptions()
            options.checkpoint = { actual, _, _ in if actual == point { gate.arrive() } }
            let running = start([file], to: destination, options: options)
            await waitUntil("worker enters \(point) checkpoint") { gate.entered }
            if point == .preparing { check("metadata scan honestly reports unknown total", running.task.snapshot.totalBytes == nil && running.task.snapshot.state == .preparing) }
            running.task.pause()
            gate.release()
            await waitUntil("pause is honored at \(point)") { running.task.snapshot.state == .paused }
            running.task.cancel()
            let result = await finished(running)
            check("cancellation from paused \(point) leaves no successful item", result.cancelled && result.created.isEmpty && exists(file) && !exists(destination.appendingPathComponent("source.bin")))
        }

        let (source, destination) = try folders("conflict-wait", in: fixture)
        let file = source.appendingPathComponent("same.txt"), output = destination.appendingPathComponent("same.txt")
        try Data("source".utf8).write(to: file)
        try Data("target".utf8).write(to: output)
        var answer: ((FileOperations.ConflictDecision) -> Void)?
        let running = start([file], to: destination, asyncConflict: { _, resolve in answer = resolve })
        await waitUntil("asynchronous conflict request is waiting") { answer != nil && running.task.snapshot.state == .waitingForConflict }
        running.task.cancel()
        let result = await finished(running)
        check("conflict-wait cancellation completes without waiting for an answer", result.cancelled && result.created.isEmpty && (try? String(contentsOf: file)) == "source" && (try? String(contentsOf: output)) == "target")
        answer?(.init(resolution: .replace))
        try await Task.sleep(nanoseconds: 40_000_000)
        check("late conflict answer cannot restart a cancelled operation", running.callbackCount == 1 && running.task.snapshot.state == .cancelled && (try? String(contentsOf: output)) == "target")

        let stopped = await finished(start([file], to: destination, conflict: { _ in .init(resolution: .cancel) }))
        check("conflict Stop remains a cancelled batch with no mutation", stopped.cancelled && stopped.created.isEmpty && (try? String(contentsOf: output)) == "target")

        let (publishedSource, publishedDestination) = try folders("cancel-after-publication", in: fixture)
        let first = publishedSource.appendingPathComponent("first.txt"), last = publishedSource.appendingPathComponent("last.txt")
        try Data("published successfully".utf8).write(to: first)
        try Data("not started".utf8).write(to: last)
        let gate = Gate()
        var options = TransferOptions()
        options.checkpoint = { point, _, _ in if point == .afterPublish { gate.arrive() } }
        let committed = start([first, last], to: publishedDestination, options: options)
        await waitUntil("first item reaches post-publication boundary") { gate.entered }
        committed.task.cancel()
        gate.release()
        let committedResult = await finished(committed)
        let published = publishedDestination.appendingPathComponent("first.txt")
        check("cancellation after publication retains the completed item as partial success", committed.task.snapshot.state == .partial && committedResult.cancelled && committedResult.created == [published] && (try? String(contentsOf: published)) == "published successfully" && !exists(publishedDestination.appendingPathComponent("last.txt")))
        if let journal = committedResult.journal {
            _ = try FileOperations.replay(journal)
            check("cancelled partial task retains an undo journal for only its published item", !exists(published) && exists(first) && exists(last))
        } else { check("cancelled partial task supplies an undo journal", false) }
    }

    @MainActor private static func crossVolumeMoves(in fixture: URL) async throws {
        // The fixture lives on one writable volume. Force the transfer branch
        // while preserving real copy, publication and source-retirement I/O.
        for point: TransferCheckpoint in [.chunk, .beforeSourceRemoval] {
            let (source, destination) = try folders("cross-volume-failure-\(point)", in: fixture)
            let file = source.appendingPathComponent("move.bin"), output = destination.appendingPathComponent("move.bin")
            let bytes = payload()
            try bytes.write(to: file)
            try Data("original destination".utf8).write(to: output)
            var options = slowOptions()
            options.forceCrossVolumeMove = true
            options.checkpoint = { actual, _, count in
                if actual == point && (point != .chunk || count >= 64 * 1024) { throw POSIXError(.EIO) }
            }
            let running = start([file], to: destination, kind: .move, options: options, conflict: { _ in .init(resolution: .replace) })
            let result = await finished(running)
            check("forced cross-volume failure at \(point) cannot retire the source", result.moved.isEmpty && result.failures.count == 1 && (try? Data(contentsOf: file)) == bytes)
            check("forced cross-volume failure at \(point) restores the previous target", (try? String(contentsOf: output)) == "original destination")
        }

        let (source, destination) = try folders("cross-volume-success", in: fixture)
        let file = source.appendingPathComponent("move.bin"), output = destination.appendingPathComponent("move.bin")
        let bytes = payload()
        try bytes.write(to: file)
        var options = TransferOptions()
        options.forceCrossVolumeMove = true
        let result = await finished(start([file], to: destination, kind: .move, options: options))
        check("forced cross-volume success retires source only after complete copy", result.moved.count == 1 && result.created.isEmpty && !exists(file) && (try? Data(contentsOf: output)) == bytes)
        if let journal = result.journal {
            let redo = try FileOperations.replay(journal)
            check("cross-volume undo restores source and removes completed target", (try? Data(contentsOf: file)) == bytes && !exists(output))
            _ = try FileOperations.replay(redo)
            check("cross-volume redo preserves complete bytes", !exists(file) && (try? Data(contentsOf: output)) == bytes)
        } else { check("completed cross-volume move supplies an undo journal", false) }

        let (atomicSource, atomicDestination) = try folders("atomic-move", in: fixture)
        let atomicFile = atomicSource.appendingPathComponent("atomic.bin")
        try bytes.write(to: atomicFile)
        let gate = Gate()
        var atomicOptions = TransferOptions()
        atomicOptions.checkpoint = { point, _, _ in if point == .beforePublish { gate.arrive() } }
        let atomic = start([atomicFile], to: atomicDestination, kind: .move, options: atomicOptions)
        await waitUntil("same-volume atomic move reaches commit boundary") { gate.entered }
        check("atomic move does not invent transferred bytes, speed or ETA", atomic.task.snapshot.totalBytes == 0 && atomic.task.snapshot.completedBytes == 0 && atomic.task.snapshot.bytesPerSecond == nil && atomic.task.snapshot.estimatedTimeRemaining == nil)
        gate.release()
        let atomicResult = await finished(atomic)
        check("atomic move publishes source without pretending to stream it", atomicResult.moved.count == 1 && atomic.task.snapshot.completedBytes == 0 && !exists(atomicFile) && (try? Data(contentsOf: atomicDestination.appendingPathComponent("atomic.bin"))) == bytes)
    }

    @MainActor private static func changedIdentityBoundaries(in fixture: URL) async throws {
        let fm = FileManager.default
        for replaceSource in [true, false] {
            let (source, destination) = try folders(replaceSource ? "changed-merge-source" : "changed-merge-destination", in: fixture)
            let folder = source.appendingPathComponent("Folder"), target = destination.appendingPathComponent("Folder")
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            try Data("original source".utf8).write(to: folder.appendingPathComponent("source.txt"))
            try Data("original target".utf8).write(to: target.appendingPathComponent("target.txt"))
            var answer: ((FileOperations.ConflictDecision) -> Void)?
            let running = start([folder], to: destination, kind: .move, asyncConflict: { _, reply in answer = reply })
            await waitUntil("merge conflict waits before identity replacement") { answer != nil }
            let replaced = replaceSource ? folder : target
            let displaced = replaced.deletingLastPathComponent().appendingPathComponent("OriginalFolder")
            try fm.moveItem(at: replaced, to: displaced)
            try fm.createDirectory(at: replaced, withIntermediateDirectories: false)
            answer?(.init(resolution: .merge))
            let result = await finished(running)
            check("merge rejects a replaced \(replaceSource ? "source" : "destination") directory", result.failures.count == 1 && result.created.isEmpty && result.moved.isEmpty && running.task.snapshot.state == .failed)
            check("merge preserves the unrelated replacement directory and displaced originals", exists(replaced) && (try? visibleNames(replaced).isEmpty) == true && (try? String(contentsOf: displaced.appendingPathComponent(replaceSource ? "source.txt" : "target.txt"))) == (replaceSource ? "original source" : "original target"))
        }

        let (source, destination) = try folders("changed-replacement-content", in: fixture)
        let file = source.appendingPathComponent("same.txt"), target = destination.appendingPathComponent("same.txt")
        try Data("incoming".utf8).write(to: file)
        try Data("old original".utf8).write(to: target)
        let gate = Gate()
        var options = TransferOptions()
        options.checkpoint = { point, _, _ in if point == .beforePublish { gate.arrive() } }
        let running = start([file], to: destination, options: options, conflict: { _ in .init(resolution: .replace) })
        await waitUntil("replacement copy is ready to publish") { gate.entered }
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("newest external edit".utf8))
        try handle.close()
        gate.release()
        let result = await finished(running)
        check("Replace rejects a target changed in place after the decision", result.created.isEmpty && result.failures.count == 1 && (try? String(contentsOf: target)) == "newest external edit" && (try? String(contentsOf: file)) == "incoming")

        for replaceSource in [true, false] {
            let (source, destination) = try folders(replaceSource ? "changed-source-ancestor" : "changed-target-ancestor", in: fixture)
            let file = source.appendingPathComponent("source.txt")
            try Data("fixed source".utf8).write(to: file)
            let alternative = source.deletingLastPathComponent().appendingPathComponent("alternative")
            try fm.createDirectory(at: alternative, withIntermediateDirectories: false)
            try Data("unrelated source".utf8).write(to: alternative.appendingPathComponent("source.txt"))
            let gate = Gate()
            var options = TransferOptions()
            options.checkpoint = { point, _, _ in if point == .beforePublish { gate.arrive() } }
            let running = start([file], to: destination, options: options)
            await waitUntil("transfer waits before ancestor symlink replacement") { gate.entered }
            let replaced = replaceSource ? source : destination
            let displaced = replaced.deletingLastPathComponent().appendingPathComponent("original-parent")
            try fm.moveItem(at: replaced, to: displaced)
            try fm.createSymbolicLink(atPath: replaced.path, withDestinationPath: alternative.path)
            gate.release()
            let result = await finished(running)
            check("ancestor replacement cannot redirect the \(replaceSource ? "source" : "destination") of a fixed task", result.created.isEmpty && result.failures.count == 1 && (try? String(contentsOf: alternative.appendingPathComponent("source.txt"))) == "unrelated source")
            check("ancestor replacement leaves the original source data intact", (try? String(contentsOf: (replaceSource ? displaced : source).appendingPathComponent("source.txt"))) == "fixed source")
        }
    }

    @MainActor private static func replayGuardBoundaries(in fixture: URL) async throws {
        let fm = FileManager.default
        let (source, destination) = try folders("cross-volume-edited-undo", in: fixture)
        let file = source.appendingPathComponent("edited.txt"), output = destination.appendingPathComponent("edited.txt")
        try Data("original before move".utf8).write(to: file)
        var options = TransferOptions()
        options.forceCrossVolumeMove = true
        let moved = await finished(start([file], to: destination, kind: .move, options: options))
        guard let journal = moved.journal else {
            check("cross-volume replay guard fixture has an undo journal", false); return
        }
        // Keep the destination inode: an inode-only check must not discard an
        // edit made after copy-and-retire completed on another volume.
        let writer = try FileHandle(forWritingTo: output)
        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: Data("edited after the completed move".utf8))
        try writer.close()
        var refusedUndo = false
        do { _ = try FileOperations.replay(journal) }
        catch { refusedUndo = true }
        check("cross-volume Undo refuses a destination edited in place after completion", refusedUndo)
        check("refused cross-volume Undo preserves the edit and cannot restore stale source bytes", !exists(file) && (try? String(contentsOf: output)) == "edited after the completed move")

        let (batchSource, batchDestination) = try folders("cross-volume-edited-during-batch", in: fixture)
        let first = batchSource.appendingPathComponent("first.txt"), second = batchSource.appendingPathComponent("second.txt")
        let firstOutput = batchDestination.appendingPathComponent("first.txt"), secondOutput = batchDestination.appendingPathComponent("second.txt")
        try Data("original first item".utf8).write(to: first)
        try Data("original second item".utf8).write(to: second)
        var batchOptions = TransferOptions()
        batchOptions.forceCrossVolumeMove = true
        batchOptions.checkpoint = { point, source, _ in
            guard point == .afterPublish, source.path == first.path else { return }
            // An external editor can change an already-published item while
            // the same batch is still copying its remaining sources.
            let writer = try FileHandle(forWritingTo: firstOutput)
            try writer.truncate(atOffset: 0)
            try writer.write(contentsOf: Data("edited while second item was pending".utf8))
            try writer.close()
        }
        let batch = await finished(start([first, second], to: batchDestination, kind: .move, options: batchOptions))
        check("cross-volume batch completes its second item after the first destination was edited", batch.moved.count == 2 && batch.failures.isEmpty && (try? String(contentsOf: secondOutput)) == "original second item")
        guard let batchJournal = batch.journal else {
            check("cross-volume in-batch edit fixture has an undo journal", false); return
        }
        var refusedBatchUndo = false
        do { _ = try FileOperations.replay(batchJournal) }
        catch { refusedBatchUndo = true }
        check("cross-volume Undo captures each item's identity at publication rather than batch completion", refusedBatchUndo)
        check("in-batch destination edit survives refused Undo without restoring either stale source", !exists(first) && !exists(second) && (try? String(contentsOf: firstOutput)) == "edited while second item was pending" && (try? String(contentsOf: secondOutput)) == "original second item")

        let (mergeSource, mergeDestination) = try folders("merge-redo-new-child", in: fixture)
        let folder = mergeSource.appendingPathComponent("Folder"), target = mergeDestination.appendingPathComponent("Folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let incoming = folder.appendingPathComponent("same.txt"), existing = target.appendingPathComponent("same.txt")
        try Data("incoming child".utf8).write(to: incoming)
        try Data("original target child".utf8).write(to: existing)
        try Data("unrelated target child".utf8).write(to: target.appendingPathComponent("keep.txt"))
        let merged = await finished(start([folder], to: mergeDestination, kind: .move, conflict: { conflict in
            .init(resolution: conflict.bothFolders ? .merge : .replace)
        }))
        guard let mergeJournal = merged.journal else {
            check("move-merge replay guard fixture has an undo journal", false); return
        }
        let redo = try FileOperations.replay(mergeJournal)
        let added = folder.appendingPathComponent("added-after-undo.txt")
        try Data("new unrelated source child".utf8).write(to: added)
        var refusedRedo = false
        do { _ = try FileOperations.replay(redo) }
        catch { refusedRedo = true }
        check("move-merge Redo refuses to retire a source folder containing a new child", refusedRedo)
        check("refused move-merge Redo preserves new source content and rolls back prior child moves", (try? String(contentsOf: incoming)) == "incoming child" && (try? String(contentsOf: added)) == "new unrelated source child")
        check("refused move-merge Redo restores the target conflict and unrelated destination sibling", (try? String(contentsOf: existing)) == "original target child" && (try? String(contentsOf: target.appendingPathComponent("keep.txt"))) == "unrelated target child" && !exists(target.appendingPathComponent("added-after-undo.txt")))
    }

    @MainActor private static func browserPaths(in fixture: URL, provider: FileProvider) async throws {
        print("== transfer task controls through real browser entry points ==")
        let fm = FileManager.default
        let oldMode = ViewPreferences.viewMode
        let oldGroup = ViewPreferences.groupKey
        let oldLastGroup = ViewPreferences.lastGroupKey
        defer {
            ViewPreferences.viewMode = oldMode
            ViewPreferences.groupKey = oldGroup
            ViewPreferences.lastGroupKey = oldLastGroup
            TransferTasksWindowController.shared.clearFinished(nil)
        }
        let bytes = payload()
        for mode: ViewMode in [.details, .icons] {
            let (source, destination) = try folders("browser-\(mode)", in: fixture)
            let elsewhere = source.deletingLastPathComponent().appendingPathComponent("elsewhere")
            try fm.createDirectory(at: elsewhere, withIntermediateDirectories: false)
            let file = source.appendingPathComponent("large.bin")
            try bytes.write(to: file)
            try Data("must stay filtered".utf8).write(to: source.appendingPathComponent("hidden.txt"))
            let wc = MainWindowController(provider: provider, places: PlacesModel(), initialURL: source)
            defer { wc.close() }
            let browser = wc.browser
            await listed(browser, at: source)
            wc.tabs.openInOtherPane(destination)
            let other = wc.browser
            await listed(other, at: destination)
            for pane in [browser, other] {
                pane.setViewMode(mode)
                pane.setGroupKey(.kind)
                pane.nameFilter = "*.bin"
                pane.transferOptions = slowOptions()
            }
            wc.tabs.currentPage.activate(browser)
            let listedSourceURLs = browser.model.items.filter { canonicalPath($0.url) == canonicalPath(file) }.map(\.url)
            browser.fileView.select(urls: listedSourceURLs)
            check("\(mode): filtered grouped source selection reaches the visible file view", browser.fileView.selectedItems.map { canonicalPath($0.url) } == [canonicalPath(file)] && browser.model.items.count == 1 && browser.groupKey == .kind,
                  "selected=\(browser.fileView.selectedItems.map(\.url)), fixture=\(file), model=\(browser.model.items.map(\.url)), group=\(browser.groupKey), samePane=\(browser === other), rows=\(browser.fileList.tableView.numberOfRows), rowItems=\((0..<browser.fileList.tableView.numberOfRows).compactMap { browser.fileList.item(atRow: $0)?.url })")
            browser.copyToOtherPane(nil)
            guard let task = browser.lastTransferTask,
                  let row = TransferTasksWindowController.shared.row(for: task.id),
                  let undo = wc.window?.undoManager else {
                check("\(mode): other-pane Copy creates a controlled task and window undo context", false)
                return
            }
            await waitUntil("\(mode) UI copy reaches interior bytes") { task.snapshot.completedBytes >= 64 * 1024 }
            TransferTasksWindowController.shared.refresh()
            check("\(mode): real task row renders bytes and enabled controls", row.bytesLabel.stringValue.contains(" of ") && !row.progressIndicator.isIndeterminate && row.pauseButton.isEnabled && row.cancelButton.isEnabled)
            row.pauseButton.performClick(nil)
            await waitUntil("\(mode) row Pause reaches worker") { task.snapshot.state == .paused }
            TransferTasksWindowController.shared.refresh()
            let paused = task.snapshot.completedBytes
            try await Task.sleep(nanoseconds: 60_000_000)
            check("\(mode): Pause button freezes bytes and changes to Resume", task.snapshot.completedBytes == paused && row.pauseButton.title == "Resume" && row.stateLabel.stringValue == "Paused" && row.rateLabel.stringValue.isEmpty)
            browser.navigate(to: elsewhere)
            await listed(browser, at: elsewhere)
            let newTab = wc.tabs.newTab(at: elsewhere)
            await listed(newTab, at: elsewhere)
            check("\(mode): navigation and tab changes do not retarget the task", task.sources.map(canonicalPath) == [canonicalPath(file)] && canonicalPath(task.destination) == canonicalPath(destination) && wc.browser === newTab && browser.currentURL.map(canonicalPath) == canonicalPath(elsewhere), "taskSources=\(task.sources), taskDestination=\(task.destination), current=\(String(describing: browser.currentURL))")
            row.pauseButton.performClick(nil)
            let output = destination.appendingPathComponent("large.bin")
            await waitUntil("\(mode) resumed UI copy and undo registration") { task.snapshot.isTerminal && undo.canUndo && exists(output) }
            await waitUntil("\(mode) inactive destination pane refresh") { other.model.items.contains { canonicalPath($0.url) == canonicalPath(output) } }
            TransferTasksWindowController.shared.refresh()
            check("\(mode): completed UI copy preserves content, context and filtering", (try? Data(contentsOf: output)) == bytes && browser.currentURL.map(canonicalPath) == canonicalPath(elsewhere) && wc.browser === newTab && other.isFiltering && other.groupKey == .kind)
            check("\(mode): completed row removes its live controls", row.pauseButton.isHidden && row.cancelButton.isHidden && row.stateLabel.stringValue == "Completed")
            undo.undo()
            await waitUntil("\(mode) undo refreshes inactive target pane") { !exists(output) && !other.model.items.contains { canonicalPath($0.url) == canonicalPath(output) } }
            check("\(mode): Undo affects the captured destination and preserves source", exists(file) && !exists(elsewhere.appendingPathComponent("large.bin")) && undo.canRedo)
            undo.redo()
            await waitUntil("\(mode) redo refreshes inactive target pane") { exists(output) && other.model.items.contains { canonicalPath($0.url) == canonicalPath(output) } }
            check("\(mode): Redo restores the exact completed copy", (try? Data(contentsOf: output)) == bytes)

            // Paste invokes the browser's clipboard route, while Cancel is sent
            // through the actual task-row button during a single file's copy.
            let clipboardFile = source.appendingPathComponent("clipboard.bin")
            try bytes.write(to: clipboardFile)
            newTab.navigate(to: source)
            await listed(newTab, at: source)
            newTab.setViewMode(mode)
            newTab.fileView.select(urls: newTab.model.items.filter { canonicalPath($0.url) == canonicalPath(clipboardFile) }.map(\.url))
            newTab.copy(nil)
            newTab.navigate(to: elsewhere)
            await listed(newTab, at: elsewhere)
            newTab.transferOptions = slowOptions()
            newTab.paste(nil)
            guard let pasteTask = newTab.lastTransferTask,
                  let pasteRow = TransferTasksWindowController.shared.row(for: pasteTask.id) else {
                check("\(mode): Paste registers an independent task", false); return
            }
            await waitUntil("\(mode) pasted file begins copying") { pasteTask.snapshot.completedBytes > 0 }
            pasteRow.cancelButton.performClick(nil)
            await waitUntil("\(mode) pasted task cancels") { pasteTask.snapshot.isTerminal }
            check("\(mode): Paste Cancel leaves its source and no partial destination", pasteTask.snapshot.state == .cancelled && exists(clipboardFile) && !exists(elsewhere.appendingPathComponent("clipboard.bin")))
            check("\(mode): task controls remain bound to their own task", task.snapshot.state == .completed && task.id != pasteTask.id)

            // Both concrete file views route accepted drops through the same
            // callback. Keep the originating pane alive after its tab closes.
            undo.removeAllActions()
            newTab.fileView.onDropFiles?([clipboardFile], elsewhere, .copy)
            guard let dropTask = newTab.lastTransferTask else { check("\(mode): dropped files create a task", false); return }
            await waitUntil("\(mode) dropped file begins copying") { dropTask.snapshot.completedBytes > 0 }
            check("\(mode): closing an originating tab succeeds during transfer", wc.tabs.closeCurrentTab())
            await waitUntil("\(mode) closed-tab transfer finishes with undo") { dropTask.snapshot.isTerminal && exists(elsewhere.appendingPathComponent("clipboard.bin")) && undo.canUndo && undo.undoActionName == "Copy" }
            check("\(mode): closing a tab retains task and original window undo", dropTask.snapshot.state == .completed && (try? Data(contentsOf: elsewhere.appendingPathComponent("clipboard.bin"))) == bytes)
            undo.undo()
            check("\(mode): closed-tab task remains undoable", !exists(elsewhere.appendingPathComponent("clipboard.bin")) && exists(clipboardFile))

            // Duplicate previously blocked AppKit with copyItem; it now has the
            // same cancellable task and preserves its per-source parent.
            let active = wc.browser
            active.navigate(to: source)
            await listed(active, at: source)
            active.nameFilter = ""
            active.setViewMode(mode)
            active.fileView.select(urls: active.model.items.filter { canonicalPath($0.url) == canonicalPath(file) }.map(\.url))
            active.transferOptions = slowOptions()
            active.duplicate(nil)
            guard let duplicateTask = active.lastTransferTask else { check("\(mode): Duplicate creates a task", false); return }
            await waitUntil("\(mode) Duplicate transfers an interior block") { duplicateTask.snapshot.completedBytes > 0 }
            check("\(mode): Duplicate keeps AppKit responsive during its transfer", !duplicateTask.snapshot.isTerminal && duplicateTask.kind == .copy)
            let canCloseImmediately = wc.windowShouldClose(wc.window!)
            check("\(mode): closing a window waits for its active worker", !canCloseImmediately)
            await waitUntil("\(mode) window-close cancellation stops writing") { duplicateTask.snapshot.isTerminal }
            TransferTasksWindowController.shared.refresh()
            check("\(mode): window-close cancellation cleans Duplicate and releases ownership", duplicateTask.snapshot.state == .cancelled && !exists(source.appendingPathComponent("large copy.bin")) && exists(file) && !TransferTasksWindowController.shared.hasActiveTasks(ownedBy: wc.window!))
        }
        try await conflictControls(in: fixture, provider: provider)
    }

    @MainActor private static func conflictControls(in fixture: URL, provider: FileProvider) async throws {
        let (source, destination) = try folders("browser-conflict", in: fixture)
        let one = source.appendingPathComponent("one.txt"), two = source.appendingPathComponent("two.txt")
        for file in [one, two] {
            try Data("incoming".utf8).write(to: file)
            try Data("existing".utf8).write(to: destination.appendingPathComponent(file.lastPathComponent))
        }
        let wc = MainWindowController(provider: provider, places: PlacesModel(), initialURL: destination)
        defer { wc.close() }
        await listed(wc.browser, at: destination)
        wc.browser.dropFiles([one, two], to: destination, op: .copy)
        guard let task = wc.browser.lastTransferTask,
              let row = TransferTasksWindowController.shared.row(for: task.id) else {
            check("real conflict task has a control row", false); return
        }
        await waitUntil("nonmodal conflict row appears") { row.hasPendingConflict && task.snapshot.state == .waitingForConflict }
        check("real conflict controls preserve all file choices", row.conflictButtons[.keepBoth]?.isHidden == false && row.conflictButtons[.replace]?.isHidden == false && row.conflictButtons[.skip]?.isHidden == false && row.conflictButtons[.cancel]?.isHidden == false && row.conflictButtons[.merge]?.isHidden == true && !row.applyToAllButton.isHidden)
        row.applyToAllButton.state = .on
        row.conflictButtons[.keepBoth]?.performClick(nil)
        await waitUntil("Keep Both Apply to all finishes without another prompt") { task.snapshot.isTerminal }
        TransferTasksWindowController.shared.refresh()
        check("real Keep Both controls preserve originals and apply to every conflict", task.snapshot.state == .completed && !row.hasPendingConflict && (try? String(contentsOf: destination.appendingPathComponent("one.txt"))) == "existing" && (try? String(contentsOf: destination.appendingPathComponent("two.txt"))) == "existing" && (try? String(contentsOf: destination.appendingPathComponent("one 2.txt"))) == "incoming" && (try? String(contentsOf: destination.appendingPathComponent("two 2.txt"))) == "incoming")
    }

    @MainActor private static func listed(_ browser: BrowserViewController, at url: URL) async {
        // Called immediately after navigation on main. An old empty listing
        // must not satisfy the condition before the newly requested load ends.
        let startingGeneration = browser.model.generation
        await waitUntil("listing \(url.lastPathComponent)", detail: { "current=\(String(describing: browser.currentURL)), model=\(String(describing: browser.model.url))" }) {
            browser.currentURL.map(canonicalPath) == canonicalPath(url)
                && browser.model.url.map(canonicalPath) == canonicalPath(url)
                && browser.model.generation > startingGeneration && !browser.isPreparingArchive
                && browser.model.items.allSatisfy { canonicalPath($0.url.deletingLastPathComponent()) == canonicalPath(url) }
        }
        browser.view.layoutSubtreeIfNeeded()
    }

    /// UI fixture comparisons account for macOS's /var and /private/var aliases;
    /// selection itself still receives the complete URL of the actual FileItem.
    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func folders(_ name: String, in fixture: URL) throws -> (URL, URL) {
        let root = fixture.appendingPathComponent(name)
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (source, destination)
    }

    private static func payload() -> Data {
        let block = (0..<4096).map { UInt8(($0 &* 37 &+ $0 / 11) % 251) }
        var data = Data(capacity: 2 * 1024 * 1024)
        for _ in 0..<512 { data.append(contentsOf: block) }
        return data
    }

    private static func slowOptions() -> TransferOptions {
        var options = TransferOptions()
        options.blockSize = 16 * 1024
        options.chunkDelay = 0.004
        return options
    }

    /// Includes hidden staging names: cleanup checks must not hide leftovers.
    private static func visibleNames(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func setAttribute(_ name: String, data: Data, at url: URL) throws {
        let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func attribute(_ name: String, at url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var value = Data(count: size)
        let read = value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? value : nil
    }

    private static func accessControlList(at url: URL) -> String? {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(text) }
        return String(cString: text)
    }

    @MainActor private static func waitUntil(_ label: String, detail: () -> String = { "" }, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > deadline { check("\(label) completes", false, detail()); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        print("\(success ? "ok  " : "FAIL") transfer: \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !success { fflush(stdout); exit(1) }
    }
}

import Foundation
import Darwin

/// Deterministic cancellation and cleanup checks, independent of browser UI.
enum ArchivePreparationSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let manager = FileManager.default
            let fixture = manager.temporaryDirectory.appendingPathComponent("tursora-zip-preparation-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: fixture) }
            do {
                print("== ZIP preparation cancellation ==")
                let source = fixture.appendingPathComponent("Source")
                try manager.createDirectory(at: source, withIntermediateDirectories: true)
                try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
                try Data("vanish".utf8).write(to: source.appendingPathComponent("vanish.txt"))
                let archive: URL = try await withCheckedThrowingContinuation { continuation in
                    FileOperations.compress(urls: [source], to: fixture) { continuation.resume(with: $0) }
                }
                let bytes = try Data(contentsOf: archive)
                try await subscriptionChecks(archive: archive, fixture: fixture)
                try await cancellationChecks(archive: archive)
                try await entryChecks(archive: archive)
                await processChecks()
                check("ZIP cancellation never changes the source archive", (try? Data(contentsOf: archive)) == bytes)
                check("ZIP cancellation and entry races leave original files untouched",
                      (try? String(contentsOf: source.appendingPathComponent("keep.txt"))) == "keep"
                      && (try? String(contentsOf: source.appendingPathComponent("vanish.txt"))) == "vanish")
                completion()
            } catch { check("ZIP preparation fixture completes", false, error.localizedDescription) }
        }
    }

    @MainActor private static func subscriptionChecks(archive: URL, fixture: URL) async throws {
        let harness = PreparationHarness()
        let workspace = ArchiveWorkspace(preparer: harness.start)
        defer { workspace.shutdownAll() }
        var firstCalls = 0, secondCalls = 0
        let first = workspace.prepare(archive: archive) { _ in firstCalls += 1 }
        _ = workspace.prepare(archive: archive) { result in
            if case .success = result { secondCalls += 1 }
            check("shared ZIP preparation delivers on the main thread", Thread.isMainThread)
        }
        check("two subscribers share one extraction job", harness.jobs.count == 1 && workspace.hasPendingPreparation(for: archive))
        first.cancel()
        first.cancel()
        check("cancelling one subscriber leaves the other extraction running", !harness.jobs[0].cancellation.isCancelled)
        let original = try await prepare(archive)
        harness.jobs[0].completion(.success(original))
        await wait("remaining ZIP subscriber receives completion") { secondCalls == 1 }
        check("cancelled subscriber never receives the shared result", firstCalls == 0 && workspace.session(for: archive) === original)
        check("successful extraction leaves no pending job", !workspace.hasPendingPreparation(for: archive))

        var cachedCalls = 0
        let cached = workspace.prepare(archive: archive) { _ in cachedCalls += 1 }
        cached.cancel()
        await nextMainTurn()
        check("cancellation suppresses an already queued cached result", cachedCalls == 0 && harness.jobs.count == 1)
        check("cancelling a cached delivery preserves the usable snapshot", !original.isClosed && workspace.session(for: archive) === original)

        let undeliveredURL = fixture.appendingPathComponent("Undelivered.zip")
        var undeliveredCalls = 0
        let undelivered = workspace.prepare(archive: undeliveredURL) { _ in undeliveredCalls += 1 }
        let undeliveredJob = harness.jobs.last!
        let undeliveredResult = try await prepare(archive, logical: undeliveredURL)
        undeliveredJob.completion(.success(undeliveredResult))
        undelivered.cancel()
        await wait("cancelling a queued new result finishes private storage cleanup") {
            !workspace.hasPendingPreparation(for: undeliveredURL)
        }
        check("cancelling before the first delivery does not retain an unused ZIP snapshot",
              undeliveredCalls == 0 && workspace.session(for: undeliveredURL) == nil
              && undeliveredResult.isClosed && !FileManager.default.fileExists(atPath: undeliveredResult.storageURL.path))

        let retryURL = fixture.appendingPathComponent("Retry.zip")
        var abandonedCalls = 0, retryCalls = 0
        let abandoned = workspace.prepare(archive: retryURL) { _ in abandonedCalls += 1 }
        abandoned.cancel()
        check("cancelling the final subscriber cancels the underlying job", harness.jobs.count == 3 && harness.jobs[2].cancellation.isCancelled)
        check("cancelled extraction stays pending until its cleanup result arrives", workspace.hasPendingPreparation(for: retryURL))
        _ = workspace.prepare(archive: retryURL) { result in if case .success = result { retryCalls += 1 } }
        check("a same-ZIP retry gets a fresh uncancelled job", harness.jobs.count == 4 && !harness.jobs[3].cancellation.isCancelled)
        let oldResult = try await prepare(archive, logical: retryURL)
        let newResult = try await prepare(archive, logical: retryURL)
        harness.jobs[2].completion(.success(oldResult))
        await wait("stale successful ZIP preparation is cleaned") { oldResult.isClosed && !FileManager.default.fileExists(atPath: oldResult.storageURL.path) }
        check("an old job cannot publish into or finish the replacement job",
              abandonedCalls == 0 && retryCalls == 0 && workspace.session(for: retryURL) == nil
              && workspace.hasPendingPreparation(for: retryURL))
        harness.jobs[3].completion(.success(newResult))
        await wait("same-ZIP retry receives its own result") { retryCalls == 1 }
        check("the retry publishes only its new snapshot", workspace.session(for: retryURL) === newResult && !newResult.isClosed)

        let shutdownURL = fixture.appendingPathComponent("Shutdown.zip")
        var stoppedCalls = 0, shutdowns = 0
        _ = workspace.prepare(archive: shutdownURL) { result in
            if case .failure(let error) = result, case ArchiveBrowsingSession.SessionError.closed = error { stoppedCalls += 1 }
        }
        workspace.shutdownAll { shutdowns += 1 }
        workspace.shutdownAll { shutdowns += 1 }
        await nextMainTurn()
        check("shutdown cancels pending work and informs still-subscribed panes", harness.jobs[4].cancellation.isCancelled && stoppedCalls == 1)
        check("repeated shutdown calls wait for the same unfinished job", shutdowns == 0 && workspace.hasPendingPreparation(for: shutdownURL))
        check("shutdown closes ready snapshots without waiting for unrelated child cleanup",
              original.isClosed && newResult.isClosed && !FileManager.default.fileExists(atPath: original.storageURL.path))
        let lateResult = try await prepare(archive, logical: shutdownURL)
        harness.jobs[4].completion(.success(lateResult))
        await wait("shutdown barriers finish after stale private storage cleanup") { shutdowns == 2 }
        check("shutdown callbacks run only after the last discarded result is cleaned",
              lateResult.isClosed && !FileManager.default.fileExists(atPath: lateResult.storageURL.path)
              && !workspace.hasPendingPreparation(for: shutdownURL))
        workspace.shutdownAll { shutdowns += 1 }
        await nextMainTurn()
        check("shutdown remains idempotent after all work has settled", shutdowns == 3)
        var rejectedCalls = 0
        let rejected = workspace.prepare(archive: archive) { _ in rejectedCalls += 1 }
        rejected.cancel()
        await nextMainTurn()
        check("a cancelled subscription also suppresses a queued shutdown error", rejectedCalls == 0 && harness.jobs.count == 5)
    }

    @MainActor private static func cancellationChecks(archive: URL) async throws {
        let cancelled = ArchivePreparationCancellation()
        cancelled.cancel()
        let beforeStart: Result<ArchiveBrowsingSession, Error> = await withCheckedContinuation { continuation in
            ArchiveBrowsingSession.prepare(archive: archive, cancellation: cancelled) { continuation.resume(returning: $0) }
        }
        check("pre-cancelled extraction fails without starting a child", isCancellation(beforeStart))

        for stage in ["before extraction", "before publication"] {
            let gate = WorkerGate()
            let storage = LockedBox<URL?>(nil)
            let token = ArchivePreparationCancellation { checkpoint in
                switch checkpoint {
                case .storageCreated(let url): storage.value = url
                case .beforeExtraction: if stage == "before extraction" { gate.arriveAndWait() }
                case .beforePublication: if stage == "before publication" { gate.arriveAndWait() }
                }
            }
            let result = LockedBox<Result<ArchiveBrowsingSession, Error>?>(nil)
            ArchiveBrowsingSession.prepare(archive: archive, cancellation: token) { result.value = $0 }
            await wait("ZIP worker reaches \(stage)") { gate.arrived }
            check("\(stage): preparation owns private storage before cancellation",
                  storage.value.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            token.cancel()
            check("\(stage): cancellation returns before the worker gate is released", token.isCancelled && result.value == nil)
            gate.release()
            await wait("ZIP cancellation completes \(stage)") { result.value != nil }
            check("\(stage): cancelled extraction reports cancellation after cleaning storage",
                  result.value.map(isCancellation) == true
                  && storage.value.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        }

        let gate = WorkerGate()
        let storage = LockedBox<URL?>(nil)
        let workspace = ArchiveWorkspace { source, logical, completion in
            let token = ArchivePreparationCancellation { checkpoint in
                if case .storageCreated(let url) = checkpoint { storage.value = url }
                if case .beforeExtraction = checkpoint { gate.arriveAndWait() }
            }
            return ArchiveBrowsingSession.prepare(archive: source, logicalArchiveURL: logical, cancellation: token, completion: completion)
        }
        _ = workspace.prepare(archive: archive) { _ in }
        await wait("real shutdown fixture reaches extraction gate") { gate.arrived }
        var completed = false
        workspace.shutdownAll { completed = true }
        await nextMainTurn()
        check("real workspace shutdown cannot finish before extraction cleanup", !completed && workspace.hasPendingPreparation(for: archive))
        gate.release()
        await wait("real workspace shutdown finishes cleanup") { completed }
        check("real shutdown removes cancelled private storage before replying",
              storage.value.map { !FileManager.default.fileExists(atPath: $0.path) } == true
              && workspace.session(for: archive) == nil && !workspace.hasPendingPreparation(for: archive))
    }

    @MainActor private static func entryChecks(archive: URL) async throws {
        let session = try await prepare(archive)
        defer { session.close() }
        let root = session.rootURL.appendingPathComponent("Source")
        let entries = try session.entries(in: root) { url in
            if url.lastPathComponent == "vanish.txt" { try FileManager.default.removeItem(at: url) }
        }
        check("a child removed between ZIP enumeration and metadata read does not blank the directory",
              entries.map(\.name) == ["keep.txt"] && !FileManager.default.fileExists(atPath: root.appendingPathComponent("vanish.txt").path))
        var permissionError = false
        do { _ = try session.entries(in: root) { _ in throw POSIXError(.EACCES) } }
        catch { permissionError = (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == EACCES }
        check("ZIP listing continues to report errors other than a vanished child", permissionError)
    }

    @MainActor private static func processChecks() async {
        let token = ArchivePreparationCancellation()
        let gate = WorkerGate()
        let result = LockedBox<Bool?>(nil)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try token.runProcess(child)
                gate.arriveAndWait()
                child.waitUntilExit()
                token.finishProcess(child)
                result.value = token.isCancelled && !child.isRunning && child.terminationReason == .uncaughtSignal
            } catch { result.value = false }
        }
        await wait("real cancellable child starts") { gate.arrived }
        token.cancel()
        check("process cancellation returns without waiting on the worker", result.value == nil)
        gate.release()
        await wait("cancelled child is waited and reaped") { result.value != nil }
        check("cancellation terminates the actual child before worker completion", result.value == true)
    }

    @MainActor private static func prepare(_ archive: URL, logical: URL? = nil) async throws -> ArchiveBrowsingSession {
        try await withCheckedThrowingContinuation { continuation in
            ArchiveBrowsingSession.prepare(archive: archive, logicalArchiveURL: logical) { continuation.resume(with: $0) }
        }
    }

    private static func isCancellation(_ result: Result<ArchiveBrowsingSession, Error>) -> Bool {
        if case .failure(let error) = result, case ArchiveBrowsingSession.SessionError.cancelled = error { return true }
        return false
    }

    @MainActor private static func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @MainActor private static func wait(_ label: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { check("\(label) completes", false); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private final class PreparationHarness {
        struct Job {
            let cancellation: ArchivePreparationCancellation
            let completion: (Result<ArchiveBrowsingSession, Error>) -> Void
        }
        var jobs: [Job] = []
        func start(_ source: URL, _ logical: URL,
                   _ completion: @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) -> ArchivePreparationCancellation {
            let token = ArchivePreparationCancellation()
            jobs.append(Job(cancellation: token, completion: completion))
            return token
        }
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private final class WorkerGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var reached = false
        private var released = false
        var arrived: Bool { condition.lock(); defer { condition.unlock() }; return reached }
        func arriveAndWait() {
            condition.lock()
            reached = true
            while !released {
                if !condition.wait(until: Date().addingTimeInterval(10)) { break }
            }
            condition.unlock()
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }

    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        print("\(success ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !success { fflush(stdout); exit(1) }
    }
}

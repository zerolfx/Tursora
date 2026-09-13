import AppKit

/// Shared scaffolding for the headless smoke suites (`*SmokeTests.swift`).
///
/// Every suite adopts `SmokeSuite`, optionally supplies a `checkPrefix`
/// ("transfer: "), and gets the same `check` / `waitUntil` family. The output
/// format is fixed: `ok  <prefix><name>[ — detail]` on success and
/// `FAIL <prefix><name>[ — detail]` followed by `exit(1)` on the first failure.
/// `SmokeTest.run` line-buffers stdout, so no helper needs `fflush`.
protocol SmokeSuite {
    /// Text printed between the `ok  ` / `FAIL` marker and the check name.
    static var checkPrefix: String { get }
}

/// A failed check raised where a suite must release fixtures (a live PTY,
/// a mounted volume) before the process exits; its description is the FAIL line.
struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension SmokeSuite {
    static var checkPrefix: String { "" }

    /// Prints one result line and exits on the first failure. The detail
    /// autoclosure is only evaluated when non-empty output is printed.
    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        let extra = detail()
        print("\(ok ? "ok  " : "FAIL") \(checkPrefix)\(name)\(extra.isEmpty ? "" : " — \(extra)")")
        if !ok { exit(1) }
    }

    /// Prints a failure line and exits.
    static func fail(_ name: String, _ detail: String = "") -> Never {
        check(name, false, detail)
        fatalError("unreachable")
    }

    /// Like `check`, but throws `SmokeFailure` instead of exiting so the
    /// caller can clean up before reporting; print the error and exit there.
    static func require(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") throws {
        guard ok else {
            let extra = detail()
            throw SmokeFailure("\(checkPrefix)\(name)\(extra.isEmpty ? "" : " — \(extra)")")
        }
        print("ok  \(checkPrefix)\(name)")
    }

    /// Polls `condition` on the main actor until it holds; silent on success,
    /// a failed check on timeout.
    @MainActor
    static func waitUntil(_ name: String, timeout: TimeInterval = 15, interval: UInt64 = 10_000_000,
                          detail: () -> String = { "" }, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { check(name, false, detail()); return }
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    /// Polls like `waitUntil` but always records the outcome as a check, so
    /// suites that count the wait as a result keep their totals.
    @MainActor
    static func expectEventually(_ name: String, timeout: TimeInterval = 15, interval: UInt64 = 10_000_000,
                                 detail: () -> String = { "" }, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: interval) }
        let passed = condition()
        check(name, passed, passed ? "" : detail())
    }

    /// Throwing variant of `expectEventually` for suites that clean up fixtures
    /// before exiting; records `ok` on success.
    @MainActor
    static func requireEventually(_ name: String, timeout: TimeInterval = 15, interval: UInt64 = 10_000_000,
                                  detail: () -> String = { "" }, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw SmokeFailure("\(checkPrefix)\(name) — \(detail())") }
            try await Task.sleep(nanoseconds: interval)
        }
        try require(name, true)
    }

    /// Lets queued main-queue work run before the next check.
    @MainActor
    static func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}

/// Shared smoke fixtures that several suites used to declare privately.
enum SmokeFixtures {
    /// A `FileProvider` whose every directory is empty; `listingDelay` reproduces
    /// a slow initial listing.
    final class EmptyProvider: FileProvider {
        let homeURL: URL
        let listingDelay: TimeInterval
        init(homeURL: URL = FileManager.default.temporaryDirectory, listingDelay: TimeInterval = 0) {
            self.homeURL = homeURL
            self.listingDelay = listingDelay
        }
        func displayName(for url: URL) -> String { url.lastPathComponent }
        func listDirectory(_ url: URL) throws -> [FileItem] {
            if listingDelay > 0 { Thread.sleep(forTimeInterval: listingDelay) }
            return []
        }
    }

    /// Creates `$TMPDIR/tursora-<suite>-<UUID>` for a suite's files; callers
    /// remove it when done (the AGENTS.md cleanup command matches the prefix).
    static func temporaryDirectory(_ suite: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tursora-\(suite)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `FileOperations.compress` as an async call for fixture construction.
    static func compress(_ urls: [URL], to directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            FileOperations.compress(urls: urls, to: directory) { continuation.resume(with: $0) }
        }
    }
}

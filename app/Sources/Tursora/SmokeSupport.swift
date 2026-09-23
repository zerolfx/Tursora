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

    /// A ZIP whose first entry is plain, whose second is password-protected
    /// with ZipCrypto, and whose third is plain again. The pre-flight reads
    /// only the first local header, so this is the shape that got past it: its
    /// directory batch used to leave the encrypted member as a correctly-sized,
    /// zero-filled file that listed as readable. Built with Info-ZIP's own
    /// `/usr/bin/zip`, because it is real encryption rather than a flag.
    static func mixedEncryptionZip(in directory: URL) throws -> URL {
        try infoZip([("d/a.txt", "plain one", nil), ("d/b.txt", "SECRET", "pw"), ("d/c.txt", "plain three", nil)],
                    in: directory)
    }

    /// Build a ZIP one member at a time with Info-ZIP's `/usr/bin/zip`, in the
    /// order given, encrypting a member with ZipCrypto when it has a password.
    /// Real encryption, not a flag set on plaintext.
    static func infoZip(_ members: [(path: String, contents: String, password: String?)],
                        in directory: URL) throws -> URL {
        let fm = FileManager.default
        let staging = directory.appendingPathComponent("zip-source-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for member in members {
            let file = staging.appendingPathComponent(member.path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(member.contents.utf8).write(to: file)
        }
        let archive = directory.appendingPathComponent("infozip-\(UUID().uuidString).zip")
        for member in members {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = staging
            process.arguments = ["-q"] + (member.password.map { ["-P", $0] } ?? []) + [archive.path, member.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw SmokeFailure("zip failed on \(member.path)") }
        }
        return archive
    }

    /// A ZIP holding one ordinary entry and one that resolves outside the
    /// archive root. bsdtar refuses the second; the first must still browse.
    static func zipWithParentTraversal() -> Data {
        zip([("safe.txt", "safe"), ("up/../escape.txt", "escaped")])
    }

    /// A minimal ZIP writer, for fixtures a real archiver will not produce.
    static func zip(_ entries: [(name: String, contents: String)]) -> Data {
        var data = Data(), central = Data()
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        for entry in entries {
            let name = Data(entry.name.utf8), payload = Data(entry.contents.utf8)
            let offset = UInt32(data.count)
            var crc: UInt32 = 0xffffffff
            for byte in payload {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            }
            crc ^= 0xffffffff
            for (signature, isCentral) in [(UInt32(0x04034b50), false), (UInt32(0x02014b50), true)] {
                var block = Data()
                append(signature, to: &block)
                if isCentral { append(UInt16(20), to: &block) }
                append(UInt16(20), to: &block)          // version needed
                append(UInt16(0), to: &block)           // flags
                append(UInt16(0), to: &block)           // stored
                append(UInt32(0), to: &block)           // time/date
                append(crc, to: &block)
                append(UInt32(payload.count), to: &block)
                append(UInt32(payload.count), to: &block)
                append(UInt16(name.count), to: &block)
                append(UInt16(0), to: &block)           // extra
                if isCentral {
                    append(UInt16(0), to: &block)       // comment
                    append(UInt16(0), to: &block)       // disk
                    append(UInt16(0), to: &block)       // internal attrs
                    append(UInt32(0o100644 << 16), to: &block)
                    append(offset, to: &block)
                }
                block.append(name)
                if isCentral { central.append(block) } else { data.append(block); data.append(payload) }
            }
        }
        let centralOffset = UInt32(data.count)
        data.append(central)
        append(UInt32(0x06054b50), to: &data)
        append(UInt16(0), to: &data); append(UInt16(0), to: &data)
        append(UInt16(entries.count), to: &data); append(UInt16(entries.count), to: &data)
        append(UInt32(central.count), to: &data); append(centralOffset, to: &data)
        append(UInt16(0), to: &data)
        return data
    }

    /// `FileOperations.compress` as an async call for fixture construction.
    static func compress(_ urls: [URL], to directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            FileOperations.compress(urls: urls, to: directory) { continuation.resume(with: $0) }
        }
    }
}

/// Holds a worker thread at a point the suite chooses until it is released,
/// giving up after ten seconds so a failed check cannot hang the run.
final class WorkerGate: @unchecked Sendable {
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

/// A drag in progress, as a drop target sees it, carrying a pasteboard the
/// suite filled — for asking a view's validate-drop without a real drag.
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation
    init(pasteboard: NSPasteboard, mask: NSDragOperation = .copy) {
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = mask
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

extension SmokeFixtures {
    /// Brings archive entries to disk off the main thread, as every caller in
    /// the app does: the suite must not run the archive tool on the main
    /// thread either, or its main-thread count means nothing (D102).
    static func materialize(_ session: ArchiveBrowsingSession, _ paths: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try session.materializer.materialize(session.tree.batchPlan(for: paths, skipping: session.materializer.settledPaths))
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

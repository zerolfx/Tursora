import Foundation
import Darwin

/// Cancels only one private browsing extraction. The worker still waits for
/// its child to exit before removing any directory the child could write to.
final class ArchivePreparationCancellation: @unchecked Sendable {
    enum Checkpoint { case storageCreated(URL), beforeExtraction, beforePublication }
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private let checkpointHandler: (@Sendable (Checkpoint) -> Void)?

    init(checkpoint: (@Sendable (Checkpoint) -> Void)? = nil) { checkpointHandler = checkpoint }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        // terminate sends a signal; it never waits for process completion.
        if let running, running.isRunning { running.terminate() }
    }

    func checkCancellation() throws {
        if isCancelled { throw ArchiveBrowsingSession.SessionError.cancelled }
    }

    func checkpoint(_ point: Checkpoint) throws {
        try checkCancellation()
        checkpointHandler?(point)
        try checkCancellation()
    }

    func runProcess(_ child: Process) throws {
        try checkCancellation()
        try child.run()
        lock.lock()
        process = child
        let shouldStop = cancelled
        lock.unlock()
        // Cancellation may arrive while Process.run is starting the child.
        if shouldStop, child.isRunning { child.terminate() }
    }

    func finishProcess(_ child: Process) {
        lock.lock(); defer { lock.unlock() }
        if process === child { process = nil }
    }
}

/// Determinate progress for an extraction in flight. The tool's own verbose
/// stream drives it, so there is no second source of truth to disagree with
/// what is actually being written (D90).
struct ArchiveToolProgress {
    let listing: [ArchiveEntrySummary]
    /// Where the tool writes; the entry being extracted is measured under it.
    let outputRoot: URL
    var pollInterval: TimeInterval = 0.05
    /// Called on the worker thread, not the main queue.
    let onProgress: (_ completedBytes: Int64, _ totalBytes: Int64?, _ entry: ArchiveEntrySummary?) -> Void
    /// False asks the tool to stop.
    let isCancelled: () -> Bool
}

extension FileOperations {
    enum ArchiveError: LocalizedError {
        case noSelection, duplicateNames, destinationInsideSelection, unsupportedArchive, invalidArchive, emptyArchive
        case encryptedArchive
        case cancelled
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSelection: return "Select at least one item to compress."
            case .duplicateNames: return "Items with the same name cannot be added to one archive."
            case .destinationInsideSelection: return "Choose a destination outside the folders being compressed."
            case .unsupportedArchive: return "Only ZIP archives can be extracted here."
            case .invalidArchive: return "This file does not appear to be a valid ZIP archive."
            case .emptyArchive: return "The archive contains no files."
            case .encryptedArchive: return "This ZIP is password-protected and cannot be opened here."
            case .cancelled: return "The extraction was cancelled."
            case .commandFailed(let message): return message
            }
        }
    }

    /// Keep the original extension: Finder compresses report.txt as report.txt.zip.
    static func archiveName(for urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent + ".zip" : "Archive.zip"
    }

    static func canExtractArchive(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "zip"
    }

    /// Work is isolated from user files; only the completed ZIP is published.
    static func compress(urls: [URL], to directory: URL,
                         completion: @escaping (Result<URL, Error>) -> Void) {
        archiveOperation(completion: completion) {
            guard !urls.isEmpty else { throw ArchiveError.noSelection }
            let names = urls.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
            guard Set(names).count == urls.count else { throw ArchiveError.duplicateNames }
            let destination = directory.resolvingSymlinksInPath().standardizedFileURL
            for source in urls {
                let sourceComponents = source.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                guard !destination.pathComponents.starts(with: sourceComponents) else {
                    throw ArchiveError.destinationInsideSelection
                }
            }
            return try withArchiveWorkspace(in: directory) { workspace in
                let input = workspace.appendingPathComponent("input", isDirectory: true)
                try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
                for source in urls {
                    // FileManager copies symlinks themselves, never their target trees.
                    try FileManager.default.copyItem(at: source, to: input.appendingPathComponent(source.lastPathComponent))
                }
                let output = workspace.appendingPathComponent("result.zip")
                try runArchiveTool("/usr/bin/ditto", arguments: ["-c", "-k", "--rsrc", "--sequesterRsrc", input.path, output.path], workspace: workspace)
                return try publishArchiveItem(output, named: archiveName(for: urls), in: directory)
            }
        }
    }

    /// libarchive's default traversal protection stays enabled (never -P or -U).
    /// No existing destination is used as an extraction root or replaced.
    static func extract(archive: URL, to directory: URL,
                        completion: @escaping (Result<URL, Error>) -> Void) {
        extract(archive: archive, to: directory, preserveRoot: false, completion: completion)
    }

    /// Extract with determinate progress and cancellation, for the explicit
    /// Extract command. The three-argument `extract` above is unchanged and
    /// still used where no progress is wanted.
    static func extract(archive: URL, to directory: URL,
                        listing: ArchiveListing,
                        onProgress: @escaping (_ completedBytes: Int64, _ totalBytes: Int64?, _ entry: String?) -> Void,
                        isCancelled: @escaping () -> Bool,
                        pollInterval: TimeInterval = 0.05,
                        completion: @escaping (Result<URL, Error>) -> Void) {
        archiveOperation(completion: completion) {
            guard canExtractArchive(archive) else { throw ArchiveError.unsupportedArchive }
            try checkExtractionSignature(archive)
            if isCancelled() { throw ArchiveError.cancelled }
            // The listing is the tool's own, so it agrees by construction with
            // what the tool will write. A failure here is not fatal: extraction
            // still runs, it just cannot report a percentage.
            let entries = (try? listing.entries(of: archive)) ?? []
            return try withArchiveWorkspace(in: directory) { workspace in
                let output = workspace.appendingPathComponent("contents", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                let progress = ArchiveToolProgress(
                    listing: entries, outputRoot: output, pollInterval: pollInterval,
                    onProgress: { bytes, total, entry in onProgress(bytes, entries.isEmpty ? nil : total, entry?.name) },
                    isCancelled: isCancelled)
                try runArchiveTool("/usr/bin/tar", arguments: extractionArguments(archive: archive, output: output, verbose: true),
                                   workspace: workspace, progress: progress)
                if isCancelled() { throw ArchiveError.cancelled }
                try propagateArchiveQuarantine(from: archive, to: output)
                let items = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
                guard !items.isEmpty else { throw ArchiveError.emptyArchive }
                if isCancelled() { throw ArchiveError.cancelled }
                if items.count == 1, let item = items.first {
                    return try publishArchiveItem(item, named: item.lastPathComponent, in: directory)
                }
                let name = archive.deletingPathExtension().lastPathComponent
                return try publishArchiveItem(output, named: name.isEmpty ? "Archive" : name, in: directory)
            }
        }
    }

    /// The read-only browser needs the exact archive hierarchy, including a
    /// single top-level folder, instead of the normal extraction presentation.
    static func extractArchiveContents(archive: URL, to directory: URL,
                                       cancellation: ArchivePreparationCancellation? = nil,
                                       completion: @escaping (Result<URL, Error>) -> Void) {
        extract(archive: archive, to: directory, preserveRoot: true, cancellation: cancellation, completion: completion)
    }

    private static func extract(archive: URL, to directory: URL, preserveRoot: Bool,
                                cancellation: ArchivePreparationCancellation? = nil,
                                completion: @escaping (Result<URL, Error>) -> Void) {
        archiveOperation(completion: completion) {
            try cancellation?.checkpoint(.beforeExtraction)
            guard canExtractArchive(archive) else { throw ArchiveError.unsupportedArchive }
            try checkExtractionSignature(archive)
            return try withArchiveWorkspace(in: directory) { workspace in
                let output = workspace.appendingPathComponent("contents", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                try runArchiveTool("/usr/bin/tar", arguments: extractionArguments(archive: archive, output: output, verbose: false),
                                   workspace: workspace, cancellation: cancellation)
                try cancellation?.checkCancellation()
                try propagateArchiveQuarantine(from: archive, to: output, cancellation: cancellation)
                let items = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
                try cancellation?.checkpoint(.beforePublication)
                if preserveRoot {
                    return try publishArchiveItem(output, named: "Contents", in: directory)
                }
                guard !items.isEmpty else { throw ArchiveError.emptyArchive }
                if items.count == 1, let item = items.first {
                    return try publishArchiveItem(item, named: item.lastPathComponent, in: directory)
                }
                let name = archive.deletingPathExtension().lastPathComponent
                return try publishArchiveItem(output, named: name.isEmpty ? "Archive" : name, in: directory)
            }
        }
    }

    /// The first four bytes, plus the local header's general-purpose bit flag
    /// when there is one. Encryption has to be refused here rather than
    /// discovered during extraction, because the tool reports it in a way that
    /// is actively dangerous to trust: `tar -tvf` on an encrypted archive exits
    /// **0** with a complete, correct listing, and `tar -x` then exits 1 while
    /// leaving a correctly-sized, entirely zero-filled file at the right path.
    /// Anything that judged success by `fileExists` would serve those zeros to
    /// Quick Look, drag-out and Copy. Measured; see
    /// docs/research/lazy-zip-browsing.md.
    /// The pre-flight the browsing path runs before it creates any storage:
    /// a ZIP by extension, a real ZIP by signature, and not password-protected.
    static func checkArchiveForBrowsing(_ archive: URL) throws {
        guard canExtractArchive(archive) else { throw ArchiveError.unsupportedArchive }
        try checkExtractionSignature(archive)
    }

    private static func checkExtractionSignature(_ archive: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 8), header.count >= 4 else { throw ArchiveError.invalidArchive }
        let signature = header.prefix(4)
        let localFile = Data([0x50, 0x4b, 0x03, 0x04])
        let emptyArchive = Data([0x50, 0x4b, 0x05, 0x06])
        guard signature == localFile || signature == emptyArchive else { throw ArchiveError.invalidArchive }
        // Only a local file header carries the flag; an empty archive has none.
        guard signature == localFile, header.count >= 8 else { return }
        let bytes = [UInt8](header)
        let flags = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        if flags & 0x0001 != 0 { throw ArchiveError.encryptedArchive }
    }

    /// Supplying a passphrase disables bsdtar's interactive callback entirely.
    /// Encryption is unsupported; a random value makes encrypted archives fail
    /// without opening /dev/tty, which redirecting stdin alone cannot prevent.
    /// `-v` is added only when something is reading the stream: the ZIP
    /// browsing path keeps a clean error log.
    private static func extractionArguments(archive: URL, output: URL, verbose: Bool,
                                            memberList: URL? = nil, noRecursion: Bool = false,
                                            excludes: [String] = []) -> [String] {
        var arguments = ["-x"]
        if verbose { arguments.append("-v") }
        // `-n` stops a leaf's name prefix-matching a deeper entry: a member
        // `clash` otherwise also tries `clash/inside.txt` and reports an error
        // (measured). It must NOT be used for a directory or a package — a ZIP
        // need store no directory record, and with `-n` such a member is
        // "Not found in archive". `-q`/`--fast-read` must never be used at all:
        // it stops at the first match and silently truncates a subtree.
        if noRecursion { arguments.append("-n") }
        arguments += [
            "-f", archive.path, "-C", output.path,
            "--no-same-owner", "--no-same-permissions", "--mac-metadata", "--no-acls", "--no-fflags",
            "--passphrase", UUID().uuidString,
        ]
        // Excludes before the member list, as options: bsdtar stops reading
        // options at the first positional pattern.
        for exclude in excludes { arguments += ["--exclude", exclude] }
        // A member list goes through a file, never argv: ARG_MAX is 1 MiB and a
        // directory can hold more names than that.
        if let memberList { arguments += ["-T", memberList.path] }
        return arguments
    }

    /// Extract exactly the named members of an archive into `output`.
    ///
    /// Two measured properties shape this and must not be softened.
    /// **Exit status is archive-wide**: a batch of two members where one is
    /// missing exits 1 *and* writes the other, so a non-zero status does not
    /// mean nothing happened. And **existence is never evidence of success**:
    /// a member of an encrypted archive exits 1 while leaving a correctly-sized,
    /// entirely zero-filled file at the right path. Callers get the tool's own
    /// stderr so they can tell which members failed and remove their debris.
    /// `scratch` holds the member list and the tool's error log. It must sit
    /// **beside** the extraction root, never inside it: anything written under
    /// the root, even briefly and even hidden, is part of what the user is
    /// browsing.
    static func materializeArchiveMembers(archive: URL, into output: URL, scratch: URL,
                                          members: [String], noRecursion: Bool, excluding excludes: [String] = [],
                                          cancellation: ArchivePreparationCancellation? = nil) throws {
        guard !members.isEmpty else { return }
        let workspace = scratch.appendingPathComponent(".tursora-materialize-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let list = workspace.appendingPathComponent("members.lst")
        try Data((members.joined(separator: "\n") + "\n").utf8).write(to: list)
        try runArchiveTool("/usr/bin/tar",
                           arguments: extractionArguments(archive: archive, output: output, verbose: false,
                                                          memberList: list, noRecursion: noRecursion,
                                                          excludes: excludes),
                           workspace: workspace, cancellation: cancellation)
    }

    private static func archiveOperation(completion: @escaping (Result<URL, Error>) -> Void,
                                         work: @escaping () throws -> URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// An extracted application must retain the downloaded archive's quarantine.
    /// Never follow extracted symlinks while setting metadata on the new tree.
    static func propagateArchiveQuarantine(from archive: URL, to root: URL,
                                                    cancellation: ArchivePreparationCancellation? = nil) throws {
        try cancellation?.checkCancellation()
        let attribute = "com.apple.quarantine"
        let length = getxattr(archive.path, attribute, nil, 0, 0, 0)
        if length < 0 {
            if errno == ENOATTR || errno == ENOTSUP { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard length > 0 else { return }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(archive.path, attribute, $0.baseAddress, length, 0, 0) }
        guard read == length else { throw POSIXError(.EIO) }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationError = error; return false }) else { throw POSIXError(.EIO) }
        func mark(_ url: URL) throws {
            try cancellation?.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return }
            let outcome = data.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
            if outcome != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try mark(root)
        for case let url as URL in enumerator { try mark(url) }
        if let enumerationError { throw enumerationError }
    }

    private static func withArchiveWorkspace(in directory: URL, work: (URL) throws -> URL) throws -> URL {
        let workspace = directory.appendingPathComponent(".tursora-archive-" + UUID().uuidString, isDirectory: true)
        // Same volume as the destination: publication is a single exclusive rename.
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        return try work(workspace)
    }

    private static func runArchiveTool(_ executable: String, arguments: [String], workspace: URL,
                                        cancellation: ArchivePreparationCancellation? = nil,
                                        progress: ArchiveToolProgress? = nil) throws {
        let log = workspace.appendingPathComponent("tool-errors.txt")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // A regular file cannot fill a pipe and deadlock waitUntilExit().
        process.standardError = errors
        // Ignore inherited tool-specific switches such as TAR_READER_OPTIONS.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        if let cancellation { try cancellation.runProcess(process) }
        else { try process.run() }
        defer { cancellation?.finishProcess(process) }
        var cancelledByReporter = false
        if let progress {
            // The tool's `-v` output goes to stderr, which is already a regular
            // file here — deliberately, so a full pipe can never deadlock
            // waitUntilExit(). Polling that file adds no pipe and keeps that
            // property. The loop always falls through to waitUntilExit() below,
            // so the child is reaped whichever way it ends.
            cancelledByReporter = followProgress(progress, log: log, process: process)
        }
        process.waitUntilExit()
        if cancelledByReporter { throw ArchiveError.cancelled }
        try cancellation?.checkCancellation()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: log)
            defer { try? reader.close() }
            let raw = String(data: (try? reader.read(upToCount: 64 * 1024)) ?? Data(), encoding: .utf8) ?? ""
            // With `-v` the log also carries one line per extracted entry. Only
            // whole known names are dropped: a traversal refusal is reported as
            // "x ../../outside.txt: Path contains '..'", which also starts "x ".
            let detail = progress.map { ArchiveExtractionProgress.errorDetail(from: raw, knownEntries: Set($0.listing.map(\.name))) }
                ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.commandFailed(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The archive could not be processed.")
        }
    }

    /// Returns true when the reporter asked to stop. Reads only the new tail of
    /// the log each pass, so a long extraction does not re-scan its own output.
    private static func followProgress(_ progress: ArchiveToolProgress, log: URL, process: Process) -> Bool {
        var tracker = ArchiveExtractionProgress(entries: progress.listing)
        var offset: UInt64 = 0
        var partial = ""
        progress.onProgress(0, tracker.totalBytes, nil)

        func drain() {
            guard let reader = try? FileHandle(forReadingFrom: log) else { return }
            defer { try? reader.close() }
            try? reader.seek(toOffset: offset)
            guard let data = try? reader.readToEnd(), !data.isEmpty else { return }
            offset += UInt64(data.count)
            partial += String(decoding: data, as: UTF8.self)
            // Keep the last fragment: the tool may be mid-line.
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()
            for line in lines { tracker.consume(verboseLine: line) }
        }

        func report() {
            // Read-after-write of a file being appended to goes through
            // FileManager; URL.resourceValues caches for the run-loop pass and
            // the reported size would stop moving (AGENTS.md rule 5).
            var current: Int64 = 0
            if let url = tracker.currentEntryURL(in: progress.outputRoot),
               let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
                current = size.int64Value
            }
            progress.onProgress(tracker.completedBytes(currentFileSize: current), tracker.totalBytes, tracker.currentEntry)
        }

        while process.isRunning {
            if progress.isCancelled() {
                if process.isRunning { process.terminate() }
                return true
            }
            drain()
            report()
            Thread.sleep(forTimeInterval: max(0.01, progress.pollInterval))
        }
        drain()
        report()
        return false
    }

    /// RENAME_EXCL closes the check-then-rename race, including dangling symlinks.
    private static func publishArchiveItem(_ source: URL, named name: String, in directory: URL) throws -> URL {
        let original = directory.appendingPathComponent(name)
        var candidate = original
        var number = 2
        while true {
            let outcome = source.withUnsafeFileSystemRepresentation { src in
                candidate.withUnsafeFileSystemRepresentation { dst in
                    renamex_np(src!, dst!, UInt32(RENAME_EXCL))
                }
            }
            if outcome == 0 { return candidate }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            let ext = original.pathExtension
            let base = original.deletingPathExtension().lastPathComponent
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
    }
}

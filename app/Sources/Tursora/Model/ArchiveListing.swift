import Foundation

/// One entry of an archive, as the tool that will extract it reports it.
struct ArchiveEntrySummary: Equatable {
    enum Kind { case file, directory, symbolicLink }
    /// The tool's own spelling of the path. This is the match key for the
    /// verbose stream during extraction, so it must not be normalized.
    let name: String
    let uncompressedSize: Int64
    let kind: Kind
    /// The owner's execute bit, from the listing's mode. Extraction keeps it
    /// (the umask only touches group and other), and it is what makes an
    /// extensionless file a "Unix Executable File" rather than a "Document".
    var isExecutable: Bool = false
    /// Directories and symbolic links occupy no extracted bytes worth counting;
    /// a symlink is listed as size 0 regardless.
    var countsTowardBytes: Bool { kind == .file }
}

/// Why a listing could not be produced. Extraction progress treats any failure
/// as "no total" and carries on; browsing has to tell the user, so the reasons
/// are distinct rather than an empty array.
enum ArchiveListingError: LocalizedError {
    /// The tool refused the archive. Carries its own message where it gave one.
    case damaged(String?)
    /// More entries than a listing is allowed to hold in memory at once.
    case tooManyEntries(Int)

    var errorDescription: String? {
        switch self {
        case .damaged(let detail):
            return detail.flatMap { $0.isEmpty ? nil : $0 } ?? "This ZIP archive could not be read."
        case .tooManyEntries(let limit):
            return "This ZIP contains more than \(limit) items, which is too many to browse."
        }
    }
}

/// Reads an archive's table of contents without extracting it.
///
/// Deliberately not a ZIP parser. Extraction progress is only meaningful if the
/// listing agrees with what the extractor will actually write, and the only
/// source guaranteed to agree with bsdtar is bsdtar's own listing — including
/// its `__MACOSX` AppleDouble folding, which `unzip -Z1` reports differently
/// (D90). A future native reader for lazy ZIP browsing can adopt this protocol.
protocol ArchiveListing {
    func entries(of archive: URL) throws -> [ArchiveEntrySummary]
}

/// Parses `tar -tvf`'s long listing. Pure, so the shapes that matter — a
/// symbolic link's ` -> target` suffix, a name containing spaces, a name
/// containing non-ASCII — are all covered without running a process.
enum BSDTarListingParser {
    /// `-rw-r--r--  0 501    0      307200 Sep 22 19:42 sub/with space.txt`
    ///
    /// Nine fields: mode, link count, uid, gid, size, month, day, time-or-year,
    /// then the name — which may itself contain spaces, so the split stops at
    /// eight. `LANG` is pinned to `en_US.UTF-8` by the caller, which is what
    /// keeps the date three fields wide.
    static func entry(from line: String) -> ArchiveEntrySummary? {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count == 9, let mode = parts[0].first, let size = Int64(parts[4]) else { return nil }
        var name = String(parts[8])
        let kind: ArchiveEntrySummary.Kind
        switch mode {
        case "d": kind = .directory
        case "l":
            kind = .symbolicLink
            // The arrow belongs to the listing, not to the name. Keyed on the
            // mode character, never on a " -> " substring: a regular file may
            // legitimately be called "a -> b.txt", and dropping its suffix
            // would make its name never match the extraction stream.
            if let arrow = name.range(of: " -> ", options: .backwards) { name = String(name[..<arrow.lowerBound]) }
        default: kind = .file
        }
        guard !name.isEmpty else { return nil }
        // `-rwxr-xr-x`: the owner's execute slot is the fourth character, and
        // `s` there is setuid over an execute bit (`S` is setuid without one).
        let modeCharacters = Array(parts[0])
        let executable = kind == .file && modeCharacters.count > 3 && "xs".contains(modeCharacters[3])
        return ArchiveEntrySummary(name: name, uncompressedSize: max(0, size), kind: kind, isExecutable: executable)
    }

    static func entries(from listing: String) -> [ArchiveEntrySummary] {
        listing.split(separator: "\n", omittingEmptySubsequences: true).compactMap { entry(from: String($0)) }
    }
}

/// `tar -tvf`, run with the same hardening as the extraction itself: a pinned
/// environment (LANG also fixes the date column count the parser depends on),
/// no inherited stdin, and a passphrase so an encrypted archive fails instead
/// of opening /dev/tty. Output goes to a regular file, never a pipe.
struct BSDTarArchiveListing: ArchiveListing {
    /// A listing only has to bound memory, not the archive. Measured at 75.6
    /// bytes per entry, so this is the honest limit rather than a byte count
    /// the caller cannot reason about. Matches `FolderSizes`' own entry limit.
    static let maximumEntries = 500_000
    /// Read in chunks and parse complete lines, so a very large listing is
    /// never one String and a half-written last line is never half-parsed.
    static let readChunkBytes = 1 << 20

    func entries(of archive: URL) throws -> [ArchiveEntrySummary] {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("tursora-listing-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let output = workspace.appendingPathComponent("listing.txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        // The tool's own complaint is the only useful message for a damaged
        // archive, so stderr goes to a regular file rather than to nowhere.
        // A regular file cannot fill and deadlock waitUntilExit(); a pipe can.
        let log = workspace.appendingPathComponent("tool-errors.txt")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // --mac-metadata is rejected in -t mode; --passphrase is accepted.
        process.arguments = ["-tvf", archive.path, "--passphrase", UUID().uuidString]
        process.standardInput = FileHandle.nullDevice
        // A regular file cannot fill a pipe and deadlock waitUntilExit().
        process.standardOutput = handle
        process.standardError = errors
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            throw ArchiveListingError.damaged(Self.toolMessage(in: log))
        }
        return try Self.parse(output)
    }

    /// Parse complete lines out of the listing file a chunk at a time. Holding
    /// only the unterminated tail means a truncated final line can never be
    /// parsed into a half-built entry.
    static func parse(_ output: URL) throws -> [ArchiveEntrySummary] {
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        var entries: [ArchiveEntrySummary] = []
        var pending = ""
        func take(_ line: String) throws {
            guard let entry = BSDTarListingParser.entry(from: line) else { return }
            guard entries.count < maximumEntries else { throw ArchiveListingError.tooManyEntries(maximumEntries) }
            entries.append(entry)
        }
        while let chunk = try reader.read(upToCount: readChunkBytes), !chunk.isEmpty {
            pending += String(decoding: chunk, as: UTF8.self)
            var lines = pending.components(separatedBy: "\n")
            pending = lines.removeLast()
            for line in lines { try take(line) }
        }
        if !pending.isEmpty { try take(pending) }
        return entries
    }

    private static func toolMessage(in log: URL) -> String? {
        guard let reader = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: 4096)) ?? Data()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

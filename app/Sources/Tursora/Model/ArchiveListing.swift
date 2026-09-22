import Foundation

/// One entry of an archive, as the tool that will extract it reports it.
struct ArchiveEntrySummary: Equatable {
    enum Kind { case file, directory, symbolicLink }
    /// The tool's own spelling of the path. This is the match key for the
    /// verbose stream during extraction, so it must not be normalized.
    let name: String
    let uncompressedSize: Int64
    let kind: Kind
    /// Directories and symbolic links occupy no extracted bytes worth counting;
    /// a symlink is listed as size 0 regardless.
    var countsTowardBytes: Bool { kind == .file }
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
        return ArchiveEntrySummary(name: name, uncompressedSize: max(0, size), kind: kind)
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
    /// A listing only has to bound memory, not the archive: a ZIP with a
    /// million entries would otherwise be read into a single String.
    static let maximumListingBytes = 8 * 1024 * 1024

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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // --mac-metadata is rejected in -t mode; --passphrase is accepted.
        process.arguments = ["-tvf", archive.path, "--passphrase", UUID().uuidString]
        process.standardInput = FileHandle.nullDevice
        // A regular file cannot fill a pipe and deadlock waitUntilExit().
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else { return [] }

        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: Self.maximumListingBytes)) ?? Data()
        // A truncated listing would under-report the total and leave the bar
        // short of 100%; report nothing and let the caller go indeterminate.
        if data.count >= Self.maximumListingBytes { return [] }
        return BSDTarListingParser.entries(from: String(decoding: data, as: UTF8.self))
    }
}

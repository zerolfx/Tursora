import Foundation
import Darwin

/// Isolated model checks; the main smoke sequence owns the UI-path checks.
enum ArchiveSmokeTests: SmokeSuite {
    static func run(completion: @escaping () -> Void) {
        Task {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("tursora-archive-tests-" + UUID().uuidString)
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: false)
                defer { try? fm.removeItem(at: root) }
                print("== archive operations ==")
                let first = root.appendingPathComponent("-報告 copy.txt")
                let second = root.appendingPathComponent("second file.txt")
                try Data("first contents\n".utf8).write(to: first)
                try Data("second contents\n".utf8).write(to: second)
                check("archive: single name retains its extension", FileOperations.archiveName(for: [first]) == "-報告 copy.txt.zip")
                check("archive: multiple items use Archive.zip", FileOperations.archiveName(for: [first, second]) == "Archive.zip")
                check("archive: ZIP detection is case insensitive", FileOperations.canExtractArchive(root.appendingPathComponent("sample.ZIP")) && !FileOperations.canExtractArchive(second))

                let existingZIP = root.appendingPathComponent("-報告 copy.txt.zip")
                try Data("do not replace".utf8).write(to: existingZIP)
                let single = try await compress([first], to: root).get()
                check("archive: compression avoids an existing ZIP", single.lastPathComponent == "-報告 copy.txt 2.zip" && contents(existingZIP) == "do not replace")
                let extracted = try await extract(single, to: root).get()
                check("archive: extraction avoids an existing source", extracted.lastPathComponent == "-報告 copy 2.txt" && contents(first) == "first contents\n")
                check("archive: Unicode, spaces and leading dashes round trip", contents(extracted) == "first contents\n")
                check("archive: extraction preserves the archive", fm.fileExists(atPath: single.path))

                let multi = try await compress([first, second], to: root).get()
                check("archive: multiple selected items compress together", multi.lastPathComponent == "Archive.zip")
                let multiOutput = try await extract(multi, to: root).get()
                check("archive: multiple roots are contained in an archive-named folder", multiOutput.lastPathComponent == "Archive" && contents(multiOutput.appendingPathComponent(first.lastPathComponent)) == "first contents\n" && contents(multiOutput.appendingPathComponent(second.lastPathComponent)) == "second contents\n")
                let nextMulti = try await extract(multi, to: root).get()
                check("archive: extraction never merges into an existing folder", nextMulti.lastPathComponent == "Archive 2" && contents(multiOutput.appendingPathComponent(second.lastPathComponent)) == "second contents\n")

                let folder = root.appendingPathComponent("Project.v1", isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                try Data("nested".utf8).write(to: folder.appendingPathComponent("nested.txt"))
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("nested.txt").path)
                try fm.createSymbolicLink(atPath: folder.appendingPathComponent("shortcut").path, withDestinationPath: "nested.txt")
                let resource = Data("resource-fork".utf8)
                let resourceMark = resource.withUnsafeBytes { setxattr(folder.appendingPathComponent("nested.txt").path, "com.apple.ResourceFork", $0.baseAddress, resource.count, 0, 0) }
                guard resourceMark == 0 else { throw POSIXError(.EIO) }
                let folderZIP = try await compress([folder], to: root).get()
                let quarantine = Data("0083;65000000;TursoraSmokeTest;".utf8)
                let mark = quarantine.withUnsafeBytes { setxattr(folderZIP.path, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, 0) }
                guard mark == 0 else { throw POSIXError(.EIO) }
                let folderOutput = try await extract(folderZIP, to: root).get()
                check("archive: a single root folder is not double wrapped", contents(folderOutput.appendingPathComponent("nested.txt")) == "nested")
                check("archive: ordinary relative symlinks survive", (try? fm.destinationOfSymbolicLink(atPath: folderOutput.appendingPathComponent("shortcut").path)) == "nested.txt")
                let mode = try fm.attributesOfItem(atPath: folderOutput.appendingPathComponent("nested.txt").path)[.posixPermissions] as? NSNumber
                check("archive: executable permission survives extraction", mode.map { $0.intValue & 0o111 == 0o111 } == true)
                var restoredResource = Data(count: resource.count)
                let resourceRead = restoredResource.withUnsafeMutableBytes { getxattr(folderOutput.appendingPathComponent("nested.txt").path, "com.apple.ResourceFork", $0.baseAddress, resource.count, 0, 0) }
                check("archive: macOS resource forks survive extraction", resourceRead == resource.count && restoredResource == resource)
                var inherited = Data(count: quarantine.count)
                let read = inherited.withUnsafeMutableBytes { getxattr(folderOutput.appendingPathComponent("nested.txt").path, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, 0) }
                check("archive: downloaded archive quarantine reaches extracted contents", read == quarantine.count && inherited == quarantine)

                let dangling = root.appendingPathComponent("standalone.txt")
                try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: "does-not-exist")
                let validFixture = root.appendingPathComponent("standalone.zip")
                try zip([Entry("standalone.txt", "new")]).write(to: validFixture)
                let safeOutput = try await extract(validFixture, to: root).get()
                check("archive: a dangling destination symlink is not overwritten", safeOutput.lastPathComponent == "standalone 2.txt" && (try? fm.destinationOfSymbolicLink(atPath: dangling.path)) == "does-not-exist")

                let sentinel = root.appendingPathComponent("outside.txt")
                try Data("protected".utf8).write(to: sentinel)
                let badDestination = root.appendingPathComponent("rejected", isDirectory: true)
                try fm.createDirectory(at: badDestination, withIntermediateDirectories: false)
                let invalid: [(String, Data)] = [
                    ("parent traversal", zip([Entry("safe.txt", "partial"), Entry("../../outside.txt", "overwrite")])),
                    ("symlink traversal", zip([Entry("link", root.path, mode: 0o120777), Entry("link/outside.txt", "overwrite")])),
                    ("corrupt archive", Data("PK\u{3}\u{4}corrupt".utf8)),
                    ("encrypted archive", zip([Entry("secret.txt", "not encrypted data", flags: 1)])),
                    ("empty archive", zip([]))
                ]
                for (label, data) in invalid {
                    let fixture = root.appendingPathComponent(label + ".zip")
                    try data.write(to: fixture)
                    let result = await extract(fixture, to: badDestination)
                    check("archive: rejects \(label)", isFailure(result))
                    check("archive: \(label) leaves no partial output or changed originals", (try fm.contentsOfDirectory(atPath: badDestination.path)).isEmpty && contents(sentinel) == "protected" && (try? Data(contentsOf: fixture)) == data)
                }

                let emptySelection = await compress([], to: badDestination)
                check("archive: an empty selection fails without output", isFailure(emptySelection) && (try? fm.contentsOfDirectory(atPath: badDestination.path)) == [])
                let recursive = await compress([root], to: badDestination)
                check("archive: cannot stage inside a selected folder", isFailure(recursive) && (try? fm.contentsOfDirectory(atPath: badDestination.path)) == [])
                let missing = await compress([root.appendingPathComponent("missing")], to: badDestination)
                check("archive: missing source cleanup leaves no temporary files", isFailure(missing) && (try? fm.contentsOfDirectory(atPath: badDestination.path)) == [])

                // Concurrent publication must neither overwrite nor lose either result.
                async let one = compress([second], to: badDestination)
                async let two = compress([second], to: badDestination)
                let a = try await one.get(), b = try await two.get()
                check("archive: concurrent compression publishes two distinct results", a != b && Set([a.lastPathComponent, b.lastPathComponent]) == Set(["second file.txt.zip", "second file.txt 2.zip"]))
                check("archive: successful operations clean their workspaces", !(try fm.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".tursora-archive-") } && (try? fm.contentsOfDirectory(atPath: badDestination.path).contains { $0.hasPrefix(".tursora-archive-") }) == false)

                listingParser()
                progressAccounting()
                try await extractionProgress(archive: folderZIP, root: root)

                try fm.removeItem(at: root)
                DispatchQueue.main.async { completion() }
            } catch {
                try? fm.removeItem(at: root)
                check("archive: unexpected operation error", false, error.localizedDescription)
            }
        }
    }

    /// `tar -tvf`'s long listing, parsed without running a process. The shapes
    /// that matter are a symbolic link's ` -> target` suffix, a name with
    /// spaces, and a name that legitimately contains an arrow.
    private static func listingParser() {
        let file = BSDTarListingParser.entry(from: "-rw-r--r--  0 501    0      307200 Sep 22 19:42 big.bin")
        check("archive: a file line yields its name, size and kind",
              file == ArchiveEntrySummary(name: "big.bin", uncompressedSize: 307_200, kind: .file), "\(String(describing: file))")
        let spaced = BSDTarListingParser.entry(from: "-rw-r--r--  0 501    0           1 Sep 22 19:42 sub/with space.txt")
        check("archive: a name containing spaces survives the split",
              spaced?.name == "sub/with space.txt", spaced?.name ?? "nil")
        let unicode = BSDTarListingParser.entry(from: "-rw-r--r--  0 501    0           5 Sep 22 19:42 sub/中文文件.txt")
        check("archive: a non-ASCII name is not mangled", unicode?.name == "sub/中文文件.txt", unicode?.name ?? "nil")
        let link = BSDTarListingParser.entry(from: "lrwxr-xr-x  0 0      0           0 Sep 22 19:42 link.bin -> a.bin")
        check("archive: a symlink line drops the arrow and is not counted in bytes",
              link == ArchiveEntrySummary(name: "link.bin", uncompressedSize: 0, kind: .symbolicLink) && link?.countsTowardBytes == false,
              "\(String(describing: link))")
        // Keyed on the mode character, never on a " -> " substring: dropping the
        // suffix here would stop the name ever matching the extraction stream.
        let arrowNamed = BSDTarListingParser.entry(from: "-rw-r--r--  0 501    0           3 Sep 22 19:42 a -> b.txt")
        check("archive: a regular file named with an arrow keeps its whole name",
              arrowNamed?.name == "a -> b.txt" && arrowNamed?.kind == .file, arrowNamed?.name ?? "nil")
        let directory = BSDTarListingParser.entry(from: "drwxr-xr-x  0 501    0           0 Sep 22 19:42 sub/")
        check("archive: a directory line is not counted in bytes",
              directory?.kind == .directory && directory?.countsTowardBytes == false)
        check("archive: a line that is not a listing entry is ignored",
              BSDTarListingParser.entry(from: "tar: Error exit delayed from previous errors.") == nil
              && BSDTarListingParser.entry(from: "") == nil)
    }

    /// Progress accounting, with no I/O at all.
    private static func progressAccounting() {
        let entries = [
            ArchiveEntrySummary(name: "a.bin", uncompressedSize: 100, kind: .file),
            ArchiveEntrySummary(name: "link", uncompressedSize: 0, kind: .symbolicLink),
            ArchiveEntrySummary(name: "dir/", uncompressedSize: 0, kind: .directory),
            ArchiveEntrySummary(name: "dir/b.bin", uncompressedSize: 400, kind: .file),
        ]
        var progress = ArchiveExtractionProgress(entries: entries)
        check("archive: the total counts files only, not links or directories", progress.totalBytes == 500, "\(String(describing: progress.totalBytes))")
        check("archive: nothing announced means nothing completed", progress.completedBytes() == 0)
        progress.consume(verboseLine: "x a.bin")
        // An entry is announced when it is OPENED, so it is in progress, not done.
        check("archive: the announced entry counts as in progress, not finished",
              progress.completedBytes() == 0 && progress.completedBytes(currentFileSize: 40) == 40)
        check("archive: a file measured larger than listed never passes its own size",
              progress.completedBytes(currentFileSize: 10_000) == 100)
        progress.consume(verboseLine: "x link")
        progress.consume(verboseLine: "x dir/")
        check("archive: the previous entry settles in full once the next is announced",
              progress.completedBytes() == 100, "\(progress.completedBytes())")
        progress.consume(verboseLine: "x dir/b.bin")
        check("archive: progress never exceeds the total",
              progress.completedBytes(currentFileSize: 999_999) == 500)

        var unknown = ArchiveExtractionProgress(entries: entries)
        unknown.consume(verboseLine: "x surprise.bin")
        check("archive: an entry the listing never mentioned makes the total unknown", unknown.totalBytes == nil)

        let empty = ArchiveExtractionProgress(entries: [])
        check("archive: an unusable listing gives no total, rather than a total of zero", empty.totalBytes == nil)

        // The trap: a traversal refusal is also reported on a line starting "x ".
        let log = """
        x safe.txt
        x ../../outside.txt: Path contains '..': Unknown error: -1
        tar: Error exit delayed from previous errors.
        """
        let detail = ArchiveExtractionProgress.errorDetail(from: log, knownEntries: ["safe.txt"])
        check("archive: filtering progress lines keeps the traversal error",
              detail == "x ../../outside.txt: Path contains '..': Unknown error: -1\ntar: Error exit delayed from previous errors.",
              detail ?? "nil")
        check("archive: a log of nothing but progress lines yields no error detail",
              ArchiveExtractionProgress.errorDetail(from: "x safe.txt\n", knownEntries: ["safe.txt"]) == nil)
    }

    /// End to end against a real archive — the one with a symlink in it, which
    /// is what breaks a parser that splits the name off by field count alone.
    private static func extractionProgress(archive: URL, root: URL) async throws {
        let listing = BSDTarArchiveListing()
        let entries = try listing.entries(of: archive)
        check("archive: the real listing reports the archive's entries", !entries.isEmpty, "\(entries.count)")
        check("archive: the real listing marks the symbolic link as one",
              entries.contains { $0.name.hasSuffix("shortcut") && $0.kind == .symbolicLink },
              "\(entries.map { "\($0.name)[\($0.kind)]" })")

        let destination = root.appendingPathComponent("progress-out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var samples: [(Int64, Int64?)] = []
        var lastEntry: String?
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            FileOperations.extract(archive: archive, to: destination, listing: listing,
                onProgress: { bytes, total, entry in
                    samples.append((bytes, total))
                    if let entry { lastEntry = entry }
                },
                isCancelled: { false }, pollInterval: 0.01) { continuation.resume(returning: $0) }
        }
        guard case .success(let output) = result else {
            check("archive: extraction with progress succeeds", false, "\(result)"); return
        }
        check("archive: extraction with progress succeeds", FileManager.default.fileExists(atPath: output.path))
        check("archive: the total stays determinate through an archive containing a symlink",
              samples.allSatisfy { $0.1 != nil }, "\(samples.map { $0.1 })")
        // Swift.zip: this suite has a `zip(_:)` fixture builder of its own.
        check("archive: progress never goes backwards", Swift.zip(samples, samples.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 },
              "\(samples.map(\.0))")
        check("archive: progress never exceeds the total", samples.allSatisfy { sample in sample.1.map { sample.0 <= $0 } ?? true })
        check("archive: the reporter names the entry being written", lastEntry != nil, lastEntry ?? "nil")

        // Cancelled before it starts: nothing published, no staging left behind.
        let cancelDestination = root.appendingPathComponent("cancel-out", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelDestination, withIntermediateDirectories: false)
        let cancelled: Result<URL, Error> = await withCheckedContinuation { continuation in
            FileOperations.extract(archive: archive, to: cancelDestination, listing: listing,
                onProgress: { _, _, _ in }, isCancelled: { true }, pollInterval: 0.01) { continuation.resume(returning: $0) }
        }
        var wasCancelled = false
        if case .failure(let error) = cancelled, case FileOperations.ArchiveError.cancelled = error { wasCancelled = true }
        check("archive: a cancelled extraction reports cancellation, not a tool failure", wasCancelled, "\(cancelled)")
        check("archive: a cancelled extraction publishes nothing and leaves no staging directory",
              (try? FileManager.default.contentsOfDirectory(atPath: cancelDestination.path))?.isEmpty == true)
    }

    private static func contents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private static func isFailure(_ result: Result<URL, Error>) -> Bool {
        if case .failure = result { return true }; return false
    }
    private static func compress(_ urls: [URL], to directory: URL) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            FileOperations.compress(urls: urls, to: directory) { result in
                // Every success/failure path uses this assertion, without extra log noise.
                if !Thread.isMainThread { check("archive: compression completion is on main", false) }
                continuation.resume(returning: result)
            }
        }
    }
    private static func extract(_ archive: URL, to directory: URL) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            FileOperations.extract(archive: archive, to: directory) { result in
                if !Thread.isMainThread { check("archive: extraction completion is on main", false) }
                continuation.resume(returning: result)
            }
        }
    }

    /// Minimal stored ZIP writer for hostile fixtures, independent of the system
    /// archiver: central and local names are identical, CRCs are valid.
    private struct Entry {
        let name: String
        let data: Data
        let mode: UInt32
        let flags: UInt16
        init(_ name: String, _ contents: String, mode: UInt32 = 0o100644, flags: UInt16 = 0) {
            self.name = name; data = Data(contents.utf8); self.mode = mode; self.flags = flags
        }
    }
    private static func zip(_ entries: [Entry]) -> Data {
        var data = Data(), central = Data()
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        for entry in entries {
            let name = Data(entry.name.utf8), offset = UInt32(data.count)
            var crc: UInt32 = 0xffffffff
            for byte in entry.data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            }
            crc ^= 0xffffffff
            append(UInt32(0x04034b50), to: &data)
            for word: UInt16 in [20, entry.flags | 0x0800, 0, 0, 0] { append(word, to: &data) }
            for word in [crc, UInt32(entry.data.count), UInt32(entry.data.count)] { append(word, to: &data) }
            append(UInt16(name.count), to: &data); append(UInt16(0), to: &data)
            data.append(name); data.append(entry.data)
            append(UInt32(0x02014b50), to: &central)
            for word: UInt16 in [0x0314, 20, entry.flags | 0x0800, 0, 0, 0] { append(word, to: &central) }
            for word in [crc, UInt32(entry.data.count), UInt32(entry.data.count)] { append(word, to: &central) }
            for word: UInt16 in [UInt16(name.count), 0, 0, 0, 0] { append(word, to: &central) }
            append(entry.mode << 16, to: &central); append(offset, to: &central)
            central.append(name)
        }
        let offset = UInt32(data.count)
        data.append(central)
        append(UInt32(0x06054b50), to: &data)
        for word: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { append(word, to: &data) }
        append(UInt32(central.count), to: &data); append(offset, to: &data); append(UInt16(0), to: &data)
        return data
    }
}

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
                try browsingGuardrails(in: root)
                archiveTree()
                centralDirectoryDecoding()
                try await centralDirectoryAgreesWithExtraction(in: root)
                try await extractionProgress(archive: folderZIP, root: root)

                try fm.removeItem(at: root)
                DispatchQueue.main.async { completion() }
            } catch {
                try? fm.removeItem(at: root)
                check("archive: unexpected operation error", false, error.localizedDescription)
            }
        }
    }

    /// The browsable shape built from a table of contents alone. Pure: every
    /// rule here is a measured property of what bsdtar will do on extraction,
    /// and a tree that disagrees with the extractor produces rows that can
    /// never be opened.
    private static func archiveTree() {
        func entry(_ name: String, _ size: Int64 = 0,
                   _ kind: ArchiveEntrySummary.Kind = .file) -> ArchiveEntrySummary {
            ArchiveEntrySummary(name: name, uncompressedSize: size, kind: kind)
        }

        // A Python-written ZIP stores no directory records at all (measured),
        // so the hierarchy has to be synthesized or nothing is navigable.
        let bare = ArchiveTree(entries: [entry("a/b/c/deep.txt", 4), entry("a/other.txt", 5), entry("top.txt", 3)])
        check("archive tree: intermediate directories absent from the archive are synthesized",
              bare.node(at: "a")?.isDirectory == true && bare.node(at: "a/b")?.isDirectory == true
              && bare.node(at: "a/b/c")?.isDirectory == true)
        check("archive tree: the root lists the archive's top level",
              Set((bare.children(of: "") ?? []).map(\.name)) == ["a", "top.txt"],
              "\((bare.children(of: "") ?? []).map(\.name))")
        check("archive tree: a file has no children, a directory does",
              bare.children(of: "top.txt") == nil && bare.children(of: "a")?.count == 2)
        check("archive tree: a directory reports its direct child count for an unstaged listing",
              bare.node(at: "a")?.childCount == 2 && bare.node(at: "a/b")?.childCount == 1)

        // An explicit directory record and an implied one must not both appear.
        let explicitDir = ArchiveTree(entries: [entry("a/", 0, .directory), entry("a/inside.txt", 2)])
        check("archive tree: an explicit directory record does not duplicate the implied one",
              explicitDir.children(of: "")?.count == 1 && explicitDir.node(at: "a")?.isDirectory == true)

        // Two entries of one name are legal; extraction yields the later one.
        let duplicates = ArchiveTree(entries: [entry("dup.txt", 5), entry("dup.txt", 6)])
        check("archive tree: a duplicated name collapses to the entry extraction would win with",
              duplicates.children(of: "")?.count == 1 && duplicates.node(at: "dup.txt")?.uncompressedSize == 6)

        // A file entry and a directory implied by another entry's path.
        let clash = ArchiveTree(entries: [entry("clash", 11), entry("clash/inside.txt", 6)])
        check("archive tree: a real file beats a directory implied by another entry",
              clash.node(at: "clash")?.kind == .file, "\(String(describing: clash.node(at: "clash")?.kind))")

        // bsdtar's own path rewrites, reproduced so a row resolves where the
        // extraction will really write.
        let rewritten = ArchiveTree(entries: [entry("/etc/evil.txt", 3), entry("C:/win.txt", 5), entry("./dotslash.txt", 3)])
        check("archive tree: a leading slash is stripped, as the tool strips it",
              rewritten.node(at: "etc/evil.txt") != nil && rewritten.node(at: "/etc/evil.txt") != nil,
              "\(rewritten.node(at: "etc/evil.txt")?.path ?? "missing")")
        check("archive tree: the member keeps the archive's own spelling while the path is the rewritten one",
              rewritten.node(at: "etc/evil.txt")?.member == "/etc/evil.txt")
        check("archive tree: a drive-letter prefix is stripped, as the tool strips it",
              rewritten.node(at: "win.txt") != nil, "\((rewritten.children(of: "") ?? []).map(\.path))")
        check("archive tree: a leading ./ is dropped", rewritten.node(at: "dotslash.txt") != nil)

        // Entries bsdtar will refuse are marked so they are never asked for:
        // a request would only produce an error for the whole batch.
        let hostile = ArchiveTree(entries: [entry("up/../escape.txt", 3), entry("tab" + "\\" + "there.txt", 3), entry("safe.txt", 3)])
        check("archive tree: a .. entry is listed and marked unextractable",
              hostile.node(at: "up/escape.txt")?.isExtractable == false
              || hostile.inertPaths.contains { $0.hasSuffix("escape.txt") },
              "\(hostile.inertPaths)")
        check("archive tree: a name the listing had to escape is unextractable",
              hostile.inertPaths.contains { $0.contains("here.txt") }, "\(hostile.inertPaths)")
        check("archive tree: an ordinary sibling of a hostile entry is unaffected",
              hostile.node(at: "safe.txt")?.isExtractable == true)

        // Escaping is mandatory: unescaped star*.txt takes three files.
        check("archive tree: glob metacharacters in a member are escaped",
              ArchiveTree.escapeMember("star*.txt") == "star\\*.txt"
              && ArchiveTree.escapeMember("brack[1].txt") == "brack\\[1\\].txt"
              && ArchiveTree.escapeMember("q?.txt") == "q\\?.txt",
              ArchiveTree.escapeMember("brack[1].txt"))
        check("archive tree: characters a glob does not use are left alone",
              ArchiveTree.escapeMember("a~{b}.txt") == "a~{b}.txt")

        // UTType(filenameExtension:) alone calls .app an application-FILE,
        // which is not a package; conforming the lookup to .directory is what
        // matches the real isPackageKey.
        check("archive tree: a bundle extension is recognised as a package",
              ArchiveTree.isPackage("My.app") && ArchiveTree.isPackage("doc.rtfd") && ArchiveTree.isPackage("p.pages"))
        check("archive tree: a framework and a plain folder are not packages",
              !ArchiveTree.isPackage("f.framework") && !ArchiveTree.isPackage("plaindir"))

        // A package has to be pulled whole or the app it represents is broken.
        let bundle = ArchiveTree(entries: [entry("Demo.app/Contents/Info.plist", 5),
                                           entry("Demo.app/Contents/MacOS/Demo", 3),
                                           entry("note.txt", 4)])
        check("archive tree: a bundle is one package node, not a directory to walk into",
              bundle.node(at: "Demo.app")?.isPackage == true)
        let plan = bundle.materializationPlan(for: "")
        check("archive tree: the root's plan takes its files with -n and its packages whole",
              plan.leaves == ["note.txt"] && plan.packages == ["Demo.app"],
              "leaves=\(plan.leaves) packages=\(plan.packages)")
        check("archive tree: a package is not in the directory skeleton — it arrives whole",
              !bundle.directoryPaths.contains("Demo.app"), "\(bundle.directoryPaths)")
        check("archive tree: the skeleton lists parents before children",
              bare.directoryPaths == ["a", "a/b", "a/b/c"], "\(bare.directoryPaths)")

        // Sub-directories need nothing: the skeleton already holds them.
        let nested = ArchiveTree(entries: [entry("dir/inner/x.txt", 1), entry("dir/y.txt", 2)])
        let dirPlan = nested.materializationPlan(for: "dir")
        check("archive tree: a directory's plan takes its own files and not its subtree",
              dirPlan.leaves == ["dir/y.txt"] && dirPlan.packages.isEmpty,
              "leaves=\(dirPlan.leaves)")

        let links = ArchiveTree(entries: [entry("alias", 0, .symbolicLink), entry("real.txt", 4)])
        check("archive tree: symbolic links are named for materialization at mount",
              links.symbolicLinkMembers == ["alias"], "\(links.symbolicLinkMembers)")
        check("archive tree: an empty archive yields an empty tree", ArchiveTree(entries: []).isEmpty)
    }

    /// Stage 3: the central-directory reader's pieces, without any archive.
    private static func centralDirectoryDecoding() {
        let utc = TimeZone(identifier: "UTC")!
        // 2020-01-01 12:00:06 → DOS date (40<<9)|(1<<5)|1, time (12<<11)|(0<<5)|3.
        let dos = ZIPCentralDirectory.dosDate(UInt16((40 << 9) | (1 << 5) | 1),
                                              time: UInt16((12 << 11) | 3), timeZone: utc)
        let expected = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: utc,
                                      year: 2020, month: 1, day: 1, hour: 12, minute: 0, second: 6).date
        check("archive dates: a DOS date and time decode, with two-second resolution", dos == expected,
              "\(String(describing: dos))")
        check("archive dates: an impossible DOS date is rejected rather than rolled over",
              ZIPCentralDirectory.dosDate(0, time: 0, timeZone: utc) == nil)

        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)] }
        // 0x5855 — what ditto, and so Finder's Compress, writes: atime, then mtime.
        let ux: [UInt8] = [0x55, 0x58, 8, 0] + le32(111) + le32(1_577_880_000)
        check("archive dates: the Info-ZIP Unix field supplies the mtime, not the atime",
              ZIPCentralDirectory.unixModificationTime(ux, from: 0, length: ux.count) == 1_577_880_000)
        // 0x5455 — a flags byte, then mtime when bit 0 is set.
        let ut: [UInt8] = [0x55, 0x54, 5, 0, 0x01] + le32(1_600_000_000)
        check("archive dates: the extended-timestamp field supplies the mtime",
              ZIPCentralDirectory.unixModificationTime(ut, from: 0, length: ut.count) == 1_600_000_000)
        let utNoMtime: [UInt8] = [0x55, 0x54, 5, 0, 0x02] + le32(1_600_000_000)
        check("archive dates: an extended timestamp without its mtime bit is ignored",
              ZIPCentralDirectory.unixModificationTime(utNoMtime, from: 0, length: utNoMtime.count) == nil)
        // libarchive processes fields in order, a later one overriding.
        check("archive dates: a later Unix field overrides an earlier one, as libarchive does",
              ZIPCentralDirectory.unixModificationTime(ux + ut, from: 0, length: ux.count + ut.count) == 1_600_000_000)
        // NTFS 0x000a is not read, because libarchive does not read it either.
        let ntfs: [UInt8] = [0x0a, 0x00, 4, 0, 1, 2, 3, 4]
        check("archive dates: the NTFS field is not read, matching the extractor",
              ZIPCentralDirectory.unixModificationTime(ntfs, from: 0, length: ntfs.count) == nil)
        let truncated: [UInt8] = [0x55, 0x58, 8, 0, 1, 2]
        check("archive dates: a truncated extra field is ignored rather than overread",
              ZIPCentralDirectory.unixModificationTime(truncated, from: 0, length: truncated.count) == nil)
        check("archive dates: an empty central directory yields no dates",
              ZIPCentralDirectory.parse(Data()).isEmpty)
    }

    /// The property the whole of Stage 3 rests on: the date shown for an entry
    /// before it is materialized is the date extraction then writes to disk. If
    /// these disagreed, a row's date would change the moment it was opened.
    private static func centralDirectoryAgreesWithExtraction(in root: URL) async throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent("Dated", isDirectory: true)
        let nested = source.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: nested.appendingPathComponent("b.txt"))
        let old = Date(timeIntervalSince1970: 1_577_880_000)     // 2020-01-01T12:00:00Z
        let older = Date(timeIntervalSince1970: 1_262_347_200)   // 2010-01-01T12:00:00Z
        for (url, date) in [(source.appendingPathComponent("a.txt"), old), (nested.appendingPathComponent("b.txt"), older),
                            (nested, older), (source, old)] {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let archive = try await SmokeFixtures.compress([source], to: root)
        let dates = ZIPCentralDirectory.modificationDates(of: archive)
        check("archive dates: every entry of a Finder-made archive has a date",
              ["Dated", "Dated/a.txt", "Dated/Nested", "Dated/Nested/b.txt"].allSatisfy { dates[$0] != nil },
              "\(dates.keys.sorted())")
        check("archive dates: a recorded directory carries its own date, not its contents'",
              dates["Dated"] == old && dates["Dated/Nested"] == older,
              "Dated=\(String(describing: dates["Dated"])) Nested=\(String(describing: dates["Dated/Nested"]))")

        // Extract the whole archive the way the old path did and compare.
        let out = root.appendingPathComponent("dated-out", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: false)
        let extracted = try await extract(archive, to: out).get()
        var disagreements: [String] = []
        for (relative, expected) in dates {
            let onDisk = extracted.deletingLastPathComponent().appendingPathComponent(relative)
            guard let written = try? fm.attributesOfItem(atPath: onDisk.path)[.modificationDate] as? Date else { continue }
            if abs(written.timeIntervalSince(expected)) >= 1 { disagreements.append("\(relative): cd=\(expected) disk=\(written)") }
        }
        check("archive dates: the central directory's dates are exactly what extraction writes",
              disagreements.isEmpty, disagreements.joined(separator: "; "))
    }

    /// Stage 0 of lazy browsing: the refusals that must happen before a single
    /// byte is staged, and the listing seam's error reporting.
    private static func browsingGuardrails(in root: URL) throws {
        let fm = FileManager.default

        // An encrypted ZIP is refused by its local-header flag, by name. This
        // matters more than a nicer message: `tar -tvf` exits 0 on an encrypted
        // archive with a complete, correct listing, and `tar -x` then exits 1
        // while leaving a correctly-sized, entirely zero-filled file at the
        // right path — which anything judging success by fileExists would serve.
        let encrypted = root.appendingPathComponent("flagged.zip")
        try zip([Entry("secret.txt", "not encrypted data", flags: 1)]).write(to: encrypted)
        var encryptionRefusal: String?
        do { try FileOperations.checkArchiveForBrowsing(encrypted) }
        catch { encryptionRefusal = error.localizedDescription }
        check("archive: a password-protected ZIP is refused by name before anything is staged",
              encryptionRefusal?.contains("password-protected") == true, encryptionRefusal ?? "not refused")

        let plain = root.appendingPathComponent("plain.zip")
        try zip([Entry("open.txt", "readable")]).write(to: plain)
        var plainError: String?
        do { try FileOperations.checkArchiveForBrowsing(plain) } catch { plainError = "\(error)" }
        check("archive: an ordinary ZIP passes the browsing pre-flight", plainError == nil, plainError ?? "")

        let empty = root.appendingPathComponent("empty-central.zip")
        try zip([]).write(to: empty)
        var emptyError: String?
        do { try FileOperations.checkArchiveForBrowsing(empty) } catch { emptyError = "\(error)" }
        check("archive: an empty ZIP has no local header and is not mistaken for encrypted",
              emptyError == nil, emptyError ?? "")

        // A damaged archive must say what the tool said, not return an empty
        // listing that reads as "this ZIP has no files in it".
        let damaged = root.appendingPathComponent("damaged.zip")
        try Data("PK\u{3}\u{4}corrupt payload".utf8).write(to: damaged)
        var listingFailure: Error?
        do { _ = try BSDTarArchiveListing().entries(of: damaged) } catch { listingFailure = error }
        var reportedDamaged = false
        if let failure = listingFailure, case ArchiveListingError.damaged = failure { reportedDamaged = true }
        check("archive: a damaged archive throws rather than listing as empty", reportedDamaged,
              listingFailure.map { "\($0)" } ?? "no error")
        check("archive: the damaged-archive message carries the tool's own words",
              (listingFailure?.localizedDescription.isEmpty == false), listingFailure?.localizedDescription ?? "")

        // The chunked parser: a final line with no newline must not become a
        // half-built entry, and the entry cap must throw rather than truncate.
        let partial = root.appendingPathComponent("partial-listing.txt")
        try Data("-rw-r--r--  0 501    0           4 Sep 22 19:42 a.bin\n-rw-r--r--  0 501".utf8).write(to: partial)
        let parsed = try BSDTarArchiveListing.parse(partial)
        check("archive: a truncated final listing line yields no half-parsed entry",
              parsed.map(\.name) == ["a.bin"], "\(parsed.map(\.name))")

        // Free space is a refusal, not a crash, and it never fires for zero.
        let noRefusal = FileOperations.requiredSpaceRefusal(forExtracting: 0, into: root)
        check("archive: an archive of no content is never refused for space", noRefusal == nil)
        let refusal = FileOperations.requiredSpaceRefusal(forExtracting: Int64.max / 2, into: root)
        check("archive: an archive larger than the volume is refused before staging",
              refusal != nil && refusal?.localizedDescription.contains("temporary space") == true,
              refusal?.localizedDescription ?? "not refused")

        // The launch sweep must remove an orphan and spare a directory another
        // process still holds: $TMPDIR is shared between Tursora processes.
        let sweepRoot = root.appendingPathComponent("sweep", isDirectory: true)
        try fm.createDirectory(at: sweepRoot, withIntermediateDirectories: true)
        let orphan = sweepRoot.appendingPathComponent(ArchiveBrowsingSession.storagePrefix + "orphan")
        let live = sweepRoot.appendingPathComponent(ArchiveBrowsingSession.storagePrefix + "live")
        let stranger = sweepRoot.appendingPathComponent("someone-elses-directory")
        for url in [orphan, live, stranger] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        // The orphan carries a marker nobody holds; the live one is locked.
        let orphanMarker = orphan.appendingPathComponent(ArchiveBrowsingSession.lockName)
        fm.createFile(atPath: orphanMarker.path, contents: nil)
        let heldDescriptor = ArchiveBrowsingSession.takeStorageLock(in: live)
        check("archive: a live session can take its storage lock", heldDescriptor >= 0)
        FileOperations.sweepOrphanedStorage(in: sweepRoot)
        check("archive: the launch sweep removes an unowned storage directory",
              !fm.fileExists(atPath: orphan.path))
        check("archive: the launch sweep spares storage another process still holds",
              fm.fileExists(atPath: live.path))
        check("archive: the launch sweep touches nothing outside its own prefix",
              fm.fileExists(atPath: stranger.path))
        ArchiveBrowsingSession.releaseStorageLock(heldDescriptor)
        FileOperations.sweepOrphanedStorage(in: sweepRoot)
        check("archive: once released, that storage is swept too", !fm.fileExists(atPath: live.path))
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

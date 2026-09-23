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
                archiveToolLayer()
                try await centralDirectoryAgreesWithExtraction(in: root)
                try await extractionProgress(archive: folderZIP, root: root)
                try materializerChecks(in: root)

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
        let plan = bundle.prefetchPlan(for: "")
        check("archive tree: the root's plan selects its files and takes its packages whole",
              plan.selected.map(\.path) == ["note.txt"] && plan.packages.map(\.path) == ["Demo.app"],
              "selected=\(plan.selected.map(\.path)) packages=\(plan.packages.map(\.path))")
        check("archive tree: a package is not in the directory skeleton — it arrives whole",
              !bundle.directoryPaths.contains("Demo.app"), "\(bundle.directoryPaths)")
        check("archive tree: the skeleton lists parents before children",
              bare.directoryPaths == ["a", "a/b", "a/b/c"], "\(bare.directoryPaths)")

        // Sub-directories need nothing: the skeleton already holds them.
        let nested = ArchiveTree(entries: [entry("dir/inner/x.txt", 1), entry("dir/y.txt", 2)])
        let dirPlan = nested.prefetchPlan(for: "dir")
        check("archive tree: a directory's plan takes its own files and not its subtree",
              dirPlan.publishes == ["dir/y.txt"] && dirPlan.packages.isEmpty,
              "publishes=\(dirPlan.publishes)")

        // D94: the central directory's encryption flag makes a member inert,
        // so it is never put in a batch that would leave zeros behind.
        let encrypted = ArchiveTree(entries: [entry("d/a.txt", 9), entry("d/b.txt", 6), entry("d/c.txt", 11)],
                                    records: ["d/b.txt": ZIPCentralDirectory.Record(modificationDate: nil, isEncrypted: true)])
        check("archive tree: an encrypted member is inert, for that reason",
              encrypted.node(at: "d/b.txt")?.inertReason == .encrypted
              && encrypted.node(at: "d/a.txt")?.inertReason == nil)
        let encryptedPlan = encrypted.prefetchPlan(for: "d")
        check("archive tree: an encrypted member is left out of its folder's batch, and excluded from its run",
              Set(encryptedPlan.publishes) == ["d/a.txt", "d/c.txt"]
              && encryptedPlan.selection?.excludes.contains("d/b.txt") == true,
              "\(encryptedPlan.publishes) \(String(describing: encryptedPlan.selection))")

        // A package's descendants are never created on their own: not in the
        // skeleton, and not as a mount-time link, or the package would exist as
        // an empty shell before it was ever extracted.
        let shell = ArchiveTree(entries: [entry("Demo.app/Contents/Info.plist", 5),
                                          entry("Demo.app/Contents/Frameworks/K.framework/Versions/A/K", 3),
                                          entry("Demo.app/Contents/Frameworks/K.framework/K", 0, .symbolicLink),
                                          entry("plain/x.txt", 1)])
        check("archive tree: nothing inside a package is in the directory skeleton",
              !shell.directoryPaths.contains { $0.hasPrefix("Demo.app") }, "\(shell.directoryPaths)")
        check("archive tree: a link inside a package is not a mount-time link",
              shell.symbolicLinkMembers.isEmpty, "\(shell.symbolicLinkMembers)")
        check("archive tree: a package's descendants know they are inside it",
              shell.node(at: "Demo.app/Contents")?.insidePackage == true
              && shell.node(at: "plain")?.insidePackage == false)
        let packageWithSecret = ArchiveTree(entries: [entry("Demo.app/Contents/Info.plist", 5),
                                                      entry("Demo.app/Contents/bin", 4)],
                                            records: ["Demo.app/Contents/bin": ZIPCentralDirectory.Record(isEncrypted: true)])
        check("archive tree: a package names its encrypted members so they can be excluded",
              packageWithSecret.inertMembers(inside: "Demo.app") == ["Demo.app/Contents/bin"])

        // Stage 2: publication is refused under a link and inside a package.
        let reach = ArchiveTree(entries: [entry("ok/file.txt", 1), entry("link", 0, .symbolicLink),
                                          entry("link/through.txt", 1), entry("Demo.app/Contents/Info.plist", 1),
                                          entry("up/../escape.txt", 1)])
        check("archive tree: an ordinary file is reachable", reach.isReachable("ok/file.txt"))
        check("archive tree: nothing under a symbolic link is reachable — staging would bypass bsdtar's own check",
              !reach.isReachable("link/through.txt"))
        check("archive tree: a package is reachable as a whole, its insides are not",
              reach.isReachable("Demo.app") && !reach.isReachable("Demo.app/Contents/Info.plist"))
        check("archive tree: an inert entry is never reachable", !reach.isReachable("up/escape.txt"))

        // Prefetch: one folder's direct files in one selection.
        let folder = ArchiveTree(entries: [entry("big/a.txt", 3), entry("big/b.txt", 4), entry("big/sub/deep.txt", 5),
                                           entry("big/Demo.app/Contents/Info.plist", 6), entry("/big/abs.txt", 7),
                                           entry("big/secret.txt", 8)],
                                 records: ["big/secret.txt": ZIPCentralDirectory.Record(isEncrypted: true)])
        let prefetch = folder.prefetchPlan(for: "big")
        check("archive tree: a folder's direct files are one selection, excluding two levels down and the inert",
              prefetch.selection == ArchiveTool.DirectorySelection(include: "big", excludes: ["big/*/*", "big/secret.txt"])
              && Set(prefetch.selected.map(\.path)) == ["big/a.txt", "big/b.txt"],
              "\(String(describing: prefetch.selection)) \(prefetch.selected.map(\.path))")
        check("archive tree: a member bsdtar will not match through an include is asked for by name",
              prefetch.leaves.map(\.path) == ["big/abs.txt"] && prefetch.leaves.first?.raw == "/big/abs.txt",
              "\(prefetch.leaves.map(\.path))")
        check("archive tree: a package in the folder comes whole, in its own run",
              prefetch.packages.map(\.path) == ["big/Demo.app"])
        check("archive tree: a folder's plan never reaches into a subfolder",
              !prefetch.publishes.contains("big/sub/deep.txt"))
        check("archive tree: the archive root is selected with no include",
              folder.prefetchPlan(for: "").selection?.include == nil)
        let mostlyThere = folder.prefetchPlan(for: "big", skipping: ["big/a.txt", "big/b.txt", "big/abs.txt"])
        check("archive tree: a folder already mostly here names the rest instead of excluding what is here",
              mostlyThere.selection == nil && mostlyThere.selected.isEmpty,
              "\(String(describing: mostlyThere.selection))")

        // Subtree: a folder and everything below it, for copying it out whole.
        let subtree = folder.subtreePlan(for: "big")
        check("archive tree: a folder's subtree plan reaches every file below it, never the inert",
              Set(subtree.publishes) == ["big/a.txt", "big/b.txt", "big/sub/deep.txt", "big/Demo.app", "big/abs.txt"],
              "\(subtree.publishes.sorted())")
        check("archive tree: a subtree selection keeps packages for their own run",
              subtree.selection?.excludes.contains("big/Demo.app") == true
              && subtree.selection?.excludes.contains("big/secret.txt") == true,
              "\(String(describing: subtree.selection))")

        // An explicit request names files; a large request that is most of a
        // folder becomes that folder's selection.
        let named = folder.batchPlan(for: ["big/a.txt", "big/Demo.app"])
        check("archive tree: an explicit request names its files and takes packages whole",
              named.leaves.map(\.path) == ["big/a.txt"] && named.packages.map(\.path) == ["big/Demo.app"]
              && named.selection == nil)
        let many = ArchiveTree(entries: (0..<300).map { entry("m/f\($0).txt", 1) })
        let bulk = many.batchPlan(for: (0..<290).map { "m/f\($0).txt" })
        check("archive tree: requesting most of a large folder becomes one selection, not 290 names",
              bulk.selection?.include == "m" && bulk.selected.count == 290 && bulk.leaves.isEmpty
              && bulk.selection?.excludes.count == 11,   // m/*/* and the ten not asked for
              "sel=\(String(describing: bulk.selection?.excludes.count)) leaves=\(bulk.leaves.count)")

        let links = ArchiveTree(entries: [entry("alias", 0, .symbolicLink), entry("real.txt", 4)])
        check("archive tree: symbolic links are named for materialization at mount",
              links.symbolicLinkMembers == ["alias"], "\(links.symbolicLinkMembers)")
        check("archive tree: an empty archive yields an empty tree", ArchiveTree(entries: []).isEmpty)
    }

    /// Stage 2's pure tool layer: the argument list, and per-member attribution
    /// against log lines copied verbatim from real bsdtar runs.
    private static func archiveToolLayer() {
        let source = URL(fileURLWithPath: "/src.zip"), out = URL(fileURLWithPath: "/out")
        let args = ArchiveTool.extractionArguments(source: source, output: out, noRecursion: false,
                                                   excludes: ["big/*/*", "big/secret.txt"], includes: ["big"],
                                                   passphrase: "P")
        // Measured: a pattern before `--exclude` turns `--exclude` into a
        // pattern and extracts the whole subtree, package included.
        let firstExclude = args.firstIndex(of: "--exclude") ?? .max
        let separator = args.firstIndex(of: "--") ?? .max
        check("archive tool: every exclude comes before the include, behind a --",
              firstExclude < separator && args.last == "big" && args[separator + 1] == "big", "\(args)")
        check("archive tool: verbose is always on, and -n only when asked",
              args.contains("-v") && !args.contains("-n")
              && ArchiveTool.extractionArguments(source: source, output: out, noRecursion: true).contains("-n"))
        check("archive tool: fast-read is never used",
              !args.contains("-q") && !args.contains("--fast-read"))
        // A member named like an option must still be a member.
        let dashed = ArchiveTool.extractionArguments(source: source, output: out, noRecursion: false, includes: ["-n"])
        check("archive tool: a member named -n is read as a member, after --",
              Array(dashed.suffix(2)) == ["--", "-n"], "\(dashed.suffix(3))")
        check("archive tool: the archive root is selected with no include at all",
              ArchiveTool.directSelection(of: nil) == ArchiveTool.DirectorySelection(include: nil, excludes: ["*/*"]))
        check("archive tool: a folder's direct files are selected by excluding two levels down",
              ArchiveTool.directSelection(of: "big", excluding: ["big/secret.txt"])
                == ArchiveTool.DirectorySelection(include: "big", excludes: ["big/*/*", "big/secret.txt"]))

        func spelling(_ path: String, raw: String? = nil) -> ArchiveMemberSpelling {
            let raw = raw ?? path
            return ArchiveMemberSpelling(path: path, raw: raw, escaped: ArchiveTree.escapeMember(raw))
        }
        // Verbatim from a real run: a CRC failure, a clean pair, a missing member.
        let crcLog = """
        x d/a.txt
        x d/bad.txt: ZIP bad CRC: 0xbde39420 should be 0x5ca44334: Unknown error: -1
        x d/c.txt
        tar: d/nope\\*.txt: Not found in archive
        tar: Error exit delayed from previous errors.
        """
        let crc = ArchiveToolVerdict.attribute(log: crcLog, members: [spelling("d/a.txt"), spelling("d/bad.txt"),
                                                                     spelling("d/c.txt"), spelling("d/nope*.txt")])
        check("archive tool: a clean announcement is a success",
              crc.extracted == ["d/a.txt", "d/c.txt"], "\(crc.extracted.sorted())")
        check("archive tool: a CRC failure is pinned to its member, with bsdtar's reason",
              crc.failed["d/bad.txt"]?.hasPrefix("ZIP bad CRC") == true, "\(crc.failed)")
        check("archive tool: Not found is matched through the escaped spelling it repeats",
              crc.notFound == ["d/nope*.txt"], "\(crc.notFound)")
        check("archive tool: the run's trailer is not mistaken for a member",
              crc.isTrustworthy, "\(crc.unrecognized)")

        let encrypted = ArchiveToolVerdict.attribute(
            log: "x d/a.txt\nx d/b.txt: Incorrect passphrase: Unknown error: -1\ntar: Error exit delayed from previous errors.",
            members: [spelling("d/a.txt"), spelling("d/b.txt")])
        check("archive tool: an encrypted member fails and its sibling does not",
              encrypted.extracted == ["d/a.txt"] && encrypted.failed["d/b.txt"]?.contains("passphrase") == true)

        let source404 = ArchiveToolVerdict.attribute(
            log: "tar: Error opening archive: Failed to open '/nonexistent.zip'", members: [spelling("d/a.txt")])
        check("archive tool: an unreadable archive is a source failure, not a member one",
              source404.sourceFailure != nil && source404.failed.isEmpty && !source404.isTrustworthy)

        // bsdtar reports a rewritten member under its rewritten name.
        let rewritten = ArchiveToolVerdict.attribute(
            log: "tar: Removing leading '/' from member names\nx etc/evil.txt",
            members: [spelling("etc/evil.txt", raw: "/etc/evil.txt")])
        check("archive tool: a leading slash bsdtar removed does not hide the member",
              rewritten.extracted == ["etc/evil.txt"] && rewritten.isTrustworthy, "\(rewritten)")

        // A package succeeds or fails as a unit.
        let package = ArchiveToolVerdict.attribute(
            log: "x Demo.app/\nx Demo.app/Contents/Info.plist\nx Demo.app/Contents/bin: ZIP bad CRC: x: Unknown error: -1",
            members: [spelling("Demo.app")], packages: ["Demo.app"])
        check("archive tool: a failure anywhere inside a package fails the package",
              package.failed["Demo.app"] != nil && !package.extracted.contains("Demo.app"), "\(package)")
        // The same, with every descendant's spelling supplied as the real
        // caller does, including one whose name itself contains ": ".
        let appTree = ArchiveTree(entries: ["Demo.app/Contents/Info.plist", "Demo.app/Contents/a: b"].map {
            ArchiveEntrySummary(name: $0, uncompressedSize: 1, kind: .file)
        })
        let clean = ArchiveToolVerdict.attribute(
            log: "x Demo.app/Contents/Info.plist\nx Demo.app/Contents/a: b",
            members: appTree.packageSpellings("Demo.app"), packages: ["Demo.app"])
        check("archive tool: with its descendants named, a sound package is a success even with \": \" in a name",
              clean.extracted == ["Demo.app"] && clean.failed.isEmpty, "\(clean)")

        let colon = ArchiveToolVerdict.attribute(log: "x d/a: b.txt", members: [spelling("d/a: b.txt"), spelling("d/a")])
        check("archive tool: a name containing \": \" is a success, not a failure of a shorter name",
              colon.extracted == ["d/a: b.txt"] && colon.failed.isEmpty, "\(colon)")

        let stray = ArchiveToolVerdict.attribute(log: "x d/a.txt\nsomething bsdtar never said", members: [spelling("d/a.txt")])
        check("archive tool: an unrecognised line makes the whole verdict untrustworthy",
              !stray.isTrustworthy && stray.unrecognized == ["something bsdtar never said"])
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

        // D94: general-purpose bit 0 at record +8. A record's flags are not
        // the first local header's, which is all the pre-flight reads.
        func record(_ name: String, flags: UInt16) -> [UInt8] {
            var bytes: [UInt8] = [0x50, 0x4b, 0x01, 0x02, 20, 3, 20, 0,
                                  UInt8(flags & 0xff), UInt8(flags >> 8), 0, 0,
                                  0, 0x60, 0x21, 0x50]                     // time, date
            bytes += [UInt8](repeating: 0, count: 12)                       // crc, sizes
            bytes += [UInt8(name.utf8.count), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            return bytes + Array(name.utf8)
        }
        let flagged = ZIPCentralDirectory.parseRecords(Data(record("plain.txt", flags: 0) + record("locked.txt", flags: 0x0009)))
        check("archive dates: a record with the encryption bit set reads as encrypted",
              flagged["locked.txt"]?.isEncrypted == true && flagged["plain.txt"]?.isEncrypted == false,
              "\(flagged.mapValues(\.isEncrypted))")
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

    /// Counts runs, and can hold the first one until released, so concurrent
    /// callers really do arrive while it is in flight.
    private final class GatedRunner: ArchiveToolRunning {
        private let lock = NSLock()
        private var runs = 0
        private let gate = DispatchSemaphore(value: 0)
        private var holdFirst: Bool
        init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
        var count: Int { lock.lock(); defer { lock.unlock() }; return runs }
        func release() { gate.signal() }
        func run(_ arguments: [String], scratch: URL, cancellation: ArchivePreparationCancellation?) throws -> ArchiveToolRun {
            lock.lock(); runs += 1; let hold = holdFirst; holdFirst = false; lock.unlock()
            if hold { gate.wait() }
            return try SystemArchiveToolRunner.shared.run(arguments, scratch: scratch, cancellation: cancellation)
        }
    }

    /// A materializer over a real archive, mounted the way a session mounts:
    /// the skeleton and the links, nothing else.
    private static func mount(_ archive: URL, in parent: URL, runner: ArchiveToolRunning)
        throws -> (ArchiveMaterializer, root: URL, storage: URL) {
        let fm = FileManager.default
        let storage = parent.appendingPathComponent("storage-\(UUID().uuidString)", isDirectory: true)
        let root = storage.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let tree = ArchiveTree(entries: try BSDTarArchiveListing().entries(of: archive),
                               records: ZIPCentralDirectory.records(of: archive))
        for path in tree.directoryPaths { try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        try FileOperations.materializeArchiveMembers(archive: archive, into: root, scratch: storage,
                                                     members: tree.symbolicLinkMembers, noRecursion: true)
        let materializer = ArchiveMaterializer(tree: tree, source: archive, rootURL: root.resolvingSymlinksInPath(),
                                               storageURL: storage, runner: runner, spaceCheck: { _, _ in nil })
        return (materializer, root.resolvingSymlinksInPath(), storage)
    }

    /// Stage 2's core: staging, per-member attribution, one exclusive no-follow
    /// rename per member, and coalescing (D95).
    private static func materializerChecks(in root: URL) throws {
        let fm = FileManager.default
        let area = root.appendingPathComponent("materializer", isDirectory: true)
        try fm.createDirectory(at: area, withIntermediateDirectories: true)
        func stagingLeft(_ storage: URL) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: storage.path)) ?? []).contains { $0.hasPrefix(".tursora-stage-") }
        }
        func read(_ url: URL?) -> String? { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }

        // One entry: exactly its bytes, and nothing else written.
        let plain = area.appendingPathComponent("plain.zip")
        try zip([Entry("d/a.txt", "alpha"), Entry("d/b.txt", "beta")]).write(to: plain)
        let basic = try mount(plain, in: area, runner: GatedRunner())
        try basic.0.materialize(basic.0.tree.batchPlan(for: ["d/a.txt"]))
        check("materializer: one requested entry is published with exactly its bytes",
              read(basic.0.publishedURL(for: "d/a.txt")) == "alpha")
        check("materializer: an entry not asked for is not written",
              !fm.fileExists(atPath: basic.root.appendingPathComponent("d/b.txt").path))
        check("materializer: no staging directory is left behind", !stagingLeft(basic.storage))

        // A CRC-corrupt member: bsdtar writes it with the corrupt bytes and says
        // so on one stderr line. It must never be published.
        var corrupt = zip([Entry("c/good.txt", "fine"), Entry("c/bad.txt", "corrupt me"), Entry("c/good2.txt", "fine too")])
        if let range = corrupt.range(of: Data("corrupt me".utf8)) { corrupt[range.lowerBound] ^= 0xFF }
        let crcZIP = area.appendingPathComponent("crc.zip")
        try corrupt.write(to: crcZIP)
        let crcRunner = GatedRunner()
        let crc = try mount(crcZIP, in: area, runner: crcRunner)
        try crc.0.materialize(crc.0.tree.prefetchPlan(for: "c"))
        var crcReason = ""
        if case .failed(let reason) = crc.0.state(of: "c/bad.txt") { crcReason = reason }
        check("materializer: a CRC-corrupt member fails, with bsdtar's reason",
              crcReason.contains("CRC"), "\(crc.0.state(of: "c/bad.txt"))")
        check("materializer: a CRC-corrupt member leaves nothing at its path",
              !fm.fileExists(atPath: crc.root.appendingPathComponent("c/bad.txt").path))
        check("materializer: its sound siblings in the same run are published",
              read(crc.0.publishedURL(for: "c/good.txt")) == "fine" && read(crc.0.publishedURL(for: "c/good2.txt")) == "fine too")
        let runsBefore = crcRunner.count
        try crc.0.materialize(crc.0.tree.prefetchPlan(for: "c", skipping: crc.0.settledPaths))
        check("materializer: a member that failed is not asked for again",
              crcRunner.count == runsBefore, "runs \(runsBefore) -> \(crcRunner.count)")
        crc.0.forgetFailures(under: "c")
        check("materializer: Reload forgets a failure so it can be tried again",
              crc.0.state(of: "c/bad.txt") == .absent)

        // Eight concurrent requests for one entry: one run, one publication.
        let gated = GatedRunner(holdFirst: true)
        let many = try mount(plain, in: area, runner: gated)
        let group = DispatchGroup()
        let plan = many.0.tree.batchPlan(for: ["d/b.txt"])
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async { try? many.0.materialize(plan); group.leave() }
        }
        Thread.sleep(forTimeInterval: 0.2)
        gated.release()
        group.wait()
        check("materializer: eight concurrent requests for one entry cause one run",
              gated.count == 1, "\(gated.count) runs")
        check("materializer: and every caller sees it published", read(many.0.publishedURL(for: "d/b.txt")) == "beta")

        // Overlapping batches: the shared member is written once.
        let overlapZIP = area.appendingPathComponent("overlap.zip")
        try zip([Entry("o/a", "A"), Entry("o/b", "B"), Entry("o/c", "C"), Entry("o/d", "D")]).write(to: overlapZIP)
        let held = GatedRunner(holdFirst: true)
        let overlap = try mount(overlapZIP, in: area, runner: held)
        let first = DispatchGroup(); first.enter()
        DispatchQueue.global().async { try? overlap.0.materialize(overlap.0.tree.batchPlan(for: ["o/a", "o/b", "o/c"])); first.leave() }
        Thread.sleep(forTimeInterval: 0.1)
        let second = DispatchGroup(); second.enter()
        DispatchQueue.global().async { try? overlap.0.materialize(overlap.0.tree.batchPlan(for: ["o/b", "o/d"])); second.leave() }
        Thread.sleep(forTimeInterval: 0.1)
        held.release()
        first.wait(); second.wait()
        let inode = { (path: String) in
            (try? fm.attributesOfItem(atPath: overlap.root.appendingPathComponent(path).path)[.systemFileNumber] as? NSNumber)?.intValue
        }
        let bInode = inode("o/b")
        check("materializer: overlapping batches publish every member once",
              ["o/a", "o/b", "o/c", "o/d"].allSatisfy { overlap.0.state(of: $0) == .published }
              && held.count == 2 && inode("o/b") == bInode, "runs \(held.count)")

        // Staging must never publish through a link into somewhere outside.
        let outside = area.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let escapeZIP = area.appendingPathComponent("escape.zip")
        try zip([Entry("link", outside.path, mode: 0o120777), Entry("link/outside.txt", "overwrite")]).write(to: escapeZIP)
        let escape = try mount(escapeZIP, in: area, runner: GatedRunner())
        check("materializer: a member under a link is never planned", escape.0.tree.batchPlan(for: ["link/outside.txt"]).isEmpty)
        // Force it anyway, past the plan: publication must still refuse it.
        var forced = ArchiveTree.BatchPlan()
        forced.leaves = [ArchiveMemberSpelling(path: "link/outside.txt", raw: "link/outside.txt", escaped: "link/outside.txt")]
        try? escape.0.materialize(forced)
        check("materializer: a member forced through a link is refused at publication",
              escape.0.state(of: "link/outside.txt") != .published
              && ((try? fm.contentsOfDirectory(atPath: outside.path)) ?? []).isEmpty,
              "\(escape.0.state(of: "link/outside.txt")) outside=\((try? fm.contentsOfDirectory(atPath: outside.path)) ?? [])")

        // A downloaded archive's quarantine reaches what is published from it.
        let quarantined = area.appendingPathComponent("quarantined.zip")
        try zip([Entry("q/app.txt", "q")]).write(to: quarantined)
        let mark = Data("0083;65000000;TursoraSmokeTest;".utf8)
        _ = mark.withUnsafeBytes { setxattr(quarantined.path, "com.apple.quarantine", $0.baseAddress, mark.count, 0, 0) }
        let q = try mount(quarantined, in: area, runner: GatedRunner())
        try q.0.materialize(q.0.tree.batchPlan(for: ["q/app.txt"]))
        var stamped = Data(count: mark.count)
        let got = stamped.withUnsafeMutableBytes {
            getxattr(q.root.appendingPathComponent("q/app.txt").path, "com.apple.quarantine", $0.baseAddress, mark.count, 0, 0)
        }
        check("materializer: a published entry carries its archive's download quarantine",
              got == mark.count && stamped == mark)
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

import AppKit

enum ArchiveWorkspaceSmokeTests: SmokeSuite {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            let fixture = fm.temporaryDirectory.appendingPathComponent("tursora-archive-workspace-" + UUID().uuidString).resolvingSymlinksInPath()
            let workspace = ArchiveWorkspace()
            let oldPreference = AppPreferences.experimentalZIPBrowsingEnabled
            defer {
                AppPreferences.experimentalZIPBrowsingEnabled = oldPreference
                workspace.shutdownAll()
                try? fm.removeItem(at: fixture)
            }
            do {
                print("== same-pane ZIP workspace ==")
                let folder = fixture.appendingPathComponent("Folder #50%", isDirectory: true)
                let nested = folder.appendingPathComponent("深 度", isDirectory: true)
                try fm.createDirectory(at: nested, withIntermediateDirectories: true)
                let note = nested.appendingPathComponent("report #100%.txt")
                try Data("snapshot contents".utf8).write(to: note)
                let outside = fixture.appendingPathComponent("outside.txt")
                try Data("outside original".utf8).write(to: outside)
                try fm.createSymbolicLink(atPath: folder.appendingPathComponent("escape").path, withDestinationPath: outside.path)
                try fm.createSymbolicLink(atPath: folder.appendingPathComponent("missing").path, withDestinationPath: "missing-target")
                try fm.createSymbolicLink(atPath: folder.appendingPathComponent("safe-link").path, withDestinationPath: "深 度/report #100%.txt")
                let plainDirectory = fixture.appendingPathComponent("ordinary.zip", isDirectory: true)
                try fm.createDirectory(at: plainDirectory, withIntermediateDirectories: false)
                let created = try await SmokeFixtures.compress([folder], to: fixture)
                let archive = fixture.appendingPathComponent("Sample #100%.zip")
                try fm.moveItem(at: created, to: archive)
                let archiveData = try Data(contentsOf: archive)
                let logicalFolder = archive.appendingPathComponent(folder.lastPathComponent)
                let logicalNested = logicalFolder.appendingPathComponent(nested.lastPathComponent)
                let logicalNote = logicalNested.appendingPathComponent(note.lastPathComponent)
                let provider = ArchiveFileProvider(base: LocalFileProvider(), workspace: workspace)

                check("archive workspace detects ZIP root and unprepared child", workspace.archiveURL(containing: archive) == archive && workspace.archiveURL(containing: logicalNote) == archive)
                check("archive workspace leaves directories named zip ordinary", try workspace.archiveURL(containing: plainDirectory) == nil && provider.listDirectory(plainDirectory).isEmpty)
                check("unprepared ZIP file remains a readable ordinary file", try workspace.physicalURL(for: archive) == archive)
                check("unprepared logical child cannot be read as an ordinary path", (try? workspace.physicalURL(for: logicalNote)) == nil)
                AppPreferences.experimentalZIPBrowsingEnabled = false
                check("disabled experiment does not resolve a new ZIP directory", PathCompleter.resolveDirectory(archive.path, cwd: fixture, home: fixture, workspace: workspace) == nil)
                AppPreferences.experimentalZIPBrowsingEnabled = true
                check("address accepts an unprepared ZIP root", PathCompleter.resolveDirectory(archive.path, cwd: fixture, home: fixture, workspace: workspace) == archive)
                check("address accepts a trailing slash on a ZIP root", PathCompleter.resolveDirectory(archive.path + "/", cwd: fixture, home: fixture, workspace: workspace) == archive)
                check("unprepared children are only navigation candidates", PathCompleter.resolveDirectory(logicalNested.path, cwd: fixture, home: fixture, workspace: workspace) == nil && PathCompleter.resolveNavigationLocation(logicalNested.path, cwd: fixture, home: fixture, workspace: workspace) == logicalNested)

                async let first = prepare(archive, workspace: workspace)
                async let second = prepare(archive, workspace: workspace)
                let (session, reused) = try await (first, second)
                check("concurrent preparation coalesces into one retained snapshot", session === reused)

                // The assertion the whole feature rests on: mounting reads the
                // table of contents and writes the shape, not the bytes. Stated
                // as "no regular file anywhere under the root", which is stabler
                // than a wall clock and fails loudly if staging ever returns.
                check("a mounted archive is lazily backed", session.isLazilyMounted)
                var staged: [String] = []
                if let walker = fm.enumerator(at: session.rootURL, includingPropertiesForKeys: nil) {
                    for case let url as URL in walker {
                        let attributes = try fm.attributesOfItem(atPath: url.path)
                        if attributes[.type] as? FileAttributeType == .typeRegular {
                            staged.append(session.archivePath(of: url))
                        }
                    }
                }
                check("mounting a ZIP writes no file contents at all", staged.isEmpty, "\(staged)")
                check("mounting a ZIP does write the directory skeleton",
                      fm.fileExists(atPath: session.rootURL.appendingPathComponent(folder.lastPathComponent).path))
                check("mounting a ZIP writes the symbolic links, so containment can be judged",
                      (try? fm.destinationOfSymbolicLink(atPath: session.rootURL
                        .appendingPathComponent(folder.lastPathComponent)
                        .appendingPathComponent("escape").path)) != nil)

                // Listing one directory brings its own files and nothing else.
                _ = try provider.listDirectory(logicalFolder)
                let deepPath = session.rootURL.appendingPathComponent(folder.lastPathComponent)
                    .appendingPathComponent(nested.lastPathComponent)
                    .appendingPathComponent(note.lastPathComponent)
                check("listing a directory leaves a deeper directory's files alone",
                      !fm.fileExists(atPath: deepPath.path))
                _ = try provider.listDirectory(logicalNested)
                check("listing a directory brings in that directory's own files",
                      fm.fileExists(atPath: deepPath.path)
                      && (try? String(contentsOf: deepPath, encoding: .utf8)) == "snapshot contents")

                check("ZIP session preserves original logical archive identity", session.archiveURL == archive)
                check("root maps between original ZIP and private directory", try workspace.physicalURL(for: archive) == session.rootURL && workspace.logicalURL(for: session.rootURL) == archive)
                let physicalNote = try workspace.physicalURL(for: logicalNote)
                check("special characters survive component-by-component mapping", try workspace.logicalURL(for: physicalNote) == logicalNote && physicalNote.lastPathComponent == note.lastPathComponent && String(contentsOf: physicalNote) == "snapshot contents")
                check("child and root parents remain logical file locations", logicalNested.deletingLastPathComponent().path == logicalFolder.path && workspace.logicalURL(for: session.rootURL).deletingLastPathComponent().path == fixture.path)
                check("registry recognizes logical and physical descendants", workspace.session(for: logicalNote) === session && workspace.session(for: physicalNote) === session && workspace.containsArchiveLocation(logicalFolder))
                check("ordinary siblings never become archive locations", !workspace.containsArchiveLocation(outside) && workspace.logicalURL(for: outside) == outside)
                let roots = try provider.listDirectory(archive)
                check("archive provider lists logical roots with readable snapshot content", roots.count == 1 && roots[0].url == logicalFolder && roots[0].isArchiveEntry && roots[0].isNavigable && roots[0].contentURL != roots[0].url)
                let entries = try provider.listDirectory(logicalFolder)
                let escaped = entries.first { $0.name == "escape" }!
                let missing = entries.first { $0.name == "missing" }!
                let safeLink = entries.first { $0.name == "safe-link" }!
                check("escaped links remain inert visible entries", !escaped.canAccess && !escaped.isNavigable && escaped.publishedContentURL == nil && !ThumbnailProvider.canPreview(escaped))
                check("dangling links remain inert without breaking directory listing", !missing.canAccess && missing.publishedContentURL == nil && entries.contains { $0.name == nested.lastPathComponent })
                check("contained symlinks remain readable", safeLink.canAccess && safeLink.publishedContentURL != nil)
                check("physicalURL rejects escaped links and private workspace parents", (try? workspace.physicalURL(for: escaped.url)) == nil && (try? workspace.physicalURL(for: session.rootURL.appendingPathComponent("../unpublished"))) == nil)
                let noteItem = try provider.listDirectory(logicalNested).first!
                check("content items expose logical identity and physical bytes separately", noteItem.url == logicalNote && noteItem.publishedContentURL == physicalNote)
                let ordinaryZIP = FileItem(url: archive)!
                check("ordinary ZIP item still reads original after session preparation", !ordinaryZIP.isArchiveEntry && ordinaryZIP.contentURL == archive && ordinaryZIP.publishedContentURL == archive)
                let alias = fixture.appendingPathComponent("snapshot-alias")
                try fm.createSymbolicLink(at: alias, withDestinationURL: session.rootURL)
                let aliasFolder = alias.appendingPathComponent(folder.lastPathComponent)
                let aliasNote = aliasFolder.appendingPathComponent(nested.lastPathComponent).appendingPathComponent(note.lastPathComponent)
                check("snapshot aliases retain archive ownership and logical navigation", workspace.session(for: aliasFolder) === session && workspace.containsArchiveLocation(aliasFolder) && workspace.logicalURL(for: aliasFolder) == logicalFolder && workspace.logicalURL(for: alias) == archive)
                check("snapshot aliases read only their validated snapshot contents", try workspace.physicalURL(for: aliasNote) == physicalNote && String(contentsOf: workspace.physicalURL(for: aliasNote)) == "snapshot contents")
                let aliasedEntries = try provider.listDirectory(aliasFolder)
                check("aliased directory listing keeps read-only archive items", !aliasedEntries.isEmpty && aliasedEntries.allSatisfy { $0.isArchiveEntry && $0.url.path.hasPrefix(logicalFolder.path + "/") } && aliasedEntries.first { $0.name == "escape" }?.canAccess == false,
                      "expected=\(logicalFolder.path), entries=\(aliasedEntries.map { "\($0.name): \($0.url.path), archive=\($0.isArchiveEntry), access=\($0.canAccess)" })")
                let aliasEscape = aliasFolder.appendingPathComponent("escape")
                check("alias escape links retain ownership before their targets resolve", workspace.session(for: aliasEscape) === session && workspace.logicalURL(for: aliasEscape) == logicalFolder.appendingPathComponent("escape") && (try? workspace.physicalURL(for: aliasEscape)) == nil)
                let storageAlias = fixture.appendingPathComponent("storage-alias")
                try fm.createSymbolicLink(at: storageAlias, withDestinationURL: session.storageURL)
                check("private storage aliases cannot become ordinary writable locations", workspace.containsArchiveLocation(storageAlias) && workspace.archiveURL(containing: storageAlias) == archive && (try? workspace.physicalURL(for: storageAlias)) == nil && (try? provider.listDirectory(storageAlias)) == nil)
                let storageAliasNote = storageAlias.appendingPathComponent(session.rootURL.lastPathComponent).appendingPathComponent(folder.lastPathComponent).appendingPathComponent(nested.lastPathComponent).appendingPathComponent(note.lastPathComponent)
                check("storage aliases remap enclosed items without leaking temp paths", workspace.logicalURL(for: storageAliasNote) == logicalNote && (try? workspace.physicalURL(for: storageAliasNote)) == physicalNote)
                let ordinaryAlias = fixture.appendingPathComponent("ordinary-directory-alias")
                try fm.createSymbolicLink(at: ordinaryAlias, withDestinationURL: plainDirectory)
                let archiveFileAlias = fixture.appendingPathComponent("original-zip-alias")
                try fm.createSymbolicLink(at: archiveFileAlias, withDestinationURL: archive)
                check("aliases to ordinary directories and original ZIP files stay ordinary", workspace.session(for: ordinaryAlias) == nil && workspace.logicalURL(for: ordinaryAlias) == ordinaryAlias && workspace.session(for: archiveFileAlias) == nil && FileItem(url: archiveFileAlias)?.publishedContentURL == archiveFileAlias)
                let alternatePath = session.rootURL.path.hasPrefix("/private/var/")
                    ? String(session.rootURL.path.dropFirst("/private".count))
                    : "/private" + session.rootURL.path
                let alternateRoot = URL(fileURLWithPath: alternatePath, isDirectory: true)
                check("system temp aliases preserve the same snapshot identity", workspace.session(for: alternateRoot) === session && workspace.logicalURL(for: alternateRoot) == archive && (try? workspace.physicalURL(for: alternateRoot)) == session.rootURL)
                let ordinaryItems = try provider.listDirectory(fixture)
                check("provider delegates ordinary directory entries unchanged", ordinaryItems.first { $0.name == archive.lastPathComponent }?.publishedContentURL == ordinaryItems.first { $0.name == archive.lastPathComponent }?.url && ordinaryItems.first { $0.name == plainDirectory.lastPathComponent }?.isNavigable == true && ordinaryItems.allSatisfy { !$0.isArchiveEntry })
                AppPreferences.experimentalZIPBrowsingEnabled = false
                check("existing ZIP paths remain navigable after disabling experiment", PathCompleter.resolveDirectory(logicalNested.path, cwd: archive, home: fixture, workspace: workspace) == logicalNested)
                check("address rejects files inside prepared archives", PathCompleter.resolveNavigationLocation(logicalNote.path, cwd: archive, home: fixture, workspace: workspace) == nil)
                check("address completions list only safe archive directories", PathCompleter.completions(for: "", cwd: logicalFolder, home: fixture, workspace: workspace) == [nested.lastPathComponent + "/"])
                let offMain = try await Task.detached { try provider.listDirectory(logicalNested).map(\.url) }.value
                check("archive provider safely lists off the main thread", offMain == [logicalNote])
                try Data("edited temporary copy".utf8).write(to: physicalNote)
                check("snapshot edits never change source ZIP or originals", try Data(contentsOf: archive) == archiveData && String(contentsOf: note) == "snapshot contents")
                try fm.removeItem(at: physicalNote)
                try fm.createSymbolicLink(atPath: physicalNote.path, withDestinationPath: outside.path)
                check("cached entries revalidate targets before icon and preview reads", noteItem.publishedContentURL == nil && !ThumbnailProvider.canPreview(noteItem) && noteItem.icon(size: 16).size.width == 16)
                check("replaced snapshot links cannot read outside contents", try (try? workspace.physicalURL(for: logicalNote)) == nil && String(contentsOf: outside) == "outside original")
                check("alias ownership survives an externally replaced escaping member", workspace.session(for: aliasNote) === session && workspace.logicalURL(for: aliasNote) == logicalNote && (try? workspace.physicalURL(for: aliasNote)) == nil)
                let multipleZIP = try await SmokeFixtures.compress([folder, outside], to: fixture)
                let multipleSession = try await prepare(multipleZIP, workspace: workspace)
                check("archive workspace preserves multiple roots without an extra wrapper", Set(try provider.listDirectory(multipleZIP).map(\.name)) == Set([folder.lastPathComponent, outside.lastPathComponent]) && multipleSession.rootURL != session.rootURL)
                let empty = fixture.appendingPathComponent("empty.zip")
                try (Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0, count: 18)).write(to: empty)
                let emptySession = try await prepare(empty, workspace: workspace)
                check("archive workspace supports an empty ZIP root", try provider.listDirectory(empty).isEmpty && workspace.physicalURL(for: empty) == emptySession.rootURL)
                let corrupt = fixture.appendingPathComponent("corrupt.zip")
                try Data("not a ZIP".utf8).write(to: corrupt)
                var corruptFailed = false
                do { _ = try await prepare(corrupt, workspace: workspace) }
                catch { corruptFailed = true }
                check("corrupt archive preparation never registers a partial snapshot", corruptFailed && workspace.session(for: corrupt) == nil && (try? Data(contentsOf: corrupt)) == Data("not a ZIP".utf8))
                // Stage 1's worst bug. The pre-flight reads only the first
                // local header, so an archive that starts plain and holds an
                // encrypted member later got past it, and entering that folder
                // left the encrypted member as a zero-filled file that listed as
                // readable — served to Quick Look, Open and Copy as the real thing.
                let mixed = try SmokeFixtures.mixedEncryptionZip(in: fixture)
                let mixedSession = try await prepare(mixed, workspace: workspace)
                let mixedRows = try provider.listDirectory(mixed.appendingPathComponent("d"))
                let encryptedPath = mixedSession.rootURL.appendingPathComponent("d/b.txt")
                check("an encrypted member inside an ordinary ZIP never lands on disk as zeros",
                      !fm.fileExists(atPath: encryptedPath.path),
                      (try? Data(contentsOf: encryptedPath)).map { "found \($0.count) bytes: \($0.map { String(format: "%02x", $0) }.joined())" } ?? "")
                check("an encrypted member is never offered as a readable row",
                      !mixedRows.contains { $0.name == "b.txt" && $0.publishedContentURL != nil },
                      "\(mixedRows.map { "\($0.name) readable=\($0.publishedContentURL != nil)" })")
                check("the plain members beside it still open with their real bytes",
                      mixedRows.first { $0.name == "a.txt" }?.publishedContentURL
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "plain one"
                      && mixedRows.first { $0.name == "c.txt" }?.publishedContentURL
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "plain three")
                // A package is extracted whole — less any member of it that
                // is encrypted, which would otherwise arrive as zeros inside it.
                let appZIP = try SmokeFixtures.infoZip([("Demo.app/Contents/Info.plist", "plist", nil),
                                                        ("Demo.app/Contents/bin", "CODE", "pw")], in: fixture)
                let appSession = try await prepare(appZIP, workspace: workspace)
                let appPackage = appSession.rootURL.appendingPathComponent("Demo.app")
                check("a package is not on disk, not even as an empty shell, before it is asked for",
                      !fm.fileExists(atPath: appPackage.path))
                _ = try provider.listDirectory(appZIP)
                check("a package arrives whole when its folder is listed",
                      (try? String(contentsOf: appPackage.appendingPathComponent("Contents/Info.plist"), encoding: .utf8)) == "plist")
                check("an encrypted member inside a package is left out rather than written as zeros",
                      !fm.fileExists(atPath: appPackage.appendingPathComponent("Contents/bin").path))

                // A refused batch must not be remembered as done: the next
                // listing tries again rather than trusting an unfilled folder.
                let retryZIP = try SmokeFixtures.infoZip([("r/one.txt", "first", nil)], in: fixture)
                let retrySession = try await prepare(retryZIP, workspace: workspace)
                retrySession.spaceCheck = { needed, _ in .insufficientSpace(needed: needed, available: 0) }
                var refused: Error?
                do { _ = try provider.listDirectory(retryZIP.appendingPathComponent("r")) } catch { refused = error }
                check("a folder whose batch does not fit fails to list, rather than listing as empty",
                      refused?.localizedDescription.contains("temporary space") == true,
                      refused?.localizedDescription ?? "listed without error")
                retrySession.spaceCheck = { _, _ in nil }
                let retried = try provider.listDirectory(retryZIP.appendingPathComponent("r"))
                check("once there is room, the same folder is extracted on the next listing",
                      retried.first { $0.name == "one.txt" }?.publishedContentURL
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "first",
                      "\(retried.map(\.name))")

                try await rowChecks(in: fixture)
                try await systemAliasRecoveryChecks(archiveData: archiveData, folder: folder.lastPathComponent,
                                                    nested: nested.lastPathComponent, note: note.lastPathComponent)
                workspace.shutdownAll()
                check("workspace shutdown closes snapshots without touching originals", session.isClosed && !fm.fileExists(atPath: session.storageURL.path) && fm.fileExists(atPath: archive.path) && fm.fileExists(atPath: note.path))
                check("closed workspace rejects subsequent reads", (try? workspace.physicalURL(for: logicalFolder)) == nil)
                DispatchQueue.main.async(execute: completion)
            } catch {
                check("archive workspace setup and operations", false, error.localizedDescription)
            }
        }
    }

    /// D97: rows come from the table of contents. With nothing extracted on
    /// listing, every folder still lists, and each row says what a full
    /// extraction of the same ZIP says about the same item.
    @MainActor private static func rowChecks(in fixture: URL) async throws {
        let fm = FileManager.default
        let area = fixture.appendingPathComponent("rows", isDirectory: true)
        let source = area.appendingPathComponent("Rows", isDirectory: true)
        func write(_ path: String, _ text: String, mode: Int = 0o644) throws {
            let url = source.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try write("note.txt", "a note")
        try write("plain", "no extension")
        try write("tool", "#!/bin/sh\necho hi\n", mode: 0o755)
        try write(".hidden", "dot")
        try write("Demo.app/Contents/Info.plist", "<plist/>")
        try write("Demo.app/Contents/MacOS/Demo", "CODE", mode: 0o755)
        try write("Doc.rtfd/TXT.rtf", "{\\rtf1 hi}")
        try write("Kit.framework/Resources/x.txt", "kit")
        try write("Proj.xcodeproj/project.pbxproj", "// pbx")
        try write("sub/deep/inner.txt", "inner")
        for (name, target) in [("link-to-deep", "sub/deep"), ("link-to-inner", "sub/deep/inner.txt"),
                               ("dangling", "nowhere"), ("escaping", "/etc/hosts"), ("upward", "../../outside")] {
            try fm.createSymbolicLink(atPath: source.appendingPathComponent(name).path, withDestinationPath: target)
        }
        // Distinct whole-second dates, set last, so a date taken from anywhere
        // but the archive shows.
        let compared = ["note.txt", "plain", "tool", ".hidden", "Demo.app", "Doc.rtfd", "Kit.framework",
                        "Proj.xcodeproj", "sub"]
        for (index, name) in (compared + ["sub/deep/inner.txt"]).enumerated() {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 86_400)],
                                 ofItemAtPath: source.appendingPathComponent(name).path)
        }
        let archive = try await SmokeFixtures.compress([source], to: area)
        let full = area.appendingPathComponent("full", isDirectory: true)
        try fm.createDirectory(at: full, withIntermediateDirectories: false)
        let extractedResult = await withCheckedContinuation { continuation in
            FileOperations.extract(archive: archive, to: full) { continuation.resume(returning: $0) }
        }
        let extracted = try extractedResult.get()
        let reference = extracted.lastPathComponent == "Rows" ? extracted : extracted.appendingPathComponent("Rows")

        let workspace = ArchiveWorkspace(materializationPolicy: .never)
        defer { workspace.shutdownAll() }
        let session = try await prepare(archive, workspace: workspace)
        let provider = ArchiveFileProvider(base: LocalFileProvider(), workspace: workspace)
        let logicalRows = archive.appendingPathComponent("Rows")
        let rows = try provider.listDirectory(logicalRows)
        let references = try LocalFileProvider().listDirectory(reference)
        func describe(_ item: FileItem?) -> String {
            guard let item else { return "missing" }
            return "dir=\(item.isDirectory) pkg=\(item.isPackage) nav=\(item.isNavigable) hidden=\(item.isHidden) "
                + "type=\(item.contentType?.identifier ?? "nil") kind=\(item.kindDescription) "
                + "modified=\(item.modificationDate?.timeIntervalSince1970 ?? -1) created=\(item.creationDate?.timeIntervalSince1970 ?? -1)"
        }
        for name in compared {
            let row = rows.first { $0.name == name }, full = references.first { $0.name == name }
            check("rows: \(name) shows what its extracted copy shows, before a byte is extracted",
                  row != nil && describe(row) == describe(full), "row: \(describe(row)) | extracted: \(describe(full))")
        }
        for name in ["note.txt", "plain", "tool", ".hidden"] {
            let row = rows.first { $0.name == name }, full = references.first { $0.name == name }
            check("rows: \(name) has its extracted size", row != nil && row?.size == full?.size,
                  "\(String(describing: row?.size)) vs \(String(describing: full?.size))")
        }
        let demo = rows.first { $0.name == "Demo.app" }
        check("rows: a package's size is everything it holds", demo?.size == Int64("<plist/>".utf8.count + "CODE".utf8.count),
              "\(String(describing: demo?.size))")
        check("rows: dates come from the archive and Date Added and Date Last Opened are empty",
              rows.allSatisfy { $0.addedDate == nil && $0.accessDate == nil })

        let linkToDeep = rows.first { $0.name == "link-to-deep" }
        let linkToInner = rows.first { $0.name == "link-to-inner" }
        check("rows: a link into a folder not yet entered is accessible, and navigable",
              linkToDeep?.canAccess == true && linkToDeep?.isNavigable == true && linkToInner?.canAccess == true
              && linkToInner?.size == Int64("inner".utf8.count) && linkToInner?.kindDescription == references.first { $0.name == "link-to-inner" }?.kindDescription,
              "\(describe(linkToDeep)) / \(describe(linkToInner))")
        check("rows: dangling, absolute and upward links are inert",
              ["dangling", "escaping", "upward"].allSatisfy { name in rows.first { $0.name == name }?.canAccess == false })
        check("rows: a folder counts its items from the tree, a linked folder where it leads",
              rows.first { $0.name == "sub" }?.archiveChildCount == 1 && linkToDeep?.archiveChildCount == 1)
        let throughLink = try provider.listDirectory(logicalRows.appendingPathComponent("link-to-deep"))
        check("rows: a folder reached through a link lists what the link leads to, under the link's own path",
              throughLink.map(\.name) == ["inner.txt"]
              && throughLink.first?.url == logicalRows.appendingPathComponent("link-to-deep/inner.txt"),
              "\(throughLink.map(\.url.path))")
        for folder in ["sub", "sub/deep", "Kit.framework", "Kit.framework/Resources"] {
            _ = try provider.listDirectory(logicalRows.appendingPathComponent(folder))
        }
        let everything = (fm.enumerator(at: session.rootURL, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        let written = everything.filter {
            (try? fm.attributesOfItem(atPath: $0.path))?[.type] as? FileAttributeType == .typeRegular
        }.map(session.archivePath(of:))
        check("rows: listing every folder writes no file when nothing is extracted on listing", written.isEmpty, "\(written)")
        check("rows: the Kind probes are gone once read",
              !fm.fileExists(atPath: session.storageURL.appendingPathComponent(".tursora-kind-probes").path))

        // Bytes arrive only when asked for, and the row learns it from state.
        let inner = throughLink.first
        let sub = rows.first { $0.name == "sub" }
        check("rows: a file not yet extracted has no readable URL, and nor does its folder",
              inner?.publishedContentURL == nil && linkToInner?.publishedContentURL == nil && sub?.publishedContentURL == nil)
        try session.materializer.materialize(session.tree.batchPlan(for: ["Rows/sub/deep/inner.txt"]))
        check("rows: once extracted, the same row reads its bytes, through the link as well",
              inner?.publishedContentURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "inner"
              && linkToInner?.publishedContentURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "inner")
        check("rows: a folder is readable once everything below it is here",
              sub?.publishedContentURL != nil && rows.first { $0.name == "Kit.framework" }?.publishedContentURL == nil)

        // M48: grouping by Application asks by type, not by a path that does
        // not exist.
        let note = rows.first { $0.name == "note.txt" }, fullNote = references.first { $0.name == "note.txt" }
        let bucket = note.map(Grouping.applicationBucket)
        check("rows: grouping by Application puts an archive file under its default application",
              bucket != nil && bucket?.title != "No Application"
              && bucket?.title == fullNote.map(Grouping.applicationBucket)?.title,
              "\(String(describing: bucket?.title))")
    }

    @MainActor private static func systemAliasRecoveryChecks(archiveData: Data, folder: String,
                                                            nested: String, note: String) async throws {
        let fm = FileManager.default
        // Preserve this spelling: existing disk paths can standardize to /tmp,
        // but the virtual ZIP descendants still have /private/tmp components.
        let fixture = URL(fileURLWithPath: "/private/tmp/tursora-archive-system-alias-" + UUID().uuidString,
                          isDirectory: true)
        let workspace = ArchiveWorkspace()
        defer { workspace.shutdownAll(); try? fm.removeItem(at: fixture) }
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        let archive = fixture.appendingPathComponent("Broken.zip")
        let logicalNested = archive.appendingPathComponent(folder).appendingPathComponent(nested)
        check("system alias retry fixture preserves the restored private path", logicalNested.path.hasPrefix("/private/tmp/"))
        try Data("not a ZIP".utf8).write(to: archive)
        var rejected = false
        do { _ = try await prepare(archive, workspace: workspace) }
        catch { rejected = true }
        check("a broken ZIP under the system alias leaves its member target retryable",
              rejected && workspace.session(for: logicalNested) == nil && !workspace.hasPendingPreparation(for: archive))
        try archiveData.write(to: archive)
        let session = try await prepare(archive, workspace: workspace)
        let provider = ArchiveFileProvider(base: LocalFileProvider(), workspace: workspace)
        let entries = try provider.listDirectory(logicalNested)
        let physicalNested = try workspace.physicalURL(for: logicalNested)
        let expected = session.archiveURL.appendingPathComponent(folder).appendingPathComponent(nested)
        check("repairing a ZIP restores members requested through the system parent alias",
              workspace.session(for: logicalNested) === session && entries.map(\.name) == [note]
              && (try? String(contentsOf: workspace.physicalURL(for: logicalNested.appendingPathComponent(note)))) == "snapshot contents")
        check("system alias member mapping round-trips without losing ZIP path components",
              workspace.logicalURL(for: logicalNested).path == expected.path
              && workspace.logicalURL(for: physicalNested).path == expected.path)
        let fileAlias = fixture.appendingPathComponent("File Alias.zip")
        try fm.createSymbolicLink(at: fileAlias, withDestinationURL: archive)
        check("system parent aliases do not turn symlinks to original ZIP files into snapshot roots",
              workspace.session(for: fileAlias) == nil && workspace.logicalURL(for: fileAlias) == fileAlias)
    }

    private static func prepare(_ archive: URL, workspace: ArchiveWorkspace) async throws -> ArchiveBrowsingSession {
        try await withCheckedThrowingContinuation { continuation in
            workspace.prepare(archive: archive) { result in
                if !Thread.isMainThread { check("archive workspace callbacks return on main", false) }
                continuation.resume(with: result)
            }
        }
    }
}

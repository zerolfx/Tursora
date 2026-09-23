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
                check("unprepared ZIP file remains a readable ordinary file", try workspace.readableURL(for: archive) == archive)
                check("unprepared logical child cannot be read as an ordinary path", (try? workspace.readableURL(for: logicalNote)) == nil)
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
                check("root maps between original ZIP and private directory", try workspace.readableURL(for: archive) == session.rootURL && workspace.logicalURL(for: session.rootURL) == archive)
                let physicalNote = try workspace.readableURL(for: logicalNote)
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
                check("escaped links remain inert visible entries", !escaped.canAccess && !escaped.isNavigable && escaped.readableContentURL == nil && !ThumbnailProvider.canPreview(escaped))
                check("dangling links remain inert without breaking directory listing", !missing.canAccess && missing.readableContentURL == nil && entries.contains { $0.name == nested.lastPathComponent })
                check("contained symlinks remain readable", safeLink.canAccess && safeLink.readableContentURL != nil)
                check("readableURL rejects escaped links and private workspace parents", (try? workspace.readableURL(for: escaped.url)) == nil && (try? workspace.readableURL(for: session.rootURL.appendingPathComponent("../unpublished"))) == nil)
                let noteItem = try provider.listDirectory(logicalNested).first!
                check("content items expose logical identity and physical bytes separately", noteItem.url == logicalNote && noteItem.readableContentURL == physicalNote)
                let ordinaryZIP = FileItem(url: archive)!
                check("ordinary ZIP item still reads original after session preparation", !ordinaryZIP.isArchiveEntry && ordinaryZIP.contentURL == archive && ordinaryZIP.readableContentURL == archive)
                let alias = fixture.appendingPathComponent("snapshot-alias")
                try fm.createSymbolicLink(at: alias, withDestinationURL: session.rootURL)
                let aliasFolder = alias.appendingPathComponent(folder.lastPathComponent)
                let aliasNote = aliasFolder.appendingPathComponent(nested.lastPathComponent).appendingPathComponent(note.lastPathComponent)
                check("snapshot aliases retain archive ownership and logical navigation", workspace.session(for: aliasFolder) === session && workspace.containsArchiveLocation(aliasFolder) && workspace.logicalURL(for: aliasFolder) == logicalFolder && workspace.logicalURL(for: alias) == archive)
                check("snapshot aliases read only their validated snapshot contents", try workspace.readableURL(for: aliasNote) == physicalNote && String(contentsOf: workspace.readableURL(for: aliasNote)) == "snapshot contents")
                let aliasedEntries = try provider.listDirectory(aliasFolder)
                check("aliased directory listing keeps read-only archive items", !aliasedEntries.isEmpty && aliasedEntries.allSatisfy { $0.isArchiveEntry && $0.url.path.hasPrefix(logicalFolder.path + "/") } && aliasedEntries.first { $0.name == "escape" }?.canAccess == false,
                      "expected=\(logicalFolder.path), entries=\(aliasedEntries.map { "\($0.name): \($0.url.path), archive=\($0.isArchiveEntry), access=\($0.canAccess)" })")
                let aliasEscape = aliasFolder.appendingPathComponent("escape")
                check("alias escape links retain ownership before their targets resolve", workspace.session(for: aliasEscape) === session && workspace.logicalURL(for: aliasEscape) == logicalFolder.appendingPathComponent("escape") && (try? workspace.readableURL(for: aliasEscape)) == nil)
                let storageAlias = fixture.appendingPathComponent("storage-alias")
                try fm.createSymbolicLink(at: storageAlias, withDestinationURL: session.storageURL)
                check("private storage aliases cannot become ordinary writable locations", workspace.containsArchiveLocation(storageAlias) && workspace.archiveURL(containing: storageAlias) == archive && (try? workspace.readableURL(for: storageAlias)) == nil && (try? provider.listDirectory(storageAlias)) == nil)
                let storageAliasNote = storageAlias.appendingPathComponent(session.rootURL.lastPathComponent).appendingPathComponent(folder.lastPathComponent).appendingPathComponent(nested.lastPathComponent).appendingPathComponent(note.lastPathComponent)
                check("storage aliases remap enclosed items without leaking temp paths", workspace.logicalURL(for: storageAliasNote) == logicalNote && (try? workspace.readableURL(for: storageAliasNote)) == physicalNote)
                let ordinaryAlias = fixture.appendingPathComponent("ordinary-directory-alias")
                try fm.createSymbolicLink(at: ordinaryAlias, withDestinationURL: plainDirectory)
                let archiveFileAlias = fixture.appendingPathComponent("original-zip-alias")
                try fm.createSymbolicLink(at: archiveFileAlias, withDestinationURL: archive)
                check("aliases to ordinary directories and original ZIP files stay ordinary", workspace.session(for: ordinaryAlias) == nil && workspace.logicalURL(for: ordinaryAlias) == ordinaryAlias && workspace.session(for: archiveFileAlias) == nil && FileItem(url: archiveFileAlias)?.readableContentURL == archiveFileAlias)
                let alternatePath = session.rootURL.path.hasPrefix("/private/var/")
                    ? String(session.rootURL.path.dropFirst("/private".count))
                    : "/private" + session.rootURL.path
                let alternateRoot = URL(fileURLWithPath: alternatePath, isDirectory: true)
                check("system temp aliases preserve the same snapshot identity", workspace.session(for: alternateRoot) === session && workspace.logicalURL(for: alternateRoot) == archive && (try? workspace.readableURL(for: alternateRoot)) == session.rootURL)
                let ordinaryItems = try provider.listDirectory(fixture)
                check("provider delegates ordinary directory entries unchanged", ordinaryItems.first { $0.name == archive.lastPathComponent }?.readableContentURL == ordinaryItems.first { $0.name == archive.lastPathComponent }?.url && ordinaryItems.first { $0.name == plainDirectory.lastPathComponent }?.isNavigable == true && ordinaryItems.allSatisfy { !$0.isArchiveEntry })
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
                check("cached entries revalidate targets before icon and preview reads", noteItem.readableContentURL == nil && !ThumbnailProvider.canPreview(noteItem) && noteItem.icon(size: 16).size.width == 16)
                check("replaced snapshot links cannot read outside contents", try (try? workspace.readableURL(for: logicalNote)) == nil && String(contentsOf: outside) == "outside original")
                check("alias ownership survives an externally replaced escaping member", workspace.session(for: aliasNote) === session && workspace.logicalURL(for: aliasNote) == logicalNote && (try? workspace.readableURL(for: aliasNote)) == nil)
                let multipleZIP = try await SmokeFixtures.compress([folder, outside], to: fixture)
                let multipleSession = try await prepare(multipleZIP, workspace: workspace)
                check("archive workspace preserves multiple roots without an extra wrapper", Set(try provider.listDirectory(multipleZIP).map(\.name)) == Set([folder.lastPathComponent, outside.lastPathComponent]) && multipleSession.rootURL != session.rootURL)
                let empty = fixture.appendingPathComponent("empty.zip")
                try (Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0, count: 18)).write(to: empty)
                let emptySession = try await prepare(empty, workspace: workspace)
                check("archive workspace supports an empty ZIP root", try provider.listDirectory(empty).isEmpty && workspace.readableURL(for: empty) == emptySession.rootURL)
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
                      !mixedRows.contains { $0.name == "b.txt" && $0.readableContentURL != nil },
                      "\(mixedRows.map { "\($0.name) readable=\($0.readableContentURL != nil)" })")
                check("the plain members beside it still open with their real bytes",
                      mixedRows.first { $0.name == "a.txt" }?.readableContentURL
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "plain one"
                      && mixedRows.first { $0.name == "c.txt" }?.readableContentURL
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
                      retried.first { $0.name == "one.txt" }?.readableContentURL
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "first",
                      "\(retried.map(\.name))")

                try await systemAliasRecoveryChecks(archiveData: archiveData, folder: folder.lastPathComponent,
                                                    nested: nested.lastPathComponent, note: note.lastPathComponent)
                workspace.shutdownAll()
                check("workspace shutdown closes snapshots without touching originals", session.isClosed && !fm.fileExists(atPath: session.storageURL.path) && fm.fileExists(atPath: archive.path) && fm.fileExists(atPath: note.path))
                check("closed workspace rejects subsequent reads", (try? workspace.readableURL(for: logicalFolder)) == nil)
                DispatchQueue.main.async(execute: completion)
            } catch {
                check("archive workspace setup and operations", false, error.localizedDescription)
            }
        }
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
        let physicalNested = try workspace.readableURL(for: logicalNested)
        let expected = session.archiveURL.appendingPathComponent(folder).appendingPathComponent(nested)
        check("repairing a ZIP restores members requested through the system parent alias",
              workspace.session(for: logicalNested) === session && entries.map(\.name) == [note]
              && (try? String(contentsOf: workspace.readableURL(for: logicalNested.appendingPathComponent(note)))) == "snapshot contents")
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

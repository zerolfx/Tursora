import AppKit

enum ArchiveWorkspaceSmokeTests {
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
                let created = try await compress([folder], to: fixture)
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
                let multipleZIP = try await compress([folder, outside], to: fixture)
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
                workspace.shutdownAll()
                check("workspace shutdown closes snapshots without touching originals", session.isClosed && !fm.fileExists(atPath: session.storageURL.path) && fm.fileExists(atPath: archive.path) && fm.fileExists(atPath: note.path))
                check("closed workspace rejects subsequent reads", (try? workspace.readableURL(for: logicalFolder)) == nil)
                DispatchQueue.main.async(execute: completion)
            } catch {
                check("archive workspace setup and operations", false, error.localizedDescription)
            }
        }
    }

    private static func prepare(_ archive: URL, workspace: ArchiveWorkspace) async throws -> ArchiveBrowsingSession {
        try await withCheckedThrowingContinuation { continuation in
            workspace.prepare(archive: archive) { result in
                if !Thread.isMainThread { check("archive workspace callbacks return on main", false) }
                continuation.resume(with: result)
            }
        }
    }
    private static func compress(_ urls: [URL], to directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            FileOperations.compress(urls: urls, to: directory) { continuation.resume(with: $0) }
        }
    }
    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        if success { print("ok   \(name)") }
        else { print("FAIL  \(name) \(detail)"); fflush(stdout); exit(1) }
    }
}

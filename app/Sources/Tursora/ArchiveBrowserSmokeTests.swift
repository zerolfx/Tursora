import AppKit

enum ArchiveBrowserSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            let fixture = fm.temporaryDirectory.appendingPathComponent("tursora-zip-browser-tests-" + UUID().uuidString)
            var sessions: [ArchiveBrowsingSession] = []
            do {
                try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
                defer {
                    sessions.forEach { $0.close() }
                    try? fm.removeItem(at: fixture)
                }
                print("== experimental ZIP browsing ==")
                let boundary = URL(fileURLWithPath: "/tmp/example")
                check("ZIP browsing: containment uses whole path components", ArchiveBrowsingSession.containsPath(root: boundary, candidate: boundary.appendingPathComponent("inside")) && !ArchiveBrowsingSession.containsPath(root: boundary, candidate: URL(fileURLWithPath: "/tmp/example-other")))
                check("ZIP browsing: parent traversal cannot pass containment", !ArchiveBrowsingSession.containsPath(root: boundary, candidate: boundary.appendingPathComponent("../outside")))

                let docs = fixture.appendingPathComponent("Docs", isDirectory: true)
                let nested = docs.appendingPathComponent("Inner", isDirectory: true)
                try fm.createDirectory(at: nested, withIntermediateDirectories: true)
                let sourceNote = docs.appendingPathComponent("notes.txt")
                try Data("original note".utf8).write(to: sourceNote)
                try Data("nested note".utf8).write(to: nested.appendingPathComponent("nested.txt"))
                let welcome = fixture.appendingPathComponent("welcome.txt")
                try Data("welcome".utf8).write(to: welcome)
                let outside = fixture.appendingPathComponent("outside.txt")
                try Data("must stay untouched".utf8).write(to: outside)
                try fm.createSymbolicLink(atPath: docs.appendingPathComponent("outside-link").path, withDestinationPath: outside.path)
                try fm.createSymbolicLink(atPath: docs.appendingPathComponent("inside-link").path, withDestinationPath: "notes.txt")
                try fm.createSymbolicLink(atPath: docs.appendingPathComponent("missing-link").path, withDestinationPath: "does-not-exist")
                let archive = try await compress([docs, welcome], to: fixture)
                let sourceZIP = try Data(contentsOf: archive)

                var opened: [URL] = []
                let controller = ArchiveBrowserController(archive: archive, fileOpener: { opened.append($0); return true })
                check("ZIP browsing: constructing the window does not extract", controller.session == nil && !controller.isLoading && controller.entries.isEmpty)
                check("ZIP browsing: window identifies the original ZIP and read-only mode", controller.window?.representedURL == archive.resolvingSymlinksInPath() && controller.window?.subtitle.contains("Read-only") == true)
                check("ZIP browsing: external edit limitations are visible", controller.noteLabel.stringValue.contains("do not update the ZIP") && controller.noteLabel.stringValue.contains("Save As"))

                let session = try await prepare(archive)
                sessions.append(session)
                let mode = try fm.attributesOfItem(atPath: session.storageURL.path)[.posixPermissions] as? NSNumber
                check("ZIP browsing: extraction uses a private session directory", mode?.intValue == 0o700 && session.storageURL != archive.deletingLastPathComponent())
                let rootEntries = try session.entries(in: session.rootURL)
                check("ZIP browsing: multiple archive roots are not wrapped again", Set(rootEntries.map(\.name)) == Set(["Docs", "welcome.txt"]))
                let extractedDocs = session.rootURL.appendingPathComponent("Docs")
                let childEntries = try session.entries(in: extractedDocs)
                check("ZIP browsing: folders sort before files", childEntries.first?.name == "Inner")
                check("ZIP browsing: links outside extraction are inaccessible", childEntries.first { $0.name == "outside-link" }?.canAccess == false && (try? session.validatedURL(extractedDocs.appendingPathComponent("outside-link"))) == nil)
                check("ZIP browsing: internal links remain usable", childEntries.first { $0.name == "inside-link" }?.canAccess == true)
                check("ZIP browsing: a dangling link does not hide the rest of its folder", childEntries.first { $0.name == "missing-link" }?.canAccess == false && childEntries.contains { $0.name == "notes.txt" })

                controller.install(session)
                await settle(controller)
                check("ZIP browsing: initial listing never launches an enclosed file", opened.isEmpty && controller.entries.count == 2 && controller.tableView.numberOfRows == 2)
                check("ZIP browsing: root breadcrumb displays the ZIP name", controller.pathControl.pathItems.map(\.title) == [archive.lastPathComponent])
                select("Docs", in: controller)
                controller.openSelection(nil)
                await settle(controller)
                check("ZIP browsing: opening a folder navigates inside the archive", controller.currentDirectory == extractedDocs && opened.isEmpty && controller.pathControl.pathItems.map(\.title) == [archive.lastPathComponent, "Docs"])

                select("notes.txt", in: controller)
                let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                controller.tableView.keyDown(with: key)
                check("ZIP browsing: Return opens only the selected temporary copy", opened.count == 1 && opened[0] == extractedDocs.appendingPathComponent("notes.txt") && opened[0] != sourceNote)
                controller.doubleClicked(nil)
                check("ZIP browsing: a blank-area double click cannot reopen an old selection", opened.count == 1)
                try Data("edited temporary copy".utf8).write(to: opened[0])
                check("ZIP browsing: external edits cannot change ZIP or source files", (try Data(contentsOf: archive)) == sourceZIP && (try? String(contentsOf: sourceNote, encoding: .utf8)) == "original note")

                select("outside-link", in: controller)
                controller.openSelection(nil)
                check("ZIP browsing: escaped links never reach the external opener", opened.count == 1 && controller.errorMessage != nil && (try? String(contentsOf: outside, encoding: .utf8)) == "must stay untouched")
                select("missing-link", in: controller)
                controller.openSelection(nil)
                check("ZIP browsing: dangling links never reach the external opener", opened.count == 1 && controller.errorMessage?.contains("unavailable") == true, "opened=\(opened), error=\(String(describing: controller.errorMessage)), row=\(controller.tableView.selectedRow), entry=\(controller.entries.first { $0.name == "missing-link" }?.canAccess as Any)")
                controller.navigate(to: outside.deletingLastPathComponent())
                check("ZIP browsing: direct outside navigation is rejected", controller.currentDirectory == extractedDocs && controller.errorMessage != nil)
                controller.goUp(nil)
                await settle(controller)
                check("ZIP browsing: Up returns to archive root", controller.currentDirectory == session.rootURL)
                controller.goBack(nil)
                await settle(controller)
                check("ZIP browsing: Back restores the enclosed folder", controller.currentDirectory == extractedDocs)
                controller.navigateToPathComponent(0)
                await settle(controller)
                check("ZIP browsing: breadcrumb navigates without exposing the temp hierarchy", controller.currentDirectory == session.rootURL && controller.pathControl.pathItems.count == 1)
                controller.goUp(nil)
                check("ZIP browsing: Up cannot leave the archive root", controller.currentDirectory == session.rootURL && !controller.isLoading)
                controller.close()
                check("ZIP browsing: closing the window retains externally opened copies", fm.fileExists(atPath: opened[0].path) && !session.isClosed)
                session.close()
                check("ZIP browsing: session cleanup removes only owned extraction", !fm.fileExists(atPath: session.storageURL.path) && fm.fileExists(atPath: archive.path) && (try? String(contentsOf: outside, encoding: .utf8)) == "must stay untouched")
                check("ZIP browsing: ended sessions cannot be accessed again", (try? session.entries(in: session.rootURL)) == nil)
                try await normalBrowserRouting(archive: archive, directory: fixture)

                let singleFolder = try await compress([docs], to: fixture)
                let folderSession = try await prepare(singleFolder)
                sessions.append(folderSession)
                check("ZIP browsing: a single root folder remains part of the hierarchy", try folderSession.entries(in: folderSession.rootURL).map(\.name) == ["Docs"])
                let singleFile = try await compress([welcome], to: fixture)
                let fileSession = try await prepare(singleFile)
                sessions.append(fileSession)
                check("ZIP browsing: a one-file ZIP still has a browsable root", try fileSession.entries(in: fileSession.rootURL).map(\.name) == ["welcome.txt"])
                let empty = fixture.appendingPathComponent("empty.zip")
                try (Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0, count: 18)).write(to: empty)
                let emptySession = try await prepare(empty)
                sessions.append(emptySession)
                check("ZIP browsing: empty ZIP opens as an empty folder", try emptySession.entries(in: emptySession.rootURL).isEmpty)
                let corrupt = fixture.appendingPathComponent("broken.zip")
                try Data("broken".utf8).write(to: corrupt)
                let failed = await withCheckedContinuation { continuation in
                    ArchiveBrowsingSession.prepare(archive: corrupt) { result in
                        check("ZIP browsing: failed preparation returns on main", Thread.isMainThread)
                        if case .failure = result { continuation.resume(returning: true) }
                        else { continuation.resume(returning: false) }
                    }
                }
                check("ZIP browsing: corrupt ZIP fails without altering the archive", failed && (try? String(contentsOf: corrupt, encoding: .utf8)) == "broken")
                sessions.forEach { $0.close() }
                try fm.removeItem(at: fixture)
                completion()
            } catch {
                sessions.forEach { $0.close() }
                try? fm.removeItem(at: fixture)
                check("ZIP browsing: unexpected error", false, error.localizedDescription)
            }
        }
    }

    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        print("\(success ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !success { exit(1) }
    }

    @MainActor private static func normalBrowserRouting(archive: URL, directory: URL) async throws {
        let previousFlag = AppPreferences.experimentalZIPBrowsingEnabled
        let previousMode = ViewPreferences.viewMode
        let previousGroup = ViewPreferences.groupKey
        let previousLastGroup = ViewPreferences.lastGroupKey
        defer {
            AppPreferences.experimentalZIPBrowsingEnabled = previousFlag
            ViewPreferences.viewMode = previousMode
            ViewPreferences.groupKey = previousGroup
            ViewPreferences.lastGroupKey = previousLastGroup
        }
        let browser = BrowserViewController(provider: LocalFileProvider(), initialURL: directory)
        browser.view.frame = NSRect(x: 0, y: 0, width: 700, height: 460)
        browser.setGroupKey(.none)
        await waitUntil("initial fixture", detail: { "generation=\(browser.model.generation), url=\(String(describing: browser.currentURL))" }) { browser.model.generation > 0 }
        for mode: ViewMode in [.details, .icons] {
            browser.setViewMode(mode)
            browser.view.layoutSubtreeIfNeeded()
            browser.fileView.select(urls: [archive])
            AppPreferences.experimentalZIPBrowsingEnabled = true
            browser.openSelection()
            await waitUntil("\(mode) experimental open", detail: { "selection=\(browser.fileView.selectedItems.map(\.url)), archive=\(archive), model=\(browser.model.items.map(\.url)), windows=\(ArchiveBrowserController.openWindows.map(\.archiveURL))" }) { ArchiveBrowserController.openWindows.contains { $0.archiveURL == archive.resolvingSymlinksInPath() } }
            guard let opened = ArchiveBrowserController.openWindows.first(where: { $0.archiveURL == archive.resolvingSymlinksInPath() }) else { return }
            await settle(opened)
            check("ZIP browsing: \(mode.rawValue) normal Open enters the experiment", opened.session != nil && opened.errorMessage == nil && Set(opened.entries.map(\.name)) == Set(["Docs", "welcome.txt"]) && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Archive").path))
            let count = ArchiveBrowserController.openWindows.count
            browser.openSelection()
            check("ZIP browsing: \(mode.rawValue) reopening reuses the ZIP window", ArchiveBrowserController.openWindows.count == count && ArchiveBrowserController.openWindows.contains { $0 === opened })
            opened.close()
            opened.session?.close()
        }
        AppPreferences.experimentalZIPBrowsingEnabled = false
        browser.fileView.select(urls: [archive])
        browser.openSelection()
        let output = directory.appendingPathComponent("Archive")
        await waitUntil("default extraction selection", detail: { "selected=\(browser.fileView.selectedItems.map(\.url)), output=\(output), exists=\(FileManager.default.fileExists(atPath: output.path)), model=\(browser.model.items.map(\.url))" }) { browser.fileView.selectedItems.map { $0.url.standardizedFileURL.path } == [output.standardizedFileURL.path] }
        check("ZIP browsing: disabling the experiment restores extraction and exact selection", FileManager.default.fileExists(atPath: output.path) && !ArchiveBrowserController.openWindows.contains { $0.archiveURL == archive.resolvingSymlinksInPath() })
    }

    @MainActor private static func waitUntil(_ label: String, detail: () -> String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > deadline { check("ZIP browsing: \(label) completes", false, detail()); return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    @MainActor private static func settle(_ controller: ArchiveBrowserController) async {
        let deadline = Date().addingTimeInterval(15)
        while controller.isLoading {
            if Date() > deadline { check("ZIP browsing: listing completes", false); return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    @MainActor private static func select(_ name: String, in controller: ArchiveBrowserController) {
        guard let row = controller.entries.firstIndex(where: { $0.name == name }) else {
            check("ZIP browsing: fixture row exists", false, name); return
        }
        controller.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    private static func prepare(_ archive: URL) async throws -> ArchiveBrowsingSession {
        try await withCheckedThrowingContinuation { continuation in
            ArchiveBrowsingSession.prepare(archive: archive) { result in
                if !Thread.isMainThread { check("ZIP browsing: preparation returns on main", false) }
                continuation.resume(with: result)
            }
        }
    }
    private static func compress(_ urls: [URL], to directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            FileOperations.compress(urls: urls, to: directory) { continuation.resume(with: $0) }
        }
    }
}

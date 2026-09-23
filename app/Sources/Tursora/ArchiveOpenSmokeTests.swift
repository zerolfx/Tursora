import AppKit
import Quartz

/// Open, Copy and Copy to Other Pane on ZIP entries that are not extracted yet
/// (D98), through the real pane: all three views, with a split pane and a
/// second tab open, grouping on and a filter applied, and nothing extracted
/// by listing, so every byte these checks see was brought by the action.
enum ArchiveOpenSmokeTests: SmokeSuite {
    static let checkPrefix = "archive open: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            guard let root = try? SmokeFixtures.temporaryDirectory("archive-open") else {
                check("fixture created", false); completion(); return
            }
            let workspace = ArchiveWorkspace.shared
            let runner = SystemArchiveToolRunner.shared
            let previousPolicy = workspace.materializationPolicy
            // The harness starts with ZIP browsing off; this suite needs it on.
            let previousBrowsing = AppPreferences.experimentalZIPBrowsingEnabled
            var window: MainWindowController?
            var openedArchives: [URL] = []
            let viewStore = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
            defer {
                runner.beforeRunForTesting = nil
                window?.close()
                // Write now what closing scheduled, or it lands after the
                // fixture is removed and leaves the folder behind.
                try? viewStore.flush()
                workspace.materializationPolicy = previousPolicy
                AppPreferences.experimentalZIPBrowsingEnabled = previousBrowsing
                // This suite's own sessions only: shutdownAll latches the
                // shared workspace closed for every later suite.
                openedArchives.forEach { workspace.session(for: $0)?.close() }
                try? fm.removeItem(at: root)
                completion()
            }
            do {
                print("== archive open and copy out ==")
                let box = root.appendingPathComponent("Box", isDirectory: true)
                func write(_ path: String, _ text: String) throws {
                    let url = box.appendingPathComponent(path)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: url)
                }
                try write("a.txt", "alpha")
                try write("b.txt", "bravo")
                try write("c.txt", "charlie")
                try write("e.md", "echo")
                try write("Doc.rtfd/TXT.rtf", "{\\rtf1 doc}")
                try write("Sub/Never/deep.txt", "deep")
                try write("Tool.app/Contents/Info.plist", "plist")
                try write("Tool.app/Contents/MacOS/Tool", "code")
                let source = try await SmokeFixtures.compress([box], to: root)
                let expected = tree(at: box)

                workspace.materializationPolicy = .never
                AppPreferences.experimentalZIPBrowsingEnabled = true
                let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                              viewPropertiesStore: viewStore)
                window = wc
                wc.window?.makeKeyAndOrderFront(nil)
                await waitUntil("the fixture folder lists") { wc.browser.model.generation > 0 }
                wc.tabs.newTab(at: root)
                wc.tabs.selectTab(at: 0)
                wc.tabs.toggleSplit()
                let pb = NSPasteboard.general

                for mode in ViewMode.allCases {
                    let name = mode.rawValue
                    let archive = root.appendingPathComponent("Box-\(name).zip")
                    try fm.copyItem(at: source, to: archive)
                    openedArchives.append(archive)
                    let destination = root.appendingPathComponent("out-\(name)", isDirectory: true)
                    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
                    guard let other = wc.tabs.currentPage.inactive else { check("\(name): a split pane is open", false); return }
                    other.navigate(to: destination)
                    await waitUntil("\(name): the other pane lists its folder") {
                        other.model.url?.standardizedFileURL == destination.standardizedFileURL
                    }
                    let pane = wc.browser
                    pane.setViewMode(mode)
                    let logicalBox = archive.appendingPathComponent("Box")
                    pane.navigate(to: logicalBox)
                    await waitUntil("\(name): the archive folder lists", detail: {
                        "items=\(pane.model.items.map(\.name)) at=\(pane.currentURL?.path ?? "nil") preparing=\(pane.isPreparingArchive)"
                    }) {
                        Set(pane.model.items.map(\.name)).isSuperset(of: ["a.txt", "Sub", "Tool.app", "Doc.rtfd"])
                    }
                    guard let session = workspace.session(for: archive) else { check("\(name): a session exists", false); return }
                    pane.setGroupKey(.kind)
                    check("\(name): listing extracted nothing", session.materializer.publishedPaths.isEmpty,
                          "\(session.materializer.publishedPaths.sorted())")

                    // Enabling reads the rows alone: no menu, toolbar or palette
                    // query may run the archive tool (D98).
                    let runsBefore = runner.invocations
                    pane.fileView.select(urls: ["a.txt", "Sub", "Tool.app"].map { logicalBox.appendingPathComponent($0) })
                    var enabled = pane.canOpenSelection && pane.canPreviewSelection && pane.hasAccessibleSelection
                    for action: MainMenu.FileAction in [.open, .quickLook, .copy] {
                        let item = NSMenuItem(title: "", action: #selector(MainWindowController.performFileAction(_:)), keyEquivalent: "")
                        item.representedObject = action.rawValue
                        enabled = enabled && wc.validateMenuItem(item)
                    }
                    for selector in [#selector(BrowserViewController.copy(_:)), #selector(BrowserViewController.copyToOtherPane(_:))] {
                        enabled = enabled && pane.validateMenuItem(NSMenuItem(title: "", action: selector, keyEquivalent: ""))
                    }
                    enabled = enabled && CommandPaletteRunner.contextualEnabled(ShortcutCatalog.openID, in: wc)
                        && CommandPaletteRunner.contextualEnabled(ShortcutCatalog.previewID, in: wc)
                    let menu = pane.buildContextMenu(for: pane.fileView.selectedItems)
                    _ = wc.sharingItems
                    let resolved = PathCompleter.resolveDirectory(logicalBox.appendingPathComponent("Sub/Never").path,
                                                                  cwd: root, home: root)
                    check("\(name): enabling, the context menu and path resolution never run the archive tool",
                          enabled && menu.items.first { $0.title == "Copy" }?.isEnabled == true
                          && resolved?.standardizedFileURL == logicalBox.appendingPathComponent("Sub/Never").standardizedFileURL
                          && runner.invocations == runsBefore && session.materializer.publishedPaths.isEmpty,
                          "runs \(runsBefore) -> \(runner.invocations), resolved \(resolved?.path ?? "nil")")

                    // Open With is built from the type, before any byte exists.
                    for entry in ["a.txt", "Doc.rtfd"] {
                        guard let item = pane.model.items.first(where: { $0.name == entry }) else {
                            check("\(name): \(entry) is listed", false); return
                        }
                        let openWith = pane.buildContextMenu(for: [item]).items.first { $0.title == "Open With" }
                        let apps = openWith?.submenu?.items.filter { $0.representedObject is URL } ?? []
                        check("\(name): Open With lists applications for \(entry) before it is extracted",
                              !apps.isEmpty && item.publishedContentURL == nil, "\(apps.map(\.title))")
                    }

                    // Open: one request for the whole selection, one launch each.
                    var opened: [URL] = []
                    pane.archiveFileOpener = { opened.append($0); return true }
                    pane.nameFilter = "*.txt"
                    await waitUntil("\(name): the filter narrows to the text files") {
                        pane.model.items.map(\.name).sorted() == ["a.txt", "b.txt", "c.txt"]
                    }
                    pane.fileView.select(urls: ["a.txt", "b.txt", "c.txt"].map { logicalBox.appendingPathComponent($0) })
                    let runsBeforeOpen = runner.invocations
                    pane.openSelection()
                    pane.openSelection()
                    await expectEventually("\(name): Open on three files not yet extracted launches each once") { opened.count == 3 }
                    await drainMainQueue()
                    let contents = opened.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.sorted()
                    check("\(name): a double Open launches each file once, with its real bytes, from one run",
                          opened.count == 3 && contents == ["alpha", "bravo", "charlie"] && runner.invocations == runsBeforeOpen + 1,
                          "opened=\(opened.map(\.lastPathComponent)) runs=\(runner.invocations - runsBeforeOpen)")
                    pane.nameFilter = ""
                    await waitUntil("\(name): the filter clears") { pane.model.items.count >= 7 }

                    // Quick Look waits for the bytes, then shows them.
                    pane.fileView.select(urls: [logicalBox.appendingPathComponent("e.md")])
                    check("\(name): Quick Look has nothing to show before the file is extracted", pane.previewSelectionURLs.isEmpty)
                    pane.toggleQuickLook()
                    await expectEventually("\(name): Quick Look brings the file and then shows it") {
                        session.isPublished("Box/e.md")
                            && pane.previewSelectionURLs.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "echo"
                    }
                    await drainMainQueue()
                    if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true {
                        QLPreviewPanel.shared()?.orderOut(nil)
                    }

                    // Copy claims the pasteboard at once and writes it when ready.
                    pane.fileView.select(urls: [logicalBox.appendingPathComponent("Tool.app")])
                    let before = pb.changeCount
                    pane.copy(nil)
                    check("\(name): Copy of an entry not yet extracted clears the pasteboard at once",
                          pb.changeCount != before && pb.fileURLs.isEmpty)
                    await expectEventually("\(name): the copied package is on the pasteboard once extracted") {
                        pb.fileURLs.count == 1
                    }
                    let copiedApp = pb.fileURLs.first
                    check("\(name): the pasteboard holds the whole package",
                          copiedApp.flatMap { try? String(contentsOf: $0.appendingPathComponent("Contents/MacOS/Tool"), encoding: .utf8) } == "code")
                    pane.fileView.select(urls: [logicalBox.appendingPathComponent("Doc.rtfd")])
                    pane.copy(nil)
                    pb.clearContents()
                    pb.setString("copied meanwhile", forType: .string)
                    await waitUntil("\(name): the document finishes extracting") { session.isPublished("Box/Doc.rtfd") }
                    await drainMainQueue()
                    await drainMainQueue()
                    check("\(name): a Copy still being prepared never overwrites what was copied after it",
                          pb.string(forType: .string) == "copied meanwhile" && pb.fileURLs.isEmpty)

                    // Copy to Other Pane: the whole tree, never-entered folders
                    // and the package included (the Stage 1 partial-copy bug).
                    pane.navigate(to: archive)
                    await waitUntil("\(name): back at the archive root") {
                        pane.model.items.map(\.url.standardizedFileURL) == [logicalBox.standardizedFileURL]
                    }
                    pane.fileView.select(urls: [logicalBox])
                    let previousTask = pane.lastTransferTask
                    pane.copyToOtherPane(nil)
                    let copyTask = pane.lastTransferTask
                    check("\(name): Copy to Other Pane starts a transfer", copyTask != nil && copyTask !== previousTask)
                    let copied = destination.appendingPathComponent("Box")
                    await waitUntil("\(name): the folder is copied to the other pane") {
                        copyTask?.snapshot.isTerminal == true
                    }
                    check("\(name): Copy to Other Pane copies a folder byte for byte, subfolders never entered and the package included",
                          tree(at: copied) == expected, "\(tree(at: copied).keys.sorted()) vs \(expected.keys.sorted())")

                    // A copy still waiting for the archive tool: preparing, no
                    // Pause, and Cancel leaves the destination untouched.
                    let held = root.appendingPathComponent("Held-\(name).zip")
                    try fm.copyItem(at: source, to: held)
                    openedArchives.append(held)
                    let heldDestination = root.appendingPathComponent("held-out-\(name)", isDirectory: true)
                    try fm.createDirectory(at: heldDestination, withIntermediateDirectories: false)
                    other.navigate(to: heldDestination)
                    await waitUntil("\(name): the other pane moves to the held destination") {
                        other.model.url?.standardizedFileURL == heldDestination.standardizedFileURL
                    }
                    pane.navigate(to: held)
                    // By URL: the previous archive's root also lists just "Box".
                    await waitUntil("\(name): the held archive opens") {
                        pane.model.items.map(\.url.standardizedFileURL) == [held.appendingPathComponent("Box").standardizedFileURL]
                    }
                    let gate = WorkerGate()
                    runner.beforeRunForTesting = { gate.arriveAndWait() }
                    pane.fileView.select(urls: [held.appendingPathComponent("Box")])
                    let finishedTask = pane.lastTransferTask
                    pane.copyToOtherPane(nil)
                    await waitUntil("\(name): the copy reaches the archive tool") { gate.arrived }
                    let task = pane.lastTransferTask
                    check("\(name): the held copy is a new transfer", task != nil && task !== finishedTask)
                    let snapshot = task?.snapshot
                    check("\(name): a copy waiting for the archive tool is preparing and cannot pause",
                          snapshot?.state == .preparing && snapshot?.canPause == false,
                          "\(String(describing: snapshot?.state)) canPause=\(String(describing: snapshot?.canPause))")
                    task?.cancel()
                    runner.beforeRunForTesting = nil
                    gate.release()
                    await waitUntil("\(name): the cancelled copy ends") { task?.snapshot.isTerminal == true }
                    check("\(name): cancelling it leaves nothing in the destination",
                          task?.snapshot.state == .cancelled
                          && ((try? fm.contentsOfDirectory(atPath: heldDestination.path)) ?? ["?"]).isEmpty,
                          "\(String(describing: task?.snapshot.state)) \((try? fm.contentsOfDirectory(atPath: heldDestination.path)) ?? [])")
                    pane.navigate(to: root)
                    await waitUntil("\(name): leaving the archive") { pane.currentURL?.standardizedFileURL == root.standardizedFileURL }
                }

                try await reloadChecks(root: root, window: wc, openedArchives: &openedArchives)
            } catch {
                check("unexpected error", false, "\(error)")
            }
        }
    }

    /// A member that fails is sticky and shows unavailable; Reload forgets
    /// the failure so it is tried again.
    @MainActor private static func reloadChecks(root: URL, window wc: MainWindowController,
                                                openedArchives: inout [URL]) async throws {
        let workspace = ArchiveWorkspace.shared
        var data = SmokeFixtures.zip([("r/good.txt", "fine"), ("r/bad.txt", "corrupt me")])
        if let range = data.range(of: Data("corrupt me".utf8)) { data[range.lowerBound] ^= 0xFF }
        let archive = root.appendingPathComponent("Broken.zip")
        try data.write(to: archive)
        openedArchives.append(archive)
        let pane = wc.browser
        pane.setViewMode(.details)
        let folder = archive.appendingPathComponent("r")
        pane.navigate(to: folder)
        await waitUntil("the damaged archive lists") { pane.model.items.map(\.name).sorted() == ["bad.txt", "good.txt"] }
        guard let session = workspace.session(for: archive) else { check("a session exists", false); return }
        var opened: [URL] = []
        pane.archiveFileOpener = { opened.append($0); return true }
        pane.fileView.select(urls: [folder.appendingPathComponent("bad.txt")])
        pane.openSelection()
        await waitUntil("the damaged member is tried") {
            if case .failed = session.materializer.state(of: "r/bad.txt") { return true } else { return false }
        }
        await expectEventually("a member that failed to extract turns unavailable in the pane") {
            pane.model.items.first { $0.name == "bad.txt" }?.canAccess == false
        }
        check("its damaged bytes were never opened", opened.isEmpty)
        wc.reload(nil)
        await expectEventually("Reload forgets the failure, so the member can be tried again") {
            session.materializer.state(of: "r/bad.txt") == .absent
                && pane.model.items.first { $0.name == "bad.txt" }?.canAccess == true
        }
        pane.navigate(to: root)
        await waitUntil("leaving the damaged archive") { pane.currentURL?.standardizedFileURL == root.standardizedFileURL }
    }

    /// Every file under a folder, by relative path, with its bytes; folders
    /// as empty entries so an empty one still counts.
    private static func tree(at folder: URL) -> [String: Data] {
        let fm = FileManager.default
        var result: [String: Data] = [:]
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents.count
        let urls = (fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for url in urls {
            let relative = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            result[relative + (isDirectory.boolValue ? "/" : "")] = isDirectory.boolValue ? Data() : (try? Data(contentsOf: url)) ?? Data()
        }
        return result
    }
}

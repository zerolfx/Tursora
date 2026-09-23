import AppKit
import Quartz
import UniformTypeIdentifiers

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
                    // An archive page has no view settings of its own and
                    // opens with the default ones, so the mode is made the
                    // default while the pane is still on an ordinary folder.
                    pane.setViewMode(mode)
                    // Thumbnails are checked on their own below; here they
                    // would add runs of the archive tool to every count.
                    pane.setShowsPreviews(false)
                    pane.useCurrentViewAsDefault()
                    let logicalBox = archive.appendingPathComponent("Box")
                    pane.navigate(to: logicalBox)
                    await waitUntil("\(name): the archive folder lists", detail: {
                        "items=\(pane.model.items.map(\.name)) at=\(pane.currentURL?.path ?? "nil") preparing=\(pane.isPreparingArchive)"
                    }) {
                        Set(pane.model.items.map(\.name)).isSuperset(of: ["a.txt", "Sub", "Tool.app", "Doc.rtfd"])
                    }
                    guard let session = workspace.session(for: archive) else { check("\(name): a session exists", false); return }
                    check("\(name): the archive opens in the \(name) view", pane.viewMode == mode, "\(pane.viewMode)")
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
                    // Two items, so the column view shows no preview column —
                    // which would extract a single selected file by itself.
                    pane.fileView.select(urls: ["Tool.app", "Sub"].map { logicalBox.appendingPathComponent($0) })
                    let before = pb.changeCount
                    pane.copy(nil)
                    check("\(name): Copy of entries not yet extracted clears the pasteboard at once",
                          pb.changeCount != before && pb.fileURLs.isEmpty)
                    await expectEventually("\(name): the copied package and folder are on the pasteboard once extracted") {
                        pb.fileURLs.count == 2
                    }
                    let copiedApp = pb.fileURLs.first { $0.lastPathComponent == "Tool.app" }
                    let copiedFolder = pb.fileURLs.first { $0.lastPathComponent == "Sub" }
                    check("\(name): the pasteboard holds the whole package and the whole folder",
                          copiedApp.flatMap { try? String(contentsOf: $0.appendingPathComponent("Contents/MacOS/Tool"), encoding: .utf8) } == "code"
                          && copiedFolder.flatMap { try? String(contentsOf: $0.appendingPathComponent("Never/deep.txt"), encoding: .utf8) } == "deep")
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

                // The checks below run from the list view.
                wc.browser.setViewMode(.details)
                wc.browser.useCurrentViewAsDefault()
                try await reloadChecks(root: root, window: wc, openedArchives: &openedArchives)
                try await previewChecks(root: root, window: wc, openedArchives: &openedArchives)
                try await thumbnailChecks(root: root, window: wc, openedArchives: &openedArchives)
                try await dragChecks(root: root, window: wc, openedArchives: &openedArchives)
                try await prefetchChecks(root: root, window: wc, openedArchives: &openedArchives)
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

    /// Quick Look and the preview column on entries not yet extracted (D99).
    /// The automatic limit is lowered to 1 KiB for the run, so a 2 KiB member
    /// stands in for one over 64 MiB.
    @MainActor private static func previewChecks(root: URL, window wc: MainWindowController,
                                                 openedArchives: inout [URL]) async throws {
        let workspace = ArchiveWorkspace.shared
        let runner = SystemArchiveToolRunner.shared
        let previousLimit = ArchivePreviewLimit.automaticBytes
        ArchivePreviewLimit.automaticBytes = 1024
        defer { ArchivePreviewLimit.automaticBytes = previousLimit; runner.beforeRunForTesting = nil }
        let archive = root.appendingPathComponent("Look.zip")
        try SmokeFixtures.zip([("Box/a1.txt", "a1"), ("Box/a2-big.bin", String(repeating: "z", count: 2048)),
                               ("Box/b1.txt", "b1"), ("Box/b2.txt", "b2"), ("Box/c1.txt", "c1"),
                               ("Box/c2.txt", "c2")]).write(to: archive)
        openedArchives.append(archive)
        let folder = archive.appendingPathComponent("Box")
        func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
        func text(_ url: URL?) -> String? { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
        let pane = wc.browser
        pane.setViewMode(.details)
        pane.setGroupKey(.none)
        pane.navigate(to: folder)
        await waitUntil("preview: the archive lists") { pane.model.items.map(\.url.standardizedFileURL).contains(url("c2.txt").standardizedFileURL) }
        guard let session = workspace.session(for: archive) else { check("preview: a session exists", false); return }

        // Quick Look's data source, called directly: a placeholder first, the
        // file once it is here, one refresh, and the next item in the same run.
        pane.fileView.select(urls: [url("b1.txt")])
        let refreshes = pane.quickLookRefreshesForTesting
        let runs = runner.invocations
        let first = pane.previewPanel(nil, previewItemAt: 0)
        check("Quick Look is handed a placeholder for a file not yet extracted",
              pane.numberOfPreviewItems(in: nil) == 1 && first is ArchivePendingPreviewItem
              && first?.previewItemURL == nil && first?.previewItemTitle == "b1.txt")
        await expectEventually("the placeholder's bytes arrive and Quick Look is refreshed") {
            pane.quickLookRefreshesForTesting == refreshes + 1
        }
        await drainMainQueue()
        check("Quick Look then shows the file itself, refreshed once",
              text(pane.previewPanel(nil, previewItemAt: 0)?.previewItemURL) == "b1"
              && pane.quickLookRefreshesForTesting == refreshes + 1)
        check("the next item arrives in the same run when it is small enough",
              session.isPublished("Box/b2.txt") && runner.invocations == runs + 1,
              "runs=\(runner.invocations - runs)")
        pane.fileView.select(urls: [url("a1.txt")])
        _ = pane.previewPanel(nil, previewItemAt: 0)
        await expectEventually("Quick Look brings the item on show") { session.isPublished("Box/a1.txt") }
        check("a neighbour over the automatic limit is never asked for", !session.isPublished("Box/a2-big.bin"))

        // The preview column: preparing, then showing.
        pane.setViewMode(.columns)
        await waitUntil("preview: the column view lists") { pane.viewMode == .columns && !pane.model.items.isEmpty }
        let columns = pane.columnView
        columns.select(urls: [url("c1.txt")])
        if let node = pane.model.node(for: url("c1.txt")) { _ = columns.browser(columns.browser, previewViewControllerForLeafItem: node) }
        check("the preview column prepares a file not yet extracted", columns.previewStateForTesting == .preparing,
              "\(columns.previewStateForTesting)")
        await expectEventually("then shows it", detail: { "\(columns.previewStateForTesting)" }) {
            if case .showing(let shown) = columns.previewStateForTesting { return text(shown) == "c1" }
            return false
        }

        // A result that arrives after the selection has moved is dropped.
        let gate = WorkerGate()
        runner.beforeRunForTesting = { gate.arriveAndWait() }
        columns.select(urls: [url("c2.txt")])
        if let node = pane.model.node(for: url("c2.txt")) { _ = columns.browser(columns.browser, previewViewControllerForLeafItem: node) }
        await waitUntil("preview: the next file's extraction is held") { gate.arrived }
        columns.select(urls: [url("b1.txt")])
        if let node = pane.model.node(for: url("b1.txt")) { _ = columns.browser(columns.browser, previewViewControllerForLeafItem: node) }
        runner.beforeRunForTesting = nil
        gate.release()
        await drainMainQueue()
        try await Task.sleep(nanoseconds: 300_000_000)
        await drainMainQueue()
        var shownAfterMove: String?
        if case .showing(let shown) = columns.previewStateForTesting { shownAfterMove = text(shown) }
        check("a late result for a file no longer selected is dropped", shownAfterMove == "b1",
              "\(columns.previewStateForTesting)")

        // Too large to extract unasked; Show Preview asks.
        let runsBeforeLarge = runner.invocations
        columns.select(urls: [url("a2-big.bin")])
        if let node = pane.model.node(for: url("a2-big.bin")) { _ = columns.browser(columns.browser, previewViewControllerForLeafItem: node) }
        check("a member over the automatic limit is not extracted, and offers Show Preview",
              columns.previewStateForTesting == .tooLarge && columns.isPreviewShowAnywayVisibleForTesting
              && runner.invocations == runsBeforeLarge && !session.isPublished("Box/a2-big.bin"),
              "\(columns.previewStateForTesting) runs=\(runner.invocations - runsBeforeLarge)")
        columns.pressPreviewShowAnywayForTesting()
        await expectEventually("Show Preview extracts it and shows it", detail: { "\(columns.previewStateForTesting)" }) {
            if case .showing = columns.previewStateForTesting { return session.isPublished("Box/a2-big.bin") }
            return false
        }
        pane.setViewMode(.details)
        pane.navigate(to: root)
        await waitUntil("preview: leaving the archive") { pane.currentURL?.standardizedFileURL == root.standardizedFileURL }
    }

    /// Thumbnails for entries not yet extracted (D100): gathered per run-loop
    /// pass into one transient extraction, withdrawn by token, and never
    /// leaving the archive's bytes behind.
    @MainActor private static func thumbnailChecks(root: URL, window wc: MainWindowController,
                                                   openedArchives: inout [URL]) async throws {
        let workspace = ArchiveWorkspace.shared
        let runner = SystemArchiveToolRunner.shared
        let thumbnails = ThumbnailProvider.shared
        let previousLimit = ArchivePreviewLimit.automaticBytes
        ArchivePreviewLimit.automaticBytes = 1024
        defer { ArchivePreviewLimit.automaticBytes = previousLimit; runner.beforeRunForTesting = nil }
        var entries: [(name: String, contents: String)] = []
        for folder in ["I", "L", "C"] {
            for index in 0..<40 { entries.append(("\(folder)/\(folder.lowercased())\(String(format: "%02d", index)).txt", "\(folder) \(index)")) }
        }
        entries += [("P/p.txt", "shared"), ("G/g.txt", "gated"), ("B/big.txt", String(repeating: "b", count: 2048))]
        let archive = root.appendingPathComponent("Thumbs.zip")
        try SmokeFixtures.zip(entries).write(to: archive)
        openedArchives.append(archive)
        let pane = wc.browser
        pane.setViewMode(.details)
        pane.navigate(to: archive)
        await waitUntil("thumbnails: the archive opens") { pane.model.items.map(\.name).contains("P") }
        guard let session = workspace.session(for: archive) else { check("thumbnails: a session exists", false); return }
        let provider = ArchiveFileProvider(base: LocalFileProvider(), workspace: workspace)
        func items(_ folder: String) throws -> [FileItem] { try provider.listDirectory(archive.appendingPathComponent(folder)) }
        func transientLeft() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: session.storageURL.path)) ?? []).filter { $0.hasPrefix(".tursora-thumbs-") }
        }
        func settle() async {
            await drainMainQueue()
            await waitUntil("thumbnails: the queue settles") { ArchiveThumbnailQueue.shared.isIdleForTesting }
        }

        // Withdrawn in the pass they were asked in: never extracted.
        let cancelled = try items("C")
        let runsBeforeCancel = runner.invocations
        let tokens = cancelled.map { item -> ThumbnailToken in
            let token = ThumbnailToken()
            thumbnails.thumbnail(for: item, size: 64, scale: 2, token: token) { _ in }
            return token
        }
        tokens.forEach(thumbnails.cancel)
        await settle()
        try await Task.sleep(nanoseconds: 300_000_000)
        check("thumbnail requests withdrawn in the same pass are never extracted",
              tokens.count == 40 && runner.invocations == runsBeforeCancel && transientLeft().isEmpty,
              "runs=\(runner.invocations - runsBeforeCancel)")

        // Over the automatic limit: not asked for at all.
        let big = try items("B")[0]
        check("a member over the automatic limit gets no thumbnail request",
              !ThumbnailProvider.canPreview(big) && thumbnails.thumbnail(for: big, size: 64, scale: 2) { _ in } == nil)

        // Two panes on one key: withdrawing one still delivers to the other.
        let shared = try items("P")[0]
        let first = ThumbnailToken(), second = ThumbnailToken()
        var firstDelivered = false
        var secondImage: NSImage?
        thumbnails.thumbnail(for: shared, size: 64, scale: 2, token: first) { _ in firstDelivered = true }
        thumbnails.thumbnail(for: shared, size: 64, scale: 2, token: second) { secondImage = $0 }
        thumbnails.cancel(first)
        await expectEventually("withdrawing one of two requests for a thumbnail still delivers to the other") { secondImage != nil }
        check("and the withdrawn one hears nothing", !firstDelivered)

        // Withdrawn after its run started: made anyway, cached, not poisoned.
        let gated = try items("G")[0]
        let gate = WorkerGate()
        runner.beforeRunForTesting = { gate.arriveAndWait() }
        let early = ThumbnailToken()
        thumbnails.thumbnail(for: gated, size: 64, scale: 2, token: early) { _ in }
        await waitUntil("thumbnails: the gated run starts") { gate.arrived }
        thumbnails.cancel(early)
        runner.beforeRunForTesting = nil
        gate.release()
        await waitUntil("thumbnails: the gated thumbnail is made anyway") { thumbnails.isCachedForTesting(gated, size: 64, scale: 2) }
        check("a request withdrawn after its run started is made anyway, and asked again is there at once",
              thumbnails.thumbnail(for: gated, size: 64, scale: 2) { _ in } != nil
              && !thumbnails.isUnsupportedForTesting(gated, size: 64, scale: 2))

        // Through the real views: every visible cell in one run, and a reload
        // while that run is held keeps what it asked for. A large window, so
        // a page of cells is on screen, as in use.
        wc.window?.setContentSize(NSSize(width: 1500, height: 1000))
        for (mode, folder) in [(ViewMode.icons, "I"), (ViewMode.details, "L")] {
            // Archive pages open with the default view settings; set them
            // there from an ordinary folder.
            // The ordinary folder's own rows, not the previous archive
            // folder's still on screen: switching the view over those would
            // ask for their thumbnails too.
            pane.navigate(to: root)
            await waitUntil("thumbnails: back on an ordinary folder") {
                pane.model.url?.standardizedFileURL == root.standardizedFileURL
                    && pane.model.items.contains { $0.name == "Thumbs.zip" }
            }
            pane.setViewMode(mode)
            if mode == .details, let index = ZoomLevel.sizes(for: .details).firstIndex(of: 32) { pane.setZoomIndex(index) }
            pane.setShowsPreviews(true)
            pane.useCurrentViewAsDefault()
            await settle()
            let gate = WorkerGate()
            runner.beforeRunForTesting = { gate.arriveAndWait() }
            let runsBefore = runner.invocations
            let queueRunsBefore = ArchiveThumbnailQueue.shared.runsForTesting.count
            pane.navigate(to: archive.appendingPathComponent(folder))
            await waitUntil("thumbnails: \(mode.rawValue) lists its folder") { pane.model.items.count == 40 }
            check("thumbnails: the archive folder opens in the \(mode.rawValue) view with previews",
                  pane.viewMode == mode && pane.showsPreviews && ZoomLevel.sizes(for: mode)[pane.zoomIndex] >= ZoomLevel.previewThreshold,
                  "\(pane.viewMode) previews=\(pane.showsPreviews) zoom=\(pane.zoomIndex)")
            await waitUntil("thumbnails: \(mode.rawValue) asks for its visible cells") { gate.arrived }
            pane.fileView.reloadData()
            runner.beforeRunForTesting = nil
            gate.release()
            let scale = pane.view.window?.backingScaleFactor ?? 2
            let size = ZoomLevel.sizes(for: mode)[pane.zoomIndex]
            // Read afresh on each poll: straight after a reload the grid has
            // not laid its cells out yet.
            func visibleItems() -> [FileItem] {
                if mode == .icons {
                    return pane.iconGrid.collectionView.indexPathsForVisibleItems().compactMap {
                        pane.model.groups.indices.contains($0.section) && pane.model.groups[$0.section].nodes.indices.contains($0.item)
                            ? pane.model.groups[$0.section].nodes[$0.item].item : nil
                    }
                }
                let table = pane.fileList.tableView
                let rows = table.rows(in: table.visibleRect)
                return (rows.location..<(rows.location + rows.length)).compactMap { (table.item(atRow: $0) as? FileNode)?.item }
            }
            await expectEventually("\(mode.rawValue) at \(Int(size)) pt: every visible cell gets its thumbnail",
                                   detail: { "\(visibleItems().filter { thumbnails.isCachedForTesting($0, size: size, scale: scale) }.count) of \(visibleItems().count)" }) {
                let visible = visibleItems()
                return !visible.isEmpty && visible.allSatisfy { thumbnails.isCachedForTesting($0, size: size, scale: scale) }
            }
            let visible = visibleItems()
            check("\(mode.rawValue): \(visible.count) visible cells cost one run of the archive tool, a reload during it included",
                  runner.invocations == runsBefore + 1,
                  "runs=\(runner.invocations - runsBefore) " + describeRuns(since: queueRunsBefore))
        }
        await settle()
        check("thumbnails leave no transient directory and extract nothing for good",
              transientLeft().isEmpty && session.materializer.publishedPaths.isEmpty,
              "\(transientLeft()) \(session.materializer.publishedPaths.sorted().prefix(5))")
        pane.navigate(to: root)
        await waitUntil("thumbnails: leaving the archive") { pane.currentURL?.standardizedFileURL == root.standardizedFileURL }
        pane.setViewMode(.details)
        pane.setZoomIndex(ZoomLevel.defaultIndex(for: .details))
        pane.useCurrentViewAsDefault()
    }

    /// Dragging and sharing entries not yet extracted (D101): a file promise
    /// for other applications, the logical URL for Tursora's own panes.
    @MainActor private static func dragChecks(root: URL, window wc: MainWindowController,
                                              openedArchives: inout [URL]) async throws {
        let fm = FileManager.default
        let workspace = ArchiveWorkspace.shared
        let runner = SystemArchiveToolRunner.shared
        let entries: [(name: String, contents: String)] = [
            ("Box/f.txt", "file"), ("Box/Folder/sub/x.txt", "deep"), ("Box/App.app/Contents/Info.plist", "plist"),
            ("Box/App.app/Contents/MacOS/App", "code"), ("Box/pub.txt", "published"), ("Box/share.txt", "shared"),
        ]
        func read(_ url: URL, _ path: String = "") -> String? {
            try? String(contentsOf: path.isEmpty ? url : url.appendingPathComponent(path), encoding: .utf8)
        }
        let pane = wc.browser
        guard let other = wc.tabs.currentPage.inactive else { check("drag: a split pane is open", false); return }

        // The writer, through each view's own drag source.
        for mode in ViewMode.allCases {
            let archive = root.appendingPathComponent("Drag-\(mode.rawValue).zip")
            try SmokeFixtures.zip(entries).write(to: archive)
            openedArchives.append(archive)
            let folder = archive.appendingPathComponent("Box")
            pane.navigate(to: root)
            await waitUntil("drag: \(mode.rawValue) back on an ordinary folder") {
                pane.model.url?.standardizedFileURL == root.standardizedFileURL
                    && pane.model.items.contains { $0.name == archive.lastPathComponent }
            }
            pane.setViewMode(mode)
            pane.setShowsPreviews(false)
            pane.useCurrentViewAsDefault()
            pane.navigate(to: folder)
            // By URL: the previous archive's folder has the same names.
            await waitUntil("drag: \(mode.rawValue) lists the archive") {
                pane.model.items.contains { $0.url.standardizedFileURL == folder.appendingPathComponent("pub.txt").standardizedFileURL }
            }
            guard let session = workspace.session(for: archive) else { check("drag: a session exists", false); return }
            try await SmokeFixtures.materialize(session, ["Box/pub.txt"])
            func node(_ name: String) -> FileNode? { pane.model.node(for: folder.appendingPathComponent(name)) }
            var writers: [NSPasteboardWriting?] = []
            switch mode {
            case .details:
                writers = ["f.txt", "pub.txt"].map { name in node(name).flatMap { pane.fileList.outlineView(pane.fileList.tableView, pasteboardWriterForItem: $0) } }
            case .icons:
                let items = pane.model.groups.first?.nodes ?? []
                writers = ["f.txt", "pub.txt"].map { name in
                    items.firstIndex { $0.item.name == name }.flatMap {
                        pane.iconGrid.collectionView(pane.iconGrid.collectionView, pasteboardWriterForItemAt: IndexPath(item: $0, section: 0))
                    }
                }
            case .columns:
                let columns = pane.columnView
                let drag = NSPasteboard(name: NSPasteboard.Name("tursora-drag-\(UUID().uuidString)"))
                defer { drag.releaseGlobally() }
                var indexes = IndexSet()
                for row in 0..<pane.model.items.count {
                    if let item = (columns.browser.item(atRow: row, inColumn: 0) as? FileNode)?.item, ["f.txt", "pub.txt"].contains(item.name) {
                        indexes.insert(row)
                    }
                }
                let wrote = columns.browser(columns.browser, writeRowsWith: indexes, inColumn: 0, to: drag)
                check("drag: the column view writes both rows", wrote && drag.pasteboardItems?.count == 2,
                      "\(String(describing: drag.pasteboardItems?.count))")
                check("drag: columns: a file not yet extracted is promised with the private type, an extracted one is its file",
                      drag.fileURLs.map(\.lastPathComponent).sorted() == ["f.txt", "pub.txt"]
                      && drag.types?.contains(ArchiveEntryPromiseProvider.internalType) == true,
                      "\(drag.fileURLs)")
                continue
            }
            check("drag: \(mode.rawValue): a file not yet extracted is promised with the private type, an extracted one is its file",
                  writers.count == 2 && (writers[0] as? ArchiveEntryPromiseProvider)?.logicalURL == folder.appendingPathComponent("f.txt")
                  && (writers[1] as? NSURL).flatMap { read($0 as URL) } == "published",
                  "\(writers.map { String(describing: type(of: $0)) })")
        }

        // Promises kept: a file, a folder with its whole subtree, a package.
        let promised = root.appendingPathComponent("Promise.zip")
        try SmokeFixtures.zip(entries).write(to: promised)
        openedArchives.append(promised)
        pane.navigate(to: promised.appendingPathComponent("Box"))
        await waitUntil("drag: the promise archive lists") {
            pane.model.items.contains { $0.url.standardizedFileURL == promised.appendingPathComponent("Box/Folder").standardizedFileURL }
        }
        let target = root.appendingPathComponent("promised-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        for name in ["f.txt", "Folder", "App.app"] {
            guard let item = pane.model.items.first(where: { $0.name == name }),
                  let provider = ArchiveDragExport.writer(for: item) as? ArchiveEntryPromiseProvider else {
                check("drag: \(name) is promised", false); return
            }
            let error: Error? = await withCheckedContinuation { continuation in
                provider.operationQueue(for: provider).addOperation {
                    provider.filePromiseProvider(provider, writePromiseTo: target.appendingPathComponent(name)) {
                        continuation.resume(returning: $0)
                    }
                }
            }
            check("drag: keeping the promise for \(name) writes it", error == nil, "\(String(describing: error))")
        }
        check("drag: the promised file, folder and package arrive whole",
              read(target, "f.txt") == "file" && read(target, "Folder/sub/x.txt") == "deep"
              && read(target, "App.app/Contents/MacOS/App") == "code" && read(target, "App.app/Contents/Info.plist") == "plist")

        // Tursora's own panes: the logical URL, copied like Copy to Other Pane.
        let drop = root.appendingPathComponent("Drop.zip")
        try SmokeFixtures.zip(entries).write(to: drop)
        openedArchives.append(drop)
        let dropFolder = drop.appendingPathComponent("Box")
        pane.navigate(to: dropFolder)
        await waitUntil("drag: the drop archive lists") {
            pane.model.items.contains { $0.url.standardizedFileURL == dropFolder.appendingPathComponent("Folder").standardizedFileURL }
        }
        let destination = root.appendingPathComponent("dropped-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        other.navigate(to: destination)
        await waitUntil("drag: the other pane shows the destination") {
            other.model.url?.standardizedFileURL == destination.standardizedFileURL
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tursora-drop-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects(["f.txt", "Folder"].compactMap { name in
            pane.model.items.first { $0.name == name }.flatMap(ArchiveDragExport.writer(for:))
        })
        let dropped = pasteboard.fileURLs
        check("drag: a drop in Tursora reads the entries' logical URLs",
              Set(dropped.map(\.standardizedFileURL)) == Set(["f.txt", "Folder"].map { dropFolder.appendingPathComponent($0).standardizedFileURL }),
              "\(dropped)")
        other.setViewMode(.columns)
        await waitUntil("drag: the other pane shows columns") { other.viewMode == .columns }
        var row = -1, column = 0
        var operation = NSBrowser.DropOperation.on
        let validated = other.columnView.browser(other.columnView.browser, validateDrop: FakeDraggingInfo(pasteboard: pasteboard),
                                                 proposedRow: &row, column: &column, dropOperation: &operation)
        check("drag: the column view accepts a promised entry through the shared reader", validated == .copy, "\(validated)")
        other.setViewMode(.details)
        let previous = other.lastTransferTask
        other.dropFiles(dropped, to: destination, op: .copy)
        let task = other.lastTransferTask
        await waitUntil("drag: the dropped entries are copied") { task !== previous && task?.snapshot.isTerminal == true }
        check("drag: dropping them into the other pane copies their bytes, the folder whole",
              read(destination, "f.txt") == "file" && read(destination, "Folder/sub/x.txt") == "deep",
              "\((try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])")

        // Share: a provider for an entry not yet extracted, a URL for one that is.
        pane.fileView.select(urls: ["share.txt", "pub.txt"].map { dropFolder.appendingPathComponent($0) })
        guard let dropSession = workspace.session(for: drop) else { check("drag: a session exists", false); return }
        try await SmokeFixtures.materialize(dropSession, ["Box/pub.txt"])
        let runsBefore = runner.invocations
        let shareable = wc.canShareSelection
        check("drag: enabling Share never runs the archive tool", shareable && runner.invocations == runsBefore)
        let items = wc.sharingItems
        let provider = items.compactMap { $0 as? NSItemProvider }.first
        check("drag: Share is handed an item provider for an entry not yet extracted and a URL for one that is",
              items.count == 2 && provider != nil && items.compactMap { $0 as? URL }.map(\.lastPathComponent) == ["pub.txt"],
              "\(items.map { String(describing: type(of: $0)) })")
        var shared: String?
        var loaded = false
        _ = provider?.loadFileRepresentation(forTypeIdentifier: UTType.plainText.identifier) { url, _ in
            shared = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            loaded = true
        }
        await waitUntil("drag: the shared item loads") { loaded }
        check("drag: loading the provider yields the entry's bytes", shared == "shared", "\(String(describing: shared))")
        pane.navigate(to: root)
        await waitUntil("drag: leaving the archive") { pane.currentURL?.standardizedFileURL == root.standardizedFileURL }
    }

    /// Listing never extracts; the folder on screen is prefetched within the
    /// limits, and navigating away stops it (D102).
    @MainActor private static func prefetchChecks(root: URL, window wc: MainWindowController,
                                                  openedArchives: inout [URL]) async throws {
        let workspace = ArchiveWorkspace.shared
        let runner = SystemArchiveToolRunner.shared
        let mib: Int64 = 1 << 20, gib: Int64 = 1 << 30
        check("prefetch: a folder of up to 1,000 files and 64 MiB on this Mac is fetched ahead",
              ArchivePrefetch.allows(fileCount: 1_000, bytes: 64 * mib, alreadyPrefetched: 0, freeSpace: 100 * gib, sourceIsLocal: true))
        check("prefetch: not 1,001 files, not a byte over 64 MiB, not over the network, not an empty folder",
              !ArchivePrefetch.allows(fileCount: 1_001, bytes: mib, alreadyPrefetched: 0, freeSpace: 100 * gib, sourceIsLocal: true)
              && !ArchivePrefetch.allows(fileCount: 10, bytes: 64 * mib + 1, alreadyPrefetched: 0, freeSpace: 100 * gib, sourceIsLocal: true)
              && !ArchivePrefetch.allows(fileCount: 10, bytes: mib, alreadyPrefetched: 0, freeSpace: 100 * gib, sourceIsLocal: false)
              && !ArchivePrefetch.allows(fileCount: 0, bytes: 0, alreadyPrefetched: 0, freeSpace: 100 * gib, sourceIsLocal: true))
        check("prefetch: an archive's budget is the smaller of 1 GiB and a tenth of free space",
              ArchivePrefetch.sessionBudget(freeSpace: 100 * gib) == gib && ArchivePrefetch.sessionBudget(freeSpace: 5 * gib) == 512 * mib
              && !ArchivePrefetch.allows(fileCount: 10, bytes: 2 * mib, alreadyPrefetched: gib - mib, freeSpace: 100 * gib, sourceIsLocal: true))

        let previousPolicy = workspace.materializationPolicy
        workspace.materializationPolicy = .prefetch
        defer { workspace.materializationPolicy = previousPolicy; runner.beforeRunForTesting = nil }
        var entries: [(name: String, contents: String)] = (0...1_000).map { ("Big/f\(String(format: "%04d", $0)).txt", "\($0)") }
        entries += [("Small/a.txt", "a"), ("Small/b.txt", "b"), ("Held/h.txt", "held")]
        let archive = root.appendingPathComponent("Many.zip")
        try SmokeFixtures.zip(entries).write(to: archive)
        openedArchives.append(archive)
        let pane = wc.browser
        pane.setViewMode(.details)
        pane.navigate(to: archive)
        await waitUntil("prefetch: the archive opens") {
            pane.model.items.contains { $0.url.standardizedFileURL == archive.appendingPathComponent("Big").standardizedFileURL }
        }
        guard let session = workspace.session(for: archive) else { check("prefetch: a session exists", false); return }
        let bigItem = pane.model.items.first { $0.name == "Big" }
        await expectEventually("prefetch: a folder of 1,001 files counts its items from the tree",
                               detail: { bigItem.map { pane.model.folderSizes.displaySize(for: $0) } ?? "nil" }) {
            bigItem.map { pane.model.folderSizes.displaySize(for: $0) } == "1001 items"
        }
        pane.navigate(to: archive.appendingPathComponent("Big"))
        await waitUntil("prefetch: the large folder lists") { pane.model.items.count == 1_001 }
        try await Task.sleep(nanoseconds: 300_000_000)
        check("prefetch: a folder of 1,001 files is not fetched ahead, and shows the rows it counted",
              pane.prefetchRequest == nil && session.materializer.publishedPaths.isEmpty && pane.model.items.count == 1_001)

        // A small folder: fetched while it is on screen.
        pane.navigate(to: archive.appendingPathComponent("Small"))
        await expectEventually("prefetch: a small folder on screen is fetched in the background") {
            session.isPublished("Small/a.txt") && session.isPublished("Small/b.txt")
        }

        // Navigating away stops a fetch still at the tool.
        let gate = WorkerGate()
        runner.beforeRunForTesting = { gate.arriveAndWait() }
        pane.navigate(to: archive.appendingPathComponent("Held"))
        await waitUntil("prefetch: the held folder's fetch reaches the tool") { gate.arrived }
        pane.navigate(to: root)
        await waitUntil("prefetch: back on an ordinary folder") { pane.currentURL?.standardizedFileURL == root.standardizedFileURL }
        runner.beforeRunForTesting = nil
        gate.release()
        try await Task.sleep(nanoseconds: 300_000_000)
        check("prefetch: navigating away cancels a fetch still at the tool", !session.isPublished("Held/h.txt"))

        // No path that shows or completes a folder runs the tool on the main
        // thread: expanding in the list, selecting in the columns, address
        // completion and the breadcrumb submenu.
        let mainBefore = runner.mainThreadInvocations
        pane.navigate(to: archive)
        await waitUntil("prefetch: back at the archive root") {
            pane.model.items.contains { $0.url.standardizedFileURL == archive.appendingPathComponent("Held").standardizedFileURL }
                && pane.currentURL?.standardizedFileURL == archive.standardizedFileURL
        }
        if let held = pane.model.node(for: archive.appendingPathComponent("Held")) { pane.fileList.expand(held) }
        let completions = PathCompleter.completions(for: "Sm", cwd: archive, home: root)
        let submenu = wc.tabs.addressBar.subfolderMenu(of: archive, current: nil)
        pane.setViewMode(.columns)
        pane.columnView.select(urls: [archive.appendingPathComponent("Held")])
        await drainMainQueue()
        check("prefetch: expanding, column selection, completion and the breadcrumb menu never run the tool on the main thread",
              runner.mainThreadInvocations == mainBefore && completions == ["Small/"] && submenu.items.count >= 3,
              "main runs \(runner.mainThreadInvocations - mainBefore), completions \(completions), menu \(submenu.items.count)")
        pane.setViewMode(.details)
        pane.navigate(to: root)
        await waitUntil("prefetch: leaving the archive") { pane.currentURL?.standardizedFileURL == root.standardizedFileURL }
    }

    /// Each thumbnail run since a point, as its members' names and the size
    /// they were asked at, for a failure's detail.
    private static func describeRuns(since start: Int) -> String {
        let runs = Array(ArchiveThumbnailQueue.shared.runsForTesting.dropFirst(start))
        return runs.map { (run: [String]) -> String in
            let names: [String] = run.map { key in
                let path = key.split(separator: "|").first.map(String.init) ?? key
                return (path as NSString).lastPathComponent
            }
            let size: String = run.first.map { key in key.split(separator: "|").dropFirst().first.map(String.init) ?? "" } ?? ""
            return names.joined(separator: ",") + " @" + size
        }.joined(separator: " ; ")
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

import AppKit

enum WorkspaceContinuitySmokeTests: SmokeSuite {
    static var checkPrefix: String { "workspace continuity: " }

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            do {
                try modelRules()
                try await viewRestoration()
                try await listHorizontalRestoration()
                try await columnHorizontalRestoration()
                try await externalPreviewRefresh()
            } catch { fail("fixture", String(describing: error)) }
            completion()
        }
    }

    private static func modelRules() throws {
        let a = URL(fileURLWithPath: "/tmp/a.txt")
        let state = WorkspacePaneViewState(mode: .columns,
            selectedURLs: [a, a, URL(string: "https://example.com/a")!],
            scrollOffset: .infinity, columnScrollOffsets: ["/tmp": -30, "relative": 4, "/bad": .nan],
            listHorizontalScrollOffset: .infinity).sanitized()
        check("view state removes invalid URLs, duplicates and unsafe offsets",
              state.selectedURLs == [a] && state.scrollOffset == 0 && state.columnScrollOffsets == ["/tmp": 0]
                && state.listHorizontalScrollOffset == 0)
        let pane = WorkspacePaneState(url: a.deletingLastPathComponent(), viewState: state)
        let roundTrip = try JSONDecoder().decode(WorkspacePaneState.self, from: JSONEncoder().encode(pane))
        check("selection and all scroll representations round-trip", roundTrip == pane)
        let legacy = try JSONDecoder().decode(WorkspacePaneState.self, from: Data("{\"url\":\"file:///tmp/\"}".utf8))
        check("older panes still decode without a view snapshot", legacy.viewState == nil)
        let legacyView = WorkspacePaneViewState(mode: .details)
        let legacyData = try JSONEncoder().encode(legacyView)
        let legacyObject = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        let decodedLegacyView = try JSONDecoder().decode(WorkspacePaneViewState.self, from: legacyData)
        check("older view snapshots decode without a list horizontal field",
              legacyObject["listHorizontalScrollOffset"] == nil && decodedLegacyView.listHorizontalScrollOffset == nil)
        let boundedX = [-30.0, 10_000_001, Double.nan].map {
            WorkspacePaneViewState(mode: .details, listHorizontalScrollOffset: $0).sanitized().listHorizontalScrollOffset
        }
        check("list horizontal offsets clamp negative, excessive and nonfinite values", boundedX == [0, 10_000_000, 0])
    }

    @MainActor private static func viewRestoration() async throws {
        let root = try SmokeFixtures.temporaryDirectory("continuity")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (0..<140).map { folder.appendingPathComponent(String(format: "item-%03d.txt", $0)) }
        for file in files { try Data("file".utf8).write(to: file) }
        let provider = LocalFileProvider()
        for mode in ViewMode.allCases {
            let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("\(mode)-views.json"))
            let original = MainWindowController(provider: provider, places: PlacesModel(), initialURL: folder, viewPropertiesStore: store)
            original.window?.setContentSize(NSSize(width: 1100, height: 700))
            original.window?.makeKeyAndOrderFront(nil)
            let pane = original.browser
            await waitUntil("\(mode) initial rows") { pane.model.items.count == files.count }
            pane.setViewMode(mode)
            pane.setGroupKey(.kind)
            pane.fileView.select(urls: [files[90], files[91]])
            original.window?.contentView?.layoutSubtreeIfNeeded()
            if mode == .columns { pane.columnView.browser.scrollRowToVisible(100, inColumn: 0) }
            else { pane.fileView.scrollOffset = 480 }
            let captured = original.workspaceSessionState
            let saved = captured.tabs[0].panes[0].viewState!
            let expectedPaths = Set([files[90], files[91]].map { $0.standardizedFileURL.path })
            let savedPaths = Set(saved.selectedURLs.map { $0.standardizedFileURL.path })
            check("\(mode) captures the full selection", savedPaths == expectedPaths,
                  "actual \(savedPaths.sorted()); expected \(expectedPaths.sorted())")
            if mode == .columns {
                check("column scroll is captured from its real native scroll view",
                      (saved.columnScrollOffsets[folder.path] ?? 0) > 0, "\(saved.columnScrollOffsets)")
            } else { check("\(mode) fixture actually scrolled", saved.scrollOffset > 0) }
            try store.flush()
            let restoredStore = DirectoryViewPropertiesStore(fileURL: store.fileURL)
            let restored = MainWindowController(provider: provider, places: PlacesModel(), initialURL: root, viewPropertiesStore: restoredStore)
            restored.window?.setContentSize(NSSize(width: 1100, height: 700))
            restored.window?.makeKeyAndOrderFront(nil)
            let persisted = try JSONDecoder().decode(WorkspaceWindowState.self, from: JSONEncoder().encode(captured))
            restored.restoreWorkspaceSession(persisted)
            await waitUntil("\(mode) restored rows and position") {
                restored.browser.model.items.count == files.count && restored.browser.pendingWorkspaceView == nil
            }
            let restoredPaths = Set(restored.browser.fileView.selectedItems.map { $0.url.standardizedFileURL.path })
            check("\(mode) restores selection into fresh native views", restoredPaths == savedPaths,
                  "actual \(restoredPaths.sorted()); expected \(savedPaths.sorted())")
            check("\(mode) restores its saved scroll offset",
                  abs(Double(restored.browser.fileView.scrollOffset) - saved.scrollOffset) < 2)
            if mode == .columns {
                let offset = restored.browser.columnView.workspaceColumnOffsets[folder.path] ?? -1
                check("column vertical scroll survives restart", abs(offset - (saved.columnScrollOffsets[folder.path] ?? 0)) < 2)
                let columns = restored.browser.columnView
                let prior = columns.scrollOffset
                columns.scrollOffset = .greatestFiniteMagnitude
                let maximum = max(0, (columns.horizontalScrollView?.documentView?.frame.width ?? 0)
                                  - (columns.horizontalScrollView?.contentView.bounds.width ?? 0))
                check("an oversized column offset remains within native loaded columns",
                      columns.scrollOffset >= 0 && columns.scrollOffset <= maximum
                        && Set(columns.selectedItems.map { $0.url.standardizedFileURL.path }) == savedPaths,
                      "offset \(columns.scrollOffset); maximum \(maximum); selection \(columns.selectedItems.map { $0.url.path }); expected \(savedPaths.sorted())")
                columns.scrollOffset = prior
                let missing = folder.appendingPathComponent("Removed folder/selected.txt")
                WorkspacePaneState(url: folder,
                    viewState: WorkspacePaneViewState(mode: .columns, selectedURLs: [missing], scrollOffset: 10_000_000))
                    .restoreWorkspacePane(in: restored.browser)
                await waitUntil("a missing saved descendant settles without invalid columns") {
                    restored.browser.pendingWorkspaceView == nil
                }
                check("missing descendants clear selection without changing the restored location",
                      restored.browser.currentURL?.standardizedFileURL.path == folder.standardizedFileURL.path && columns.selectedItems.isEmpty
                        && columns.scrollOffset == 0)
            }
            recentTabs(in: restored, folder: folder)
            for controller in [original, restored] {
                for browser in controller.tabs.pages.flatMap(\.panes) {
                    browser.model.folderSizes.cancel()
                    browser.model.onChange = nil
                }
                controller.close()
            }
            try store.flush(); try restoredStore.flush()
        }
    }

    @MainActor private static func listHorizontalRestoration() async throws {
        let root = try SmokeFixtures.temporaryDirectory("list-continuity")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Files", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        for directory in [folder, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let files = (0..<110).map { folder.appendingPathComponent(String(format: "item-%03d.txt", $0)) }
        for file in files { try Data("file".utf8).write(to: file) }
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let original = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: folder, viewPropertiesStore: store)
        var controllers = [original]
        var stores = [store]
        defer {
            for controller in controllers {
                for pane in controller.tabs.pages.flatMap(\.panes) {
                    pane.model.folderSizes.cancel()
                    pane.model.folderSizes.onUpdate = nil
                    pane.model.onChange = nil
                    pane.model.onLoadSuccess = nil
                    pane.onWorkspaceSessionChanged = nil
                }
                controller.close()
            }
            for savedStore in stores { try? savedStore.flush() }
        }
        original.window?.setContentSize(NSSize(width: 1100, height: 700))
        original.window?.makeKeyAndOrderFront(nil)
        let pane = original.browser
        await waitUntil("list horizontal fixture rows") { pane.model.items.count == files.count }
        pane.setViewMode(.details)
        pane.setGroupKey(.kind)
        let right = original.tabs.currentPage.split(with: other)
        await waitUntil("list horizontal fixture split") { right.model.generation > 0 }
        original.tabs.currentPage.activate(pane)
        pane.fileList.userResizedColumns(["name": 465])
        original.window?.contentView?.layoutSubtreeIfNeeded()
        try require("list restart fixture has narrow overflowing columns",
                    pane.view.bounds.width < 600
                      && pane.fileList.tableView.bounds.width > pane.fileList.scrollView.contentView.bounds.width + 100)
        let selection = [files[90], files[91]]
        let expectedPaths = Set(selection.map { $0.standardizedFileURL.path })
        for (requestedX, omitField) in [(70.0, false), (0.0, false), (0.0, true)] {
            pane.fileView.select(urls: selection)
            pane.fileView.scrollOffset = 480
            pane.fileList.horizontalScrollOffset = CGFloat(requestedX)
            var captured = original.workspaceSessionState
            let saved = captured.tabs[0].panes[0].viewState!
            try require("list restart captures exact selection and both native axes at x=\(requestedX)",
                        Set(saved.selectedURLs.map { $0.standardizedFileURL.path }) == expectedPaths
                          && saved.scrollOffset > 0
                          && abs((saved.listHorizontalScrollOffset ?? -1) - requestedX) < 0.5)
            if omitField { captured.tabs[0].panes[0].viewState?.listHorizontalScrollOffset = nil }
            try store.flush()
            let freshStore = DirectoryViewPropertiesStore(fileURL: store.fileURL)
            stores.append(freshStore)
            let restored = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root, viewPropertiesStore: freshStore)
            controllers.append(restored)
            restored.window?.setContentSize(NSSize(width: 1100, height: 700))
            restored.window?.makeKeyAndOrderFront(nil)
            restored.restoreWorkspaceSession(try JSONDecoder().decode(WorkspaceWindowState.self, from: JSONEncoder().encode(captured)))
            let fresh = restored.tabs.currentPage.panes[0]
            await waitUntil("list restart settles at x=\(requestedX), legacy=\(omitField)") {
                fresh.model.items.count == files.count && fresh.pendingWorkspaceView == nil
            }
            restored.window?.contentView?.layoutSubtreeIfNeeded()
            check("list restart restores selection and both axes at x=\(requestedX), legacy=\(omitField)",
                  Set(fresh.fileView.selectedItems.map { $0.url.standardizedFileURL.path }) == expectedPaths
                    && abs(Double(fresh.fileView.scrollOffset) - saved.scrollOffset) < 2
                    && abs(Double(fresh.fileList.horizontalScrollOffset) - requestedX) < 0.5,
                  "selection \(fresh.fileView.selectedItems.map { $0.url.path }); x=\(fresh.fileList.horizontalScrollOffset); y=\(fresh.fileView.scrollOffset)")
            if requestedX == 0 {
                let nameRect = fresh.fileList.tableView.rect(ofColumn: fresh.fileList.tableView.column(withIdentifier: FileListViewController.Column.name.id))
                check("list restart keeps Name visible at zero, legacy=\(omitField)",
                      nameRect.intersection(fresh.fileList.scrollView.documentVisibleRect).width >= 160)
            }
        }
    }

    @MainActor private static func columnHorizontalRestoration() async throws {
        let root = try SmokeFixtures.temporaryDirectory("column-continuity")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Files", isDirectory: true)
        var leaf = folder
        for depth in 0..<8 { leaf.appendPathComponent("Level-\(depth)", isDirectory: true) }
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        let files = ["a.txt", "b.txt"].map { leaf.appendingPathComponent($0) }
        for file in files { try Data("file".utf8).write(to: file) }
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let original = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: folder, viewPropertiesStore: store)
        let restored = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: folder, viewPropertiesStore: store)
        defer {
            for controller in [original, restored] {
                controller.browser.model.folderSizes.cancel()
                controller.browser.model.folderSizes.onUpdate = nil
                controller.browser.model.onChange = nil
                controller.browser.model.onLoadSuccess = nil
                controller.browser.onWorkspaceSessionChanged = nil
                controller.close()
            }
            try? store.flush()
        }
        for controller in [original, restored] {
            controller.window?.setContentSize(NSSize(width: 1100, height: 700))
            controller.window?.makeKeyAndOrderFront(nil)
            await waitUntil("long column fixture listing") { controller.browser.model.generation > 0 }
            controller.browser.setViewMode(.columns)
        }
        let columns = original.browser.columnView
        columns.select(urls: files)
        original.window?.contentView?.layoutSubtreeIfNeeded()
        try require("long column fixture opens the complete native chain", columns.browser.lastColumn >= 8)
        guard let scroll = columns.horizontalScrollView else { throw SmokeFailure("native horizontal scroll view missing") }
        var bounds = scroll.contentView.bounds
        bounds.origin.x = 333
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        let nativeOffset = scroll.contentView.bounds.minX
        let captured = original.workspaceSessionState
        let saved = captured.tabs[0].panes[0].viewState!
        try require("column snapshot captures real partial-column horizontal pixels",
                    nativeOffset > 300 && abs(saved.scrollOffset - Double(nativeOffset)) < 1,
                    "native \(nativeOffset); saved \(saved.scrollOffset)")
        columns.scrollOffset = nativeOffset + 37
        try require("column offset moves even when its target column was already visible",
                    abs(scroll.contentView.bounds.minX - (nativeOffset + 37)) < 1)
        columns.scrollOffset = nativeOffset
        try require("column offset restores in the opposite direction", abs(scroll.contentView.bounds.minX - nativeOffset) < 1)
        restored.restoreWorkspaceSession(try JSONDecoder().decode(WorkspaceWindowState.self, from: JSONEncoder().encode(captured)))
        await waitUntil("long column restart restores its native viewport") { restored.browser.pendingWorkspaceView == nil }
        let actual = restored.browser.columnView
        check("long column restart restores both selected leaves and partial-column scrolling",
              Set(actual.selectedItems.map { $0.url.standardizedFileURL.path }) == Set(files.map { $0.standardizedFileURL.path })
                && abs((actual.horizontalScrollView?.contentView.bounds.minX ?? -1) - nativeOffset) < 1,
              "selected \(actual.selectedItems.map { $0.url.path }); horizontal \(actual.horizontalScrollView?.contentView.bounds.minX ?? -1); expected \(nativeOffset)")
    }

    @MainActor private static func recentTabs(in controller: MainWindowController, folder: URL) {
        let tabs = controller.tabs
        _ = tabs.newTab(at: folder)
        let first = tabs.currentPage
        first.customTitle = "First closed"
        _ = tabs.newTab(at: folder)
        let second = tabs.currentPage
        second.customTitle = "Second closed"
        _ = tabs.closeTab(at: 1)
        _ = tabs.closeTab(at: 1)
        let menu = RecentlyClosedTabsMenu()
        menu.refresh(for: tabs)
        check("recent tabs lists newest first", menu.items.map(\.title) == ["Second closed", "First closed"])
        let older = menu.items[1]
        check("recent tab menu dispatches through its owning window", NSApp.sendAction(older.action!, to: older.target, from: older))
        check("selecting an older closed tab preserves the newer recovery entry",
              tabs.currentPage === first && tabs.recentlyClosedPages.first === second)
        let count = tabs.count
        _ = NSApp.sendAction(older.action!, to: older.target, from: older)
        check("a stale recovery row cannot reopen a different tab", tabs.count == count)
        check("the existing shortcut still reopens the newest remaining tab", tabs.reopenClosedTab() && tabs.currentPage === second)
    }

    @MainActor private static func externalPreviewRefresh() async throws {
        let root = try SmokeFixtures.temporaryDirectory("preview-refresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = folder.appendingPathComponent("note.md")
        try Data("# Original".utf8).write(to: note)
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let controller = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: folder, viewPropertiesStore: store)
        defer {
            controller.browser.model.folderSizes.cancel()
            controller.browser.model.onChange = nil
            controller.close()
            try? store.flush()
        }
        controller.window?.setContentSize(NSSize(width: 1100, height: 700))
        controller.window?.makeKeyAndOrderFront(nil)
        await waitUntil("preview listing") { controller.browser.model.items.count == 1 }
        controller.togglePreviewPane(nil)
        for mode in ViewMode.allCases {
            controller.browser.setViewMode(mode)
            controller.browser.fileView.select(urls: [note])
            let text = "Edited outside Tursora in \(mode.rawValue)"
            try Data("# \(text)".utf8).write(to: note, options: .atomic)
            await expectEventually("\(mode) external FSEvents refreshes unchanged Markdown URL", timeout: 8) {
                controller.previewPanel?.renderedTextForTesting.contains(text) == true
            }
        }
    }
}

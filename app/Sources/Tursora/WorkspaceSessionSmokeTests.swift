import AppKit

/// Exercises saved workspaces through real windows and fresh controller trees.
/// Every fixture owns its directory-view store; no user's session file is opened.
enum WorkspaceSessionSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("tursora-workspace-ui-" + UUID().uuidString).resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: fixture) }
            do {
                print("== workspace session windows ==")
                let folders = ["Left", "Right", "Other", "Nested", "Extra"].map {
                    fixture.appendingPathComponent($0, isDirectory: true)
                }
                for folder in folders {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data("workspace fixture".utf8).write(to: folder.appendingPathComponent("needle.txt"))
                }
                geometryChecks()
                for mode: ViewMode in [.details, .icons] {
                    try await roundTrip(mode: mode, folders: folders, fixture: fixture)
                }
                try await searchRestoration(folders: folders, fixture: fixture)
                try await archiveRestoration(folders: folders, fixture: fixture)
                try await unavailableLocations(folders: folders, fixture: fixture)
                await backgroundChanges(folders: folders, fixture: fixture)
                try await applicationLifecycle(folders: folders, fixture: fixture)
                completion()
            } catch { check("fixtures complete", false, error.localizedDescription) }
        }
    }

    @MainActor private static func roundTrip(mode: ViewMode, folders: [URL], fixture: URL) async throws {
        let storeFile = fixture.appendingPathComponent("\(mode)-views.json")
        let store = DirectoryViewPropertiesStore(fileURL: storeFile)
        let original = makeWindow(at: folders[0], store: store)
        defer { original.close() }
        let tabs = original.tabs
        let comparison = tabs.currentPage
        let left = comparison.active
        await listed(left, at: folders[0])
        left.navigate(to: folders[3]); await listed(left, at: folders[3])
        left.navigate(to: folders[0]); await listed(left, at: folders[0])
        let right = comparison.split(with: folders[1])
        await listed(right, at: folders[1])
        left.setViewMode(mode); right.setViewMode(mode)
        left.setGroupKey(.kind)
        right.setGroupKey(.dateModified)
        left.nameFilter = "needle"
        left.fileView.select(urls: [folders[0].appendingPathComponent("needle.txt")])
        let expectedActive = mode == .details ? 0 : 1
        comparison.activate(comparison.panes[expectedActive])
        original.window?.makeFirstResponder(comparison.active.focusView)
        tabs.setTitle("  Daily comparison  ", for: comparison)
        check("\(mode): configured split keeps the chosen physical side", comparison.activeIndex == expectedActive)

        let other = tabs.newTab(at: folders[2]); await listed(other, at: folders[2])
        let nested = tabs.newTab(at: folders[3]); await listed(nested, at: folders[3])
        tabs.moveTab(from: 2, to: 0)
        check("\(mode): reordering keeps the selected page by identity", tabs.current === nested && tabs.currentIndex == 0)
        tabs.selectTab(at: 1)
        check("\(mode): reselecting comparison focuses its saved side", tabs.currentPage === comparison && original.window?.firstResponder === comparison.active.focusView)
        check("\(mode): closing a background tab retains selected comparison", tabs.closeTab(at: 2) && tabs.currentPage === comparison)
        let extra = tabs.newTab(at: folders[4], activate: false)
        await listed(extra, at: folders[4])
        check("\(mode): background tab creation retains selected comparison", tabs.count == 3 && tabs.currentPage === comparison)
        comparison.setWorkspaceSplitFraction(mode == .details ? 0.37 : 0.63)
        original.window?.contentView?.layoutSubtreeIfNeeded()
        var sidebarAncestor = original.sidebar.view.superview
        while let view = sidebarAncestor, !(view is NSSplitView) { sidebarAncestor = view.superview }
        if let sidebarSplit = sidebarAncestor as? NSSplitView {
            sidebarSplit.setPosition(245, ofDividerAt: 0)
            original.window?.contentView?.layoutSubtreeIfNeeded()
        } else { check("\(mode): sidebar is installed in its native split view", false) }
        if mode == .icons { original.toggleSidebar(nil) }
        let undo = original.window!.undoManager!
        undo.registerUndo(withTarget: left) { _ in }
        let captured = original.workspaceSessionState
        check("\(mode): capture preserves tab order after reorder and close", captured.tabs.map { $0.panes[0].url } == [folders[3], folders[0], folders[4]])
        check("\(mode): capture saves selected tab and split sides", captured.selectedTabIndex == 1 && captured.tabs[1].panes.map(\.url) == [folders[0], folders[1]] && captured.tabs[1].activePaneIndex == expectedActive)
        check("\(mode): capture saves normalized custom title", captured.tabs[1].customTitle == "Daily comparison" && captured.tabs[0].customTitle == nil)
        check("\(mode): capture saves non-equal divider position", abs(captured.tabs[1].splitFraction - (mode == .details ? 0.37 : 0.63)) < 0.015)
        let sidebarSplit = sidebarAncestor as? NSSplitView
        let sidebarDetail = "saved=\(captured.sidebarWidth), collapsed=\(captured.sidebarCollapsed), sidebar=\(original.sidebar.view.frame), parent=\(String(describing: original.sidebar.parent)), splitBounds=\(String(describing: sidebarSplit?.bounds)), arranged=\(sidebarSplit?.arrangedSubviews.map { String(describing: $0.frame) } ?? [])"
        check("\(mode): capture saves sidebar visibility and expanded width", captured.sidebarCollapsed == (mode == .icons) && abs(captured.sidebarWidth - 245) < 2, sidebarDetail)
        check("\(mode): capture records actual window geometry", captured.frame != nil && frame(captured.frame!) == original.window!.frame)
        check("\(mode): fixture includes transient state to discard", left.history.entries.count == 3 && left.isFiltering && !left.fileView.selectedItems.isEmpty && undo.canUndo && tabs.canReopenClosedTab)
        try store.flush()

        // JSON creates a value-only process boundary. The new window begins
        // with an unrelated initial URL whose deferred load must not win.
        let persisted = try JSONDecoder().decode(WorkspaceWindowState.self, from: JSONEncoder().encode(captured))
        let restoredStore = DirectoryViewPropertiesStore(fileURL: storeFile)
        let restored = makeWindow(at: fixture, store: restoredStore)
        defer { restored.close() }
        restored.restoreWorkspaceSession(persisted)
        await allListed(restored, state: persisted)
        let freshComparison = restored.tabs.pages[1]
        check("\(mode): restore replaces the initial tab without adding Home", restored.tabs.count == 3 && restored.tabs.pages.map { $0.panes[0].currentURL } == [folders[3], folders[0], folders[4]])
        check("\(mode): restored pages and panes have fresh ownership", freshComparison !== comparison && freshComparison.panes[0] !== left && freshComparison.panes[1] !== right && freshComparison.panes.allSatisfy { $0.host === restored })
        check("\(mode): restore selects correct tab and active pane", restored.tabs.currentIndex == 1 && restored.browser === freshComparison.panes[expectedActive] && freshComparison.activeIndex == expectedActive)
        check("\(mode): restored keyboard focus agrees with active marker", restored.window?.firstResponder === restored.browser.focusView)
        check("\(mode): exactly the selected page is visible", restored.tabs.pages.enumerated().allSatisfy { $0.element.view.isHidden == ($0.offset != 1) })
        check("\(mode): labels and physical pane paths are restored", restored.tabs.tabBar.titles == ["Nested", "Daily comparison", "Extra"] && freshComparison.panes.map { $0.addressBar.url } == [folders[0], folders[1]])
        check("\(mode): sidebar state is applied to actual layout", restored.isSidebarCollapsed == captured.sidebarCollapsed && abs(restored.workspaceSessionState.sidebarWidth - captured.sidebarWidth) < 2)
        check("\(mode): split divider is applied after window layout", abs(freshComparison.workspaceSplitFraction - captured.tabs[1].splitFraction) < 0.015 && freshComparison.panes.allSatisfy { $0.view.bounds.width >= 159 })
        check("\(mode): window frame survives the round trip", restored.window!.frame == frame(persisted.frame!))
        check("\(mode): directory-view preferences still choose the actual view", freshComparison.panes.allSatisfy { $0.viewMode == mode && ($0.fileView is IconGridViewController) == (mode == .icons) })
        check("\(mode): independently stored folder grouping survives", freshComparison.panes[0].model.groupKey == .kind && freshComparison.panes[1].model.groupKey == .dateModified)
        check("\(mode): history and local filters restart cleanly", restored.tabs.pages.flatMap(\.panes).allSatisfy { $0.history.entries.count == 1 && !$0.isFiltering })
        check("\(mode): selection, undo and closed-tab stack are not resurrected", restored.tabs.pages.flatMap(\.panes).allSatisfy { $0.fileView.selectedItems.isEmpty } && restored.window?.undoManager?.canUndo == false && !restored.tabs.canReopenClosedTab)
        check("\(mode): originals retain their transient state independently", left.history.entries.count == 3 && left.isFiltering && undo.canUndo)

        restored.restoreWorkspaceSession(persisted)
        await allListed(restored, state: persisted)
        check("\(mode): repeated restoration stays at three tabs", restored.tabs.count == 3 && restored.tabs.pages.map { $0.panes[0].currentURL } == [folders[3], folders[0], folders[4]])
        check("\(mode): repeated restoration retains active side and focus", restored.tabs.currentIndex == 1 && restored.tabs.currentPage.activeIndex == expectedActive && restored.window?.firstResponder === restored.browser.focusView)
        check("\(mode): recapture retains durable tab values", restored.workspaceSessionState.tabs.enumerated().allSatisfy {
            let expected = persisted.tabs[$0.offset]
            return $0.element.panes == expected.panes && $0.element.customTitle == expected.customTitle
                && $0.element.activePaneIndex == expected.activePaneIndex && abs($0.element.splitFraction - expected.splitFraction) < 0.015
        })
        let resizedPage = restored.tabs.currentPage
        resizedPage.setWorkspaceSplitFraction(0.7)
        let wideFrame = restored.window!.frame
        var narrowFrame = wideFrame
        narrowFrame.size.width = 560
        restored.window?.setFrame(narrowFrame, display: false)
        restored.window?.contentView?.layoutSubtreeIfNeeded()
        check("\(mode): narrow layout keeps the requested ratio", abs(resizedPage.workspaceSplitFraction - 0.7) < 0.001)
        check("\(mode): narrow layout leaves both panes visible", resizedPage.panes.allSatisfy { $0.view.bounds.width > 120 })
        restored.tabs.selectTab(at: 0)
        restored.window?.setFrame(wideFrame, display: false)
        restored.window?.contentView?.layoutSubtreeIfNeeded()
        restored.tabs.selectTab(at: 1)
        restored.window?.contentView?.layoutSubtreeIfNeeded()
        let usableWidth = resizedPage.splitView.bounds.width - resizedPage.splitView.dividerThickness
        check("\(mode): background resize retains the requested ratio", abs(restored.workspaceSessionState.tabs[1].splitFraction - 0.7) < 0.001)
        check("\(mode): wide layout returns the divider to its saved proportion", usableWidth > 0 && abs(resizedPage.panes[0].view.frame.width / usableWidth - 0.7) < 0.015)
        check("\(mode): returning to resized background split restores focus", restored.window?.firstResponder === resizedPage.active.focusView)
    }

    @MainActor private static func searchRestoration(folders: [URL], fixture: URL) async throws {
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("search-views.json"))
        let original = makeWindow(at: folders[0], store: store)
        defer { original.close() }
        await listed(original.browser, at: folders[0])
        let request = SearchRequest(rootURL: folders[3], name: "needle", kind: .document)
        original.browser.startSearch(request)
        await searched(original.browser)
        let right = original.tabs.currentPage.split(with: folders[1])
        await listed(right, at: folders[1])
        original.tabs.currentPage.activate(original.tabs.currentPage.panes[0])
        let captured = original.workspaceSessionState
        check("search capture retains origin separately from search scope", captured.tabs[0].panes[0].url == folders[0] && captured.tabs[0].panes[0].search == request)
        check("search capture keeps the ordinary peer pane ordinary", captured.tabs[0].panes[1].search == nil && captured.tabs[0].panes[1].url == folders[1])
        let freshResult = folders[3].appendingPathComponent("new-needle.txt")
        try Data("created after the session snapshot".utf8).write(to: freshResult)
        let restored = makeWindow(at: fixture, store: store)
        defer { restored.close() }
        restored.restoreWorkspaceSession(captured)
        let pane = restored.tabs.currentPage.panes[0]
        await searched(pane)
        await listed(restored.tabs.currentPage.panes[1], at: folders[1])
        check("restored search re-runs saved conditions", pane.searchSession.request == request && pane.model.items.contains { sameFilePath($0.url, freshResult) }, "request=\(String(describing: pane.searchSession.request)), expected=\(request), status=\(pane.searchSession.status.message), items=\(pane.model.items.map(\.url)), fresh=\(freshResult)")
        check("restored search results use real file URLs", pane.model.items.allSatisfy { $0.url.isFileURL && sameFilePath($0.url.deletingLastPathComponent(), folders[3]) })
        check("restored search preserves the original browsing location", pane.currentURL == folders[0] && pane.history.entries.count == 1)
        check("restored search has active keyboard focus", restored.browser === pane && restored.window?.firstResponder === pane.focusView)
        check("restored search leaves the peer pane unswitched", !restored.tabs.currentPage.panes[1].isSearching && restored.tabs.currentPage.panes[1].currentURL == folders[1])
        check("restored search exposes its conditions and title", pane.searchPanel.isShowingOptions && restored.tabs.tabBar.titles[0] == "Search: needle | Right")
        pane.closeSearch()
        await listed(pane, at: folders[0])
        check("closing restored search returns to the original directory", !pane.isSearching && pane.currentURL == folders[0] && restored.workspaceSessionState.tabs[0].panes[0].search == nil)
        check("closing a restored search leaves the original search intact", original.tabs.currentPage.panes[0].isSearching && original.tabs.currentPage.panes[0].searchSession.request == request)
    }

    @MainActor private static func unavailableLocations(folders: [URL], fixture: URL) async throws {
        let missing = fixture.appendingPathComponent("unmounted-or-renamed", isDirectory: true)
        let regularFile = fixture.appendingPathComponent("no-longer-a-folder")
        try Data("a file now occupies the old folder path".utf8).write(to: regularFile)
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("unavailable-views.json"))
        let state = WorkspaceWindowState(tabs: [
            WorkspaceTabState(panes: [WorkspacePaneState(url: folders[0]), WorkspacePaneState(url: missing)], activePaneIndex: 1),
            WorkspaceTabState(panes: [WorkspacePaneState(url: regularFile)], activePaneIndex: 0)
        ], selectedTabIndex: 0)
        let wc = makeWindow(at: fixture, store: store)
        defer { wc.close() }
        wc.restoreWorkspaceSession(state)
        await allListed(wc, state: state)
        let missingPane = wc.tabs.pages[0].panes[1]
        let replacedPane = wc.tabs.pages[1].active
        await wait("missing directory displays an inline error") { visibleError(in: missingPane) }
        wc.tabs.selectTab(at: 1)
        await wait("file replacing a directory displays an inline error") { visibleError(in: replacedPane) }
        check("unavailable locations retain their saved URLs", missingPane.currentURL?.path == missing.path && replacedPane.currentURL == regularFile && wc.workspaceSessionState.tabs[0].panes[1].url.path == missing.path)
        check("unavailable locations do not replace healthy peers", wc.tabs.pages[0].panes[0].currentURL == folders[0] && !wc.tabs.pages[0].panes[0].model.items.isEmpty)
        check("unavailable locations keep their slots and active side", wc.tabs.count == 2 && wc.tabs.pages[0].isSplit && wc.tabs.pages[0].activeIndex == 1)
        check("unavailable location errors never open a modal or sheet", NSApp.modalWindow == nil && wc.window?.attachedSheet == nil)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try Data("available again".utf8).write(to: missing.appendingPathComponent("returned.txt"))
        wc.tabs.selectTab(at: 0)
        missingPane.reload()
        await wait("previously missing location can be refreshed") { missingPane.model.items.contains { $0.name == "returned.txt" } }
        check("refresh retains the recovered pane's identity and location", wc.browser === missingPane && missingPane.currentURL?.path == missing.path && wc.tabs.count == 2)
        missingPane.navigate(to: folders[1])
        await listed(missingPane, at: folders[1])
        check("navigation out of unavailable location clears inline failure", !visibleError(in: missingPane) && wc.workspaceSessionState.tabs[0].panes[1].url == folders[1])
    }

    @MainActor private static func archiveRestoration(folders: [URL], fixture: URL) async throws {
        let manager = FileManager.default
        let source = fixture.appendingPathComponent("ZIP # 会话", isDirectory: true)
        let nested = source.appendingPathComponent("Nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("restored ZIP content".utf8).write(to: nested.appendingPathComponent("note.txt"))
        let archive: URL = try await withCheckedThrowingContinuation { continuation in
            FileOperations.compress(urls: [source], to: fixture) { continuation.resume(with: $0) }
        }
        let archiveBytes = try Data(contentsOf: archive)
        let logical = archive.appendingPathComponent(source.lastPathComponent).appendingPathComponent(nested.lastPathComponent)
        let views = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("zip-session-views.json"))
        let zipKey = "experimentalZIPBrowsingEnabled"
        let originalPreference = UserDefaults.standard.object(forKey: zipKey)
        var windows: [MainWindowController] = []
        var extracted: [ArchiveBrowsingSession] = []
        defer {
            windows.forEach { $0.close() }
            // Release only snapshots prepared by this fixture. Closing the
            // shared registry would disable subsequent archive smoke tests.
            extracted.forEach { $0.close() }
            restorePreference(originalPreference, forKey: zipKey)
        }
        restorePreference(nil, forKey: zipKey)
        check("ZIP sessions restore with the fresh browsing default", AppPreferences.experimentalZIPBrowsingEnabled)
        let original = makeWindow(at: folders[0], store: views)
        windows.append(original)
        await listed(original.browser, at: folders[0])
        original.browser.navigate(to: logical)
        let pending = original.workspaceSessionState
        check("ZIP navigation captures the logical destination while extraction is pending", original.browser.isPreparingArchive && pending.tabs[0].panes[0].url.path == logical.path)
        await listed(original.browser, at: logical)
        guard let firstSession = ArchiveWorkspace.shared.session(for: logical) else {
            check("ZIP fixture prepares a retained snapshot", false); return
        }
        extracted.append(firstSession)
        let physical = try ArchiveWorkspace.shared.readableURL(for: logical)
        original.browser.navigate(to: physical)
        await listed(original.browser, at: logical)
        let captured = original.workspaceSessionState
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let encoded = try encoder.encode(captured)
        let document = String(decoding: encoded, as: UTF8.self)
        check("ZIP capture maps private snapshot navigation back to its logical archive path", captured.tabs[0].panes[0].url.path == logical.path && !document.contains(firstSession.storageURL.path) && !document.contains(firstSession.rootURL.path))
        check("ZIP capture retains a read-only ordinary navigation entry", captured.tabs[0].panes[0].search == nil && original.browser.isBrowsingArchive && !original.browser.canModifyCurrentLocation)
        original.close()
        firstSession.close()
        check("ZIP fixture removes its first private extraction before restoration", !manager.fileExists(atPath: firstSession.storageURL.path) && ArchiveWorkspace.shared.session(for: logical) == nil)

        let restored = makeWindow(at: folders[4], store: views)
        windows.append(restored)
        restored.restoreWorkspaceSession(try JSONDecoder().decode(WorkspaceWindowState.self, from: encoded))
        check("ZIP restoration starts a fresh extraction and preserves pending capture", restored.browser.isPreparingArchive && restored.workspaceSessionState.tabs[0].panes[0].url.path == logical.path)
        await listed(restored.browser, at: logical)
        guard let secondSession = ArchiveWorkspace.shared.session(for: logical) else {
            check("restored ZIP prepares a fresh snapshot", false); return
        }
        extracted.append(secondSession)
        check("ZIP restoration creates a different private snapshot", secondSession !== firstSession && secondSession.rootURL != firstSession.rootURL && manager.fileExists(atPath: secondSession.rootURL.path))
        check("restored ZIP displays original content using logical file URLs", restored.browser.model.items.map(\.name) == ["note.txt"] && restored.browser.model.items.allSatisfy { $0.url.path.hasPrefix(logical.path + "/") && $0.isArchiveEntry })
        let readable = restored.browser.model.items.first?.readableContentURL
        let contents = try readable.map { try String(contentsOf: $0) }
        check("restored ZIP reads the re-extracted file", contents == "restored ZIP content")
        check("restored ZIP retains fresh history and active keyboard focus", restored.browser.history.entries.count == 1 && restored.window?.firstResponder === restored.browser.focusView && restored.browser.isBrowsingArchive && !restored.browser.canModifyCurrentLocation)

        AppPreferences.experimentalZIPBrowsingEnabled = false
        let disabled = makeWindow(at: folders[0], store: views)
        windows.append(disabled)
        disabled.restoreWorkspaceSession(captured)
        await listed(disabled.browser, at: archive.deletingLastPathComponent())
        check("disabled ZIP restoration opens the archive's enclosing folder", !disabled.browser.isBrowsingArchive && disabled.workspaceSessionState.tabs[0].panes[0].url.path == archive.deletingLastPathComponent().path && disabled.tabs.count == 1)
        check("disabled ZIP restoration leaves the existing read-only pane intact", restored.browser.isBrowsingArchive && restored.browser.currentURL?.path == logical.path)
        let plainZIP = fixture.appendingPathComponent("ordinary-folder.zip", isDirectory: true)
        try manager.createDirectory(at: plainZIP, withIntermediateDirectories: true)
        disabled.restoreWorkspaceSession(WorkspaceWindowState(tabs: [WorkspaceTabState(panes: [WorkspacePaneState(url: plainZIP)])]))
        await listed(disabled.browser, at: plainZIP)
        check("an ordinary directory ending in zip restores normally with the experiment off", disabled.browser.currentURL?.path == plainZIP.path && !disabled.browser.isBrowsingArchive)
        check("session restoration never modifies the source archive", try Data(contentsOf: archive) == archiveBytes)

        restored.close()
        secondSession.close()
        try manager.removeItem(at: archive)
        for enabled in [false, true] {
            AppPreferences.experimentalZIPBrowsingEnabled = enabled
            let missing = makeWindow(at: folders[1], store: views)
            windows.append(missing)
            missing.restoreWorkspaceSession(captured)
            await listed(missing.browser, at: logical)
            await wait("missing ZIP shows an inline location error") { visibleError(in: missing.browser) }
            check("missing ZIP retains its full logical location with the experiment \(enabled ? "on" : "off")", missing.browser.currentURL?.path == logical.path && missing.workspaceSessionState.tabs[0].panes[0].url.path == logical.path && missing.tabs.count == 1)
            check("missing ZIP restoration never presents a modal or sheet", NSApp.modalWindow == nil && missing.window?.attachedSheet == nil)
        }

        let corruptZIP = fixture.appendingPathComponent("corrupt-workspace.zip")
        try Data("not an archive".utf8).write(to: corruptZIP)
        let failed = makeWindow(at: folders[0], store: views)
        windows.append(failed)
        await listed(failed.browser, at: folders[0])
        failed.browser.navigate(to: corruptZIP)
        await wait("corrupt ZIP preparation finishes") { !failed.browser.isPreparingArchive }
        check("failed ZIP navigation retains the currently displayed ordinary location", failed.browser.currentURL?.path == folders[0].path && !failed.browser.isBrowsingArchive && failed.workspaceSessionState.tabs[0].panes[0].url.path == folders[0].path)
        let afterFailureRequest = SearchRequest(rootURL: folders[0], name: "needle")
        failed.browser.startSearch(afterFailureRequest)
        await searched(failed.browser)
        let afterFailureState = failed.workspaceSessionState
        check("a search after failed ZIP navigation captures the displayed directory as origin", afterFailureState.tabs[0].panes[0].url.path == folders[0].path && afterFailureState.tabs[0].panes[0].search == afterFailureRequest)
        let freshSearch = makeWindow(at: folders[4], store: views)
        windows.append(freshSearch)
        freshSearch.restoreWorkspaceSession(afterFailureState)
        await searched(freshSearch.browser)
        check("restoring a search after failed ZIP navigation returns to its ordinary origin", freshSearch.browser.currentURL?.path == folders[0].path && freshSearch.browser.searchSession.request == afterFailureRequest && freshSearch.browser.model.items.map(\.name) == ["needle.txt"])
    }

    @MainActor private static func backgroundChanges(folders: [URL], fixture: URL) async {
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("callbacks-views.json"))
        let wc = makeWindow(at: folders[0], store: store)
        defer { wc.close() }
        await listed(wc.browser, at: folders[0])
        var changes = 0
        wc.onSessionChanged = { changes += 1 }
        var baseline = changes
        let left = wc.browser
        let right = wc.tabs.currentPage.split(with: folders[1])
        await listed(right, at: folders[1])
        check("creating a split reports a session change", changes > baseline)
        baseline = changes
        wc.tabs.currentPage.activate(left)
        check("switching active side reports a session change", changes > baseline)
        baseline = changes
        right.navigate(to: folders[2]); await listed(right, at: folders[2])
        check("inactive peer navigation reports a session change", changes > baseline && wc.browser === left)
        baseline = changes
        let background = wc.tabs.newTab(at: folders[3], activate: false)
        await listed(background, at: folders[3])
        check("adding a background tab reports a session change", changes > baseline && wc.browser === left)
        let backgroundPage = wc.tabs.pages[1]
        baseline = changes
        background.navigate(to: folders[4]); await listed(background, at: folders[4])
        check("background tab navigation reports a session change", changes > baseline && wc.browser === left && wc.workspaceSessionState.tabs[1].panes[0].url == folders[4])
        baseline = changes
        wc.tabs.setTitle("Background work", for: backgroundPage)
        check("background rename reports a session change", changes > baseline && wc.workspaceSessionState.tabs[1].customTitle == "Background work")
        baseline = changes
        wc.tabs.moveTab(from: 1, to: 0)
        check("tab reorder reports a session change without switching pages", changes > baseline && wc.tabs.currentIndex == 1 && wc.browser === left)
        baseline = changes
        let split = wc.tabs.currentPage.splitView
        split.setPosition((split.bounds.width - split.dividerThickness) * 0.4, ofDividerAt: 0)
        check("divider adjustment reports a session change", changes > baseline && abs(wc.workspaceSessionState.tabs[1].splitFraction - 0.4) < 0.015)
        baseline = changes
        wc.toggleSidebar(nil)
        check("sidebar collapse reports a session change", changes > baseline && wc.workspaceSessionState.sidebarCollapsed)
        baseline = changes
        wc.tabs.selectTab(at: 0)
        check("tab selection reports a session change", changes > baseline && wc.workspaceSessionState.selectedTabIndex == 0)
        baseline = changes
        wc.tabs.closeTab(at: 0)
        check("closing a tab reports a session change", changes > baseline && wc.workspaceSessionState.tabs.count == 1)
        // A removed page may finish work later. Its old callback must not turn
        // a closed tab back into persisted state or change the active window.
        baseline = changes
        background.navigate(to: folders[1]); await listed(background, at: folders[1])
        check("late navigation from a closed page cannot affect session state", changes == baseline && wc.workspaceSessionState.tabs.count == 1 && wc.browser === left)
        baseline = changes
        wc.tabs.toggleSplit()
        check("closing a pane reports the surviving location", changes > baseline && wc.workspaceSessionState.tabs[0].panes.count == 1 && wc.browser === right)
    }

    private static func geometryChecks() {
        let primary = NSRect(x: 0, y: 25, width: 1440, height: 850)
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let minimum = NSSize(width: 560, height: 360)
        func constrain(_ frame: NSRect, screens: [NSRect] = []) -> NSRect {
            WorkspaceWindowGeometry.constrainedFrame(frame, visibleFrames: screens.isEmpty ? [primary] : screens, minimumSize: minimum)
        }
        let intact = NSRect(x: 100, y: 150, width: 1000, height: 640)
        check("on-screen saved geometry is unchanged", constrain(intact) == intact)
        let secondaryFrame = NSRect(x: -1700, y: 100, width: 1000, height: 640)
        check("negative-origin connected displays retain their windows", constrain(secondaryFrame, screens: [primary, secondary]) == secondaryFrame)
        check("a removed display's window becomes fully reachable", primary.contains(constrain(NSRect(x: 3000, y: 200, width: 1000, height: 640))))
        check("a window below the visible display is moved back", primary.contains(constrain(NSRect(x: 100, y: -900, width: 1000, height: 640))))
        check("a window above the menu bar is moved back", primary.contains(constrain(NSRect(x: 100, y: 950, width: 1000, height: 640))))
        let oversized = constrain(NSRect(x: -100, y: -100, width: 4000, height: 2400))
        check("oversized windows fit the current display", primary.contains(oversized) && oversized.width >= minimum.width && oversized.height >= minimum.height)
        let tiny = constrain(NSRect(x: 100, y: 100, width: 30, height: 40))
        check("undersized saved windows respect current minimum size", primary.contains(tiny) && tiny.width >= minimum.width && tiny.height >= minimum.height)
        let seam = constrain(NSRect(x: -50, y: 100, width: 1000, height: 640), screens: [primary, secondary])
        check("a window straddling displays remains fully reachable on one", primary.contains(seam) || secondary.contains(seam))
    }

    @MainActor private static func applicationLifecycle(folders: [URL], fixture: URL) async throws {
        let terminalKey = "experimentalTerminalEnabled"
        let originalTerminalPreference = UserDefaults.standard.object(forKey: terminalKey)
        defer { restorePreference(originalTerminalPreference, forKey: terminalKey) }
        restorePreference(nil, forKey: terminalKey)
        check("workspace lifecycle uses the fresh enabled terminal preference", AppPreferences.experimentalTerminalEnabled)
        let domain = "com.tursora.workspace-smoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
        let provider = FixtureProvider(home: folders[0])
        let views = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("lifecycle-views.json"))
        var delegates: [AppDelegate] = []
        defer {
            for delegate in delegates {
                delegate.prepareWorkspaceForTermination()
                delegate.windowControllers.forEach { $0.close() }
            }
        }
        func delegate(_ store: WorkspaceSessionStore) -> AppDelegate {
            let value = AppDelegate(provider: provider, places: PlacesModel(), workspaceStore: store,
                                    preferences: preferences, viewPropertiesStore: views)
            delegates.append(value)
            return value
        }
        let session = WorkspaceSessionState(windows: [
            WorkspaceWindowState(tabs: [WorkspaceTabState(panes: [WorkspacePaneState(url: folders[1]), WorkspacePaneState(url: folders[2])], activePaneIndex: 1, customTitle: "Comparison")]),
            WorkspaceWindowState(tabs: [WorkspaceTabState(panes: [WorkspacePaneState(url: folders[3])])])
        ], activeWindowIndex: 1)
        let file = fixture.appendingPathComponent("lifecycle/session.json")
        let store = WorkspaceSessionStore(fileURL: file)
        check("lifecycle fixture saves two windows", store.save(session))
        let first = delegate(store)
        first.beginWorkspaceSession(showWindows: false)
        check("launch restores every saved window without an extra Home", first.windowControllers.count == 2 && first.currentWorkspaceState.windows.map { $0.tabs[0].panes[0].url } == [folders[1], folders[3]])
        check("restoring windows and split panes never creates a default-enabled terminal", first.windowControllers.allSatisfy { $0.terminalPanel == nil })
        check("launch restores the active window index", first.currentWorkspaceState.activeWindowIndex == 1)
        check("launch retains split focus and custom title", first.windowControllers[0].tabs.currentPage.activeIndex == 1 && first.windowControllers[0].tabs.currentPage.customTitle == "Comparison")
        let windowIDs = first.windowControllers.map(ObjectIdentifier.init)
        first.beginWorkspaceSession(showWindows: false)
        check("launch restoration runs only once", first.windowControllers.map(ObjectIdentifier.init) == windowIDs)
        for (index, window) in first.windowControllers.enumerated() { await allListed(window, state: session.windows[index]) }
        let backgroundPane = first.windowControllers[0].tabs.currentPage.panes[0]
        backgroundPane.navigate(to: folders[4])
        await listed(backgroundPane, at: folders[4])
        check("background navigation leaves every terminal panel uncreated", first.windowControllers.allSatisfy { $0.terminalPanel == nil })
        await wait("background navigation is saved by the app debounce") {
            guard case .loaded(let value) = store.load() else { return false }
            return value.windows[0].tabs[0].panes[0].url == folders[4]
        }
        check("automatic snapshots include background navigation and active window", loaded(store)?.windows[0].tabs[0].panes[0].url == folders[4] && loaded(store)?.activeWindowIndex == 1)
        let clearRequest = SearchRequest(rootURL: folders[4], name: "needle")
        backgroundPane.startSearch(clearRequest)
        await searched(backgroundPane)
        check("search-clear fixture persists an active background search", first.saveWorkspaceNow() && loaded(store)?.windows[0].tabs[0].panes[0].search == clearRequest)
        var clearEvents = 0
        let originalSessionCallback = first.windowControllers[0].onSessionChanged
        first.windowControllers[0].onSessionChanged = { clearEvents += 1; originalSessionCallback?() }
        backgroundPane.searchPanel.clearButton.performClick(nil)
        check("Clear reports a workspace change and removes the captured search", clearEvents > 0 && first.currentWorkspaceState.windows[0].tabs[0].panes[0].search == nil)
        await wait("clearing background search persists through the app debounce") {
            guard case .loaded(let value) = store.load() else { return false }
            return value.windows[0].tabs[0].panes[0].search == nil
        }
        check("cleared search cannot return on the next launch", loaded(store)?.windows[0].tabs[0].panes[0].search == nil && loaded(store)?.windows[0].tabs[0].panes[0].url == folders[4])
        backgroundPane.navigate(to: folders[1])
        first.prepareWorkspaceForTermination()
        check("immediate quit saves the final location before asynchronous listing", loaded(store)?.windows[0].tabs[0].panes[0].url == folders[1])
        let quittingData = try Data(contentsOf: file)
        backgroundPane.navigate(to: folders[2])
        first.prepareWorkspaceForTermination()
        check("repeated termination preparation cannot overwrite the first quit snapshot", try Data(contentsOf: file) == quittingData)
        first.windowControllers.forEach { $0.close() }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("quit cleanup cannot replace the saved windows with an empty session", try Data(contentsOf: file) == quittingData)

        let next = delegate(WorkspaceSessionStore(fileURL: file))
        next.beginWorkspaceSession(showWindows: false)
        check("a fresh application instance restores the quit snapshot", next.windowControllers.count == 2 && next.currentWorkspaceState.activeWindowIndex == 1)
        next.windowControllers[0].close()
        check("normal window close removes the closed window from capture", next.currentWorkspaceState.windows.count == 1 && next.currentWorkspaceState.windows[0].tabs[0].panes[0].url == folders[3])
        check("normal close persists only surviving windows", next.saveWorkspaceNow() && loaded(next.workspaceStore)?.windows.count == 1)
        next.windowControllers[0].close()
        check("closing every window persists an explicit empty session", next.saveWorkspaceNow() && loaded(next.workspaceStore)?.windows.isEmpty == true)
        let empty = delegate(WorkspaceSessionStore(fileURL: file))
        empty.beginWorkspaceSession(showWindows: false)
        check("an explicitly empty session launches one Home window", empty.windowControllers.count == 1 && empty.currentWorkspaceState.windows[0].tabs[0].panes[0].url == folders[0])
        await listed(empty.windowControllers[0].browser, at: folders[0])
        check("launching Home with the terminal enabled keeps its panel uncreated", empty.windowControllers[0].terminalPanel == nil)
        empty.prepareWorkspaceForTermination()
        empty.windowControllers.forEach { $0.close() }

        let explicitStore = WorkspaceSessionStore(fileURL: fixture.appendingPathComponent("explicit/session.json"))
        check("explicit-open fixture saves its old workspace", explicitStore.save(session))
        let explicit = delegate(explicitStore)
        let requested = explicit.newWindow(at: folders[4], show: false, cascade: false)
        await listed(requested.browser, at: folders[4])
        check("an explicit new window does not eagerly construct a terminal", requested.terminalPanel == nil)
        explicit.beginWorkspaceSession(showWindows: false)
        check("a prelaunch explicit request coexists with restored windows", explicit.windowControllers.count == 3 && explicit.windowControllers[0] === requested)
        check("the explicit request remains the active launch destination", explicit.currentWorkspaceState.activeWindowIndex == 0 && requested.workspaceSessionState.tabs[0].panes[0].url == folders[4])
        check("combining an explicit window with a restored workspace leaves all terminals uncreated", explicit.windowControllers.allSatisfy { $0.terminalPanel == nil })
        explicit.prepareWorkspaceForTermination()
        explicit.windowControllers.forEach { $0.close() }

        let optionStore = WorkspaceSessionStore(fileURL: fixture.appendingPathComponent("option/session.json"))
        check("option fixture saves its previous workspace", optionStore.save(session))
        preferences.restoreWorkspaceOnLaunch = false
        let disabled = delegate(optionStore)
        disabled.beginWorkspaceSession(showWindows: false)
        check("disabled restoration opens Home and clears the prior session", disabled.windowControllers.count == 1 && disabled.currentWorkspaceState.windows[0].tabs[0].panes[0].url == folders[0] && optionStore.load() == .missing)
        disabled.windowControllers[0].browser.navigate(to: folders[2])
        await listed(disabled.windowControllers[0].browser, at: folders[2])
        check("disabled restoration does not save subsequent navigation", !disabled.saveWorkspaceNow() && optionStore.load() == .missing)
        preferences.restoreWorkspaceOnLaunch = true
        check("enabling restoration saves the current workspace immediately", loaded(optionStore)?.windows[0].tabs[0].panes[0].url == folders[2] && disabled.windowControllers.count == 1)
        disabled.windowControllers[0].browser.navigate(to: folders[4])
        preferences.restoreWorkspaceOnLaunch = false
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("disabling restoration cancels a pending automatic save", optionStore.load() == .missing)
        disabled.prepareWorkspaceForTermination()
        disabled.windowControllers.forEach { $0.close() }
        preferences.restoreWorkspaceOnLaunch = true

        for (name, content) in [("corrupt", "not JSON"), ("future", "{\"version\":999,\"windows\":[]}")] {
            let damagedFile = fixture.appendingPathComponent("\(name)-session.json")
            let bytes = Data(content.utf8)
            try bytes.write(to: damagedFile)
            let damagedStore = WorkspaceSessionStore(fileURL: damagedFile)
            let damaged = delegate(damagedStore)
            damaged.beginWorkspaceSession(showWindows: false)
            check("\(name) session launches a usable Home window", damaged.windowControllers.count == 1 && damaged.currentWorkspaceState.windows[0].tabs[0].panes[0].url == folders[0])
            damaged.windowControllers[0].browser.navigate(to: folders[1])
            let automaticSave = damaged.saveWorkspaceNow()
            let preserved = try Data(contentsOf: damagedFile)
            check("\(name) session is not silently repaired by navigation", !automaticSave && preserved == bytes)
            damaged.prepareWorkspaceForTermination()
            check("quitting preserves a \(name) session file", try Data(contentsOf: damagedFile) == bytes)
            check("explicit retry can replace the \(name) session with current work", damaged.saveWorkspaceNow(replacingUnreadable: true) && loaded(damagedStore)?.windows[0].tabs[0].panes[0].url == folders[1])
            damaged.windowControllers.forEach { $0.close() }
        }

        let clearDomain = domain + ".pending-clear"
        let clearDefaults = UserDefaults(suiteName: clearDomain)!
        defer { clearDefaults.removePersistentDomain(forName: clearDomain) }
        let clearPreferences = AppPreferences.Store(defaults: clearDefaults, notificationCenter: NotificationCenter())
        clearPreferences.restoreWorkspaceOnLaunch = false
        let clearFile = fixture.appendingPathComponent("pending-clear-session.json")
        try FileManager.default.createDirectory(at: clearFile, withIntermediateDirectories: true)
        let clearStore = WorkspaceSessionStore(fileURL: clearFile)
        let clearing = AppDelegate(provider: provider, places: PlacesModel(), workspaceStore: clearStore,
                                   preferences: clearPreferences, viewPropertiesStore: views)
        defer { clearing.windowControllers.forEach { $0.close() } }
        clearing.beginWorkspaceSession(showWindows: false)
        var isDirectory: ObjCBool = false
        check("disabled restoration preserves a directory blocking session deletion and reports the failure", clearStore.lastError != nil && FileManager.default.fileExists(atPath: clearFile.path, isDirectory: &isDirectory) && isDirectory.boolValue && clearing.windowControllers.count == 1)
        // Replace only this empty fixture directory with an owned regular
        // file, making the pending unlink possible without another toggle.
        try FileManager.default.removeItem(at: clearFile)
        try JSONEncoder().encode(session).write(to: clearFile)
        clearing.prepareWorkspaceForTermination()
        check("quit retries a pending session deletion while restoration remains disabled", !clearPreferences.restoreWorkspaceOnLaunch && !FileManager.default.fileExists(atPath: clearFile.path) && clearStore.lastError == nil)
    }

    private static func loaded(_ store: WorkspaceSessionStore) -> WorkspaceSessionState? {
        if case .loaded(let state) = store.load() { return state }
        return nil
    }

    private static func sameFilePath(_ first: URL, _ second: URL) -> Bool {
        first.resolvingSymlinksInPath().standardizedFileURL.path == second.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private final class FixtureProvider: FileProvider {
        let homeURL: URL
        private let local = LocalFileProvider()
        init(home: URL) { homeURL = home }
        func listDirectory(_ url: URL) throws -> [FileItem] { try local.listDirectory(url) }
        func displayName(for url: URL) -> String { local.displayName(for: url) }
    }

    @MainActor private static func makeWindow(at url: URL, store: DirectoryViewPropertiesStore) -> MainWindowController {
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: url, viewPropertiesStore: store)
        if let window = wc.window {
            // Legacy NSWindow frame autosaving can leave a prior smoke run's
            // 560-point frame behind. Establish room for the explicit sidebar
            // and pane proportions before exercising their restoration.
            var size = NSSize(width: 1000, height: 640)
            if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
                let available = window.contentRect(forFrameRect: visibleFrame).size
                size.width = min(size.width, available.width)
                size.height = min(size.height, available.height)
            }
            window.setContentSize(size)
            window.center()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        wc.window?.makeKeyAndOrderFront(nil)
        return wc
    }

    private static func frame(_ state: WorkspaceWindowFrame) -> NSRect {
        NSRect(x: state.x, y: state.y, width: state.width, height: state.height)
    }

    private static func restorePreference(_ value: Any?, forKey key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .tursoraPreferencesChanged, object: AppPreferences.shared)
    }

    @MainActor private static func allListed(_ wc: MainWindowController, state: WorkspaceWindowState) async {
        check("restored window has the expected number of tabs", wc.tabs.count == state.tabs.count)
        for (index, tab) in state.tabs.enumerated() {
            check("restored tab \(index) has the expected pane count", wc.tabs.pages[index].panes.count == tab.panes.count)
            for (paneIndex, pane) in tab.panes.enumerated() {
                await listed(wc.tabs.pages[index].panes[paneIndex], at: pane.url)
            }
        }
        wc.window?.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor private static func listed(_ pane: BrowserViewController, at url: URL) async {
        await wait("directory listing", detail: { "\(pane.currentURL?.path ?? "nil") vs \(url.path)" }) {
            pane.currentURL?.standardizedFileURL.path == url.standardizedFileURL.path
                && pane.model.url?.standardizedFileURL.path == url.standardizedFileURL.path
                && pane.model.generation > 0 && !pane.isPreparingArchive && !pane.model.isSearchResults
        }
    }

    @MainActor private static func searched(_ pane: BrowserViewController) async {
        await wait("search finishes", detail: { pane.searchSession.status.message }) {
            guard case .finished = pane.searchSession.status else { return false }
            return pane.isSearching && pane.model.isSearchResults
        }
    }

    @MainActor private static func visibleError(in pane: BrowserViewController) -> Bool {
        func containsError(_ view: NSView) -> Bool {
            if let label = view as? NSTextField, !label.isHidden,
               label.stringValue.contains("Cannot open this folder.") { return true }
            return view.subviews.contains { containsError($0) }
        }
        return containsError(pane.view)
    }

    @MainActor private static func wait(_ name: String, detail: () -> String = { "" }, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > deadline { check(name, false, detail()); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        print("\(success ? "ok  " : "FAIL") workspace UI: \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !success { fflush(stdout); exit(1) }
    }
}

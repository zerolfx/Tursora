import AppKit

/// Tab actions retain the clicked page across asynchronous menus, while fresh
/// tabs and detached windows reconstruct locations without moving ownership.
enum TabActionsSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("tursora-tab-actions-" + UUID().uuidString).resolvingSymlinksInPath()
            let oldZIP = AppPreferences.experimentalZIPBrowsingEnabled
            defer {
                AppPreferences.experimentalZIPBrowsingEnabled = oldZIP
                try? FileManager.default.removeItem(at: fixture)
            }
            do {
                print("== pane titles and tab context actions ==")
                let folders = ["Left", "Right", "Other", "Nested"].map { fixture.appendingPathComponent($0) }
                for url in folders { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
                try Data("search result".utf8).write(to: folders[3].appendingPathComponent("needle.txt"))
                pureTitles()
                for mode: ViewMode in [.details, .icons] {
                    try await menuActions(mode: mode, folders: folders, fixture: fixture)
                }
                try await searchAndArchive(folders: folders, fixture: fixture)
                completion()
            } catch { check("fixtures complete", false, error.localizedDescription) }
        }
    }

    private static func pureTitles() {
        check("single pane title", TabPage.title(left: "Left", right: nil, activeIndex: 0, custom: nil) == "Left")
        check("left-active split title has a separator without focus parentheses", TabPage.title(left: "Left", right: "Right", activeIndex: 0, custom: nil) == "Left | Right")
        check("right-active split title keeps the same names and physical order", TabPage.title(left: "Left", right: "Right", activeIndex: 1, custom: nil) == "Left | Right")
        check("literal folder-name parentheses remain intact", TabPage.title(left: "Plan (final)", right: "Archive (old)", activeIndex: 0, custom: nil) == "Plan (final) | Archive (old)")
        check("custom title overrides both panes", TabPage.title(left: "Left", right: "Right", activeIndex: 1, custom: "Work") == "Work")
        check("empty custom title returns automatic title", TabPage.title(left: "Left", right: nil, activeIndex: 0, custom: "") == "Left")
    }

    @MainActor private static func menuActions(mode: ViewMode, folders: [URL], fixture: URL) async throws {
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("\(mode)-views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: folders[0], viewPropertiesStore: store)
        defer { wc.close() }
        wc.window?.makeKeyAndOrderFront(nil)
        let tabs = wc.tabs
        await listed(wc.browser, at: folders[0])
        check("\(mode): single tab strip remains visible", !tabs.tabBar.isHidden)
        let first = tabs.currentPage
        let left = first.active
        let right = first.split(with: folders[1])
        await listed(right, at: folders[1])
        left.setViewMode(mode); right.setViewMode(mode)
        left.nameFilter = "*.txt"; right.setGroupKey(.kind)
        check("\(mode): split title includes both locations without focus markers", tabs.tabBar.titles[0] == "Left | Right", "\(tabs.tabBar.titles)")
        check("\(mode): split tooltip retains both full paths", tabs.tabBar.toolTips[0].contains(folders[0].path) && tabs.tabBar.toolTips[0].contains(folders[1].path))
        first.activate(left)
        check("\(mode): switching focus preserves the split title", tabs.tabBar.titles[0] == "Left | Right")
        check("\(mode): tooltip retains physical order and the focused side", tabs.tabBar.toolTips[0] == "Left (active): \(folders[0].path)\nRight: \(folders[1].path)")
        first.activate(right)
        let secondPane = tabs.newTab(at: folders[2])
        await listed(secondPane, at: folders[2])
        let second = tabs.currentPage
        let thirdPane = tabs.newTab(at: folders[3])
        await listed(thirdPane, at: folders[3])
        let third = tabs.currentPage
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let frame = tabs.tabBar.tabFrameForTesting(0)
        let point = tabs.tabBar.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: wc.window?.windowNumber ?? 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = tabs.tabBar.menu(for: event)!
        check("\(mode): right click builds all seven Dolphin actions", menu.items.filter { !$0.isSeparatorItem }.map(\.title) == TabContextAction.allCases.map(\.title))
        check("\(mode): context menu grouping matches pinned Dolphin", menu.items.enumerated().filter { $0.element.isSeparatorItem }.map(\.offset) == [2, 4])
        check("\(mode): background context menu does not select its tab", tabs.currentPage === third)
        check("\(mode): edge actions validate clicked page", item(.closeLeft, in: menu)?.isEnabled == false && item(.closeRight, in: menu)?.isEnabled == true)

        var renameReply: ((String?) -> Void)?
        tabs.renameTabTitleProvider = { _, reply in renameReply = reply }
        dispatch(.rename, in: menu)
        tabs.moveTab(from: 0, to: 2)
        tabs.selectTab(at: 0)
        renameReply?("  Comparison  ")
        check("\(mode): delayed rename follows clicked page through reorder", first.customTitle == "Comparison" && second.customTitle == nil && tabs.currentPage === second)
        first.activate(left)
        check("\(mode): renamed split ignores focus title changes", tabs.tabBar.titles.last == "Comparison")
        first.activate(right)
        // Use the menu created before reorder: New Tab must still read first,
        // not the unrelated page now occupying the old index.
        dispatch(.newTab, in: menu)
        let fresh = tabs.currentPage
        await listed(fresh.active, at: folders[1])
        check("\(mode): New Tab uses clicked active pane and starts unsplit", fresh !== first && !fresh.isSplit && fresh.active.currentURL == right.currentURL && fresh.customTitle == nil)
        check("\(mode): New Tab creates independent history and filter", fresh.active.history.entries.count == 1 && !fresh.active.isFiltering && left.isFiltering)
        let freshMenu = tabs.tabContextMenu(at: tabs.currentIndex)!
        tabs.renameTabTitleProvider = { _, reply in reply("Disposable") }
        dispatch(.rename, in: freshMenu)
        dispatch(.close, in: freshMenu)
        check("\(mode): closed menu actions cannot hit replacement index", !tabs.pages.contains { $0 === fresh })
        let beforeStale = tabs.count
        dispatch(.newTab, in: freshMenu, expectEnabled: false)
        check("\(mode): stale New Tab is a no-op", tabs.count == beforeStale)
        check("\(mode): reopen keeps custom title", tabs.reopenClosedTab() && tabs.currentPage === fresh && fresh.customTitle == "Disposable")
        dispatch(.close, in: tabs.tabContextMenu(at: tabs.currentIndex)!)
        tabs.selectTab(at: tabs.pages.firstIndex { $0 === second }!)
        second.active.addressBar.beginEditing()
        let beforeResponder = wc.window?.firstResponder
        tabs.closeTab(at: tabs.pages.firstIndex { $0 === third }!)
        check("\(mode): closing background preserves current page and address edit", tabs.currentPage === second && second.active.addressBar.isEditing && beforeResponder is NSTextView && wc.window?.firstResponder === beforeResponder)
        second.active.addressBar.endEditing(returnFocus: false)

        tabs.renameTabTitleProvider = { _, reply in reply("\n  ") }
        dispatch(.rename, in: menu)
        check("\(mode): blank rename restores automatic split title", first.customTitle == nil && first.tabTitle == "Left | Right")
        first.activate(left)
        let firstIndex = tabs.pages.firstIndex { $0 === first }!
        check("\(mode): background pane activation preserves its title and the current tab", tabs.tabBar.titles[firstIndex] == "Left | Right" && tabs.currentPage === second)
        first.activate(right)
        dispatch(.closeOthers, in: menu)
        check("\(mode): Close Other Tabs keeps clicked split and activates it", tabs.count == 1 && tabs.currentPage === first && first.panes[0] === left && first.panes[1] === right)
        check("\(mode): close boundaries disable when none exist", !tabs.canPerformTabAction(.closeLeft, on: first) && !tabs.canPerformTabAction(.closeRight, on: first) && !tabs.canPerformTabAction(.closeOthers, on: first))

        right.addressBar.beginEditing()
        tabs.toggleSplit()
        check("\(mode): closing an active pane editor focuses the survivor", !first.isSplit && first.active === left && wc.window?.firstResponder === left.focusView && !right.addressBar.isEditing)
        let replacementRight = first.split(with: folders[1])
        await listed(replacementRight, at: folders[1])
        replacementRight.addressBar.beginEditing()
        let editingResponder = wc.window?.firstResponder
        first.closePane(left)
        check("\(mode): closing the inactive pane preserves active editor focus", first.active === replacementRight && replacementRight.addressBar.isEditing && editingResponder is NSTextView && wc.window?.firstResponder === editingResponder)
        replacementRight.addressBar.endEditing(returnFocus: false)

        let b = tabs.newTab(at: folders[2]); await listed(b, at: folders[2])
        let survivor = tabs.currentPage
        let c = tabs.newTab(at: folders[3]); await listed(c, at: folders[3])
        tabs.selectTab(at: 1)
        let middleMenu = tabs.tabContextMenu(at: 1)!
        dispatch(.closeLeft, in: middleMenu)
        check("\(mode): Close Left preserves clicked current page", tabs.count == 2 && tabs.currentPage === survivor && tabs.pages[0] === survivor)
        dispatch(.closeRight, in: middleMenu)
        check("\(mode): Close Right still resolves reordered clicked identity", tabs.count == 1 && tabs.currentPage === survivor)
        tabs.onDetachTab = { _ in false }
        dispatch(.detach, in: tabs.tabContextMenu(at: 0)!)
        check("\(mode): failed detach keeps original page", tabs.count == 1 && tabs.currentPage === survivor)
        var closedWindow = false
        wc.onClose = { closedWindow = true }
        dispatch(.close, in: tabs.tabContextMenu(at: 0)!)
        check("\(mode): final Close Tab closes its owning window", closedWindow && tabs.count == 1)
    }

    @MainActor private static func searchAndArchive(folders: [URL], fixture: URL) async throws {
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("virtual-views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: folders[0], viewPropertiesStore: store)
        var detachedWindow: MainWindowController?
        defer { wc.close(); detachedWindow?.close() }
        wc.window?.makeKeyAndOrderFront(nil)
        let tabs = wc.tabs
        let source = wc.browser
        await listed(source, at: folders[0])
        source.navigate(to: folders[1]); await listed(source, at: folders[1])
        source.navigate(to: folders[0]); await listed(source, at: folders[0])
        let sourceUndo = wc.window!.undoManager!
        sourceUndo.registerUndo(withTarget: source) { _ in }
        let request = SearchRequest(rootURL: folders[3], name: "needle")
        source.startSearch(request)
        await searched(source)
        let sourcePage = tabs.currentPage
        check("search title distinguishes results from origin", sourcePage.tabTitle == "Search: needle")
        tabs.newTab(at: folders[2]); await listed(tabs.current, at: folders[2])
        dispatch(.newTab, in: tabs.tabContextMenu(at: 0)!)
        let copied = tabs.current
        await searched(copied)
        check("New Tab retains clicked search conditions and real result URLs", copied !== source && copied.searchSession.request == request && copied.model.items.map(\.url) == source.model.items.map(\.url) && copied.currentURL == folders[0])
        copied.closeSearch()
        await listed(copied, at: folders[0])
        check("closing copied search leaves source search intact", source.isSearching && !copied.isSearching)
        tabs.selectTab(at: 0)
        wc.newTab(nil)
        await searched(tabs.current)
        check("keyboard New Tab retains search conditions", tabs.current.searchSession.request == request && !tabs.currentPage.isSplit)
        tabs.closeCurrentTab()
        tabs.selectTab(at: 0)
        tabs.tabBar.onAdd?()
        await searched(tabs.current)
        check("plus New Tab retains search conditions", tabs.current.searchSession.request == request && !tabs.currentPage.isSplit)
        tabs.closeCurrentTab()
        tabs.selectTab(at: 0)
        let right = sourcePage.split(with: folders[1])
        await listed(right, at: folders[1])
        sourcePage.activate(source)
        tabs.setTitle("Search comparison", for: sourcePage)
        tabs.selectTab(at: 1)
        let currentBefore = tabs.currentPage
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        dispatch(.detach, in: tabs.tabContextMenu(at: 0)!)
        detachedWindow = NSApp.windows.filter { !windowsBefore.contains(ObjectIdentifier($0)) }
            .compactMap { $0.windowController as? MainWindowController }.first
        guard let detachedWindow else { check("Detach creates a registered app window", false); return }
        let detached = detachedWindow.tabs.currentPage
        await searched(detached.panes[0]); await listed(detached.panes[1], at: folders[1])
        check("Detach preserves URL pair, search, active side and custom title", detached.isSplit && detached.activeIndex == 0 && detached.customTitle == "Search comparison" && detached.panes[0].searchSession.request == request && detached.panes[1].currentURL == folders[1])
        check("Detach keyboard focus matches the restored active pane", detachedWindow.window?.firstResponder === detached.active.focusView)
        check("Detach creates fresh controllers without task or undo migration", detached !== sourcePage && detached.panes[0] !== source && detached.panes[1] !== right && detached.panes.allSatisfy { $0.history.entries.count == 1 } && detachedWindow.window?.undoManager?.canUndo == false && source.history.entries.count > 1 && sourceUndo.canUndo)
        check("Detach background tab preserves original current page", tabs.currentPage === currentBefore && !tabs.pages.contains { $0 === sourcePage })
        check("detached source can reopen with original split state", tabs.reopenClosedTab() && tabs.currentPage === sourcePage && sourcePage.active === source && source.isSearching)

        AppPreferences.experimentalZIPBrowsingEnabled = true
        let archive = try await compress(folders[3], to: fixture)
        let inside = archive.appendingPathComponent("Nested")
        let zipPane = tabs.newTab(at: inside)
        await listed(zipPane, at: inside)
        let zipPage = tabs.currentPage
        tabs.selectTab(at: 0)
        dispatch(.newTab, in: tabs.tabContextMenu(at: tabs.pages.firstIndex { $0 === zipPage }!)!)
        await listed(tabs.current, at: inside)
        check("ZIP New Tab retains logical archive path and read-only state", tabs.current !== zipPane && tabs.current.isBrowsingArchive && tabs.current.currentURL == inside && tabs.current.model.items.allSatisfy { $0.url.path.hasPrefix(archive.path) })
        let zipSnapshot = TabSnapshot(zipPage)
        let zipWC = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: fixture, viewPropertiesStore: store)
        defer { zipWC.close() }
        zipSnapshot.restore(in: zipWC.tabs)
        await listed(zipWC.browser, at: inside)
        check("ZIP detach snapshot never opens private extraction paths", zipWC.browser.isBrowsingArchive && zipWC.browser.currentURL == inside && zipWC.browser.archiveSourceURL == archive)
    }

    private static func item(_ action: TabContextAction, in menu: NSMenu) -> NSMenuItem? { menu.items.first { $0.title == action.title } }
    @MainActor private static func dispatch(_ action: TabContextAction, in menu: NSMenu, expectEnabled: Bool = true) {
        guard let item = item(action, in: menu), let selector = item.action else { check("\(action.title) has an action", false); return }
        check("\(action.title) uses its explicit action selector", NSStringFromSelector(selector) == "invoke:")
        if expectEnabled { check("\(action.title) menu item enabled", (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? item.isEnabled) }
        check("\(action.title) dispatch reaches controller", NSApp.sendAction(selector, to: item.target, from: item))
    }
    @MainActor private static func listed(_ pane: BrowserViewController, at url: URL) async {
        await wait("directory listing", detail: { "\(pane.currentURL?.path ?? "nil") vs \(url.path)" }) {
            pane.currentURL?.standardizedFileURL == url.standardizedFileURL && pane.model.url?.standardizedFileURL == url.standardizedFileURL && pane.model.generation > 0 && !pane.isPreparingArchive && !pane.model.isSearchResults
        }
    }
    @MainActor private static func searched(_ pane: BrowserViewController) async {
        await wait("search completes", detail: { pane.searchSession.status.message }) { pane.isSearching && !pane.searchSession.status.isSearching && pane.model.isSearchResults }
        check("search results available", !pane.model.items.isEmpty)
    }
    @MainActor private static func wait(_ name: String, detail: () -> String = { "" }, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > deadline { check(name, false, detail()); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private static func compress(_ source: URL, to destination: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            FileOperations.compress(urls: [source], to: destination) { continuation.resume(with: $0) }
        }
    }
    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        print("\(success ? "ok  " : "FAIL") tab actions: \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !success { fflush(stdout); exit(1) }
    }
}

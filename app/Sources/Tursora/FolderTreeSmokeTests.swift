import AppKit
import Darwin

/// Folder-tree checks use task-owned fixtures, isolated view stores and gated
/// providers. They do not enumerate a user's Home or persist a workspace.
enum FolderTreeSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            print("== folder tree ==")
            // Use libc's physical spelling. Foundation can retain /var on a
            // directory URL while directory enumeration returns /private/var.
            let root = URL(fileURLWithPath: physicalPath(FileManager.default.temporaryDirectory)!, isDirectory: true)
                .appendingPathComponent("tursora-folder-tree-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try makeFixture(root)
                try await modelChecks(root)
                try await delayedChecks(root)
                try await abandonedTreeChecks(root)
                try await systemAliasChecks(root)
                try await scrollVisibilityChecks(root.appendingPathComponent("Scroll"))
                for mode: ViewMode in [.details, .icons] {
                    let fixture = root.appendingPathComponent("UI-\(mode)")
                    try makeFixture(fixture)
                    try await windowChecks(fixture, mode: mode)
                }
                completion()
            } catch { check("fixture completes", false, error.localizedDescription) }
        }
    }

    private static func makeFixture(_ root: URL) throws {
        for name in ["Alpha/Nested/Deep", "Beta/Child", "Gamma", ".Hidden", "Demo.app/Contents"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("folder tree".utf8).write(to: root.appendingPathComponent("note.txt"))
        for name in ["Alpha", "Beta", "Gamma"] {
            try Data("folder tree".utf8).write(to: root.appendingPathComponent(name).appendingPathComponent("note.txt"))
        }
    }

    @MainActor private static func modelChecks(_ root: URL) async throws {
        let alpha = root.appendingPathComponent("Alpha")
        check("Home root uses a path-component boundary", sameLocation(FolderTreeModel.rootURL(for: alpha, home: root, limitsToHome: true), root) && FolderTreeModel.rootURL(for: URL(fileURLWithPath: root.path + "-outside"), home: root, limitsToHome: true).path == "/")
        check("unlimited or outside-Home locations use filesystem root", FolderTreeModel.rootURL(for: alpha, home: root, limitsToHome: false).path == "/" && FolderTreeModel.rootURL(for: URL(fileURLWithPath: "/Volumes"), home: root, limitsToHome: true).path == "/")
        let provider = CountingProvider(home: root)
        let items = try provider.listDirectory(root)
        let folders = FolderTreeModel.folders(from: items, showsHidden: false)
        check("tree filters files, packages and hidden folders", folders.map(\.name) == ["Alpha", "Beta", "Gamma"], folders.map(\.name).description)
        check("Show Hidden includes hidden folders but still excludes package contents", FolderTreeModel.folders(from: items, showsHidden: true).map(\.name).contains(".Hidden") && !FolderTreeModel.folders(from: items, showsHidden: true).contains { $0.name == "Demo.app" })
        let model = FolderTreeModel(provider: provider)
        model.follow(alpha)
        let count = provider.requestCount
        check("inactive construction and follow do not scan", model.root == nil && !model.isActive && provider.requestCount == count)
        model.follow(root)
        model.setActive(true)
        await until("root listing finishes") { model.root?.children != nil && model.root?.isLoading == false }
        check("opening the root loads only its immediate folders", provider.requestCount == count + 1 && model.loadedNodes.count == 4 && model.root?.children?.allSatisfy { $0.children == nil } == true)
        let alphaNode = model.root!.children!.first { $0.name == "Alpha" }!
        model.load(alphaNode)
        await until("explicit Alpha expansion finishes") { alphaNode.children != nil && !alphaNode.isLoading }
        check("expanding one level does not recursively scan grandchildren", alphaNode.children?.map(\.name) == ["Nested"] && alphaNode.children?.first?.children == nil && provider.count(at: alpha.appendingPathComponent("Nested")) == 0)
        var revealed: [FolderTreeModel.Node]?
        model.follow(alpha.appendingPathComponent("Nested/Deep")) { revealed = $0 }
        await until("deep path reveal finishes") { revealed != nil }
        check("following a deep folder loads just its ancestor chain", revealed?.map(\.name) == [root.lastPathComponent, "Alpha", "Nested", "Deep"] && provider.count(at: root.appendingPathComponent("Beta")) == 0)
        model.showsHiddenFolders = true
        await until("Show Hidden refresh finishes") { model.root?.children?.contains { $0.name == ".Hidden" } == true }
        check("hidden preference survives a model refresh", model.showsHiddenFolders)
        model.setActive(false)
        let stoppedCount = provider.requestCount
        model.refresh()
        model.follow(root.appendingPathComponent("Beta"))
        check("hidden model stops refresh and navigation enumeration", provider.requestCount == stoppedCount && !model.isActive)

        let oldState = WorkspaceWindowState(tabs: [.init(panes: [.init(url: root)])])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldState)) as! [String: Any]
        for key in ["foldersVisible", "foldersFraction", "foldersShowHidden", "foldersLimitToHome"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(WorkspaceWindowState.self, from: JSONSerialization.data(withJSONObject: json))
        check("older workspace files default to a hidden Home-limited tree", !legacy.foldersVisible && legacy.foldersFraction == 0.45 && !legacy.foldersShowHidden && legacy.foldersLimitToHome)
        var bounds = oldState
        bounds.foldersFraction = .infinity
        check("nonfinite tree split fractions normalize safely", bounds.sanitized()?.foldersFraction == 0.45)
        bounds.foldersFraction = 50
        check("tree split fractions stay within visible panel bounds", bounds.sanitized()?.foldersFraction == 0.8)
    }

    @MainActor private static func delayedChecks(_ root: URL) async throws {
        let provider = CountingProvider(home: root)
        let model = FolderTreeModel(provider: provider)
        let firstGate = provider.gateNext(root)
        model.setActive(true)
        await until("gated initial listing starts") { provider.isWaiting }
        let discardedRoot = model.root!
        model.setActive(false)
        firstGate.signal()
        await until("cancelled listing returns") { provider.completedCount == 1 }
        await turn()
        check("late result cannot repopulate an inactive tree", discardedRoot.children == nil && !discardedRoot.isLoading && model.root === discardedRoot && !model.isActive)
        model.setActive(true)
        await until("reactivated listing finishes") { model.root?.children != nil && model.root?.isLoading == false }
        check("reactivation creates fresh root identity", model.root !== discardedRoot)
        let current = model.root!
        let secondGate = provider.gateNext(root)
        model.load(current, refresh: true)
        await until("gated refresh snapshots old children") { provider.isWaiting }
        let addition = root.appendingPathComponent("QueuedRefresh")
        try FileManager.default.createDirectory(at: addition, withIntermediateDirectories: false)
        model.refresh()
        var refreshedReveal: [FolderTreeModel.Node]?
        var refreshedRevealCount = 0
        model.follow(addition) { refreshedReveal = $0; refreshedRevealCount += 1 }
        secondGate.signal()
        await until("queued refresh sees a change made during enumeration") { current.children?.contains { $0.name == "QueuedRefresh" } == true && !current.isLoading }
        check("refresh during loading causes a follow-up enumeration", provider.count(at: root) >= 4)
        check("follow waits for queued refresh before concluding a new child is absent", refreshedRevealCount == 1 && refreshedReveal?.last?.name == "QueuedRefresh")

        let alpha = current.children!.first { $0.name == "Alpha" }!
        let childGate = provider.gateNext(alpha.url)
        model.load(alpha)
        await until("first child listing snapshots before a change") { provider.isWaiting }
        try FileManager.default.createDirectory(at: alpha.url.appendingPathComponent("QueuedChild"), withIntermediateDirectories: false)
        DirectoryChanges.post([alpha.url.appendingPathComponent("QueuedChild")])
        // Wait for the model's debounced invalidation; its first child result
        // remains gated, so the request must be retained rather than ignored.
        try? await Task.sleep(nanoseconds: 300_000_000)
        childGate.signal()
        await until("first child loading retains directory invalidation") { alpha.children?.contains { $0.name == "QueuedChild" } == true && !alpha.isLoading }
        check("invalidation while a nonroot first load is pending triggers another read", provider.count(at: alpha.url) >= 2)

        let beta = current.children!.first { $0.name == "Beta" }!
        let thirdGate = provider.gateNext(beta.url)
        var staleReveal = false
        var latestReveal: [FolderTreeModel.Node]?
        model.follow(beta.url.appendingPathComponent("Child")) { _ in staleReveal = true }
        await until("old reveal is waiting on Beta") { provider.isWaiting }
        model.follow(root.appendingPathComponent("Alpha")) { latestReveal = $0 }
        await until("latest reveal completes independently") { latestReveal != nil }
        thirdGate.signal()
        await until("old Beta result returns") { !beta.isLoading }
        check("a late reveal cannot select the formerly active directory", !staleReveal && latestReveal?.last?.name == "Alpha" && sameLocation(model.location, root.appendingPathComponent("Alpha")))

        let missing = current.children!.first { $0.name == "QueuedRefresh" }!
        try FileManager.default.removeItem(at: addition)
        model.load(missing)
        await until("unavailable folder produces an inline model error") { !missing.isLoading && missing.error != nil }
        check("enumeration failure does not produce a modal or remove unrelated folders", missing.children?.isEmpty == true && model.lastError != nil && current.children?.contains { $0.name == "Alpha" } == true)
        model.setActive(false)
    }

    @MainActor private static func abandonedTreeChecks(_ root: URL) async throws {
        let provider = CountingProvider(home: root)
        let model = FolderTreeModel(provider: provider)
        let gate = provider.gateNext(root)
        model.setActive(true)
        await until("abandoned root fixture is loading") { provider.isWaiting }
        model.follow(root.appendingPathComponent("Alpha/Nested")) { _ in }
        let replacedRoot = WeakNode(model.root)
        model.showsHiddenFolders = true
        await until("replacement root loads independently") { model.root?.children != nil && model.root?.isLoading == false }
        gate.signal()
        await until("root replacement releases pending ancestor callbacks") { replacedRoot.value == nil }
        model.setActive(false)

        let deinitProvider = CountingProvider(home: root)
        var disposable: FolderTreeModel? = FolderTreeModel(provider: deinitProvider)
        let deinitGate = deinitProvider.gateNext(root)
        disposable?.setActive(true)
        await until("deinit root fixture is loading") { deinitProvider.isWaiting }
        disposable?.follow(root.appendingPathComponent("Alpha/Nested")) { _ in }
        let disposedRoot = WeakNode(disposable?.root)
        disposable = nil
        deinitGate.signal()
        await until("model deinit releases pending ancestor callbacks") { disposedRoot.value == nil }

        let removedURL = root.appendingPathComponent("RemovedDuringLoad")
        try FileManager.default.createDirectory(at: removedURL.appendingPathComponent("Child"), withIntermediateDirectories: true)
        let removalProvider = CountingProvider(home: root)
        let removalModel = FolderTreeModel(provider: removalProvider)
        removalModel.setActive(true)
        defer { removalModel.setActive(false) }
        await until("descendant removal fixture root loads") { removalModel.root?.children != nil && removalModel.root?.isLoading == false }
        let removedNode = WeakNode(removalModel.root?.children?.first { $0.name == "RemovedDuringLoad" })
        check("descendant removal fixture has a live folder node", removedNode.value != nil)
        let removalGate = removalProvider.gateNext(removedURL)
        defer { removalGate.signal() }
        var removedRevealCompleted = false
        removalModel.follow(removedURL.appendingPathComponent("Child")) { _ in removedRevealCompleted = true }
        await until("removed descendant has a pending ancestor callback") { removalProvider.isWaiting }
        try FileManager.default.removeItem(at: removedURL)
        removalModel.load(removalModel.root!, refresh: true)
        await until("parent refresh discards the loading descendant") {
            removalModel.root?.children?.contains { $0.name == "RemovedDuringLoad" } == false && removalModel.root?.isLoading == false
        }
        removalGate.signal()
        await until("discarded descendant releases its pending ancestor callback") { removedNode.value == nil }
        check("discarded descendant cannot complete an obsolete reveal", !removedRevealCompleted)
    }

    @MainActor private static func scrollVisibilityChecks(_ root: URL) async throws {
        for number in 0..<50 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(String(format: "Folder %02d", number)), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder 00/Explored child"), withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("ZZZ Workspace/Active Project")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("scroll fixture".utf8).write(to: destination.appendingPathComponent("note.txt"))
        let provider = CountingProvider(home: root)
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let window = MainWindowController(provider: provider, places: PlacesModel(), initialURL: destination, viewPropertiesStore: store)
        defer { window.close() }
        await listed(window.browser, at: destination)
        window.toggleFoldersPanel(nil)
        window.window?.setContentSize(NSSize(width: 800, height: 500))
        window.window?.contentView?.layoutSubtreeIfNeeded()
        let panel = window.sidebar.foldersPanel!
        await selected(destination, in: panel)
        await until("following a deep row waits for final panel layout", detail: { visibilityDetail(panel) }) { selectedRowIsVisible(panel) }
        check("scroll fixture selected row is far below the initial viewport", panel.outlineView.selectedRow > 50 && panel.scrollView.documentVisibleRect.minY > 0)
        window.window?.setContentSize(NSSize(width: 800, height: 360))
        window.window?.contentView?.layoutSubtreeIfNeeded()
        await until("shrinking the sidebar keeps the whole selected row visible", detail: { visibilityDetail(panel) }) { selectedRowIsVisible(panel) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AAA Inserted"), withIntermediateDirectories: false)
        panel.model.refresh()
        await until("refresh adds a row above the selected branch") { panel.model.root?.children?.contains { $0.name == "AAA Inserted" } == true && panel.model.root?.isLoading == false }
        await until("reload and re-expansion keep the selected row above the status bar", detail: { visibilityDetail(panel) }) { selectedRowIsVisible(panel) }
        await turn()
        let clip = panel.scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: .zero, size: clip.bounds.size)).origin)
        panel.scrollView.reflectScrolledClipView(clip)
        let manualOrigin = panel.scrollView.documentVisibleRect.minY
        check("manual exploration can scroll away from the active row", !selectedRowIsVisible(panel))
        let explored = panel.model.root!.children!.first { $0.name == "Folder 00" }!
        panel.outlineView.expandItem(explored)
        await until("manually explored unrelated branch finishes loading") { explored.children != nil && !explored.isLoading }
        await turn()
        check("loading another branch preserves manual scrolling", !selectedRowIsVisible(panel) && abs(panel.scrollView.documentVisibleRect.minY - manualOrigin) < 1, visibilityDetail(panel))
        panel.outlineView.collapseItem(explored)
        await turn()
        check("manual collapse keeps the explored branch closed", !panel.outlineView.isItemExpanded(explored))
        panel.model.refresh()
        await until("background refresh while manually scrolled finishes") { panel.model.loadedNodes.allSatisfy { !$0.isLoading } }
        await turn()
        check("background refresh does not snap back to offscreen active row", !selectedRowIsVisible(panel) && abs(panel.scrollView.documentVisibleRect.minY - manualOrigin) < 1, visibilityDetail(panel))
        check("background refresh preserves the manually collapsed branch", !panel.outlineView.isItemExpanded(explored))
        panel.follow(destination)
        await until("explicit follow still reveals the active row after manual exploration", detail: { visibilityDetail(panel) }) { selectedRowIsVisible(panel) }

        let right = window.tabs.currentPage.split(with: destination)
        await listed(right, at: destination)
        window.showWindow(nil)
        let nativeWindow = window.window!
        for size in [NSSize(width: 1100, height: 740), NSSize(width: 560, height: 360),
                     NSSize(width: 720, height: 460), NSSize(width: 560, height: 360)] {
            nativeWindow.setFrame(NSRect(origin: nativeWindow.frame.origin, size: size), display: true)
            nativeWindow.contentView?.layoutSubtreeIfNeeded()
            await turn()
            await until("tree selection remains visible after split window resize to \(Int(size.width))×\(Int(size.height))", detail: { visibilityDetail(panel) }) { selectedRowIsVisible(panel) }
            check("narrow split window returns to the run loop with contained breadcrumb controls",
                  window.tabs.currentPage.panes.allSatisfy { pane in
                      pane.addressBar.visibleNavigationFrames.allSatisfy {
                          $0.minX >= 0 && $0.maxX <= pane.addressBar.bounds.width + 1
                      }
                  })
        }
    }

    @MainActor private static func selectedRowIsVisible(_ panel: FoldersPanelController) -> Bool {
        let row = panel.outlineView.selectedRow
        guard row >= 0, row < panel.outlineView.numberOfRows else { return false }
        let rowRect = panel.outlineView.rect(ofRow: row)
        let visible = panel.scrollView.documentVisibleRect
        return visible.height >= rowRect.height && rowRect.minY >= visible.minY - 0.5 && rowRect.maxY <= visible.maxY + 0.5
    }
    @MainActor private static func visibilityDetail(_ panel: FoldersPanelController) -> String {
        "row=\(panel.outlineView.selectedRow), rect=\(panel.outlineView.rect(ofRow: panel.outlineView.selectedRow)), visible=\(panel.scrollView.documentVisibleRect), panel=\(panel.view.bounds), scroll=\(panel.scrollView.frame), status=\(panel.statusLabel.frame)"
    }

    @MainActor private static func windowChecks(_ root: URL, mode: ViewMode) async throws {
        let provider = CountingProvider(home: root)
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        var defaults = DirectoryViewProperties()
        defaults.viewMode = mode
        store.setDefault(defaults)
        let window = MainWindowController(provider: provider, places: PlacesModel(), initialURL: root,
                                          viewPropertiesStore: store)
        defer { window.close() }
        await listed(window.browser, at: root)
        check("\(mode): startup constructs no tree", window.sidebar.foldersPanel == nil && !window.isFoldersPanelVisible)
        let page = window.tabs.currentPage
        let left = window.browser
        left.setViewMode(mode)
        left.nameFilter = "note"
        left.setGroupKey(.kind)
        let right = page.split(with: root.appendingPathComponent("Beta"))
        await listed(right, at: root.appendingPathComponent("Beta"))
        right.setViewMode(mode)
        right.nameFilter = "note"
        right.setGroupKey(.dateModified)
        page.activate(left)
        let background = window.tabs.newTab(at: root.appendingPathComponent("Gamma"), activate: false)
        await listed(background, at: root.appendingPathComponent("Gamma"))
        window.toggleFoldersPanel(nil)
        guard let panel = window.sidebar.foldersPanel else { check("\(mode): toggle creates a tree", false); return }
        await until("\(mode): tree root is visible") { panel.model.root?.children != nil && panel.outlineView.numberOfRows >= 4 }
        check("\(mode): Places remains installed above independent tree", window.sidebar.outlineView.superview != nil && panel.view.superview != nil && window.sidebar.foldersVisible && panel.model.isActive)
        check("\(mode): filtering file pane does not filter tree folders", panel.model.root?.children?.map(\.name) == ["Alpha", "Beta", "Gamma"])
        let collapsedChildren = panel.model.root!.children!
        let beforeQueries = provider.requestCount
        for node in collapsedChildren {
            check("\(mode): expansion permission allows a folder", panel.outlineView(panel.outlineView, shouldExpandItem: node))
        }
        // AppKit returns legacy NSOutlineRow objects here, which need not
        // conform to the NSAccessibilityRow protocol declared by Swift's
        // imported array type. Preserve NSArray and query the ObjC AX surface.
        let accessibilityRows = panel.outlineView.perform(NSSelectorFromString("accessibilityRows"))?.takeUnretainedValue() as? NSArray ?? []
        var accessibilityQueries = 0
        for element in accessibilityRows {
            guard let row = element as? NSObject else { continue }
            _ = row.accessibilityAttributeValue(.disclosing)
            _ = row.accessibilityAttributeValue(.disclosedRows)
            _ = row.accessibilityIsAttributeSettable(.disclosing)
            accessibilityQueries += 1
        }
        await turn()
        await turn()
        check("\(mode): accessibility and expansion permission queries do not enumerate or expand siblings", accessibilityQueries > 0 && provider.requestCount == beforeQueries && collapsedChildren.allSatisfy { $0.children == nil && !$0.isLoading && !panel.outlineView.isItemExpanded($0) })
        select(root.appendingPathComponent("Alpha"), in: panel)
        await listed(left, at: root.appendingPathComponent("Alpha"))
        check("\(mode): tree selection navigates only active pane", window.browser === left && sameLocation(right.currentURL, root.appendingPathComponent("Beta")) && right.nameFilter == "note" && right.model.groupKey == .dateModified && sameLocation(background.currentURL, root.appendingPathComponent("Gamma")))
        check("\(mode): active file view remains the chosen implementation", left.viewMode == mode && (left.fileView is IconGridViewController) == (mode == .icons))
        page.activate(right)
        await selected(root.appendingPathComponent("Beta"), in: panel)
        check("\(mode): activating the opposite pane moves tree selection", sameLocation(selectedURL(panel), right.currentURL))
        window.tabs.selectTab(at: 1)
        await selected(root.appendingPathComponent("Gamma"), in: panel)
        check("\(mode): selecting a tab follows its folder", sameLocation(selectedURL(panel), background.currentURL))
        window.tabs.selectTab(at: 0)
        page.activate(left)
        await selected(root.appendingPathComponent("Alpha"), in: panel)

        let alphaRow = row(root.appendingPathComponent("Alpha"), in: panel)
        let capturedMenu = panel.contextMenu(forRow: alphaRow)
        let openTab = capturedMenu.items.first { $0.title == "Open in New Tab" }!
        select(root.appendingPathComponent("Beta"), in: panel)
        await listed(left, at: root.appendingPathComponent("Beta"))
        let previousCount = window.tabs.count
        dispatch(openTab)
        await listed(window.browser, at: root.appendingPathComponent("Alpha"))
        check("\(mode): context New Tab keeps right-click URL after selection changes", window.tabs.count == previousCount + 1 && sameLocation(window.browser.currentURL, root.appendingPathComponent("Alpha")) && sameLocation(left.currentURL, root.appendingPathComponent("Beta")))
        window.tabs.selectTab(at: 0)
        page.activate(left)
        await selected(root.appendingPathComponent("Beta"), in: panel)
        let otherMenu = panel.contextMenu(forRow: row(root.appendingPathComponent("Gamma"), in: panel))
        let openOther = otherMenu.items.first { $0.title == "Open in Other Pane" }!
        select(root.appendingPathComponent("Alpha"), in: panel)
        await listed(left, at: root.appendingPathComponent("Alpha"))
        dispatch(openOther)
        await listed(right, at: root.appendingPathComponent("Gamma"))
        check("\(mode): context Other Pane uses captured URL and keeps source pane", window.browser === right && sameLocation(left.currentURL, root.appendingPathComponent("Alpha")) && sameLocation(right.currentURL, root.appendingPathComponent("Gamma")))

        let options = panel.contextMenu(forRow: -1)
        dispatch(options.items.first { $0.title == "Show Hidden Folders" }!)
        await until("\(mode): hidden folder option refreshes tree") { panel.model.root?.children?.contains { $0.name == ".Hidden" } == true }
        check("\(mode): tree hidden option does not alter file-view filtering", panel.model.showsHiddenFolders && sameLocation(left.currentURL, root.appendingPathComponent("Alpha")))
        // Changing the second option while inactive proves it is persisted
        // without enumerating the real filesystem root in this test.
        window.toggleFoldersPanel(nil)
        dispatch(panel.contextMenu(forRow: -1).items.first { $0.title == "Limit to Home Directory" }!)
        check("\(mode): hidden tree records independent options without scanning", !panel.model.isActive && !panel.model.limitsToHome)
        window.sidebar.foldersFraction = 0.6
        var saved = window.workspaceSessionState
        check("\(mode): workspace captures tree visibility, options and split fraction", !saved.foldersVisible && saved.foldersShowHidden && !saved.foldersLimitToHome && saved.foldersFraction == 0.6)
        saved.foldersLimitToHome = true
        saved.foldersVisible = true
        let persisted = try JSONDecoder().decode(WorkspaceWindowState.self, from: JSONEncoder().encode(saved))
        let restored = MainWindowController(provider: provider, places: PlacesModel(), initialURL: root,
                                            viewPropertiesStore: store)
        defer { restored.close() }
        restored.restoreWorkspaceSession(persisted)
        await listed(restored.browser, at: right.currentURL!)
        await until("\(mode): restored tree follows restored active pane") { restored.sidebar.foldersPanel.map { sameLocation(selectedURL($0), right.currentURL) } == true }
        check("\(mode): restore creates fresh tree with persisted options", restored.isFoldersPanelVisible && restored.sidebar.foldersPanel !== panel && restored.sidebar.foldersPanel?.model.showsHiddenFolders == true && restored.sidebar.foldersPanel?.model.limitsToHome == true)
        check("\(mode): restored folder divider fraction is retained", abs(restored.workspaceSessionState.foldersFraction - 0.6) < 0.04, "actual=\(restored.workspaceSessionState.foldersFraction)")
        restored.toggleSidebar(nil)
        check("\(mode): collapsing sidebar suspends tree while preserving visibility preference", restored.isSidebarCollapsed && restored.sidebar.foldersVisible && restored.sidebar.foldersPanel?.model.isActive == false)
        restored.toggleFoldersPanel(nil)
        check("\(mode): Show Folders reopens collapsed sidebar", !restored.isSidebarCollapsed && restored.isFoldersPanelVisible && restored.sidebar.foldersPanel?.model.isActive == true)

        // A standalone controller can exercise external deletion while the
        // selected target stays independent from any browser's watcher.
        let deletionPanel = FoldersPanelController(provider: provider)
        _ = deletionPanel.view
        var opened: [URL] = []
        deletionPanel.onOpen = { opened.append($0) }
        deletionPanel.follow(root)
        deletionPanel.setActive(true)
        await until("\(mode): deletion fixture root loaded") { deletionPanel.outlineView.numberOfRows >= 4 }
        select(root.appendingPathComponent("Gamma"), in: deletionPanel)
        check("\(mode): manual tree selection dispatches its exact URL", sameLocation(opened.last, root.appendingPathComponent("Gamma")))
        let countBeforeRemoval = opened.count
        try FileManager.default.removeItem(at: root.appendingPathComponent("Gamma"))
        deletionPanel.model.refresh()
        await until("\(mode): external deletion removes selected node") { deletionPanel.model.root?.children?.contains { $0.name == "Gamma" } == false && deletionPanel.model.root?.isLoading == false }
        check("\(mode): deleting selected folder clears numeric row selection without navigation", deletionPanel.outlineView.selectedRow == -1 && opened.count == countBeforeRemoval)
        deletionPanel.setActive(false)
        restored.sidebar.foldersPanel?.onClose?()
        check("\(mode): close control hides tree and retains Places", !restored.sidebar.foldersVisible && restored.sidebar.outlineView.superview != nil)
    }

    @MainActor private static func systemAliasChecks(_ root: URL) async throws {
        let tmpRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tursora-tree-system-alias-" + UUID().uuidString)
        let tmpTarget = tmpRoot.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: tmpTarget, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let varTarget = root.appendingPathComponent("Alpha/Nested")
        let provider = AncestorsOnlyProvider(home: root.appendingPathComponent("Home"), targets: [varTarget, tmpTarget])
        let panel = FoldersPanelController(provider: provider)
        _ = panel.view
        let varAlias = URL(fileURLWithPath: physicalPath(varTarget)!.replacingOccurrences(of: "/private/var/", with: "/var/"))
        panel.follow(varAlias)
        panel.setActive(true)
        await until("filesystem-root tree reveals /var through physical ancestors", detail: {
            "selected=\(selectedURL(panel)?.path ?? "nil"), root=\(panel.model.root?.url.path ?? "nil"), nodes=\(panel.model.loadedNodes.map { $0.url.path })"
        }) { sameLocation(selectedURL(panel), varTarget) }
        check("system alias reveal retains Show Hidden preference and required /private ancestor", !panel.model.showsHiddenFolders && panel.model.loadedNodes.contains { $0.url.path == "/private" })
        let tmpAlias = URL(fileURLWithPath: physicalPath(tmpTarget)!.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        panel.follow(tmpAlias)
        await until("filesystem-root tree also reveals /tmp alias") { sameLocation(selectedURL(panel), tmpTarget) }
        check("alias fixtures never enumerate actual system directories", provider.requested.allSatisfy { provider.allowed[$0] != nil })
        panel.setActive(false)
    }

    @MainActor private static func row(_ url: URL, in panel: FoldersPanelController) -> Int {
        guard let node = panel.model.loadedNodes.first(where: { sameLocation($0.url, url) }) else { check("tree has target \(url.lastPathComponent)", false); return -1 }
        let row = panel.outlineView.row(forItem: node)
        check("target \(url.lastPathComponent) is a visible tree row", row >= 0)
        return row
    }
    @MainActor private static func select(_ url: URL, in panel: FoldersPanelController) {
        panel.outlineView.selectRowIndexes(IndexSet(integer: row(url, in: panel)), byExtendingSelection: false)
    }
    @MainActor private static func selectedURL(_ panel: FoldersPanelController) -> URL? {
        (panel.outlineView.item(atRow: panel.outlineView.selectedRow) as? FolderTreeModel.Node)?.url
    }
    @MainActor private static func selected(_ url: URL, in panel: FoldersPanelController) async {
        await until("tree follows \(url.lastPathComponent)", detail: { "expected=\(url.path), selected=\(selectedURL(panel)?.path ?? "nil"), root=\(panel.model.root?.url.path ?? "nil")" }) { sameLocation(selectedURL(panel), url) }
    }
    @MainActor private static func listed(_ browser: BrowserViewController, at url: URL) async {
        await until("browser lists \(url.lastPathComponent)", detail: {
            "expected=\(url.path), current=\(browser.currentURL?.path ?? "nil"), model=\(browser.model.url?.path ?? "nil"), generation=\(browser.model.generation), items=\(browser.model.allNodes.prefix(12).map { $0.url.path })"
        }) {
            sameLocation(browser.currentURL, url) && browser.model.generation > 0
                && browser.model.allNodes.contains { sameLocation($0.url, url.appendingPathComponent("note.txt")) }
        }
    }
    @MainActor private static func dispatch(_ item: NSMenuItem) {
        check("dispatch \(item.title)", item.action.map { NSApp.sendAction($0, to: item.target, from: item) } == true)
    }
    @MainActor private static func until(_ name: String, detail: () -> String = { "" }, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        let passed = condition()
        check(name, passed, passed ? "" : detail())
    }
    @MainActor private static func turn() async { try? await Task.sleep(nanoseconds: 30_000_000) }
    private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        print("\(condition ? "ok  " : "FAIL") folder tree: \(name) \(detail)")
        if !condition { exit(1) }
    }

    private static func sameLocation(_ first: URL?, _ second: URL?) -> Bool {
        guard let first = physicalPath(first), let second = physicalPath(second) else { return false }
        return first == second
    }
    private static func physicalPath(_ url: URL?) -> String? {
        guard let url else { return nil }
        if let bytes = realpath(url.path, nil) {
            defer { free(bytes) }
            return String(cString: bytes)
        }
        // A deleted fixture item still compares by its physical parent.
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, let prefix = physicalPath(parent) else { return url.path }
        return (prefix == "/" ? "" : prefix) + "/" + url.lastPathComponent
    }

    private final class WeakNode {
        weak var value: FolderTreeModel.Node?
        init(_ value: FolderTreeModel.Node?) { self.value = value }
    }

    private final class CountingProvider: FileProvider {
        let homeURL: URL
        private let base = LocalFileProvider()
        private let lock = NSLock()
        private var requests: [String] = []
        private var finished = 0
        private var gate: (path: String, semaphore: DispatchSemaphore)?
        private var waiting = false
        init(home: URL) { homeURL = home }
        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
        var completedCount: Int { lock.lock(); defer { lock.unlock() }; return finished }
        var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
        func count(at url: URL) -> Int { let path = physicalPath(url)!; lock.lock(); defer { lock.unlock() }; return requests.filter { $0 == path }.count }
        func gateNext(_ url: URL) -> DispatchSemaphore {
            let semaphore = DispatchSemaphore(value: 0)
            let path = physicalPath(url)!
            lock.lock(); gate = (path, semaphore); waiting = false; lock.unlock()
            return semaphore
        }
        func listDirectory(_ url: URL) throws -> [FileItem] {
            let path = physicalPath(url)!
            lock.lock()
            requests.append(path)
            let block = gate?.path == path ? gate?.semaphore : nil
            if block != nil { gate = nil }
            lock.unlock()
            // Snapshot before announcing the gate, reproducing a stale result.
            let result = Result { try base.listDirectory(url) }
            if let block {
                lock.lock(); waiting = true; lock.unlock()
                if block.wait(timeout: .now() + 20) == .timedOut { throw CocoaError(.userCancelled) }
            }
            lock.lock(); finished += 1; if block != nil { waiting = false }; lock.unlock()
            return try result.get()
        }
        func displayName(for url: URL) -> String { url.lastPathComponent }
    }

    /// Supplies only the known physical ancestors of two owned targets. Root
    /// and /private metadata are real; directory contents are never enumerated.
    private final class AncestorsOnlyProvider: FileProvider {
        let homeURL: URL
        let allowed: [String: [FileItem]]
        private let lock = NSLock()
        private var storedRequests: [String] = []
        var requested: [String] { lock.lock(); defer { lock.unlock() }; return storedRequests }
        init(home: URL, targets: [URL]) {
            homeURL = home
            var graph: [String: [String: FileItem]] = [:]
            for target in targets {
                let components = URL(fileURLWithPath: physicalPath(target)!).pathComponents
                for count in 1..<components.count {
                    let parent = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(count))))
                    let child = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(count + 1))))
                    if let item = FileItem(url: child) { graph[physicalPath(parent)!, default: [:]][physicalPath(child)!] = item }
                }
                graph[physicalPath(target)!, default: [:]] = [:]
            }
            allowed = graph.mapValues { Array($0.values) }
        }
        func listDirectory(_ url: URL) throws -> [FileItem] {
            let path = physicalPath(url)!
            lock.lock(); storedRequests.append(path); lock.unlock()
            return allowed[path] ?? []
        }
        func displayName(for url: URL) -> String { url.lastPathComponent }
    }
}

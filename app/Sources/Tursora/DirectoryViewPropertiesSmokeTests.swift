import AppKit

/// Isolated storage and actual pane navigation checks for remembered folder views.
enum DirectoryViewPropertiesSmokeTests: SmokeSuite {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            let fixture = fm.temporaryDirectory.appendingPathComponent("tursora-directory-views-" + UUID().uuidString)
                .resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: fixture) }
            do {
                try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
                try await modelChecks(in: fixture)
                try await paneChecks(in: fixture)
                try await narrowSplitPolicyLayout(in: fixture)
                try await navigationRace(in: fixture)
                try await retargetedSymlink(in: fixture)
                try await archiveChecks(in: fixture)
                completion()
            } catch {
                check("directory view properties fixture completes", false, error.localizedDescription)
            }
        }
    }

    private static var firstProperties: DirectoryViewProperties {
        var p = DirectoryViewProperties()
        p.viewMode = .icons
        p.detailsZoomIndex = 3
        p.iconsZoomIndex = 5
        p.sortKey = .size
        p.ascending = false
        p.groupKey = .kind
        p.lastGroupKey = .kind
        p.showHidden = true
        p.showPreviews = false
        return p
    }

    private static var secondProperties: DirectoryViewProperties {
        var p = DirectoryViewProperties()
        p.detailsZoomIndex = 1
        p.iconsZoomIndex = 4
        p.sortKey = .dateModified
        p.groupKey = .dateModified
        p.lastGroupKey = .dateModified
        return p
    }

    @MainActor
    private static func modelChecks(in fixture: URL) async throws {
        print("== directory view property storage ==")
        let fm = FileManager.default
        let file = fixture.appendingPathComponent("model/view-properties.json")
        let a = fixture.appendingPathComponent("model-a", isDirectory: true)
        let b = fixture.appendingPathComponent("model-b", isDirectory: true)
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        let aKey = DirectoryViewPropertiesStore.directoryKey(for: a)!
        let bKey = DirectoryViewPropertiesStore.directoryKey(for: b)!
        let defaults = DirectoryViewProperties()
        let store = DirectoryViewPropertiesStore(fileURL: file, initialDefaults: defaults)
        check("unrecorded folders and virtual locations use the explicit defaults",
              store.properties(forKey: aKey) == defaults && store.properties(forKey: nil) == defaults
              && !store.hasOverride(forKey: aKey) && store.policy == .perDirectory)
        store.save(firstProperties, forKey: aKey)
        store.save(secondProperties, forKey: bKey)
        check("different folders retain independent properties without replacing defaults",
              store.properties(forKey: aKey) == firstProperties && store.properties(forKey: bKey) == secondProperties
              && store.defaultProperties == defaults)
        try store.flush()
        let restarted = DirectoryViewPropertiesStore(fileURL: file, initialDefaults: secondProperties)
        check("reconstructed store restores every field and persisted defaults",
              restarted.properties(forKey: aKey) == firstProperties && restarted.properties(forKey: bKey) == secondProperties
              && restarted.defaultProperties == defaults && restarted.policy == .perDirectory)
        restarted.setDefault(secondProperties)
        check("new defaults apply to unrecorded folders and preserve existing overrides",
              restarted.properties(forKey: "unrecorded") == secondProperties
              && restarted.properties(forKey: aKey) == firstProperties)
        restarted.reset(key: aKey)
        check("reset removes only the requested folder override",
              !restarted.hasOverride(forKey: aKey) && restarted.properties(forKey: aKey) == secondProperties
              && restarted.hasOverride(forKey: bKey))
        restarted.save(firstProperties, forKey: aKey)
        restarted.setPolicy(.unified)
        check("unified policy reads defaults while retaining remembered folder records",
              restarted.properties(forKey: aKey) == secondProperties && restarted.hasOverride(forKey: aKey))
        restarted.save(firstProperties, forKey: bKey)
        check("unified changes update the shared default", restarted.defaultProperties == firstProperties)
        restarted.setPolicy(.perDirectory)
        check("returning to per-directory policy revives retained overrides",
              restarted.properties(forKey: aKey) == firstProperties && restarted.properties(forKey: bKey) == secondProperties)
        for index in 0..<30 {
            var properties = firstProperties
            properties.iconsZoomIndex = index % ZoomLevel.iconSizes.count
            restarted.save(properties, forKey: aKey)
        }
        try restarted.flush()
        let coalesced = DirectoryViewPropertiesStore(fileURL: file)
        check("flush persists the last change after a burst of saves",
              coalesced.properties(forKey: aKey).iconsZoomIndex == 29 % ZoomLevel.iconSizes.count
              && coalesced.policy == .perDirectory && coalesced.defaultProperties == firstProperties)

        let link = fixture.appendingPathComponent("model-alias")
        try fm.createSymbolicLink(at: link, withDestinationURL: a)
        let dotted = a.appendingPathComponent("../model-a/./", isDirectory: true)
        check("directory keys normalize path components and resolve symlinks",
              DirectoryViewPropertiesStore.directoryKey(for: dotted) == aKey
              && DirectoryViewPropertiesStore.directoryKey(for: link) == aKey)
        var decorated = URLComponents(url: a, resolvingAgainstBaseURL: false)!
        decorated.query = "display=icons"
        decorated.fragment = "selection"
        check("directory identity excludes URL query and fragment",
              DirectoryViewPropertiesStore.directoryKey(for: decorated.url!) == aKey)
        check("virtual archive and non-file URLs cannot produce persistent folder keys",
              DirectoryViewPropertiesStore.directoryKey(for: a, isVirtual: true) == nil
              && DirectoryViewPropertiesStore.directoryKey(for: URL(string: "tursora-search:///query")!) == nil
              && DirectoryViewPropertiesStore.directoryKey(for: URL(string: "file://remote.example/share")!) == nil)
        let moved = fixture.appendingPathComponent("model-renamed", isDirectory: true)
        try fm.moveItem(at: a, to: moved)
        check("path identity deliberately treats a renamed directory as a new location",
              DirectoryViewPropertiesStore.directoryKey(for: moved) != aKey)

        let invalidDocuments: [Data] = [Data("not JSON".utf8), Data("{\"version\":0}".utf8),
                                        Data("{\"version\":999}".utf8), Data("{}".utf8)]
        for (index, data) in invalidDocuments.enumerated() {
            let damagedFile = fixture.appendingPathComponent("damaged-\(index).json")
            try data.write(to: damagedFile)
            let damaged = DirectoryViewPropertiesStore(fileURL: damagedFile, initialDefaults: secondProperties)
            check("invalid or unsupported store \(index) falls back safely",
                  damaged.defaultProperties == secondProperties && damaged.policy == .perDirectory
                  && !damaged.hasOverride(forKey: aKey))
            try damaged.flush()
            check("fallback \(index) preserves the original document until an explicit edit",
                  try Data(contentsOf: damagedFile) == data)
        }
        let repairedFile = fixture.appendingPathComponent("repairable.json")
        let repairable: [String: Any] = ["version": 1, "policy": "perDirectory",
            "defaultProperties": ["viewMode": "icons", "detailsZoomIndex": -20, "iconsZoomIndex": 100,
                                  "sortKey": "unknown", "ascending": "invalid", "showHidden": true],
            "directories": [aKey: ["viewMode": "icons", "showPreviews": false], bKey: "invalid"]]
        try JSONSerialization.data(withJSONObject: repairable).write(to: repairedFile)
        let repaired = DirectoryViewPropertiesStore(fileURL: repairedFile)
        check("valid fields survive damaged or missing property fields",
              repaired.defaultProperties.viewMode == .icons && repaired.defaultProperties.showHidden
              && repaired.defaultProperties.sortKey == .name && repaired.defaultProperties.ascending)
        check("decoded zoom values clamp to each view's supported ladder",
              repaired.defaultProperties.detailsZoomIndex == 0
              && repaired.defaultProperties.iconsZoomIndex == ZoomLevel.iconSizes.count - 1)
        check("malformed directory records do not discard valid sibling records",
              repaired.hasOverride(forKey: aKey) && !repaired.hasOverride(forKey: bKey)
              && repaired.properties(forKey: aKey).viewMode == .icons
              && !repaired.properties(forKey: aKey).showPreviews)

        let blockedParent = fixture.appendingPathComponent("blocked-parent")
        try Data("file blocks directory creation".utf8).write(to: blockedParent)
        let blocked = DirectoryViewPropertiesStore(fileURL: blockedParent.appendingPathComponent("views.json"))
        let settings = SettingsWindowController(viewPropertiesStore: blocked)
        defer { settings.close() }
        check("Settings initially hides the view-property Retry action", settings.retryFolderViewSave.isHidden)
        blocked.save(firstProperties, forKey: aKey)
        var rejected = false
        do { try blocked.flush() } catch { rejected = true }
        check("storage failures are reported without losing the in-memory view",
              rejected && blocked.lastWriteError != nil && blocked.properties(forKey: aKey) == firstProperties)
        await expectEventually("a save failure reaches the already-open Settings window") {
            !settings.retryFolderViewSave.isHidden
        }
        check("save failures appear inline without presenting a modal window",
              settings.folderViewSaveMessage.stringValue.contains("could not be saved")
              && settings.window?.attachedSheet == nil && NSApp.modalWindow == nil)
        try fm.removeItem(at: blockedParent)
        settings.retryFolderViewSave.performClick(nil)
        check("a later flush recovers after the storage obstruction is removed",
              blocked.lastWriteError == nil
              && DirectoryViewPropertiesStore(fileURL: blockedParent.appendingPathComponent("views.json"))
                .properties(forKey: aKey) == firstProperties)
        check("Settings Retry clears the inline failure and hides itself after saving",
              settings.retryFolderViewSave.isHidden && !settings.folderViewSaveMessage.stringValue.contains("could not be saved"))
    }

    @MainActor
    private static func apply(_ properties: DirectoryViewProperties, to pane: BrowserViewController) {
        pane.setViewMode(.details)
        pane.setZoomIndex(properties.detailsZoomIndex)
        pane.setViewMode(.icons)
        pane.setZoomIndex(properties.iconsZoomIndex)
        pane.setViewMode(properties.viewMode)
        pane.fileList.setSort(key: properties.sortKey, ascending: properties.ascending)
        pane.setGroupKey(properties.groupKey)
        pane.showsHiddenFiles = properties.showHidden
        pane.setShowsPreviews(properties.showPreviews)
    }

    @MainActor
    private static func paneChecks(in fixture: URL) async throws {
        print("== remembered folder views in tabs and panes ==")
        let fm = FileManager.default
        let a = fixture.appendingPathComponent("Folder A", isDirectory: true)
        let b = fixture.appendingPathComponent("Folder B", isDirectory: true)
        for folder in [a, b] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("one".utf8).write(to: folder.appendingPathComponent("alpha.txt"))
            try Data("longer content".utf8).write(to: folder.appendingPathComponent("bravo.txt"))
            try Data("hidden".utf8).write(to: folder.appendingPathComponent(".secret.txt"))
        }
        let defaults = DirectoryViewProperties()
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("pane-views.json"), initialDefaults: defaults)
        let controller = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: a,
                                              viewPropertiesStore: store)
        defer { controller.close() }
        let pane = controller.browser
        let settings = SettingsWindowController(viewPropertiesStore: store)
        defer { settings.close() }
        await listed(pane, at: a)
        check("Settings exposes both folder-view policies and reflects the stored selection",
              settings.folderViewPolicy.numberOfItems == 2 && settings.folderViewPolicy.indexOfSelectedItem == 0)
        check("new pane begins with defaults and a directory key",
              pane.currentViewProperties == defaults && pane.viewPropertiesKey == DirectoryViewPropertiesStore.directoryKey(for: a))
        apply(firstProperties, to: pane)
        check("real view controls save all folder properties", pane.currentViewProperties == firstProperties
              && store.properties(forKey: pane.viewPropertiesKey) == firstProperties)
        check("hidden files and grouping affect the actual icon listing",
              pane.model.items.contains { $0.name == ".secret.txt" } && pane.model.isGrouped
              && pane.fileView === pane.iconGrid)
        checkChrome(controller, expected: firstProperties, name: "configured A")
        let oldGeneration = pane.model.generation
        pane.navigate(to: b)
        await listed(pane, at: b, after: oldGeneration)
        check("visiting an unrecorded folder restores defaults instead of the prior folder's view",
              pane.currentViewProperties == defaults && !pane.model.items.contains { $0.name == ".secret.txt" })
        apply(secondProperties, to: pane)
        checkChrome(controller, expected: secondProperties, name: "configured B")
        let bGeneration = pane.model.generation
        pane.goBack()
        await listed(pane, at: a, after: bGeneration)
        check("back navigation restores A's complete independent configuration", pane.currentViewProperties == firstProperties)
        checkChrome(controller, expected: firstProperties, name: "restored A")
        let aGeneration = pane.model.generation
        pane.goForward()
        await listed(pane, at: b, after: aGeneration)
        check("forward navigation restores B's complete independent configuration", pane.currentViewProperties == secondProperties)
        checkChrome(controller, expected: secondProperties, name: "restored B")
        pane.nameFilter = "alpha"
        pane.fileView.select(name: "alpha.txt")
        pane.fileView.scrollOffset = 25
        let newTab = controller.tabs.newTab(at: b)
        await listed(newTab, at: b)
        check("a new tab restores directory properties without filter, selection or history",
              newTab.currentViewProperties == secondProperties && newTab.nameFilter.isEmpty
              && newTab.fileView.selectedItems.isEmpty && newTab.history.entries.count == 1
              && newTab.fileView.scrollOffset == 0)
        controller.tabs.toggleSplit()
        let peer = controller.browser
        await listed(peer, at: b)
        check("a new split pane restores the same folder properties", peer !== newTab
              && peer.currentViewProperties == secondProperties && peer.nameFilter.isEmpty)
        apply(firstProperties, to: peer)
        check("ordinary folder edits leave already-open peers and temporary filters independent",
              peer.currentViewProperties == firstProperties && newTab.currentViewProperties == secondProperties
              && pane.currentViewProperties == secondProperties && pane.nameFilter == "alpha")
        controller.tabs.focusOtherPane()
        checkChrome(controller, expected: secondProperties, name: "inactive peer activated")
        let peerGeneration = newTab.model.generation
        newTab.navigate(to: a)
        await listed(newTab, at: a, after: peerGeneration)
        let returnGeneration = newTab.model.generation
        newTab.navigate(to: b)
        await listed(newTab, at: b, after: returnGeneration)
        check("re-entering a folder picks up the most recent peer's saved properties",
              newTab.currentViewProperties == firstProperties)
        checkChrome(controller, expected: firstProperties, name: "peer re-entered B")
        dispatchMenu(#selector(MainWindowController.useCurrentViewAsDefault(_:)), to: controller)
        check("Use Current View as Default changes defaults without navigating",
              store.defaultProperties == firstProperties && newTab.currentURL == b && newTab.history.currentURL == b)
        dispatchMenu(#selector(MainWindowController.restoreFolderViewDefaults(_:)), to: controller)
        check("Reset This Folder removes its override and refreshes open peers",
              !store.hasOverride(forKey: newTab.viewPropertiesKey!)
              && newTab.currentViewProperties == firstProperties && peer.currentViewProperties == firstProperties)
        apply(secondProperties, to: newTab)
        settings.folderViewPolicy.selectItem(at: 1)
        check("Settings policy popup dispatches its real action",
              settings.folderViewPolicy.sendAction(settings.folderViewPolicy.action, to: settings.folderViewPolicy.target))
        check("unified policy immediately applies the default to all open panes",
              [pane, newTab, peer].allSatisfy { $0.currentViewProperties == firstProperties })
        check("View menu marks unified policy and disables folder reset under it",
              menuState(#selector(MainWindowController.useUnifiedFolderView(_:)), controller: controller) == .on
              && menuState(#selector(MainWindowController.rememberFolderViews(_:)), controller: controller) == .off
              && !controller.validateMenuItem(requiredMenuItem(#selector(MainWindowController.restoreFolderViewDefaults(_:)))))
        apply(secondProperties, to: newTab)
        check("unified view edits synchronize the other panes without changing their locations",
              [pane, newTab, peer].allSatisfy { $0.currentViewProperties == secondProperties && $0.currentURL == b }
              && pane.nameFilter == "alpha" && store.defaultProperties == secondProperties)
        checkChrome(controller, expected: secondProperties, name: "unified changed")
        dispatchMenu(#selector(MainWindowController.rememberFolderViews(_:)), to: controller)
        check("switching back to remembered folders restores their retained records",
              store.policy == .perDirectory && newTab.currentViewProperties == secondProperties)
        check("Settings follows a policy change made from the View menu",
              settings.folderViewPolicy.indexOfSelectedItem == 0
              && menuState(#selector(MainWindowController.rememberFolderViews(_:)), controller: controller) == .on)
        try store.flush()
        let restarted = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("pane-views.json"))
        let restartedPane = BrowserViewController(provider: LocalFileProvider(), initialURL: a, viewPropertiesStore: restarted)
        _ = restartedPane.view
        await listed(restartedPane, at: a)
        check("a pane using a reconstructed store restores A after simulated restart",
              restartedPane.currentViewProperties == firstProperties && restartedPane.fileView === restartedPane.iconGrid)
        restartedPane.setViewMode(.details)
        check("restored list zoom stays independent of the remembered icon zoom",
              restartedPane.zoomIndex == firstProperties.detailsZoomIndex
              && restartedPane.statusBar.zoomSlider.integerValue == firstProperties.detailsZoomIndex)
        restartedPane.setViewMode(.icons)
        check("returning to icons restores their own remembered zoom", restartedPane.zoomIndex == firstProperties.iconsZoomIndex)
        try restarted.flush()
        try store.flush()
    }

    @MainActor
    private static func narrowSplitPolicyLayout(in fixture: URL) async throws {
        print("== folder view policy in a narrow split layout ==")
        let fm = FileManager.default
        let artwork = fixture.appendingPathComponent("Narrow Artwork", isDirectory: true)
        let documents = fixture.appendingPathComponent("Narrow Documents", isDirectory: true)
        for folder in [artwork, documents] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("small".utf8).write(to: folder.appendingPathComponent("alpha.txt"))
            try Data("larger document".utf8).write(to: folder.appendingPathComponent("bravo.txt"))
        }
        var listProperties = DirectoryViewProperties()
        listProperties.detailsZoomIndex = 1
        listProperties.sortKey = .size
        listProperties.showHidden = true
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("narrow-split-views.json"))
        store.save(firstProperties, forKey: DirectoryViewPropertiesStore.directoryKey(for: artwork)!)
        store.save(listProperties, forKey: DirectoryViewPropertiesStore.directoryKey(for: documents)!)
        let controller = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: artwork,
                                              viewPropertiesStore: store)
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 1270, height: 610))
        let left = controller.browser
        await listed(left, at: artwork)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        check("narrow-layout source initially mounts grouped icons", left.viewMode == .icons && left.groupKey == .kind)
        controller.tabs.openInOtherPane(documents)
        let right = controller.browser
        await listed(right, at: documents)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        check("layout fixture has an inactive icon pane and an active narrow list pane",
              right !== left && right.currentViewProperties == listProperties
              && left.view.bounds.width > 160 && left.view.bounds.width < 600,
              "left=\(left.view.bounds), right=\(right.view.bounds)")
        dispatchMenu(#selector(MainWindowController.useCurrentViewAsDefault(_:)), to: controller)
        let settings = SettingsWindowController(viewPropertiesStore: store)
        defer { settings.close() }
        settings.folderViewPolicy.selectItem(at: 1)
        check("narrow-layout unified policy uses the real Settings action",
              settings.folderViewPolicy.sendAction(settings.folderViewPolicy.action, to: settings.folderViewPolicy.target))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 20_000_000)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let table = left.fileList.tableView
        let scrollView = left.fileList.scrollView
        let visible = scrollView.documentVisibleRect
        let nameColumn = table.rect(ofColumn: 0)
        check("unified policy changes the previously inactive grouped icon pane to the default list",
              left.currentViewProperties == listProperties && left.fileView === left.fileList)
        check("first list mount in a narrow pane keeps the Name column visible without horizontal scrolling",
              abs(scrollView.contentView.bounds.minX) < 0.5 && visible.width > 0
              && nameColumn.intersection(visible).width >= 160,
              "clip=\(scrollView.contentView.bounds), visible=\(visible), name=\(nameColumn), table=\(table.frame)")
        let clip = scrollView.contentView
        var manuallyScrolled = clip.bounds
        manuallyScrolled.origin.x = 70
        clip.scroll(to: clip.constrainBoundsRect(manuallyScrolled).origin)
        scrollView.reflectScrolledClipView(clip)
        let savedHorizontalOffset = clip.bounds.minX
        check("narrow-layout fixture permits an explicit user horizontal scroll", savedHorizontalOffset > 0)
        left.restoreViewProperties()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        check("restoring properties in the same list mode preserves the user's horizontal position",
              abs(clip.bounds.minX - savedHorizontalOffset) < 0.5,
              "before=\(savedHorizontalOffset), after=\(clip.bounds.minX)")
        try store.flush()
    }

    @MainActor
    private static func checkChrome(_ controller: MainWindowController, expected: DirectoryViewProperties, name: String) {
        let pane = controller.browser
        let zoom = expected.viewMode == .icons ? expected.iconsZoomIndex : expected.detailsZoomIndex
        check("\(name): toolbar mode and zoom slider match the active pane",
              controller.selectedToolbarViewModeForTesting == expected.viewMode && pane.zoomIndex == zoom
              && pane.statusBar.zoomSlider.integerValue == zoom
              && pane.statusBar.zoomSlider.numberOfTickMarks == ZoomLevel.sizes(for: expected.viewMode).count)
        let descriptors = pane.fileList.tableView.sortDescriptors
        check("\(name): list sort direction matches the restored model",
              descriptors.first?.ascending == expected.ascending && pane.model.sortKey == expected.sortKey)
        let icons = requiredMenuItem(#selector(BrowserViewController.viewAsIcons(_:)))
        let previews = requiredMenuItem(#selector(BrowserViewController.togglePreviews(_:)))
        _ = pane.validateMenuItem(icons)
        _ = pane.validateMenuItem(previews)
        check("\(name): View menu checks match restored mode, hidden files and previews",
              icons.state == (expected.viewMode == .icons ? .on : .off)
              && previews.state == (expected.showPreviews ? .on : .off)
              && menuState(#selector(MainWindowController.toggleHiddenFiles(_:)), controller: controller)
                == (expected.showHidden ? .on : .off)
              && menuState(#selector(MainWindowController.toggleSortOrder(_:)), controller: controller)
                == (expected.ascending ? .on : .off))
    }

    @MainActor
    private static func navigationRace(in fixture: URL) async throws {
        print("== remembered view asynchronous navigation ==")
        let slow = fixture.appendingPathComponent("Slow A", isDirectory: true)
        let fast = fixture.appendingPathComponent("Fast B", isDirectory: true)
        try FileManager.default.createDirectory(at: slow, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fast, withIntermediateDirectories: true)
        try Data("B".utf8).write(to: fast.appendingPathComponent("only-B.txt"))
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("race.json"))
        store.save(firstProperties, forKey: DirectoryViewPropertiesStore.directoryKey(for: slow)!)
        store.save(secondProperties, forKey: DirectoryViewPropertiesStore.directoryKey(for: fast)!)
        let provider = GatedProvider(homeURL: slow)
        let pane = BrowserViewController(provider: provider, initialURL: slow, viewPropertiesStore: store)
        _ = pane.view
        await expectEventually("slow navigation starts") { provider.didStart }
        pane.navigate(to: fast)
        await listed(pane, at: fast)
        check("fast navigation restores B while A's listing is still pending", pane.currentViewProperties == secondProperties)
        provider.release()
        await expectEventually("stale listing returns") { provider.didReturn }
        try await Task.sleep(nanoseconds: 50_000_000)
        check("late A listing cannot apply properties or contents to B",
              pane.currentURL == fast && pane.currentViewProperties == secondProperties
              && pane.model.items.map(\.name) == ["only-B.txt"]
              && pane.viewPropertiesKey == DirectoryViewPropertiesStore.directoryKey(for: fast))
        pane.setZoomIndex(2)
        check("edits after a navigation race target B's record only",
              store.properties(forKey: DirectoryViewPropertiesStore.directoryKey(for: slow)) == firstProperties
              && store.properties(forKey: DirectoryViewPropertiesStore.directoryKey(for: fast)).detailsZoomIndex == 2)
        try store.flush()
    }

    @MainActor
    private static func retargetedSymlink(in fixture: URL) async throws {
        print("== remembered view identity during symlink retargeting ==")
        let fm = FileManager.default
        let a = fixture.appendingPathComponent("Symlink A", isDirectory: true)
        let b = fixture.appendingPathComponent("Symlink B", isDirectory: true)
        let link = fixture.appendingPathComponent("Changing Alias", isDirectory: true)
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("A".utf8).write(to: a.appendingPathComponent("only-A.txt"))
        try Data("B".utf8).write(to: b.appendingPathComponent("only-B.txt"))
        try Data("A selection".utf8).write(to: a.appendingPathComponent("same-name.txt"))
        try Data("B selection".utf8).write(to: b.appendingPathComponent("same-name.txt"))
        try fm.createSymbolicLink(at: link, withDestinationURL: a)
        let aKey = DirectoryViewPropertiesStore.directoryKey(for: a)!
        let bKey = DirectoryViewPropertiesStore.directoryKey(for: b)!
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("retarget.json"))
        store.save(firstProperties, forKey: aKey)
        store.save(secondProperties, forKey: bKey)
        let pane = BrowserViewController(provider: LocalFileProvider(), initialURL: link, viewPropertiesStore: store)
        _ = pane.view
        await listed(pane, at: link)
        check("a symlink starts with its resolved directory's properties and contents",
              pane.viewPropertiesKey == aKey && pane.currentViewProperties == firstProperties
              && Set(pane.model.items.map(\.name)) == Set(["only-A.txt", "same-name.txt"]),
              "key=\(pane.viewPropertiesKey ?? "nil"), expected=\(aKey), properties=\(pane.currentViewProperties), items=\(pane.model.items.map(\.name))")
        pane.nameFilter = "same-name"
        pane.fileView.select(name: "same-name.txt")
        check("symlink source has a temporary filter and a selected same-name file",
              pane.nameFilter == "same-name" && pane.fileView.selectedItems.map(\.name) == ["same-name.txt"])
        let generation = pane.model.generation
        let historyCount = pane.history.entries.count
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: b)
        pane.setZoomIndex(6)
        check("an edit before reload keeps the displayed directory's captured identity",
              pane.viewPropertiesKey == aKey && store.properties(forKey: aKey).iconsZoomIndex == 6
              && store.properties(forKey: bKey) == secondProperties)
        pane.reload()
        await listed(pane, at: link, after: generation)
        check("reload after symlink retargeting restores the new target without adding history",
              pane.viewPropertiesKey == bKey && pane.currentViewProperties == secondProperties
              && Set(pane.model.items.map(\.name)) == Set(["only-B.txt", "same-name.txt"])
              && pane.history.entries.count == historyCount)
        check("retargeting clears the previous directory's filter and same-name selection",
              pane.nameFilter.isEmpty && pane.fileView.selectedItems.isEmpty && pane.history.current?.selectedName == nil)
        try store.flush()
    }

    @MainActor
    private static func archiveChecks(in fixture: URL) async throws {
        print("== archive view-property persistence boundary ==")
        let archive = fixture.appendingPathComponent("view-boundary.zip")
        try (Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0, count: 18)).write(to: archive)
        let session: ArchiveBrowsingSession = try await withCheckedThrowingContinuation { continuation in
            ArchiveWorkspace.shared.prepare(archive: archive) { continuation.resume(with: $0) }
        }
        defer { session.close() }
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("archive-views.json"),
                                                 initialDefaults: secondProperties)
        let pane = BrowserViewController(provider: LocalFileProvider(), initialURL: session.rootURL, viewPropertiesStore: store)
        _ = pane.view
        await listed(pane, at: archive)
        check("archive snapshots navigate through the logical ZIP path and use defaults",
              pane.currentURL == archive && pane.viewPropertiesKey == nil && pane.currentViewProperties == secondProperties
              && pane.isBrowsingArchive && !pane.canModifyCurrentLocation)
        apply(firstProperties, to: pane)
        check("archive view changes stay transient and keep both views read-only",
              store.defaultProperties == secondProperties && pane.fileList.isReadOnly && pane.iconGrid.isReadOnly
              && !store.hasOverride(forKey: archive.path) && !store.hasOverride(forKey: session.rootURL.path))
        store.setPolicy(.unified)
        check("global policy changes leave virtual pages' current transient views alone",
              pane.currentViewProperties == firstProperties)
        apply(firstProperties, to: pane)
        check("virtual pages never overwrite unified defaults", store.defaultProperties == secondProperties)
        pane.useCurrentViewAsDefault()
        pane.restoreDirectoryViewDefaults()
        check("directory default commands cannot persist an archive view",
              pane.currentViewProperties == firstProperties && store.defaultProperties == secondProperties)
        try store.flush()
        let text = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        check("persisted views never contain archive snapshot paths", !text.contains(session.rootURL.path))
    }

    @MainActor
    private static func requiredMenuItem(_ action: Selector) -> NSMenuItem {
        func find(in menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.action == action { return item }
                if let nested = find(in: item.submenu) { return nested }
            }
            return nil
        }
        guard let item = find(in: NSApp.mainMenu) else {
            check("View menu contains \(NSStringFromSelector(action))", false)
            fatalError("Missing menu action")
        }
        return item
    }

    @MainActor
    private static func menuState(_ action: Selector, controller: MainWindowController) -> NSControl.StateValue {
        let item = requiredMenuItem(action)
        _ = controller.validateMenuItem(item)
        return item.state
    }

    @MainActor
    private static func dispatchMenu(_ action: Selector, to controller: MainWindowController) {
        let item = requiredMenuItem(action)
        check("View menu action \(item.title) is enabled and dispatches",
              controller.validateMenuItem(item) && NSApp.sendAction(action, to: controller, from: item))
    }

    @MainActor
    private static func listed(_ pane: BrowserViewController, at url: URL, after generation: Int = 0) async {
        await expectEventually("directory view listing: \(url.lastPathComponent)") {
            pane.currentURL?.standardizedFileURL == url.standardizedFileURL
                && pane.model.url?.standardizedFileURL == url.standardizedFileURL
                && pane.model.generation > generation && !pane.isPreparingArchive
        }
    }

    private final class GatedProvider: FileProvider {
        let homeURL: URL
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var started = false
        private var returned = false
        init(homeURL: URL) { self.homeURL = homeURL }
        var didStart: Bool { lock.lock(); defer { lock.unlock() }; return started }
        var didReturn: Bool { lock.lock(); defer { lock.unlock() }; return returned }
        func release() { gate.signal() }
        func displayName(for url: URL) -> String { url.lastPathComponent }
        func listDirectory(_ url: URL) throws -> [FileItem] {
            if url == homeURL {
                lock.lock(); started = true; lock.unlock()
                _ = gate.wait(timeout: .now() + 5)
                lock.lock(); returned = true; lock.unlock()
            }
            return try LocalFileProvider().listDirectory(url)
        }
    }
}

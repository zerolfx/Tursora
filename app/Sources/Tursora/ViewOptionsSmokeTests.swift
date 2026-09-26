import AppKit

enum ViewOptionsSmokeTests: SmokeSuite {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-view-options-" + UUID().uuidString).resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: fixture) }
            do {
                try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                try modelChecks(fixture)
                try await paneChecks(fixture)
                completion()
            } catch { fail("view options fixture", error.localizedDescription) }
        }
    }

    private static func modelChecks(_ fixture: URL) throws {
        let old = try JSONDecoder().decode(DirectoryViewProperties.self, from: Data(#"{"viewMode":"columns","showHidden":true}"#.utf8))
        check("old folder records keep default widths and their other settings", old.listColumnWidths.isEmpty && old.columnViewWidths.isEmpty && old.showHidden && old.viewMode == .columns)
        let bounded = DirectoryViewProperties.normalizedListColumnWidths(["name": 2, "size": 9000, "kind": .nan, "future": 300])
        check("list widths constrain known identifiers and reject nonfinite input", bounded == ["name": 180, "size": 1600])
        check("column widths clamp depth, range and nonfinite input",
              DirectoryViewProperties.normalizedColumnViewWidths([0, 9000, .infinity]) == [100, 1200, 245]
              && DirectoryViewProperties.normalizedColumnViewWidths(Array(repeating: 300, count: 100)).count == 64)
        var properties = DirectoryViewProperties()
        properties.listColumnWidths = ["name": 465, "dateModified": 205, "dateCreated": 240]
        properties.columnViewWidths = [310, 425]
        let file = fixture.appendingPathComponent("widths.json")
        let store = DirectoryViewPropertiesStore(fileURL: file)
        store.save(properties, forKey: "/folder-a")
        store.setDefault(properties)
        try store.flush()
        let restarted = DirectoryViewPropertiesStore(fileURL: file)
        check("all visible and hidden widths survive a store restart", restarted.properties(forKey: "/folder-a") == properties && restarted.defaultProperties == properties)
    }

    @MainActor private static func paneChecks(_ fixture: URL) async throws {
        let a = fixture.appendingPathComponent("Folder A"), b = fixture.appendingPathComponent("Folder B")
        for folder in [a, b] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("visible".utf8).write(to: folder.appendingPathComponent("note.txt"))
            try Data("hidden".utf8).write(to: folder.appendingPathComponent(".secret"))
        }
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("pane.json"))
        let owner = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: a, viewPropertiesStore: store)
        defer { owner.close() }
        owner.showWindow(nil)
        owner.window?.setContentSize(NSSize(width: 1100, height: 740))
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        let pane = owner.browser
        await listed(pane, a)
        let options = ViewOptionsWindowController(owner: owner)
        defer { options.close() }
        options.show()
        let name = pane.fileList.tableView.tableColumn(withIdentifier: FileListViewController.Column.name.id)!
        name.width = 500
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        check("automatic list layout never creates width overrides", pane.fileList.columnWidths.isEmpty && !store.hasOverride(forKey: pane.viewPropertiesKey!))
        (pane.fileList.tableView.headerView as? FileListHeaderView)?.onUserResizedColumns?(["name": 465, "dateCreated": 245])
        check("native list header callback saves explicit widths", store.properties(forKey: pane.viewPropertiesKey).listColumnWidths == ["name": 465, "dateCreated": 245])
        pane.navigate(to: b)
        await listed(pane, b)
        check("entering another folder restores default widths without a write", pane.fileList.columnWidths.isEmpty && !store.hasOverride(forKey: pane.viewPropertiesKey!))
        pane.navigate(to: a)
        await listed(pane, a)
        check("revisiting a folder restores actual list widths", name.width == 465 && pane.fileList.columnWidths["dateCreated"] == 245, "name width \(name.width)")
        pane.setViewMode(.columns)
        let columns = pane.columnView
        let wanted = columns.browser(columns.browser, shouldSizeColumn: 0, forUserResize: true, toWidth: 365)
        columns.browser.setWidth(wanted, ofColumn: 0)
        columns.browserColumnConfigurationDidChange(Notification(name: NSBrowser.columnConfigurationDidChangeNotification, object: columns.browser))
        check("native column resize callback persists root-depth width", pane.currentViewProperties.columnViewWidths.first == 365 && store.properties(forKey: pane.viewPropertiesKey).columnViewWidths.first == 365)
        columns.setColumnWidths([295])
        columns.browserColumnConfigurationDidChange(Notification(name: NSBrowser.columnConfigurationDidChangeNotification, object: columns.browser))
        check("restoring column sizes never writes them back as a user edit", store.properties(forKey: pane.viewPropertiesKey).columnViewWidths.first == 365)
        pane.restoreViewProperties()
        check("column view applies its saved physical width", columns.browser.width(ofColumn: 0) == 365)

        options.refresh()
        pane.nameFilter = "note"
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        await waitUntil("the native column has drawn the filtered fixture row") {
            columns.rowCountForTesting(0) == 1
                && (columns.browser.loadedCell(atRow: 0, column: 0) as? NSCell)?.stringValue.contains("note.txt") == true
        }
        pane.fileView.select(urls: [a.appendingPathComponent("note.txt")])
        func checkSelection(_ stage: String) {
            let actual = pane.fileView.selectedItems.map { $0.url.standardizedFileURL }
            let expected = a.appendingPathComponent("note.txt").standardizedFileURL
            check("View Options preserves selection after \(stage)", actual == [expected],
                  "selected=\(actual.map(\.absoluteString)) expected=\(expected.absoluteString)")
        }
        checkSelection("initial column selection")
        choose(options.modeControl, 0)
        checkSelection("mode")
        choose(options.sortControl, 2)
        checkSelection("sort")
        choose(options.directionControl, 1)
        checkSelection("direction")
        choose(options.groupControl, GroupKey.allCases.firstIndex(of: .kind)!)
        checkSelection("group")
        choose(options.zoomControl, 2)
        checkSelection("zoom")
        options.hiddenControl.performClick(nil)
        checkSelection("hidden")
        options.previewsControl.performClick(nil)
        checkSelection("previews")
        options.sizesControl.performClick(nil)
        checkSelection("sizes")
        options.columnControls[.dateCreated]?.performClick(nil)
        checkSelection("optional column")
        check("View Options controls drive mode, sorting, grouping and zoom", pane.viewMode == .details && pane.model.sortKey == .size && !pane.model.ascending && pane.groupKey == .kind && pane.zoomIndex == 2)
        check("View Options checkbox actions drive real listing and columns", pane.showsHiddenFiles && !pane.showsPreviews && pane.model.folderSizes.calculatesAllSizes && pane.fileList.isColumnVisible(.dateCreated))
        check("view settings preserve the active filter and exact selection", pane.nameFilter == "note" && pane.fileView.selectedItems.map { $0.url.standardizedFileURL } == [a.appendingPathComponent("note.txt").standardizedFileURL],
              "filter=\(pane.nameFilter) selected=\(pane.fileView.selectedItems.map { $0.url.path }) expected=\(a.appendingPathComponent("note.txt").path)")
        choose(options.modeControl, 1)
        check("icon mode shares the panel but disables list column controls", pane.fileView === pane.iconGrid && options.columnControls.values.allSatisfy { !$0.isEnabled } && !options.resetWidthsButton.isEnabled)
        choose(options.zoomControl, 3)
        checkSelection("icon zoom")
        options.previewsControl.performClick(nil)
        checkSelection("icon previews")
        options.previewsControl.performClick(nil)
        choose(options.modeControl, 0)
        options.defaultButton.performClick(nil)
        check("View Options saves widths together with the current defaults", store.defaultProperties == pane.currentViewProperties && store.defaultProperties.listColumnWidths["name"] == 465)
        options.resetWidthsButton.performClick(nil)
        check("reset widths changes only the active view's widths", pane.fileList.columnWidths.isEmpty && pane.columnView.columnWidths.first == 365)
        options.resetButton.performClick(nil)
        check("restore folder defaults removes the override and restores widths", !store.hasOverride(forKey: pane.viewPropertiesKey!) && pane.fileList.columnWidths["name"] == 465)

        let other = owner.tabs.currentPage.split(with: b)
        await listed(other, b)
        owner.tabs.currentPage.activate(pane)
        options.refresh()
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        check("presentation fixture has a narrow list with horizontal overflow",
              pane.view.bounds.width < 600
              && pane.fileList.tableView.bounds.width > pane.fileList.scrollView.contentView.bounds.width)
        let note = a.appendingPathComponent("note.txt").standardizedFileURL
        pane.fileView.select(urls: [note])
        for requestedX in [CGFloat(0), CGFloat(70)] {
            pane.fileList.horizontalScrollOffset = requestedX
            let expectedX = pane.fileList.horizontalScrollOffset
            check("narrow list accepts requested horizontal position \(requestedX)", abs(expectedX - requestedX) < 0.5)
            let actions: [(String, () -> Void)] = [
                ("zoom", { choose(options.zoomControl, pane.zoomIndex == 0 ? 1 : 0) }),
                ("previews", { options.previewsControl.performClick(nil) }),
                ("folder sizes", { options.sizesControl.performClick(nil) }),
            ]
            for (name, action) in actions {
                action()
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                check("\(name) preserves selection and horizontal position \(requestedX) in a narrow grouped list",
                      pane.fileView.selectedItems.map { $0.url.standardizedFileURL } == [note]
                      && abs(pane.fileList.horizontalScrollOffset - expectedX) < 0.5,
                      "x=\(pane.fileList.horizontalScrollOffset), expected=\(expectedX)")
                if requestedX == 0 {
                    let nameRect = pane.fileList.tableView.rect(ofColumn: pane.fileList.tableView.column(withIdentifier: FileListViewController.Column.name.id))
                    check("\(name) keeps the narrow list Name column visible",
                          nameRect.intersection(pane.fileList.scrollView.documentVisibleRect).width >= 160)
                }
            }
        }
        owner.tabs.currentPage.activate(other)
        options.refresh()
        let before = pane.showsPreviews
        options.previewsControl.performClick(nil)
        check("the open panel targets the active split pane", other.showsPreviews != before && pane.showsPreviews == before)
        choose(options.policyControl, 1)
        options.hiddenControl.performClick(nil)
        check("shared policy updates both panes without recursive writes", store.policy == .unified && pane.showsHiddenFiles == other.showsHiddenFiles && !options.resetButton.isEnabled)
        let tab = owner.tabs.newTab(at: a)
        await listed(tab, a)
        options.refresh()
        choose(options.policyControl, 0)
        let tabBefore = tab.showsPreviews
        let otherBefore = other.showsPreviews
        options.previewsControl.performClick(nil)
        check("the same panel follows a newly selected tab", tab.showsPreviews != tabBefore && other.showsPreviews == otherBefore)
        let saved = store.properties(forKey: tab.viewPropertiesKey)
        tab.isSearching = true
        options.refresh()
        options.previewsControl.performClick(nil)
        (tab.fileList.tableView.headerView as? FileListHeaderView)?.onUserResizedColumns?(["name": 640])
        check("virtual results keep view edits transient and disable default actions", !options.defaultButton.isEnabled && !options.resetButton.isEnabled && store.properties(forKey: tab.viewPropertiesKey) == saved)
        tab.isSearching = false
        tab.restoreViewProperties()
        options.window?.contentView?.layoutSubtreeIfNeeded()
        if let content = options.window?.contentView {
            let footer = options.resetButton.convert(options.resetButton.bounds, to: content)
            check("View Options buttons fit inside the panel", footer.minY >= 0 && footer.maxY <= content.bounds.height)
        }
        owner.close()
        check("closing the browser window closes its options panel", options.window?.isVisible != true)
    }

    @MainActor private static func choose(_ popup: NSPopUpButton, _ index: Int) {
        popup.selectItem(at: index)
        if let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
    }
    @MainActor private static func listed(_ pane: BrowserViewController, _ url: URL) async {
        await waitUntil("view options directory listing") {
            pane.currentURL?.standardizedFileURL == url.standardizedFileURL
                && pane.model.url?.standardizedFileURL == url.standardizedFileURL && pane.model.generation > 0
                && pane.model.items.contains { $0.url.standardizedFileURL == url.appendingPathComponent("note.txt").standardizedFileURL }
        }
    }
}

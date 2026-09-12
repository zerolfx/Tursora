import AppKit

/// Exercises the real toolbar control without displaying a window or reading user files.
enum SplitToolbarSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            await runChecks()
            completion()
        }
    }

    @MainActor
    private static func runChecks() async {
        print("== split toolbar ==")
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "ok  " : "FAIL") \(name)")
            if !condition { exit(1) }
        }
        let provider = EmptyProvider()
        let defaults = UserDefaults.standard
        let savedFavorites = defaults.object(forKey: "favouritesOrder")
        defer {
            if let savedFavorites { defaults.set(savedFavorites, forKey: "favouritesOrder") }
            else { defaults.removeObject(forKey: "favouritesOrder") }
        }
        let controller = MainWindowController(provider: provider, places: PlacesModel(), initialURL: provider.homeURL)
        defer { controller.close() }
        await listed(controller.browser, at: provider.homeURL)
        guard let toolbar = controller.window?.toolbar else {
            check("split toolbar exists", false)
            return
        }
        let identifier = NSToolbarItem.Identifier("tursora.split")
        check("split toggle is included in the default toolbar", controller.toolbarDefaultItemIdentifiers(toolbar).contains(identifier))
        let item = toolbar.items.first { $0.itemIdentifier == identifier }
            ?? controller.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: false)
        guard let button = controller.splitToolbarButtonForTesting else {
            check("split toolbar creates an actual button", false)
            return
        }
        check("split toolbar targets the existing toggle action",
              button.target === controller && button.action == #selector(MainWindowController.toggleSplit(_:))
              && button.state == .off && item?.label == "Split View")

        let original = controller.browser
        button.performClick(nil)
        await listed(controller.browser, at: provider.homeURL)
        check("split toolbar click opens and activates a second pane",
              controller.tabs.isSplit && controller.tabs.currentPage.panes.count == 2
              && controller.browser !== original && button.state == .on)
        check("split toolbar describes closing the active right pane",
              item?.label == "Close Right Pane" && button.toolTip?.contains("Close Right Pane") == true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        check("split list panes retain a readable filename column", controller.tabs.currentPage.panes.allSatisfy {
            ($0.fileList.tableView.outlineTableColumn?.width ?? 0) >= 180
        })

        controller.tabs.newTab(at: provider.homeURL)
        await listed(controller.browser, at: provider.homeURL)
        check("split toolbar resets for a newly selected unsplit tab", !controller.tabs.isSplit && button.state == .off && item?.label == "Split View")
        controller.tabs.selectTab(at: 0)
        check("split toolbar restores the selected tab's split state", controller.tabs.isSplit && button.state == .on && item?.label == "Close Right Pane")

        controller.tabs.focusOtherPane()
        let survivor = controller.tabs.currentPage.inactive
        check("split toolbar follows active pane changes", controller.browser === original && item?.label == "Close Left Pane")
        button.performClick(nil)
        check("split toolbar closes the active pane and preserves its peer",
              !controller.tabs.isSplit && controller.browser === survivor && button.state == .off && item?.label == "Split View")

        if let overflow = item?.menuFormRepresentation {
            let dispatched = NSApp.sendAction(overflow.action!, to: overflow.target, from: overflow)
            await listed(controller.browser, at: provider.homeURL)
            check("split overflow command uses the same action and state",
                  dispatched && controller.tabs.isSplit && button.state == .on && overflow.state == .on)
        } else { check("split overflow command exists", false) }

        button.performClick(nil)
        let source = controller.browser
        let sourcePath = source.currentURL?.standardizedFileURL.path
        let destination = FileManager.default.homeDirectoryForCurrentUser
        controller.places.addFavourite(destination)
        let outline = controller.sidebar.outlineView
        let row = controller.sidebar.row(for: destination)
        check("sidebar split fixture has a favorite row", row >= 0)
        let point = outline.convert(NSPoint(x: outline.bounds.midX, y: outline.rect(ofRow: row).midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                           timestamp: 0, windowNumber: controller.window!.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let menu = outline.menu(for: event) else {
            check("sidebar favorite creates its real context menu", false)
            return
        }
        let otherIndex = menu.indexOfItem(withTitle: "Open in Other Pane")
        check("sidebar favorite offers Open in Other Pane", otherIndex >= 0)
        menu.performActionForItem(at: otherIndex)
        await listed(controller.browser, at: destination)
        check("sidebar menu opens its favorite in a new opposite pane",
              controller.tabs.isSplit && controller.browser !== source && controller.browser.currentURL?.standardizedFileURL.path == destination.standardizedFileURL.path
              && source.currentURL?.standardizedFileURL.path == sourcePath && button.state == .on)

        let newTabIndex = menu.indexOfItem(withTitle: "Open in New Tab")
        check("sidebar favorite retains its New Tab command", newTabIndex >= 0)
        let previousTabCount = controller.tabs.count
        menu.performActionForItem(at: newTabIndex)
        await listed(controller.browser, at: destination)
        check("sidebar New Tab opens the captured favorite and synchronizes the split toggle",
              controller.tabs.count == previousTabCount + 1 && controller.browser.currentURL?.standardizedFileURL.path == destination.standardizedFileURL.path
              && source.currentURL?.standardizedFileURL.path == sourcePath && !controller.tabs.isSplit && button.state == .off)
    }

    @MainActor
    private static func listed(_ browser: BrowserViewController, at url: URL) async {
        let expected = url.standardizedFileURL.path
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if browser.currentURL?.standardizedFileURL.path == expected,
               browser.model.url?.standardizedFileURL.path == expected,
               browser.model.generation > 0, !browser.isPreparingArchive { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        print("FAIL split toolbar timed out waiting for \(expected); current=\(browser.currentURL?.path ?? "nil"), generation=\(browser.model.generation)")
        exit(1)
    }

    private final class EmptyProvider: FileProvider {
        let homeURL = FileManager.default.temporaryDirectory
        func displayName(for url: URL) -> String { url.lastPathComponent }
        func listDirectory(_ url: URL) throws -> [FileItem] { [] }
    }
}

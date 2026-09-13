import AppKit

/// Uses the existing favourite fixtures; never changes persisted favourites or
/// presents a menu. Mouse hit-testing and dispatch use the production AppKit path.
enum SidebarContextSmokeTests: SmokeSuite {
    static func run(_ sidebar: SidebarViewController, firstURL: URL, secondURL: URL) {
        print("== sidebar context menus ==")
        let outline = sidebar.outlineView
        let originalSelection = outline.selectedRowIndexes
        let originalOpen = sidebar.onSelectPlace
        let originalTab = sidebar.onOpenInNewTab
        let originalPane = sidebar.onOpenInOtherPane
        defer {
            outline.selectRowIndexes(originalSelection, byExtendingSelection: false)
            sidebar.onSelectPlace = originalOpen
            sidebar.onOpenInNewTab = originalTab
            sidebar.onOpenInOtherPane = originalPane
        }
        func sameLocations(_ lhs: [URL], _ rhs: [URL]) -> Bool {
            lhs.map { $0.standardizedFileURL.path } == rhs.map { $0.standardizedFileURL.path }
        }
        var opened: [URL] = [], tabs: [URL] = [], panes: [URL] = []
        sidebar.onSelectPlace = { opened.append($0) }
        sidebar.onOpenInNewTab = { tabs.append($0) }
        sidebar.onOpenInOtherPane = { panes.append($0) }
        let favourites = sidebar.places.sections.first?.places.map(\.url) ?? []
        let firstRow = sidebar.row(for: firstURL), secondRow = sidebar.row(for: secondURL)
        check("sidebar context: both favourite fixtures are visible", firstRow >= 0 && secondRow >= 0 && firstRow != secondRow)
        sidebar.syncSelection(to: firstURL)

        func menu(at point: NSPoint) -> NSMenu? {
            let event = NSEvent.mouseEvent(with: .rightMouseDown,
                location: outline.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: outline.window?.windowNumber ?? 0, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
            return outline.menu(for: event)
        }
        func menu(row: Int) -> NSMenu? {
            let rect = outline.rect(ofRow: row)
            return menu(at: NSPoint(x: rect.midX, y: rect.midY))
        }
        guard let secondMenu = menu(row: secondRow) else {
            check("sidebar context: right-clicking a favourite produces a menu", false)
            return
        }
        let expected = ["Open", "Open in New Tab", "Open in Other Pane"]
        check("sidebar context: favourites offer all three opening destinations", Array(secondMenu.items.prefix(3).map(\.title)) == expected)
        check("sidebar context: favourites keep navigation inside Tursora", !secondMenu.items.contains { $0.title == "Reveal in Finder" })
        check("sidebar context: ordinary favourites have no Eject command", !secondMenu.items.contains { $0.title.hasPrefix("Eject") })
        check("sidebar context: building a menu does not navigate or select its target", opened.isEmpty && outline.selectedRow == firstRow)

        func dispatch(_ title: String, in menu: NSMenu) {
            let index = menu.indexOfItem(withTitle: title)
            check("sidebar context: \(title) is enabled and directly targeted", index >= 0 && menu.item(at: index)?.isEnabled == true && menu.item(at: index)?.target === sidebar)
            menu.performActionForItem(at: index)
        }
        dispatch("Open in New Tab", in: secondMenu)
        check("sidebar context: New Tab receives the right-clicked URL without navigating", sameLocations(tabs, [secondURL]) && opened.isEmpty && panes.isEmpty && outline.selectedRow == firstRow)
        dispatch("Open in Other Pane", in: secondMenu)
        check("sidebar context: Other Pane receives the right-clicked URL without navigating", sameLocations(panes, [secondURL]) && opened.isEmpty && outline.selectedRow == firstRow)

        // Keep menu items while another context is prepared and selection changes.
        // Handlers must not read clickedRow, selectedRow or the latest context.
        let captured = NSMenu()
        for title in ["Open", "Open in New Tab", "Open in Other Pane"] {
            captured.addItem(secondMenu.item(withTitle: title)!.copy() as! NSMenuItem)
        }
        _ = menu(row: firstRow)
        sidebar.syncSelection(to: secondURL)
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        opened.removeAll()
        dispatch("Open in New Tab", in: captured)
        dispatch("Open in Other Pane", in: captured)
        check("sidebar context: captured targets survive menu replacement and outline reload", sameLocations(tabs, [secondURL, secondURL]) && sameLocations(panes, [secondURL, secondURL]) && opened.isEmpty)
        dispatch("Open", in: captured)
        check("sidebar context: Open uses the captured place", sameLocations(opened, [secondURL]))

        let sectionRow = (0..<outline.numberOfRows).first { row in
            guard let item = outline.item(atRow: row) else { return false }
            return sidebar.outlineView(outline, isGroupItem: item)
        }
        check("sidebar context: a section row is available", sectionRow != nil)
        check("sidebar context: section headers do not inherit the previous menu", menu(row: sectionRow!) == nil)
        let bottom = outline.rect(ofRow: outline.numberOfRows - 1).maxY + 40
        check("sidebar context: blank space has no context menu", menu(at: NSPoint(x: 20, y: bottom)) == nil)

        // Actions with no captured place must never fall back to a selected row.
        let invalid = NSMenu()
        for action in ["ctxRemove:", "ctxResetFavourites:", "ctxEject:"] {
            let item = NSMenuItem(title: action, action: Selector(action), keyEquivalent: "")
            item.target = sidebar
            invalid.addItem(item)
        }
        for index in 0..<invalid.numberOfItems { invalid.performActionForItem(at: index) }
        check("sidebar context: opening and targetless actions never remove or reset favourites", sidebar.places.sections.first?.places.map(\.url) == favourites)
        check("sidebar context: context commands never perform an implicit second navigation", sameLocations(opened, [secondURL]))
    }
}

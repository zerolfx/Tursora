import AppKit

/// A per-window, newest-first view of the existing ten-tab recovery pool.
final class RecentlyClosedTabsMenu: NSMenu, NSMenuDelegate {
    init() {
        super.init(title: "Recently Closed Tabs")
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let owner = (NSApp.keyWindow?.windowController as? MainWindowController)
            ?? (NSApp.mainWindow?.windowController as? MainWindowController)
        refresh(for: owner?.tabs)
    }

    func refresh(for tabs: TabsController?) {
        removeAllItems()
        for page in tabs?.recentlyClosedPages ?? [] {
            let item = NSMenuItem(title: page.tabTitle.plain,
                                  action: #selector(TabsController.reopenSelectedClosedTab(_:)), keyEquivalent: "")
            item.target = tabs
            item.representedObject = page
            item.toolTip = page.panes.map { $0.chromeLocationURL.path }.joined(separator: "\n")
            addItem(item)
        }
        if items.isEmpty {
            let empty = NSMenuItem(title: "No Recently Closed Tabs", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            addItem(empty)
        }
    }
}

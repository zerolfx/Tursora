import AppKit

/// A fresh pane can revisit a logical ZIP URL or rerun a search without moving
/// the old pane's history, selection, task ownership or undo manager.
struct TabPaneSnapshot {
    let url: URL
    let search: SearchRequest?

    init(_ pane: BrowserViewController) {
        url = ArchiveWorkspace.shared.logicalURL(for: pane.currentURL ?? pane.provider.homeURL)
        search = pane.isSearching ? pane.searchSession.request : nil
    }

    func restore(in pane: BrowserViewController) {
        // Navigate explicitly before search so deferred initial navigation cannot
        // replace the newly started result model on the next run-loop pass.
        pane.navigate(to: url)
        if let search { pane.startSearch(search) }
    }
}

struct TabSnapshot {
    let panes: [TabPaneSnapshot]
    let activeIndex: Int
    let customTitle: String?

    init(_ page: TabPage) {
        panes = page.panes.map(TabPaneSnapshot.init)
        activeIndex = page.activeIndex
        customTitle = page.customTitle
    }

    func restore(in tabs: TabsController) {
        guard let first = panes.first else { return }
        let page = tabs.currentPage
        first.restore(in: page.panes[0])
        if panes.count == 2 {
            let right = page.split(with: panes[1].url)
            panes[1].restore(in: right)
        }
        if page.panes.indices.contains(activeIndex) { page.activate(page.panes[activeIndex]) }
        tabs.setTitle(customTitle, for: page)
        tabs.view.window?.makeFirstResponder(page.active.focusView)
    }
}

extension TabPage {
    /// Keep physical left/right order without adding focus markers to names.
    static func title(left: String, right: String?, activeIndex _: Int, custom: String?) -> String {
        if let custom, !custom.isEmpty { return custom }
        guard let right else { return left }
        return "\(left) | \(right)"
    }

    private func paneTitle(_ pane: BrowserViewController) -> String {
        if pane.isSearching {
            let name = pane.searchSession.request?.trimmedName ?? ""
            return name.isEmpty ? "Search Results" : "Search: \(name)"
        }
        guard let url = pane.currentURL else { return "…" }
        return pane.isBrowsingArchive ? url.lastPathComponent : provider.displayName(for: url)
    }

    var automaticTabTitle: String {
        Self.title(left: panes.first.map(paneTitle) ?? "…",
                   right: panes.count == 2 ? paneTitle(panes[1]) : nil,
                   activeIndex: activeIndex, custom: nil)
    }

    var tabTitle: String { customTitle ?? automaticTabTitle }

    var tabToolTip: String {
        let locations = panes.enumerated().map { index, pane in
            let path = pane.currentURL.map { ArchiveWorkspace.shared.logicalURL(for: $0).path } ?? "…"
            let location = pane.isSearching
                ? "\(paneTitle(pane)) — \(pane.searchSession.request?.effectiveRootURL.path ?? path)"
                : path
            guard isSplit else { return location }
            let side = index == 0 ? "Left" : "Right"
            return "\(side)\(index == activeIndex ? " (active)" : ""): \(location)"
        }
        return ([customTitle].compactMap { $0 } + locations).joined(separator: "\n")
    }
}

enum TabContextAction: CaseIterable {
    case newTab, detach, rename, closeOthers, closeLeft, closeRight, close

    var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .detach: return "Detach Tab"
        case .rename: return "Rename Tab"
        case .closeOthers: return "Close Other Tabs"
        case .closeLeft: return "Close Tabs to the Left"
        case .closeRight: return "Close Tabs to the Right"
        case .close: return "Close Tab"
        }
    }
}

extension TabsController {
    func tabContextMenu(at index: Int) -> NSMenu? {
        guard pages.indices.contains(index) else { return nil }
        let page = pages[index]
        let menu = NSMenu()
        for action in TabContextAction.allCases {
            if action == .rename || action == .closeOthers { menu.addItem(.separator()) }
            let target = TabMenuTarget(tabs: self, page: page, action: action)
            let item = NSMenuItem(title: action.title, action: #selector(TabMenuTarget.invoke(_:)), keyEquivalent: "")
            // NSMenuItem.target is weak. Each item owns its target and therefore
            // its clicked page even when another menu is built before dispatch.
            item.representedObject = target
            item.target = target
            item.isEnabled = canPerformTabAction(action, on: page)
            menu.addItem(item)
        }
        return menu
    }

    func canPerformTabAction(_ action: TabContextAction, on page: TabPage) -> Bool {
        guard let index = pages.firstIndex(where: { $0 === page }) else { return false }
        switch action {
        case .newTab: return !page.active.isPreparingArchive
        case .detach: return onDetachTab != nil && !page.panes.contains(where: \.isPreparingArchive)
        case .rename: return true
        case .closeOthers: return pages.count > 1
        case .closeLeft: return index > 0
        case .closeRight: return index < pages.count - 1
        case .close: return pages.count > 1 || onCloseLastTab != nil
        }
    }

    func performTabAction(_ action: TabContextAction, on page: TabPage) {
        guard canPerformTabAction(action, on: page),
              let index = pages.firstIndex(where: { $0 === page }) else { return }
        switch action {
        case .newTab:
            let location = TabPaneSnapshot(page.active)
            let pane = newTab(at: location.url)
            location.restore(in: pane)
        case .detach:
            guard onDetachTab?(TabSnapshot(page)) == true else { return }
            // Tasks keep their original owner. Closing the last source tab uses
            // the normal window delegate, including cancellation and cleanup.
            if let now = pages.firstIndex(where: { $0 === page }), !closeTab(at: now) { onCloseLastTab?() }
        case .rename:
            requestTabTitle(for: page)
        case .closeOthers, .closeLeft, .closeRight:
            let targets = pages.enumerated().compactMap { candidate, value -> TabPage? in
                switch action {
                case .closeOthers: return value === page ? nil : value
                case .closeLeft: return candidate < index ? value : nil
                case .closeRight: return candidate > index ? value : nil
                default: return nil
                }
            }
            // Select the clicked survivor if the current page is being closed;
            // otherwise leave the existing current page and its focus intact.
            if targets.contains(where: { $0 === currentPage }) { selectTab(at: index) }
            for target in targets.reversed() {
                if let now = pages.firstIndex(where: { $0 === target }) { closeTab(at: now) }
            }
        case .close:
            if !closeTab(at: index) { onCloseLastTab?() }
        }
    }

    private func requestTabTitle(for page: TabPage) {
        let completion: (String?) -> Void = { [weak self, weak page] title in
            guard let self, let page, let title else { return }
            self.setTitle(title, for: page)
        }
        if let renameTabTitleProvider {
            renameTabTitleProvider(page.tabTitle, completion)
            return
        }
        guard !SmokeTest.isRequested else {
            print("   [tab rename] Sheet suppressed in smoke mode")
            return
        }
        guard let window = view.window else { return }
        let field = NSTextField(string: page.customTitle ?? "")
        field.placeholderString = page.automaticTabTitle
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a name for this tab. Leave it empty to use the folder names."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
    }
}

private final class TabMenuTarget: NSObject, NSMenuItemValidation {
    weak var tabs: TabsController?
    let page: TabPage
    let action: TabContextAction

    init(tabs: TabsController, page: TabPage, action: TabContextAction) {
        self.tabs = tabs
        self.page = page
        self.action = action
    }

    @objc func invoke(_ sender: NSMenuItem) { tabs?.performTabAction(action, on: page) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { tabs?.canPerformTabAction(action, on: page) ?? false }
}

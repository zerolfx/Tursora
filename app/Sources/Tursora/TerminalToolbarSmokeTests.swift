import AppKit

/// Runs the real toolbar and overflow actions without launching a user shell.
enum TerminalToolbarSmokeTests: SmokeSuite {
    static let checkPrefix = "terminal toolbar: "
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            await runChecks()
            completion()
        }
    }

    @MainActor
    private static func runChecks() async {
        print("== terminal toolbar ==")
        let savedEnabled = AppPreferences.experimentalTerminalEnabled
        defer { AppPreferences.experimentalTerminalEnabled = savedEnabled }
        AppPreferences.experimentalTerminalEnabled = true
        let provider = SmokeFixtures.EmptyProvider()
        let first = MainWindowController(provider: provider, places: PlacesModel(), initialURL: provider.homeURL)
        let second = MainWindowController(provider: provider, places: PlacesModel(), initialURL: provider.homeURL)
        defer { first.close(); second.close() }
        await listed(first.browser)
        await listed(second.browser)
        guard let toolbar = first.window?.toolbar else { check("window has a toolbar", false); return }
        let identifier = NSToolbarItem.Identifier("tursora.terminal")
        check("included in the default toolbar", first.toolbarDefaultItemIdentifiers(toolbar).contains(identifier))
        let item = toolbar.items.first { $0.itemIdentifier == identifier }
            ?? first.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: false)
        guard let button = first.terminalToolbarButtonForTesting,
              let overflow = item?.menuFormRepresentation else { check("button and overflow exist", false); return }
        check("initial state describes opening", button.isEnabled && button.state == .off && item?.label == "Show Terminal")
        for mode in [ViewMode.details, .icons] {
            first.browser.setViewMode(mode)
            first.browser.nameFilter = "*.swift"
            first.browser.setGroupKey(.kind)
            button.performClick(nil)
            guard let panel = first.terminalPanel else { check("click opens from \(mode)", false); return }
            check("click opens from \(mode) without a headless shell", !panel.isRunning && panel.terminalView == nil)
            check("button and overflow reflect open panel", button.state == .on && item?.label == "Hide Terminal" && overflow.state == .on)
            check("another window is independent", second.terminalPanel == nil && second.terminalToolbarButtonForTesting?.state == .off)
            first.tabs.toggleSplit()
            await listed(first.browser)
            first.tabs.newTab(at: provider.homeURL)
            await listed(first.browser)
            check("panel belongs to its window across panes and tabs", first.terminalPanel === panel && button.state == .on)
            check("overflow dispatches the same close action", NSApp.sendAction(overflow.action!, to: overflow.target, from: overflow))
            check("overflow hides the retained panel and restores file focus", !first.isTerminalVisible && first.terminalPanel === panel && button.state == .off && first.window?.firstResponder === first.browser.focusView)
        }
        button.performClick(nil)
        let opened = first.terminalPanel
        opened?.onClose?()
        check("panel hide updates toolbar and overflow without discarding it", !first.isTerminalVisible && first.terminalPanel === opened && button.state == .off && overflow.state == .off)
        button.performClick(nil)

        // Switched off, the button leaves the toolbar rather than sitting there
        // dimmed, in every open window and in the identifiers a new one builds from.
        AppPreferences.experimentalTerminalEnabled = false
        let terminalMenuItem = menuItem(#selector(MainWindowController.toggleTerminal(_:)), in: NSApp.mainMenu)
        check("settings opt-out withdraws the button from every window",
              !identifiers(of: first).contains(identifier) && !identifiers(of: second).contains(identifier),
              "first=\(names(of: first)) second=\(names(of: second))")
        check("the withdrawn button is released rather than detached and held",
              first.terminalToolbarButtonForTesting == nil && second.terminalToolbarButtonForTesting == nil)
        check("a window opened while off builds a toolbar without it",
              !first.toolbarDefaultItemIdentifiers(toolbar).contains(identifier),
              names(first.toolbarDefaultItemIdentifiers(toolbar)))
        check("the menu command hides on the same preference", terminalMenuItem?.isHidden == true,
              terminalMenuItem.map { "hidden=\($0.isHidden)" } ?? "no menu item")
        check("the opt-out hides the retained panel", !first.isTerminalVisible && first.terminalPanel === opened)
        check("the withdrawn item stays insertable", first.toolbarAllowedItemIdentifiers(toolbar).contains(identifier))
        first.toggleTerminal(nil)
        check("the withdrawn action cannot reveal the retained panel", !first.isTerminalVisible && first.terminalPanel === opened)

        AppPreferences.experimentalTerminalEnabled = true
        let split = NSToolbarItem.Identifier("tursora.split")
        check("re-enabling returns the button to its place after Split View",
              identifiers(of: first).firstIndex(of: identifier) == identifiers(of: first).firstIndex(of: split).map { $0 + 1 }
              && identifiers(of: second).contains(identifier)
              && first.toolbarDefaultItemIdentifiers(toolbar).contains(identifier),
              "first=\(names(of: first))")
        check("re-enabling brings the menu command back", terminalMenuItem?.isHidden == false)
        guard let restored = first.terminalToolbarButtonForTesting,
              let restoredItem = toolbar.items.first(where: { $0.itemIdentifier == identifier }),
              let restoredOverflow = restoredItem.menuFormRepresentation else {
            check("the restored button and overflow exist", false); return
        }
        check("the restored button describes opening the kept session",
              restored.isEnabled && restored.state == .off && restoredItem.label == "Show Terminal"
              && restoredOverflow.title == "Show Terminal" && restoredOverflow.state == .off
              && !first.isTerminalVisible && first.terminalPanel === opened)
        first.window?.setContentSize(NSSize(width: 560, height: 360))
        first.window?.contentView?.layoutSubtreeIfNeeded()
        check("narrow toolbar retains usable overflow", NSApp.sendAction(restoredOverflow.action!, to: restoredOverflow.target, from: restoredOverflow) && first.terminalPanel != nil)
        check("the restored button tracks the panel it reopened", restored.state == .on && restoredItem.label == "Hide Terminal")
        first.hideTerminal()
    }

    @MainActor
    private static func identifiers(of wc: MainWindowController) -> [NSToolbarItem.Identifier] {
        wc.window?.toolbar?.items.map(\.itemIdentifier) ?? []
    }

    @MainActor
    private static func names(of wc: MainWindowController) -> String { names(identifiers(of: wc)) }
    private static func names(_ ids: [NSToolbarItem.Identifier]) -> String {
        ids.map(\.rawValue).joined(separator: " ")
    }

    private static func menuItem(_ action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let found = menuItem(action, in: item.submenu) { return found }
        }
        return nil
    }

    @MainActor
    private static func listed(_ browser: BrowserViewController) async {
        await waitUntil("initial listing") { browser.model.generation > 0 }
    }
}

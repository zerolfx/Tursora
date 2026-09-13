import AppKit

/// Runs the real toolbar and overflow actions without launching a user shell.
enum TerminalToolbarSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            await runChecks()
            completion()
        }
    }

    @MainActor
    private static func runChecks() async {
        print("== terminal toolbar ==")
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "ok  " : "FAIL") terminal toolbar: \(name)")
            if !condition { exit(1) }
        }
        let savedEnabled = AppPreferences.experimentalTerminalEnabled
        defer { AppPreferences.experimentalTerminalEnabled = savedEnabled }
        AppPreferences.experimentalTerminalEnabled = true
        let provider = EmptyProvider()
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
            check("overflow closes and restores the file focus", first.terminalPanel == nil && button.state == .off && first.window?.firstResponder === first.browser.focusView)
        }
        button.performClick(nil)
        let opened = first.terminalPanel
        opened?.onClose?()
        check("panel close updates toolbar and overflow", first.terminalPanel == nil && button.state == .off && overflow.state == .off)
        button.performClick(nil)
        AppPreferences.experimentalTerminalEnabled = false
        check("settings opt-out closes and disables all window controls", first.terminalPanel == nil && !button.isEnabled && !overflow.isEnabled && second.terminalToolbarButtonForTesting?.isEnabled == false)
        button.performClick(nil)
        first.toggleTerminal(nil)
        check("disabled action cannot reopen the panel", first.terminalPanel == nil && button.state == .off)
        AppPreferences.experimentalTerminalEnabled = true
        check("re-enabling exposes the action without starting a shell", button.isEnabled && overflow.isEnabled && first.terminalPanel == nil)
        first.window?.setContentSize(NSSize(width: 560, height: 360))
        first.window?.contentView?.layoutSubtreeIfNeeded()
        check("narrow toolbar retains usable overflow", NSApp.sendAction(overflow.action!, to: overflow.target, from: overflow) && first.terminalPanel != nil)
        first.hideTerminal()
    }

    @MainActor
    private static func listed(_ browser: BrowserViewController) async {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if browser.model.generation > 0 { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        print("FAIL terminal toolbar: initial listing timed out")
        exit(1)
    }

    private final class EmptyProvider: FileProvider {
        let homeURL = FileManager.default.temporaryDirectory
        func displayName(for url: URL) -> String { url.lastPathComponent }
        func listDirectory(_ url: URL) throws -> [FileItem] { [] }
    }
}

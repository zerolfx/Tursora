import AppKit
import SwiftTerm

/// Tests the complete catalog, storage, recorder and real responder-chain paths.
enum ShortcutSmokeTests: SmokeSuite {
    static let checkPrefix = "shortcuts: "
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            modelAndSettings()
            await routing()
            completion()
        }
    }

    @MainActor
    private static func modelAndSettings() {
        print("== customizable keyboard shortcuts ==")
        let domain = "com.tursora.shortcut-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
        let store = preferences.shortcuts
        let actions = ShortcutCatalog.actions
        check("every catalog command has a unique persistent ID", Set(actions.map(\.id)).count == actions.count)
        check("catalog includes all menu commands, unbound actions and key-only aliases",
              actions.count == MainMenu.shortcutDefinitions().count + 15
              && actions.contains { $0.id == "menu.compressSelection" && $0.defaultShortcut == nil }
              && actions.contains { $0.id == "menu.toggleFoldersPanel" }
              && actions.contains { $0.id == "window.selectTab.9" })
        check("defaults have no competing commands", store.bindings.values.allSatisfy { value in store.bindings.values.filter { $0.isEquivalent(to: value) }.count == 1 })
        check("reading defaults does not create a saved map", defaults.object(forKey: ShortcutStore.defaultsKey) == nil)
        let f8 = AppPreferences.Shortcut(keyEquivalent: "\u{f70b}", modifierFlags: [])
        check("function keys and Command arrows have readable labels", f8.displayString == "F8" && AppPreferences.Shortcut(keyEquivalent: "\u{f700}", modifierFlags: .command).displayString == "⌘↑")
        check("F6 hardware key records even with empty event characters", AppPreferences.Shortcut.from(event("", .function, 97)).displayString == "F6")
        check("layout-independent navigation keys ignore empty translations", AppPreferences.Shortcut.from(event("", .command, 126)).displayString == "⌘↑")
        let forwardDelete = AppPreferences.Shortcut.from(event("\u{f728}", .command, 117))
        let backspace = AppPreferences.Shortcut.from(event("\u{7f}", .command, 51))
        check("Forward Delete uses the menu character and remains distinct from Backspace", forwardDelete.keyEquivalent == "\u{7f}" && forwardDelete.displayString == "⌘⌦"
              && backspace.keyEquivalent == "\u{8}" && backspace.displayString == "⌘⌫" && !forwardDelete.isEquivalent(to: backspace))
        check("reported Forward Delete normalization never adds Shift", AppPreferences.Shortcut(keyEquivalent: "\u{f728}", modifierFlags: .command) == forwardDelete)
        check("Fn Delete records forward deletion even with Backspace hardware code", AppPreferences.Shortcut.from(event("\u{f728}", [.command, .function], 51)) == forwardDelete)
        let rawDelete = event("\u{f728}", [.command, .function], 117)
        let menuDelete = AppPreferences.Shortcut.eventForMenu(rawDelete)
        check("menu deletion normalization preserves the original editing event and modifiers", rawDelete.characters == "\u{f728}"
              && menuDelete.characters == "\u{7f}" && menuDelete.modifierFlags == rawDelete.modifierFlags && menuDelete.keyCode == rawDelete.keyCode)
        check("empty layout translation falls back to the reported character", AppPreferences.Shortcut.keyEquivalent(keyCode: 0, translated: "", reported: "é", characters: "é") == "é")
        let plus = AppPreferences.Shortcut(keyEquivalent: "+", modifierFlags: .command)
        let shiftedEquals = AppPreferences.Shortcut(keyEquivalent: "=", modifierFlags: [.command, .shift])
        let usLayout = ShortcutKeyboardLayout(shiftedCharacters: ["=": "+", "a": "A"])
        let germanLayout = ShortcutKeyboardLayout(shiftedCharacters: ["+": "*", "=": "=", "a": "A"])
        check("literal plus is never rewritten to a US physical key", plus.keyEquivalent == "+" && plus.modifierFlags == .command && plus.displayString == "⌘+")
        check("US layout identifies Shift Equals as the same shortcut", plus != shiftedEquals && plus.isEquivalent(to: shiftedEquals, layout: usLayout))
        check("non-US layout keeps unshifted plus separate from Shift Equals", !plus.isEquivalent(to: shiftedEquals, layout: germanLayout))
        check("non-US shifted punctuation follows its own layout", AppPreferences.Shortcut(keyEquivalent: "+", modifierFlags: [.command, .shift]).isEquivalent(to: .init(keyEquivalent: "*", modifierFlags: .command), layout: germanLayout))
        check("Shift letter identity stays distinct from unshifted typing", !AppPreferences.Shortcut(keyEquivalent: "a", modifierFlags: [.command, .shift]).isEquivalent(to: .init(keyEquivalent: "a", modifierFlags: .command), layout: usLayout))
        let frenchLayout = ShortcutKeyboardLayout(shiftedCharacters: ["é": "2"])
        check("layouts with shifted digit keys can reach tab-number equivalents", AppPreferences.Shortcut(keyEquivalent: "é", modifierFlags: [.command, .shift]).isEquivalent(to: .init(keyEquivalent: "2", modifierFlags: .command), layout: frenchLayout))
        if shiftedEquals.isEquivalent(to: plus) {
            check("current layout conflicts with its actual Plus owner", store.validationError(shiftedEquals, for: ShortcutCatalog.filterID) != nil)
        }
        for action in actions {
            do {
                try store.set(nil, for: action.id)
                check("can clear \(action.id)", store.shortcut(for: action.id) == nil)
                try store.set(f8, for: action.id)
                check("can rebind \(action.id)", store.shortcut(for: action.id) == f8)
                try store.reset(action.id)
                check("can reset \(action.id)", store.shortcut(for: action.id) == action.defaultShortcut)
            } catch { check("catalog command edit failed: \(error.localizedDescription)", false) }
        }
        do {
            try store.set(f8, for: "menu.toggleTerminal")
            let restored = ShortcutStore(defaults: defaults)
            check("bindings persist across service instances", restored.shortcut(for: "menu.toggleTerminal") == f8)
            check("conflicts name the current owner", store.validationError(f8, for: "menu.toggleFoldersPanel")?.contains("Show Terminal") == true)
            try store.set(nil, for: "menu.toggleTerminal")
            check("cleared binding remains cleared after recreation", restored.shortcut(for: "menu.toggleTerminal") == nil)
            try store.set(.init(keyEquivalent: "\u{f707}", modifierFlags: []), for: "menu.toggleFoldersPanel")
            check("clearing a command frees its old key", restored.shortcut(for: "menu.toggleFoldersPanel")?.displayString == "F4")
            check("single reset rejects a newly occupied default", store.validationError(ShortcutCatalog.action("menu.toggleTerminal")?.defaultShortcut, for: "menu.toggleTerminal") != nil)
        } catch { check("persistence sequence: \(error)", false) }
        store.resetAll()
        defaults.set("i", forKey: "filterShortcutKey")
        defaults.set(NSEvent.ModifierFlags.control.rawValue, forKey: "filterShortcutModifiers")
        check("legacy filter configuration is migrated lazily", store.shortcut(for: ShortcutCatalog.filterID)?.displayString == "⌃I")
        try! store.set(.init(keyEquivalent: "j", modifierFlags: [.command, .control]), for: ShortcutCatalog.filterID)
        check("new map takes precedence over legacy values", store.shortcut(for: ShortcutCatalog.filterID)?.displayString == "⌃⌘J")
        store.resetAll()
        defaults.set(Data("{invalid json".utf8), forKey: ShortcutStore.defaultsKey)
        check("corrupt map falls back without rewriting its bytes", store.shortcut(for: ShortcutCatalog.filterID) == .defaultFilter && defaults.data(forKey: ShortcutStore.defaultsKey) == Data("{invalid json".utf8))
        defaults.set(Data("{\"menu.focusFilter\":{\"key\":\"q\",\"modifiers\":1048576},\"unknown.futureCommand\":{}}".utf8), forKey: ShortcutStore.defaultsKey)
        check("conflicting imported overrides cannot hijack Quit", store.shortcut(for: ShortcutCatalog.filterID) == .defaultFilter && store.shortcut(for: "menu.terminate")?.displayString == "⌘Q")
        store.resetAll()

        let settings = SettingsWindowController(preferences: preferences, workspaceStore: WorkspaceSessionStore(fileURL: nil))
        defer { settings.close() }
        settings.settingsTabs.selectTabViewItem(withIdentifier: "shortcuts")
        let page = settings.shortcutsController
        let selectedRect = page.tableView.rect(ofRow: page.tableView.selectedRow)
        check("initial Filter selection is visible when Shortcuts opens", page.selectedID == ShortcutCatalog.filterID
              && selectedRect.height > 0 && page.tableView.visibleRect.minY <= selectedRect.minY && page.tableView.visibleRect.maxY >= selectedRect.maxY)
        page.recorder.startRecording(nil)
        page.recorder.keyDown(with: event("", .function, 97))
        check("real F6 keyCode passes recorder validation and persists", store.shortcut(for: ShortcutCatalog.filterID)?.displayString == "F6" && !page.recorder.isRecording)
        page.resetButton.performClick(nil)
        page.selectAction("menu.toggleTerminal")
        check("settings exposes all commands in a dedicated tab", page.visibleActions.count == actions.count && settings.settingsTabs.selectedTabViewItem?.label == "Shortcuts")
        check("programmatic command selection survives table reload notifications", page.selectedID == "menu.toggleTerminal"
              && page.visibleActions.indices.contains(page.tableView.selectedRow) && page.visibleActions[page.tableView.selectedRow].id == "menu.toggleTerminal")
        let recorded = page.recorder.record(keyEquivalent: "\u{f70b}", modifierFlags: [])
        if !recorded || store.shortcut(for: "menu.toggleTerminal") != f8 {
            print("shortcut recorder diagnosis: selected=\(page.selectedID), accepted=\(recorded), message=\(page.message.stringValue), stored=\(store.shortcut(for: "menu.toggleTerminal")?.displayString ?? "none")")
        }
        check("recorder changes the selected command", recorded && store.shortcut(for: "menu.toggleTerminal") == f8)
        page.selectAction("menu.toggleFoldersPanel")
        check("recorder keeps a conflict inline", !page.recorder.record(keyEquivalent: "\u{f70b}", modifierFlags: []) && page.message.stringValue.contains("Show Terminal"))
        page.selectAction("menu.toggleTerminal")
        page.clearButton.performClick(nil)
        check("Clear removes the selected binding", store.shortcut(for: "menu.toggleTerminal") == nil && page.recorder.title == "Record Shortcut…")
        page.resetButton.performClick(nil)
        check("Reset restores the selected default", store.shortcut(for: "menu.toggleTerminal")?.displayString == "F4")
        page.filterCommands("folder view settings")
        check("search includes command categories", page.visibleActions.count == 4)
        page.filterCommands("a command that does not exist")
        check("empty search disables recording", page.visibleActions.isEmpty && !page.recorder.isEnabled)
        page.selectAction("menu.toggleTerminal")
        page.recorder.startRecording(nil)
        page.recorder.keyDown(with: event("\u{1b}", [], 53))
        check("Escape stops recording without changing the binding", !page.recorder.isRecording && store.shortcut(for: "menu.toggleTerminal")?.displayString == "F4")
        page.recorder.startRecording(nil)
        settings.settingsTabs.selectTabViewItem(withIdentifier: "terminal")
        check("switching Settings pages always stops recording", !page.recorder.isRecording)
        settings.settingsTabs.selectTabViewItem(withIdentifier: "shortcuts")
        settings.window?.contentView?.layoutSubtreeIfNeeded()
        if let content = settings.window?.contentView {
            check("shortcut controls fit inside Settings", [page.searchField, page.recorder, page.clearButton, page.resetAllButton].allSatisfy {
                content.bounds.contains($0.convert($0.bounds, to: content)) && $0.bounds.width > 30 && $0.bounds.height >= 14
            })
        }
    }

    @MainActor
    private static func routing() async {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: ShortcutStore.defaultsKey)
        let store = AppPreferences.shared.shortcuts
        let oldKey = NSApp.keyWindow
        defer {
            if let saved { defaults.set(saved, forKey: ShortcutStore.defaultsKey) }
            else { defaults.removeObject(forKey: ShortcutStore.defaultsKey) }
            if let menu = NSApp.mainMenu { MainMenu.applyPreferences(to: menu) }
            if oldKey?.isVisible == true { oldKey?.makeKeyAndOrderFront(nil) }
        }
        store.resetAll()
        let provider = SmokeFixtures.EmptyProvider()
        let pathBar = BreadcrumbBar(frame: .zero)
        let tabBar = TabBarView(frame: .zero)
        try! store.set(.init(keyEquivalent: "l", modifierFlags: [.command, .control]), for: "menu.editLocation")
        try! store.set(.init(keyEquivalent: "t", modifierFlags: [.command, .control]), for: "menu.newTab")
        check("open path and tab hints follow custom shortcuts", pathBar.textField.placeholderString == "Type a folder path — ⌃⌘L" && tabBar.newTabToolTipForTesting == "New Tab (⌃⌘T)")
        try! store.set(nil, for: "menu.editLocation")
        try! store.set(nil, for: "menu.newTab")
        check("cleared shortcuts disappear from path and tab hints", pathBar.textField.placeholderString == "Type a folder path" && tabBar.newTabToolTipForTesting == "New Tab")
        store.resetAll()
        let viewFile = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-shortcut-views-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: viewFile) }
        let controller = MainWindowController(provider: provider, places: PlacesModel(), initialURL: provider.homeURL,
                                              viewPropertiesStore: DirectoryViewPropertiesStore(fileURL: viewFile))
        defer { controller.close() }
        controller.window?.makeKeyAndOrderFront(nil)
        await loaded(controller.browser)
        controller.tabs.newTab(at: provider.homeURL)
        await loaded(controller.browser)
        controller.tabs.selectTab(at: 0)
        controller.window?.makeFirstResponder(controller.browser.focusView)
        try! store.set(.init(keyEquivalent: "j", modifierFlags: [.command, .control]), for: ShortcutCatalog.nextTabID)
        check("old Control Tab alias stops dispatching after rebind", !ShortcutDispatcher.handle(event("\t", .control, 48, controller.window), in: controller) && controller.tabs.currentIndex == 0)
        check("custom alias changes the selected real tab", ShortcutDispatcher.handle(event("j", [.command, .control], 38, controller.window), in: controller) && controller.tabs.currentIndex == 1)
        try! store.set(nil, for: "window.selectTab.1")
        check("cleared tab-number shortcut no longer selects a tab", !ShortcutDispatcher.handle(event("1", .command, 18, controller.window), in: controller) && controller.tabs.currentIndex == 1)
        try! store.set(.init(keyEquivalent: "3", modifierFlags: [.command, .option]), for: "menu.viewAsIcons")
        let menu = NSApp.mainMenu!
        let icons = find("menu.viewAsIcons", menu)
        check("real menu updates the assigned equivalent immediately", icons?.keyEquivalent == "3" && icons?.keyEquivalentModifierMask == [.command, .option])
        // Native menu actions use NSApp's responder chain, not the windowNumber
        // on a synthetic event. Reacquire it after asynchronous fixture loading.
        controller.browser.setViewMode(.details)
        focusNativeMenuWindow(controller, responder: controller.browser.focusView)
        icons?.menu?.update()
        let iconTarget = icons.flatMap { item in item.action.flatMap { NSApp.target(forAction: $0, to: item.target, from: item) } }
        if (iconTarget as AnyObject?) !== controller.browser { printMenuDiagnosis(icons, controller: controller) }
        check("native menu resolves the owned active pane", (iconTarget as AnyObject?) === controller.browser)
        let handledIcons = menu.performKeyEquivalent(with: event("3", [.command, .option], 20, controller.window))
        if !handledIcons || controller.browser.viewMode != .icons { printMenuDiagnosis(icons, controller: controller, handled: handledIcons) }
        check("native menu dispatch changes the active pane", handledIcons && controller.browser.viewMode == .icons)
        check("old menu equivalent stops dispatching", !menu.performKeyEquivalent(with: event("1", [.command, .option], 18, controller.window)))
        if let plusEvent = plusEvent(in: controller.window) {
            let before = controller.browser.zoomIndex
            check("native Plus menu dispatch follows the current layout", menu.performKeyEquivalent(with: plusEvent) && controller.browser.zoomIndex == before + 1)
        } else { check("current layout can generate the Plus shortcut", false) }
        try! store.set(.init(keyEquivalent: "\u{7f}", modifierFlags: .command), for: "menu.togglePreviews")
        let previousPreviews = controller.browser.showsPreviews
        check("physical Forward Delete dispatches a remapped native menu command", menu.performKeyEquivalent(with: event("\u{f728}", .command, 117, controller.window))
              && controller.browser.showsPreviews != previousPreviews)
        check("Fn Delete dispatches the same native menu command", menu.performKeyEquivalent(with: event("\u{f728}", [.command, .function], 51, controller.window))
              && controller.browser.showsPreviews == previousPreviews)
        try! store.set(nil, for: "menu.moveToTrash")
        check("physical Backspace cannot dispatch the Forward Delete binding", !menu.performKeyEquivalent(with: event("\u{7f}", .command, 51, controller.window))
              && controller.browser.showsPreviews == previousPreviews)
        try! store.reset("menu.moveToTrash")
        if let item = find("menu.togglePreviews", menu), let submenu = item.menu {
            let autoenables = submenu.autoenablesItems
            submenu.autoenablesItems = false
            item.isEnabled = false
            _ = menu.performKeyEquivalent(with: event("\u{f728}", .command, 117, controller.window))
            check("Forward Delete normalization respects disabled native menu items", !item.isEnabled
                  && controller.browser.showsPreviews == previousPreviews)
            item.isEnabled = true
            submenu.autoenablesItems = autoenables
        } else { check("Forward Delete command has a native menu item", false) }
        try! store.reset("menu.togglePreviews")
        try! store.set(.init(keyEquivalent: "\u{f70b}", modifierFlags: []), for: "menu.showInspector")
        check("custom Inspector binding becomes a visible standalone menu row", find("menu.showInspector", menu)?.isAlternate == false)
        check("Summary also becomes standalone when Inspector breaks its alternate group", find("menu.getSummaryInfo", menu)?.isAlternate == false)
        try! store.set(nil, for: "menu.showInspector")
        check("cleared Inspector cannot hide Summary behind an unrelated base row", find("menu.getSummaryInfo", menu)?.isAlternate == false)
        try! store.reset("menu.showInspector")
        check("reset restores the contiguous Info alternate group", find("menu.showInspector", menu)?.isAlternate == true && find("menu.getSummaryInfo", menu)?.isAlternate == true)

        controller.toggleSplit(nil)
        await loaded(controller.browser)
        let inactive = controller.tabs.currentPage.inactive!
        for mode: ViewMode in [.details, .icons] {
            controller.browser.setViewMode(mode)
            controller.window?.makeFirstResponder(controller.browser.focusView)
            var renames = 0
            var previews = 0
            let browser = controller.browser
            if mode == .details {
                browser.fileList.tableView.onReturn = { renames += 1 }
                browser.fileList.tableView.onSpace = { previews += 1 }
            } else {
                browser.iconGrid.collectionView.onReturn = { renames += 1 }
                browser.iconGrid.collectionView.onSpace = { previews += 1 }
            }
            try! store.set(.init(keyEquivalent: "\u{f705}", modifierFlags: []), for: ShortcutCatalog.renameID)
            try! store.set(.init(keyEquivalent: "\u{f706}", modifierFlags: []), for: ShortcutCatalog.previewID)
            browser.fileView.forwardKey(event("\u{f705}", [], 120, controller.window))
            browser.fileView.forwardKey(event("\u{f706}", [], 99, controller.window))
            check("\(mode) receives remapped Rename and Quick Look keys", renames == 1 && previews == 1)
            browser.fileView.forwardKey(event("\r", [], 36, controller.window))
            browser.fileView.forwardKey(event(" ", [], 49, controller.window))
            check("\(mode) no longer invokes old Return and Space callbacks", renames == 1 && previews == 1)
            check("\(mode) retains the other pane and tab context", controller.tabs.currentIndex == 1 && controller.tabs.currentPage.inactive === inactive)
        }
        try! store.set(.init(keyEquivalent: "i", modifierFlags: .control), for: ShortcutCatalog.filterID)
        let text = KeySink(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        controller.window?.contentView?.addSubview(text)
        controller.window?.makeFirstResponder(text)
        check("Control-only application binding reaches text input unchanged", ShortcutDispatcher.handle(event("i", .control, 34, controller.window), in: controller) && text.received == 1 && controller.window?.firstResponder === text)
        try! store.set(.init(keyEquivalent: "\u{7f}", modifierFlags: .control), for: "menu.reload")
        check("Control Forward Delete keeps the original text-input event", ShortcutDispatcher.protectInput(event("\u{f728}", .control, 117, controller.window))
              && text.received == 2 && controller.window?.firstResponder === text)
        try! store.reset("menu.reload")
        let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        editorWindow.isReleasedWhenClosed = false
        let otherEditor = KeySink(frame: NSRect(x: 0, y: 0, width: 250, height: 60))
        editorWindow.contentView?.addSubview(otherEditor)
        editorWindow.makeFirstResponder(otherEditor)
        check("input protection also covers non-browser windows", ShortcutDispatcher.protectInput(event("i", .control, 34, editorWindow)) && otherEditor.received == 1)
        editorWindow.close()
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        controller.window?.contentView?.addSubview(terminal)
        controller.window?.makeFirstResponder(terminal)
        check("real SwiftTerm receives Control input while retaining focus", ShortcutDispatcher.protectInput(event("i", .control, 34, controller.window)) && controller.window?.firstResponder === terminal)
        check("terminal toggle remains available while the shell has focus", !ShortcutDispatcher.protectInput(event("\u{f707}", [], 118, controller.window)))
        check("Command editing shortcuts retain normal responder-chain dispatch", !ShortcutDispatcher.protectInput(event("c", .command, 8, controller.window)))
        terminal.removeFromSuperview()
        focusNativeMenuWindow(controller, responder: text)
        try! store.set(.init(keyEquivalent: "j", modifierFlags: [.command, .option]), for: ShortcutCatalog.filterID)
        check("Command shortcut dispatch from text fields still reaches the app", menu.performKeyEquivalent(with: event("j", [.command, .option], 38, controller.window)) && controller.window?.firstResponder !== text)
        text.removeFromSuperview()
        store.resetAll()
    }

    @MainActor
    private static func focusNativeMenuWindow(_ controller: MainWindowController, responder: NSResponder) {
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeMain()
        check("native menu fixture owns its requested first responder", controller.window?.makeFirstResponder(responder) == true
            && controller.window?.firstResponder === responder)
    }

    @MainActor
    private static func printMenuDiagnosis(_ item: NSMenuItem?, controller: MainWindowController, handled: Bool? = nil) {
        let target = item.flatMap { item in item.action.flatMap { NSApp.target(forAction: $0, to: item.target, from: item) } }
        print("shortcut menu diagnosis: handled=\(String(describing: handled)), active=\(NSApp.isActive), key=\(NSApp.keyWindow?.windowNumber ?? -1), main=\(NSApp.mainWindow?.windowNumber ?? -1), expected=\(controller.window?.windowNumber ?? -1), fileFocus=\(controller.window?.firstResponder === controller.browser.focusView), target=\(String(describing: target.map { type(of: $0) })), targetIsBrowser=\((target as AnyObject?) === controller.browser), enabled=\(item?.isEnabled == true), mode=\(controller.browser.viewMode)")
    }

    private static func event(_ key: String, _ modifiers: NSEvent.ModifierFlags, _ code: UInt16, _ window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: window?.windowNumber ?? 0, context: nil, characters: key,
                        charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
    }
    private static func plusEvent(in window: NSWindow?) -> NSEvent? {
        let plus = AppPreferences.Shortcut(keyEquivalent: "+", modifierFlags: .command)
        for code in UInt16(0)...127 {
            for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
                let probe = event("x", modifiers, code, window)
                guard AppPreferences.Shortcut.from(probe).isEquivalent(to: plus),
                      let character = probe.characters(byApplyingModifiers: modifiers.subtracting(.command)) else { continue }
                return event(character, modifiers, code, window)
            }
        }
        return nil
    }
    private static func find(_ id: String, _ menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier?.rawValue == id { return item }
            if let submenu = item.submenu, let found = find(id, submenu) { return found }
        }
        return nil
    }
    @MainActor private static func loaded(_ browser: BrowserViewController) async {
        await expectEventually("fixture loaded") { browser.model.generation > 0 }
    }
    private final class KeySink: NSTextView {
        var received = 0
        override func keyDown(with event: NSEvent) { received += 1 }
    }
}

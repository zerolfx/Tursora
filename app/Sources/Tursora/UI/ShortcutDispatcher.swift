import AppKit
import SwiftTerm

/// Menu commands continue through AppKit's validation/responder chain. This
/// dispatcher covers aliases and contextual keys that a menu cannot express.
enum ShortcutDispatcher {
    private static var inputMonitor: Any?

    static func installInputProtection() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            protectInput(event) ? nil : event
        }
    }

    /// Applies to Info and Settings field editors too, not only browser windows.
    @discardableResult
    static func protectInput(_ event: NSEvent, store: ShortcutStore = AppPreferences.shared.shortcuts) -> Bool {
        guard !event.modifierFlags.contains(.command), let responder = event.window?.firstResponder,
              responder is NSTextView || responder is NSTextField || responder is TerminalView else { return false }
        let bindings = store.bindings
        guard let action = ShortcutCatalog.actions.first(where: {
            bindings[$0.id].map { matches($0, event: event) } ?? false
        }), action.id != "menu.toggleTerminal" else { return false }
        // Calling keyDown directly bypasses the menu equivalent without changing
        // the text system's own completion, selection or terminal input handling.
        responder.keyDown(with: event)
        return true
    }

    static func matches(_ shortcut: AppPreferences.Shortcut, event: NSEvent) -> Bool {
        shortcut.isEquivalent(to: AppPreferences.Shortcut.from(event))
    }

    static func handleFileView(_ event: NSEvent, store: ShortcutStore = AppPreferences.shared.shortcuts,
                               onRename: (() -> Void)?, onQuickLook: (() -> Void)?) -> Bool {
        let bindings = store.bindings
        if let shortcut = bindings[ShortcutCatalog.renameID], matches(shortcut, event: event) { onRename?(); return true }
        if let shortcut = bindings[ShortcutCatalog.previewID], matches(shortcut, event: event) { onQuickLook?(); return true }
        return false
    }

    static func handle(_ event: NSEvent, in controller: MainWindowController,
                       store: ShortcutStore = AppPreferences.shared.shortcuts) -> Bool {
        guard event.window === controller.window else { return false }
        let responder = controller.window?.firstResponder
        guard !(responder is ShortcutRecorderButton) else { return false }
        let bindings = store.bindings
        guard let action = ShortcutCatalog.actions.first(where: {
            bindings[$0.id].map { matches($0, event: event) } ?? false
        }) else { return false }
        let inFileView = responder === controller.browser.focusView
        if protectInput(event, store: store) { return true }
        if action.context == .fileView && !inFileView { return false }
        switch action.id {
        case ShortcutCatalog.renameID, ShortcutCatalog.previewID:
            return handleFileView(event, store: store,
                onRename: { controller.browser.renameSelectionInline(nil) },
                onQuickLook: { controller.browser.quickLook(nil) })
        case ShortcutCatalog.cancelArchiveID:
            guard controller.browser.isPreparingArchive else { return false }
            controller.browser.cancelArchiveOpening(nil)
        case ShortcutCatalog.nextTabID: controller.tabs.selectNext()
        case ShortcutCatalog.previousTabID: controller.tabs.selectPrevious()
        case ShortcutCatalog.zoomInID: controller.browser.zoomIn(nil)
        default:
            guard action.id.hasPrefix("window.selectTab."), let number = Int(action.id.split(separator: ".").last!) else {
                return false // Native menu dispatch, including disabled actions.
            }
            let index = number == 9 ? controller.tabs.count - 1 : number - 1
            if index < controller.tabs.count { controller.tabs.selectTab(at: index) }
        }
        return true
    }
}

import AppKit

extension Notification.Name {
    static let tursoraPreferencesChanged = Notification.Name("Tursora.preferencesChanged")
}

/// Application settings are separate from per-pane view and navigation state.
enum AppPreferences {
    static let shared = Store()

    static var showFileExtensions: Bool {
        get { shared.showFileExtensions }
        set { shared.showFileExtensions = newValue }
    }
    static var restoreWorkspaceOnLaunch: Bool {
        get { shared.restoreWorkspaceOnLaunch }
        set { shared.restoreWorkspaceOnLaunch = newValue }
    }
    static var experimentalTerminalEnabled: Bool {
        get { shared.experimentalTerminalEnabled }
        set { shared.experimentalTerminalEnabled = newValue }
    }
    static var experimentalZIPBrowsingEnabled: Bool {
        get { shared.experimentalZIPBrowsingEnabled }
        set { shared.experimentalZIPBrowsingEnabled = newValue }
    }
    static var filterShortcut: Shortcut { shared.filterShortcut }

    struct Shortcut: Equatable {
        let keyEquivalent: String
        let modifierFlags: NSEvent.ModifierFlags
        static let defaultFilter = Shortcut(keyEquivalent: "f", modifierFlags: .command)
        static let supportedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

        init(keyEquivalent: String, modifierFlags: NSEvent.ModifierFlags) {
            var modifiers = modifierFlags.intersection(Self.supportedModifiers)
            let key = keyEquivalent == "\u{f728}" ? "\u{7f}" : keyEquivalent.lowercased()
            if keyEquivalent.lowercased() != keyEquivalent { modifiers.insert(.shift) }
            self.keyEquivalent = key
            self.modifierFlags = modifiers
        }

        var displayString: String {
            var result = ""
            for (flag, symbol): (NSEvent.ModifierFlags, String) in [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] {
                if modifierFlags.contains(flag) { result += symbol }
            }
            let names = ["\r": "↩", "\t": "⇥", " ": "Space", "\u{1b}": "Esc", "\u{8}": "⌫", "\u{7f}": "⌦",
                         "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→", "\u{f728}": "⌦",
                         "\u{f729}": "Home", "\u{f72b}": "End", "\u{f72c}": "Page Up", "\u{f72d}": "Page Down", "\u{f746}": "Help"]
            if let scalar = keyEquivalent.unicodeScalars.first, (0xf704...0xf726).contains(scalar.value) {
                return result + "F" + String(scalar.value - 0xf703)
            }
            return result + (names[keyEquivalent] ?? keyEquivalent.uppercased())
        }

        /// Compatibility validation for the original filter-only API. The full
        /// settings UI validates against the user's current complete catalog.
        func validationError(in menu: NSMenu? = nil) -> String? {
            if let error = syntaxError(context: .application) { return error }
            if let reserved = ShortcutCatalog.systemConflict(self) { return reserved }
            if let conflict = ShortcutCatalog.actions.first(where: { $0.id != ShortcutCatalog.filterID && $0.defaultShortcut?.isEquivalent(to: self) == true }) {
                return "\(displayString) is already used for \(conflict.title). Choose another shortcut."
            }
            if let menu, let title = conflictingMenuTitle(in: menu) {
                return "\(displayString) is already used for \(title). Choose another shortcut."
            }
            return nil
        }

        private func conflictingMenuTitle(in menu: NSMenu) -> String? {
            for item in menu.items {
                if let submenu = item.submenu, let title = conflictingMenuTitle(in: submenu) { return title }
                guard !item.keyEquivalent.isEmpty, item.action != Selector(("focusFilter:")) else { continue }
                if Shortcut(keyEquivalent: item.keyEquivalent, modifierFlags: item.keyEquivalentModifierMask).isEquivalent(to: self) {
                    return item.title
                }
            }
            return nil
        }
    }

    struct PreferenceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    final class Store {
        private enum Key {
            static let extensions = "showFileExtensions"
            static let workspace = "restoreWorkspaceOnLaunch"
            static let terminal = "experimentalTerminalEnabled"
            static let zip = "experimentalZIPBrowsingEnabled"
            static let shortcutKey = "filterShortcutKey"
            static let shortcutModifiers = "filterShortcutModifiers"
        }
        private let defaults: UserDefaults
        let shortcuts: ShortcutStore
        let notificationCenter: NotificationCenter

        init(defaults: UserDefaults = AppDefaults.shared, notificationCenter: NotificationCenter = .default) {
            self.defaults = defaults
            self.notificationCenter = notificationCenter
            self.shortcuts = ShortcutStore(defaults: defaults, notificationCenter: notificationCenter)
        }

        var showFileExtensions: Bool {
            get { defaults.object(forKey: Key.extensions) == nil ? true : defaults.bool(forKey: Key.extensions) }
            set { set(newValue, forKey: Key.extensions, oldValue: showFileExtensions) }
        }
        var restoreWorkspaceOnLaunch: Bool {
            get { defaults.object(forKey: Key.workspace) == nil ? true : defaults.bool(forKey: Key.workspace) }
            set { set(newValue, forKey: Key.workspace, oldValue: restoreWorkspaceOnLaunch) }
        }
        var experimentalTerminalEnabled: Bool {
            get { defaults.object(forKey: Key.terminal) == nil ? true : defaults.bool(forKey: Key.terminal) }
            set { set(newValue, forKey: Key.terminal, oldValue: experimentalTerminalEnabled) }
        }
        var experimentalZIPBrowsingEnabled: Bool {
            get { defaults.object(forKey: Key.zip) == nil ? true : defaults.bool(forKey: Key.zip) }
            set { set(newValue, forKey: Key.zip, oldValue: experimentalZIPBrowsingEnabled) }
        }
        var filterShortcut: Shortcut {
            shortcuts.shortcut(for: ShortcutCatalog.filterID) ?? Shortcut(keyEquivalent: "", modifierFlags: [])
        }

        func setFilterShortcut(_ shortcut: Shortcut, menu: NSMenu? = nil) throws {
            let previous = filterShortcut
            try shortcuts.set(shortcut, for: ShortcutCatalog.filterID, menu: menu)
            if previous != filterShortcut { notificationCenter.post(name: .tursoraPreferencesChanged, object: self) }
        }

        func resetFilterShortcut() {
            let changed = shortcuts.shortcut(for: ShortcutCatalog.filterID) != .defaultFilter
            defaults.removeObject(forKey: Key.shortcutKey)
            defaults.removeObject(forKey: Key.shortcutModifiers)
            try? shortcuts.reset(ShortcutCatalog.filterID)
            if changed { notificationCenter.post(name: .tursoraPreferencesChanged, object: self) }
        }

        private func set(_ value: Bool, forKey key: String, oldValue: Bool) {
            // Record explicit choices even when they match today's default.
            // Future default changes must not overwrite that intent.
            if defaults.object(forKey: key) == nil || defaults.bool(forKey: key) != value {
                defaults.set(value, forKey: key)
            }
            if oldValue != value { notify() }
        }
        private func notify() { notificationCenter.post(name: .tursoraPreferencesChanged, object: self) }
    }
}

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
            let key = keyEquivalent.lowercased()
            if key != keyEquivalent { modifiers.insert(.shift) }
            self.keyEquivalent = key
            self.modifierFlags = modifiers
        }

        var displayString: String {
            var result = ""
            for (flag, symbol): (NSEvent.ModifierFlags, String) in [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] {
                if modifierFlags.contains(flag) { result += symbol }
            }
            return result + keyEquivalent.uppercased()
        }

        func validationError(in menu: NSMenu? = nil) -> String? {
            guard keyEquivalent.count == 1, let character = keyEquivalent.first,
                  "abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./+".contains(character) else {
                return "Use a letter, number or punctuation key with Command or Control."
            }
            guard modifierFlags.contains(.command) || modifierFlags.contains(.control) else {
                return "Include Command or Control so ordinary typing still works. Option and Shift can be added."
            }
            if let command = Self.reserved.first(where: { $0.shortcut == self })?.title {
                return "\(displayString) is already used for \(command). Choose another shortcut."
            }
            if let menu, let command = conflictingMenuTitle(in: menu) {
                return "\(displayString) is already used for \(command). Choose another shortcut."
            }
            return nil
        }

        private func conflictingMenuTitle(in menu: NSMenu) -> String? {
            for item in menu.items {
                if let submenu = item.submenu, let title = conflictingMenuTitle(in: submenu) { return title }
                guard !item.keyEquivalent.isEmpty, item.action != Selector(("focusFilter:")) else { continue }
                if Shortcut(keyEquivalent: item.keyEquivalent, modifierFlags: item.keyEquivalentModifierMask) == self {
                    return item.title
                }
            }
            return nil
        }

        /// Includes monitor-only bindings and future menu entries (Settings),
        /// so validation also works before NSApp has built its main menu.
        private static var reserved: [(shortcut: Shortcut, title: String)] {
            var entries: [(Shortcut, String)] = []
            func add(_ keys: String, _ modifiers: NSEvent.ModifierFlags, _ title: String) {
                entries += keys.map { (Shortcut(keyEquivalent: String($0), modifierFlags: modifiers), title) }
            }
            add("hqntyidwxczvarlkm,[]-+=0123456789", .command, "an existing app command")
            add("nwtzcmdphgf.[]", [.command, .shift], "an existing app command")
            add("hi12", [.command, .option], "an existing app command")
            add("is01234567", [.command, .control], "an existing app command")
            add("=", [.command, .shift], "Zoom In")
            add("`", .command, "Cycle Windows")
            add("`", [.command, .shift], "Cycle Windows")
            add("/", [.command, .shift], "Help")
            add("q", [.command, .control], "Lock Screen")
            return entries
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
        let notificationCenter: NotificationCenter

        init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
            self.defaults = defaults
            self.notificationCenter = notificationCenter
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
            guard let key = defaults.string(forKey: Key.shortcutKey),
                  let raw = defaults.object(forKey: Key.shortcutModifiers) as? NSNumber else { return .defaultFilter }
            let shortcut = Shortcut(keyEquivalent: key, modifierFlags: NSEvent.ModifierFlags(rawValue: raw.uintValue))
            return shortcut.validationError() == nil ? shortcut : .defaultFilter
        }

        func setFilterShortcut(_ shortcut: Shortcut, menu: NSMenu? = nil) throws {
            if let error = shortcut.validationError(in: menu) { throw PreferenceError(message: error) }
            guard shortcut != filterShortcut else { return }
            defaults.set(shortcut.keyEquivalent, forKey: Key.shortcutKey)
            defaults.set(shortcut.modifierFlags.rawValue, forKey: Key.shortcutModifiers)
            notify()
        }

        func resetFilterShortcut() {
            let changed = filterShortcut != .defaultFilter
            defaults.removeObject(forKey: Key.shortcutKey)
            defaults.removeObject(forKey: Key.shortcutModifiers)
            if changed { notify() }
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

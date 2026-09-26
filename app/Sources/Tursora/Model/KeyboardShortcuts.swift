import AppKit
import Carbon

extension Notification.Name {
    static let tursoraShortcutsChanged = Notification.Name("Tursora.shortcutsChanged")
}

enum ShortcutContext { case application, fileView }

struct ShortcutAction {
    let id: String
    let title: String
    let category: String
    let selector: String?
    let representedObject: String?
    let defaultShortcut: AppPreferences.Shortcut?
    let context: ShortcutContext
}

enum ShortcutCatalog {
    static let filterID = "menu.focusFilter"
    static let renameID = "file.rename"
    static let openID = "file.open"
    static let previewID = "file.quickLook"
    static let cancelArchiveID = "file.cancelArchiveOpening"
    static let nextTabID = "window.nextTabAlternative"
    static let previousTabID = "window.previousTabAlternative"
    static let zoomInID = "file.zoomInAlternative"

    static let actions: [ShortcutAction] = {
        var items = MainMenu.shortcutDefinitions()
        func add(_ id: String, _ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags,
                 context: ShortcutContext = .application) {
            items.append(ShortcutAction(id: id, title: title, category: context == .fileView ? "File View" : "Window",
                selector: nil, representedObject: nil, defaultShortcut: .init(keyEquivalent: key, modifierFlags: modifiers),
                context: context))
        }
        add(renameID, "Rename (Return / Enter)", "\r", [], context: .fileView)
        // Ships unbound. Finder's Return renames and ⌘↓ opens (D3); Windows
        // Explorer and Dolphin open on Return, and this row is how a user who
        // wants that swaps them. Kept after renameID so Rename still wins a
        // hand-edited override map that put Return on both.
        items.append(ShortcutAction(id: openID, title: "Open Selection (Alternative)", category: "File View",
            selector: nil, representedObject: nil, defaultShortcut: nil, context: .fileView))
        add(previewID, "Quick Look (Space)", " ", [], context: .fileView)
        add(cancelArchiveID, "Cancel Opening Archive", "\u{1b}", [], context: .fileView)
        add(nextTabID, "Next Tab (Alternative)", "\t", .control)
        add(previousTabID, "Previous Tab (Alternative)", "\t", [.control, .shift])
        add(zoomInID, "Zoom In (Alternative)", "=", .command)
        for number in 1...9 {
            add("window.selectTab.\(number)", number == 9 ? "Select Last Tab" : "Select Tab \(number)", String(number), .command)
        }
        return items
    }()

    static func action(_ id: String) -> ShortcutAction? { actions.first { $0.id == id } }

    static func systemConflict(_ shortcut: AppPreferences.Shortcut) -> String? {
        let reserved: [(String, NSEvent.ModifierFlags)] = [
            ("`", .command), ("`", [.command, .shift]), ("/", [.command, .shift]),
            ("q", [.command, .control]), (" ", .command), (" ", .control),
        ]
        return reserved.contains { AppPreferences.Shortcut(keyEquivalent: $0.0, modifierFlags: $0.1).isEquivalent(to: shortcut) }
            ? "\(shortcut.displayString) is reserved by macOS. Choose another shortcut." : nil
    }
}

extension AppPreferences.Shortcut {
    func syntaxError(context: ShortcutContext) -> String? {
        guard keyEquivalent.count == 1, let scalar = keyEquivalent.unicodeScalars.first,
              scalar.value >= 32 || [8, 9, 13, 27].contains(scalar.value), scalar.value != 0xfffd else {
            return "Press one key with optional Command, Control, Option or Shift modifiers."
        }
        let function = (UInt32(NSF1FunctionKey)...UInt32(NSF35FunctionKey)).contains(scalar.value)
        let contextualKey = ["\r", "\t", " ", "\u{1b}"].contains(keyEquivalent)
        if !modifierFlags.contains(.command) && !modifierFlags.contains(.control) && !function {
            guard context == .fileView && contextualKey || keyEquivalent == "\t" && modifierFlags == .option else {
                return "Include Command or Control, or use a function key. Bare Return, Space and Escape are limited to File View commands."
            }
        }
        return nil
    }

    static func from(_ event: NSEvent) -> Self {
        let key = keyEquivalent(keyCode: event.keyCode,
            translated: event.characters(byApplyingModifiers: []),
            reported: event.charactersIgnoringModifiers, characters: event.characters)
        return Self(keyEquivalent: key, modifierFlags: event.modifierFlags)
    }

    static func keyEquivalent(keyCode: UInt16, translated: String?, reported: String?, characters: String?) -> String {
        // Fn-Delete can retain the Backspace hardware code while reporting the
        // forward-delete function character. Its reported meaning takes priority.
        if reported == "\u{f728}" || characters == "\u{f728}" { return "\u{7f}" }
        if let key = specialKeyEquivalents[Int(keyCode)] { return key }
        // Function-key text may be absent, or translation may return an empty
        // string rather than nil. A reported AppKit special character wins over
        // printable-layout retranslation; it is not an ordinary layout letter.
        if let reported, reported.unicodeScalars.count == 1,
           let scalar = reported.unicodeScalars.first, (0xf700...0xf8ff).contains(scalar.value) { return reported }
        return [translated, reported, characters].compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    static func eventForMenu(_ event: NSEvent) -> NSEvent {
        guard event.type == .keyDown || event.type == .keyUp else { return event }
        let key = keyEquivalent(keyCode: event.keyCode, translated: nil,
            reported: event.charactersIgnoringModifiers, characters: event.characters)
        guard key == "\u{8}" || key == "\u{7f}",
              event.characters != key || event.charactersIgnoringModifiers != key else { return event }
        return NSEvent.keyEvent(with: event.type, location: event.locationInWindow,
            modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber,
            context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    /// HIToolbox Events.h explicitly identifies these virtual keys as layout
    /// independent. Only printable keys use the current input source's mapping.
    private static let specialKeyEquivalents: [Int: String] = {
        var keys: [Int: String] = [kVK_Return: "\r", kVK_ANSI_KeypadEnter: "\r", kVK_Tab: "\t",
            kVK_Space: " ", kVK_Delete: "\u{8}", kVK_ForwardDelete: "\u{7f}", kVK_Escape: "\u{1b}"]
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, keyCode) in functions.enumerated() { keys[keyCode] = String(UnicodeScalar(NSF1FunctionKey + index)!) }
        for (keyCode, character) in [(kVK_LeftArrow, NSLeftArrowFunctionKey), (kVK_RightArrow, NSRightArrowFunctionKey),
            (kVK_UpArrow, NSUpArrowFunctionKey), (kVK_DownArrow, NSDownArrowFunctionKey),
            (kVK_Home, NSHomeFunctionKey), (kVK_End, NSEndFunctionKey),
            (kVK_PageUp, NSPageUpFunctionKey), (kVK_PageDown, NSPageDownFunctionKey), (kVK_Help, NSHelpFunctionKey)] {
            keys[keyCode] = String(UnicodeScalar(character)!)
        }
        return keys
    }()
}

/// One versioned map distinguishes an absent override (default) from a cleared
/// binding. Reads tolerate unknown future IDs and reject corrupt/conflicting
/// entries without executing unexpected commands or rewriting the user's data.
final class ShortcutStore {
    static let defaultsKey = "keyboardShortcutOverrides.v1"
    private let defaults: UserDefaults
    let notificationCenter: NotificationCenter
    private struct Binding: Codable {
        let key: String?
        let modifiers: UInt?
        var shortcut: AppPreferences.Shortcut? {
            guard let key, let modifiers else { return nil }
            return .init(keyEquivalent: key, modifierFlags: .init(rawValue: modifiers))
        }
        init(_ shortcut: AppPreferences.Shortcut?) {
            key = shortcut?.keyEquivalent
            modifiers = shortcut?.modifierFlags.rawValue
        }
    }

    init(defaults: UserDefaults = AppDefaults.shared, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    private var overrides: [String: Binding] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? JSONDecoder().decode([String: Binding].self, from: data) else { return [:] }
        return entries
    }

    var bindings: [String: AppPreferences.Shortcut] {
        var result: [String: AppPreferences.Shortcut] = [:]
        var accepted = Set<String>()
        let entries = overrides
        for action in ShortcutCatalog.actions {
            if let entry = entries[action.id] {
                if let shortcut = entry.shortcut {
                    if shortcut.syntaxError(context: action.context) == nil && ShortcutCatalog.systemConflict(shortcut) == nil {
                        result[action.id] = shortcut
                        accepted.insert(action.id)
                    } else { result[action.id] = action.defaultShortcut }
                } else if entry.key == nil && entry.modifiers == nil { accepted.insert(action.id) }
                else { result[action.id] = action.defaultShortcut }
            } else { result[action.id] = action.defaultShortcut }
        }
        if entries[ShortcutCatalog.filterID] == nil,
           let key = defaults.string(forKey: "filterShortcutKey"),
           let modifiers = defaults.object(forKey: "filterShortcutModifiers") as? NSNumber {
            let legacy = AppPreferences.Shortcut(keyEquivalent: key, modifierFlags: .init(rawValue: modifiers.uintValue))
            if legacy.validationError() == nil {
                result[ShortcutCatalog.filterID] = legacy
                accepted.insert(ShortcutCatalog.filterID)
            }
        }
        // A malformed imported map must not create ambiguous dispatch. Revert
        // conflicting overrides together, then recheck collisions with defaults.
        while true {
            let conflicts = accepted.filter { id in
                guard let value = result[id] else { return false }
                return result.contains { $0.key != id && $0.value.isEquivalent(to: value) }
            }
            if conflicts.isEmpty { break }
            for id in conflicts {
                result[id] = ShortcutCatalog.action(id)?.defaultShortcut
                accepted.remove(id)
            }
        }
        return result
    }

    func shortcut(for id: String) -> AppPreferences.Shortcut? { bindings[id] }

    func validationError(_ shortcut: AppPreferences.Shortcut?, for id: String, menu: NSMenu? = nil) -> String? {
        guard let action = ShortcutCatalog.action(id) else { return "This command is unavailable." }
        guard let shortcut else { return nil }
        if let error = shortcut.syntaxError(context: action.context) { return error }
        if let error = ShortcutCatalog.systemConflict(shortcut) { return error }
        if let conflict = bindings.first(where: { $0.key != id && $0.value.isEquivalent(to: shortcut) }),
           let other = ShortcutCatalog.action(conflict.key) {
            return "\(shortcut.displayString) is already used for \(other.category) → \(other.title). Clear or change that shortcut first."
        }
        func externalConflict(_ menu: NSMenu) -> String? {
            for item in menu.items {
                if let submenu = item.submenu, let error = externalConflict(submenu) { return error }
                guard item.action != nil, item.identifier.flatMap({ ShortcutCatalog.action($0.rawValue) }) == nil,
                      NSStringFromSelector(item.action!) != ShortcutCatalog.action(id)?.selector,
                      !item.keyEquivalent.isEmpty else { continue }
                if AppPreferences.Shortcut(keyEquivalent: item.keyEquivalent, modifierFlags: item.keyEquivalentModifierMask).isEquivalent(to: shortcut) {
                    return "\(shortcut.displayString) is already used for \(item.title). Choose another shortcut."
                }
            }
            return nil
        }
        return menu.flatMap(externalConflict)
    }

    func set(_ shortcut: AppPreferences.Shortcut?, for id: String, menu: NSMenu? = nil) throws {
        if let error = validationError(shortcut, for: id, menu: menu) { throw AppPreferences.PreferenceError(message: error) }
        guard self.shortcut(for: id) != shortcut else { return }
        var entries = overrides
        entries[id] = Binding(shortcut)
        try save(entries)
    }

    func reset(_ id: String) throws {
        guard let action = ShortcutCatalog.action(id) else { return }
        if let error = validationError(action.defaultShortcut, for: id) { throw AppPreferences.PreferenceError(message: error) }
        var entries = overrides
        entries.removeValue(forKey: id)
        if id == ShortcutCatalog.filterID {
            defaults.removeObject(forKey: "filterShortcutKey")
            defaults.removeObject(forKey: "filterShortcutModifiers")
        }
        try save(entries)
    }

    func resetAll() {
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: "filterShortcutKey")
        defaults.removeObject(forKey: "filterShortcutModifiers")
        didChange()
    }

    private func save(_ entries: [String: Binding]) throws {
        defaults.set(try JSONEncoder().encode(entries), forKey: Self.defaultsKey)
        didChange()
    }

    func keyboardLayoutDidChange() { didChange() }

    private func didChange() {
        notificationCenter.post(name: .tursoraShortcutsChanged, object: self)
        if self === AppPreferences.shared.shortcuts, let menu = NSApp.mainMenu {
            MainMenu.applyPreferences(to: menu, shortcuts: self)
        }
    }
}

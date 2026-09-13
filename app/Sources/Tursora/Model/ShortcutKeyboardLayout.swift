import AppKit

/// Resolves equivalent physical combinations without rewriting persisted keys.
/// A literal '+' remains '+' on layouts where it is an unshifted key; only the
/// current layout can say whether Shift–Equals produces the same character.
struct ShortcutKeyboardLayout {
    let shiftedCharacters: [String: String]

    func canonical(_ shortcut: AppPreferences.Shortcut) -> AppPreferences.Shortcut {
        guard shortcut.modifierFlags.contains(.shift),
              let shifted = shiftedCharacters[shortcut.keyEquivalent], shifted != shortcut.keyEquivalent else { return shortcut }
        return .init(keyEquivalent: shifted, modifierFlags: shortcut.modifierFlags.subtracting(.shift))
    }

    static var current: ShortcutKeyboardLayout { Current.shared.layout }

    private static func capture() -> ShortcutKeyboardLayout {
        var characters: [String: String] = [:]
        for keyCode in UInt16(0)...127 {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: keyCode),
                  let base = event.characters(byApplyingModifiers: []), base.count == 1,
                  let shifted = event.characters(byApplyingModifiers: .shift), shifted.count == 1,
                  base != shifted else { continue }
            // Prefer the first ordinary key over keypad duplicates.
            if characters[base] == nil { characters[base] = shifted }
        }
        return ShortcutKeyboardLayout(shiftedCharacters: characters)
    }

    private final class Current {
        static let shared = Current()
        var layout = ShortcutKeyboardLayout.capture()
        private var observer: NSObjectProtocol?
        init() {
            observer = NotificationCenter.default.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                    self?.layout = ShortcutKeyboardLayout.capture()
                    AppPreferences.shared.shortcuts.keyboardLayoutDidChange()
                }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

extension AppPreferences.Shortcut {
    func isEquivalent(to other: Self, layout: ShortcutKeyboardLayout = .current) -> Bool {
        self == other || layout.canonical(self) == layout.canonical(other)
    }
}

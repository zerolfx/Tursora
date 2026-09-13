import AppKit

extension Notification.Name {
    static let tursoraTerminalPreferencesChanged = Notification.Name("Tursora.terminalPreferencesChanged")
}

/// Terminal preferences are application-wide; neither navigation nor a settings
/// edit writes shell input. Store validation and launch validation are separate
/// because an executable can disappear after the preference was saved.
enum TerminalPreferences {
    static let shared = Store()
    static let storageKey = "terminalPreferences.v1"

    enum ShellMode: String, Codable, CaseIterable { case system, custom }
    enum Theme: String, Codable, CaseIterable {
        case system, dark, light, custom
        var title: String {
            switch self {
            case .system: return "Follow Appearance"
            case .dark: return "Dark"
            case .light: return "Light"
            case .custom: return "Custom"
            }
        }
    }

    struct Configuration: Codable, Equatable {
        var shellMode: ShellMode = .system
        var customShell = "/bin/zsh"
        /// Empty uses the platform's monospaced system font.
        var fontName = ""
        var fontSize: Double = 12
        var theme: Theme = .system
        var foreground = "#E6E6E6"
        var background = "#17191D"

        var font: NSFont {
            if !fontName.isEmpty, let font = NSFont(name: fontName, size: fontSize), Self.isMonospaced(font) { return font }
            return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }

        static func isMonospaced(_ font: NSFont) -> Bool {
            font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }

        func colors(for appearance: NSAppearance) -> (foreground: NSColor, background: NSColor) {
            switch theme {
            case .system:
                var colors = (foreground: NSColor.textColor, background: NSColor.textBackgroundColor)
                appearance.performAsCurrentDrawingAppearance {
                    colors = (NSColor.textColor.usingColorSpace(.sRGB) ?? .black,
                              NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white)
                }
                return colors
            case .dark: return (Self.color("#E6E6E6")!, Self.color("#17191D")!)
            case .light: return (Self.color("#222222")!, Self.color("#FFFFFF")!)
            case .custom: return (Self.color(foreground)!, Self.color(background)!)
            }
        }

        static func normalizedHex(_ value: String) -> String? {
            let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard digits.utf8.count == 6, digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
            return "#" + digits.uppercased()
        }

        static func color(_ hex: String) -> NSColor? {
            guard let normalized = normalizedHex(hex), let rgb = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
            return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255, alpha: 1)
        }

        func resolvedShell(systemShell: String = TerminalLaunchConfiguration.userShell,
                           isExecutable: (String) -> Bool = TerminalPreferences.isExecutableFile) throws -> String {
            let path = shellMode == .system ? systemShell : customShell
            if let error = TerminalPreferences.shellValidationError(path, isExecutable: isExecutable) {
                throw PreferenceError(message: error)
            }
            return path
        }

        fileprivate func normalized() throws -> Self {
            guard (8...36).contains(fontSize), fontSize.isFinite else { throw PreferenceError(message: "Use a font size from 8 to 36 points.") }
            guard fontName.isEmpty || (NSFont(name: fontName, size: fontSize).map(Self.isMonospaced) == true) else {
                throw PreferenceError(message: "Choose an installed monospaced font.")
            }
            guard let foreground = Self.normalizedHex(foreground), let background = Self.normalizedHex(background) else {
                throw PreferenceError(message: "Use six-digit colors such as #E6E6E6.")
            }
            guard TerminalPreferences.shellPathShapeError(customShell) == nil else {
                throw PreferenceError(message: "Enter an absolute shell executable path, such as /bin/zsh. Arguments are not supported.")
            }
            var value = self
            value.foreground = foreground
            value.background = background
            return value
        }
    }

    struct PreferenceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func shellPathShapeError(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return "Enter an absolute shell executable path, such as /bin/zsh. Arguments are not supported."
        }
        return nil
    }

    static func shellValidationError(_ path: String, isExecutable: (String) -> Bool = isExecutableFile) -> String? {
        if let error = shellPathShapeError(path) { return error }
        guard isExecutable(path) else { return "The shell must be an existing executable file. Check its path and permissions." }
        return nil
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    final class Store {
        private let defaults: UserDefaults
        let notificationCenter: NotificationCenter
        private let isExecutable: (String) -> Bool
        var configuration: Configuration {
            guard let data = defaults.data(forKey: TerminalPreferences.storageKey),
                  var decoded = try? JSONDecoder().decode(Configuration.self, from: data) else { return Configuration() }
            // Removing a font must not silently reset the user's chosen shell.
            if !decoded.fontName.isEmpty,
               NSFont(name: decoded.fontName, size: 12).map(Configuration.isMonospaced) != true { decoded.fontName = "" }
            return (try? decoded.normalized()) ?? Configuration()
        }

        init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default,
             isExecutable: @escaping (String) -> Bool = TerminalPreferences.isExecutableFile) {
            self.defaults = defaults
            self.notificationCenter = notificationCenter
            self.isExecutable = isExecutable
        }

        func set(_ configuration: Configuration) throws {
            let value = try configuration.normalized()
            let previous = self.configuration
            if value.shellMode == .custom,
               value.shellMode != previous.shellMode || value.customShell != previous.customShell {
                _ = try value.resolvedShell(isExecutable: isExecutable)
            }
            guard value != previous else { return }
            defaults.set(try JSONEncoder().encode(value), forKey: TerminalPreferences.storageKey)
            notificationCenter.post(name: .tursoraTerminalPreferencesChanged, object: self)
        }

        func reset() {
            let changed = configuration != Configuration()
            defaults.removeObject(forKey: TerminalPreferences.storageKey)
            if changed { notificationCenter.post(name: .tursoraTerminalPreferencesChanged, object: self) }
        }
    }
}

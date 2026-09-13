import AppKit
import Darwin
import SwiftTerm

/// All preferences use a private suite. The one real PTY starts our controlled
/// executable, which ignores login arguments and execs /bin/sh without rc files.
enum TerminalPreferencesSmokeTests {
    static func run(completion: @escaping () -> Void) {
        print("== terminal preferences ==")
        let suite = "Tursora.TerminalPreferencesSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let center = NotificationCenter()
        let store = TerminalPreferences.Store(defaults: defaults, notificationCenter: center)
        modelChecks(defaults: defaults, store: store)
        settingsChecks(store: store)
        realSessionChecks(store: store) {
            defaults.removePersistentDomain(forName: suite)
            completion()
        }
    }

    private static func modelChecks(defaults: UserDefaults, store: TerminalPreferences.Store) {
        check("defaults preserve existing terminal appearance without persisting", store.configuration == .init() && defaults.object(forKey: TerminalPreferences.storageKey) == nil)
        check("system mode resolves the supplied login shell", (try? store.configuration.resolvedShell(systemShell: "/selected/shell", isExecutable: { $0 == "/selected/shell" })) == "/selected/shell")
        for path in ["zsh", "~/bin/zsh", "", "/bin/zsh\0-c", "/bin/zsh\n-c", "/" + String(repeating: "a", count: 4096)] {
            check("reject invalid shell path \(path.debugDescription.prefix(70))", TerminalPreferences.shellValidationError(path, isExecutable: { _ in true }) != nil)
        }
        check("reject a directory even when it has executable permissions", TerminalPreferences.shellValidationError("/bin") != nil)
        check("reject a shell command with arguments", TerminalPreferences.shellValidationError("/bin/sh -c true") != nil)
        check("literal shell metacharacters are valid filename characters", TerminalPreferences.shellValidationError("/tmp/quoted ' shell; $HOME", isExecutable: { _ in true }) == nil)
        check("hex colors normalize without accepting alpha or short forms", TerminalPreferences.Configuration.normalizedHex("aAbBcC") == "#AABBCC" && TerminalPreferences.Configuration.color("#123") == nil && TerminalPreferences.Configuration.color("#12345678") == nil && TerminalPreferences.Configuration.color("#GGGGGG") == nil)

        var notifications = 0
        let observer = store.notificationCenter.addObserver(forName: .tursoraTerminalPreferencesChanged, object: store, queue: nil) { _ in notifications += 1 }
        defer { store.notificationCenter.removeObserver(observer) }
        var value = store.configuration
        value.fontSize = 18
        value.theme = .custom
        value.foreground = "abcdef"
        value.background = "#112233"
        save(value, to: store)
        let restored = TerminalPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
        check("stored appearance round-trips into a new store", restored.configuration.fontSize == 18 && restored.configuration.theme == .custom && restored.configuration.foreground == "#ABCDEF" && restored.configuration.background == "#112233")
        save(value, to: store)
        check("unchanged normalized values do not notify again", notifications == 1)
        let valid = store.configuration
        for size in [0.0, 7.0, 37.0, Double.nan, Double.infinity] {
            value = valid; value.fontSize = size
            check("reject font size \(size) without changing stored state", rejects { try store.set(value) } && store.configuration == valid)
        }
        value = valid; value.fontName = "Tursora-Nonexistent-Smoke-Font"
        check("reject an unavailable font", rejects { try store.set(value) } && store.configuration == valid)
        value = valid; value.foreground = "oops"
        check("reject invalid colors atomically", rejects { try store.set(value) } && store.configuration == valid)
        value = valid; value.shellMode = .custom; value.customShell = "/no-such-tursora-shell"
        check("reject a missing custom shell without changing appearance or shell", rejects { try store.set(value) } && store.configuration == valid)
        value = valid; value.shellMode = .custom; value.customShell = "/bin/sh"
        save(value, to: store)
        check("custom shell is persisted and chosen over system shell", restored.configuration.customShell == "/bin/sh" && (try? restored.configuration.resolvedShell(systemShell: "/bin/zsh")) == "/bin/sh")
        check("launch revalidates a shell that disappeared", rejects { _ = try restored.configuration.resolvedShell(isExecutable: { _ in false }) })

        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        value = .init()
        let lightBackground = value.colors(for: light).background
        let darkBackground = value.colors(for: dark).background
        check("system colors resolve under each window appearance", !sameColor(lightBackground, darkBackground))
        value.theme = .dark
        check("fixed dark palette remains stable in light appearance", sameColor(value.colors(for: light).background, value.colors(for: dark).background))
        defaults.set(Data("not JSON".utf8), forKey: TerminalPreferences.storageKey)
        check("malformed persisted data uses safe defaults", store.configuration == .init())
        store.reset()
        check("reset removes the persisted configuration", defaults.object(forKey: TerminalPreferences.storageKey) == nil)
    }

    private static func settingsChecks(store: TerminalPreferences.Store) {
        let page = TerminalSettingsViewController(preferences: store)
        let second = TerminalSettingsViewController(preferences: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = page
        window.setContentSize(NSSize(width: 540, height: 660))
        _ = second.view
        check("system shell disables custom path controls", !page.shellPath.isEnabled && !page.applyShellButton.isEnabled && page.shellMode.indexOfSelectedItem == 0)
        page.shellMode.selectItem(at: 1)
        dispatch(page.shellMode)
        check("choosing custom shell waits for explicit Apply", page.shellPath.isEnabled && store.configuration.shellMode == .system)
        page.shellPath.stringValue = "/missing-shell"
        dispatch(page.applyShellButton)
        check("invalid shell shows an inline error and keeps saved system shell", !page.message.stringValue.isEmpty && store.configuration.shellMode == .system)
        page.shellPath.stringValue = "/bin/sh"
        dispatch(page.applyShellButton)
        check("Apply Shell saves a valid executable and updates another settings page", page.message.stringValue.isEmpty && store.configuration.shellMode == .custom && second.shellPath.stringValue == "/bin/sh" && second.shellMode.indexOfSelectedItem == 1)
        page.fontSize.stringValue = "99"
        dispatch(page.fontSize)
        check("invalid size stays editable with inline feedback", page.fontSize.stringValue == "99" && !page.message.stringValue.isEmpty && store.configuration.fontSize == 12)
        page.fontSize.stringValue = "16"
        dispatch(page.fontSize)
        check("font size action updates storage and preview", store.configuration.fontSize == 16 && page.preview.font?.pointSize == 16 && second.fontSize.doubleValue == 16)
        page.sizeStepper.doubleValue = 17
        dispatch(page.sizeStepper)
        check("font size stepper updates both settings pages", page.fontSize.doubleValue == 17 && second.fontSize.doubleValue == 17)
        if let menlo = page.fontPicker.itemTitles.firstIndex(of: "Menlo-Regular") {
            page.fontPicker.selectItem(at: menlo)
            dispatch(page.fontPicker)
            check("font menu changes the actual preview face", store.configuration.fontName == "Menlo-Regular" && page.preview.font?.fontName == "Menlo-Regular")
        }
        page.themePicker.selectItem(at: 3)
        dispatch(page.themePicker)
        check("Custom theme enables color controls", page.foregroundField.isEnabled && page.backgroundField.isEnabled && page.applyColorsButton.isEnabled)
        page.foregroundField.stringValue = "#012345"
        page.backgroundField.stringValue = "bad color"
        dispatch(page.applyColorsButton)
        check("invalid color does not partially save the valid field", store.configuration.foreground == "#E6E6E6" && !page.message.stringValue.isEmpty)
        page.backgroundField.stringValue = "#FAFBFC"
        dispatch(page.applyColorsButton)
        check("Apply Colors updates preview and second page", store.configuration.foreground == "#012345" && second.backgroundField.stringValue == "#FAFBFC" && sameColor(page.preview.backgroundColor!, TerminalPreferences.Configuration.color("#FAFBFC")!))
        page.shellPath.stringValue = "/bin/zsh"
        page.foregroundField.stringValue = "#A0B0C0"
        page.backgroundField.stringValue = "#D0E0F0"
        let oldKey = NSApp.keyWindow
        window.makeKeyAndOrderFront(nil)
        page.fontSize.nextKeyView = page.foregroundField
        window.makeFirstResponder(page.fontSize)
        guard let editor = window.firstResponder as? NSTextView, editor === page.fontSize.currentEditor() else {
            fail("font size acquires its actual field editor", String(describing: window.firstResponder))
        }
        editor.selectAll(nil)
        editor.insertText("14", replacementRange: NSRange(location: NSNotFound, length: 0))
        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, characters: "\t",
                                  charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        editor.keyDown(with: tab)
        check("typing a size then Tab commits through the actual field editor", store.configuration.fontSize == 14 && page.sizeStepper.doubleValue == 14 && page.preview.font?.pointSize == 14 && second.fontSize.doubleValue == 14 && page.fontSize.currentEditor() == nil)
        check("font commit preserves unapplied shell and custom-color drafts", page.shellPath.stringValue == "/bin/zsh" && page.foregroundField.stringValue == "#A0B0C0" && page.backgroundField.stringValue == "#D0E0F0" && store.configuration.customShell == "/bin/sh" && store.configuration.foreground == "#012345")
        window.makeFirstResponder(nil)
        if oldKey?.isVisible == true { oldKey?.makeKeyAndOrderFront(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        for control: NSView in [page.shellPath, page.applyShellButton, page.fontPicker, page.fontSize,
                               page.themePicker, page.foregroundField, page.backgroundField, page.applyColorsButton,
                               page.preview, page.message, page.resetButton] {
            let frame = page.view.convert(control.bounds, from: control)
            check("settings control fits 540-point page: \(type(of: control))", frame.width > 0 && frame.height > 0 && page.view.bounds.contains(frame), "bounds=\(page.view.bounds), control=\(frame)")
        }
        dispatch(page.resetButton)
        check("Restore Defaults resets other settings pages and disables custom controls", store.configuration == .init() && second.shellMode.indexOfSelectedItem == 0 && !page.foregroundField.isEnabled && !page.shellPath.isEnabled)
        window.close()
    }

    private static func realSessionChecks(store: TerminalPreferences.Store, completion: @escaping () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-terminal-preferences-" + UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("quoted ' directory; $HOME", isDirectory: true)
        let shell = root.appendingPathComponent("controlled ' shell; $SHELL")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "#!/bin/sh\nexec /bin/sh -f -i\n".write(to: shell, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        } catch { fail("controlled shell fixture", error.localizedDescription) }
        var value = store.configuration
        value.shellMode = .custom
        value.customShell = shell.path
        save(value, to: store)
        let controller = TerminalPanelController(initialDirectory: directory, preferences: store)
        let other = TerminalPanelController(initialDirectory: root, preferences: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 720, height: 300))
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 240))
        controller.installTerminal(terminal, in: directory)
        let otherTerminal = LocalProcessTerminalView(frame: terminal.frame)
        other.installTerminal(otherTerminal, in: root)
        let configuration: TerminalLaunchConfiguration
        do {
            configuration = try controller.launchConfiguration(in: directory, environment: [
                "PATH": "/usr/bin:/bin", "HOME": root.path, "ENV": "/dev/null", "PS1": "$ ",
                "TURSORA_EXPECTED_CWD": directory.resolvingSymlinksInPath().path,
            ])
        } catch { fail("configured shell launch", error.localizedDescription) }
        check("configured custom executable stays a literal argv value", configuration.arguments[4] == shell.path && !configuration.arguments[1].contains(shell.path))
        terminal.startProcess(executable: configuration.executable, args: configuration.arguments,
                              environment: configuration.environment, currentDirectory: directory.path)
        check("saved custom shell starts a real owned PTY", controller.isRunning && isatty(terminal.process.childfd) == 1)
        let pid = terminal.process.shellPid
        send("stty -echo; test -t 0 && test \"$PWD\" = \"$TURSORA_EXPECTED_CWD\" && printf '\\n__PREFERENCES_%s__\\n' READY\n", to: terminal)
        waitFor("__PREFERENCES_READY__", in: terminal) {
            send("printf '\\n__PRESERVED_%s__\\n' INPUT", to: terminal)
            var changed = store.configuration
            changed.fontSize = 18
            changed.theme = .custom
            changed.foreground = "#AABBCC"
            changed.background = "#102030"
            save(changed, to: store)
            check("live appearance reaches both terminals without replacing the running PTY", controller.terminalView === terminal && terminal.process.shellPid == pid && controller.isRunning && terminal.font.pointSize == 18 && otherTerminal.font.pointSize == 18 && sameColor(terminal.nativeBackgroundColor, TerminalPreferences.Configuration.color("#102030")!))
            send("\n", to: terminal)
            waitFor("__PRESERVED_INPUT__", in: terminal) {
                changed.shellMode = .system
                save(changed, to: store)
                check("shell preference change preserves the existing session", terminal.process.shellPid == pid && controller.isRunning && (try? controller.launchConfiguration(in: root).shell) == TerminalLaunchConfiguration.userShell)
                changed.shellMode = .custom
                save(changed, to: store)
                try? FileManager.default.removeItem(at: shell)
                check("a disappeared saved shell blocks the next launch without killing the current one", rejects { _ = try controller.launchConfiguration(in: root) } && controller.isRunning && terminal.process.shellPid == pid)
                controller.processTerminated(source: terminal, exitCode: 0)
                let ended = controller.titleLabel.toolTip
                changed.fontSize = 14
                save(changed, to: store)
                check("appearance changes preserve the ended output and header", controller.titleLabel.toolTip == ended && ended?.contains("Session ended") == true && controller.statusState == .ended && controller.terminalView === terminal && output(terminal).contains("__PRESERVED_INPUT__"))
                TerminalProcessLifecycle.stop(terminal.process) {
                    var status: Int32 = 0
                    check("configured shell is reaped after explicit shutdown", waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
                    controller.shutdown()
                    other.shutdown()
                    window.close()
                    store.reset()
                    try? FileManager.default.removeItem(at: root)
                    completion()
                }
            }
        }
    }

    private static func dispatch(_ control: NSControl) {
        guard let action = control.action else { fail("control action", "Missing action") }
        check("settings dispatch \(NSStringFromSelector(action))", NSApp.sendAction(action, to: control.target, from: control))
    }
    private static func sameColor(_ first: NSColor, _ second: NSColor) -> Bool {
        guard let a = first.usingColorSpace(.sRGB), let b = second.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.002 && abs(a.greenComponent - b.greenComponent) < 0.002 && abs(a.blueComponent - b.blueComponent) < 0.002
    }
    private static func save(_ value: TerminalPreferences.Configuration, to store: TerminalPreferences.Store) {
        do { try store.set(value) } catch { fail("save valid preferences", error.localizedDescription) }
    }
    private static func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
    private static func send(_ text: String, to terminal: LocalProcessTerminalView) { terminal.process.send(data: Array(text.utf8)[...]) }
    private static func output(_ terminal: LocalProcessTerminalView) -> String { String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
    private static func waitFor(_ marker: String, in terminal: LocalProcessTerminalView, completion: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(10)
        func poll() {
            if output(terminal).contains(marker) { check("real PTY receives \(marker)", true); completion(); return }
            if Date() >= deadline { fail("real PTY receives \(marker)", output(terminal)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
        }
        poll()
    }
    private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition { print("ok  terminal preferences: \(name)") } else { fail(name, detail) }
    }
    private static func fail(_ name: String, _ detail: String) -> Never {
        print("FAIL terminal preferences: \(name) \(detail)")
        exit(1)
    }
}

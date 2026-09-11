import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let shared = SettingsWindowController()

    static func show() {
        guard !SmokeTest.isRequested else { return }
        shared.refreshControls()
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
    }

    let extensionsCheckbox = NSButton(checkboxWithTitle: "Show all filename extensions", target: nil, action: nil)
    let terminalCheckbox = NSButton(checkboxWithTitle: "Terminal panel", target: nil, action: nil)
    let zipCheckbox = NSButton(checkboxWithTitle: "Browse ZIP archives", target: nil, action: nil)
    let shortcutRecorder = ShortcutRecorderButton()
    let shortcutMessage = NSTextField(wrappingLabelWithString: "")
    private let preferences: AppPreferences.Store
    private var observer: NSObjectProtocol?

    init(preferences: AppPreferences.Store = AppPreferences.shared) {
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
        refreshControls()
        observer = preferences.notificationCenter.addObserver(forName: .tursoraPreferencesChanged,
                                                               object: preferences, queue: .main) { [weak self] _ in
            self?.refreshControls()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        func heading(_ title: String) -> NSTextField {
            let field = NSTextField(labelWithString: title)
            field.font = .systemFont(ofSize: 13, weight: .semibold)
            return field
        }
        func detail(_ text: String) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            return field
        }
        func separator() -> NSBox {
            let box = NSBox(); box.boxType = .separator
            return box
        }
        extensionsCheckbox.target = self
        extensionsCheckbox.action = #selector(toggleExtensions(_:))
        terminalCheckbox.target = self
        terminalCheckbox.action = #selector(toggleTerminal(_:))
        zipCheckbox.target = self
        zipCheckbox.action = #selector(toggleZIPBrowsing(_:))
        shortcutRecorder.onChange = { [weak self] shortcut in
            guard let self else { return nil }
            do {
                try self.preferences.setFilterShortcut(shortcut, menu: NSApp.mainMenu)
                self.shortcutMessage.stringValue = ""
                return nil
            } catch {
                self.shortcutMessage.stringValue = error.localizedDescription
                return error.localizedDescription
            }
        }
        shortcutRecorder.setAccessibilityLabel("Filter by Name shortcut")
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut(_:)))
        reset.bezelStyle = .rounded
        reset.toolTip = "Restore ⌘F"
        let shortcutRow = NSStackView(views: [NSTextField(labelWithString: "Filter by Name"), NSView(), shortcutRecorder, reset])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 10
        shortcutRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 145).isActive = true
        shortcutMessage.font = .systemFont(ofSize: 12)
        shortcutMessage.textColor = .systemRed
        shortcutMessage.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        let rows: [NSView] = [
            heading("General"), extensionsCheckbox,
            detail("Applies to file labels. Files keep their original names."), separator(),
            heading("Keyboard"), shortcutRow,
            detail("Click the shortcut, then press a new combination with Command or Control. Filters names in the current folder."),
            shortcutMessage, separator(), heading("Experimental"),
            terminalCheckbox, detail("Show a terminal alongside your files. Off by default."),
            zipCheckbox, detail("Open ZIP files in a read-only browser instead of extracting them. Off by default."),
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window?.initialFirstResponder = extensionsCheckbox
    }

    private func refreshControls() {
        extensionsCheckbox.state = preferences.showFileExtensions ? .on : .off
        terminalCheckbox.state = preferences.experimentalTerminalEnabled ? .on : .off
        zipCheckbox.state = preferences.experimentalZIPBrowsingEnabled ? .on : .off
        shortcutRecorder.shortcut = preferences.filterShortcut
    }

    @objc func toggleExtensions(_ sender: NSButton) { preferences.showFileExtensions = sender.state == .on }
    @objc func toggleTerminal(_ sender: NSButton) { preferences.experimentalTerminalEnabled = sender.state == .on }
    @objc func toggleZIPBrowsing(_ sender: NSButton) { preferences.experimentalZIPBrowsingEnabled = sender.state == .on }
    @objc func resetShortcut(_ sender: Any?) {
        shortcutRecorder.stopRecording()
        preferences.resetFilterShortcut()
        shortcutMessage.stringValue = ""
        refreshControls()
    }

    func windowWillClose(_ notification: Notification) { shortcutRecorder.stopRecording() }
    func windowDidResignKey(_ notification: Notification) { shortcutRecorder.stopRecording() }
    deinit {
        if let observer { preferences.notificationCenter.removeObserver(observer) }
    }
}

/// Intercepts recording before menu dispatch, so pressing an existing command
/// reports a conflict instead of executing it (especially Quit or Close).
final class ShortcutRecorderButton: NSButton {
    var shortcut = AppPreferences.Shortcut.defaultFilter {
        didSet { if !isRecording { title = shortcut.displayString } }
    }
    var onChange: ((AppPreferences.Shortcut) -> String?)?
    private(set) var isRecording = false
    private var keyMonitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        title = shortcut.displayString
        toolTip = "Record shortcut; press Escape to cancel"
        target = self
        action = #selector(startRecording(_:))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    @objc func startRecording(_ sender: Any?) {
        guard !isRecording else { return }
        window?.makeFirstResponder(self)
        isRecording = true
        title = "Type shortcut…"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording, self.window?.isKeyWindow == true,
                  self.window?.firstResponder === self else { return event }
            self.capture(event)
            return nil
        }
    }

    func stopRecording() {
        isRecording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        title = shortcut.displayString
    }

    @discardableResult
    func record(keyEquivalent: String, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let value = AppPreferences.Shortcut(keyEquivalent: keyEquivalent, modifierFlags: modifierFlags)
        if let onChange {
            guard onChange(value) == nil else { return false }
        } else if value.validationError() != nil { return false }
        shortcut = value
        stopRecording()
        return true
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 { stopRecording(); return }
        // The keyboard layout, rather than a US-keyboard table, determines the
        // unmodified character. Modifiers are persisted separately for NSMenu.
        let key = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        _ = record(keyEquivalent: key, modifierFlags: event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        if isRecording { capture(event) } else { super.keyDown(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
}

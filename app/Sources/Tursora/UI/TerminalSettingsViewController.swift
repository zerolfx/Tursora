import AppKit

/// A self-contained Settings page. Shell edits require Apply; appearance edits
/// update every existing terminal while preserving its process and input.
final class TerminalSettingsViewController: NSViewController {
    let preferences: TerminalPreferences.Store
    let shellMode = NSPopUpButton(frame: .zero, pullsDown: false)
    let shellPath = NSTextField(string: "")
    let applyShellButton = NSButton(title: "Apply Shell", target: nil, action: nil)
    let fontPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let fontSize = NSTextField(string: "12")
    let sizeStepper = NSStepper()
    let themePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let foregroundField = NSTextField(string: "")
    let backgroundField = NSTextField(string: "")
    let applyColorsButton = NSButton(title: "Apply Colors", target: nil, action: nil)
    let preview = NSTextField(labelWithString: "Tursora ~/Projects % ls\nDocuments  Images  Notes.txt")
    let message = NSTextField(wrappingLabelWithString: "")
    let resetButton = NSButton(title: "Restore Terminal Defaults", target: nil, action: nil)
    private var observer: NSObjectProtocol?
    private var availableFonts: [String] = [""]
    private var displayedConfiguration: TerminalPreferences.Configuration?

    init(preferences: TerminalPreferences.Store = TerminalPreferences.shared) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { preferences.notificationCenter.removeObserver(observer) } }

    override func loadView() {
        let root = AppearanceObservingView(flipped: true, frame: NSRect(x: 0, y: 0, width: 580, height: 620))
        view = root
        root.onAppearanceChanged = { [weak self] in self?.refreshPreview() }
        let title = NSTextField.heading("Terminal")
        let shellNote = NSTextField.detail("Shell changes apply the next time you open or restart a terminal. Running sessions keep their shell.")
        shellMode.addItems(withTitles: ["System Login Shell", "Custom Shell"])
        wire(shellMode, #selector(changeShellMode(_:)))
        shellPath.placeholderString = "/bin/zsh"
        shellPath.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shellPath.cell?.sendsActionOnEndEditing = false
        wire(shellPath, #selector(applyShell(_:)))
        applyShellButton.bezelStyle = .rounded
        wire(applyShellButton, #selector(applyShell(_:)))
        let shellRow = row([shellPath, applyShellButton])
        shellPath.setContentHuggingPriority(.defaultLow, for: .horizontal)
        shellPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        availableFonts += NSFontManager.shared.availableFonts.filter {
            NSFont(name: $0, size: 12).map(TerminalPreferences.Configuration.isMonospaced) == true
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        fontPicker.addItems(withTitles: ["System Monospaced"] + availableFonts.dropFirst())
        wire(fontPicker, #selector(changeFont(_:)))
        fontPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fontSize.alignment = .right
        fontSize.cell?.sendsActionOnEndEditing = true
        wire(fontSize, #selector(changeFontSize(_:)))
        sizeStepper.minValue = 8
        sizeStepper.maxValue = 36
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        wire(sizeStepper, #selector(stepFontSize(_:)))
        fontSize.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let fontRow = row([label("Font"), fontPicker, fontSize, label("pt"), sizeStepper])
        fontPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)

        themePicker.addItems(withTitles: TerminalPreferences.Theme.allCases.map(\.title))
        wire(themePicker, #selector(changeTheme(_:)))
        let themeRow = row([label("Colors"), themePicker])
        for field in [foregroundField, backgroundField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.cell?.sendsActionOnEndEditing = false
            field.widthAnchor.constraint(equalToConstant: 86).isActive = true
            wire(field, #selector(applyColors(_:)))
        }
        applyColorsButton.bezelStyle = .rounded
        wire(applyColorsButton, #selector(applyColors(_:)))
        let colorsRow = row([label("Text"), foregroundField, label("Background"), backgroundField, applyColorsButton])
        let appearanceNote = NSTextField.detail("Font and colors update open terminals immediately. Custom colors use #RRGGBB; programs can still choose their own ANSI colors.")
        preview.isSelectable = false
        preview.isBordered = false
        preview.drawsBackground = true
        preview.wantsLayer = true
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byClipping
        preview.heightAnchor.constraint(equalToConstant: 100).isActive = true
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .systemRed
        message.setContentHuggingPriority(.defaultLow, for: .vertical)
        message.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        resetButton.bezelStyle = .rounded
        wire(resetButton, #selector(restoreDefaults(_:)))

        let stack = NSStackView(views: [title, shellMode, shellRow, shellNote, fontRow, themeRow,
                                       colorsRow, appearanceNote, preview, message, resetButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])
        for item in [shellRow, shellNote, fontRow, appearanceNote, preview, message] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        observer = preferences.notificationCenter.addObserver(forName: .tursoraTerminalPreferencesChanged, object: preferences, queue: nil) { [weak self] _ in
            self?.refreshControls()
        }
        refreshControls()
    }

    private func wire(_ control: NSControl, _ action: Selector) { control.target = self; control.action = action }
    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        return label
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func refreshControls(force: Bool = false) {
        let value = preferences.configuration
        let previous = displayedConfiguration
        // Do not discard unsubmitted shell or color text when another setting
        // changes or a different Settings window broadcasts an appearance edit.
        if force || previous?.shellMode != value.shellMode || previous?.customShell != value.customShell {
            shellMode.selectItem(at: value.shellMode == .system ? 0 : 1)
            shellPath.stringValue = value.customShell
            setShellControlsEnabled(value.shellMode == .custom)
        }
        if force || previous?.fontName != value.fontName {
            fontPicker.selectItem(at: availableFonts.firstIndex(of: value.fontName) ?? 0)
        }
        if force || previous?.fontSize != value.fontSize {
            fontSize.doubleValue = value.fontSize
            sizeStepper.doubleValue = value.fontSize
        }
        if force || previous?.theme != value.theme {
            themePicker.selectItem(at: TerminalPreferences.Theme.allCases.firstIndex(of: value.theme) ?? 0)
        }
        if force || previous?.foreground != value.foreground || previous?.background != value.background {
            foregroundField.stringValue = value.foreground
            backgroundField.stringValue = value.background
        }
        for control in [foregroundField, backgroundField, applyColorsButton] { control.isEnabled = value.theme == .custom }
        displayedConfiguration = value
        refreshPreview()
    }

    private func setShellControlsEnabled(_ enabled: Bool) {
        shellPath.isEnabled = enabled
        applyShellButton.isEnabled = enabled
        shellPath.toolTip = enabled ? "Absolute path to the shell executable; no command arguments."
            : "Current system login shell: \(TerminalLaunchConfiguration.userShell)"
    }

    private func refreshPreview() {
        guard isViewLoaded else { return }
        let value = preferences.configuration
        let colors = value.colors(for: view.effectiveAppearance)
        preview.font = value.font
        preview.textColor = colors.foreground
        preview.backgroundColor = colors.background
    }

    @discardableResult
    private func save(_ edit: (inout TerminalPreferences.Configuration) -> Void) -> Bool {
        var value = preferences.configuration
        edit(&value)
        do {
            try preferences.set(value)
            message.stringValue = ""
            refreshControls()
            return true
        } catch {
            message.stringValue = error.localizedDescription
            return false
        }
    }

    @objc func changeShellMode(_ sender: Any?) {
        if shellMode.indexOfSelectedItem == 0 { _ = save { $0.shellMode = .system } }
        else {
            setShellControlsEnabled(true)
            message.stringValue = "Enter the shell path, then choose Apply Shell."
        }
    }

    @objc func applyShell(_ sender: Any?) {
        let path = shellPath.stringValue
        if let error = TerminalPreferences.shellValidationError(path) {
            message.stringValue = error
            return
        }
        _ = save { $0.shellMode = .custom; $0.customShell = path }
    }
    @objc func changeFont(_ sender: Any?) {
        guard availableFonts.indices.contains(fontPicker.indexOfSelectedItem) else { return }
        let name = availableFonts[fontPicker.indexOfSelectedItem]
        _ = save { $0.fontName = name }
    }
    @objc func changeFontSize(_ sender: Any?) {
        guard let size = Double(fontSize.stringValue), size.isFinite else {
            message.stringValue = "Use a font size from 8 to 36 points."
            return
        }
        if save({ $0.fontSize = size }) {
            fontSize.doubleValue = preferences.configuration.fontSize
            sizeStepper.doubleValue = preferences.configuration.fontSize
        }
    }
    @objc func stepFontSize(_ sender: Any?) { _ = save { $0.fontSize = sizeStepper.doubleValue } }
    @objc func changeTheme(_ sender: Any?) {
        guard TerminalPreferences.Theme.allCases.indices.contains(themePicker.indexOfSelectedItem) else { return }
        let theme = TerminalPreferences.Theme.allCases[themePicker.indexOfSelectedItem]
        _ = save { $0.theme = theme }
    }
    @objc func applyColors(_ sender: Any?) {
        let foreground = foregroundField.stringValue
        let background = backgroundField.stringValue
        if save({ $0.foreground = foreground; $0.background = background }) {
            foregroundField.stringValue = preferences.configuration.foreground
            backgroundField.stringValue = preferences.configuration.background
        }
    }
    @objc func restoreDefaults(_ sender: Any?) {
        preferences.reset()
        message.stringValue = ""
        refreshControls(force: true)
    }
}

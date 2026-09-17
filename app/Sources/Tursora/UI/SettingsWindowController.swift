import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    private static let shared = SettingsWindowController()

    static func show() {
        guard !SmokeTest.isRequested else { return }
        shared.refreshControls()
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
    }

    let extensionsCheckbox = NSButton(checkboxWithTitle: "Show all filename extensions", target: nil, action: nil)
    let restoreWorkspaceCheckbox = NSButton(checkboxWithTitle: "Reopen windows and tabs on launch", target: nil, action: nil)
    /// macOS has no "default file manager" setting; what it has is the handler
    /// for `public.folder`. The button asks the system, which puts its own
    /// confirmation in front of the user (D86).
    let defaultFileManagerButton = NSButton(title: "Set Tursora as Default", target: nil, action: nil)
    let defaultFileManagerStatus = NSTextField.detail("")
    /// True while macOS's own confirmation for the folder role is up.
    private(set) var isClaimingFolderRole = false
    let workspaceSaveMessage = NSTextField(wrappingLabelWithString: "")
    let retryWorkspaceSave = NSButton(title: "Retry Saving Workspace", target: nil, action: nil)
    let generalScrollView = NSScrollView()
    let terminalCheckbox = NSButton(checkboxWithTitle: "Terminal panel", target: nil, action: nil)
    let zipCheckbox = NSButton(checkboxWithTitle: "Browse ZIP archives", target: nil, action: nil)
    let shortcutsController: ShortcutsSettingsViewController
    let terminalSettingsController = TerminalSettingsViewController()
    var shortcutRecorder: ShortcutRecorderButton { shortcutsController.recorder }
    var shortcutMessage: NSTextField { shortcutsController.message }
    let folderViewSaveMessage = NSTextField(wrappingLabelWithString: "")
    let retryFolderViewSave = NSButton(title: "Retry Saving View Settings", target: nil, action: nil)
    let folderViewPolicy = NSPopUpButton(frame: .zero, pullsDown: false)
    let settingsTabs = NSTabView()
    let automaticUpdateChecksCheckbox = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    let automaticUpdateDownloadsCheckbox = NSButton(checkboxWithTitle: "Automatically download and install updates", target: nil, action: nil)
    let checkForUpdatesButton = NSButton(title: "Check for Updates…", target: nil, action: nil)
    let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let updater: AppUpdater
    private var updaterObserver: NSObjectProtocol?
    private let viewPropertiesStore: DirectoryViewPropertiesStore
    private var viewPropertiesObserver: NSObjectProtocol?
    private let preferences: AppPreferences.Store
    private var observer: NSObjectProtocol?
    private let workspaceStore: WorkspaceSessionStore
    private var workspaceObserver: NSObjectProtocol?

    init(preferences: AppPreferences.Store = AppPreferences.shared,
         viewPropertiesStore: DirectoryViewPropertiesStore = .shared,
         updater: AppUpdater = .shared,
         workspaceStore: WorkspaceSessionStore = .shared) {
        self.shortcutsController = ShortcutsSettingsViewController(store: preferences.shortcuts)
        self.workspaceStore = workspaceStore
        self.updater = updater
        self.viewPropertiesStore = viewPropertiesStore
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 745),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        viewPropertiesObserver = NotificationCenter.default.addObserver(forName: DirectoryViewPropertiesStore.didChange, object: viewPropertiesStore, queue: .main) { [weak self] _ in
            self?.refreshControls()
        }
        workspaceObserver = NotificationCenter.default.addObserver(forName: WorkspaceSessionStore.didChange, object: workspaceStore, queue: .main) { [weak self] _ in
            self?.refreshControls()
        }
        window.delegate = self
        window.center()
        buildContent()
        refreshControls()
        updaterObserver = updater.notificationCenter.addObserver(forName: AppUpdater.didChange, object: updater, queue: .main) { [weak self] _ in
            self?.refreshUpdateControls()
        }
        observer = preferences.notificationCenter.addObserver(forName: .tursoraPreferencesChanged,
                                                               object: preferences, queue: .main) { [weak self] _ in
            self?.refreshControls()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let windowContent = window?.contentView else { return }
        settingsTabs.delegate = self
        settingsTabs.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(settingsTabs)
        NSLayoutConstraint.activate([
            settingsTabs.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor, constant: 8),
            settingsTabs.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor, constant: -8),
            settingsTabs.topAnchor.constraint(equalTo: windowContent.topAnchor, constant: 8),
            settingsTabs.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor, constant: -8),
        ])
        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        // General can grow to show a save error without clipping controls on
        // a smaller display; the document remains at its natural text height.
        generalScrollView.hasVerticalScroller = true
        generalScrollView.autohidesScrollers = true
        generalScrollView.drawsBackground = false
        generalScrollView.borderType = .noBorder
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        generalScrollView.documentView = content
        let clip = generalScrollView.contentView
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
        ])
        general.view = generalScrollView
        settingsTabs.addTabViewItem(general)
        let shortcuts = NSTabViewItem(identifier: "shortcuts")
        shortcuts.label = "Shortcuts"
        shortcuts.view = shortcutsController.view
        settingsTabs.addTabViewItem(shortcuts)
        let terminal = NSTabViewItem(identifier: "terminal")
        terminal.label = "Terminal"
        let terminalScroll = NSScrollView()
        terminalScroll.hasVerticalScroller = true
        terminalScroll.autohidesScrollers = true
        terminalScroll.drawsBackground = false
        let terminalContent = terminalSettingsController.view
        terminalContent.translatesAutoresizingMaskIntoConstraints = false
        terminalScroll.documentView = terminalContent
        NSLayoutConstraint.activate([
            terminalContent.leadingAnchor.constraint(equalTo: terminalScroll.contentView.leadingAnchor),
            terminalContent.topAnchor.constraint(equalTo: terminalScroll.contentView.topAnchor),
            terminalContent.widthAnchor.constraint(equalTo: terminalScroll.contentView.widthAnchor),
            terminalContent.heightAnchor.constraint(greaterThanOrEqualTo: terminalScroll.contentView.heightAnchor),
        ])
        terminal.view = terminalScroll
        settingsTabs.addTabViewItem(terminal)
        let updates = NSTabViewItem(identifier: "updates")
        updates.label = "Updates"
        let updateContent = NSView()
        updates.view = updateContent
        settingsTabs.addTabViewItem(updates)
        buildUpdates(in: updateContent)
        func separator() -> NSBox {
            let box = NSBox(); box.boxType = .separator
            return box
        }
        folderViewSaveMessage.font = .systemFont(ofSize: 12)
        retryFolderViewSave.bezelStyle = .rounded
        retryFolderViewSave.target = self
        retryFolderViewSave.action = #selector(retrySavingFolderViews(_:))
        folderViewPolicy.addItems(withTitles: ["Remember Each Folder", "Use One View for All Folders"])
        folderViewPolicy.target = self
        folderViewPolicy.action = #selector(changeFolderViewPolicy(_:))
        folderViewPolicy.setAccessibilityLabel("Folder View Settings")
        extensionsCheckbox.target = self
        extensionsCheckbox.action = #selector(toggleExtensions(_:))
        restoreWorkspaceCheckbox.target = self
        restoreWorkspaceCheckbox.action = #selector(toggleWorkspaceRestoration(_:))
        defaultFileManagerButton.bezelStyle = .rounded
        defaultFileManagerButton.target = self
        defaultFileManagerButton.action = #selector(makeDefaultFileManager(_:))
        workspaceSaveMessage.font = .systemFont(ofSize: 12)
        workspaceSaveMessage.textColor = .systemRed
        retryWorkspaceSave.bezelStyle = .rounded
        retryWorkspaceSave.target = self
        retryWorkspaceSave.action = #selector(retrySavingWorkspace(_:))
        terminalCheckbox.target = self
        terminalCheckbox.action = #selector(toggleTerminal(_:))
        zipCheckbox.target = self
        zipCheckbox.action = #selector(toggleZIPBrowsing(_:))

        let rows: [NSView] = [
            NSTextField.heading("Startup"), restoreWorkspaceCheckbox,
            NSTextField.detail("Restore your windows, tabs and split panes. Turning this off clears the saved workspace."),
            workspaceSaveMessage, retryWorkspaceSave, separator(),
            NSTextField.heading("Opening folders"), defaultFileManagerStatus, defaultFileManagerButton,
            NSTextField.heading("General"), extensionsCheckbox,
            NSTextField.detail("Applies to file labels. Files keep their original names."), separator(),
            NSTextField.heading("Folder View Settings"), folderViewPolicy,
            NSTextField.detail("Remember view mode, sorting, icon sizes, groups, hidden files and previews. Use View → Folder View Settings to save a default or reset a folder. In Remember Each Folder mode, open panes keep their own view until you revisit the folder."),
            folderViewSaveMessage, retryFolderViewSave, separator(),
            NSTextField.heading("Terminal & ZIP"),
            terminalCheckbox, NSTextField.detail("Use the toolbar Terminal button to show or hide your terminal. Hidden sessions keep running, including when this option is off. Re-enable it to return to the session. Customize its shell and appearance in Terminal, and its shortcut in Shortcuts."),
            zipCheckbox, NSTextField.detail("Open ZIP files read-only in the current pane. Use Extract when you want to unpack the archive."),
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
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        // Labels, checkboxes and pop-ups fill the pane; a push button must not.
        // Stretched to the full width it reads as a banner rather than a
        // button, and its title floats in the middle of an empty bar.
        let naturalWidth: [NSView] = [defaultFileManagerButton, retryWorkspaceSave, retryFolderViewSave]
        for row in rows where !naturalWidth.contains(where: { $0 === row }) {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window?.initialFirstResponder = extensionsCheckbox
    }

    private func refreshControls() {
        refreshUpdateControls()
        syncDefaultFileManager()
        restoreWorkspaceCheckbox.state = preferences.restoreWorkspaceOnLaunch ? .on : .off
        workspaceSaveMessage.stringValue = workspaceStore.lastError ?? ""
        workspaceSaveMessage.isHidden = workspaceStore.lastError == nil
        retryWorkspaceSave.isHidden = workspaceStore.lastError == nil
        retryWorkspaceSave.title = preferences.restoreWorkspaceOnLaunch ? "Retry Saving Workspace" : "Retry Clearing Saved Workspace"
        if let error = viewPropertiesStore.lastWriteError {
            folderViewSaveMessage.stringValue = "View settings could not be saved. Changes are available for this session. " + error.localizedDescription
            folderViewSaveMessage.textColor = .systemRed
            retryFolderViewSave.isHidden = false
        } else {
            folderViewSaveMessage.stringValue = "Settings are stored by Tursora; no files are added to your folders."
            folderViewSaveMessage.textColor = .secondaryLabelColor
            retryFolderViewSave.isHidden = true
        }
        folderViewPolicy.selectItem(at: viewPropertiesStore.policy == .perDirectory ? 0 : 1)
        extensionsCheckbox.state = preferences.showFileExtensions ? .on : .off
        terminalCheckbox.state = preferences.experimentalTerminalEnabled ? .on : .off
        zipCheckbox.state = preferences.experimentalZIPBrowsingEnabled ? .on : .off
        shortcutsController.refresh()
    }

    private func buildUpdates(in content: NSView) {
        let title = NSTextField.heading("Software Updates")
        let detail = NSTextField.detail("Check for new versions daily. Downloaded updates are verified before installation. Automatic installation is off by default; when enabled, updates can install when you quit Tursora.")
        automaticUpdateChecksCheckbox.target = self
        automaticUpdateChecksCheckbox.action = #selector(toggleAutomaticUpdateChecks(_:))
        automaticUpdateDownloadsCheckbox.target = self
        automaticUpdateDownloadsCheckbox.action = #selector(toggleAutomaticUpdateDownloads(_:))
        checkForUpdatesButton.target = updater
        checkForUpdatesButton.action = #selector(AppUpdater.checkForUpdates(_:))
        checkForUpdatesButton.bezelStyle = .rounded
        updateStatus.font = .systemFont(ofSize: 12)
        updateStatus.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, automaticUpdateChecksCheckbox, automaticUpdateDownloadsCheckbox,
                                       detail, checkForUpdatesButton, updateStatus])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            updateStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func refreshUpdateControls() {
        automaticUpdateChecksCheckbox.state = updater.automaticallyChecksForUpdates ? .on : .off
        automaticUpdateChecksCheckbox.isEnabled = updater.isAvailable
        automaticUpdateDownloadsCheckbox.state = updater.automaticallyDownloadsUpdates ? .on : .off
        automaticUpdateDownloadsCheckbox.isEnabled = updater.allowsAutomaticUpdates
        checkForUpdatesButton.isEnabled = updater.canCheckForUpdates
        updateStatus.stringValue = updater.statusText
    }

    @objc func toggleAutomaticUpdateChecks(_ sender: NSButton) {
        updater.automaticallyChecksForUpdates = sender.state == .on
        refreshUpdateControls()
    }

    @objc func toggleAutomaticUpdateDownloads(_ sender: NSButton) {
        updater.automaticallyDownloadsUpdates = sender.state == .on
        refreshUpdateControls()
    }

    @objc func retrySavingFolderViews(_ sender: Any?) {
        try? viewPropertiesStore.flush()
        refreshControls()
    }

    @objc func changeFolderViewPolicy(_ sender: NSPopUpButton) {
        viewPropertiesStore.setPolicy(sender.indexOfSelectedItem == 0 ? .perDirectory : .unified)
    }

    @objc func toggleExtensions(_ sender: NSButton) { preferences.showFileExtensions = sender.state == .on }
    @objc func toggleWorkspaceRestoration(_ sender: NSButton) { preferences.restoreWorkspaceOnLaunch = sender.state == .on }
    @objc func retrySavingWorkspace(_ sender: Any?) {
        NotificationCenter.default.post(name: .tursoraWorkspaceSaveRequested, object: workspaceStore)
    }
    @objc func toggleTerminal(_ sender: NSButton) { preferences.experimentalTerminalEnabled = sender.state == .on }
    @objc func toggleZIPBrowsing(_ sender: NSButton) { preferences.experimentalZIPBrowsingEnabled = sender.state == .on }
    @objc func resetShortcut(_ sender: Any?) {
        shortcutsController.resetSelected(sender)
    }

    func windowWillClose(_ notification: Notification) { shortcutRecorder.stopRecording() }
    func windowDidResignKey(_ notification: Notification) { shortcutRecorder.stopRecording() }
    func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) { shortcutRecorder.stopRecording() }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard tabViewItem?.identifier as? String == "shortcuts" else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        shortcutsController.revealSelectedCommand()
    }
    deinit {
        if let observer { preferences.notificationCenter.removeObserver(observer) }
        if let viewPropertiesObserver { NotificationCenter.default.removeObserver(viewPropertiesObserver) }
        if let updaterObserver { updater.notificationCenter.removeObserver(updaterObserver) }
        if let workspaceObserver { NotificationCenter.default.removeObserver(workspaceObserver) }
    }

    /// Reads LaunchServices rather than remembering: the user can change the
    /// handler in another application, and a remembered answer would go stale
    /// without anything telling us.
    func syncDefaultFileManager() {
        let isCurrent = DefaultFileManager.isCurrent()
        // Say why the button cannot work before it is pressed. LaunchServices
        // refuses an application in a temporary or read-only location, and its
        // own error is "The file couldn't be opened." — which sent the owner
        // looking for a bug in Tursora rather than moving the app.
        let problem = isCurrent ? nil : DefaultFileManager.locationProblem()
        defaultFileManagerStatus.stringValue = problem?.explanation
            ?? DefaultFileManager.statusText(isCurrent: isCurrent,
                                             currentName: DefaultFileManager.currentHandlerName())
        // Never re-enable while the system's confirmation is still up: any
        // unrelated refresh would otherwise arm a second concurrent request.
        defaultFileManagerButton.isEnabled = !isCurrent && !isClaimingFolderRole && problem == nil
        defaultFileManagerButton.title = isCurrent ? "Tursora Is the Default" : "Set Tursora as Default"
    }

    /// The role can be handed to another application while this window sits
    /// open, so the line is read again whenever the window comes forward.
    func windowDidBecomeKey(_ notification: Notification) { syncDefaultFileManager() }

    @objc func makeDefaultFileManager(_ sender: Any?) {
        guard !isClaimingFolderRole else { return }
        isClaimingFolderRole = true
        defaultFileManagerButton.isEnabled = false
        DefaultFileManager.makeCurrent { [weak self] result in
            guard let self else { return }
            self.isClaimingFolderRole = false
            if case .failure(let error) = result {
                // A headless run must never raise a sheet (AGENTS rule 2), and
                // a sheet on a window the user has closed is a sheet nobody
                // sees — that case gets an ordinary alert instead.
                if SmokeTest.isRequested {
                    print("default file manager: \(error.localizedDescription)")
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Tursora could not become the default."
                    alert.informativeText = error.localizedDescription
                    if let window = self.window, window.isVisible {
                        alert.beginSheetModal(for: window) { _ in }
                    } else {
                        alert.runModal()
                    }
                }
            }
            // Either way the truth comes from LaunchServices, not from the
            // result: the user may have declined the system's confirmation.
            self.syncDefaultFileManager()
        }
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
        if event.keyCode == 53 && event.modifierFlags.intersection(AppPreferences.Shortcut.supportedModifiers).isEmpty { stopRecording(); return }
        // The keyboard layout, rather than a US-keyboard table, determines the
        // unmodified character. Modifiers are persisted separately for NSMenu.
        let shortcut = AppPreferences.Shortcut.from(event)
        _ = record(keyEquivalent: shortcut.keyEquivalent, modifierFlags: shortcut.modifierFlags)
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

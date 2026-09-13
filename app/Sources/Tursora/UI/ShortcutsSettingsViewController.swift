import AppKit

final class ShortcutsSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    let tableView = NSTableView()
    let recorder = ShortcutRecorderButton()
    let message = NSTextField(wrappingLabelWithString: "")
    let selectionLabel = NSTextField(wrappingLabelWithString: "")
    let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let resetAllButton = NSButton(title: "Reset All Shortcuts", target: nil, action: nil)
    let store: ShortcutStore
    private(set) var visibleActions = ShortcutCatalog.actions
    private(set) var selectedID = ShortcutCatalog.filterID
    private var isUpdatingSelection = false
    private var observer: NSObjectProtocol?

    init(store: ShortcutStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        observer = store.notificationCenter.addObserver(forName: .tursoraShortcutsChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        searchField.placeholderString = "Find a command"
        searchField.delegate = self
        searchField.setAccessibilityLabel("Find a keyboard shortcut command")
        let detail = NSTextField(wrappingLabelWithString: "Select a command, click its shortcut, then press a new combination. Command shortcuts work throughout the app; Control-only and function keys stay with text fields and the shell while typing. File View keys apply only to the file list or icons.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let command = NSTableColumn(identifier: .init("command"))
        command.title = "Command"; command.width = 350; command.minWidth = 180
        let shortcut = NSTableColumn(identifier: .init("shortcut"))
        shortcut.title = "Shortcut"; shortcut.width = 130; shortcut.minWidth = 100
        tableView.addTableColumn(command); tableView.addTableColumn(shortcut)
        tableView.dataSource = self; tableView.delegate = self
        tableView.rowHeight = 40; tableView.style = .inset
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.allowsEmptySelection = false
        tableView.setAccessibilityLabel("Application keyboard shortcuts")
        let scroll = NSScrollView()
        scroll.documentView = tableView; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        selectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        recorder.onChange = { [weak self] shortcut in self?.apply(shortcut) }
        recorder.setAccessibilityLabel("Record selected command shortcut")
        clearButton.target = self; clearButton.action = #selector(clearSelected(_:))
        resetButton.target = self; resetButton.action = #selector(resetSelected(_:))
        resetAllButton.target = self; resetAllButton.action = #selector(resetAll(_:))
        for button in [clearButton, resetButton, resetAllButton] { button.bezelStyle = .rounded }
        recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let edit = NSStackView(views: [recorder, clearButton, resetButton, NSView()])
        edit.orientation = .horizontal; edit.spacing = 8
        message.font = .systemFont(ofSize: 12); message.textColor = .systemRed
        let footer = NSTextField(wrappingLabelWithString: "Clear the current owner before reusing a shortcut. Escape cancels recording; use Control–Escape or another combination to change archive cancellation. macOS shortcuts and standard text-editing, completion, selection and terminal controls remain managed by their own views.")
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [detail, searchField, scroll, selectionLabel, edit, message, resetAllButton, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            message.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        for row in [detail, searchField, scroll, selectionLabel, edit, message, footer] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refresh()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleActions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleActions.indices.contains(row) else { return nil }
        let action = visibleActions[row]
        if tableColumn?.identifier.rawValue == "shortcut" {
            let text = NSTextField(labelWithString: store.shortcut(for: action.id)?.displayString ?? "—")
            text.font = .systemFont(ofSize: 13)
            return text
        }
        let title = NSTextField(labelWithString: action.title)
        let category = NSTextField(labelWithString: action.category)
        title.lineBreakMode = .byTruncatingTail
        category.font = .systemFont(ofSize: 10); category.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, category])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 1
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection, visibleActions.indices.contains(tableView.selectedRow) else { return }
        recorder.stopRecording()
        selectedID = visibleActions[tableView.selectedRow].id
        message.stringValue = ""
        refreshSelection()
    }

    func controlTextDidChange(_ obj: Notification) { filterCommands(searchField.stringValue) }

    func filterCommands(_ query: String) {
        recorder.stopRecording()
        let intendedID = selectedID
        isUpdatingSelection = true
        defer { isUpdatingSelection = false }
        visibleActions = ShortcutCatalog.actions.filter {
            query.isEmpty || ($0.category + " " + $0.title).localizedCaseInsensitiveContains(query)
        }
        tableView.reloadData()
        if let row = visibleActions.firstIndex(where: { $0.id == intendedID }) {
            selectedID = intendedID
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if let first = visibleActions.first {
            selectedID = first.id
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        message.stringValue = ""
        refreshSelection()
    }

    func selectAction(_ id: String) {
        _ = view
        guard ShortcutCatalog.action(id) != nil else { return }
        selectedID = id
        searchField.stringValue = ""
        filterCommands("")
        revealSelectedCommand()
    }

    func revealSelectedCommand() {
        view.layoutSubtreeIfNeeded()
        tableView.scrollRowToVisible(tableView.selectedRow)
    }

    func refresh() {
        guard isViewLoaded else { return }
        let id = selectedID
        isUpdatingSelection = true
        defer { isUpdatingSelection = false }
        tableView.reloadData()
        if let row = visibleActions.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        selectedID = id
        refreshSelection()
    }

    private func refreshSelection() {
        let action = visibleActions.first { $0.id == selectedID }
        selectionLabel.stringValue = action.map { $0.category + " → " + $0.title } ?? "No matching commands"
        recorder.isEnabled = action != nil; clearButton.isEnabled = action != nil; resetButton.isEnabled = action != nil
        recorder.shortcut = store.shortcut(for: selectedID) ?? .init(keyEquivalent: "", modifierFlags: [])
        if recorder.shortcut.keyEquivalent.isEmpty && !recorder.isRecording { recorder.title = "Record Shortcut…" }
    }

    @discardableResult
    private func apply(_ shortcut: AppPreferences.Shortcut?) -> String? {
        do {
            try store.set(shortcut, for: selectedID, menu: NSApp.mainMenu)
            message.stringValue = ""
            refresh()
            return nil
        } catch {
            message.stringValue = error.localizedDescription
            return error.localizedDescription
        }
    }

    @objc func clearSelected(_ sender: Any?) { recorder.stopRecording(); _ = apply(nil) }
    @objc func resetSelected(_ sender: Any?) {
        recorder.stopRecording()
        do { try store.reset(selectedID); message.stringValue = ""; refresh() }
        catch { message.stringValue = error.localizedDescription }
    }
    @objc func resetAll(_ sender: Any?) {
        recorder.stopRecording(); store.resetAll(); message.stringValue = ""; refresh()
    }
    override func viewWillDisappear() { super.viewWillDisappear(); recorder.stopRecording() }
    deinit { if let observer { store.notificationCenter.removeObserver(observer) } }
}

import AppKit

/// Finder's "Rename Finder Items" window, rebuilt as a sheet: the mode popup,
/// the fields of the chosen mode, and — Tursora's addition, as in Dolphin's
/// batch rename — a live preview of every old name and the name it becomes.
/// The sheet never mutates anything itself; it hands the plan to its owner.
final class BatchRenameSheetController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    /// One item to rename, with the date "Name and Date" uses.
    struct Target {
        let url: URL
        let name: String
        let date: Date
        init(url: URL, name: String? = nil, date: Date = Date()) {
            self.url = url
            self.name = name ?? url.lastPathComponent
            self.date = date
        }
    }

    // A sheet is retained by nothing else once presented: keep it alive here,
    // and let the owner (and the smoke test) find the sheet a window is showing.
    // The parent is recorded when the sheet is presented, because NSWindow sets
    // sheetParent only once the presentation has actually started.
    private static var retained: [ObjectIdentifier: BatchRenameSheetController] = [:]
    static func presented(in parent: NSWindow) -> BatchRenameSheetController? {
        retained.values.first { $0.parentWindow === parent }
    }
    private(set) weak var parentWindow: NSWindow?
    private(set) var isDismissed = false

    let targets: [Target]
    let entries: [BatchRename.Entry]
    /// Directory path → names that directory already holds. Supplied by the
    /// owner; the sheet must not read the filesystem.
    var siblings: [String: Set<String>]
    var onApply: (([FileOperations.RenameRequest]) -> Void)?
    var onClose: (() -> Void)?

    // Controls — internal so the smoke test can drive them like a user.
    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let findField = NSTextField(string: "")
    let replaceField = NSTextField(string: "")
    let addTextField = NSTextField(string: "")
    let addWherePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let nameFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let formatWherePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let customFormatField = NSTextField(string: "")
    let startNumberField = NSTextField(string: "1")
    let exampleLabel = NSTextField(labelWithString: "Example: ")
    let messageLabel = NSTextField(labelWithString: "")
    let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let previewTable = NSTableView()

    private let replacePanel = NSGridView()
    private let addPanel = NSGridView()
    private let formatPanel = NSGridView()
    private var startNumberRow: NSGridRow?

    private(set) var previewRows: [(old: String, new: String)] = []
    private(set) var problem: BatchRename.Problem?
    var validationMessage: String? { problem?.message }
    var canRename: Bool { renameButton.isEnabled }

    init(targets: [Target], siblings: [String: Set<String>]) {
        self.targets = targets
        self.entries = targets.map { BatchRename.Entry(url: $0.url, date: $0.date) }
        self.siblings = siblings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = BatchRename.sheetTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Presentation

    @discardableResult
    static func present(targets: [Target], siblings: [String: Set<String>], in parent: NSWindow,
                        onApply: @escaping ([FileOperations.RenameRequest]) -> Void) -> BatchRenameSheetController? {
        guard targets.count > 1 else { return nil }
        let controller = BatchRenameSheetController(targets: targets, siblings: siblings)
        guard let sheet = controller.window else { return nil }
        controller.onApply = onApply
        controller.parentWindow = parent
        retained[ObjectIdentifier(sheet)] = controller
        parent.beginSheet(sheet) { _ in controller.finish() }
        sheet.makeFirstResponder(controller.findField)
        return controller
    }

    /// Closes the sheet. The controller stops being "the sheet this window is
    /// showing" at once, even though ending a sheet finishes asynchronously.
    func dismiss() {
        guard let sheet = window, !isDismissed else { return }
        finish()
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
    }

    /// Runs once, whether the sheet was closed by a button or by its parent.
    private func finish() {
        guard !isDismissed, let sheet = window else { return }
        isDismissed = true
        Self.retained.removeValue(forKey: ObjectIdentifier(sheet))
        onClose?()
    }

    // MARK: - Layout (Finder's window, top to bottom)

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: BatchRename.sheetTitle)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        modePopup.addItems(withTitles: BatchRename.Mode.titles)
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modePopup.setAccessibilityIdentifier("batchRenameMode")

        for popup in [addWherePopup, formatWherePopup] {
            popup.addItems(withTitles: BatchRename.Position.allCases.map(\.title))
            popup.target = self
            popup.action = #selector(fieldChanged(_:))
        }
        nameFormatPopup.addItems(withTitles: BatchRename.FormatKind.allCases.map(\.title))
        nameFormatPopup.target = self
        nameFormatPopup.action = #selector(formatKindChanged(_:))

        for field in [findField, replaceField, addTextField, customFormatField, startNumberField] {
            field.delegate = self
            field.target = self
            field.action = #selector(fieldChanged(_:))
            field.isEditable = true
        }
        findField.setAccessibilityIdentifier("batchRenameFind")
        replaceField.setAccessibilityIdentifier("batchRenameReplace")
        addTextField.setAccessibilityIdentifier("batchRenameAddText")
        customFormatField.setAccessibilityIdentifier("batchRenameCustomFormat")
        startNumberField.setAccessibilityIdentifier("batchRenameStartNumber")

        buildPanels()

        exampleLabel.textColor = .secondaryLabelColor
        exampleLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .systemRed
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setAccessibilityIdentifier("batchRenameMessage")

        let preview = buildPreviewTable()

        renameButton.bezelStyle = .rounded
        renameButton.keyEquivalent = "\r"
        renameButton.target = self
        renameButton.action = #selector(performRename(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelRename(_:))

        let header = NSStackView(views: [title, modePopup])
        header.orientation = .horizontal
        header.spacing = 8
        let buttons = NSStackView(views: [messageLabel, NSView(), cancelButton, renameButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [header, replacePanel, addPanel, formatPanel, exampleLabel, preview, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            header.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            buttons.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            preview.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        applyMode()
    }

    private func buildPanels() {
        replacePanel.addRow(with: [NSTextField(labelWithString: "Find:"), findField])
        replacePanel.addRow(with: [NSTextField(labelWithString: "Replace with:"), replaceField])
        addPanel.addRow(with: [NSTextField(labelWithString: "Add Text:"), addTextField])
        addPanel.addRow(with: [NSTextField(labelWithString: "Where:"), addWherePopup])
        formatPanel.addRow(with: [NSTextField(labelWithString: "Name Format:"), nameFormatPopup])
        formatPanel.addRow(with: [NSTextField(labelWithString: "Where:"), formatWherePopup])
        formatPanel.addRow(with: [NSTextField(labelWithString: "Custom Format:"), customFormatField])
        startNumberRow = formatPanel.addRow(with: [NSTextField(labelWithString: "Start numbers at:"), startNumberField])
        for panel in [replacePanel, addPanel, formatPanel] {
            panel.rowSpacing = 8
            panel.columnSpacing = 8
            panel.column(at: 0).xPlacement = .trailing
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.column(at: 1).width = 320
        }
    }

    private func buildPreviewTable() -> NSScrollView {
        let old = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("old"))
        old.title = "Current Name"
        old.width = 220
        let new = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("new"))
        new.title = "New Name"
        new.width = 220
        previewTable.addTableColumn(old)
        previewTable.addTableColumn(new)
        previewTable.dataSource = self
        previewTable.delegate = self
        previewTable.rowSizeStyle = .custom
        previewTable.rowHeight = 18
        previewTable.usesAlternatingRowBackgroundColors = true
        previewTable.style = .plain
        previewTable.allowsEmptySelection = true
        previewTable.setAccessibilityIdentifier("batchRenamePreview")
        let scroll = NSScrollView()
        scroll.documentView = previewTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    // MARK: - Mode

    /// Which of Finder's three modes the popup shows.
    var modeIndex: Int { modePopup.indexOfSelectedItem }

    func selectMode(_ index: Int) {
        guard index >= 0, index < modePopup.numberOfItems else { return }
        modePopup.selectItem(at: index)
        applyMode()
    }

    func selectFormatKind(_ kind: BatchRename.FormatKind) {
        nameFormatPopup.selectItem(withTitle: kind.title)
        applyStartNumberVisibility()
        refresh()
    }

    /// The mode the controls currently describe.
    var mode: BatchRename.Mode {
        switch modeIndex {
        case 1:
            return .add(text: addTextField.stringValue, position: position(addWherePopup))
        case 2:
            let kind = BatchRename.FormatKind.allCases.first { $0.title == nameFormatPopup.titleOfSelectedItem } ?? .nameAndIndex
            return .format(kind: kind, custom: customFormatField.stringValue,
                           start: Int(startNumberField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1,
                           position: position(formatWherePopup))
        default:
            return .replace(find: findField.stringValue, replacement: replaceField.stringValue)
        }
    }

    private func position(_ popup: NSPopUpButton) -> BatchRename.Position {
        BatchRename.Position.allCases.first { $0.title == popup.titleOfSelectedItem } ?? .afterName
    }

    private func applyMode() {
        replacePanel.isHidden = modeIndex != 0
        addPanel.isHidden = modeIndex != 1
        formatPanel.isHidden = modeIndex != 2
        exampleLabel.isHidden = false
        applyStartNumberVisibility()
        refresh()
    }

    /// Finder shows "Start numbers at:" only for the numbering formats.
    private func applyStartNumberVisibility() {
        guard let row = startNumberRow else { return }
        if case .format(let kind, _, _, _) = mode { row.isHidden = kind == .nameAndDate }
        else { row.isHidden = true }
    }

    var isStartNumberVisible: Bool { !(startNumberRow?.isHidden ?? true) }

    // MARK: - Live preview

    /// Sets a field the way typing does, preview included.
    func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        refresh()
    }

    func refresh() {
        let names = BatchRename.plan(entries, mode: mode)
        previewRows = zip(targets.map(\.name), names).map { (old: $0, new: $1) }
        problem = BatchRename.validate(names, for: entries, siblings: siblings)
        messageLabel.stringValue = problem?.message ?? ""
        renameButton.isEnabled = problem == nil
        exampleLabel.stringValue = "Example: " + (names.first ?? "")
        previewTable.reloadData()
    }

    /// The plan as rename requests, in selection order.
    var requests: [FileOperations.RenameRequest] {
        zip(targets, BatchRename.plan(entries, mode: mode)).map { .init(url: $0.url, newName: $1) }
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: Any?) { applyMode() }
    @objc private func formatKindChanged(_ sender: Any?) { applyStartNumberVisibility(); refresh() }
    @objc private func fieldChanged(_ sender: Any?) { refresh() }
    func controlTextDidChange(_ obj: Notification) { refresh() }

    @objc func performRename(_ sender: Any?) {
        guard problem == nil else { return }
        let plan = requests
        dismiss()
        onApply?(plan)
    }

    @objc func cancelRename(_ sender: Any?) { dismiss() }

    // MARK: - Preview table

    func numberOfRows(in tableView: NSTableView) -> Int { previewRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, previewRows.indices.contains(row) else { return nil }
        let isNew = tableColumn.identifier.rawValue == "new"
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? NSTableCellView.make(identifier: identifier, withIcon: false)
        let entry = previewRows[row]
        cell.textField?.stringValue = isNew ? entry.new : entry.old
        cell.textField?.textColor = isNew && entry.new != entry.old ? .labelColor : .secondaryLabelColor
        return cell
    }
}

import AppKit

/// Pane-owned search conditions. Query execution and filesystem access belong to the browser/model.
final class SearchPanelController: NSViewController, NSTextFieldDelegate, NSMenuDelegate {
    let nameField = NSTextField(string: "")
    let contentField = NSTextField(string: "")
    let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Where a content search looks. Only meaningful with text in Content,
    /// so it is disabled until there is some.
    let contentSourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let datePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let saveNameField = NSTextField(string: "")
    let savedPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let optionsButton = NSButton(title: "Search Options…", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    let closeButton = NSButton(title: "Close", target: nil, action: nil)
    let savedDisclosure = NSButton(title: "Saved Searches", target: nil, action: nil)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let openSavedButton = NSButton(title: "Open", target: nil, action: nil)
    let deleteSavedButton = NSButton(title: "Delete", target: nil, action: nil)
    let afterCheckbox = NSButton(checkboxWithTitle: "Since", target: nil, action: nil)
    let beforeCheckbox = NSButton(checkboxWithTitle: "Before", target: nil, action: nil)
    let afterPicker = NSDatePicker()
    let beforePicker = NSDatePicker()
    let statusLabel = NSTextField(wrappingLabelWithString: "Search this folder and its subfolders.")
    let scopeLabel = NSTextField(labelWithString: "")

    var onSearch: ((SearchRequest) -> Void)?
    var onCancel: (() -> Void)?
    var onClear: (() -> Void)?
    var onClose: (() -> Void)?
    var onShowOptions: (() -> Void)?
    var onFocusName: (() -> Void)?
    private(set) var isRunning = false
    private(set) var isShowingOptions = false
    private(set) var rootURL = FileManager.default.homeDirectoryForCurrentUser
    private let store: SavedSearchStore
    private let progress = NSProgressIndicator()
    private let customDateRows = NSStackView()
    private let savedRows = NSStackView()
    private let compactRows = NSStackView()
    private let optionRows = NSStackView()
    private var pendingSearch: DispatchWorkItem?
    private var pendingSearchGeneration = 0
    private var savedIDs: [UUID] = []
    private var storeObserver: NSObjectProtocol?
    private static let indexedTextExplanation = "Searches text indexed by macOS; only supported files. Unindexed or excluded files may be missing."
    private static let scanExplanation = "Reads the files themselves, so folders macOS has not indexed are searched too. Slower, and it skips binary files."

    private enum DateChoice: Int, CaseIterable {
        case any, today, lastSevenDays, lastThirtyDays, custom

        var title: String {
            switch self {
            case .any: return "Modified Anytime"
            case .today: return "Modified Today"
            case .lastSevenDays: return "Last 7 Days"
            case .lastThirtyDays: return "Last 30 Days"
            case .custom: return "Custom Dates…"
            }
        }
    }

    init(store: SavedSearchStore = .shared) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        storeObserver = NotificationCenter.default.addObserver(forName: SavedSearchStore.didChange,
                                                                 object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isViewLoaded else { return }
            self.refreshSavedSearches()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        view = background

        let currentFolder = NSTextField(labelWithString: "Current Folder")
        currentFolder.font = .systemFont(ofSize: 11)
        currentFolder.textColor = .secondaryLabelColor
        currentFolder.lineBreakMode = .byTruncatingTail
        currentFolder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wire(optionsButton, #selector(showOptions(_:)))
        optionsButton.toolTip = "Search subfolders or add search conditions"
        compactRows.orientation = .horizontal
        compactRows.alignment = .centerY
        compactRows.spacing = 5
        for item in [currentFolder, NSView(), optionsButton] { compactRows.addArrangedSubview(item) }
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        closeButton.toolTip = "Close search and return to the folder"
        wire(closeButton, #selector(close(_:)))
        wire(savedDisclosure, #selector(toggleSavedSearches(_:)))
        savedDisclosure.setButtonType(.pushOnPushOff)
        savedDisclosure.toolTip = "Save, open, or delete saved search conditions"
        let header = row([progress, NSView(), savedDisclosure, closeButton])

        configureField(nameField, placeholder: "Name contains", label: "Search File Name")
        // The toolbar owns the visible query field. Keep this storage control
        // detached so it cannot become a second editor or accessibility input.
        nameField.isHidden = true
        configureField(contentField, placeholder: "Text contains", label: "Search File Contents")
        contentField.toolTip = Self.indexedTextExplanation
        configureField(saveNameField, placeholder: "Name this saved search", label: "Saved Search Name")

        scopePopup.addItems(withTitles: ["This Folder + Subfolders", "Home Folder + Subfolders"])
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))
        scopePopup.setAccessibilityLabel("Search Scope")
        scopeLabel.font = .systemFont(ofSize: 11)
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingMiddle
        scopeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scopeLabel.setAccessibilityLabel("Search Root Folder")

        contentSourcePopup.addItems(withTitles: ContentSource.allCases.map(\.title))
        contentSourcePopup.setAccessibilityLabel("Search File Contents Using")
        contentSourcePopup.target = self
        contentSourcePopup.action = #selector(conditionsChanged(_:))
        kindPopup.addItems(withTitles: SearchKind.allCases.map(\.title))
        kindPopup.setAccessibilityLabel("Search File Type")
        kindPopup.target = self
        kindPopup.action = #selector(conditionsChanged(_:))
        datePopup.addItems(withTitles: DateChoice.allCases.map(\.title))
        datePopup.setAccessibilityLabel("Search Modification Date")
        datePopup.target = self
        datePopup.action = #selector(dateChanged(_:))
        let conditions = row([kindPopup, datePopup])
        kindPopup.widthAnchor.constraint(equalTo: datePopup.widthAnchor).isActive = true

        customDateRows.orientation = .vertical
        customDateRows.alignment = .leading
        customDateRows.spacing = 4
        for (checkbox, picker) in [(afterCheckbox, afterPicker), (beforeCheckbox, beforePicker)] {
            checkbox.target = self
            checkbox.action = #selector(dateBoundChanged(_:))
            checkbox.widthAnchor.constraint(equalToConstant: 66).isActive = true
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinute]
            picker.dateValue = Calendar.current.startOfDay(for: Date())
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            picker.setAccessibilityLabel(checkbox === afterCheckbox ? "Modified Since" : "Modified Before")
            picker.target = self
            picker.action = #selector(conditionsChanged(_:))
            let dateRow = row([checkbox, picker])
            customDateRows.addArrangedSubview(dateRow)
            dateRow.widthAnchor.constraint(equalTo: customDateRows.widthAnchor).isActive = true
        }
        afterPicker.toolTip = "Include files modified at or after this date and time"
        beforePicker.toolTip = "Exclude files modified at or after this date and time"
        customDateRows.isHidden = true

        wire(cancelButton, #selector(cancel(_:)))
        wire(clearButton, #selector(clear(_:)))
        wire(saveButton, #selector(save(_:)))
        wire(openSavedButton, #selector(openSaved(_:)))
        wire(deleteSavedButton, #selector(deleteSaved(_:)))
        cancelButton.isEnabled = false
        clearButton.toolTip = "Cancel the current query and clear name, content, type, and date conditions"
        saveButton.toolTip = "Save the conditions and folder shown above"
        openSavedButton.toolTip = "Restore and run the selected saved search"
        deleteSavedButton.toolTip = "Delete only the saved conditions; files are unchanged"
        let actions = row([cancelButton, clearButton, NSView()])
        let saveRow = row([saveNameField, saveButton])
        savedPopup.setAccessibilityLabel("Saved Searches")
        savedPopup.menu?.delegate = self
        savedPopup.target = self
        savedPopup.action = #selector(savedSelectionChanged(_:))
        let savedRow = row([savedPopup, openSavedButton, deleteSavedButton])
        savedRows.orientation = .vertical
        savedRows.alignment = .leading
        savedRows.spacing = 5
        for item in [saveRow, savedRow] {
            savedRows.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: savedRows.widthAnchor).isActive = true
        }
        savedRows.isHidden = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setAccessibilityIdentifier("searchStatus")
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let rows: [NSView] = [header, labeled("Content", contentField),
                              labeled("Using", contentSourcePopup),
                              labeled("In", scopePopup), scopeLabel, conditions, customDateRows,
                              actions, savedRows, statusLabel]
        optionRows.orientation = .vertical
        optionRows.alignment = .leading
        optionRows.spacing = 5
        for item in rows {
            optionRows.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: optionRows.widthAnchor).isActive = true
        }
        let stack = NSStackView(views: [compactRows, optionRows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        // The browser collapses this hidden pane accessory to zero height.
        // Its content can retain its natural height without conflicting with that constraint.
        let bottom = stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            bottom,
        ])
        for item in [compactRows, optionRows] { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        for popup in [scopePopup, kindPopup, datePopup, savedPopup] {
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        updateScopeLabel()
        refreshSavedSearches()
        updatePresentation()
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        return stack
    }

    private func labeled(_ text: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.widthAnchor.constraint(equalToConstant: 46).isActive = true
        return row([label, control])
    }

    private func configureField(_ field: NSTextField, placeholder: String, label: String) {
        field.placeholderString = placeholder
        field.setAccessibilityLabel(label)
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = self
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func wire(_ button: NSButton, _ action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    func configure(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        _ = view
        updateScopeLabel()
    }

    func present(request: SearchRequest) {
        _ = view
        cancelPendingSearch()
        let previous = currentRequest
        let keepsDateChoice = previous.modifiedAfter == request.modifiedAfter
            && previous.modifiedBefore == request.modifiedBefore
        let existingDateChoice = DateChoice(rawValue: datePopup.indexOfSelectedItem) ?? .any
        rootURL = request.rootURL
        nameField.stringValue = request.name
        if contentField.stringValue != request.content { contentField.stringValue = request.content }
        scopePopup.selectItem(at: request.scope == .home ? 1 : 0)
        kindPopup.selectItem(at: SearchKind.allCases.firstIndex(of: request.kind) ?? 0)
        contentSourcePopup.selectItem(at: ContentSource.allCases.firstIndex(of: request.contentSource) ?? 0)
        syncContentSourceAvailability()
        let hasDates = request.modifiedAfter != nil || request.modifiedBefore != nil
        let dateChoice = !hasDates ? DateChoice.any : keepsDateChoice ? existingDateChoice : .custom
        datePopup.selectItem(at: dateChoice.rawValue)
        afterCheckbox.state = request.modifiedAfter == nil ? .off : .on
        beforeCheckbox.state = request.modifiedBefore == nil ? .off : .on
        if let date = request.modifiedAfter { afterPicker.dateValue = date }
        if let date = request.modifiedBefore { beforePicker.dateValue = date }
        updateDateControls()
        updateScopeLabel()
    }

    var currentRequest: SearchRequest {
        _ = view
        let dates = selectedDateBounds()
        return SearchRequest(rootURL: rootURL, scope: scopePopup.indexOfSelectedItem == 1 ? .home : .currentFolder,
                             name: nameField.currentEditor()?.string ?? nameField.stringValue,
                             content: contentField.currentEditor()?.string ?? contentField.stringValue,
                             contentSource: ContentSource.allCases[max(0, contentSourcePopup.indexOfSelectedItem)],
                             kind: SearchKind.allCases[max(0, kindPopup.indexOfSelectedItem)],
                             modifiedAfter: dates.0, modifiedBefore: dates.1)
    }

    /// The setting only means something with text to look for, and its tooltip
    /// explains the trade-off the user is choosing between.
    func syncContentSourceAvailability() {
        let text = contentField.currentEditor()?.string ?? contentField.stringValue
        contentSourcePopup.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let source = ContentSource.allCases[max(0, contentSourcePopup.indexOfSelectedItem)]
        contentSourcePopup.toolTip = source == .index ? Self.indexedTextExplanation : Self.scanExplanation
        contentField.toolTip = contentSourcePopup.toolTip
    }

    private func selectedDateBounds() -> (Date?, Date?) {
        let choice = DateChoice(rawValue: datePopup.indexOfSelectedItem) ?? .any
        if choice == .any { return (nil, nil) }
        if choice == .custom {
            return (afterCheckbox.state == .on ? afterPicker.dateValue : nil,
                    beforeCheckbox.state == .on ? beforePicker.dateValue : nil)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = choice == .lastSevenDays ? -6 : choice == .lastThirtyDays ? -29 : 0
        return (calendar.date(byAdding: .day, value: days, to: today),
                calendar.date(byAdding: .day, value: 1, to: today))
    }

    func focusName() {
        onFocusName?()
    }

    func setShowsOptions(_ shown: Bool) {
        _ = view
        isShowingOptions = shown
        if !shown { cancelPendingSearch() }
        updatePresentation()
    }

    private func updatePresentation() {
        compactRows.isHidden = isShowingOptions
        optionRows.isHidden = !isShowingOptions
    }

    @objc private func showOptions(_ sender: Any?) { onShowOptions?() }

    func setNameQuery(_ text: String, scheduleSearch: Bool = true) {
        guard nameField.stringValue != text else {
            if !scheduleSearch { cancelPendingSearch() }
            return
        }
        nameField.stringValue = text
        if scheduleSearch { self.scheduleSearch() } else { cancelPendingSearch() }
    }

    func cancelPendingSearch() {
        pendingSearchGeneration += 1
        pendingSearch?.cancel()
        pendingSearch = nil
        cancelButton.isEnabled = isRunning
    }

    func scheduleSearch() {
        cancelPendingSearch()
        guard isShowingOptions else { return }
        guard !clearIfEmpty(currentRequest) else { return }
        let generation = pendingSearchGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isShowingOptions, self.pendingSearchGeneration == generation else { return }
            self.search(nil)
        }
        pendingSearch = work
        cancelButton.isEnabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    func update(status: String, resultCount: Int, isRunning: Bool, isError: Bool = false) {
        _ = view
        self.isRunning = isRunning
        cancelButton.isEnabled = isRunning || pendingSearch != nil
        if isRunning { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let count = "\(resultCount) \(resultCount == 1 ? "result" : "results")"
        let fullStatus = status.isEmpty ? count : "\(count) · \(status)"
        if status.contains(SearchRequest.contentLimitMessage) {
            // Keep the index boundary visible even when a long error or path
            // exceeds the compact status area's three lines.
            let detail = status.replacingOccurrences(of: SearchRequest.contentLimitMessage, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            statusLabel.stringValue = "\(count) · \(Self.indexedTextExplanation)\n\(detail)"
        } else { statusLabel.stringValue = fullStatus }
        statusLabel.toolTip = statusLabel.stringValue
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    @objc func search(_ sender: Any?) {
        cancelPendingSearch()
        let request = currentRequest
        guard !clearIfEmpty(request) else { return }
        guard validDates(request) else { return }
        onSearch?(request)
    }

    @objc func cancel(_ sender: Any?) { cancelPendingSearch(); onCancel?() }

    @objc func clear(_ sender: Any?) {
        cancelPendingSearch()
        let scope = scopePopup.indexOfSelectedItem
        if let onClear { onClear() } else { onCancel?() }
        present(request: SearchRequest(rootURL: rootURL, scope: scope == 1 ? .home : .currentFolder))
        statusLabel.stringValue = "Conditions cleared. Enter a filename or add search conditions."
        statusLabel.toolTip = statusLabel.stringValue
        statusLabel.textColor = .secondaryLabelColor
        focusName()
    }

    @objc func close(_ sender: Any?) { cancelPendingSearch(); onClose?() }

    @objc func toggleSavedSearches(_ sender: Any?) {
        savedRows.isHidden = savedDisclosure.state != .on
        if !savedRows.isHidden { refreshSavedSearches() }
    }

    @objc func save(_ sender: Any?) {
        let name = (saveNameField.currentEditor()?.string ?? saveNameField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showMessage("Enter a name to save these search conditions.", isError: true)
            view.window?.makeFirstResponder(saveNameField)
            return
        }
        let request = currentRequest
        guard validDates(request) else { return }
        let item = store.save(name: name, request: request)
        refreshSavedSearches(selecting: item.id)
        showMessage("Saved “\(item.name)”.")
    }

    @objc func openSaved(_ sender: Any?) {
        guard let item = selectedSavedSearch else { refreshSavedSearches(); return }
        present(request: item.request)
        saveNameField.stringValue = item.name
        search(sender)
    }

    @objc func deleteSaved(_ sender: Any?) {
        guard let item = selectedSavedSearch else { refreshSavedSearches(); return }
        store.delete(id: item.id)
        refreshSavedSearches()
        showMessage("Deleted saved conditions “\(item.name)”.")
    }

    private var selectedSavedSearch: SavedSearch? {
        let index = savedPopup.indexOfSelectedItem - 1
        guard savedIDs.indices.contains(index) else { return nil }
        return store.items.first { $0.id == savedIDs[index] }
    }

    func refreshSavedSearches(selecting id: UUID? = nil) {
        let previousIndex = savedPopup.indexOfSelectedItem - 1
        let selectedID = id ?? (savedIDs.indices.contains(previousIndex) ? savedIDs[previousIndex] : nil)
        let items = store.items
        savedIDs = items.map(\.id)
        savedPopup.removeAllItems()
        savedPopup.addItem(withTitle: items.isEmpty ? "No Saved Searches" : "Saved Searches…")
        let counts = Dictionary(grouping: items, by: \.name).mapValues(\.count)
        var occurrences: [String: Int] = [:]
        for item in items {
            // Explicit menu items preserve separate identities even when names repeat.
            let occurrence = (occurrences[item.name] ?? 0) + 1
            occurrences[item.name] = occurrence
            let count = counts[item.name] ?? 1
            let title = count > 1 ? "\(item.name) (\(occurrence) of \(count))" : item.name
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menuItem.toolTip = savedSummary(item.request)
            savedPopup.menu?.addItem(menuItem)
        }
        if let selectedID, let index = savedIDs.firstIndex(of: selectedID) {
            savedPopup.selectItem(at: index + 1)
        } else { savedPopup.selectItem(at: 0) }
        savedSelectionChanged(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshSavedSearches() }

    @objc private func savedSelectionChanged(_ sender: Any?) {
        let selected = selectedSavedSearch
        let hasSelection = selected != nil
        openSavedButton.isEnabled = hasSelection
        deleteSavedButton.isEnabled = hasSelection
        savedPopup.toolTip = selected.map { savedSummary($0.request) } ?? "Choose saved conditions, then Open"
    }

    private func savedSummary(_ request: SearchRequest) -> String {
        var lines = [request.effectiveRootURL.path,
                     request.trimmedName.isEmpty ? "Any filename" : "Name contains: \(request.name)",
                     request.trimmedContent.isEmpty ? "No content condition" : "Content contains: \(request.content)",
                     request.kind.title]
        if let date = request.modifiedAfter {
            lines.append("Since: " + DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
        }
        if let date = request.modifiedBefore {
            lines.append("Before: " + DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
        }
        return lines.joined(separator: "\n")
    }

    @objc private func scopeChanged(_ sender: Any?) {
        updateScopeLabel()
        conditionsChanged(sender)
    }

    @objc private func conditionsChanged(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .keyDown, [36, 76].contains(event.keyCode) {
            search(sender)
        } else { scheduleSearch() }
    }

    private func updateScopeLabel() {
        let url = scopePopup.indexOfSelectedItem == 1 ? FileManager.default.homeDirectoryForCurrentUser : rootURL
        scopeLabel.stringValue = url.path
        scopeLabel.toolTip = "Search recursively in \(url.path). Packages and ZIP contents are excluded."
    }

    @objc private func dateChanged(_ sender: Any?) {
        updateDateControls()
        conditionsChanged(sender)
    }

    private func updateDateControls() {
        customDateRows.isHidden = datePopup.indexOfSelectedItem != DateChoice.custom.rawValue
        afterPicker.isEnabled = afterCheckbox.state == .on
        beforePicker.isEnabled = beforeCheckbox.state == .on
    }

    @objc private func dateBoundChanged(_ sender: Any?) {
        afterPicker.isEnabled = afterCheckbox.state == .on
        beforePicker.isEnabled = beforeCheckbox.state == .on
        conditionsChanged(sender)
    }

    private func validDates(_ request: SearchRequest) -> Bool {
        if let after = request.modifiedAfter, let before = request.modifiedBefore, after >= before {
            showMessage("The Before date must be later than the Since date.", isError: true)
            return false
        }
        return true
    }

    /// Clearing the toolbar must not turn an empty query into a recursive
    /// enumeration of the entire selected scope.
    private func clearIfEmpty(_ request: SearchRequest) -> Bool {
        guard request.trimmedName.isEmpty, request.trimmedContent.isEmpty, request.kind == .any,
              request.modifiedAfter == nil, request.modifiedBefore == nil else { return false }
        if let onClear { onClear() } else { onCancel?() }
        showMessage("Enter a filename or add search conditions.")
        return true
    }

    private func showMessage(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.toolTip = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === saveNameField { saveButton.performClick(nil) }
            else { search(nil) }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if isRunning { cancelButton.performClick(nil) } else { closeButton.performClick(nil) }
            return true
        }
        return false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === contentField || field === nameField else { return }
        if field === contentField { syncContentSourceAvailability() }
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
            cancelPendingSearch()
            return
        }
        scheduleSearch()
    }

    deinit {
        pendingSearch?.cancel()
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }
}

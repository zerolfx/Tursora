import AppKit

/// One modeless panel per browser window. Every action resolves its owner's
/// active pane at execution, so a tab or split change cannot edit the old pane.
final class ViewOptionsWindowController: NSWindowController, NSWindowDelegate {
    static let propertiesDidChange = Notification.Name("Tursora.viewOptionsPropertiesChanged")
    private weak var browserOwner: MainWindowController?
    private var observers: [NSObjectProtocol] = []
    let locationLabel = NSTextField(labelWithString: "")
    let modeControl = NSPopUpButton()
    let sortControl = NSPopUpButton()
    let directionControl = NSPopUpButton()
    let groupControl = NSPopUpButton()
    let zoomControl = NSPopUpButton()
    let policyControl = NSPopUpButton()
    let hiddenControl = NSButton(checkboxWithTitle: "Show Hidden Files", target: nil, action: nil)
    let previewsControl = NSButton(checkboxWithTitle: "Show icon preview", target: nil, action: nil)
    let sizesControl = NSButton(checkboxWithTitle: "Calculate all sizes", target: nil, action: nil)
    let defaultButton = NSButton(title: "Use Current Settings as Default", target: nil, action: nil)
    let resetButton = NSButton(title: "Restore Folder Defaults", target: nil, action: nil)
    let resetWidthsButton = NSButton(title: "Reset Column Widths", target: nil, action: nil)
    private(set) var columnControls: [FileListViewController.Column: NSButton] = [:]
    private let scopeLabel = NSTextField(wrappingLabelWithString: "")
    private let modes: [ViewMode] = [.details, .icons, .columns]
    private let sorts: [DirectoryModel.SortKey] = [.name, .kind, .size, .dateModified, .dateCreated, .dateLastOpened, .dateAdded]

    init(owner: MainWindowController) {
        self.browserOwner = owner
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 620),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "View Options"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        buildContent()
        observers.append(NotificationCenter.default.addObserver(forName: Self.propertiesDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let self, let pane = notification.object as? BrowserViewController,
                  pane === self.browserOwner?.browser else { return }
            self.refresh()
        })
        observers.append(NotificationCenter.default.addObserver(forName: DirectoryViewPropertiesStore.didChange,
                                                                object: owner.browser.viewPropertiesStore, queue: .main) { [weak self] _ in
            // Pane observers may still be restoring the new properties.
            DispatchQueue.main.async { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner.window, queue: .main) { [weak self] _ in
            self?.close()
        })
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func show() {
        refresh()
        if window?.isVisible != true, let frame = browserOwner?.window?.frame, let panel = window {
            panel.setFrameTopLeftPoint(NSPoint(x: max(0, frame.maxX - panel.frame.width - 24), y: frame.maxY - 48))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        locationLabel.font = .boldSystemFont(ofSize: 13)
        locationLabel.lineBreakMode = .byTruncatingMiddle
        add(locationLabel)
        modeControl.addItems(withTitles: ["List", "Icons", "Columns"])
        sortControl.addItems(withTitles: sorts.map { GroupKey(rawValue: $0.rawValue)?.title ?? "Name" })
        directionControl.addItems(withTitles: ["Ascending", "Descending"])
        groupControl.addItems(withTitles: GroupKey.allCases.map(\.title))
        policyControl.addItems(withTitles: ["Remember each folder", "Use shared settings"])
        let entries: [(String, NSPopUpButton, Selector)] = [
            ("View:", modeControl, #selector(changeMode(_:))),
            ("Sort By:", sortControl, #selector(changeSort(_:))),
            ("Order:", directionControl, #selector(changeDirection(_:))),
            ("Group By:", groupControl, #selector(changeGroup(_:))),
            ("Icon size:", zoomControl, #selector(changeZoom(_:))),
            ("Folder views:", policyControl, #selector(changePolicy(_:))),
        ]
        let grid = NSGridView(views: entries.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        for (_, control, action) in entries { control.target = self; control.action = action }
        add(grid)
        for (control, action) in [(hiddenControl, #selector(changeHidden(_:))),
                                  (previewsControl, #selector(changePreviews(_:))),
                                  (sizesControl, #selector(changeSizes(_:)))] {
            control.target = self
            control.action = action
            add(control)
        }
        add(NSTextField(labelWithString: "Show Columns:"))
        let columns = FileListViewController.optionalColumns
        var rows: [[NSView]] = []
        for pairStart in stride(from: 0, to: columns.count, by: 2) {
            var row: [NSView] = []
            for index in pairStart..<min(columns.count, pairStart + 2) {
                let column = columns[index]
                let button = NSButton(checkboxWithTitle: column.title, target: self, action: #selector(changeColumn(_:)))
                button.identifier = column.id
                columnControls[column] = button
                row.append(button)
            }
            if row.count == 1 { row.append(NSView()) }
            rows.append(row)
        }
        let columnGrid = NSGridView(views: rows)
        columnGrid.rowSpacing = 5
        add(columnGrid)
        for (button, action) in [(resetWidthsButton, #selector(resetWidths(_:))),
                                 (defaultButton, #selector(useDefault(_:))),
                                 (resetButton, #selector(resetFolder(_:)))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            add(button)
        }
        scopeLabel.font = .systemFont(ofSize: 11)
        scopeLabel.textColor = .secondaryLabelColor
        add(scopeLabel)
        content.layoutSubtreeIfNeeded()
        // Let native controls determine the height; neither system font
        // metrics nor wrapping in the scope explanation should clip buttons.
        window?.setContentSize(NSSize(width: 430, height: max(620, stack.fittingSize.height + 36)))
    }

    func refresh() {
        guard let pane = browserOwner?.browser else { return }
        let properties = pane.currentViewProperties
        locationLabel.stringValue = pane.model.isSearchResults ? "Search Results" : pane.currentURL.map { $0.lastPathComponent.isEmpty ? "/" : $0.lastPathComponent } ?? "View Options"
        locationLabel.toolTip = pane.currentURL?.path
        modeControl.selectItem(at: modes.firstIndex(of: pane.viewMode) ?? 0)
        sortControl.selectItem(at: sorts.firstIndex(of: properties.sortKey) ?? 0)
        directionControl.selectItem(at: properties.ascending ? 0 : 1)
        groupControl.selectItem(at: GroupKey.allCases.firstIndex(of: properties.groupKey) ?? 0)
        zoomControl.removeAllItems()
        zoomControl.addItems(withTitles: ZoomLevel.sizes(for: pane.viewMode).map { "\(Int($0)) pt" })
        zoomControl.selectItem(at: pane.zoomIndex)
        hiddenControl.state = properties.showHidden ? .on : .off
        previewsControl.state = properties.showPreviews ? .on : .off
        sizesControl.state = properties.calculateAllSizes ? .on : .off
        sizesControl.isEnabled = pane.canCalculateFolderSizes
        for (column, control) in columnControls {
            control.state = pane.fileList.isColumnVisible(column) ? .on : .off
            control.isEnabled = pane.viewMode == .details
        }
        let perDirectory = pane.viewPropertiesStore.policy == .perDirectory
        policyControl.selectItem(at: perDirectory ? 0 : 1)
        defaultButton.isEnabled = pane.canPersistViewProperties
        resetButton.isEnabled = pane.canPersistViewProperties && perDirectory
        resetWidthsButton.isEnabled = pane.viewMode != .icons
        scopeLabel.stringValue = !pane.canPersistViewProperties
            ? "Changes here last only in this pane. Folder defaults are unavailable for search and archive contents."
            : (perDirectory ? "Changes are saved for this folder. Other open panes keep their current view until they revisit it."
                            : "Changes update shared settings for ordinary folders. Remembered folder settings are retained.")
    }

    @objc private func changeMode(_ sender: NSPopUpButton) {
        guard modes.indices.contains(sender.indexOfSelectedItem) else { return }
        browserOwner?.browser.setViewMode(modes[sender.indexOfSelectedItem]); refresh()
    }
    @objc private func changeSort(_ sender: NSPopUpButton) {
        guard let pane = browserOwner?.browser, sorts.indices.contains(sender.indexOfSelectedItem) else { return }
        pane.fileList.setSort(key: sorts[sender.indexOfSelectedItem], ascending: pane.model.ascending); refresh()
    }
    @objc private func changeDirection(_ sender: NSPopUpButton) {
        guard let pane = browserOwner?.browser else { return }
        pane.fileList.setSort(key: pane.model.sortKey, ascending: sender.indexOfSelectedItem == 0); refresh()
    }
    @objc private func changeGroup(_ sender: NSPopUpButton) {
        guard GroupKey.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        browserOwner?.browser.setGroupKey(GroupKey.allCases[sender.indexOfSelectedItem]); refresh()
    }
    @objc private func changeZoom(_ sender: NSPopUpButton) { browserOwner?.browser.setZoomIndex(sender.indexOfSelectedItem); refresh() }
    @objc private func changePolicy(_ sender: NSPopUpButton) {
        browserOwner?.browser.setViewPropertiesPolicy(sender.indexOfSelectedItem == 0 ? .perDirectory : .unified); refresh()
    }
    @objc private func changeHidden(_ sender: NSButton) { browserOwner?.browser.showsHiddenFiles = sender.state == .on; refresh() }
    @objc private func changePreviews(_ sender: NSButton) { browserOwner?.browser.setShowsPreviews(sender.state == .on); refresh() }
    @objc private func changeSizes(_ sender: NSButton) {
        guard let pane = browserOwner?.browser, pane.canCalculateFolderSizes else { return }
        pane.fileList.setCalculatesAllSizes(sender.state == .on); refresh()
    }
    @objc private func changeColumn(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let column = FileListViewController.Column(rawValue: raw) else { return }
        browserOwner?.browser.fileList.setColumn(column, visible: sender.state == .on); refresh()
    }
    @objc private func resetWidths(_ sender: Any?) {
        guard let pane = browserOwner?.browser else { return }
        if pane.viewMode == .details { pane.fileList.setColumnWidths([:]) }
        if pane.viewMode == .columns { pane.columnView.setColumnWidths([]) }
        pane.persistViewProperties(); refresh()
    }
    @objc private func useDefault(_ sender: Any?) { browserOwner?.browser.useCurrentViewAsDefault(); refresh() }
    @objc private func resetFolder(_ sender: Any?) { browserOwner?.browser.restoreDirectoryViewDefaults(); refresh() }
}

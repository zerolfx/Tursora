import AppKit

/// Runs a palette row. Commands go back through the application's own menu:
/// the `NSMenuItem` whose identifier equals the catalog ID is validated on the
/// window's responder chain and then dispatched with `NSApp.sendAction`, so a
/// command behaves exactly as it does from the menu bar. Catalog commands that
/// have no menu item (the File View keys and the window aliases) take the same
/// route `ShortcutDispatcher` uses for their key events. Folder rows navigate
/// the active pane.
enum CommandPaletteRunner {

    /// Depth-first search of the main menu for a command's item.
    static func menuItem(id: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.action != nil, item.identifier?.rawValue == id { return item }
            if let found = menuItem(id: id, in: item.submenu) { return found }
        }
        return nil
    }

    /// Refreshes every submenu's validation once, so a whole palette build
    /// pays for one pass instead of one per row.
    static func refreshValidation(_ menu: NSMenu?) {
        guard let menu else { return }
        menu.update()
        for item in menu.items { refreshValidation(item.submenu) }
    }

    /// The object AppKit would send the action to. The palette panel is key
    /// while it is open, so the target is resolved against the browser window's
    /// responder chain explicitly rather than through the key window.
    static func target(for action: Selector, item: NSMenuItem?, in controller: MainWindowController) -> AnyObject? {
        if let explicit = item?.target, (explicit as AnyObject).responds(to: action) { return explicit as AnyObject }
        var responder = controller.window?.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        let fallbacks: [AnyObject?] = [controller.browser, controller, controller.window, NSApp.delegate, NSApp]
        return fallbacks.compactMap { $0 }.first { $0.responds(to: action) }
    }

    static func isEnabled(_ entry: PaletteEntry, in controller: MainWindowController,
                          refreshingMenus: Bool = true) -> Bool {
        guard entry.kind == .command else { return entry.url != nil }
        guard let item = menuItem(id: entry.id, in: NSApp.mainMenu), let action = item.action else {
            return contextualEnabled(entry.id, in: controller)
        }
        if refreshingMenus { item.menu?.update() }
        guard let target = target(for: action, item: item, in: controller) else { return false }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    /// Availability of the catalog commands that never appear in a menu.
    static func contextualEnabled(_ id: String, in controller: MainWindowController) -> Bool {
        let browser = controller.browser
        switch id {
        case ShortcutCatalog.renameID:
            return browser.canModifySelectedItems && browser.fileView.selectedItems.count == 1
        case ShortcutCatalog.openID: return browser.canOpenSelection
        case ShortcutCatalog.previewID: return browser.canPreviewSelection
        case ShortcutCatalog.cancelArchiveID: return browser.isPreparingArchive
        case ShortcutCatalog.nextTabID, ShortcutCatalog.previousTabID: return controller.tabs.count > 1
        case ShortcutCatalog.zoomInID:
            return browser.zoomIndex < ZoomLevel.sizes(for: browser.viewMode).count - 1
        default:
            guard let index = tabIndex(id, in: controller) else { return false }
            return index >= 0 && index < controller.tabs.count
        }
    }

    private static func tabIndex(_ id: String, in controller: MainWindowController) -> Int? {
        guard id.hasPrefix("window.selectTab."), let last = id.split(separator: ".").last,
              let number = Int(last) else { return nil }
        return number == 9 ? controller.tabs.count - 1 : number - 1
    }

    /// The key-event-free twin of `ShortcutDispatcher.handle`'s contextual arm.
    @discardableResult
    static func performContextual(_ id: String, in controller: MainWindowController) -> Bool {
        guard contextualEnabled(id, in: controller) else { return false }
        switch id {
        case ShortcutCatalog.renameID: controller.browser.renameSelection(nil)
        case ShortcutCatalog.openID: controller.browser.openSelection()
        case ShortcutCatalog.previewID: controller.browser.quickLook(nil)
        case ShortcutCatalog.cancelArchiveID: controller.browser.cancelArchiveOpening(nil)
        case ShortcutCatalog.nextTabID: controller.tabs.selectNext()
        case ShortcutCatalog.previousTabID: controller.tabs.selectPrevious()
        case ShortcutCatalog.zoomInID: controller.browser.zoomIn(nil)
        default:
            guard let index = tabIndex(id, in: controller) else { return false }
            controller.tabs.selectTab(at: index)
        }
        return true
    }

    @discardableResult
    static func run(_ entry: PaletteEntry, in controller: MainWindowController) -> Bool {
        switch entry.kind {
        case .favourite, .recent:
            guard let url = entry.url else { return false }
            controller.browser.navigate(to: url)
            return true
        case .command:
            guard let item = menuItem(id: entry.id, in: NSApp.mainMenu), let action = item.action else {
                return performContextual(entry.id, in: controller)
            }
            item.menu?.update()
            guard isEnabled(entry, in: controller, refreshingMenus: false),
                  let target = target(for: action, item: item, in: controller) else { return false }
            return NSApp.sendAction(action, to: target, from: item)
        }
    }
}

/// The command palette: a floating key panel centred over the window, with a
/// search field above a ranked list. Unlike `CompletionPopup` this panel *does*
/// become key, so typing lands in its own field; ↑/↓ move, Return runs, Esc
/// closes and hands focus back to the file view.
final class CommandPaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private static var palettes: [ObjectIdentifier: CommandPaletteController] = [:]

    /// One palette per window, kept alive while its window controller lives.
    static func palette(for controller: MainWindowController) -> CommandPaletteController {
        palettes = palettes.filter { $0.value.host != nil }
        let key = ObjectIdentifier(controller)
        if let existing = palettes[key], existing.host === controller { return existing }
        let created = CommandPaletteController(host: controller)
        palettes[key] = created
        return created
    }

    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// A row list that never becomes first responder: the search field keeps
    /// focus so every keystroke goes on filtering, while clicks still pick.
    private final class ClickTableView: NSTableView {
        var onClickRow: ((Int) -> Void)?
        override var acceptsFirstResponder: Bool { false }
        override func mouseDown(with event: NSEvent) {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 { onClickRow?(row) }
        }
    }

    private final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

    private weak var host: MainWindowController?
    private let panel: KeyPanel
    private let content = AdaptiveLayerView()
    private let searchField = NSSearchField()
    private let table = ClickTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matching commands")
    private var appearanceObservation: NSKeyValueObservation?

    private var entries: [PaletteEntry] = []
    private var enabledIDs = Set<String>()
    private(set) var matches: [PaletteMatch] = []

    private let rowHeight: CGFloat = 26
    private let fieldHeight: CGFloat = 30
    private let maximumRows = 10

    private init(host: MainWindowController) {
        self.host = host
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true

        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.semanticBackgroundColor = .windowBackgroundColor
        content.semanticBorderColor = .separatorColor
        content.layer?.borderWidth = 1
        panel.contentView = content

        searchField.placeholderString = "Run a command or go to a folder"
        searchField.font = .systemFont(ofSize: 15)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Command Palette Search")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.onClickRow = { [weak self] row in
            guard let self, self.matches.indices.contains(row) else { return }
            self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            self.activateSelection()
        }
        scroll.contentView = FlippedClipView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator
        for subview in [searchField, separator, scroll, emptyLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            searchField.heightAnchor.constraint(equalToConstant: fieldHeight - 8),
            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    // MARK: - Presentation

    var isVisible: Bool { panel.isVisible }
    var panelForTesting: NSPanel { panel }
    var queryForTesting: String { searchField.stringValue }
    var visibleEntries: [PaletteEntry] { matches.map(\.entry) }
    var selectedEntry: PaletteEntry? {
        matches.indices.contains(table.selectedRow) ? matches[table.selectedRow].entry : nil
    }
    func isEnabled(_ entry: PaletteEntry) -> Bool { enabledIDs.contains(entry.id) }

    func show() {
        guard let host, let window = host.window else { return }
        rebuildEntries()
        searchField.stringValue = ""
        applyQuery("")
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            appearanceObservation = window.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] window, _ in
                self?.panel.appearance = window.effectiveAppearance
            }
        }
        panel.orderFront(nil)
        // Headless runs have no active application, so `makeKey` is a no-op
        // there; the field still becomes the panel's first responder.
        if NSApp.isActive { panel.makeKey() }
        panel.makeFirstResponder(searchField)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        appearanceObservation = nil
        guard let host, let window = host.window else { return }
        window.makeFirstResponder(host.browser.focusView)
        if NSApp.isActive { window.makeKey() }
    }

    /// Rebuilds the rows and their availability while the browser window is
    /// still key, so menu validation sees the real responder chain.
    private func rebuildEntries() {
        guard let host else { return }
        let favourites = host.places.sections.first { $0.title == CommandPalette.favouriteCategory }?.places ?? []
        entries = CommandPalette.entries(actions: ShortcutCatalog.actions,
                                         bindings: AppPreferences.shared.shortcuts.bindings,
                                         favourites: favourites,
                                         recentFolders: Self.recentFolders(of: host.browser))
        CommandPaletteRunner.refreshValidation(NSApp.mainMenu)
        enabledIDs = Set(entries.filter {
            CommandPaletteRunner.isEnabled($0, in: host, refreshingMenus: false)
        }.map(\.id))
    }

    /// The active pane's history, nearest first, without the current folder.
    static func recentFolders(of browser: BrowserViewController, limit: Int = 12) -> [URL] {
        let history = browser.history
        let urls = history.backEntries(limit: limit).map(\.entry.url)
            + history.forwardEntries(limit: limit).map(\.entry.url)
        let current = browser.currentURL?.standardizedFileURL.path
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            return path != current && seen.insert(path).inserted
        }
    }

    // MARK: - Query and selection

    func applyQuery(_ text: String) {
        if searchField.stringValue != text { searchField.stringValue = text }
        matches = CommandPalette.filter(entries, query: text)
        table.reloadData()
        emptyLabel.isHidden = !matches.isEmpty
        if matches.isEmpty {
            table.deselectAll(nil)
        } else {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        layoutPanel()
    }

    /// ↑/↓ wrap around, matching the address bar's completion list.
    func moveSelection(by delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        let current = table.selectedRow
        let next = current < 0 ? (delta > 0 ? 0 : count - 1) : (current + delta + count) % count
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Runs the highlighted row. A disabled command is refused and the palette
    /// stays open, so the dimmed row explains itself instead of vanishing.
    @discardableResult
    func activateSelection() -> Bool {
        guard let host, let entry = selectedEntry else { return false }
        guard enabledIDs.contains(entry.id) else {
            if !SmokeTest.isRequested { NSSound.beep() }
            return false
        }
        close()
        return CommandPaletteRunner.run(entry, in: host)
    }

    private func layoutPanel() {
        guard let window = host?.window else { return }
        let width = min(max(window.frame.width * 0.55, 420), 640)
        let rows = min(max(matches.count, 1), maximumRows)
        let height = fieldHeight + 10 + CGFloat(rows) * rowHeight + 4
        let origin = NSPoint(x: (window.frame.midX - width / 2).rounded(),
                             y: (window.frame.midY - height / 2 + window.frame.height * 0.12).rounded())
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        table.tile()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Field editing

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        applyQuery(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handleCommand(selector)
    }

    /// The field editor's navigation commands, separated so the smoke suite can
    /// drive ↑/↓, Return and Esc without synthesising key events.
    @discardableResult
    func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("paletteRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? PaletteRowView) ?? PaletteRowView(identifier: id)
        let match = matches[row]
        cell.apply(match, enabled: enabledIDs.contains(match.entry.id))
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}

/// One palette row: the title with its matched characters emphasised, then the
/// command's category and its current shortcut, dimmed when unavailable.
private final class PaletteRowView: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let category = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.lineBreakMode = .byTruncatingMiddle
        title.font = .systemFont(ofSize: 13)
        textField = title
        category.font = .systemFont(ofSize: 11)
        category.textColor = .secondaryLabelColor
        category.lineBreakMode = .byTruncatingTail
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        category.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        for view in [title, category, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            category.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            category.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(equalTo: category.trailingAnchor, constant: 8),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ match: PaletteMatch, enabled: Bool) {
        let colour: NSColor = enabled ? .labelColor : .disabledControlTextColor
        let secondary: NSColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        let text = NSMutableAttributedString(string: match.entry.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: colour,
        ])
        let characters = Array(match.entry.title)
        for offset in match.matchedOffsets where characters.indices.contains(offset) {
            let start = String(characters[0..<offset]).utf16.count
            let length = String(characters[offset]).utf16.count
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold),
                              range: NSRange(location: start, length: length))
        }
        title.attributedStringValue = text
        category.stringValue = match.entry.category
        category.textColor = secondary
        shortcut.stringValue = match.entry.shortcut
        shortcut.textColor = secondary
    }
}

extension MainWindowController {
    /// View → Command Palette… (⇧⌘O by default, customisable like every other
    /// command). ⇧⌘P already belongs to Show Previews.
    @objc func showCommandPalette(_ sender: Any?) {
        CommandPaletteController.palette(for: self).show()
    }

    /// The palette for this window, created on first use.
    var commandPalette: CommandPaletteController { CommandPaletteController.palette(for: self) }
}

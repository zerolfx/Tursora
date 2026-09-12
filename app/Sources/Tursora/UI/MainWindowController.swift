import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                  NSToolbarItemValidation, NSMenuItemValidation, BrowserHost, NSSearchFieldDelegate, NSSharingServicePickerToolbarItemDelegate {

    let provider: FileProvider
    let places: PlacesModel
    let sidebar: SidebarViewController
    let tabs: TabsController
    var browser: BrowserViewController { tabs.current }

    private let contentSplitController = NSSplitViewController()
    private(set) var terminalPanel: TerminalPanelController?
    private var terminalItem: NSSplitViewItem?
    private var preferencesObserver: NSObjectProtocol?
    private var displayedExtensions = AppPreferences.showFileExtensions
    private let splitViewController = NSSplitViewController()
    private var backButton: LongPressMenuButton?
    private var forwardButton: LongPressMenuButton?
    private var viewModeControl: NSSegmentedControl?
    private var splitButton: NSButton?
    private var splitToolbarItem: NSToolbarItem?
    private var shareItem: NSSharingServicePickerToolbarItem?
    private var searchItem: NSSearchToolbarItem?
    var searchField: NSSearchField? { searchItem?.searchField }
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    var onClose: (() -> Void)?

    private enum ToolbarID {
        static let sidebar = NSToolbarItem.Identifier("tursora.sidebar")
        static let back = NSToolbarItem.Identifier("tursora.back")
        static let forward = NSToolbarItem.Identifier("tursora.forward")
        static let up = NSToolbarItem.Identifier("tursora.up")
        static let viewMode = NSToolbarItem.Identifier("tursora.viewMode")
        static let split = NSToolbarItem.Identifier("tursora.split")
        static let recursiveSearch = NSToolbarItem.Identifier("tursora.recursiveSearch")
        static let search = NSToolbarItem.Identifier("tursora.search")
        static let share = NSToolbarItem.Identifier("tursora.share")
        static let more = NSToolbarItem.Identifier("tursora.more")
        static let group = NSToolbarItem.Identifier("tursora.group")
    }

    init(provider: FileProvider, places: PlacesModel, initialURL: URL,
         viewPropertiesStore: DirectoryViewPropertiesStore = .shared) {
        self.provider = provider
        self.places = places
        self.sidebar = SidebarViewController(places: places)
        self.tabs = TabsController(provider: provider, initialURL: initialURL, host: nil, viewPropertiesStore: viewPropertiesStore)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 360)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .automatic
        window.tabbingMode = .disallowed          // D1: tabs are ours, not the window's
        window.setFrameAutosaveName("TursoraMainWindow")
        window.center()
        super.init(window: window)
        window.delegate = self
        tabs.host = self
        tabs.onCloseLastTab = { [weak self] in self?.window?.performClose(nil) }
        tabs.onDetachTab = { [weak self] snapshot in
            guard let self, let app = NSApp.delegate as? AppDelegate else { return false }
            app.newWindow(snapshot: snapshot, viewPropertiesStore: self.tabs.viewPropertiesStore)
            return true
        }

        // Keep both panes flush at their shared edge; only the window owns outer corners.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = 0.2
        sidebarItem.holdingPriority = .defaultHigh
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: tabs))
        splitViewController.splitView.dividerStyle = .thin
        contentSplitController.splitView.isVertical = false
        contentSplitController.splitView.dividerStyle = .thin
        contentSplitController.addSplitViewItem(NSSplitViewItem(viewController: splitViewController))
        window.contentViewController = contentSplitController

        let toolbar = NSToolbar(identifier: "TursoraMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.contentView?.layoutSubtreeIfNeeded()
        splitViewController.splitView.setPosition(190, ofDividerAt: 0)

        tabs.onCurrentLocationChanged = { [weak self] url in self?.locationChanged(url) }
        tabs.onTabsChanged = { [weak self] in self?.validateNavigation(); self?.syncFilterUI() }
        sidebar.onSelectPlace = { [weak self] url in self?.browser.navigate(to: url) }
        sidebar.onOpenInNewTab = { [weak self] url in self?.tabs.newTab(at: url) }
        sidebar.onOpenInOtherPane = { [weak self] url in self?.tabs.openInOtherPane(url) }
        sidebar.onDropFiles = { [weak self] urls, dest, op in self?.browser.dropFiles(urls, to: dest, op: op) }
        window.initialFirstResponder = browser.focusView
        installEventMonitors()
        preferencesObserver = NotificationCenter.default.addObserver(forName: .tursoraPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.displayedExtensions != AppPreferences.showFileExtensions {
                self.displayedExtensions = AppPreferences.showFileExtensions
                for pane in self.tabs.pages.flatMap(\.panes) {
                    let selection = pane.fileView.selectedItems.map(\.url)
                    let scrollOffset = pane.fileView.scrollOffset
                    pane.fileView.reloadData()
                    pane.fileView.select(urls: selection)
                    pane.fileView.scrollOffset = scrollOffset
                }
            }
            if !AppPreferences.experimentalTerminalEnabled { self.hideTerminal() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func locationChanged(_ url: URL) {
        guard let window else { return }
        let representedURL = browser.archiveSourceURL ?? url
        window.title = provider.displayName(for: representedURL)
        window.subtitle = ""
        window.representedURL = representedURL
        sidebar.syncSelection(to: url)
        terminalPanel?.followDirectory(terminalWorkingDirectory)
        validateNavigation()
        syncFilterUI()
    }

    @objc func toggleTerminal(_ sender: Any?) {
        guard AppPreferences.experimentalTerminalEnabled else { return }
        if terminalPanel != nil { hideTerminal(); return }
        let panel = TerminalPanelController(initialDirectory: terminalWorkingDirectory)
        panel.onClose = { [weak self] in self?.hideTerminal() }
        terminalPanel = panel
        let item = NSSplitViewItem(viewController: panel)
        item.minimumThickness = 120
        item.preferredThicknessFraction = 0.32
        terminalItem = item
        contentSplitController.addSplitViewItem(item)
        contentSplitController.splitView.setPosition(max(180, contentSplitController.view.bounds.height * 0.68), ofDividerAt: 0)
        panel.focus()
    }

    /// A terminal may work beside a ZIP, never inside its temporary snapshot.
    private var terminalWorkingDirectory: URL {
        browser.archiveSourceURL?.deletingLastPathComponent() ?? browser.currentURL ?? provider.homeURL
    }

    func hideTerminal() {
        terminalPanel?.shutdown()
        if let terminalItem { contentSplitController.removeSplitViewItem(terminalItem) }
        terminalItem = nil
        terminalPanel = nil
        window?.makeFirstResponder(browser.focusView)
    }

    // MARK: - Current-directory name filter

    private var isSearchFieldFocused: Bool {
        guard let f = searchField, let editor = f.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// Apply text from the toolbar to the current pane.
    func applyFilter(_ text: String) {
        browser.nameFilter = text
        if searchField?.stringValue != text { searchField?.stringValue = text }
        syncFilterUI()
    }

    /// Esc / the field's cancel button: back to the plain listing.
    func cancelFilter() {
        browser.nameFilter = ""
        searchField?.stringValue = ""
        endSearchInteractionIfNeeded()           // lets a collapsed toolbar fold the field away again
        syncFilterUI()
        window?.makeFirstResponder(browser.focusView)
    }

    /// The configured Filter shortcut focuses the current-directory name field.
    /// True while we hold the toolbar item expanded via beginSearchInteraction.
    private var searchInteractionActive = false
    var searchInteractionActiveForTesting: Bool { searchInteractionActive }

    /// Is the field actually on screen, or has the toolbar folded it into an icon?
    private var isSearchFieldVisible: Bool {
        guard let f = searchField, f.window != nil, !f.isHiddenOrHasHiddenAncestor else { return false }
        return f.frame.width > 40
    }

    @objc func focusFilter(_ sender: Any?) {
        guard let f = searchField else { return }
        if isSearchFieldVisible {
            window?.makeFirstResponder(f)
        } else {
            // Folded into an icon: the search interaction expands it. We end
            // it again as soon as focus leaves an empty field, like Finder.
            searchItem?.beginSearchInteraction()
            searchInteractionActive = true
            if !isSearchFieldFocused { window?.makeFirstResponder(f) }
        }
        syncFilterUI()
    }

    private func endSearchInteractionIfNeeded() {
        guard searchInteractionActive else { return }
        searchItem?.endSearchInteraction()
        searchInteractionActive = false
    }

    /// The field belongs to the window, the filter to the pane: keep them in step.
    private func syncFilterUI() {
        // The field shows the *current pane's* filter. While the user types,
        // every keystroke already reached the pane, so the two agree and
        // nothing is clobbered; after a pane switch they differ and the field
        // must follow — whether or not it has focus.
        if let f = searchField, f.stringValue != browser.nameFilter {
            f.stringValue = browser.nameFilter
        }
    }

    var isSearchFieldFocusedForTesting: Bool { isSearchFieldFocused }

    // NSSearchFieldDelegate
    func searchFieldDidStartSearching(_ sender: NSSearchField) { syncFilterUI() }
    /// Fires for ⓧ and Esc (the field is empty by then) but also when focus
    /// merely leaves the field. Finder keeps the search in the latter case;
    /// so do we — only an emptied field means "stop filtering".
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if sender.stringValue.isEmpty { cancelFilter() } else { syncFilterUI() }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSSearchField, f === searchField else { return }
        applyFilter(f.stringValue)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSSearchField, f === searchField else { return }
        // Focus left the field. Empty → let an expanded-from-icon field fold back
        // (Finder); with text the filter stays and so does the field.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if f.stringValue.isEmpty { self.endSearchInteractionIfNeeded() }
            self.syncFilterUI()
        }
    }

    /// View-based toolbar items are not auto-validated; keep them in step by hand.
    private func validateNavigation() {
        backButton?.isEnabled = browser.canGoBack
        forwardButton?.isEnabled = browser.canGoForward
        viewModeControl?.selectedSegment = browser.viewMode == .icons ? 0 : 1
        syncSplitToolbar()
        shareItem?.isEnabled = !sharingItems.isEmpty
        window?.toolbar?.validateVisibleItems()
    }

    var selectedToolbarViewModeForTesting: ViewMode? {
        guard let control = viewModeControl else { return nil }
        return control.selectedSegment == 0 ? .icons : .details
    }

    var splitToolbarButtonForTesting: NSButton? { splitButton }

    private var splitActionTitle: String {
        tabs.isSplit ? (tabs.currentPage.activeSide == .left ? "Close Left Pane" : "Close Right Pane") : "Split View"
    }

    private func syncSplitToolbar() {
        splitButton?.state = tabs.isSplit ? .on : .off
        splitButton?.toolTip = "\(splitActionTitle) (⇧⌘D)"
        splitButton?.setAccessibilityLabel(splitActionTitle)
        splitToolbarItem?.label = splitActionTitle
        splitToolbarItem?.toolTip = splitButton?.toolTip
        splitToolbarItem?.menuFormRepresentation?.title = splitActionTitle
        splitToolbarItem?.menuFormRepresentation?.state = tabs.isSplit ? .on : .off
    }

    // MARK: - Keyboard & mouse that menus cannot express

    private func installEventMonitors() {
        // ⌃Tab / ⌃⇧Tab cycle tabs; ⌘1…⌘9 jump (⌘9 = last). These have no
        // single menu-item representation, so they are handled here.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == 48, flags.contains(.control) {                 // Tab
                flags.contains(.shift) ? self.tabs.selectPrevious() : self.tabs.selectNext()
                return nil
            }
            if flags == .command, e.charactersIgnoringModifiers == "=" {      // ⌘= zooms in like ⌘+
                self.browser.zoomIn(nil); return nil
            }
            if flags == .command, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
                let index = n == 9 ? self.tabs.count - 1 : n - 1
                if index < self.tabs.count { self.tabs.selectTab(at: index) }
                return nil
            }
            return e
        }
        // Mouse buttons 4/5 (buttonNumber 3/4) — back/forward, as in every browser.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            switch e.buttonNumber {
            case 3: self.browser.goBack(); return nil
            case 4: self.browser.goForward(); return nil
            default: return e
            }
        }
    }

    private func removeEventMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil; mouseMonitor = nil
    }

    // MARK: - BrowserHost

    func viewModeDidChange(in pane: BrowserViewController) {
        guard pane === browser else { return }
        validateNavigation()
    }

    var isSplit: Bool { tabs.isSplit }
    func openInNewTab(_ url: URL, activate: Bool) { tabs.newTab(at: url, activate: activate) }
    func openInNewWindow(_ url: URL) { (NSApp.delegate as? AppDelegate)?.newWindow(at: url) }
    func openInOtherPane(_ url: URL) { tabs.openInOtherPane(url) }
    func transferToOtherPane(_ urls: [URL], move: Bool) {
        guard let other = tabs.currentPage.inactive, other.canModifyCurrentLocation,
              !move || browser.canModifySelectedItems, let dest = other.currentURL else { return }
        browser.dropFiles(urls, to: dest, op: move ? .move : .copy)
    }

    @objc func toggleSplit(_ sender: Any?) { tabs.toggleSplit() }
    @objc private func viewModeChanged(_ sender: NSSegmentedControl) {
        browser.setViewMode(sender.selectedSegment == 0 ? .icons : .details)
    }
    @objc func focusOtherPane(_ sender: Any?) { tabs.focusOtherPane() }

    // MARK: - Actions (menu responder chain + toolbar targets)

    @objc func showSearch(_ sender: Any?) { browser.showSearch() }
    @objc func goBack(_ sender: Any?) { browser.goBack() }
    @objc func goForward(_ sender: Any?) { browser.goForward() }
    @objc func goUp(_ sender: Any?) { browser.goUp() }
    @objc func goHome(_ sender: Any?) { browser.goHome() }
    @objc func reload(_ sender: Any?) { browser.reload() }
    @objc func openSelection(_ sender: Any?) {
        guard browser.canOpenSelection else { return }
        browser.openSelection()
    }
    @objc func toggleHiddenFiles(_ sender: Any?) { browser.showsHiddenFiles.toggle() }
    @objc func newFolder(_ sender: Any?) {
        guard browser.canModifyCurrentLocation else { return }
        browser.newFolder()
    }
    @objc func compressSelection(_ sender: Any?) {
        guard browser.canModifyCurrentLocation else { return }
        browser.compressSelection(sender)
    }
    @objc func extractSelection(_ sender: Any?) {
        guard browser.canModifyCurrentLocation else { return }
        browser.extractSelection(sender)
    }
    @objc func connectToServer(_ sender: Any?) {
        let initiatingPane = browser
        ServerConnectionController.show(relativeTo: window) { [weak initiatingPane] url in
            guard let initiatingPane, initiatingPane.view.window != nil else { return }
            initiatingPane.navigate(to: url)
        }
    }
    @objc func getInfo(_ sender: Any?) {
        guard !browser.isBrowsingArchive else { return }
        browser.getInfo(sender)
    }
    @objc func getSummaryInfo(_ sender: Any?) {
        guard !browser.isBrowsingArchive else { return }
        browser.getSummaryInfo(sender)
    }
    @objc func showInspector(_ sender: Any?) {
        guard !browser.isBrowsingArchive else { return }
        browser.showInspector(sender)
    }
    @objc func editLocation(_ sender: Any?) { tabs.addressBar.beginEditing() }

    @objc func newTab(_ sender: Any?) { tabs.performTabAction(.newTab, on: tabs.currentPage) }
    @objc func closeTab(_ sender: Any?) {
        if !tabs.closeCurrentTab() { window?.performClose(sender) }
    }
    @objc func reopenClosedTab(_ sender: Any?) { tabs.reopenClosedTab() }
    @objc func nextTab(_ sender: Any?) { tabs.selectNext() }
    @objc func previousTab(_ sender: Any?) { tabs.selectPrevious() }

    @objc func sortBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = DirectoryModel.SortKey(rawValue: raw) else { return }
        browser.fileList.setSort(key: key, ascending: browser.model.ascending)
    }
    @objc func toggleSortOrder(_ sender: Any?) {
        browser.fileList.setSort(key: browser.model.sortKey, ascending: !browser.model.ascending)
    }

    // Favorites keeps keyboard focus in the sidebar. Window-level fallbacks
    // keep grouping available when the active browser is not in the responder chain.
    @objc func groupBy(_ sender: NSMenuItem) { browser.groupBy(sender) }
    @objc func toggleGroups(_ sender: Any?) { browser.toggleGroups(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let valid = validateViewPropertiesMenuItem(item) { return valid }
        switch item.action {
        case #selector(toggleTerminal(_:)):
            item.title = terminalPanel == nil ? "Show Terminal" : "Hide Terminal"
            return AppPreferences.experimentalTerminalEnabled
        case #selector(goBack(_:)):     return browser.canGoBack
        case #selector(goForward(_:)):  return browser.canGoForward
        case #selector(goUp(_:)):       return browser.canGoUp
        case #selector(openSelection(_:)): return browser.canOpenSelection
        case #selector(newFolder(_:)): return browser.canModifyCurrentLocation
        case #selector(getInfo(_:)), #selector(getSummaryInfo(_:)), #selector(showInspector(_:)):
            return !browser.isBrowsingArchive && browser.currentURL != nil
        case #selector(performFileAction(_:)): return validateFileAction(item)
        case #selector(compressSelection(_:)), #selector(extractSelection(_:)):
            return browser.canModifyCurrentLocation && browser.validateMenuItem(item)
        case #selector(toggleHiddenFiles(_:)):
            item.state = browser.showsHiddenFiles ? .on : .off
            return true
        case #selector(closeTab(_:)):
            item.title = tabs.count > 1 ? "Close Tab" : "Close Window"
            return true
        case #selector(reopenClosedTab(_:)): return tabs.canReopenClosedTab
        case #selector(toggleSplit(_:)):
            item.title = splitActionTitle
            return true
        case #selector(focusOtherPane(_:)): return tabs.isSplit
        case #selector(toggleSidebar(_:)):
            item.title = isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(showSearch(_:)): return browser.currentURL != nil && !browser.isBrowsingArchive && !browser.isPreparingArchive
        case #selector(focusFilter(_:)):
            item.state = browser.isFiltering ? .on : .off; return true
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return tabs.count > 1
        case #selector(sortBy(_:)):
            item.state = (item.representedObject as? String) == browser.model.sortKey.rawValue ? .on : .off
            return true
        case #selector(toggleSortOrder(_:)):
            item.state = browser.model.ascending ? .on : .off
            return true
        case #selector(groupBy(_:)), #selector(toggleGroups(_:)):
            return browser.validateMenuItem(item)
        default: return true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ToolbarID.back:    return browser.canGoBack
        case ToolbarID.forward: return browser.canGoForward
        case ToolbarID.up:      return browser.canGoUp
        case ToolbarID.share:   return !sharingItems.isEmpty
        case ToolbarID.recursiveSearch: return browser.currentURL != nil && !browser.isBrowsingArchive && !browser.isPreparingArchive
        default: return true
        }
    }

    var sharingItems: [URL] { browser.readableSelectionURLs }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] { sharingItems }

    func selectionDidChange(in pane: BrowserViewController) {
        guard pane === browser else { return }
        shareItem?.isEnabled = !sharingItems.isEmpty
    }

    private func validateFileAction(_ item: NSMenuItem) -> Bool {
        guard let raw = item.representedObject as? String, let action = MainMenu.FileAction(rawValue: raw) else { return false }
        let count = browser.fileView.selectedItems.count
        switch action {
        case .newFolder: return browser.canModifyCurrentLocation
        case .getInfo: return !browser.isBrowsingArchive && browser.currentURL != nil
        case .open: return browser.canOpenSelection
        case .quickLook: return browser.canPreviewSelection
        case .copy: return !browser.readableSelectionURLs.isEmpty
        case .rename: return browser.canModifySelectedItems && count == 1
        case .compress:
            item.title = browser.compressionTitle
            return browser.canModifyCurrentLocation && count > 0
        case .extract: return browser.canModifyCurrentLocation && browser.canExtractSelection
        case .paste:
            return browser.canModifyCurrentLocation && browser.validateMenuItem(NSMenuItem(title: "", action: #selector(BrowserViewController.paste(_:)), keyEquivalent: ""))
        case .duplicate, .trash: return browser.canModifySelectedItems && count > 0
        }
    }

    @objc func performFileAction(_ sender: NSMenuItem) {
        guard validateFileAction(sender), let raw = sender.representedObject as? String,
              let action = MainMenu.FileAction(rawValue: raw) else { return }
        switch action {
        case .newFolder: browser.newFolder()
        case .open: browser.openSelection()
        case .getInfo: browser.getInfo(sender)
        case .quickLook: browser.quickLook(sender)
        case .rename: browser.renameSelection(sender)
        case .duplicate: browser.duplicate(sender)
        case .compress: browser.compressSelection(sender)
        case .extract: browser.extractSelection(sender)
        case .copy: browser.copy(sender)
        case .paste: browser.paste(sender)
        case .trash: browser.moveToTrash(sender)
        }
    }

    var isSidebarCollapsed: Bool { splitViewController.splitViewItems[0].isCollapsed }

    @objc func toggleSidebar(_ sender: Any?) {
        let item = splitViewController.splitViewItems[0]
        item.isCollapsed.toggle()
        // Restoring focus avoids leaving it in an invisible outline view.
        if item.isCollapsed { window?.makeFirstResponder(browser.focusView) }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.sidebar, ToolbarID.back, ToolbarID.forward, ToolbarID.up, .flexibleSpace, ToolbarID.split, ToolbarID.viewMode, ToolbarID.group, ToolbarID.share, ToolbarID.more, ToolbarID.recursiveSearch, ToolbarID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ToolbarID.sidebar:
            let item = navItem(id, "Toggle Sidebar", "sidebar.leading", #selector(toggleSidebar(_:)))
            item.visibilityPriority = .user
            return item
        case ToolbarID.back:
            let (item, button) = historyItem(id, "Back", "chevron.left", #selector(goBack(_:)), back: true)
            backButton = button; return item
        case ToolbarID.forward:
            let (item, button) = historyItem(id, "Forward", "chevron.right", #selector(goForward(_:)), back: false)
            forwardButton = button; return item
        case ToolbarID.up:      return navItem(id, "Enclosing Folder", "arrow.up", #selector(goUp(_:)))
        case ToolbarID.split:
            let button = NSButton(image: NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split View")!,
                                  target: self, action: #selector(toggleSplit(_:)))
            button.bezelStyle = .texturedRounded
            button.setButtonType(.pushOnPushOff)
            button.imagePosition = .imageOnly
            let item = NSToolbarItem(itemIdentifier: id)
            item.paletteLabel = "Split View"
            item.view = button
            item.target = self
            item.action = #selector(toggleSplit(_:))
            item.autovalidates = false
            item.visibilityPriority = .high
            let overflow = NSMenuItem(title: splitActionTitle, action: #selector(toggleSplit(_:)), keyEquivalent: "")
            overflow.target = self
            item.menuFormRepresentation = overflow
            splitButton = button
            splitToolbarItem = item
            syncSplitToolbar()
            return item
        case ToolbarID.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.label = "Share"
            item.toolTip = "Share selected items"
            item.delegate = self
            item.autovalidates = false
            item.isEnabled = !sharingItems.isEmpty
            shareItem = item
            return item
        case ToolbarID.more:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "More"
            item.toolTip = "More actions"
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More actions")
            item.showsIndicator = false
            item.menu = MainMenu.actionsMenu(target: self)
            return item
        case ToolbarID.group:
            // Finder's Group button: a menu of the Group By keys (items validate through the responder chain).
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Group"
            item.paletteLabel = "Group"
            item.toolTip = "Group By"
            item.image = NSImage(systemSymbolName: "square.grid.3x1.below.line.grid.1x2", accessibilityDescription: "Group")
            item.showsIndicator = true
            item.menu = MainMenu.groupByMenuItem().submenu ?? NSMenu()
            return item
        case ToolbarID.recursiveSearch:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Search"
            item.toolTip = "Search names, contents, types and dates (⇧⌘F). ZIP contents are not searched."
            item.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Search")
            item.target = self
            item.action = #selector(showSearch(_:))
            return item
        case ToolbarID.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "Filter"
            item.paletteLabel = "Filter"
            item.preferredWidthForSearchField = 200
            item.resignsFirstResponderWithCancel = true
            item.searchField.placeholderString = "Filter by Name"
            item.searchField.toolTip = "Filter this folder by name. Supports * and ? wildcards. Escape clears the filter."
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.sendsWholeSearchString = false
            item.searchField.delegate = self
            searchItem = item
            return item
        case ToolbarID.viewMode:
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons")!,
                NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!,
            ], trackingMode: .selectOne, target: self, action: #selector(viewModeChanged(_:)))
            control.segmentStyle = .automatic
            control.setToolTip("as Icons (⌘⌥1)", forSegment: 0)
            control.setToolTip("as List (⌘⌥2)", forSegment: 1)
            control.selectedSegment = browser.viewMode == .icons ? 0 : 1
            viewModeControl = control
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "View"
            item.paletteLabel = "View"
            item.view = control
            item.autovalidates = false
            return item
        default: return nil
        }
    }

    /// Back/forward: click navigates one step; long-press or right-click lists the history.
    private func historyItem(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String,
                             _ action: Selector, back: Bool) -> (NSToolbarItem, LongPressMenuButton) {
        let button = LongPressMenuButton()
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = "\(label) — hold for history"
        button.menuProvider = { [weak self] in self?.browser.historyMenu(back: back) }
        button.isEnabled = false
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.view = button
        item.isNavigational = true
        item.autovalidates = false
        return (item, button)
    }

    private func navItem(_ id: NSToolbarItem.Identifier, _ label: String,
                         _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.isNavigational = true
        item.target = self
        item.action = action
        return item
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let tasks = TransferTasksWindowController.shared
        guard tasks.hasActiveTasks(ownedBy: sender) else { return true }
        tasks.cancelTasks(ownedBy: sender) { [weak self] in self?.window?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        removeEventMonitors()
        hideTerminal()
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        preferencesObserver = nil
        onClose?()
    }
}

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
    var isTerminalVisible: Bool { terminalItem != nil }
    private var terminalHeight: CGFloat?
    var terminalTaskConfirmation: TerminalTaskConfirmation.Decision = TerminalTaskConfirmation.confirm
    /// The preview pane, built like the terminal: the controller is retained
    /// across hides so its scroll position and Quick Look survive, while only
    /// the split item comes and goes. It is appended to `splitViewController`,
    /// never to `contentSplitController`, whose divider index the terminal
    /// hard-codes; and never inside a tab, whose split assumes exactly two
    /// arranged subviews.
    private(set) var previewPanel: PreviewPanelController?
    private var previewItem: NSSplitViewItem?
    var isPreviewVisible: Bool { previewItem != nil }
    private var previewWidth: CGFloat?
    private var previewObserver: NSObjectProtocol?
    private var previewContentWatcher: DirectoryWatcher?
    private var previewObservedURL: URL?
    private var isCheckingTerminalClose = false
    private var isUpdatingTerminalToolbarPresence = false
    private var preferencesObserver: NSObjectProtocol?
    private var shortcutsObserver: NSObjectProtocol?
    private var displayedExtensions = AppPreferences.showFileExtensions
    private let splitViewController = NSSplitViewController()
    private var backButton: LongPressMenuButton?
    private var forwardButton: LongPressMenuButton?
    private var viewModeControl: NSSegmentedControl?
    /// Segment order is Icons, List, Columns — the order of the View menu.
    static func segment(for mode: ViewMode) -> Int {
        switch mode { case .icons: return 0; case .details: return 1; case .columns: return 2 }
    }
    static func mode(forSegment segment: Int) -> ViewMode {
        switch segment { case 0: return .icons; case 2: return .columns; default: return .details }
    }
    private var splitButton: NSButton?
    private var splitToolbarItem: NSToolbarItem?
    private var terminalButton: NSButton?
    private var terminalToolbarItem: NSToolbarItem?
    private var shareItem: NSSharingServicePickerToolbarItem?
    private var searchItem: NSSearchToolbarItem?
    private var isSynchronizingSearchField = false
    private weak var composingSearchPane: BrowserViewController?
    var searchField: NSSearchField? { searchItem?.searchField }
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var sidebarResizeObserver: NSObjectProtocol?
    private var rememberedSidebarWidth: Double = 190
    private var rememberedSidebarCollapsed = false
    private var isRestoringWorkspace = false

    var onClose: (() -> Void)?
    var onSessionChanged: (() -> Void)?
    var viewOptionsController: ViewOptionsWindowController?

    @objc func showViewOptions(_ sender: Any?) {
        if viewOptionsController == nil { viewOptionsController = ViewOptionsWindowController(owner: self) }
        viewOptionsController?.show()
    }

    private enum ToolbarID {
        static let sidebar = NSToolbarItem.Identifier("tursora.sidebar")
        static let back = NSToolbarItem.Identifier("tursora.back")
        static let forward = NSToolbarItem.Identifier("tursora.forward")
        static let up = NSToolbarItem.Identifier("tursora.up")
        static let viewMode = NSToolbarItem.Identifier("tursora.viewMode")
        static let split = NSToolbarItem.Identifier("tursora.split")
        static let terminal = NSToolbarItem.Identifier("tursora.terminal")
        static let search = NSToolbarItem.Identifier("tursora.search")
        static let share = NSToolbarItem.Identifier("tursora.share")
        static let more = NSToolbarItem.Identifier("tursora.more")
        static let group = NSToolbarItem.Identifier("tursora.group")
    }

    init(provider: FileProvider, places: PlacesModel, initialURL: URL,
         viewPropertiesStore: DirectoryViewPropertiesStore = .shared) {
        self.provider = provider
        self.places = places
        self.sidebar = SidebarViewController(places: places, provider: provider)
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
        // AppKit's frame autosave always writes UserDefaults.standard, even
        // when our own stores use an isolated smoke/QA suite.
        if AppDefaults.isolatedDomain == nil { window.setFrameAutosaveName("TursoraMainWindow") }
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
        // Keep the sidebar steadier than the content, but below AppKit's
        // divider-drag priority (490), so native dragging and setPosition work.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
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

        sidebarResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitViewController.splitView, queue: .main
        ) { [weak self] _ in self?.sidebarSessionGeometryChanged() }

        tabs.onCurrentLocationChanged = { [weak self] url in self?.locationChanged(url) }
        tabs.onTabsChanged = { [weak self] in self?.validateNavigation(); self?.syncFilterUI() }
        tabs.onWorkspaceSessionChanged = { [weak self] in self?.onSessionChanged?() }
        sidebar.onSelectPlace = { [weak self] url in self?.browser.navigate(to: url) }
        sidebar.onOpenInNewTab = { [weak self] url in self?.tabs.newTab(at: url) }
        sidebar.onOpenInOtherPane = { [weak self] url in self?.tabs.openInOtherPane(url) }
        sidebar.onDropFiles = { [weak self] urls, dest, op in self?.browser.dropFiles(urls, to: dest, op: op) }
        // Spring-loaded places select the place; the folder tree expands in place.
        sidebar.onSpringLoad = { [weak self] url in self?.browser.navigate(to: url) }
        sidebar.onFoldersChanged = { [weak self] in
            guard let self, !self.isRestoringWorkspace else { return }
            self.onSessionChanged?()
        }
        window.initialFirstResponder = browser.focusView
        installEventMonitors()
        shortcutsObserver = NotificationCenter.default.addObserver(forName: .tursoraShortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.validateNavigation()
        }
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
            self.syncTerminalToolbar()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    var workspaceSessionState: WorkspaceWindowState {
        let frame = window.map {
            WorkspaceWindowFrame(x: $0.frame.minX, y: $0.frame.minY,
                                 width: $0.frame.width, height: $0.frame.height)
        }
        return WorkspaceWindowState(tabs: tabs.pages.map(\.workspaceTabState),
                                    selectedTabIndex: tabs.currentIndex, frame: frame,
                                    sidebarWidth: capturedSidebarWidth,
                                    sidebarCollapsed: isSidebarCollapsed,
                                    isMiniaturized: window?.isMiniaturized ?? false,
                                    foldersVisible: sidebar.foldersVisible, foldersFraction: sidebar.foldersFraction,
                                    foldersShowHidden: sidebar.foldersPanel?.model.showsHiddenFolders ?? false,
                                    foldersLimitToHome: sidebar.foldersPanel?.model.limitsToHome ?? true,
                                    previewVisible: isPreviewVisible,
                                    previewWidth: Double(previewPanel?.view.bounds.width ?? previewWidth ?? 360))
    }

    /// The application owns window ordering and minimization after every
    /// window is restored. This method does not bring a background window forward.
    func restoreWorkspaceSession(_ state: WorkspaceWindowState) {
        guard let state = state.sanitized() else { return }
        isRestoringWorkspace = true
        defer { isRestoringWorkspace = false }
        if let frame = state.frame, let window {
            let proposed = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            let safe = WorkspaceWindowGeometry.constrainedFrame(
                proposed, visibleFrames: NSScreen.screens.map(\.visibleFrame), minimumSize: window.minSize)
            window.setFrame(safe, display: false)
        }
        let item = splitViewController.splitViewItems[0]
        item.isCollapsed = false
        rememberedSidebarWidth = state.sidebarWidth.isFinite ? min(320, max(160, state.sidebarWidth)) : 190
        window?.contentView?.layoutSubtreeIfNeeded()
        splitViewController.splitView.setPosition(rememberedSidebarWidth, ofDividerAt: 0)
        item.isCollapsed = state.sidebarCollapsed
        rememberedSidebarCollapsed = state.sidebarCollapsed
        sidebar.foldersFraction = state.foldersFraction
        if state.foldersVisible || state.foldersShowHidden || !state.foldersLimitToHome {
            sidebar.setFoldersPanelVisible(true, active: false)
            sidebar.foldersPanel?.model.showsHiddenFolders = state.foldersShowHidden
            sidebar.foldersPanel?.model.limitsToHome = state.foldersLimitToHome
            sidebar.setFoldersPanelVisible(state.foldersVisible, active: !state.sidebarCollapsed)
        } else { sidebar.setFoldersPanelVisible(false) }
        tabs.restoreWorkspaceTabs(state.tabs, selectedIndex: state.selectedTabIndex)
        // The width is remembered before the pane is shown, so the restored
        // pane opens at the size it was closed at rather than the default.
        previewWidth = CGFloat(state.previewWidth)
        if state.previewVisible { togglePreviewPane(nil) }
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.initialFirstResponder = browser.focusView
        window?.makeFirstResponder(browser.focusView)
    }

    private var capturedSidebarWidth: Double {
        let width = Double(sidebar.view.frame.width)
        return !isSidebarCollapsed && width > 0 ? min(320, max(160, width)) : rememberedSidebarWidth
    }

    private func sidebarSessionGeometryChanged() {
        guard !isRestoringWorkspace else { return }
        let width = capturedSidebarWidth
        let collapsed = isSidebarCollapsed
        guard abs(width - rememberedSidebarWidth) > 0.1 || collapsed != rememberedSidebarCollapsed else { return }
        rememberedSidebarWidth = width
        rememberedSidebarCollapsed = collapsed
        onSessionChanged?()
    }

    private func locationChanged(_ url: URL) {
        viewOptionsController?.refresh()
        guard let window else { return }
        let representedURL = browser.archiveSourceURL ?? url
        window.title = provider.displayName(for: representedURL)
        window.representedURL = representedURL
        sidebar.syncSelection(to: browser.archiveSourceURL?.deletingLastPathComponent() ?? url)
        terminalPanel?.followDirectory(terminalWorkingDirectory)
        validateNavigation()
        syncFilterUI()
        refreshPreview()
    }

    @objc func toggleTerminal(_ sender: Any?) {
        guard AppPreferences.experimentalTerminalEnabled else { return }
        if isTerminalVisible { hideTerminal(); return }
        let panel = terminalPanel ?? TerminalPanelController(initialDirectory: terminalWorkingDirectory)
        panel.onClose = { [weak self] in self?.hideTerminal() }
        panel.onShellDirectoryChanged = { [weak self] url in self?.followShellDirectory(url) }
        terminalPanel = panel
        let item = NSSplitViewItem(viewController: panel)
        item.minimumThickness = 120
        item.preferredThicknessFraction = 0.32
        terminalItem = item
        contentSplitController.addSplitViewItem(item)
        let height = contentSplitController.view.bounds.height
        let desiredHeight = terminalHeight ?? height * 0.32
        contentSplitController.splitView.setPosition(max(180, height - max(120, desiredHeight)), ofDividerAt: 0)
        syncTerminalToolbar()
        panel.focus()
    }

    /// Reverse folder sync. The shell reported a directory nobody asked it for,
    /// so the window's active pane follows through the ordinary navigation path;
    /// the terminal panel never touches the filesystem itself.
    func followShellDirectory(_ url: URL) {
        guard isTerminalVisible,
              !TerminalPanelPresentation.isSameDirectory(url, terminalWorkingDirectory) else { return }
        browser.navigate(to: url)
    }

    /// A terminal may work beside a ZIP, never inside its temporary snapshot.
    private var terminalWorkingDirectory: URL {
        browser.archiveSourceURL?.deletingLastPathComponent() ?? browser.currentURL ?? provider.homeURL
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        if isPreviewVisible { hidePreviewPane(); return }
        let panel = previewPanel ?? PreviewPanelController()
        panel.onClose = { [weak self] in self?.hidePreviewPane() }
        previewPanel = panel
        // A file can change while it stays selected — an editor saves over it,
        // a build rewrites it. Without this the pane keeps showing the old
        // render for as long as the selection does not move, because `show`
        // short-circuits on an unchanged URL.
        if previewObserver == nil {
            previewObserver = NotificationCenter.default.addObserver(
                forName: .tursoraDirectoriesChanged, object: nil, queue: .main) { [weak self] _ in
                    self?.refreshPreview(force: true)
                }
        }
        let item = NSSplitViewItem(viewController: panel)
        item.minimumThickness = 220
        item.maximumThickness = 720
        item.canCollapse = true
        item.holdingPriority = NSLayoutConstraint.Priority(259)
        previewItem = item
        splitViewController.addSplitViewItem(item)
        splitViewController.view.layoutSubtreeIfNeeded()
        let total = splitViewController.view.bounds.width
        let desired = previewWidth ?? min(360, max(220, total * 0.28))
        if total > 0 {
            splitViewController.splitView.setPosition(
                total - desired, ofDividerAt: splitViewController.splitViewItems.count - 2)
        }
        refreshPreview()
    }

    /// `QLPreviewView` can keep playing media after its window goes away, so
    /// the pane is torn down explicitly rather than left to ARC.
    func shutdownPreview() {
        previewContentWatcher = nil
        previewObservedURL = nil
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
        previewObserver = nil
        previewPanel?.shutdown()
        previewPanel = nil
        previewItem = nil
    }

    func hidePreviewPane() {
        previewContentWatcher = nil
        previewObservedURL = nil
        guard let previewItem else { return }
        previewWidth = previewPanel?.view.bounds.width
        previewPanel?.paneHidden()
        splitViewController.removeSplitViewItem(previewItem)
        self.previewItem = nil
        window?.makeFirstResponder(browser.focusView)
    }

    /// The pane follows the same targets Get Info uses, so a selection, a
    /// navigation with nothing selected, and a search all behave the same way
    /// they already do elsewhere.
    func refreshPreview(force: Bool = false) {
        guard let previewPanel, isPreviewVisible else { return }
        let target = browser.infoTargets.count == 1 ? browser.infoTargets.first : nil
        // Search results have no directory watcher. Watch just the selected
        // file's parent so an external save refreshes its preview without
        // rerunning an entire recursive search.
        let watched = browser.isBrowsingArchive ? nil : target?.standardizedFileURL
        if watched != previewObservedURL {
            previewObservedURL = watched
            previewContentWatcher = watched.map { url in
                let path = url.resolvingSymlinksInPath().path
                let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
                return DirectoryWatcher(directory: url.deletingLastPathComponent()) { [weak self] paths in
                    guard let self, self.previewObservedURL == url,
                          paths.contains(where: {
                              // FSEvents reports /private/var while Foundation
                              // may spell the same watched item /var. Resolve
                              // both sides, as the browser listing watcher does.
                              let changed = URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                              return changed == path || changed == parent
                          }) else { return }
                    self.refreshPreview(force: true)
                }
            }
        }
        previewPanel.show(target, force: force)
    }

    func hideTerminal() {
        guard let terminalItem else { return }
        terminalHeight = terminalPanel?.view.bounds.height
        contentSplitController.removeSplitViewItem(terminalItem)
        self.terminalItem = nil
        syncTerminalToolbar()
        window?.makeFirstResponder(browser.focusView)
    }

    /// Hiding detaches only the view. Closing its window or quitting explicitly
    /// ends the retained session after the task confirmation has been accepted.
    func shutdownTerminal(completion: (() -> Void)? = nil) {
        hideTerminal()
        let panel = terminalPanel
        terminalPanel = nil
        if let panel { panel.shutdown(completion: completion) }
        else { completion?() }
    }

    // MARK: - Current-directory name filter

    private var isSearchFieldFocused: Bool {
        guard let f = searchField, let editor = f.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// Apply text from the toolbar to the current pane.
    func applyFilter(_ text: String, scheduleSearch: Bool = true) {
        browser.applySearchFieldText(text, scheduleSearch: scheduleSearch)
        setSearchFieldValue(text)
        syncFilterUI()
    }

    /// Esc / the field's cancel button: back to the plain listing.
    func cancelFilter() {
        composingSearchPane = nil
        setSearchFieldValue("")
        if browser.searchPanel.isShowingOptions { browser.closeSearch() }
        else {
            browser.nameFilter = ""
            browser.updateFilterSearchHint()
        }
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

    func focusSearch(in pane: BrowserViewController) {
        guard pane === browser else { return }
        syncFilterUI()
        focusFilter(nil)
    }

    private func endSearchInteractionIfNeeded() {
        guard searchInteractionActive else { return }
        searchItem?.endSearchInteraction()
        searchInteractionActive = false
    }

    /// The field belongs to the window, the filter to the pane: keep them in step.
    private func syncFilterUI() {
        // The ordinary filter and recursive draft are separate pane state;
        // switching panes must update chrome even while its editor has focus.
        guard let field = searchField else { return }
        let wasSynchronizing = isSynchronizingSearchField
        isSynchronizingSearchField = true
        defer { isSynchronizingSearchField = wasSynchronizing }
        let recursive = browser.searchPanel.isShowingOptions
        if !recursive { browser.updateFilterSearchHint() }
        let text = browser.searchFieldText
        setSearchFieldValue(text)
        field.placeholderString = recursive ? "Search by Name" : "Filter by Name"
        field.toolTip = recursive
            ? "Search names containing this text in the selected folder and its subfolders. Return searches now; Escape returns to the folder."
            : "Filter this folder by name. Supports * and ? wildcards. Search Options includes subfolders and more conditions."
        searchItem?.label = recursive ? "Search" : "Filter"
    }

    private func setSearchFieldValue(_ text: String) {
        guard let field = searchField else { return }
        let wasSynchronizing = isSynchronizingSearchField
        isSynchronizingSearchField = true
        defer { isSynchronizingSearchField = wasSynchronizing }
        if field.stringValue != text { field.stringValue = text }
        if let editor = field.currentEditor(), editor.string != text { editor.string = text }
    }

    var isSearchFieldFocusedForTesting: Bool { isSearchFieldFocused }

    // NSSearchFieldDelegate
    func searchFieldDidStartSearching(_ sender: NSSearchField) {
        // AppKit can deliver this before textDidChange. Adopt the first edit
        // before syncing chrome, otherwise the previous empty filter erases it.
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sender))
    }
    /// Fires for ⓧ and Esc (the field is empty by then) but also when focus
    /// merely leaves the field. Finder keeps the search in the latter case;
    /// so do we — only an emptied field means "stop filtering".
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        guard !isSynchronizingSearchField else { return }
        // An empty name is valid for content/type-only searches. Blurring that
        // empty draft must keep options open; the native cancel cell, however,
        // clears a previously non-empty name before sending this callback.
        if sender.stringValue.isEmpty && (!browser.searchPanel.isShowingOptions || !browser.searchFieldText.isEmpty) { cancelFilter() }
        else { syncFilterUI() }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard !isSynchronizingSearchField else { return }
        guard let f = obj.object as? NSSearchField, f === searchField else { return }
        let composing = (f.currentEditor() as? NSTextView)?.hasMarkedText() == true
        let pane = browser
        // Committing a candidate can remove marked text without changing its
        // characters. The draft already contains that text, but has no timer.
        let commitsUnchangedName = !composing && composingSearchPane === pane
            && pane.searchPanel.isShowingOptions && pane.searchFieldText == f.stringValue
        composingSearchPane = composing ? pane : nil
        applyFilter(f.stringValue, scheduleSearch: !composing)
        if commitsUnchangedName { pane.searchPanel.scheduleSearch() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            composingSearchPane = nil
            if browser.searchPanel.isShowingOptions { browser.searchPanel.search(nil) }
            window?.makeFirstResponder(browser.focusView)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelFilter()
            return true
        }
        return false
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
        viewModeControl?.selectedSegment = Self.segment(for: browser.viewMode)
        viewModeControl?.setToolTip(shortcutTooltip("as Icons", action: "menu.viewAsIcons"), forSegment: 0)
        viewModeControl?.setToolTip(shortcutTooltip("as List", action: "menu.viewAsList"), forSegment: 1)
        viewModeControl?.setToolTip(shortcutTooltip("as Columns", action: "menu.viewAsColumns"), forSegment: 2)
        syncSplitToolbar()
        syncTerminalToolbar()
        shareItem?.isEnabled = canShareSelection
        window?.toolbar?.validateVisibleItems()
    }

    var selectedToolbarViewModeForTesting: ViewMode? {
        guard let control = viewModeControl else { return nil }
        return Self.mode(forSegment: control.selectedSegment)
    }

    var splitToolbarButtonForTesting: NSButton? { splitButton }
    var backToolbarButtonForTesting: NSButton? { backButton }
    var terminalToolbarButtonForTesting: NSButton? { terminalButton }

    private func syncTerminalToolbar() {
        syncTerminalToolbarPresence()
        syncTerminalToolbarItem()
    }

    /// The button is present only while Settings keeps the entry point on. A
    /// permanently dimmed button explains nothing about why it cannot be used,
    /// so the toolbar drops it exactly as the View menu hides its command.
    private func syncTerminalToolbarPresence() {
        guard let toolbar = window?.toolbar, !isUpdatingTerminalToolbarPresence else { return }
        isUpdatingTerminalToolbarPresence = true
        defer { isUpdatingTerminalToolbarPresence = false }
        let placed = toolbar.items.firstIndex { $0.itemIdentifier == ToolbarID.terminal }
        switch (AppPreferences.experimentalTerminalEnabled, placed) {
        case (true, nil):
            // Back into its own place: after Split View, ahead of the view modes.
            let split = toolbar.items.firstIndex { $0.itemIdentifier == ToolbarID.split }
            toolbar.insertItem(withItemIdentifier: ToolbarID.terminal,
                               at: split.map { $0 + 1 } ?? toolbar.items.count)
        case (false, .some(let index)):
            toolbar.removeItem(at: index)
        default: break
        }
        // Toolbars sharing an identifier share their item configuration, so a
        // second window's insertion or removal reaches this one without passing
        // through the code above. The cached references are therefore read back
        // from the toolbar rather than assumed from what this call just did.
        terminalToolbarItem = toolbar.items.first { $0.itemIdentifier == ToolbarID.terminal }
        terminalButton = terminalToolbarItem?.view as? NSButton
    }

    private func syncTerminalToolbarItem() {
        let title = isTerminalVisible ? "Hide Terminal" : "Show Terminal"
        let state: NSControl.StateValue = isTerminalVisible ? .on : .off
        terminalButton?.state = state
        terminalButton?.toolTip = shortcutTooltip(title, action: "menu.toggleTerminal")
        terminalButton?.setAccessibilityLabel(title)
        terminalToolbarItem?.label = title
        terminalToolbarItem?.toolTip = terminalButton?.toolTip
        terminalToolbarItem?.menuFormRepresentation?.title = title
        terminalToolbarItem?.menuFormRepresentation?.state = state
    }

    private var splitActionTitle: String {
        tabs.isSplit ? (tabs.currentPage.activeSide == .left ? "Close Left Pane" : "Close Right Pane") : "Split View"
    }

    private func syncSplitToolbar() {
        splitButton?.state = tabs.isSplit ? .on : .off
        splitButton?.toolTip = shortcutTooltip(splitActionTitle, action: "menu.toggleSplit")
        splitButton?.setAccessibilityLabel(splitActionTitle)
        splitToolbarItem?.label = splitActionTitle
        splitToolbarItem?.toolTip = splitButton?.toolTip
        splitToolbarItem?.menuFormRepresentation?.title = splitActionTitle
        splitToolbarItem?.menuFormRepresentation?.state = tabs.isSplit ? .on : .off
    }

    private func shortcutTooltip(_ title: String, action: String) -> String {
        guard let shortcut = AppPreferences.shared.shortcuts.shortcut(for: action) else { return title }
        return "\(title) (\(shortcut.displayString))"
    }

    // MARK: - Keyboard & mouse that menus cannot express

    private func installEventMonitors() {
        // The same persistent catalog owns menu and contextual bindings.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            return ShortcutDispatcher.handle(e, in: self) ? nil : e
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
        viewOptionsController?.refresh()
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
        browser.setViewMode(Self.mode(forSegment: sender.selectedSegment))
    }
    @objc func focusOtherPane(_ sender: Any?) { tabs.focusOtherPane() }

    // MARK: - Actions (menu responder chain + toolbar targets)

    @objc func showSearch(_ sender: Any?) { browser.showSearch() }
    @objc func goBack(_ sender: Any?) { browser.goBack() }
    @objc func goForward(_ sender: Any?) { browser.goForward() }
    @objc func goUp(_ sender: Any?) { browser.goUp() }
    @objc func goHome(_ sender: Any?) { browser.goHome() }
    @objc func reload(_ sender: Any?) { browser.reloadForgettingArchiveFailures() }
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
        case #selector(togglePreviewPane(_:)):
            item.title = isPreviewVisible ? "Hide Preview" : "Show Preview"
            item.state = isPreviewVisible ? .on : .off
            return true
        case #selector(toggleTerminal(_:)):
            item.title = isTerminalVisible ? "Hide Terminal" : "Show Terminal"
            item.state = isTerminalVisible ? .on : .off
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
        case #selector(toggleFoldersPanel(_:)):
            item.title = isFoldersPanelVisible ? "Hide Folders" : "Show Folders"
            item.state = isFoldersPanelVisible ? .on : .off
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
        case ToolbarID.share:   return canShareSelection
        default: return true
        }
    }

    /// Pure: read from the rows, so validating the toolbar never extracts.
    var canShareSelection: Bool { browser.hasAccessibleSelection }
    /// What Share is handed: a file URL for anything on disk, and an item
    /// provider that extracts first for a ZIP entry not yet extracted (D101).
    var sharingItems: [Any] { browser.fileView.selectedItems.compactMap(ArchiveDragExport.sharingItem(for:)) }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] { sharingItems }

    func selectionDidChange(in pane: BrowserViewController) {
        guard pane === browser else { return }
        validateNavigation()
        refreshPreview()
    }

    func contentsDidChange(in pane: BrowserViewController) {
        guard pane === browser else { return }
        refreshPreview(force: true)
    }

    private func validateFileAction(_ item: NSMenuItem) -> Bool {
        guard let raw = item.representedObject as? String, let action = MainMenu.FileAction(rawValue: raw) else { return false }
        let count = browser.fileView.selectedItems.count
        switch action {
        case .newFolder: return browser.canModifyCurrentLocation
        case .getInfo: return !browser.isBrowsingArchive && browser.currentURL != nil
        case .open: return browser.canOpenSelection
        case .quickLook: return browser.canPreviewSelection
        case .copy: return browser.hasAccessibleSelection
        case .rename:
            // Finder's plural wording for a multi-selection batch rename.
            item.title = BrowserViewController.batchRenameTitle(count: count)
            return browser.canModifySelectedItems && count >= 1
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
    var isFoldersPanelVisible: Bool { sidebar.foldersVisible && !isSidebarCollapsed }
    /// The sidebar is looked up as `splitViewItems[0]` in three places, so a
    /// pane added ahead of it would break that silently.
    var isSidebarFirstSplitItemForTesting: Bool {
        splitViewController.splitViewItems.first?.viewController === sidebar
    }

    @objc func toggleFoldersPanel(_ sender: Any?) {
        let show = !isFoldersPanelVisible
        if show, isSidebarCollapsed { toggleSidebar(nil) }
        sidebar.setFoldersPanelVisible(show)
        if let url = browser.archiveSourceURL?.deletingLastPathComponent() ?? browser.currentURL { sidebar.foldersPanel?.follow(url) }
        onSessionChanged?()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        let item = splitViewController.splitViewItems[0]
        item.isCollapsed.toggle()
        sidebar.setFoldersActive(!item.isCollapsed)
        sidebarSessionGeometryChanged()
        // Restoring focus avoids leaving it in an invisible outline view.
        if item.isCollapsed { window?.makeFirstResponder(browser.focusView) }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar).filter {
            $0 != ToolbarID.terminal || AppPreferences.experimentalTerminalEnabled
        }
    }

    /// Always names the terminal, whatever Settings says: `insertItem` may only
    /// place an identifier its delegate allows, and that is how the button
    /// comes back when the entry point is switched on again.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.sidebar, ToolbarID.back, ToolbarID.forward, ToolbarID.up, .flexibleSpace, ToolbarID.split, ToolbarID.terminal, ToolbarID.viewMode, ToolbarID.group, ToolbarID.share, ToolbarID.more, ToolbarID.search]
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
            let (item, button) = toggleItem(id, "Split View", "rectangle.split.2x1", #selector(toggleSplit(_:)), overflowTitle: splitActionTitle)
            splitButton = button
            splitToolbarItem = item
            syncSplitToolbar()
            return item
        case ToolbarID.terminal:
            let (item, button) = toggleItem(id, "Terminal", "terminal", #selector(toggleTerminal(_:)), overflowTitle: "Show Terminal")
            terminalButton = button
            terminalToolbarItem = item
            syncTerminalToolbarItem()
            return item
        case ToolbarID.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.label = "Share"
            item.toolTip = "Share selected items"
            item.delegate = self
            item.autovalidates = false
            item.isEnabled = canShareSelection
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
                NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Columns")!,
            ], trackingMode: .selectOne, target: self, action: #selector(viewModeChanged(_:)))
            control.segmentStyle = .automatic
            control.setToolTip(shortcutTooltip("as Icons", action: "menu.viewAsIcons"), forSegment: 0)
            control.setToolTip(shortcutTooltip("as List", action: "menu.viewAsList"), forSegment: 1)
            control.setToolTip(shortcutTooltip("as Columns", action: "menu.viewAsColumns"), forSegment: 2)
            control.selectedSegment = Self.segment(for: browser.viewMode)
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

    /// Split / Terminal: a push-on-push-off button whose state the window syncs by hand.
    private func toggleItem(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String,
                            _ action: Selector, overflowTitle: String) -> (NSToolbarItem, NSButton) {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                              target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageOnly
        let item = NSToolbarItem(itemIdentifier: id)
        item.paletteLabel = label
        item.view = button
        item.target = self
        item.action = action
        item.autovalidates = false
        item.visibilityPriority = .high
        let overflow = NSMenuItem(title: overflowTitle, action: action, keyEquivalent: "")
        overflow.target = self
        item.menuFormRepresentation = overflow
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

    func windowDidMove(_ notification: Notification) { onSessionChanged?() }
    func windowDidResize(_ notification: Notification) { onSessionChanged?() }
    func windowDidMiniaturize(_ notification: Notification) { onSessionChanged?() }
    func windowDidDeminiaturize(_ notification: Notification) { onSessionChanged?() }
    func windowDidBecomeKey(_ notification: Notification) { onSessionChanged?() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isCheckingTerminalClose else { return false }
        isCheckingTerminalClose = true
        let approved = terminalTaskConfirmation(.closeWindow, terminalPanel.map { [$0.activitySnapshot()] } ?? [])
        isCheckingTerminalClose = false
        guard approved else { return false }
        let tasks = TransferTasksWindowController.shared
        guard tasks.hasActiveTasks(ownedBy: sender) else { return true }
        tasks.cancelTasks(ownedBy: sender) { [weak self] in self?.window?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        viewOptionsController?.close()
        tabs.pages.flatMap(\.panes).forEach {
            $0.suspendPendingNavigation()
            $0.searchPanel.cancelPendingSearch()
        }
        removeEventMonitors()
        shutdownTerminal()
        shutdownPreview()
        sidebar.setFoldersActive(false)
        if let shortcutsObserver { NotificationCenter.default.removeObserver(shortcutsObserver) }
        shortcutsObserver = nil
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        preferencesObserver = nil
        if let sidebarResizeObserver { NotificationCenter.default.removeObserver(sidebarResizeObserver) }
        sidebarResizeObserver = nil
        onClose?()
    }
}

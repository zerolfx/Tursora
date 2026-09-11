import AppKit
import Quartz

/// What a browsing pane needs from the window that hosts it.
protocol BrowserHost: AnyObject {
    var places: PlacesModel { get }
    var isSplit: Bool { get }
    func openInNewTab(_ url: URL, activate: Bool)
    func openInNewWindow(_ url: URL)
    func openInOtherPane(_ url: URL)
    func transferToOtherPane(_ urls: [URL], move: Bool)
    func viewModeDidChange(in pane: BrowserViewController)
}

/// One browsing pane: a directory model, its navigation history, and the
/// file list that shows it. Each tab owns one of these.
final class BrowserViewController: NSViewController, NSMenuDelegate, NSMenuItemValidation,
                                   QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    let provider: FileProvider
    let model: DirectoryModel
    let history = NavigationHistory()
    /// The details list (always present; the default view).
    let fileList: FileListViewController
    /// The icon grid, created on first use.
    private(set) lazy var iconGrid: IconGridViewController = {
        let g = IconGridViewController(model: model)
        wire(g)
        return g
    }()
    /// Whichever of the two is showing.
    private(set) var fileView: FileViewing
    var focusView: NSView { fileView.focusView }
    let statusBar = StatusBarView()
    weak var host: BrowserHost?

    private(set) var viewMode: ViewMode = ViewPreferences.viewMode
    private(set) var zoomIndex: Int = ViewPreferences.zoomIndex(for: ViewPreferences.viewMode)
    private(set) var showsPreviews: Bool = ViewPreferences.showPreviews
    var groupKey: GroupKey { model.groupKey }
    var usesGroups: Bool { model.groupKey != .none }

    /// ⌘X state is app-wide: cut in one tab, paste in another.
    private static var cutState: (changeCount: Int, urls: [URL])?

    var onLocationChanged: ((URL) -> Void)?
    /// The pane took focus or was clicked — the tab page activates it.
    var onFocus: (() -> Void)?

    private(set) var currentURL: URL?
    private let activeIndicator = NSView()
    private var indicatorHeight: NSLayoutConstraint?
    private var lastError: Error?
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let contextMenu = NSMenu()
    /// Holds whichever file view is current.
    private let viewHost = NSView()
    private var watcher: DirectoryWatcher?
    private var refreshDebounce: DispatchWorkItem?

    init(provider: FileProvider, initialURL: URL) {
        self.provider = provider
        self.model = DirectoryModel(provider: provider)
        self.fileList = FileListViewController(model: model)
        self.fileView = fileList
        model.groupKey = ViewPreferences.groupKey
        super.init(nibName: nil, bundle: nil)
        wire(fileList)
        // Match the persisted mode before loadView mounts a child. Calling
        // setViewMode here would return early because viewMode already matches.
        if viewMode == .icons { fileView = iconGrid }
        contextMenu.delegate = self
        statusBar.onZoomChanged = { [weak self] index in self?.setZoomIndex(index) }
        NotificationCenter.default.addObserver(self, selector: #selector(directoriesChanged(_:)),
                                               name: .tursoraDirectoriesChanged, object: nil)

        model.onChange = { [weak self] in
            guard let self else { return }
            self.fileView.reloadData()
            self.errorLabel.isHidden = self.lastError == nil
            self.updateStatus()
        }
        model.onError = { [weak self] error in
            guard let self else { return }
            self.lastError = error
            self.errorLabel.stringValue = "Cannot open this folder.\n\(error.localizedDescription)"
        }
        // Deferred so the owner can wire onLocationChanged first.
        DispatchQueue.main.async { [weak self] in self?.navigate(to: initialURL) }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Keeping the listing current

    /// Folders whose contents are on screen: the directory plus any expanded subfolders.
    var displayedDirectories: [URL] {
        var out: [URL] = []
        if let currentURL { out.append(currentURL) }
        out += fileList.expandedFolderURLs
        return out
    }

    /// FSEvents reports real paths (/private/var/…) even when we watch through
    /// a symlink (/var/…), so compare with symlinks resolved on both sides.
    private func isDisplaying(_ path: String) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let dirs = Set(displayedDirectories.map { $0.resolvingSymlinksInPath().path })
        return dirs.contains(real) || dirs.contains((real as NSString).deletingLastPathComponent)
    }

    /// FSEvents saw changes; refresh if any touch what this pane shows.
    private func fileSystemChanged(_ paths: [String]) {
        guard paths.contains(where: isDisplaying) else { return }
        scheduleRefresh()
    }

    /// Old name → new name for items renamed since the last refresh, so the
    /// selection follows them instead of being dropped.
    private var pendingRenames: [String: String] = [:]

    @objc private func directoriesChanged(_ note: Notification) {
        guard let dirs = note.userInfo?["directories"] as? [URL],
              dirs.contains(where: { isDisplaying($0.standardizedFileURL.path) }) else { return }
        if let from = note.userInfo?["renamedFrom"] as? URL, let to = note.userInfo?["renamedTo"] as? URL,
           isDisplaying(from.deletingLastPathComponent().path) {
            pendingRenames[from.lastPathComponent] = to.lastPathComponent
        }
        scheduleRefresh()
    }

    /// Coalesce bursts (a copy of many files is many events) into one reload.
    func scheduleRefresh(after delay: TimeInterval = 0.15) {
        refreshDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreservingSelection() }
        refreshDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A reload that keeps what the user has selected and where they scrolled —
    /// for changes that happened *around* them, not ones they asked for.
    func refreshPreservingSelection() {
        let renames = pendingRenames
        pendingRenames = [:]
        let names = fileView.selectedItems.map { renames[$0.name] ?? $0.name }
        let offset = fileView.scrollOffset
        model.reload { [weak self] in
            guard let self else { return }
            self.fileView.select(names: names)
            self.fileView.scrollOffset = offset
        }
    }

    /// Hook a file view (list or grid) up to the browser.
    private func wire(_ v: FileViewing) {
        v.onOpen = { [weak self] item in self?.open(item) }
        v.onOpenInNewTab = { [weak self] item in
            guard item.isNavigable else { return }
            self?.host?.openInNewTab(item.url, activate: false)
        }
        v.onRenameCommitted = { [weak self] item, name in self?.rename(item, to: name) }
        v.onSelectionChanged = { [weak self] in
            self?.updateStatus()
            if let self { NotificationCenter.default.post(name: .tursoraSelectionChanged, object: self) }
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible { panel.reloadData() }
        }
        v.onFocus = { [weak self] in self?.onFocus?() }
        v.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        v.onDropFiles = { [weak self] urls, dest, op in self?.dropFiles(urls, to: dest, op: op) }
        v.onZoomGesture = { [weak self] step in self?.zoom(by: step) }
        v.contextMenu = contextMenu
        v.setIconSize(ZoomLevel.sizes(for: viewMode)[zoomIndex], showPreviews: showsPreviews)
    }

    override func loadView() {
        let v = SwipeView()
        v.onSwipe = { [weak self] dx in
            // Trackpad "swipe between pages": right-to-left content motion = forward.
            if dx > 0 { self?.goBack() } else if dx < 0 { self?.goForward() }
        }
        view = v
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        activeIndicator.translatesAutoresizingMaskIntoConstraints = false
        activeIndicator.wantsLayer = true
        viewHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activeIndicator)
        view.addSubview(viewHost)
        view.addSubview(statusBar)
        let h = activeIndicator.heightAnchor.constraint(equalToConstant: 0)
        indicatorHeight = h
        NSLayoutConstraint.activate([
            activeIndicator.topAnchor.constraint(equalTo: view.topAnchor),
            activeIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            activeIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            h,
            viewHost.topAnchor.constraint(equalTo: activeIndicator.bottomAnchor),
            viewHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height),
        ])

        errorLabel.alignment = .center
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
        ])
        mount(fileView)
        syncZoomSlider()
    }

    // MARK: - Name filter (driven by the window's toolbar search field)

    /// Filter-bar text for this pane; empty = unfiltered. Per pane, like Dolphin.
    var nameFilter: String {
        get { model.nameFilter }
        set { model.nameFilter = newValue; onFilterChanged?(newValue) }
    }
    var isFiltering: Bool { !model.nameFilter.isEmpty }
    /// "3 of 12 items" for the scope bar.
    var filterSummary: String {
        guard isFiltering else { return "" }
        return "\(model.items.count) of \(model.unfilteredCount) items"
    }
    var onFilterChanged: ((String) -> Void)?

    private func mount(_ v: FileViewing) {
        addChild(v.viewController)
        viewHost.pinToEdges(v.viewController.view)
    }

    // MARK: - View mode, zoom, previews

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let selected = fileView.selectedItems.map(\.name)
        let hadFocus = view.window?.firstResponder === fileView.focusView
        fileView.viewController.view.removeFromSuperview()
        fileView.viewController.removeFromParent()
        viewMode = mode
        zoomIndex = ViewPreferences.zoomIndex(for: mode)
        ViewPreferences.viewMode = mode
        fileView = mode == .icons ? iconGrid : fileList
        if isViewLoaded { mount(fileView) }
        fileView.setIconSize(ZoomLevel.sizes(for: mode)[zoomIndex], showPreviews: showsPreviews)
        fileView.reloadData()
        fileView.select(names: selected)
        syncZoomSlider()
        if hadFocus { view.window?.makeFirstResponder(fileView.focusView) }
        host?.viewModeDidChange(in: self)
    }

    var iconSize: CGFloat { ZoomLevel.sizes(for: viewMode)[zoomIndex] }

    func setZoomIndex(_ index: Int) {
        let clamped = ZoomLevel.clamp(index, for: viewMode)
        guard clamped != zoomIndex else { return }
        zoomIndex = clamped
        ViewPreferences.setZoomIndex(clamped, for: viewMode)
        fileView.setIconSize(iconSize, showPreviews: showsPreviews)
        syncZoomSlider()
    }

    func zoom(by step: Int) { setZoomIndex(zoomIndex + step) }

    func setShowsPreviews(_ on: Bool) {
        showsPreviews = on
        ViewPreferences.showPreviews = on
        fileView.setIconSize(iconSize, showPreviews: on)
    }

    private func syncZoomSlider() {
        statusBar.setZoom(index: zoomIndex, count: ZoomLevel.sizes(for: viewMode).count)
    }

    // MARK: - Groups (Finder's View ▸ Use Groups / Group By)

    func setGroupKey(_ key: GroupKey) {
        model.groupKey = key
        ViewPreferences.groupKey = key
        if key != .none { ViewPreferences.lastGroupKey = key }
    }

    /// ⌃⌘0: off → back to the last key used (Kind at first); on → off.
    @objc func toggleGroups(_ sender: Any?) {
        setGroupKey(usesGroups ? .none : ViewPreferences.lastGroupKey)
    }

    @objc func groupBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = GroupKey(rawValue: raw) else { return }
        setGroupKey(key)
    }

    @objc func viewAsIcons(_ sender: Any?) { setViewMode(.icons) }
    @objc func viewAsList(_ sender: Any?) { setViewMode(.details) }
    @objc func zoomIn(_ sender: Any?) { zoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: -1) }
    @objc func zoomActualSize(_ sender: Any?) { setZoomIndex(ZoomLevel.defaultIndex(for: viewMode)) }
    @objc func togglePreviews(_ sender: Any?) { setShowsPreviews(!showsPreviews) }

    // MARK: - Quick Look (shared by both views)

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { fileView.selectedItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = fileView.selectedItems
        return items.indices.contains(index) ? items[index].url as NSURL : nil
    }

    /// Arrow keys in the panel move the selection, so ↑/↓ browse previews.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) else { return false }
        fileView.forwardKey(event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        return fileView.frameOnScreen(for: url)
    }

    /// nil = not in a split (no indicator); true/false = active/inactive pane.
    func setActiveIndicator(_ active: Bool?) {
        _ = view
        indicatorHeight?.constant = active == nil ? 0 : 3
        activeIndicator.layer?.backgroundColor = (active == true ? NSColor.controlAccentColor : NSColor.clear).cgColor
    }

    // MARK: - Navigation

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var canGoUp: Bool { currentURL.map { $0.path != "/" } ?? false }

    func navigate(to url: URL) {
        saveViewState()
        history.push(url)
        load(url)
    }

    func goBack() {
        saveViewState()
        if let url = history.goBack() { load(url) }
    }

    func goForward() {
        saveViewState()
        if let url = history.goForward() { load(url) }
    }

    func goUp() {
        guard let currentURL, canGoUp else { return }
        let leftName = currentURL.lastPathComponent
        navigate(to: currentURL.deletingLastPathComponent())
        // Coming up out of a folder, the folder we left is the natural selection.
        pendingSelection = leftName
    }

    func goHome() { navigate(to: provider.homeURL) }

    /// Jump to any history slot (from the back/forward long-press menus).
    func goToHistory(slot: Int) {
        saveViewState()
        if let url = history.go(to: slot) { load(url) }
    }

    /// Entries behind (back) or ahead (forward) of the current one, nearest first.
    func historyMenu(back: Bool) -> NSMenu {
        let menu = NSMenu()
        let entries = back ? history.backEntries() : history.forwardEntries()
        for (slot, entry) in entries {
            let item = NSMenuItem(title: provider.displayName(for: entry.url), action: #selector(historyMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = slot
            item.toolTip = (entry.url.path as NSString).abbreviatingWithTildeInPath
            let icon = NSWorkspace.shared.icon(forFile: entry.url.path); icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        return menu
    }

    @objc private func historyMenuItem(_ sender: NSMenuItem) { goToHistory(slot: sender.tag) }

    func reload() {
        saveViewState()
        model.reload { [weak self] in self?.restoreViewState() }
    }

    var showsHiddenFiles: Bool {
        get { model.showHidden }
        set { model.showHidden = newValue }
    }

    func openSelection() { fileView.openSelection() }

    // MARK: - Simple file operations available before M5

    /// Creates "untitled folder" (or "untitled folder 2", …) and selects it.
    @discardableResult
    func newFolder() -> URL? {
        guard let currentURL else { return nil }
        var name = "untitled folder"
        var n = 2
        while FileManager.default.fileExists(atPath: currentURL.appendingPathComponent(name).path) {
            name = "untitled folder \(n)"; n += 1
        }
        let url = currentURL.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            report(error, context: "new folder")
            return nil
        }
        pendingSelection = name
        model.reload { [weak self] in self?.restoreViewState() }
        DirectoryChanges.post([currentURL])
        return url
    }

    // MARK: - File operations (M5)

    private var selectedURLs: [URL] { fileView.selectedItems.map(\.url) }
    private var undo: UndoManager? { view.window?.undoManager }

    /// Errors go to stdout in smoke-test mode — a modal sheet would hang a
    /// headless run (and hide the message from the log).
    func report(_ error: Error, context: String = "") {
        if SmokeTest.isRequested {
            print("ERROR \(context): \(error)")
        } else {
            presentError(error)
        }
    }

    func updateStatus() {
        statusBar.update(itemCount: model.items.count,
                         totalCount: model.nameFilter.isEmpty ? nil : model.unfilteredCount,
                         selectedCount: fileView.selectedItems.count, directory: currentURL)
    }

    private func reloadSelecting(_ names: [String]) {
        model.reload { [weak self] in self?.fileView.select(names: names) }
    }

    // Edit menu — reached via the responder chain when the list has focus.

    @objc func copy(_ sender: Any?) { putOnPasteboard(selectedURLs, cut: false) }
    @objc func cut(_ sender: Any?) { putOnPasteboard(selectedURLs, cut: true) }

    private func putOnPasteboard(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        Self.cutState = cut ? (pb.changeCount, urls) : nil
        fileList.cutURLs = cut ? Set(urls) : []
        if viewMode == .icons { iconGrid.cutURLs = fileList.cutURLs }
    }

    @objc func paste(_ sender: Any?) {
        guard let dest = currentURL else { return }
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        let isCut = Self.cutState?.changeCount == pb.changeCount
        transfer(urls, to: dest, kind: isCut ? .move : .copy) { [weak self] in
            if isCut { Self.cutState = nil; pb.clearContents(); self?.fileList.cutURLs = []; if self?.viewMode == .icons { self?.iconGrid.cutURLs = [] } }
        }
    }

    @objc func duplicate(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let (created, failures) = FileOperations.duplicate(urls)
        registerUndoTrash(created, actionName: "Duplicate")
        reloadSelecting(created.map(\.lastPathComponent))
        DirectoryChanges.post(DirectoryChanges.affected(sources: urls))
        FileOperations.report(failures, in: view.window)
    }

    @objc func moveToTrash(_ sender: Any?) { trash(selectedURLs) }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Dolphin selects the next item after deleting; Finder selects nothing. Dolphin wins here.
        let nextName = fileView.itemAfterSelection()?.name
        do {
            let pairs = try FileOperations.trash(urls)
            if SmokeTest.isRequested { for p in pairs { print("   trashed \(p.original.lastPathComponent) → \(p.trashed.path)") } }
            registerUndoMove(pairs.map { (from: $0.original, to: $0.trashed) }, actionName: "Move to Trash")
            reloadSelecting(nextName.map { [$0] } ?? [])
            DirectoryChanges.post(DirectoryChanges.affected(sources: urls))
        } catch {
            report(error, context: "trash")
            reload()
        }
    }

    @objc func deletePermanently(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Are you sure you want to delete “\(urls[0].lastPathComponent)”?"
            : "Are you sure you want to delete the \(urls.count) selected items?"
        alert.informativeText = "This item will be deleted immediately. You can’t undo this action."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try FileOperations.delete(urls) } catch { report(error, context: "delete") }
        reload()
        DirectoryChanges.post(DirectoryChanges.affected(sources: urls))
    }

    @objc func renameSelection(_ sender: Any?) {
        guard let item = fileView.selectedItems.first, fileView.selectedItems.count == 1 else { return }
        fileView.beginRename(item: item)
    }

    @objc func quickLook(_ sender: Any?) { toggleQuickLook() }

    func rename(_ item: FileItem, to name: String) {
        do {
            let newURL = try FileOperations.rename(item.url, to: name)
            registerUndoRename(from: newURL, to: item.name, actionName: "Rename")
            reloadSelecting([name])
            DirectoryChanges.post(DirectoryChanges.affected(sources: [item.url]), renamed: (from: item.url, to: newURL))
        } catch {
            report(error, context: "rename")
            reload()
        }
    }

    /// Drop or sidebar-drop: op is .copy or .move.
    func dropFiles(_ urls: [URL], to destination: URL, op: NSDragOperation) {
        transfer(urls, to: destination, kind: op == .copy ? .copy : .move)
    }

    private func transfer(_ urls: [URL], to destination: URL, kind: FileOperations.Kind,
                          then: (() -> Void)? = nil) {
        statusBar.beginBusy()
        let window = view.window
        FileOperations.transfer(urls, to: destination, kind: kind,
            conflict: { conflict in FileOperations.askConflict(in: window, conflict) }
        ) { [weak self] result in
            guard let self else { return }
            self.statusBar.endBusy()
            switch kind {
            case .copy: self.registerUndoTrash(result.created, actionName: "Copy")
            case .move: self.registerUndoMove(result.moved, actionName: "Move")
            }
            let names = (result.created + result.moved.map(\.to)).map(\.lastPathComponent)
            if destination.standardizedFileURL == self.currentURL?.standardizedFileURL {
                self.reloadSelecting(names)
            } else {
                self.reload()
            }
            then?()
            // The source folder is usually another pane, tab or window: tell it.
            DirectoryChanges.post(DirectoryChanges.affected(sources: urls, destination: destination))
            FileOperations.report(result.failures, in: window)
        }
    }

    // Undo — registered on the window's undo manager so Edit ▸ Undo just works.

    /// Every file operation becomes its own undo group. Registrations arrive
    /// from async completions, and NSUndoManager's automatic per-event group
    /// can still be open from an earlier operation — observed in testing: a
    /// Copy and a later Move landed in one group and were undone together,
    /// which trashed the file the Move had just restored. So: close any stale
    /// automatic group (undo() itself does the same), then group explicitly.
    private func asUndoGroup(_ undo: UndoManager, actionName: String, _ register: () -> Void) {
        if !undo.isUndoing, !undo.isRedoing {
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
        undo.beginUndoGrouping()
        register()
        undo.setActionName(actionName)
        undo.endUndoGrouping()
        // With groupsByEvent on, NSUndoManager wraps a top-level group of ours
        // in an event group that stays open until the run loop turns. Close it
        // now so the operation is complete and self-contained immediately.
        if !undo.isUndoing, !undo.isRedoing {
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
        if SmokeTest.isRequested { print("   [undo] \(actionName) registered (undoing=\(undo.isUndoing), top=\(undo.undoActionName), level=\(undo.groupingLevel))") }
    }

    private func registerUndoMove(_ pairs: [(from: URL, to: URL)], actionName: String) {
        guard !pairs.isEmpty, let undo else { return }
        asUndoGroup(undo, actionName: actionName) {
            undo.registerUndo(withTarget: self) { me in
                var reversed: [(from: URL, to: URL)] = []
                for (from, to) in pairs {
                    do { try FileManager.default.moveItem(at: to, to: from); reversed.append((from: to, to: from)) }
                    catch { me.report(error, context: "undo move \(to.path) → \(from.path)") }
                }
                me.registerUndoMove(reversed, actionName: actionName)     // redo
                me.reloadSelecting(reversed.map(\.to.lastPathComponent))
                DirectoryChanges.post(pairs.flatMap { [$0.from.deletingLastPathComponent(), $0.to.deletingLastPathComponent()] })
            }
        }
    }

    private func registerUndoTrash(_ urls: [URL], actionName: String) {
        guard !urls.isEmpty, let undo else { return }
        asUndoGroup(undo, actionName: actionName) {
            undo.registerUndo(withTarget: self) { me in
                do {
                    let pairs = try FileOperations.trash(urls)
                    me.registerUndoMove(pairs.map { (from: $0.original, to: $0.trashed) }, actionName: actionName)
                } catch { me.report(error, context: "undo copy (trash)") }
                me.reload()
            }
        }
    }

    private func registerUndoRename(from url: URL, to oldName: String, actionName: String) {
        guard let undo else { return }
        asUndoGroup(undo, actionName: actionName) {
            undo.registerUndo(withTarget: self) { me in
                do {
                    let newName = url.lastPathComponent
                    let back = try FileOperations.rename(url, to: oldName)
                    me.registerUndoRename(from: back, to: newName, actionName: actionName)
                    me.reloadSelecting([oldName])
                } catch { me.report(error, context: "undo rename"); me.reload() }
            }
        }
    }

    // MARK: - Menu validation for the file operations

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasSelection = !fileView.selectedItems.isEmpty
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(duplicate(_:)), #selector(moveToTrash(_:)),
             #selector(deletePermanently(_:)), #selector(quickLook(_:)):
            return hasSelection
        case #selector(renameSelection(_:)):
            return fileView.selectedItems.count == 1
        case #selector(viewAsIcons(_:)):
            item.state = viewMode == .icons ? .on : .off; return true
        case #selector(viewAsList(_:)):
            item.state = viewMode == .details ? .on : .off; return true
        case #selector(togglePreviews(_:)):
            item.state = showsPreviews ? .on : .off; return true

        case #selector(toggleGroups(_:)):
            item.state = usesGroups ? .on : .off; return true
        case #selector(groupBy(_:)):
            item.state = (item.representedObject as? String) == groupKey.rawValue ? .on : .off; return true
        case #selector(zoomIn(_:)):  return zoomIndex < ZoomLevel.sizes(for: viewMode).count - 1
        case #selector(zoomOut(_:)): return zoomIndex > 0
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            return hasSelection && host?.isSplit == true
        case #selector(paste(_:)):
            return currentURL != nil && NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        default:
            return true
        }
    }

    // MARK: - Get Info (⌘I), Show Inspector (⌥⌘I), Get Summary Info (⌃⌘I)

    /// Finder's targets: the selection, or the folder itself when nothing is selected.
    var infoTargets: [URL] {
        let selected = selectedURLs
        if !selected.isEmpty { return selected }
        return currentURL.map { [$0] } ?? []
    }

    @objc func getInfo(_ sender: Any?) { InfoWindowController.show(for: infoTargets, relativeTo: view.window) }
    @objc func getSummaryInfo(_ sender: Any?) { InfoWindowController.showSummary(for: infoTargets, relativeTo: view.window) }
    @objc func showInspector(_ sender: Any?) { InfoWindowController.showInspector(relativeTo: view.window) }
    @objc private func ctxGetInfo(_ s: Any?) {
        let targets = contextTargets.map(\.url)
        InfoWindowController.show(for: targets.isEmpty ? infoTargets : targets, relativeTo: view.window)
    }

    // MARK: - Context menu

    private var pendingSelection: String?

    /// Items a context-menu action applies to: the selection if the clicked
    /// row is part of it, otherwise just the clicked row (Finder semantics).
    private var contextTargets: [FileItem] { fileView.clickedItems }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu else { return }
        menu.removeAllItems()
        for item in buildContextMenu(for: contextTargets).items {
            menu.addItem(item.copy() as! NSMenuItem)
        }
    }

    /// Public and side-effect free so it can be unit-checked.
    func buildContextMenu(for items: [FileItem]) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, _ key: String = "", enabled: Bool = true,
                 state: NSControl.StateValue = .off, symbol: String? = nil) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.target = self; mi.isEnabled = enabled; mi.state = state
            mi.image = MenuIcons.image(symbol)
            menu.addItem(mi)
        }
        if items.isEmpty {
            add("New Folder", #selector(ctxNewFolder(_:)), symbol: "folder.badge.plus")
            add("Get Info", #selector(ctxGetInfo(_:)), symbol: "info.circle")
            add("Paste", #selector(paste(_:)), enabled: validateMenuItem(NSMenuItem(title: "", action: #selector(paste(_:)), keyEquivalent: "")),
                symbol: "document.on.clipboard|doc.on.clipboard")
            menu.addItem(.separator())
            add("Reload", #selector(ctxReload(_:)), symbol: "arrow.clockwise")
            add("Show Hidden Files", #selector(ctxToggleHidden(_:)), state: showsHiddenFiles ? .on : .off)
            menu.addItem(sortMenuItem())
            if let currentURL, let host {
                menu.addItem(.separator())
                let fav = host.places.isFavourite(currentURL)
                add(fav ? "Remove from Favourites" : "Add to Favourites", #selector(ctxToggleFavourite(_:)), symbol: fav ? "star.slash" : "star")
            }
            return menu
        }

        let folders = items.filter(\.isNavigable)
        let single = items.count == 1 ? items[0] : nil

        add("Open", #selector(ctxOpen(_:)))
        if let single, !single.isNavigable {
            menu.addItem(openWithMenuItem(for: single.url))
        }
        if !folders.isEmpty {
            add(folders.count == 1 ? "Open in New Tab" : "Open in \(folders.count) New Tabs", #selector(ctxOpenInNewTab(_:)))
            if folders.count == 1 {
                add("Open in New Window", #selector(ctxOpenInNewWindow(_:)))
                add(host?.isSplit == true ? "Open in Other Pane" : "Open in New Pane", #selector(ctxOpenInOtherPane(_:)))
            }
        }
        if host?.isSplit == true {
            menu.addItem(.separator())
            add("Copy to Other Pane", #selector(ctxCopyToOtherPane(_:)))
            add("Move to Other Pane", #selector(ctxMoveToOtherPane(_:)))
        }
        menu.addItem(.separator())
        add("Quick Look", #selector(ctxQuickLook(_:)), symbol: "eye")
        add("Get Info", #selector(ctxGetInfo(_:)), symbol: "info.circle")
        if items.count == 1 { add("Rename", #selector(ctxRename(_:)), symbol: "pencil") }
        add("Duplicate", #selector(ctxDuplicate(_:)), symbol: "plus.square.on.square")
        add("Move to Trash", #selector(ctxTrash(_:)), symbol: "trash")
        menu.addItem(.separator())
        add("Cut", #selector(ctxCut(_:)), symbol: "scissors")
        add("Copy", #selector(ctxCopy(_:)), symbol: "document.on.document|doc.on.doc")
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(ctxRevealInFinder(_:)))
        add(items.count == 1 ? "Copy Path" : "Copy Paths", #selector(ctxCopyPath(_:)), symbol: "document.on.document|doc.on.doc")
        if let single, single.isNavigable, let host {
            menu.addItem(.separator())
            let fav = host.places.isFavourite(single.url)
            add(fav ? "Remove from Favourites" : "Add to Favourites", #selector(ctxToggleFavourite(_:)), symbol: fav ? "star.slash" : "star")
        }
        return menu
    }

    private func openWithMenuItem(for url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let defaultApp {
            apps.removeAll { $0 == defaultApp }
            apps.insert(defaultApp, at: 0)
        }
        for (i, app) in apps.prefix(20).enumerated() {
            let name = FileManager.default.displayName(atPath: app.path)
            let mi = NSMenuItem(title: i == 0 && defaultApp != nil ? "\(name) (default)" : name,
                                action: #selector(ctxOpenWith(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path); icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
            sub.addItem(mi)
            if i == 0, defaultApp != nil, apps.count > 1 { sub.addItem(.separator()) }
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: ""); none.isEnabled = false
            sub.addItem(none)
        }
        item.submenu = sub
        return item
    }

    private func sortMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, key) in [("Name", DirectoryModel.SortKey.name), ("Date Modified", .dateModified),
                             ("Size", .size), ("Kind", .kind)] {
            let mi = NSMenuItem(title: title, action: #selector(ctxSort(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = key.rawValue
            mi.state = model.sortKey == key ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        let asc = NSMenuItem(title: "Ascending", action: #selector(ctxToggleSortOrder(_:)), keyEquivalent: "")
        asc.target = self; asc.state = model.ascending ? .on : .off
        sub.addItem(asc)
        item.submenu = sub
        return item
    }

    @objc private func ctxOpen(_ s: Any?) { contextTargets.forEach(open) }
    @objc private func ctxQuickLook(_ s: Any?) { selectContextTargets(); toggleQuickLook() }
    @objc private func ctxRename(_ s: Any?) {
        if let item = contextTargets.first { fileView.beginRename(item: item) }
    }
    @objc private func ctxDuplicate(_ s: Any?) { selectContextTargets(); duplicate(nil) }
    @objc private func ctxTrash(_ s: Any?) { trash(contextTargets.map(\.url)) }
    @objc private func ctxCut(_ s: Any?) { putOnPasteboard(contextTargets.map(\.url), cut: true) }
    @objc private func ctxCopy(_ s: Any?) { putOnPasteboard(contextTargets.map(\.url), cut: false) }
    /// Context actions that reuse selection-based commands first make the targets the selection.
    private func selectContextTargets() {
        fileView.select(names: contextTargets.map(\.name))
    }
    @objc private func ctxOpenWith(_ s: NSMenuItem) {
        guard let app = s.representedObject as? URL else { return }
        NSWorkspace.shared.open(contextTargets.map(\.url), withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func ctxOpenInNewTab(_ s: Any?) {
        for f in contextTargets.filter(\.isNavigable) { host?.openInNewTab(f.url, activate: false) }
    }
    @objc private func ctxOpenInOtherPane(_ s: Any?) {
        if let f = contextTargets.first(where: \.isNavigable) { host?.openInOtherPane(f.url) }
    }
    @objc private func ctxCopyToOtherPane(_ s: Any?) { host?.transferToOtherPane(contextTargets.map(\.url), move: false) }
    @objc private func ctxMoveToOtherPane(_ s: Any?) { host?.transferToOtherPane(contextTargets.map(\.url), move: true) }
    @objc func copyToOtherPane(_ s: Any?) { host?.transferToOtherPane(selectedURLs, move: false) }
    @objc func moveToOtherPane(_ s: Any?) { host?.transferToOtherPane(selectedURLs, move: true) }
    @objc private func ctxOpenInNewWindow(_ s: Any?) {
        if let f = contextTargets.first(where: \.isNavigable) { host?.openInNewWindow(f.url) }
    }
    @objc private func ctxRevealInFinder(_ s: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(contextTargets.map(\.url))
    }
    @objc private func ctxCopyPath(_ s: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(contextTargets.map(\.url.path).joined(separator: "\n"), forType: .string)
    }
    @objc private func ctxToggleFavourite(_ s: Any?) {
        guard let host else { return }
        let url = contextTargets.first(where: \.isNavigable)?.url ?? currentURL
        guard let url else { return }
        host.places.isFavourite(url) ? host.places.removeFavourite(url) : host.places.addFavourite(url)
    }
    @objc private func ctxNewFolder(_ s: Any?) { newFolder() }
    @objc private func ctxReload(_ s: Any?) { reload() }
    @objc private func ctxToggleHidden(_ s: Any?) { showsHiddenFiles.toggle() }
    @objc private func ctxSort(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let key = DirectoryModel.SortKey(rawValue: raw) else { return }
        fileList.setSort(key: key, ascending: model.ascending)
    }
    @objc private func ctxToggleSortOrder(_ s: Any?) {
        fileList.setSort(key: model.sortKey, ascending: !model.ascending)
    }

    // MARK: - Private

    private func load(_ url: URL) {
        let changingDirectory = currentURL?.standardizedFileURL != url.standardizedFileURL
        currentURL = url
        lastError = nil
        errorLabel.isHidden = true
        refreshDebounce?.cancel()
        if changingDirectory, isFiltering { nameFilter = "" }     // Dolphin: clear on directory change
        watcher = DirectoryWatcher(directory: url) { [weak self] paths in self?.fileSystemChanged(paths) }
        model.load(url) { [weak self] in self?.restoreViewState() }
        onLocationChanged?(url)
        NotificationCenter.default.post(name: .tursoraSelectionChanged, object: self)
    }

    private func open(_ item: FileItem) {
        if item.isNavigable {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func saveViewState() {
        history.recordViewState(selectedName: fileView.selectedItems.first?.name,
                                scrollOffset: fileView.scrollOffset)
    }

    private func restoreViewState() {
        if let pendingSelection {
            self.pendingSelection = nil
            fileView.select(name: pendingSelection)
            return
        }
        guard let entry = history.current else { return }
        if let name = entry.selectedName {
            fileView.select(name: name)
        } else {
            fileView.select(name: nil)
            fileView.scrollOffset = entry.scrollOffset
        }
    }
}

/// Content view that turns trackpad page-swipes into history navigation.
private final class SwipeView: NSView {
    var onSwipe: ((CGFloat) -> Void)?
    override func swipe(with event: NSEvent) { onSwipe?(event.deltaX) }
    override var acceptsFirstResponder: Bool { false }
}

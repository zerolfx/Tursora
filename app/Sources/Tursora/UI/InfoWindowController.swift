import AppKit
import Quartz
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by a browsing pane when its selection or location changes, so
    /// the Inspector can follow it. object: the BrowserViewController.
    static let tursoraSelectionChanged = Notification.Name("tursora.selectionChanged")
}

/// Finder's Get Info window (⌘I), the floating Inspector that follows the
/// selection (⌥⌘I) and the Summary window for several items (⌃⌘I). Sections,
/// labels and wording come from Finder's own InfoWindow*.nib; Tags, ACLs and
/// owner changes are out of scope.
final class InfoWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
                                  NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {

    enum Mode { case item, summary, inspector }

    let mode: Mode
    private(set) var urls: [URL]
    private var url: URL { urls[0] }
    /// Several items shown as one window: always for .summary, and for the
    /// Inspector while more than one item is selected.
    var isSummary: Bool { mode == .summary || urls.count > 1 }

    static let width: CGFloat = 300
    private static let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    // MARK: - Registry

    private(set) static var openWindows: [InfoWindowController] = []
    private static weak var inspector: InfoWindowController?
    static var inspectorWindow: InfoWindowController? { inspector }

    /// ⌘I — one window per item; an item that already has one just comes to
    /// the front. Past ten items Finder shows one summary window instead.
    static func show(for urls: [URL], relativeTo parent: NSWindow?) {
        guard !urls.isEmpty else { return }
        if urls.count > 10 { showSummary(for: urls, relativeTo: parent); return }
        for url in urls {
            if let existing = openWindows.first(where: { $0.mode == .item && $0.url.standardizedFileURL == url.standardizedFileURL }) {
                existing.window?.makeKeyAndOrderFront(nil)
                continue
            }
            InfoWindowController(mode: .item, urls: [url]).present(relativeTo: parent)
        }
    }

    /// ⌃⌘I — one window for all of them.
    static func showSummary(for urls: [URL], relativeTo parent: NSWindow?) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 { show(for: urls, relativeTo: parent); return }
        if let existing = openWindows.first(where: { $0.mode == .summary && $0.urls.map(\.standardizedFileURL) == urls.map(\.standardizedFileURL) }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        InfoWindowController(mode: .summary, urls: urls).present(relativeTo: parent)
    }

    /// ⌥⌘I — a single floating panel that tracks the main window's selection.
    static func showInspector(relativeTo parent: NSWindow?) {
        if let inspector {
            inspector.syncWithMainWindow()
            inspector.window?.orderFront(nil)
            return
        }
        let wc = InfoWindowController(mode: .inspector, urls: [URL(fileURLWithPath: NSHomeDirectory())])
        inspector = wc
        wc.syncWithMainWindow()
        wc.present(relativeTo: parent)
    }

    static func closeAll() {
        for wc in openWindows { wc.close() }
    }

    private func present(relativeTo parent: NSWindow?) {
        Self.openWindows.append(self)
        if let w = window {
            if let last = Self.openWindows.dropLast().last?.window, last.isVisible {
                w.setFrameTopLeftPoint(last.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
            } else if let parent {
                w.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 60, y: parent.frame.maxY - 60))
            } else {
                w.center()
            }
        }
        showWindow(nil)
        if mode == .inspector { window?.orderFront(nil) } else { window?.makeKeyAndOrderFront(nil) }
        window?.makeFirstResponder(nil)          // Finder opens with nothing focused, not the name field
    }

    // MARK: - Setup

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let disclosureDefaults: UserDefaults
    private var sections: [InfoSection] = []
    private var valueFields: [String: NSTextField] = [:]
    private let headerIcon = NSImageView()
    private let headerName = NSTextField(wrappingLabelWithString: "")
    private let headerSize = NSTextField(labelWithString: "")
    private let headerModified = NSTextField(labelWithString: "")
    private var lockedBox: NSButton?
    private var hiddenExtensionBox: NSButton?
    private var nameField: NSTextField?
    /// The item the name field was built for — editing commits to it even if
    /// the Inspector has since moved on to another selection.
    private var nameFieldURL: URL?
    private var commentsView: NSTextView?
    private var commentsURL: URL?
    /// Each section acts on the item it was built for, never on whatever
    /// `urls[0]` is by the time a sheet or a deferred click lands.
    private var generalURL: URL?
    private var openWithURL: URL?
    private var permissionsURL: URL?
    private var wrappingLabels: [NSTextField] = []
    /// A rebuild asked for while a field is being edited waits for the edit to end.
    private var rebuildDeferred = false
    /// Inodes of the items, to follow renames made outside the app.
    private var fileIDs: [URL: UInt64] = [:]
    private var openWithPopup: NSPopUpButton?
    private var previewView: QLPreviewView?
    private var permissions: FileInfo.Permissions?
    private var permissionsTable: NSTableView?
    private var accessSummaryLabel: NSTextField?
    private var sizeCalc: FileInfo.SizeCalculation?
    private var lastSize: FileInfo.Size?
    private var watcher: DirectoryWatcher?
    private var rebuildWork: DispatchWorkItem?

    init(mode: Mode, urls: [URL], disclosureDefaults: UserDefaults = .standard) {
        self.mode = mode
        self.urls = urls
        self.disclosureDefaults = disclosureDefaults
        let rect = NSRect(x: 0, y: 0, width: Self.width, height: 520)
        let window: NSWindow
        if mode == .inspector {
            let panel = InfoPanel(contentRect: rect, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = true
            window = panel
        } else {
            window = InfoWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
        }
        window.minSize = NSSize(width: Self.width, height: 160)
        window.maxSize = NSSize(width: 520, height: 4000)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildChrome()
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(directoriesChanged(_:)),
                                               name: .tursoraDirectoriesChanged, object: nil)
        if mode == .inspector {
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
                                                   name: .tursoraSelectionChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(mainWindowChanged(_:)),
                                                   name: NSWindow.didBecomeMainNotification, object: nil)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildChrome() {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scrollView.documentView = doc
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            doc.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        window?.contentView = scrollView
    }

    // MARK: - Building the sections

    private var displayName: String { url.lastPathComponent }
    private var isFolder: Bool { FileItem(url: url)?.isNavigable ?? false }

    /// Tears everything down and builds it again for the current urls.
    /// True while the name field or the comments are being typed in.
    var isEditing: Bool {
        if nameField?.currentEditor() != nil { return true }
        if let commentsView, window?.firstResponder === commentsView { return true }
        return false
    }

    private func rebuild() {
        // Never tear the fields down under the user's cursor: a half-typed
        // name must not be committed, nor the edit lost. Resumes on end-editing.
        if isEditing { rebuildDeferred = true; return }
        rebuildDeferred = false
        sizeCalc?.cancel()
        lastSize = nil
        previewView?.close()
        previewView = nil
        saveComment()
        sections = []
        valueFields = [:]
        wrappingLabels = []
        lockedBox = nil; hiddenExtensionBox = nil; nameField = nil; nameFieldURL = nil; commentsView = nil; commentsURL = nil
        openWithPopup = nil; permissionsTable = nil; accessSummaryLabel = nil
        generalURL = nil; openWithURL = nil; permissionsURL = nil
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }

        window?.title = isSummary ? "Multiple Item Info" : "\(displayName) Info"
        stack.addArrangedSubview(headerView())
        stack.addArrangedSubview(separator())
        addSection("general", "General:", generalContent())
        if !isSummary {
            let more = FileInfo.moreInfo(for: url)
            if !more.isEmpty { addSection("moreInfo", "More Info:", grid(more.map { ($0.0, value($0.1, key: $0.0)) })) }
            addSection("name", "Name & Extension:", nameContent())
            addSection("comments", "Comments:", commentsContent())
            if !isFolder { addSection("openWith", "Open with:", openWithContent()) }
            addSection("preview", "Preview:", previewContent())
            addSection("sharing", "Sharing & Permissions:", sharingContent())
        }
        // NSStackView alignment is not a fill mode. Give every row an explicit
        // width so intrinsic sizes cannot squeeze sections against the right edge.
        for row in stack.arrangedSubviews {
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }
        fileIDs = Dictionary(uniqueKeysWithValues: urls.compactMap { u in FileInfo.fileID(of: u).map { (u, $0) } })
        startSizeCalculation()
        watchParents()
        updateWrappingWidths()
        fitWindow(animate: false)
    }

    private func resumeDeferredRebuild() {
        guard rebuildDeferred else { return }
        rebuildDeferred = false
        scheduleRebuild()
    }

    /// Ends any editing so its result is committed to the item it belongs to
    /// (Finder commits a typed name when the selection moves on).
    private func endEditing() {
        if isEditing { window?.makeFirstResponder(nil) }
    }

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func addSection(_ key: String, _ title: String, _ content: NSView) {
        let s = InfoSection(key: key, title: title, content: content, defaults: disclosureDefaults)
        s.onToggle = { [weak self] in self?.fitWindow(animate: true) }
        sections.append(s)
        stack.addArrangedSubview(s)
        stack.addArrangedSubview(separator())
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Self.small
        l.textColor = .secondaryLabelColor
        l.alignment = .right
        return l
    }

    private func value(_ text: String, key: String? = nil) -> NSTextField {
        let v = NSTextField(wrappingLabelWithString: text)
        v.font = Self.small
        v.isSelectable = true
        v.preferredMaxLayoutWidth = Self.width - 32 - 84 - 8
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let key { valueFields[key] = v }
        wrappingLabels.append(v)
        return v
    }

    /// Wrapping labels follow the window width.
    private func updateWrappingWidths() {
        let width = max(100, (window?.contentView?.frame.width ?? Self.width) - 32 - 84 - 8)
        for l in wrappingLabels where l.preferredMaxLayoutWidth != width { l.preferredMaxLayoutWidth = width }
    }

    func windowDidResize(_ notification: Notification) { updateWrappingWidths() }

    /// Finder's label/value rows: labels right-aligned in a fixed column.
    private func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let g = NSGridView(numberOfColumns: 2, rows: 0)
        g.rowSpacing = 4
        g.columnSpacing = 8
        g.rowAlignment = .firstBaseline
        g.column(at: 0).xPlacement = .trailing
        g.column(at: 0).width = 84
        g.column(at: 1).xPlacement = .fill
        for (title, view) in rows { g.addRow(with: [label(title + ":"), view]) }
        return g
    }

    private func vertical(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    // Header: icon, name, size, "Modified:" — Finder's InfoWindowSimpleHeaderView.

    private func headerView() -> NSView {
        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        headerIcon.image = isSummary ? NSImage(named: NSImage.multipleDocumentsName) : Self.icon(for: url, size: 64)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerName.stringValue = isSummary ? "\(urls.count) items" : displayName
        headerName.font = .systemFont(ofSize: 13, weight: .bold)
        headerName.maximumNumberOfLines = 2
        headerName.lineBreakMode = .byTruncatingMiddle
        headerName.isSelectable = true
        headerName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerName.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSize.font = .systemFont(ofSize: 13, weight: .semibold)
        headerSize.stringValue = "--"
        headerSize.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerModified.font = Self.small
        headerModified.textColor = .secondaryLabelColor
        headerModified.stringValue = "Modified: \(FileInfo.dateString(FileItem(url: url)?.modificationDate))"
        headerModified.isHidden = isSummary

        let row = NSStackView(views: [headerName, headerSize])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        let text = vertical([row, headerModified], spacing: 2)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true

        let container = NSView()
        container.addSubview(headerIcon)
        text.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(text)
        NSLayoutConstraint.activate([
            headerIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            headerIcon.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerIcon.widthAnchor.constraint(equalToConstant: 64),
            headerIcon.heightAnchor.constraint(equalToConstant: 64),
            headerIcon.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10),
            text.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            text.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
            text.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    static func icon(for url: URL, size: CGFloat) -> NSImage {
        let img = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: size, height: size)
        return img
    }

    // General: Kind / Size / Where / Created / Modified (+ Original, Version…) and Locked.

    private func generalContent() -> NSView {
        var rows: [(String, NSView)] = []
        if isSummary {
            rows.append(("Kind", value(FileInfo.summaryKind(for: urls), key: "Kind")))
            rows.append(("Size", value("Calculating size…", key: "Size")))
            let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
            if parents.count == 1 { rows.append(("Where", value(FileInfo.whereString(for: url), key: "Where"))) }
            return grid(rows)
        }
        generalURL = url
        let item = FileItem(url: url)
        rows.append(("Kind", value(FileInfo.kind(of: url), key: "Kind")))
        let volume = FileInfo.volumeInfo(for: url)
        if volume.isEmpty {
            rows.append(("Size", value("Calculating size…", key: "Size")))
        } else {
            for (k, v) in volume { rows.append((k, value(v, key: k))) }
        }
        rows.append(("Where", value(FileInfo.whereString(for: url), key: "Where")))
        rows.append(("Created", value(FileInfo.dateString(item?.creationDate), key: "Created")))
        rows.append(("Modified", value(FileInfo.dateString(item?.modificationDate), key: "Modified")))
        if let original = FileInfo.original(of: url) { rows.append(("Original", value(original, key: "Original"))) }
        for (k, v) in FileInfo.bundleInfo(for: url) { rows.append((k, value(v, key: k))) }
        let g = grid(rows)
        let locked = NSButton(checkboxWithTitle: "Locked", target: self, action: #selector(toggleLocked(_:)))
        locked.font = Self.small
        locked.state = FileInfo.isLocked(url) ? .on : .off
        lockedBox = locked
        g.addRow(with: [NSGridCell.emptyContentView, locked])
        return g
    }

    @objc private func toggleLocked(_ sender: NSButton) {
        guard let target = generalURL else { return }
        let on = sender.state == .on
        do {
            try FileInfo.setLocked(on, target)
            DirectoryChanges.post([target.deletingLastPathComponent()])
        } catch {
            sender.state = on ? .off : .on
            report(error)
        }
    }

    /// The checkbox's code path, for the smoke test.
    func setLocked(_ on: Bool) {
        guard let lockedBox else { return }
        lockedBox.state = on ? .on : .off
        toggleLocked(lockedBox)
    }

    // Name & Extension: an editable name and "Hide extension".

    private func nameContent() -> NSView {
        let field = NSTextField(string: displayName)
        field.font = Self.small
        field.delegate = self
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        nameField = field
        nameFieldURL = url
        let hide = NSButton(checkboxWithTitle: "Hide extension", target: self, action: #selector(toggleHiddenExtension(_:)))
        hide.font = Self.small
        hide.state = FileInfo.hasHiddenExtension(url) ? .on : .off
        hide.isEnabled = !url.pathExtension.isEmpty
        hiddenExtensionBox = hide
        let s = vertical([field, hide])
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === nameField else { return }
        commitRename(field.stringValue)
        resumeDeferredRebuild()
    }

    /// The name field's commit: renames the item the field was built for.
    func commitRename(_ newName: String) {
        guard let target = nameFieldURL else { return }
        let oldName = target.lastPathComponent
        guard !newName.isEmpty, newName != oldName, !newName.contains("/") else {
            nameField?.stringValue = oldName
            return
        }
        if !rename(target, to: newName) { nameField?.stringValue = oldName }
    }

    /// Renames `target`, follows it if it is one of ours, and registers the
    /// reverse rename with the Info window's undo manager.
    @discardableResult
    private func rename(_ target: URL, to newName: String) -> Bool {
        let oldName = target.lastPathComponent
        do {
            let newURL = try FileOperations.rename(target, to: newName)
            follow(target, to: newURL)
            if SmokeTest.isRequested { print("   [info] renamed \(oldName) → \(newURL.lastPathComponent)") }
            if let undo = window?.undoManager {
                undo.registerUndo(withTarget: self) { me in me.rename(newURL, to: oldName) }
                undo.setActionName("Rename")
            }
            DirectoryChanges.post([target.deletingLastPathComponent()], renamed: (from: target, to: newURL))
            scheduleRebuild()
            return true
        } catch {
            report(error)
            return false
        }
    }

    @objc private func toggleHiddenExtension(_ sender: NSButton) {
        guard let target = nameFieldURL else { return }
        let on = sender.state == .on
        do {
            try FileInfo.setHiddenExtension(on, target)
            DirectoryChanges.post([target.deletingLastPathComponent()])
        } catch {
            sender.state = on ? .off : .on
            report(error)
        }
    }

    func setHiddenExtension(_ on: Bool) {
        guard let hiddenExtensionBox else { return }
        hiddenExtensionBox.state = on ? .on : .off
        toggleHiddenExtension(hiddenExtensionBox)
    }

    // Comments: Finder's xattr, saved when editing ends or the window closes.

    private func commentsContent() -> NSView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: Self.width - 32, height: 60))
        tv.font = Self.small
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.minSize = NSSize(width: 0, height: 60)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.string = FileInfo.comment(for: url)
        tv.delegate = self
        scroll.documentView = tv
        commentsView = tv
        commentsURL = url
        return scroll
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === commentsView else { return }
        saveComment()
        resumeDeferredRebuild()
    }

    /// Writes the comment to the item the text view was built for, if it changed.
    func saveComment() {
        guard let tv = commentsView, let target = commentsURL else { return }
        let text = tv.string
        guard text != FileInfo.comment(for: target) else { return }
        do { try FileInfo.setComment(text, for: target) } catch { report(error) }
    }

    // Open with: the default app, the others, "Other…", and Change All.

    private func openWithContent() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = Self.small
        popup.target = self
        popup.action = #selector(openWithChanged(_:))
        openWithPopup = popup
        openWithURL = url
        populateOpenWith()
        let hint = value("Use this application to open all documents like this one.")
        hint.textColor = .secondaryLabelColor
        let changeAll = NSButton(title: "Change All…", target: self, action: #selector(changeAll(_:)))
        changeAll.controlSize = .small
        changeAll.font = Self.small
        changeAll.bezelStyle = .rounded
        let s = vertical([popup, hint, changeAll])
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    private func populateOpenWith() {
        guard let popup = openWithPopup, let target = openWithURL else { return }
        popup.removeAllItems()
        let (def, others) = FileInfo.applications(toOpen: target)
        func add(_ app: URL, suffix: String = "") {
            popup.addItem(withTitle: FileManager.default.displayName(atPath: app.path) + suffix)
            let mi = popup.lastItem!
            mi.representedObject = app
            mi.image = Self.icon(for: app, size: 16)
        }
        if let def {
            add(def, suffix: " (default)")
            popup.menu?.addItem(.separator())
        }
        for app in others { add(app) }
        if def == nil, others.isEmpty {
            popup.addItem(withTitle: "No Applications")
            popup.lastItem?.isEnabled = false
        }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: "Other…")
        popup.selectItem(at: 0)
    }

    @objc private func openWithChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, let target = openWithURL else { return }
        if let app = item.representedObject as? URL {
            setDefaultApplication(app, for: target, forAllOfType: false)
        } else if item.title == "Other…" {
            chooseOtherApplication(for: target)
        }
    }

    private func chooseOtherApplication(for target: URL) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an application to open the document “\(target.lastPathComponent)”."
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .OK, let app = panel.url { self.setDefaultApplication(app, for: target, forAllOfType: false) } else { self.populateOpenWith() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    @objc private func changeAll(_ sender: Any?) {
        guard let app = openWithPopup?.selectedItem?.representedObject as? URL, let target = openWithURL else { return }
        let appName = FileManager.default.displayName(atPath: app.path)
        let ext = target.pathExtension
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to change all your similar documents to open with the application “\(appName)”?"
        alert.informativeText = ext.isEmpty ? "This change will apply to all documents of this kind."
                                            : "This change will apply to all documents with extension “.\(ext)”."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.setDefaultApplication(app, for: target, forAllOfType: true)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handler) } else { handler(alert.runModal()) }
    }

    /// Per-file (LaunchServices xattr) or for the whole content type.
    func setDefaultApplication(_ app: URL, for target: URL, forAllOfType all: Bool) {
        let done: (Error?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                if let error { self?.report(error) }
                self?.populateOpenWith()
            }
        }
        if all {
            let type = (try? target.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: target.pathExtension)
            guard let type else { done(nil); return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type, completion: done)
        } else {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenFileAt: target, completion: done)
        }
    }

    // Preview: Quick Look inline.

    private func previewContent() -> NSView {
        let pv: QLPreviewView = QLPreviewView(frame: NSRect(x: 0, y: 0, width: Self.width - 32, height: 200), style: .normal)
        pv.translatesAutoresizingMaskIntoConstraints = false
        pv.heightAnchor.constraint(equalToConstant: 200).isActive = true
        pv.shouldCloseWithWindow = false
        pv.autostarts = false
        pv.previewItem = url as NSURL
        previewView = pv
        return pv
    }

    // Sharing & Permissions: owner / group / everyone with Finder's four privileges.

    private func sharingContent() -> NSView {
        permissionsURL = url
        permissions = FileInfo.permissions(of: url)
        let summary = value(FileInfo.accessSummary(for: url))
        summary.textColor = .secondaryLabelColor
        accessSummaryLabel = summary

        let table = NSTableView()
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Name"
        name.width = 150
        let priv = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("privilege"))
        priv.title = "Privilege"
        priv.width = 108
        table.addTableColumn(name)
        table.addTableColumn(priv)
        table.rowHeight = 20
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.dataSource = self
        table.delegate = self
        permissionsTable = table

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 3 * 20 + 26).isActive = true
        let s = vertical([summary, scroll])
        scroll.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    func numberOfRows(in tableView: NSTableView) -> Int { permissions == nil ? 0 : FileInfo.Who.allCases.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let p = permissions else { return nil }
        let who = FileInfo.Who.allCases[row]
        if tableColumn?.identifier.rawValue == "name" {
            let cell = NSTableCellView.make(identifier: NSUserInterfaceItemIdentifier("permName"), withIcon: true)
            let symbol = who == .owner ? "person.crop.circle" : who == .group ? "person.2.circle" : "globe"
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            cell.textField?.stringValue = FileInfo.displayName(for: who, p)
            cell.textField?.font = Self.small
            return cell
        }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = Self.small
        popup.isBordered = false
        for privilege in FileInfo.Privilege.allCases { popup.addItem(withTitle: privilege.rawValue) }
        popup.selectItem(withTitle: p.privilege(who).rawValue)
        popup.tag = row
        popup.target = self
        popup.action = #selector(privilegeChanged(_:))
        popup.isEnabled = p.isOwnedByMe
        return popup
    }

    @objc private func privilegeChanged(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title, let privilege = FileInfo.Privilege(rawValue: title) else { return }
        setPrivilege(privilege, for: FileInfo.Who.allCases[sender.tag])
    }

    func setPrivilege(_ privilege: FileInfo.Privilege, for who: FileInfo.Who) {
        guard let p = permissions, let target = permissionsURL else { return }
        let newMode = FileInfo.mode(p.mode, setting: privilege, for: who, isFolder: p.isFolder)
        do {
            try FileInfo.setMode(newMode, of: target)
            DirectoryChanges.post([target.deletingLastPathComponent()])
        } catch {
            report(error)
        }
        permissions = FileInfo.permissions(of: target)
        permissionsTable?.reloadData()
        accessSummaryLabel?.stringValue = FileInfo.accessSummary(for: target)
    }

    // MARK: - Size, watching, fitting

    private func startSizeCalculation() {
        sizeCalc?.cancel()
        headerSize.stringValue = "--"
        if !isSummary, !FileInfo.volumeInfo(for: url).isEmpty {
            // A whole volume: the General section already shows Used; no walk.
            headerSize.stringValue = valueFields["Used"]?.stringValue.components(separatedBy: " (").first ?? "--"
            lastSize = FileInfo.Size(finished: true)
            return
        }
        sizeCalc = FileInfo.computeSize(of: urls, countingChildren: !isSummary) { [weak self] size in
            guard let self else { return }
            self.lastSize = size
            self.valueFields["Size"]?.stringValue = FileInfo.sizeString(size)
            self.headerSize.stringValue = FileInfo.headerSizeString(size)
        }
    }

    /// Outside changes (a rename in Finder, a deleted item) reach the window
    /// through FSEvents; in-app ones through DirectoryChanges as well.
    private func watchParents() {
        let parent = url.deletingLastPathComponent()
        if watcher?.directory != parent {
            watcher = DirectoryWatcher(directory: parent) { [weak self] paths in self?.watchedPathsChanged(paths) }
        }
    }

    /// FSEvents streams the whole subtree of the parent; only the items
    /// themselves and their siblings matter here (not, say, every cache write
    /// under ~ while showing ~/Downloads/x).
    private func watchedPathsChanged(_ paths: [String]) {
        let mine = Set(urls.map { $0.resolvingSymlinksInPath().path })
        let parents = Set(urls.map { $0.deletingLastPathComponent().resolvingSymlinksInPath().path })
        let hit = paths.contains { p in
            let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            return mine.contains(real) || parents.contains((real as NSString).deletingLastPathComponent)
        }
        if hit { parentsChanged() }
    }

    @objc private func directoriesChanged(_ note: Notification) {
        guard let dirs = note.userInfo?["directories"] as? [URL] else { return }
        if let from = note.userInfo?["renamedFrom"] as? URL, let to = note.userInfo?["renamedTo"] as? URL { follow(from, to: to) }
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard dirs.contains(where: { parents.contains($0.standardizedFileURL.path) }) else { return }
        parentsChanged()
    }

    /// An item was renamed (here or elsewhere): keep showing it under its new name.
    private func follow(_ from: URL, to: URL) {
        guard let i = urls.firstIndex(of: from) else { return }
        urls[i] = to
        if nameFieldURL == from { nameFieldURL = to }
        if commentsURL == from { commentsURL = to }
        if generalURL == from { generalURL = to }
        if openWithURL == from { openWithURL = to }
        if permissionsURL == from { permissionsURL = to }
        if let id = fileIDs.removeValue(forKey: from) { fileIDs[to] = id }
    }

    private func parentsChanged() {
        // A missing item may just have been renamed outside the app: look for its inode.
        for u in urls where !FileManager.default.fileExists(atPath: u.path) {
            if let id = fileIDs[u], let moved = FileInfo.sibling(of: u, withFileID: id) { follow(u, to: moved) }
        }
        if urls.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            // Finder closes the Info window of an item that is gone; the Inspector moves on.
            if mode == .inspector { syncWithMainWindow(force: true) } else { close() }
            return
        }
        scheduleRebuild()
    }

    private func fitWindow(animate: Bool) {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        let contentHeight = stack.frame.height
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let target = min(max(contentHeight, window.minSize.height), screenHeight - 40)
        var frame = window.frame
        let current = window.contentRect(forFrameRect: frame).height
        let delta = target - current
        guard abs(delta) > 0.5 else { return }
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: animate)
    }

    // MARK: - Inspector: follow the main window's selection

    @objc private func selectionChanged(_ note: Notification) {
        // The main window's active pane; with the app inactive there is no
        // main window, so then any browser window counts.
        guard let browser = note.object as? BrowserViewController, let w = browser.view.window,
              w.isMainWindow || w.isKeyWindow || NSApp.mainWindow == nil,
              let mwc = w.windowController as? MainWindowController, mwc.browser === browser else { return }
        sync(with: browser)
    }

    @objc private func mainWindowChanged(_ note: Notification) {
        guard let w = note.object as? NSWindow, let mwc = w.windowController as? MainWindowController else { return }
        sync(with: mwc.browser)
    }

    func syncWithMainWindow(force: Bool = false) {
        let mwc = (NSApp.mainWindow?.windowController as? MainWindowController)
            ?? NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first
        if SmokeTest.isRequested { print("   [info] syncWithMainWindow main=\(NSApp.mainWindow?.title ?? "nil") mwc=\(mwc != nil)") }
        guard let mwc else { return }
        sync(with: mwc.browser, force: force)
    }

    /// The selection, or the folder itself when nothing is selected — Finder's rule.
    func sync(with browser: BrowserViewController, force: Bool = false) {
        if browser.isBrowsingArchive {
            window?.orderOut(nil)
            return
        }
        let targets = browser.infoTargets
        if SmokeTest.isRequested { print("   [info] sync targets=\(targets.map(\.lastPathComponent)) urls=\(urls.map(\.lastPathComponent)) force=\(force)") }
        guard !targets.isEmpty, force || targets != urls else { return }
        endEditing()                 // commits a typed name / comment to the item it belongs to
        saveComment()
        urls = targets
        scheduleRebuild()
    }

    // MARK: - Window delegate, errors

    func windowWillClose(_ notification: Notification) {
        saveComment()
        sizeCalc?.cancel()
        rebuildWork?.cancel()
        previewView?.close()
        previewView = nil
        watcher = nil
        Self.openWindows.removeAll { $0 === self }
        if Self.inspector === self { Self.inspector = nil }
    }

    private func report(_ error: Error) {
        if SmokeTest.isRequested { print("ERROR info window: \(error)"); return }
        if let window { NSAlert(error: error).beginSheetModal(for: window) } else { NSAlert(error: error).runModal() }
    }

    // MARK: - For the smoke test

    var displayedName: String { headerName.stringValue }
    var displayedHeaderSize: String { headerSize.stringValue }
    func value(for label: String) -> String? { valueFields[label]?.stringValue }
    var nameFieldValue: String? { nameField?.stringValue }
    var openWithTitles: [String] { openWithPopup?.itemTitles ?? [] }
    var permissionRowCount: Int { permissionsTable?.numberOfRows ?? 0 }
    var sectionKeys: [String] { sections.map(\.key) }
    /// Put the cursor in the name field, as a click would.
    func beginEditingName() { if let nameField { window?.makeFirstResponder(nameField) } }
    func typeName(_ text: String) { nameField?.stringValue = text }
    func typeComment(_ text: String) { commentsView?.string = text }
    var isSizeFinished: Bool { lastSize?.finished ?? false }
    func section(_ key: String) -> InfoSection? { sections.first { $0.key == key } }
}

/// One collapsible "Title:" block. Explicit choices are shared across Info,
/// Summary and Inspector; constructing a section does not create a preference.
final class InfoSection: NSStackView {
    let key: String
    let content: NSView
    private let chevron = NSImageView()
    private let defaults: UserDefaults
    var onToggle: (() -> Void)?

    static func explicitPreferenceKey(for key: String) -> String {
        "InfoSection.ExplicitExpanded.v2.\(key)"
    }

    /// The observed Finder baseline on the owner's Mac, not a claim about
    /// factory defaults. Evidence and the legacy migration are recorded in
    /// docs/research/info-disclosures.md.
    static func defaultExpanded(for key: String) -> Bool {
        key == "general" || key == "preview"
    }

    static func initialExpansion(for key: String, defaults: UserDefaults = .standard) -> Bool {
        if let explicit = defaults.object(forKey: explicitPreferenceKey(for: key)) as? Bool { return explicit }
        // Older versions wrote true merely by constructing every section. A
        // stored false reflects a collapse, while true is ambiguous and adopts
        // the new baseline until the user makes a new explicit choice.
        if defaults.object(forKey: "InfoSection.\(key)") as? Bool == false { return false }
        return defaultExpanded(for: key)
    }

    var isExpanded: Bool = true {
        didSet {
            applyExpansion()
            defaults.set(isExpanded, forKey: Self.explicitPreferenceKey(for: key))
        }
    }

    /// Also called from init: property observers do not run there.
    private func applyExpansion() {
        content.isHidden = !isExpanded
        chevron.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    }

    var hasChevron: Bool { chevron.image != nil }

    init(key: String, title: String, content: NSView, defaults: UserDefaults = .standard) {
        self.key = key
        self.content = content
        self.defaults = defaults
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        detachesHiddenViews = true
        edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 10, right: 16)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        let header = NSStackView(views: [titleLabel, chevron])
        header.orientation = .horizontal
        header.distribution = .fill
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggle)))
        addArrangedSubview(header)
        addArrangedSubview(content)
        for row in [header, content] {
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInsets.left),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInsets.right),
            ])
        }
        isExpanded = Self.initialExpansion(for: key, defaults: defaults)
        applyExpansion()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func toggle() {
        isExpanded.toggle()
        onToggle?()
    }
}

/// Info windows take key (for the name field) but never main, so the
/// Inspector and "Go" commands keep following the browser window.
private final class InfoWindow: NSWindow {
    override var canBecomeMain: Bool { false }
}

private final class InfoPanel: NSPanel {
    override var canBecomeMain: Bool { false }
}

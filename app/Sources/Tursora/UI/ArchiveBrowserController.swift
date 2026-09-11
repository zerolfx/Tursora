import AppKit

/// The experiment is routed here by the normal browser only after its preference
/// is enabled. No archive work happens merely by constructing a normal window.
final class ArchiveBrowserController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private(set) static var openWindows: [ArchiveBrowserController] = []
    private static var retainedSessions: [ArchiveBrowsingSession] = []
    private static var isShuttingDown = false

    let archiveURL: URL
    private(set) var session: ArchiveBrowsingSession?
    private(set) var currentDirectory: URL?
    private(set) var entries: [ArchiveBrowsingSession.Entry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var onStateChanged: (() -> Void)?

    let tableView = ArchiveContentsTable()
    let pathControl = NSPathControl()
    let statusLabel = NSTextField(labelWithString: "Preparing ZIP…")
    let noteLabel = NSTextField(wrappingLabelWithString: "Read-only ZIP. Opened files are temporary copies kept until Tursora quits. Edits in other apps do not update the ZIP; use Save As to keep them.")
    private let backButton = NSButton()
    private let upButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let fileOpener: (URL) -> Bool
    private var history: [URL] = []
    private var pathURLs: [URL] = []
    private var loadGeneration = 0
    private var hasClosed = false

    static func open(archive: URL, relativeTo parent: NSWindow?) {
        guard !isShuttingDown else { return }
        let identity = archive.resolvingSymlinksInPath().standardizedFileURL
        if let existing = openWindows.first(where: { $0.archiveURL == identity }) {
            if !SmokeTest.isRequested { existing.window?.makeKeyAndOrderFront(nil) }
            return
        }
        let controller = ArchiveBrowserController(archive: identity)
        openWindows.append(controller)
        if let parent {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 36, y: parent.frame.maxY - 36))
        } else { controller.window?.center() }
        if !SmokeTest.isRequested {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        controller.prepare()
    }

    /// Closing a browsing window must not remove files still open in an editor.
    /// App termination is the documented end of these temporary-copy sessions.
    static func shutdownAll() {
        isShuttingDown = true
        ArchiveBrowsingSession.shutdownPreparingSessions()
        for controller in openWindows { controller.close() }
        openWindows.removeAll()
        for session in retainedSessions { session.close() }
        retainedSessions.removeAll()
    }

    init(archive: URL, fileOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        archiveURL = archive.resolvingSymlinksInPath().standardizedFileURL
        self.fileOpener = fileOpener
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = archiveURL.lastPathComponent
        window.subtitle = "ZIP · Read-only"
        window.representedURL = archiveURL
        window.minSize = NSSize(width: 500, height: 300)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare() {
        guard session == nil, !isLoading, !hasClosed else { return }
        isLoading = true
        updateChrome()
        ArchiveBrowsingSession.prepare(archive: archiveURL) { [weak self] result in
            guard let self, !self.hasClosed, !Self.isShuttingDown else {
                if case .success(let session) = result { session.close() }
                return
            }
            self.isLoading = false
            switch result {
            case .success(let session): self.install(session)
            case .failure(let error): self.display(error)
            }
        }
    }

    /// Also allows the smoke test to supply an already prepared session.
    func install(_ session: ArchiveBrowsingSession) {
        guard !hasClosed, session.archiveURL == archiveURL else { return }
        self.session = session
        Self.retainedSessions.append(session)
        navigate(to: session.rootURL, recordHistory: false)
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
        guard let session, !hasClosed else { return }
        do {
            let next = try session.validatedURL(url)
            loadGeneration += 1
            let generation = loadGeneration
            isLoading = true
            errorMessage = nil
            updateChrome()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try session.entries(in: next) }
                DispatchQueue.main.async {
                    guard let self, !self.hasClosed, self.loadGeneration == generation else { return }
                    self.isLoading = false
                    switch result {
                    case .success(let entries):
                        if recordHistory, let current = self.currentDirectory, current != next { self.history.append(current) }
                        self.currentDirectory = next
                        self.entries = entries
                        self.tableView.reloadData()
                        self.tableView.deselectAll(nil)
                        self.updateChrome()
                    case .failure(let error): self.display(error)
                    }
                }
            }
        } catch { display(error) }
    }

    @objc func goBack(_ sender: Any?) {
        guard !isLoading, let previous = history.popLast() else { return }
        navigate(to: previous, recordHistory: false)
    }

    @objc func goUp(_ sender: Any?) {
        guard !isLoading, let currentDirectory, let session, currentDirectory != session.rootURL else { return }
        navigate(to: currentDirectory.deletingLastPathComponent())
    }

    @objc func openSelection(_ sender: Any?) {
        guard !isLoading, entries.indices.contains(tableView.selectedRow), let session else { return }
        let entry = entries[tableView.selectedRow]
        do {
            guard entry.canAccess else { throw ArchiveBrowsingSession.SessionError.unavailableItem }
            let url = try session.validatedURL(entry.url)
            if entry.isNavigable { navigate(to: url); return }
            // Only a deliberate double-click or Return reaches the external opener.
            if !fileOpener(url) { throw NSError(domain: "TursoraZIP", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No application could open this file."]) }
            errorMessage = nil
            statusLabel.stringValue = "Opened a temporary copy of “\(entry.name)”."
            onStateChanged?()
        } catch { display(error) }
    }

    @objc func doubleClicked(_ sender: Any?) {
        // NSTableView also sends doubleAction for the empty area below its rows.
        // A previous selection must not turn that blank-area click into a launch.
        guard entries.indices.contains(tableView.clickedRow) else { return }
        openSelection(sender)
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        if let item = sender.clickedPathItem, let index = sender.pathItems.firstIndex(where: { $0 === item }) {
            navigateToPathComponent(index)
        }
    }

    func navigateToPathComponent(_ index: Int) {
        guard pathURLs.indices.contains(index) else { return }
        navigate(to: pathURLs[index])
    }

    func windowWillClose(_ notification: Notification) {
        hasClosed = true
        loadGeneration += 1
        Self.openWindows.removeAll { $0 === self }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return !isLoading && !history.isEmpty
        case #selector(goUp(_:)): return !isLoading && currentDirectory != nil && currentDirectory != session?.rootURL
        case #selector(openSelection(_:)): return !isLoading && entries.indices.contains(tableView.selectedRow)
        default: return true
        }
    }

    private func buildChrome() {
        guard let root = window?.contentView else { return }
        let header = NSView(), scroll = NSScrollView(), footer = NSView()
        for view in [header, scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor), header.heightAnchor.constraint(equalToConstant: 42),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 78)
        ])
        for (button, symbol, help, action) in [(backButton, "chevron.left", "Back", #selector(goBack(_:))),
                                               (upButton, "arrow.up", "Enclosing Folder", #selector(goUp(_:)))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            button.bezelStyle = .texturedRounded
            button.toolTip = help
            button.target = self; button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(button)
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 28), button.centerYAnchor.constraint(equalTo: header.centerYAnchor)])
        }
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.target = self; pathControl.action = #selector(pathClicked(_:))
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        header.addSubview(pathControl)
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            upButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            pathControl.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 10),
            pathControl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            pathControl.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Name"; name.width = 570; name.minWidth = 160
        let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        size.title = "Size"; size.width = 105; size.minWidth = 80; size.maxWidth = 150
        tableView.addTableColumn(name); tableView.addTableColumn(size)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.delegate = self; tableView.dataSource = self
        tableView.rowHeight = 28
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.target = self; tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.openItem = { [weak self] in self?.openSelection(nil) }
        tableView.up = { [weak self] in self?.goUp(nil) }
        tableView.back = { [weak self] in self?.goBack(nil) }
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        statusLabel.font = .systemFont(ofSize: 12)
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        for label in [statusLabel, noteLabel] { label.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(label) }
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
            noteLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor), noteLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            noteLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 5), noteLabel.bottomAnchor.constraint(lessThanOrEqualTo: footer.bottomAnchor, constant: -8)
        ])
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)])
        updateChrome()
    }

    private func updateChrome() {
        backButton.isEnabled = !isLoading && !history.isEmpty
        upButton.isEnabled = !isLoading && currentDirectory != nil && currentDirectory != session?.rootURL
        if isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !isLoading
        tableView.isEnabled = !isLoading
        if let errorMessage { statusLabel.stringValue = errorMessage }
        else if isLoading { statusLabel.stringValue = session == nil ? "Preparing ZIP…" : "Loading folder…" }
        else { statusLabel.stringValue = "\(entries.count) \(entries.count == 1 ? "item" : "items")" }
        statusLabel.textColor = errorMessage == nil ? .secondaryLabelColor : .systemRed
        if let currentDirectory, let session {
            var urls = [session.rootURL]
            let parts = currentDirectory.pathComponents.dropFirst(session.rootURL.pathComponents.count)
            for part in parts { urls.append(urls.last!.appendingPathComponent(part)) }
            pathURLs = urls
            pathControl.pathItems = urls.enumerated().map { index, url in
                let item = NSPathControlItem()
                item.title = index == 0 ? archiveURL.lastPathComponent : url.lastPathComponent
                item.image = NSImage(systemSymbolName: index == 0 ? "doc.zipper" : "folder", accessibilityDescription: nil)
                return item
            }
        }
        onStateChanged?()
    }

    private func display(_ error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
        updateChrome()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label); cell.textField = label
        if tableColumn?.identifier.rawValue == "size" {
            label.stringValue = entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            label.alignment = .right
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4)])
        } else {
            label.stringValue = entry.name
            label.textColor = entry.canAccess ? .labelColor : .secondaryLabelColor
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: entry.isSymbolicLink ? "link" : (entry.isDirectory ? "folder.fill" : "doc"), accessibilityDescription: nil)
            icon.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7)
            ])
        }
        NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}

final class ArchiveContentsTable: NSTableView {
    var openItem: (() -> Void)?
    var up: (() -> Void)?
    var back: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openItem?(); return }
        if event.modifierFlags.contains(.command), event.keyCode == 126 { up?(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "[" { back?(); return }
        super.keyDown(with: event)
    }
}

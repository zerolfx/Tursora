import AppKit

/// Dolphin-style URL navigator. Breadcrumb mode shows one button per path
/// segment with a `›` after each that lists that folder's subfolders (so you
/// can jump sideways without going up). Edit mode is a text field with
/// inline completion plus a candidate list. Overflowing leading segments
/// collapse into a `…` menu; the first segment is always kept.
final class BreadcrumbBar: NSView, NSTextFieldDelegate {

    var url: URL? { didSet { if !isEditing { rebuild() } } }
    var homeURL = FileManager.default.homeDirectoryForCurrentUser
    var onNavigate: ((URL) -> Void)?
    var onInvalidPath: ((String) -> Void)?
    /// Activate this navigator's pane before its field takes keyboard focus.
    var onBeginEditing: (() -> Void)?
    /// Called when editing ends for any reason, so focus can go back to the list.
    var onEndEditing: (() -> Void)?
    /// Files dropped on a breadcrumb segment: (urls, that segment's folder,
    /// the operation `FileOperations.dropOperation` decided on).
    var onDropFiles: (([URL], URL, NSDragOperation) -> Void)?

    private(set) var isEditing = false
    private var isBeginningEditing = false
    let textField = NSTextField()
    let completion = CompletionPopup()
    private var segments: [Segment] = []
    private var segmentButtons: [NSButton] = []
    private var chevronButtons: [NSButton] = []
    private var overflowButton: NSButton?
    private var shortcutObserver: NSObjectProtocol?
    private let dropHighlight = NSView()
    private var hoverSegmentIndex: Int? { didSet { if hoverSegmentIndex != oldValue { updateDropHighlight() } } }

    struct Segment {
        let url: URL
        let title: String
        let icon: NSImage?
    }

    static let height: CGFloat = 30
    private let pad: CGFloat = 6

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        textField.delegate = self
        textField.isHidden = true
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        refreshShortcutHint()
        shortcutObserver = NotificationCenter.default.addObserver(forName: .tursoraShortcutsChanged,
            object: AppPreferences.shared.shortcuts, queue: .main) { [weak self] _ in self?.refreshShortcutHint() }
        textField.cell?.sendsActionOnEndEditing = false
        addSubview(textField)
        let overflow = NSButton(title: "…", target: self, action: #selector(overflowClicked(_:)))
        overflow.bezelStyle = .accessoryBarAction
        overflow.showsBorderOnlyWhileMouseInside = true
        overflow.toolTip = "Hidden segments"
        overflow.isHidden = true
        addSubview(overflow)
        overflowButton = overflow
        completion.onChoose = { [weak self] name in
            self?.accept(candidate: name)
            self?.window?.makeFirstResponder(self?.textField)
        }
        dropHighlight.wantsLayer = true
        dropHighlight.layer?.cornerRadius = 5
        dropHighlight.isHidden = true
        addSubview(dropHighlight, positioned: .below, relativeTo: nil)
        registerForDraggedTypes([.fileURL, ArchiveEntryPromiseProvider.internalType])
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let shortcutObserver { NotificationCenter.default.removeObserver(shortcutObserver) } }

    private func refreshShortcutHint() {
        let key = AppPreferences.shared.shortcuts.shortcut(for: "menu.editLocation")?.displayString
        textField.placeholderString = "Type a folder path" + (key.map { " — " + $0 } ?? "")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    // MARK: - Segments

    var segmentCount: Int { segments.count }
    var segmentTitles: [String] { segments.map(\.title) }
    /// For tests: the visible segment buttons, left to right.
    var visibleSegmentFrames: [NSRect] { segmentButtons.filter { !$0.isHidden }.map(\.frame) }
    var visibleNavigationFrames: [NSRect] {
        (segmentButtons + chevronButtons + [overflowButton].compactMap { $0 })
            .filter { !$0.isHidden }.map(\.frame)
    }
    var hasOverflowMenu: Bool { overflowButton?.isHidden == false }

    private func rebuild() {
        segmentButtons.forEach { $0.removeFromSuperview() }
        chevronButtons.forEach { $0.removeFromSuperview() }
        segmentButtons = []; chevronButtons = []
        segments = Self.segments(for: url, home: homeURL)

        for (i, seg) in segments.enumerated() {
            let b = NSButton(title: seg.title, target: self, action: #selector(segmentClicked(_:)))
            b.bezelStyle = .accessoryBarAction
            b.showsBorderOnlyWhileMouseInside = true
            b.tag = i
            b.lineBreakMode = .byTruncatingMiddle
            b.font = i == segments.count - 1
                ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                : .systemFont(ofSize: NSFont.systemFontSize)
            if let icon = seg.icon {
                b.image = icon
                b.imagePosition = .imageLeading
            }
            b.toolTip = seg.url.path
            addSubview(b)
            segmentButtons.append(b)

            let c = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Subfolders")!,
                             target: self, action: #selector(chevronClicked(_:)))
            c.bezelStyle = .accessoryBarAction
            c.showsBorderOnlyWhileMouseInside = true
            c.tag = i
            c.toolTip = "Subfolders of \(seg.title)"
            addSubview(c)
            chevronButtons.append(c)
        }
        needsLayout = true
    }

    static func segments(for url: URL?, home: URL) -> [Segment] {
        guard let sourceURL = url else { return [] }
        let url = ArchiveWorkspace.shared.logicalURL(for: sourceURL)
        let archive = ArchiveWorkspace.shared.archiveURL(containing: url)?.standardizedFileURL
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        var out: [Segment] = []
        var components: [String]
        var base: URL
        if path == homePath || path.hasPrefix(homePath + "/") {
            base = home
            let icon = NSImage(systemSymbolName: "house", accessibilityDescription: "Home")
            out.append(Segment(url: home, title: home.lastPathComponent, icon: icon))
            components = String(path.dropFirst(homePath.count)).split(separator: "/").map(String.init)
        } else {
            base = URL(fileURLWithPath: "/")
            let volume = (try? base.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "/"
            let icon = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: volume)
            out.append(Segment(url: base, title: volume, icon: icon))
            components = path.split(separator: "/").map(String.init)
        }
        for c in components {
            base = base.appendingPathComponent(c)
            let isArchive = base.standardizedFileURL == archive
            let insideArchive = archive.map { base.pathComponents.starts(with: $0.pathComponents) } ?? false
            let title = insideArchive ? c : FileManager.default.displayName(atPath: base.path)
            let icon = isArchive ? NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "ZIP archive") : nil
            out.append(Segment(url: base, title: title, icon: icon))
        }
        return out
    }

    private static func navigationIcon(for url: URL) -> NSImage? {
        let workspace = ArchiveWorkspace.shared
        let logical = workspace.logicalURL(for: url)
        let image: NSImage?
        if workspace.archiveURL(containing: logical)?.standardizedFileURL == logical.standardizedFileURL {
            image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "ZIP archive")
        } else if workspace.session(for: logical) != nil {
            image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
        } else {
            image = NSWorkspace.shared.icon(forFile: logical.path)
        }
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: - Layout (manual, so overflow folding is deterministic)

    override func layout() {
        super.layout()
        let h = bounds.height
        let y = (h - 22) / 2

        if isEditing {
            textField.frame = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 22)
            if completion.isVisible { completion.hide() }     // field moved; the list would be stale
            return
        }

        let available = bounds.width - pad * 2
        var widths = segmentButtons.map { min($0.fittingSize.width, 220) }
        let chevronW: CGFloat = 20
        let overflowW: CGFloat = 30
        func total(from start: Int, withOverflow: Bool) -> CGFloat {
            var t = widths[start...].reduce(0, +) + CGFloat(segments.count - start) * chevronW
            if start > 0 { t += widths[0] + overflowW }        // root stays, plus the "…"
            return t
        }
        // 1. Fold leading segments (never the first) into "…" until it fits.
        var firstVisible = 0
        var hidden: [Int] = []
        while segments.count > 2, firstVisible < segments.count - 1, total(from: firstVisible, withOverflow: !hidden.isEmpty) > available {
            if firstVisible == 0 { firstVisible = 1 }
            hidden.append(firstVisible)
            firstVisible += 1
        }
        // 2. Still too wide (few but long segments): shrink the widest visible
        //    ones — the buttons truncate their titles in the middle.
        let visibleIdx = (0..<segments.count).filter { $0 == 0 || $0 >= firstVisible }
        // A split pane can be only 160 pt wide. Share its remaining width
        // between captions so even the trailing subfolder control stays inside.
        let controlsWidth = CGFloat(visibleIdx.count - (hidden.isEmpty ? 0 : 1)) * chevronW
            + (hidden.isEmpty ? 0 : overflowW)
        let minimumCaptionWidth = min(60, max(0, (available - controlsWidth) / CGFloat(max(1, visibleIdx.count))))
        var overflow = total(from: firstVisible, withOverflow: !hidden.isEmpty) - available
        while overflow > 0, let widest = visibleIdx.max(by: { widths[$0] < widths[$1] }), widths[widest] > minimumCaptionWidth {
            let cut = min(overflow, widths[widest] - minimumCaptionWidth)
            widths[widest] -= cut
            overflow -= cut
        }

        // Keep the view hierarchy and visibility stable across layout passes.
        // Recreating the overflow button (or briefly unhiding the root's
        // chevron) invalidates AppKit layout again in narrow split panes.
        if overflowButton?.isHidden != hidden.isEmpty { overflowButton?.isHidden = hidden.isEmpty }
        var x = pad
        for i in 0..<segments.count {
            let s = segmentButtons[i], c = chevronButtons[i]
            let visible = i == 0 || i >= firstVisible
            let chevronHidden = !visible || (i == 0 && !hidden.isEmpty)
            if s.isHidden != !visible { s.isHidden = !visible }
            if c.isHidden != chevronHidden { c.isHidden = chevronHidden }
            if !visible { continue }
            let segmentFrame = NSRect(x: x, y: y, width: widths[i], height: 22)
            if s.frame != segmentFrame { s.frame = segmentFrame }
            x += widths[i]
            if i == 0, !hidden.isEmpty {
                let overflowFrame = NSRect(x: x, y: y, width: overflowW, height: 22)
                if overflowButton?.frame != overflowFrame { overflowButton?.frame = overflowFrame }
                x += overflowW
                continue
            }
            let chevronFrame = NSRect(x: x, y: y, width: chevronW, height: 22)
            if c.frame != chevronFrame { c.frame = chevronFrame }
            x += chevronW
        }
        hiddenSegmentIndexes = hidden
        updateDropHighlight()
    }

    private var hiddenSegmentIndexes: [Int] = []

    // MARK: - Actions

    @objc private func segmentClicked(_ sender: NSButton) {
        guard segments.indices.contains(sender.tag) else { return }
        onNavigate?(segments[sender.tag].url)
    }

    @objc private func chevronClicked(_ sender: NSButton) {
        guard segments.indices.contains(sender.tag) else { return }
        let folder = segments[sender.tag].url
        let menu = subfolderMenu(of: folder, current: segments.indices.contains(sender.tag + 1) ? segments[sender.tag + 1].url : nil)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func overflowClicked(_ sender: NSButton) {
        let menu = NSMenu()
        for i in hiddenSegmentIndexes {
            let item = NSMenuItem(title: segments[i].title, action: #selector(menuNavigate(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = segments[i].url
            item.image = Self.navigationIcon(for: segments[i].url)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// The sideways-jump menu: subfolders of `folder`, the one on the current path ticked.
    func subfolderMenu(of folder: URL, current: URL?) -> NSMenu {
        let folder = ArchiveWorkspace.shared.logicalURL(for: folder)
        let menu = NSMenu()
        let names = PathCompleter.completions(for: folder.path + "/", cwd: folder, home: homeURL)
        if names.isEmpty {
            let none = NSMenuItem(title: "No Subfolders", action: nil, keyEquivalent: "")
            none.isEnabled = false; menu.addItem(none)
            return menu
        }
        for name in names {
            let child = folder.appendingPathComponent(String(name.dropLast()))
            let item = NSMenuItem(title: String(name.dropLast()), action: #selector(menuNavigate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = child
            item.image = Self.navigationIcon(for: child)
            if let current, ArchiveWorkspace.shared.logicalURL(for: current).standardizedFileURL == child.standardizedFileURL {
                item.state = .on
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuNavigate(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onNavigate?(url)
    }

    /// Clicking empty bar space enters edit mode, like Dolphin.
    override func mouseDown(with event: NSEvent) {
        if !isEditing { beginEditing() } else { super.mouseDown(with: event) }
    }

    // MARK: - Edit mode

    func beginEditing() {
        onBeginEditing?()
        // The window reuses one field editor. Acquiring it again can deliver
        // the previous session's didEndEditing synchronously to this same
        // field; that notification must not tear down the new edit session.
        isBeginningEditing = true
        defer { isBeginningEditing = false }
        let wasEditing = isEditing
        if !wasEditing {
            isEditing = true
            segmentButtons.forEach { $0.isHidden = true }
            chevronButtons.forEach { $0.isHidden = true }
            overflowButton?.isHidden = true
            let logical = url.map { ArchiveWorkspace.shared.logicalURL(for: $0) }
            textField.stringValue = (logical?.path as NSString?)?.abbreviatingWithTildeInPath ?? ""
            textField.isHidden = false
            lastTypedCount = 0        // select-all + first keystroke must count as typing, not deleting
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        window?.makeFirstResponder(textField)
        if !wasEditing { textField.currentEditor()?.selectAll(nil) }
    }

    func endEditing(returnFocus: Bool = true) {
        guard isEditing else { return }
        isEditing = false
        completion.hide()
        if window?.firstResponder === textField.currentEditor() { window?.makeFirstResponder(nil) }
        textField.isHidden = true
        rebuild()
        if returnFocus { onEndEditing?() }
    }

    /// Resolve the typed text and navigate. Returns false (and reports) if it is not a folder.
    @discardableResult
    func commit(_ text: String) -> Bool {
        guard let cwd = url, let target = PathCompleter.resolveNavigationLocation(text, cwd: cwd, home: homeURL) else {
            NSSound.beep()
            onInvalidPath?(text)
            return false
        }
        endEditing()
        onNavigate?(target)
        return true
    }

    // MARK: - Completion

    private var lastTypedCount = 0
    private var isFilling = false
    private var editor: NSTextView? { textField.currentEditor() as? NSTextView }

    /// The text the user actually typed: everything before the caret. After an
    /// inline fill the completed tail is selected, so it is excluded here.
    var typedText: String {
        guard let editor else { return textField.stringValue }
        let range = editor.selectedRange
        return (editor.string as NSString).substring(to: min(range.location, (editor.string as NSString).length))
    }

    /// The inline-completed tail, if one is currently selected.
    var inlineCompletion: String? {
        guard let editor else { return nil }
        let range = editor.selectedRange
        let s = editor.string as NSString
        guard range.length > 0, range.location + range.length == s.length else { return nil }
        return s.substring(with: range)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isFilling else { return }
        textChanged()
    }

    /// Recompute candidates for what has been typed; fill inline when typing
    /// forward (never while deleting), and keep the list in step.
    func textChanged() {
        let typed = typedText
        let growing = typed.count > lastTypedCount
        lastTypedCount = typed.count
        let candidates = PathCompleter.completions(for: typed, cwd: url ?? homeURL, home: homeURL)
        let (_, partial) = PathCompleter.splitLastComponent(typed)
        if growing, !partial.isEmpty, let first = candidates.first, let editor {
            fill(inline: first, replacing: partial, in: editor)
        }
        showCandidates(candidates)
    }

    private func fill(inline candidate: String, replacing partial: String, in editor: NSTextView) {
        let full = editor.string as NSString
        let caret = editor.selectedRange.location
        let start = caret - (partial as NSString).length
        guard start >= 0 else { return }
        isFilling = true
        defer { isFilling = false }
        // Replace the partial component with the candidate (real case), keep
        // the caret where it was, and select the added tail.
        let range = NSRange(location: start, length: full.length - start)
        if editor.shouldChangeText(in: range, replacementString: candidate) {
            editor.replaceCharacters(in: range, with: candidate)
            editor.didChangeText()
        }
        let tail = (candidate as NSString).length - (partial as NSString).length
        editor.setSelectedRange(NSRange(location: start + (partial as NSString).length, length: max(tail, 0)))
    }

    private func showCandidates(_ candidates: [String]) {
        guard let window, isEditing, !candidates.isEmpty else { completion.hide(); return }
        let rect = window.convertToScreen(textField.convert(textField.bounds, to: nil))
        completion.show(candidates, below: rect, in: window)
    }

    /// Replace the component being typed with `candidate` and move on, so the
    /// next round of candidates is that folder's children.
    func accept(candidate: String) {
        guard let editor else { return }
        let typed = typedText
        let (dir, _) = PathCompleter.splitLastComponent(typed)
        isFilling = true
        editor.string = dir + candidate
        isFilling = false
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        lastTypedCount = editor.string.count
        showCandidates(PathCompleter.completions(for: editor.string, cwd: url ?? homeURL, home: homeURL))
    }

    /// Accept whatever completion is on offer: the list's selection, else the inline tail.
    @discardableResult
    func acceptCompletion() -> Bool {
        if let chosen = completion.selectedCandidate {
            accept(candidate: chosen); return true
        }
        if inlineCompletion != nil, let editor {
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            lastTypedCount = editor.string.count
            showCandidates(PathCompleter.completions(for: editor.string, cwd: url ?? homeURL, home: homeURL))
            return true
        }
        return false
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return takes the offered completion first, then navigates.
            if completion.selectedCandidate != nil || inlineCompletion != nil { acceptCompletion() }
            commit(textField.stringValue)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            return acceptCompletion()
        case #selector(NSResponder.moveRight(_:)):
            return inlineCompletion != nil ? acceptCompletion() : false
        case #selector(NSResponder.moveDown(_:)):
            guard completion.isVisible else { return false }
            completion.moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            guard completion.isVisible else { return false }
            completion.moveSelection(by: -1); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if completion.isVisible { completion.hide() } else { endEditing() }
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Focus left the field (clicked elsewhere): fall back to breadcrumb.
        guard obj.object as? NSTextField === textField, !isBeginningEditing else { return }
        if isEditing { endEditing(returnFocus: false) }
    }

    // MARK: - Files dragged over the breadcrumb

    /// Each visible segment is a drop target for the folder it names, using the
    /// same rule as the list, grid, sidebar, folder tree and tab strip. The
    /// "…" overflow menu's hidden segments are not targets.
    func segmentIndex(at point: NSPoint) -> Int? {
        guard !isEditing else { return nil }
        for (i, button) in segmentButtons.enumerated() where !button.isHidden {
            if button.frame.contains(point) { return i }
        }
        return nil
    }

    /// The operation a drop on `index` would perform, or none.
    func dropOperation(for urls: [URL], atSegment index: Int?, sourceMask: NSDragOperation) -> NSDragOperation {
        guard !isEditing, let index, segments.indices.contains(index), !urls.isEmpty else { return [] }
        let destination = segments[index].url
        guard !ArchiveWorkspace.shared.containsArchiveLocation(destination) else { return [] }
        return FileOperations.dropOperation(for: urls, into: destination, sourceMask: sourceMask)
    }

    /// Hands an accepted drop to the browser; the view never touches files.
    @discardableResult
    func performDrop(urls: [URL], sourceMask: NSDragOperation, onSegment index: Int?) -> Bool {
        let op = dropOperation(for: urls, atSegment: index, sourceMask: sourceMask)
        guard !op.isEmpty, let index, segments.indices.contains(index) else { return false }
        onDropFiles?(urls, segments[index].url, op)
        return true
    }

    /// For tests and for the highlight: which segment the pointer is over.
    var hoveredSegmentIndexForTesting: Int? { hoverSegmentIndex }

    /// One segment's button frame, or `.zero` when that segment is folded into
    /// the "…" menu (those hidden segments are not drop targets).
    func segmentFrameForTesting(_ index: Int) -> NSRect {
        guard segmentButtons.indices.contains(index), !segmentButtons[index].isHidden else { return .zero }
        return segmentButtons[index].frame
    }

    /// The folder a segment names, for tests that assert the drop destination.
    func segmentURLForTesting(_ index: Int) -> URL? {
        segments.indices.contains(index) ? segments[index].url : nil
    }

    private func updateDropHighlight() {
        guard let index = hoverSegmentIndex, segmentButtons.indices.contains(index), !segmentButtons[index].isHidden else {
            dropHighlight.isHidden = true
            return
        }
        dropHighlight.frame = segmentButtons[index].frame.insetBy(dx: -1, dy: -1)
        dropHighlight.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
        dropHighlight.isHidden = false
    }

    private func endDropHover() { hoverSegmentIndex = nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = sender.fileURLs
        let index = segmentIndex(at: convert(sender.draggingLocation, from: nil))
        let mask = sender.draggingSourceOperationMask
        let op = dropOperation(for: urls, atSegment: index, sourceMask: mask)
        hoverSegmentIndex = op.isEmpty ? nil : index
        return DragAndDrop.validationOperation(op, sourceMask: mask)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endDropHover() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endDropHover() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let index = segmentIndex(at: convert(sender.draggingLocation, from: nil))
        endDropHover()
        return performDrop(urls: sender.fileURLs, sourceMask: sender.draggingSourceOperationMask, onSegment: index)
    }
}

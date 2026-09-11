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
    /// Called when editing ends for any reason, so focus can go back to the list.
    var onEndEditing: (() -> Void)?

    private(set) var isEditing = false
    let textField = NSTextField()
    let completion = CompletionPopup()
    private var segments: [Segment] = []
    private var segmentButtons: [NSButton] = []
    private var chevronButtons: [NSButton] = []
    private var overflowButton: NSButton?

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
        textField.placeholderString = "Type a folder path — ⌘L"
        textField.cell?.sendsActionOnEndEditing = false
        addSubview(textField)
        completion.onChoose = { [weak self] name in
            self?.accept(candidate: name)
            self?.window?.makeFirstResponder(self?.textField)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

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
    var hasOverflowMenu: Bool { overflowButton != nil }

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
        guard let url else { return [] }
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
            out.append(Segment(url: base, title: FileManager.default.displayName(atPath: base.path), icon: nil))
        }
        return out
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

        overflowButton?.removeFromSuperview(); overflowButton = nil
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
        var overflow = total(from: firstVisible, withOverflow: !hidden.isEmpty) - available
        while overflow > 0, let widest = visibleIdx.max(by: { widths[$0] < widths[$1] }), widths[widest] > 60 {
            let cut = min(overflow, widths[widest] - 60)
            widths[widest] -= cut
            overflow -= cut
        }

        var x = pad
        for i in 0..<segments.count {
            let s = segmentButtons[i], c = chevronButtons[i]
            let visible = i == 0 || i >= firstVisible
            s.isHidden = !visible; c.isHidden = !visible
            if !visible { continue }
            s.frame = NSRect(x: x, y: y, width: widths[i], height: 22); x += widths[i]
            if i == 0, !hidden.isEmpty {
                let o = NSButton(title: "…", target: self, action: #selector(overflowClicked(_:)))
                o.bezelStyle = .accessoryBarAction; o.showsBorderOnlyWhileMouseInside = true
                o.frame = NSRect(x: x, y: y, width: overflowW, height: 22)
                o.toolTip = "Hidden segments"
                addSubview(o); overflowButton = o; x += overflowW
                c.isHidden = true
                continue
            }
            c.frame = NSRect(x: x, y: y, width: chevronW, height: 22); x += chevronW
        }
        hiddenSegmentIndexes = hidden
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
            item.image = NSWorkspace.shared.icon(forFile: segments[i].url.path); item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// The sideways-jump menu: subfolders of `folder`, the one on the current path ticked.
    func subfolderMenu(of folder: URL, current: URL?) -> NSMenu {
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
            item.image = NSWorkspace.shared.icon(forFile: child.path); item.image?.size = NSSize(width: 16, height: 16)
            if let current, current.standardizedFileURL == child.standardizedFileURL { item.state = .on }
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
        guard !isEditing else { window?.makeFirstResponder(textField); return }
        isEditing = true
        segmentButtons.forEach { $0.isHidden = true }
        chevronButtons.forEach { $0.isHidden = true }
        overflowButton?.isHidden = true
        textField.stringValue = (url?.path as NSString?)?.abbreviatingWithTildeInPath ?? ""
        textField.isHidden = false
        lastTypedCount = 0        // select-all + first keystroke must count as typing, not deleting
        needsLayout = true
        window?.makeFirstResponder(textField)
        textField.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        completion.hide()
        if window?.firstResponder === textField.currentEditor() { window?.makeFirstResponder(nil) }
        textField.isHidden = true
        rebuild()
        onEndEditing?()
    }

    /// Resolve the typed text and navigate. Returns false (and reports) if it is not a folder.
    @discardableResult
    func commit(_ text: String) -> Bool {
        guard let cwd = url, let target = PathCompleter.resolveDirectory(text, cwd: cwd, home: homeURL) else {
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
        if isEditing { endEditing() }
    }
}

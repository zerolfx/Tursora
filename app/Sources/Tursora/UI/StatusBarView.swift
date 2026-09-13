import AppKit

/// Bottom status line: "12 items, 3 selected — 120 GB available", plus a
/// spinner while a copy/move is running.
final class StatusBarView: NSView {

    static let height: CGFloat = 22

    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    let zoomSlider = NSSlider()
    let terminalStatusButton = NSButton()
    var onTerminalToggle: (() -> Void)?
    private var terminalStatus: TerminalStatusPresentation?
    var onZoomChanged: ((Int) -> Void)?
    private var busyCount = 0
    private var isShowingArchiveStatus = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        zoomSlider.controlSize = .mini
        zoomSlider.minValue = 0
        zoomSlider.maxValue = 1
        zoomSlider.allowsTickMarkValuesOnly = true
        zoomSlider.numberOfTickMarks = 2
        zoomSlider.tickMarkPosition = .below
        zoomSlider.toolTip = "Icon size (⌘-scroll or pinch to zoom)"
        zoomSlider.target = self
        zoomSlider.action = #selector(sliderMoved(_:))
        addSubview(zoomSlider)
        terminalStatusButton.bezelStyle = .inline
        terminalStatusButton.isBordered = false
        terminalStatusButton.font = .systemFont(ofSize: 10)
        terminalStatusButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        terminalStatusButton.imagePosition = .imageLeading
        terminalStatusButton.target = self
        terminalStatusButton.action = #selector(toggleTerminal(_:))
        terminalStatusButton.isHidden = true
        addSubview(terminalStatusButton)
    }

    @objc private func sliderMoved(_ sender: NSSlider) { onZoomChanged?(Int(sender.doubleValue.rounded())) }
    @objc private func toggleTerminal(_ sender: NSButton) { onTerminalToggle?() }

    func setTerminalStatus(_ value: TerminalStatusPresentation?) {
        guard terminalStatus != value else { return }
        terminalStatus = value
        terminalStatusButton.isHidden = value == nil
        terminalStatusButton.isEnabled = value?.isEnabled == true
        terminalStatusButton.toolTip = value?.detail
        terminalStatusButton.setAccessibilityLabel(value.map { $0.title + ". " + $0.detail })
        terminalStatusButton.contentTintColor = value?.hasTasks == true ? .controlAccentColor : .secondaryLabelColor
        needsLayout = true
    }

    /// Reflect the current zoom step without firing the action.
    func setZoom(index: Int, count: Int) {
        zoomSlider.maxValue = Double(max(count - 1, 1))
        zoomSlider.numberOfTickMarks = max(count, 2)
        zoomSlider.doubleValue = Double(index)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func layout() {
        super.layout()
        spinner.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
        if let terminalStatus {
            // Keep the ZIP/search status and task spinner legible in a narrow
            // pane; the full terminal state remains available to AX/tooltips.
            let compact = bounds.width < 280
            let width: CGFloat = compact ? 24 : min(140, max(110, bounds.width * 0.3))
            let title = compact ? "" : terminalStatus.title
            let imagePosition: NSControl.ImagePosition = compact ? .imageOnly : .imageLeading
            if terminalStatusButton.title != title { terminalStatusButton.title = title }
            if terminalStatusButton.imagePosition != imagePosition { terminalStatusButton.imagePosition = imagePosition }
            terminalStatusButton.frame = NSRect(x: max(4, spinner.frame.minX - width - 4), y: (bounds.height - 18) / 2, width: width, height: 18)
            zoomSlider.isHidden = bounds.width < 450
            let zoomWidth: CGFloat = zoomSlider.isHidden ? 0 : 90
            zoomSlider.frame = NSRect(x: terminalStatusButton.frame.minX - zoomWidth - 8, y: (bounds.height - 16) / 2, width: zoomWidth, height: 16)
            let trailing = zoomSlider.isHidden ? terminalStatusButton.frame.minX : zoomSlider.frame.minX
            label.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: max(0, trailing - 16), height: 16)
            return
        }
        zoomSlider.frame = NSRect(x: bounds.width - 22 - 8 - 110, y: (bounds.height - 16) / 2, width: 110, height: 16)
        // Preserve the read-only warning in narrow split panes. Zoom remains
        // available from the menu and gestures when its slider cannot fit.
        let compactArchive = isShowingArchiveStatus && bounds.width < 360
        zoomSlider.isHidden = compactArchive
        let leading: CGFloat = compactArchive ? 8 : 30
        let reserved: CGFloat = compactArchive ? 38 : 180
        label.frame = NSRect(x: leading, y: (bounds.height - 16) / 2, width: max(0, bounds.width - reserved), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    var statusText: String { label.stringValue }

    func update(itemCount: Int, totalCount: Int? = nil, selectedCount: Int, directory: URL?, archiveStatus: String? = nil, searchStatus: String? = nil) {
        isShowingArchiveStatus = archiveStatus != nil || searchStatus != nil
        label.lineBreakMode = isShowingArchiveStatus ? .byTruncatingTail : .byTruncatingMiddle
        needsLayout = true
        var parts: [String] = []
        if let totalCount, totalCount != itemCount {
            parts.append("\(itemCount) of \(totalCount) items")            // filtering
        } else {
            parts.append(itemCount == 1 ? "1 item" : "\(itemCount) items")
        }
        if selectedCount > 0 { parts[0] = "\(selectedCount) of \(itemCount) selected" }
        if archiveStatus == nil, let directory,
           let cap = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage {
            parts.append("\(ByteCountFormatter.string(fromByteCount: cap, countStyle: .file)) available")
        }
        if let context = archiveStatus ?? searchStatus { parts.insert(context, at: 0) }
        label.stringValue = parts.joined(separator: " — ")
        label.toolTip = archiveStatus == nil ? nil
            : "Read-only ZIP. Opened files are temporary copies kept until Tursora quits. Edits do not update the ZIP; use Save As to keep them."
        if searchStatus != nil { label.toolTip = "Search results use their original file locations. Reveal in Enclosing Folder opens a result's parent." }
        toolTip = label.toolTip
    }

    /// Nested-safe: several operations may overlap.
    func beginBusy() { busyCount += 1; spinner.startAnimation(nil) }
    func endBusy() { busyCount = max(0, busyCount - 1); if busyCount == 0 { spinner.stopAnimation(nil) } }
}

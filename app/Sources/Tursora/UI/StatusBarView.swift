import AppKit

/// File counts and selection/search/archive context, plus progress while a
/// copy or move is running. This view does not query filesystem capacity.
final class StatusBarView: NSView {
    static let height: CGFloat = 22

    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    let zoomSlider = NSSlider()
    var onZoomChanged: ((Int) -> Void)?
    private var busyCount = 0

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
    }

    @objc private func sliderMoved(_ sender: NSSlider) { onZoomChanged?(Int(sender.doubleValue.rounded())) }

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
        zoomSlider.frame = NSRect(x: bounds.width - 22 - 8 - 110, y: (bounds.height - 16) / 2, width: 110, height: 16)
        // Preserve file counts and context in narrow split panes. Zoom is
        // still available from its menu and gestures when the slider yields.
        let compact = bounds.width < 360
        zoomSlider.isHidden = compact
        let leading: CGFloat = compact ? 8 : 30
        let reserved: CGFloat = compact ? 38 : 180
        label.frame = NSRect(x: leading, y: (bounds.height - 16) / 2, width: max(0, bounds.width - reserved), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    var statusText: String { label.stringValue }

    func update(itemCount: Int, totalCount: Int? = nil, selectedCount: Int, archiveStatus: String? = nil, searchStatus: String? = nil) {
        let hasContext = archiveStatus != nil || searchStatus != nil
        label.lineBreakMode = hasContext ? .byTruncatingTail : .byTruncatingMiddle
        needsLayout = true
        var parts: [String] = []
        if let totalCount, totalCount != itemCount {
            parts.append("\(itemCount) of \(totalCount) items")
        } else {
            parts.append(itemCount == 1 ? "1 item" : "\(itemCount) items")
        }
        if selectedCount > 0 { parts[0] = "\(selectedCount) of \(itemCount) selected" }
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

import AppKit

/// Finder's scope bar, shown under the toolbar while the search field is in
/// use: "Filter:  [📁 Folder]". One scope for now — the current folder —
/// laid out so "This Mac" (Spotlight) can join it later.
final class SearchScopeBar: NSView {

    static let height: CGFloat = 30

    private let label = NSTextField(labelWithString: "Filter:")
    private let folderChip = NSButton()
    private let countLabel = NSTextField(labelWithString: "")

    var folderName: String = "" {
        didSet { folderChip.title = folderName; needsLayout = true }
    }
    var folderIcon: NSImage? {
        didSet { folderChip.image = folderIcon; needsLayout = true }
    }
    /// "3 of 12 items" while a filter is active.
    var summary: String = "" {
        didSet { countLabel.stringValue = summary; needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)

        folderChip.bezelStyle = .recessed          // Finder's scope chips: filled when selected
        folderChip.setButtonType(.pushOnPushOff)
        folderChip.state = .on
        folderChip.isEnabled = false               // the only scope; selected and not toggleable
        folderChip.imagePosition = .imageLeading
        folderChip.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        folderChip.controlSize = .small
        addSubview(folderChip)

        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        addSubview(countLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func layout() {
        super.layout()
        let y = (bounds.height - 20) / 2
        let lw = label.fittingSize.width
        label.frame = NSRect(x: 12, y: y, width: lw, height: 20)
        let cw = min(folderChip.fittingSize.width + 8, bounds.width * 0.5)
        folderChip.frame = NSRect(x: 12 + lw + 8, y: y, width: cw, height: 20)
        countLabel.frame = NSRect(x: bounds.width - 12 - 200, y: y, width: 200, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

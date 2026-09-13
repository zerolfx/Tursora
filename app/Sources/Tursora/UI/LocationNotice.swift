import AppKit

/// A pane-local banner for a location that could not be listed, built like
/// `ArchiveNavigationNotice`: the previous listing stays usable underneath and
/// no modal ever appears — a headless run would hang on one.
///
/// Today it carries exactly one case: the Trash (or any folder) refused
/// because Tursora lacks Full Disk Access.
final class LocationNotice: NSView {
    let messageLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let settingsButton = NSButton(title: "Open Privacy Settings", target: nil, action: nil)
    let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let buttons = NSStackView()

    /// What the banner is about, so the pane can re-list the same folder.
    private(set) var url: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        messageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        messageLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byTruncatingTail
        for button in [settingsButton, retryButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            buttons.addArrangedSubview(button)
        }
        buttons.spacing = 8
        buttons.alignment = .centerY
        let stack = NSStackView(views: [messageLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Wording is Tursora's own: Finder never shows this banner (it is the
    /// system file manager and always has the access). Recorded as inferred in
    /// docs/research/trash.md.
    static func accessDeniedMessage(for url: URL) -> String {
        "Tursora doesn’t have permission to open “\(url.lastPathComponent)”."
    }
    static let accessDeniedDetail =
        "Give Tursora Full Disk Access in Privacy & Security settings, then try again."

    func showAccessDenied(_ url: URL, error: Error) {
        self.url = url
        messageLabel.stringValue = Self.accessDeniedMessage(for: url)
        messageLabel.toolTip = url.path
        detailLabel.stringValue = Self.accessDeniedDetail + "\n" + error.localizedDescription
        detailLabel.toolTip = error.localizedDescription
        detailLabel.isHidden = false
        toolTip = error.localizedDescription
        updateButtonLayout()
    }

    private func updateButtonLayout() {
        let vertical = bounds.width < 340
        let orientation: NSUserInterfaceLayoutOrientation = vertical ? .vertical : .horizontal
        if buttons.orientation != orientation {
            buttons.orientation = orientation
            buttons.alignment = vertical ? .leading : .centerY
        }
    }

    override func layout() {
        updateButtonLayout()
        super.layout()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

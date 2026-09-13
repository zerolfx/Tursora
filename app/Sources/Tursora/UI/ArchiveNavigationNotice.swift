import AppKit

/// Pane-local progress and recovery controls; the previous listing stays usable
/// after a failed navigation instead of being covered by an error overlay.
final class ArchiveNavigationNotice: NSView {
    let messageLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    let enclosingFolderButton = NSButton(title: "Open Enclosing Folder", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let buttons = NSStackView()
    private var showsFailure = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        messageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        messageLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        [spinner, cancelButton, retryButton, enclosingFolderButton].forEach { buttons.addArrangedSubview($0) }
        buttons.spacing = 8
        buttons.alignment = .centerY
        for button in [cancelButton, retryButton, enclosingFolderButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
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
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func showOpening(_ archive: URL) {
        showsFailure = false
        updateButtonLayout()
        messageLabel.stringValue = "Opening \(archive.lastPathComponent)…"
        messageLabel.toolTip = archive.path
        detailLabel.isHidden = true
        cancelButton.isHidden = false
        retryButton.isHidden = true
        enclosingFolderButton.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    func showFailure(_ archive: URL, error: Error) {
        showsFailure = true
        updateButtonLayout()
        messageLabel.stringValue = "Cannot open \(archive.lastPathComponent)"
        messageLabel.toolTip = archive.path
        detailLabel.stringValue = error.localizedDescription
        detailLabel.toolTip = error.localizedDescription
        detailLabel.isHidden = false
        cancelButton.isHidden = true
        retryButton.isHidden = false
        enclosingFolderButton.isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
    }

    private func updateButtonLayout() {
        let vertical = showsFailure && bounds.width < 300
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

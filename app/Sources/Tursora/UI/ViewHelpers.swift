import AppKit

/// CALayer stores resolved CGColors, so retaining semantic NSColors here lets
/// an existing surface follow its view's appearance when Light/Dark changes.
class AdaptiveLayerView: NSView {
    var semanticBackgroundColor: NSColor? { didSet { needsDisplay = true } }
    var semanticBorderColor: NSColor? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = semanticBackgroundColor?.cgColor
            layer?.borderColor = semanticBorderColor?.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
}

/// Top-left-origin document view for scroll views that stack rows downwards.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Root view that tells its controller when Light/Dark changes so custom
/// surfaces (terminal colors, previews) can re-resolve semantic colors.
final class AppearanceObservingView: NSView {
    var onAppearanceChanged: (() -> Void)?
    private let flipsCoordinates: Bool

    init(flipped: Bool = false, frame: NSRect = .zero) {
        flipsCoordinates = flipped
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { flipsCoordinates }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}

extension NSTextField {
    /// 13 pt semibold section heading (Settings pages, dialogs).
    static func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    /// Wrapping secondary explanation shown under a control.
    static func detail(_ text: String, size: CGFloat = 12) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = .secondaryLabelColor
        return field
    }
}

extension NSPasteboard {
    /// The file URLs on the pasteboard, or none. A ZIP entry this process
    /// promised but has not extracted yet comes as its logical URL first, so
    /// a drop copies it the way Copy to Other Pane does (D101).
    var fileURLs: [URL] {
        ArchiveEntryPromiseProvider.logicalURLs(on: self)
            + ((readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
    }
}

extension NSDraggingInfo {
    /// The dragged file URLs, or none.
    var fileURLs: [URL] { draggingPasteboard.fileURLs }
}

extension NSView {
    /// Pin a subview to all four edges of the receiver.
    func pinToEdges(_ subview: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            subview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            subview.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

extension NSTableCellView {
    /// A cell with an optional 16pt leading icon and a single-line label,
    /// laid out the way system table views expect (label baseline-aligned,
    /// icon vertically centred).
    static func make(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool,
                     alignment: NSTextAlignment = .natural, iconSize: CGFloat = 16) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.alignment = alignment
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        var leading: NSLayoutXAxisAnchor = cell.leadingAnchor
        var leadingInset: CGFloat = 4
        if withIcon {
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: iconSize),
                icon.heightAnchor.constraint(equalToConstant: iconSize),
            ])
            leading = icon.trailingAnchor
            leadingInset = 6
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: leadingInset),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

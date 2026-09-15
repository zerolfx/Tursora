import AppKit
import Quartz
import UniformTypeIdentifiers

/// A text view that renders Markdown.
///
/// It exists as its own class for one reason: `NSTextTableBlock`, which is how
/// a Markdown table gets columns, **only takes effect under TextKit 1**. A
/// plain `NSTextView` uses TextKit 2, where the table blocks are ignored and
/// every cell simply stacks — with no error, no warning, and text that still
/// reads correctly in a log. Touching `layoutManager` at construction forces
/// the older stack; `isUsingLegacyLayoutForTesting` lets a check pin that so a
/// later refactor cannot quietly undo it.
final class MarkdownTextView: NSTextView {
    convenience init() {
        self.init(frame: .zero)
        _ = layoutManager                    // forces TextKit 1; see above
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = NSSize(width: 14, height: 12)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        autoresizingMask = [.width]
    }

    /// True while the view is on TextKit 1, which Markdown tables require.
    var isUsingLegacyLayoutForTesting: Bool { textLayoutManager == nil }

    /// A previewed document is untrusted content. Its relative links resolve to
    /// file URLs, so letting AppKit open them would turn one click on a
    /// downloaded note into `open` on an arbitrary neighbouring file — an .app
    /// or .command included. Nothing is opened from here; the pane reports the
    /// click and the window decides (today: it does nothing but say so).
    override func clicked(onLink link: Any, at charIndex: Int) {
        onLinkClicked?(link as? URL ?? (link as? String).flatMap(URL.init(string:)))
    }

    var onLinkClicked: ((URL?) -> Void)?
}

/// The docked preview pane: a resizable pane beside the file view that follows
/// the selection and stays put as you navigate.
///
/// Markdown is rendered as rich text (`MarkdownRenderer`); everything else
/// falls back to Quick Look, which is what the Inspector already uses. The two
/// surfaces are swapped rather than stacked, because `QLPreviewView` keeps
/// working — and can keep playing media — while hidden.
final class PreviewPanelController: NSViewController {

    private let titleLabel = NSTextField(labelWithString: "Preview")
    private let scrollView = NSScrollView()
    let textView = MarkdownTextView()
    private var quickLook: QLPreviewView?
    private let emptyLabel = NSTextField(labelWithString: "No selection")

    /// The item on show, so a repeated selection of the same file does not
    /// re-read and re-render it on every arrow key.
    private(set) var shownURL: URL?
    private(set) var isShowingMarkdown = false

    var onClose: (() -> Void)?
    /// Reported rather than acted on; see `MarkdownTextView.clickedOnLink`.
    var onLinkClicked: ((URL?) -> Void)?

    override func loadView() {
        view = NSView()
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide Preview")!,
                             target: self, action: #selector(closePanel(_:)))
        close.bezelStyle = .inline
        close.isBordered = false
        close.toolTip = "Hide Preview"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, spacer, close])
        header.orientation = .horizontal
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        textView.onLinkClicked = { [weak self] url in self?.onLinkClicked?(url) }
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            header.heightAnchor.constraint(equalToConstant: 24),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        show(nil)
    }

    @objc private func closePanel(_ sender: Any?) { onClose?() }

    /// Markdown by extension or declared type, mirroring the hedge
    /// `TextThumbnailRenderer.supports` already uses: the Markdown UTI is
    /// declared by third-party apps, so its presence cannot be relied on.
    static func isMarkdown(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension),
           type.identifier == "net.daringfireball.markdown" { return true }
        return ["md", "markdown", "mdown", "mkd", "mdwn"].contains(url.pathExtension.lowercased())
    }

    /// Shows `url`, or the empty state for nil. Re-showing the same URL is a
    /// no-op so that holding an arrow key does not re-read the file each time;
    /// `force` is for a file that changed underneath us.
    func show(_ url: URL?, force: Bool = false) {
        guard force || url != shownURL else { return }
        shownURL = url
        guard let url else {
            titleLabel.stringValue = "Preview"
            scrollView.isHidden = true
            releaseQuickLook()
            emptyLabel.isHidden = false
            isShowingMarkdown = false
            return
        }
        titleLabel.stringValue = url.lastPathComponent
        emptyLabel.isHidden = true

        if Self.isMarkdown(url), let snippet = TextThumbnailRenderer.readSnippet(
            from: url, limit: MarkdownRenderer.maxSourceCharacters) {
            isShowingMarkdown = true
            releaseQuickLook()
            scrollView.isHidden = false
            textView.textStorage?.setAttributedString(
                MarkdownRenderer.render(snippet.text, baseURL: url.deletingLastPathComponent()))
            textView.scroll(.zero)
        } else {
            isShowingMarkdown = false
            scrollView.isHidden = true
            let preview = quickLook ?? makeQuickLook()
            preview.isHidden = false
            preview.previewItem = url as NSURL
        }
    }

    /// Hiding a `QLPreviewView` does not stop it: a previewed video or sound
    /// keeps playing behind the Markdown view, or behind the empty state, with
    /// nothing on screen to explain the noise. Clearing the item is what
    /// actually stops it.
    private func releaseQuickLook() {
        guard let quickLook else { return }
        quickLook.previewItem = nil
        quickLook.isHidden = true
    }

    private func makeQuickLook() -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.shouldCloseWithWindow = false
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.topAnchor.constraint(equalTo: scrollView.topAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        quickLook = preview
        return preview
    }

    /// `QLPreviewView` holds resources and can keep playing media, so it is
    /// closed explicitly when the window goes away rather than left to ARC.
    /// Called when the pane is hidden. The controller is kept — its scroll
    /// position and rendered document survive a reopen — but nothing should
    /// still be playing while the pane is off screen.
    func paneHidden() { releaseQuickLook() }

    func shutdown() {
        quickLook?.close()
        quickLook?.removeFromSuperview()
        quickLook = nil
    }

    // Testing hooks
    var titleForTesting: String { titleLabel.stringValue }
    var isEmptyStateVisibleForTesting: Bool { !emptyLabel.isHidden }
    var renderedTextForTesting: String { textView.string }
    var isQuickLookVisibleForTesting: Bool { quickLook.map { !$0.isHidden } ?? false }
}

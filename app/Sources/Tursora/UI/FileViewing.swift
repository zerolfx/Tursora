import AppKit

/// What BrowserViewController needs from a file view, so the details list and
/// the icon grid are interchangeable. Selection, rename, drag & drop and the
/// context menu are the view's; navigation, file operations and Quick Look
/// are the browser's.
protocol FileViewing: AnyObject {
    var viewController: NSViewController { get }
    /// The view that should have keyboard focus.
    var focusView: NSView { get }

    var onOpen: ((FileItem) -> Void)? { get set }
    var onOpenInNewTab: ((FileItem) -> Void)? { get set }
    var onRenameCommitted: ((FileItem, String) -> Void)? { get set }
    var onSelectionChanged: (() -> Void)? { get set }
    var onFocus: (() -> Void)? { get set }
    var onQuickLook: (() -> Void)? { get set }
    var onDropFiles: (([URL], URL, NSDragOperation) -> Void)? { get set }
    /// +1 / -1 from ⌘-scroll or pinch.
    var onZoomGesture: ((Int) -> Void)? { get set }

    var contextMenu: NSMenu? { get set }
    var cutURLs: Set<URL> { get set }
    var selectedItems: [FileItem] { get }
    /// Targets of a context-menu action: the selection if the clicked item is
    /// in it, else the clicked item alone, else nothing (background).
    var clickedItems: [FileItem] { get }
    var scrollOffset: CGFloat { get set }

    func reloadData()
    func select(name: String?)
    func select(names: [String])
    func openSelection()
    func beginRename(item: FileItem)
    /// The item after the last selected one (what to select after a delete).
    func itemAfterSelection() -> FileItem?
    func setIconSize(_ size: CGFloat, showPreviews: Bool)
    func frameOnScreen(for url: URL) -> NSRect
    /// Forward a key event (Quick Look's arrow keys) to the view.
    func forwardKey(_ event: NSEvent)
}

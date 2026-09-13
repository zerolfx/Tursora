import AppKit

/// Finder's drag-and-drop behaviours: the drag-source masks and the ⌘ (generic)
/// branch of the shared drop rule, breadcrumb segments as drop targets, and
/// spring-loaded folders in the list, the grid, the Places sidebar and the
/// folder tree.
///
/// AppKit owns the spring-loading hover timer and the modifier that narrows a
/// drag's source mask, so a headless run cannot produce either. The pure rules
/// are checked as functions, and the UI path is driven through the same
/// activation entry points AppKit calls (`activateSpringLoading(atRow:)`,
/// `performDrop(urls:sourceMask:onSegment:)`) with the mask AppKit would have
/// handed over.
enum DragAndDropSmokeTests: SmokeSuite {
    static let checkPrefix = "drag and drop: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("tursora-drag-drop-" + UUID().uuidString)
                .resolvingSymlinksInPath()
            let savedFavourites = UserDefaults.standard.stringArray(forKey: "favouritesOrder")
            defer {
                UserDefaults.standard.set(savedFavourites, forKey: "favouritesOrder")
                try? FileManager.default.removeItem(at: fixture)
            }
            do {
                print("== drag and drop ==")
                try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                pureMasks()
                try pureDropRule(in: fixture)
                try pureSpringLoading(in: fixture)
                for mode: ViewMode in [.details, .icons] {
                    try await breadcrumbDrops(mode: mode, in: fixture)
                    try await springLoadedFolders(mode: mode, in: fixture)
                }
                try await sidebarAndFolderTree(in: fixture)
                completion()
            } catch {
                check("fixtures complete", false, error.localizedDescription)
            }
        }
    }

    // MARK: - Pure: drag-source masks

    /// `NSDragging.h` on this machine declares the operations (copy 1, link 2,
    /// generic 4, move 16) but documents no modifier mapping; the ⌥/⌃/⌘
    /// narrowing is AppKit behaviour, so the only thing a source can do is
    /// offer `.generic` as well and read the narrowed mask back.
    private static func pureMasks() {
        check("a writable local drag offers copy, move and generic",
              DragAndDrop.sourceMask(readOnly: false, local: true) == [.copy, .move, .generic])
        check("a writable external drag also offers link",
              DragAndDrop.sourceMask(readOnly: false, local: false) == [.copy, .move, .link, .generic])
        check("a read-only source still offers copy alone, locally",
              DragAndDrop.sourceMask(readOnly: true, local: true) == .copy)
        check("a read-only source still offers copy alone, externally",
              DragAndDrop.sourceMask(readOnly: true, local: false) == .copy)
        check("⌘ over a read-only source narrows to nothing",
              DragAndDrop.sourceMask(readOnly: true, local: true).intersection(.generic).isEmpty)

        check("a ⌘-drag's move is reported back inside its narrowed mask",
              DragAndDrop.validationOperation(.move, sourceMask: .generic) == .generic)
        check("an ordinary move is reported unchanged",
              DragAndDrop.validationOperation(.move, sourceMask: [.copy, .move, .generic]) == .move)
        check("a ⌥-drag's copy is reported unchanged",
              DragAndDrop.validationOperation(.copy, sourceMask: .copy) == .copy)
        check("a refused drop stays refused",
              DragAndDrop.validationOperation([], sourceMask: .generic).isEmpty)
    }

    // MARK: - Pure: the shared drop rule with ⌘

    private static func pureDropRule(in fixture: URL) throws {
        let fm = FileManager.default
        let home = fixture.appendingPathComponent("Rules")
        let sibling = fixture.appendingPathComponent("Sibling")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let note = home.appendingPathComponent("note.txt")
        try Data("drag".utf8).write(to: note)
        // A destination that does not exist has no volume identifier, so
        // `sameVolume` is false — the stand-in for "another volume" that a
        // headless run can rely on without mounting anything.
        let otherVolume = fixture.appendingPathComponent("NotMounted/Inbox")

        check("plain drag onto the same volume moves",
              FileOperations.dropOperation(for: [note], into: sibling, sourceMask: [.copy, .move, .generic]) == .move)
        check("plain drag onto another volume copies",
              FileOperations.dropOperation(for: [note], into: otherVolume, sourceMask: [.copy, .move, .generic]) == .copy)
        check("⌥ forces a copy on the same volume",
              FileOperations.dropOperation(for: [note], into: sibling, sourceMask: .copy) == .copy)
        check("⌘ moves on the same volume",
              FileOperations.dropOperation(for: [note], into: sibling, sourceMask: .generic) == .move)
        check("⌘ moves across volumes too",
              FileOperations.dropOperation(for: [note], into: otherVolume, sourceMask: .generic) == .move)
        check("⌘ onto the item's own folder is still a no-op",
              FileOperations.dropOperation(for: [note], into: home, sourceMask: .generic).isEmpty)
        check("⌘ onto the item itself is still a no-op",
              FileOperations.dropOperation(for: [sibling], into: sibling, sourceMask: .generic).isEmpty)
        check("an empty drag is refused whatever the modifier",
              FileOperations.dropOperation(for: [], into: sibling, sourceMask: .generic).isEmpty)
        check("the ⌘ branch reports itself as generic to AppKit",
              DragAndDrop.validationOperation(for: [note], into: sibling, sourceMask: .generic) == .generic)
        check("an ordinary drag still reports move to AppKit",
              DragAndDrop.validationOperation(for: [note], into: sibling, sourceMask: [.copy, .move, .generic]) == .move)
    }

    // MARK: - Pure: what may spring open

    private static func pureSpringLoading(in fixture: URL) throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("Spring")
        let target = root.appendingPathComponent("Target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let outside = fixture.appendingPathComponent("outside.txt")
        try Data("drag".utf8).write(to: outside)
        let inside = target.appendingPathComponent("inside.txt")
        try Data("drag".utf8).write(to: inside)
        let plain: NSDragOperation = [.copy, .move, .generic]

        check("a folder springs open for a drag from elsewhere",
              DragAndDrop.canSpringLoad(into: target, isNavigable: true, isReadOnly: false,
                                        urls: [outside], sourceMask: plain))
        check("a ⌘-drag springs the same folder open",
              DragAndDrop.canSpringLoad(into: target, isNavigable: true, isReadOnly: false,
                                        urls: [outside], sourceMask: .generic))
        check("a file never springs open",
              !DragAndDrop.canSpringLoad(into: outside, isNavigable: false, isReadOnly: false,
                                         urls: [inside], sourceMask: plain))
        check("the folder the items already live in never springs open",
              !DragAndDrop.canSpringLoad(into: target, isNavigable: true, isReadOnly: false,
                                         urls: [inside], sourceMask: plain))
        check("⌥ does not spring the items' own folder open either",
              !DragAndDrop.canSpringLoad(into: target, isNavigable: true, isReadOnly: false,
                                         urls: [inside], sourceMask: .copy))
        check("a dragged folder never springs itself open",
              !DragAndDrop.canSpringLoad(into: target, isNavigable: true, isReadOnly: false,
                                         urls: [target], sourceMask: plain))
        check("a read-only pane never springs open",
              !DragAndDrop.canSpringLoad(into: target, isNavigable: true, isReadOnly: true,
                                         urls: [outside], sourceMask: plain))
        check("an ended drag carries no URLs, so nothing springs open",
              !DragAndDrop.canSpringLoad(into: target, isNavigable: true, isReadOnly: false,
                                         urls: [], sourceMask: plain))
        check("no target means no spring loading",
              !DragAndDrop.canSpringLoad(into: nil, isNavigable: true, isReadOnly: false,
                                         urls: [outside], sourceMask: plain))
        let enabled: NSSpringLoadingOptions = DragAndDrop.springLoadingOptions(
            into: target, isNavigable: true, isReadOnly: false, urls: [outside], sourceMask: plain)
        let disabled: NSSpringLoadingOptions = DragAndDrop.springLoadingOptions(
            into: outside, isNavigable: false, isReadOnly: false, urls: [inside], sourceMask: plain)
        check("the options AppKit receives follow the same rule",
              enabled.contains(.enabled) && !disabled.contains(.enabled))
        // The hover delay itself belongs to the system, not to Tursora.
        let delay: TimeInterval? = DragAndDrop.systemSpringLoadingDelay
        let described: String = delay.map { "\($0)s" } ?? "unset"
        check("the hover delay comes from the system's own springing preference",
              delay == nil || delay! > 0, "com.apple.springing.delay = " + described)
    }

    // MARK: - Breadcrumb segments as drop targets

    @MainActor private static func breadcrumbDrops(mode: ViewMode, in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("Crumbs-\(mode)")
        let deep = root.appendingPathComponent("Deep")
        let other = fixture.appendingPathComponent("Other-\(mode)")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let note = deep.appendingPathComponent("note.txt")
        try Data("crumb".utf8).write(to: note)

        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("crumbs-\(mode).json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(),
                                      initialURL: deep, viewPropertiesStore: store)
        defer { wc.close() }
        wc.window?.setContentSize(NSSize(width: 1280, height: 720))
        wc.window?.center()
        await listed(wc.browser, at: deep)
        let left = wc.browser
        left.setViewMode(mode)
        left.setGroupKey(.kind)
        // The feature has to work with a split pane beside it.
        let right = wc.tabs.currentPage.split(with: other)
        await listed(right, at: other)
        right.setViewMode(mode)
        wc.tabs.currentPage.activate(left)
        wc.window?.contentView?.layoutSubtreeIfNeeded()

        let bar = left.addressBar
        let last = bar.segmentCount - 1
        let parent = last - 1
        check("\(mode): the breadcrumb ends at the browsed folder",
              bar.segmentURLForTesting(last)?.standardizedFileURL == deep.standardizedFileURL,
              bar.segmentTitles.description)
        check("\(mode): the segment before it is the parent folder",
              bar.segmentURLForTesting(parent)?.standardizedFileURL == root.standardizedFileURL)

        let plain: NSDragOperation = [.copy, .move, .generic]
        check("\(mode): dropping into an ancestor moves within the volume",
              bar.dropOperation(for: [note], atSegment: parent, sourceMask: plain) == .move)
        check("\(mode): ⌥ over a segment copies",
              bar.dropOperation(for: [note], atSegment: parent, sourceMask: .copy) == .copy)
        check("\(mode): ⌘ over a segment moves",
              bar.dropOperation(for: [note], atSegment: parent, sourceMask: .generic) == .move)
        check("\(mode): the item's own folder refuses the drop",
              bar.dropOperation(for: [note], atSegment: last, sourceMask: plain).isEmpty)
        check("\(mode): empty bar space is not a target",
              bar.dropOperation(for: [note], atSegment: nil, sourceMask: plain).isEmpty)
        check("\(mode): an empty drag is refused",
              bar.dropOperation(for: [], atSegment: parent, sourceMask: plain).isEmpty)

        let frame = bar.segmentFrameForTesting(parent)
        check("\(mode): the parent segment is visible and hit-testable", frame != .zero,
              "titles=\(bar.segmentTitles) barWidth=\(bar.bounds.width)")
        if frame != .zero {
            check("\(mode): the pointer over that button resolves to its segment",
                  bar.segmentIndex(at: NSPoint(x: frame.midX, y: frame.midY)) == parent)
            check("\(mode): a point outside every segment resolves to nothing",
                  bar.segmentIndex(at: NSPoint(x: bar.bounds.width - 1, y: frame.midY)) == nil
                  || bar.segmentIndex(at: NSPoint(x: bar.bounds.width - 1, y: frame.midY)) == last)
        }

        bar.beginEditing()
        check("\(mode): the path field replaces the drop targets while editing",
              bar.dropOperation(for: [note], atSegment: parent, sourceMask: plain).isEmpty
              && bar.segmentIndex(at: NSPoint(x: frame.midX, y: frame.midY)) == nil)
        bar.endEditing(returnFocus: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()

        check("\(mode): the drop is accepted on the parent segment",
              bar.performDrop(urls: [note], sourceMask: plain, onSegment: parent))
        await waitUntil("\(mode): the breadcrumb drop moves the file") {
            fm.fileExists(atPath: root.appendingPathComponent("note.txt").path)
                && !fm.fileExists(atPath: note.path)
        }
        check("\(mode): the file now lives in the ancestor folder",
              fm.fileExists(atPath: root.appendingPathComponent("note.txt").path) && !fm.fileExists(atPath: note.path))
        check("\(mode): dropping on the item's own folder is not accepted",
              !bar.performDrop(urls: [root.appendingPathComponent("note.txt")], sourceMask: plain, onSegment: parent))
    }

    // MARK: - Spring-loaded folders in both file views

    @MainActor private static func springLoadedFolders(mode: ViewMode, in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("Hover-\(mode)")
        let alpha = root.appendingPathComponent("Alpha")
        let other = fixture.appendingPathComponent("HoverOther-\(mode)")
        try fm.createDirectory(at: alpha, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("hover".utf8).write(to: root.appendingPathComponent("note.txt"))
        try Data("hover".utf8).write(to: alpha.appendingPathComponent("inner.txt"))
        let dragged = other.appendingPathComponent("dragged.txt")
        try Data("hover".utf8).write(to: dragged)

        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("hover-\(mode).json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(),
                                      initialURL: root, viewPropertiesStore: store)
        defer { wc.close() }
        wc.window?.setContentSize(NSSize(width: 1280, height: 720))
        await listed(wc.browser, at: root)
        let left = wc.browser
        left.setViewMode(mode)
        left.setGroupKey(.kind)
        let right = wc.tabs.currentPage.split(with: other)
        await listed(right, at: other)
        right.setViewMode(mode)
        wc.tabs.currentPage.activate(left)
        wc.window?.contentView?.layoutSubtreeIfNeeded()

        var sprung: [URL] = []
        let originalSpringLoad = left.fileView.onSpringLoad
        left.fileView.onSpringLoad = { url in sprung.append(url); originalSpringLoad?(url) }
        let plain: NSDragOperation = [.copy, .move, .generic]

        if mode == .details {
            let list = left.fileList
            guard let folderRow = row(of: alpha, in: list),
                  let fileRow = row(of: root.appendingPathComponent("note.txt"), in: list) else {
                check("\(mode): the fixture rows are listed", false, "rows=\(list.tableView.numberOfRows)")
                return
            }
            check("\(mode): a file row never springs open",
                  !list.activateSpringLoading(atRow: fileRow, urls: [dragged], sourceMask: plain))
            check("\(mode): a folder already holding the drag never springs open",
                  !list.activateSpringLoading(atRow: folderRow, urls: [alpha.appendingPathComponent("inner.txt")], sourceMask: plain))
            check("\(mode): an ended drag never springs open",
                  !list.activateSpringLoading(atRow: folderRow, urls: [], sourceMask: plain))
            check("\(mode): a row outside the list never springs open",
                  !list.activateSpringLoading(atRow: -1, urls: [dragged], sourceMask: plain))
            if let header = groupHeaderRow(in: list) {
                check("\(mode): a group header never springs open",
                      !list.activateSpringLoading(atRow: header, urls: [dragged], sourceMask: plain))
            } else {
                check("\(mode): grouping is active for the header case", false, "no group row found")
            }
            list.isReadOnly = true
            check("\(mode): a read-only pane never springs open",
                  !list.activateSpringLoading(atRow: folderRow, urls: [dragged], sourceMask: plain))
            list.isReadOnly = false
            check("\(mode): hovering the folder springs it open",
                  list.activateSpringLoading(atRow: folderRow, urls: [dragged], sourceMask: plain))
        } else {
            guard let grid = left.fileView as? IconGridViewController else {
                check("\(mode): the grid is mounted", false); return
            }
            guard let folderPath = indexPath(of: alpha, in: grid),
                  let filePath = indexPath(of: root.appendingPathComponent("note.txt"), in: grid) else {
                check("\(mode): the fixture items are laid out", false,
                      "sections=\(grid.collectionView.numberOfSections)")
                return
            }
            check("\(mode): a file icon never springs open",
                  !grid.activateSpringLoading(at: filePath, urls: [dragged], sourceMask: plain))
            check("\(mode): a folder already holding the drag never springs open",
                  !grid.activateSpringLoading(at: folderPath, urls: [alpha.appendingPathComponent("inner.txt")], sourceMask: plain))
            check("\(mode): an ended drag never springs open",
                  !grid.activateSpringLoading(at: folderPath, urls: [], sourceMask: plain))
            check("\(mode): an index path outside the grid never springs open",
                  !grid.activateSpringLoading(at: IndexPath(item: 99, section: 99), urls: [dragged], sourceMask: plain))
            grid.isReadOnly = true
            check("\(mode): a read-only pane never springs open",
                  !grid.activateSpringLoading(at: folderPath, urls: [dragged], sourceMask: plain))
            grid.isReadOnly = false
            check("\(mode): hovering the folder springs it open",
                  grid.activateSpringLoading(at: folderPath, urls: [dragged], sourceMask: plain))
        }

        check("\(mode): exactly the hovered folder was reported once",
              sprung.map { $0.standardizedFileURL } == [alpha.standardizedFileURL], sprung.map(\.path).description)
        await listed(left, at: alpha)
        check("\(mode): the pane navigated into the sprung folder",
              left.currentURL?.standardizedFileURL == alpha.standardizedFileURL, left.currentURL?.path ?? "nil")
        check("\(mode): the other pane of the split did not move",
              right.currentURL?.standardizedFileURL == other.standardizedFileURL)
        check("\(mode): spring loading moved no files",
              fm.fileExists(atPath: dragged.path) && fm.fileExists(atPath: root.appendingPathComponent("note.txt").path))
    }

    // MARK: - Places sidebar and folder tree

    @MainActor private static func sidebarAndFolderTree(in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("Tree")
        let alpha = root.appendingPathComponent("Alpha")
        try fm.createDirectory(at: alpha.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        let dragged = fixture.appendingPathComponent("sidebar-dragged.txt")
        try Data("sidebar".utf8).write(to: dragged)

        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("tree.json"))
        let places = PlacesModel()
        // Root the folder tree inside the fixture instead of the user's Home,
        // so the test never enumerates real folders.
        let wc = MainWindowController(provider: RootedProvider(home: root), places: places,
                                      initialURL: root, viewPropertiesStore: store)
        defer { wc.close() }
        wc.window?.setContentSize(NSSize(width: 1280, height: 720))
        await listed(wc.browser, at: root)
        places.addFavourite(alpha)
        await waitUntil("the sidebar shows the new favourite") { wc.sidebar.row(for: alpha) >= 0 }

        var sprung: [URL] = []
        wc.sidebar.onSpringLoad = { sprung.append($0) }
        let plain: NSDragOperation = [.copy, .move, .generic]
        let placeRow = wc.sidebar.row(for: alpha)
        check("sidebar: the favourite has a row", placeRow >= 0, "\(placeRow)")
        check("sidebar: a section header never springs open",
              !wc.sidebar.activateSpringLoading(atRow: 0, urls: [dragged], sourceMask: plain))
        check("sidebar: an ended drag never springs open",
              !wc.sidebar.activateSpringLoading(atRow: placeRow, urls: [], sourceMask: plain))
        check("sidebar: hovering a place springs it open",
              wc.sidebar.activateSpringLoading(atRow: placeRow, urls: [dragged], sourceMask: plain))
        check("sidebar: the sprung place is the one hovered",
              sprung.map { $0.standardizedFileURL } == [alpha.standardizedFileURL], sprung.map(\.path).description)
        check("sidebar: spring loading moved no files", fm.fileExists(atPath: dragged.path))

        wc.toggleFoldersPanel(nil)
        guard let panel = wc.sidebar.foldersPanel else {
            check("folder tree: the panel is created", false); return
        }
        panel.follow(root)
        await expectEventually("folder tree: the fixture root is listed", detail: {
            "root=\(panel.model.root?.url.path ?? "nil") rows=\(panel.outlineView.numberOfRows)"
        }) {
            panel.model.root?.url.standardizedFileURL == root.standardizedFileURL
                && panel.model.root?.children != nil && panel.outlineView.numberOfRows >= 2
        }
        guard let node = treeNode(for: alpha, in: panel) else {
            check("folder tree: Alpha has a row", false, "rows=\(panel.outlineView.numberOfRows)")
            return
        }
        let row = panel.outlineView.row(forItem: node)
        check("folder tree: Alpha starts collapsed", !panel.outlineView.isItemExpanded(node))
        check("folder tree: an ended drag never springs open",
              !panel.activateSpringLoading(atRow: row, urls: [], sourceMask: plain))
        check("folder tree: a row outside the tree never springs open",
              !panel.activateSpringLoading(atRow: -1, urls: [dragged], sourceMask: plain))
        check("folder tree: hovering a node expands it in place",
              panel.activateSpringLoading(atRow: row, urls: [dragged], sourceMask: plain))
        check("folder tree: the node is now open", panel.outlineView.isItemExpanded(node))
        check("folder tree: expanding did not navigate the pane",
              wc.browser.currentURL?.standardizedFileURL == root.standardizedFileURL,
              wc.browser.currentURL?.path ?? "nil")
        check("folder tree: spring loading moved no files", fm.fileExists(atPath: dragged.path))
    }

    // MARK: - Helpers

    @MainActor private static func row(of url: URL, in list: FileListViewController) -> Int? {
        let target = url.standardizedFileURL
        for row in 0..<list.tableView.numberOfRows where list.item(atRow: row)?.url.standardizedFileURL == target {
            return row
        }
        return nil
    }

    @MainActor private static func groupHeaderRow(in list: FileListViewController) -> Int? {
        for row in 0..<list.tableView.numberOfRows where list.tableView.item(atRow: row) is GroupNode { return row }
        return nil
    }

    @MainActor private static func indexPath(of url: URL, in grid: IconGridViewController) -> IndexPath? {
        let target = url.standardizedFileURL
        for section in 0..<grid.collectionView.numberOfSections {
            for item in 0..<grid.collectionView.numberOfItems(inSection: section) {
                let path = IndexPath(item: item, section: section)
                if grid.item(at: path)?.url.standardizedFileURL == target { return path }
            }
        }
        return nil
    }

    @MainActor private static func treeNode(for url: URL, in panel: FoldersPanelController) -> FolderTreeModel.Node? {
        let target = url.standardizedFileURL
        for row in 0..<panel.outlineView.numberOfRows {
            if let node = panel.outlineView.item(atRow: row) as? FolderTreeModel.Node,
               node.url.standardizedFileURL == target { return node }
        }
        return nil
    }

    /// `LocalFileProvider` rooted at a fixture, so the folder tree (which
    /// starts from Home) stays inside the test's own directory.
    private final class RootedProvider: FileProvider {
        let homeURL: URL
        private let inner = LocalFileProvider()
        init(home: URL) { homeURL = home }
        func displayName(for url: URL) -> String { inner.displayName(for: url) }
        func listDirectory(_ url: URL) throws -> [FileItem] { try inner.listDirectory(url) }
    }

    @MainActor private static func listed(_ pane: BrowserViewController, at url: URL) async {
        await waitUntil("directory listing", detail: { "\(pane.currentURL?.path ?? "nil") vs \(url.path)" }) {
            pane.currentURL?.standardizedFileURL == url.standardizedFileURL
                && pane.model.url?.standardizedFileURL == url.standardizedFileURL
                && pane.model.generation > 0 && !pane.isPreparingArchive && !pane.model.isSearchResults
        }
    }
}

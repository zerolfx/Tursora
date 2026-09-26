import AppKit

/// A failed listing must clear what the native views draw and can act on,
/// rather than only the model's primary array.
enum DirectoryLoadingSmokeTests: SmokeSuite {
    static var checkPrefix: String { "directory loading: " }

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            do { try await failedListings() }
            catch { fail("fixture", error.localizedDescription) }
            completion()
        }
    }

    private final class Provider: FileProvider {
        let homeURL: URL
        private let items: [FileItem]
        private let lock = NSLock()
        private var failure = false
        var fails: Bool {
            get { lock.lock(); defer { lock.unlock() }; return failure }
            set { lock.lock(); failure = newValue; lock.unlock() }
        }
        init(root: URL, items: [FileItem]) { homeURL = root; self.items = items }
        func displayName(for url: URL) -> String { url.lastPathComponent }
        func listDirectory(_ url: URL) throws -> [FileItem] {
            if fails { throw CocoaError(.fileReadNoSuchFile) }
            return items
        }
    }

    @MainActor private static func failedListings() async throws {
        let root = try SmokeFixtures.temporaryDirectory("failed-listing")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("retained.txt")
        try Data("original".utf8).write(to: file)
        let provider = Provider(root: root, items: [FileItem(url: file)!])
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let controller = MainWindowController(provider: provider, places: PlacesModel(), initialURL: root,
                                              viewPropertiesStore: store)
        defer { controller.close(); try? store.flush() }
        controller.window?.setContentSize(NSSize(width: 1100, height: 700))
        controller.window?.makeKeyAndOrderFront(nil)
        let pane = controller.browser
        await waitUntil("initial listing") { pane.model.items.count == 1 }
        for mode in ViewMode.allCases {
            pane.setViewMode(mode)
            pane.model.groupKey = .kind
            pane.fileView.select(urls: [file])
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            check("\(mode) selects the original row", pane.fileView.selectedItems.map(\.name) == ["retained.txt"])
            let generation = pane.model.generation
            provider.fails = true
            pane.reload()
            await waitUntil("\(mode) failed listing settles") { pane.model.generation > generation }
            check("\(mode) exposes the failed listing", pane.hasListingError)
            check("\(mode) clears primary and grouped collections",
                  pane.model.allNodes.isEmpty && pane.model.nodes.isEmpty && pane.model.groups.flatMap(\.nodes).isEmpty)
            switch mode {
            case .details:
                check("grouped details draws no stale file rows",
                      (0..<pane.fileList.tableView.numberOfRows).allSatisfy { pane.fileList.item(atRow: $0) == nil })
            case .icons:
                let collection = pane.iconGrid.collectionView
                check("icons contains no stale native collection items",
                      (0..<collection.numberOfSections).allSatisfy { collection.numberOfItems(inSection: $0) == 0 })
            case .columns:
                check("columns has no stale root row", pane.columnView.rowCountForTesting(0) == 0)
            }
            pane.fileView.select(urls: [file])
            check("\(mode) cannot select the old file after failure", pane.fileView.selectedItems.isEmpty)
            provider.fails = false
            let failedGeneration = pane.model.generation
            pane.reload()
            await waitUntil("\(mode) recovered listing settles") { pane.model.generation > failedGeneration }
            check("\(mode) clears the old error after successful Reload", !pane.hasListingError)
            check("\(mode) restores consistent arrays on recovery",
                  pane.model.items.map(\.name) == ["retained.txt"]
                    && pane.model.groups.flatMap(\.nodes).map(\.item.name) == ["retained.txt"])
        }
        // Icons use groups even when the grouping feature is disabled.
        pane.setViewMode(.icons)
        pane.model.groupKey = .none
        let generation = pane.model.generation
        provider.fails = true
        pane.reload()
        await waitUntil("ungrouped icon failure settles") { pane.model.generation > generation }
        check("ungrouped icons also discard all group-backed rows",
              pane.model.groups.flatMap(\.nodes).isEmpty
                && (0..<pane.iconGrid.collectionView.numberOfSections).allSatisfy {
                    pane.iconGrid.collectionView.numberOfItems(inSection: $0) == 0
                })
    }
}

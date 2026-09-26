import AppKit

/// Restored view state belongs to one navigation/query, not merely to a URL
/// that a later search happens to reuse.
enum WorkspaceRaceSmokeTests: SmokeSuite {
    static let checkPrefix = "workspace races: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            do {
                try await searchRestoration()
                try ancestorBoundaries()
                try await descendantRestoration()
            } catch { fail("fixture", String(describing: error)) }
            completion()
        }
    }

    private static func paths(_ urls: [URL]) -> [String] { urls.map { $0.standardizedFileURL.path } }

    @MainActor private static func stateDescription(_ pane: BrowserViewController) -> String {
        "status=\(pane.searchSession.status) searching=\(pane.isSearching) mode=\(pane.viewMode) "
            + "location=\(pane.currentURL?.absoluteString ?? "nil") model=\(pane.model.url?.absoluteString ?? "nil") "
            + "listingError=\(pane.hasListingError) pending=\(String(describing: pane.pendingWorkspaceView)) "
            + "rows=\(paths(pane.model.items.map(\.url))) selected=\(paths(pane.fileView.selectedItems.map(\.url))) "
            + "rawSelection=\(pane.fileView.selectedItems.map(\.url))"
    }

    @MainActor private static func close(_ controller: MainWindowController, store: DirectoryViewPropertiesStore) {
        controller.browser.searchSession.cancel()
        for pane in controller.tabs.pages.flatMap(\.panes) {
            pane.model.folderSizes.cancel()
            pane.model.onChange = nil
        }
        controller.close()
        try? store.flush()
    }

    @MainActor private static func searchRestoration() async throws {
        let fm = FileManager.default
        let root = try SmokeFixtures.temporaryDirectory("workspace-races").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("Files")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let a = folder.appendingPathComponent("a.md")
        let b = folder.appendingPathComponent("b.md")
        try Data("# A".utf8).write(to: a)
        try Data("# B".utf8).write(to: b)
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: folder, viewPropertiesStore: store)
        defer { close(wc, store: store) }
        wc.window?.setContentSize(NSSize(width: 1100, height: 700))
        wc.window?.makeKeyAndOrderFront(nil)
        let pane = wc.browser
        try await requireEventually("the ordinary folder is loaded") { pane.model.items.count == 2 }
        let snapshot = WorkspacePaneViewState(mode: .details, selectedURLs: [a], scrollOffset: 120)
        let restored = WorkspacePaneState(url: folder, search: SearchRequest(rootURL: folder, name: "a.md"), viewState: snapshot)

        // Search events are delivered on a later main-queue turn. Replacing
        // A with B here deterministically supersedes it before completion.
        restored.restoreWorkspacePane(in: pane)
        try require("the original search has a pending view snapshot", pane.pendingWorkspaceView != nil)
        pane.startSearch(SearchRequest(rootURL: folder, name: ".md"))
        try require("a new query discards the old selection immediately", pane.pendingWorkspaceView == nil)
        try await requireEventually("the replacement query finishes") { !pane.searchSession.status.isSearching }
        try require("overlapping replacement results do not select an old saved item",
                    pane.model.items.count == 2 && pane.fileView.selectedItems.isEmpty)

        let missing = root.appendingPathComponent("Offline")
        let recovered = missing.appendingPathComponent("return.md")
        WorkspacePaneState(url: missing, search: SearchRequest(rootURL: missing, name: "return.md"),
            viewState: WorkspacePaneViewState(mode: .details, selectedURLs: [recovered]))
            .restoreWorkspacePane(in: pane)
        try await requireEventually("the offline restored search fails") {
            if case .failed = pane.searchSession.status { return true }
            return false
        }
        try require("failure preserves its snapshot for Retry", paths(pane.pendingWorkspaceView?.state.selectedURLs ?? []) == paths([recovered]))
        try fm.createDirectory(at: missing, withIntermediateDirectories: false)
        try Data("# Back online".utf8).write(to: recovered)
        pane.reload()
        try await requireEventually("a successful retry restores the selected result", detail: { stateDescription(pane) }) {
            pane.pendingWorkspaceView == nil && paths(pane.fileView.selectedItems.map(\.url)) == paths([recovered])
        }

        restored.restoreWorkspacePane(in: pane)
        pane.searchPanel.onCancel?()
        try require("intentional Cancel abandons the saved view state",
                    pane.pendingWorkspaceView == nil && pane.searchSession.status == .cancelled)
        restored.restoreWorkspacePane(in: pane)
        pane.navigate(to: root)
        try require("a navigation abandons the pending query view immediately", pane.pendingWorkspaceView == nil)
        try await requireEventually("navigation wins over queued search completions", detail: { stateDescription(pane) }) {
            !pane.isSearching && pane.model.url?.standardizedFileURL.path == root.path
                && pane.model.items.contains { $0.url.standardizedFileURL.path == folder.path }
        }

        pane.navigate(to: folder)
        pane.startSearch(SearchRequest(rootURL: folder, name: "b.md"))
        try await requireEventually("the preview search completes", detail: { stateDescription(pane) }) {
            !pane.searchSession.status.isSearching && paths(pane.model.items.map(\.url)) == paths([b])
        }
        wc.togglePreviewPane(nil)
        pane.fileView.select(urls: [b])
        try require("the selected search result has a Markdown preview", wc.previewPanel?.renderedTextForTesting.contains("B") == true)
        let generation = pane.searchSession.generation
        try Data("# Changed externally in a search result".utf8).write(to: b, options: .atomic)
        try await requireEventually("external edits refresh an unchanged search result preview", timeout: 8, detail: {
            stateDescription(pane) + " preview=\(wc.previewPanel?.renderedTextForTesting ?? "nil") "
                + "disk=\((try? String(contentsOf: b)) ?? "unreadable")"
        }) {
            wc.previewPanel?.renderedTextForTesting.contains("Changed externally in a search result") == true
        }
        try require("preview invalidation does not rerun the recursive search", pane.searchSession.generation == generation)
    }

    @MainActor private static func ancestorBoundaries() throws {
        func ancestors(_ selected: String, _ root: String) -> [String] {
            BrowserViewController.workspaceSelectionAncestors(
                of: URL(fileURLWithPath: selected), under: URL(fileURLWithPath: root)).map(\.path)
        }
        try require("filesystem root includes every selected descendant ancestor",
            ancestors("/Users/owner/Folder/file.txt", "/") == ["/Users", "/Users/owner", "/Users/owner/Folder"])
        try require("restoration excludes its listing root from expansion",
            ancestors("/Root/Outer/Inner/file.txt", "/Root") == ["/Root/Outer", "/Root/Outer/Inner"])
        try require("a sibling with a shared path prefix is outside the listing",
            ancestors("/Rootly/file.txt", "/Root").isEmpty)
        try require("a direct child needs no ancestor expansion",
            ancestors("/file.txt", "/").isEmpty && ancestors("/Root/file.txt", "/Root").isEmpty)
    }

    @MainActor private static func descendantRestoration() async throws {
        // The native outline expands ordinary directories. macOS's /var is a
        // symlink and cannot stand in for an expandable root-level fixture.
        let root = try SmokeFixtures.temporaryDirectory("workspace-descendant-selection").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = root.appendingPathComponent("Outer", isDirectory: true)
        let inner = outer.appendingPathComponent("Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let leaf = inner.appendingPathComponent("selected.txt")
        try Data("selection".utf8).write(to: leaf)
        var defaults = DirectoryViewProperties()
        defaults.viewMode = .details
        defaults.showHidden = true
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"), initialDefaults: defaults)
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root, viewPropertiesStore: store)
        defer { close(wc, store: store) }
        wc.window?.makeKeyAndOrderFront(nil)
        WorkspacePaneState(url: root,
            viewState: WorkspacePaneViewState(mode: .details, selectedURLs: [leaf])).restoreWorkspacePane(in: wc.browser)
        try await requireEventually("restoration selects the exact nested descendant", detail: { stateDescription(wc.browser) }) {
            wc.browser.pendingWorkspaceView == nil && paths(wc.browser.fileView.selectedItems.map(\.url)) == paths([leaf])
        }
        try require("the native outline expands both selected descendant ancestors",
            Set(paths(wc.browser.fileList.expandedFolderURLs)) == Set(paths([outer, inner])))
        try require("descendant restoration does not navigate away", wc.browser.currentURL?.standardizedFileURL.path == root.path)
    }
}

import AppKit

/// Cross-feature regressions: search stays transient while directory defaults,
/// ordinary peers and cancellable file transfers retain their own identities.
enum IntegratedSearchSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("tursora-integrated-search-" + UUID().uuidString)
                .resolvingSymlinksInPath()
            defer {
                try? FileManager.default.removeItem(at: fixture)
                TransferTasksWindowController.shared.clearFinished(nil)
            }
            do {
                try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                for policy: DirectoryViewPropertiesStore.Policy in [.perDirectory, .unified] {
                    try await transientViews(policy: policy, in: fixture)
                }
                try await linkedSources(in: fixture)
                for mode: ViewMode in [.details, .icons] {
                    try await resultTransfers(mode: mode, in: fixture)
                }
                completion()
            } catch {
                check("fixtures complete", false, error.localizedDescription)
            }
        }
    }

    private static var folderProperties: DirectoryViewProperties {
        var value = DirectoryViewProperties()
        value.viewMode = .details
        value.detailsZoomIndex = 1
        value.iconsZoomIndex = 2
        value.sortKey = .dateModified
        value.ascending = true
        value.groupKey = .none
        value.lastGroupKey = .kind
        value.showHidden = false
        value.showPreviews = true
        return value
    }

    private static var searchProperties: DirectoryViewProperties {
        var value = DirectoryViewProperties()
        value.viewMode = .icons
        value.detailsZoomIndex = 3
        value.iconsZoomIndex = 4
        value.sortKey = .size
        value.ascending = false
        value.groupKey = .kind
        value.lastGroupKey = .kind
        value.showHidden = true
        value.showPreviews = false
        return value
    }

    @MainActor private static func transientViews(policy: DirectoryViewPropertiesStore.Policy,
                                                   in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("views-\(policy.rawValue)")
        let nested = root.appendingPathComponent("Nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested search result".utf8).write(to: nested.appendingPathComponent("needle.txt"))
        try Data("ordinary source selection".utf8).write(to: root.appendingPathComponent("ordinary.txt"))
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("\(policy.rawValue)-views.json"),
                                                 initialDefaults: folderProperties)
        let key = DirectoryViewPropertiesStore.directoryKey(for: root)!
        store.save(folderProperties, forKey: key)
        store.setPolicy(policy)
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                      viewPropertiesStore: store)
        defer { wc.close() }
        let browser = wc.browser
        await listed(browser, at: root)
        wc.tabs.toggleSplit()
        let peer = wc.browser
        await listed(peer, at: root)
        wc.tabs.currentPage.activate(browser)
        browser.fileView.select(name: "ordinary.txt")
        let request = SearchRequest(rootURL: root, name: "needle")
        browser.startSearch(request)
        await searched(browser)
        apply(searchProperties, to: browser)
        check("\(policy): changing every search view property stays temporary",
              browser.currentViewProperties == searchProperties
              && store.properties(forKey: key) == folderProperties
              && store.defaultProperties == folderProperties
              && peer.currentViewProperties == folderProperties
              && browser.isSearching && !peer.isSearching)
        let defaultAction = NSMenuItem(title: "", action: #selector(MainWindowController.useCurrentViewAsDefault(_:)), keyEquivalent: "")
        let resetAction = NSMenuItem(title: "", action: #selector(MainWindowController.restoreFolderViewDefaults(_:)), keyEquivalent: "")
        check("\(policy): search disables directory default and reset menu entries",
              wc.validateViewPropertiesMenuItem(defaultAction) == false
              && wc.validateViewPropertiesMenuItem(resetAction) == false)
        // Direct dispatch checks the action guard independently of menu validation.
        wc.useCurrentViewAsDefault(nil)
        wc.restoreFolderViewDefaults(nil)
        check("\(policy): search default and reset actions cannot change stored folders",
              store.defaultProperties == folderProperties && store.hasOverride(forKey: key)
              && store.properties(forKey: key) == folderProperties)
        browser.reload()
        await searched(browser)
        browser.refreshPreservingSelection()
        await searched(browser)
        check("\(policy): explicit and notification refreshes preserve search context and temporary view",
              browser.isSearching && browser.model.isSearchResults && browser.model.url == nil
              && browser.searchSession.request == request && browser.currentViewProperties == searchProperties)
        browser.closeSearch()
        await listed(browser, at: root)
        check("\(policy): closing search restores the folder view and original selection",
              browser.currentViewProperties == folderProperties
              && browser.fileView.selectedItems.map(\.name) == ["ordinary.txt"]
              && peer.currentViewProperties == folderProperties)

        // An explicit Settings/default change may update ordinary panes, but it
        // must not overwrite a search view or persist that view in response.
        browser.startSearch(request)
        await searched(browser)
        apply(searchProperties, to: browser)
        var newDefault = folderProperties
        newDefault.sortKey = .name
        newDefault.ascending = false
        store.setDefault(newDefault)
        if policy == .perDirectory { store.reset(key: key) }
        check("\(policy): global default and folder reset notifications leave search views untouched",
              browser.currentViewProperties == searchProperties && browser.isSearching
              && peer.currentViewProperties == newDefault && store.defaultProperties == newDefault)
        browser.closeSearch()
        await listed(browser, at: root)
        check("\(policy): leaving search picks up the newly chosen directory default",
              browser.currentViewProperties == newDefault && store.properties(forKey: key) == newDefault)
        try store.flush()
    }

    @MainActor private static func linkedSources(in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("linked-transfer-sources")
        let folder = root.appendingPathComponent("target")
        let destination = root.appendingPathComponent("destination")
        for url in [folder, destination] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let file = folder.appendingPathComponent("child.txt")
        let link = root.appendingPathComponent("linked-folder")
        let linkedChild = link.appendingPathComponent(file.lastPathComponent)
        let bytes = Data("explicit linked child must be copied separately".utf8)
        try bytes.write(to: file)
        try fm.createSymbolicLink(at: link, withDestinationURL: folder)
        let task = TransferTask(sources: [link, linkedChild, link], destination: destination, kind: .copy)
        check("task normalization retains a symbolic link and its explicit child as separate sources",
              task.sources.map(\.standardizedFileURL) == [link, linkedChild].map(\.standardizedFileURL))
        var result: FileOperations.TransferResult?
        FileOperations.transfer([link, linkedChild, link], to: destination, kind: .copy,
                                conflict: { _ in .init(resolution: .cancel) }, task: task) { result = $0 }
        await wait("linked source transfer completes") { result != nil }
        let copiedLink = destination.appendingPathComponent(link.lastPathComponent)
        let copiedChild = destination.appendingPathComponent(file.lastPathComponent)
        check("the real worker copies a link once plus its separately selected child",
              task.snapshot.state == .completed && result?.failures.isEmpty == true
              && paths(result?.created ?? []) == paths([copiedLink, copiedChild])
              && (try? fm.destinationOfSymbolicLink(atPath: copiedLink.path)) == folder.path
              && (try? Data(contentsOf: copiedChild)) == bytes && (try? Data(contentsOf: file)) == bytes)

        let container = root.appendingPathComponent("container")
        let secondDestination = root.appendingPathComponent("intermediate-link-destination")
        for url in [container, secondDestination] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
        let ordinaryChild = container.appendingPathComponent("ordinary.txt")
        try Data("included by the selected directory".utf8).write(to: ordinaryChild)
        let intermediateLink = container.appendingPathComponent("external")
        let externalChild = intermediateLink.appendingPathComponent(file.lastPathComponent)
        try fm.createSymbolicLink(at: intermediateLink, withDestinationURL: folder)
        let inputs = [container, ordinaryChild, externalChild, container, externalChild]
        let intermediateTask = TransferTask(sources: inputs, destination: secondDestination, kind: .copy)
        check("a selected directory retains an explicit child reached through an intermediate symlink",
              intermediateTask.sources == [container, externalChild].map(\.standardizedFileURL))
        check("intermediate-link source filtering preserves surviving input order",
              FileOperations.mutationSources([externalChild, ordinaryChild, container, externalChild]) == [externalChild, container])
        var intermediateResult: FileOperations.TransferResult?
        FileOperations.transfer(inputs, to: secondDestination, kind: .copy,
                                conflict: { _ in .init(resolution: .cancel) }, task: intermediateTask) { intermediateResult = $0 }
        await wait("intermediate linked child transfer completes") { intermediateResult != nil }
        let copiedContainer = secondDestination.appendingPathComponent(container.lastPathComponent)
        let standaloneChild = secondDestination.appendingPathComponent(file.lastPathComponent)
        check("the worker publishes the directory tree and its separately selected external child",
              intermediateTask.snapshot.state == .completed && intermediateResult?.failures.isEmpty == true
              && paths(intermediateResult?.created ?? []) == paths([copiedContainer, standaloneChild])
              && (try? String(contentsOf: copiedContainer.appendingPathComponent(ordinaryChild.lastPathComponent))) == "included by the selected directory"
              && (try? fm.destinationOfSymbolicLink(atPath: copiedContainer.appendingPathComponent(intermediateLink.lastPathComponent).path)) == folder.path
              && (try? Data(contentsOf: standaloneChild)) == bytes && (try? Data(contentsOf: file)) == bytes)

        // A selected real directory below a symlink still covers its own ordinary
        // children: only the path between that selection and its child matters.
        let nestedTarget = folder.appendingPathComponent("nested")
        try fm.createDirectory(at: nestedTarget, withIntermediateDirectories: false)
        try bytes.write(to: nestedTarget.appendingPathComponent("nested.txt"))
        let linkedNested = intermediateLink.appendingPathComponent("nested")
        let nestedChild = linkedNested.appendingPathComponent("nested.txt")
        check("a selected actual directory below a link still deduplicates its direct child",
              FileOperations.mutationSources([nestedChild, linkedNested]) == [linkedNested])
    }

    @MainActor private static func resultTransfers(mode: ViewMode, in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("transfers-\(mode.rawValue)/source")
        let firstParent = root.appendingPathComponent("First")
        let secondParent = root.appendingPathComponent("Second")
        let tree = root.appendingPathComponent("needle-tree")
        let destination = root.deletingLastPathComponent().appendingPathComponent("destination")
        for folder in [firstParent, secondParent, tree, destination] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let first = firstParent.appendingPathComponent("needle.bin")
        let second = secondParent.appendingPathComponent("needle.bin")
        let child = tree.appendingPathComponent("needle-child.bin")
        let firstBytes = Data(repeating: 0x35, count: 2 * 1024 * 1024)
        let secondBytes = Data(repeating: 0xA7, count: firstBytes.count)
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)
        try firstBytes.write(to: child)
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("transfer-\(mode.rawValue)-views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                      viewPropertiesStore: store)
        defer { wc.close() }
        let browser = wc.browser
        await listed(browser, at: root)
        wc.tabs.openInOtherPane(destination)
        let peer = wc.browser
        await listed(peer, at: destination)
        wc.tabs.currentPage.activate(browser)
        browser.startSearch(SearchRequest(rootURL: root, name: "needle"))
        await searched(browser)
        browser.setViewMode(mode)
        browser.setGroupKey(.kind)
        browser.nameFilter = "needle"
        browser.transferOptions.blockSize = 32 * 1024
        browser.transferOptions.chunkDelay = 0.004
        browser.fileView.select(urls: [first, second])
        check("\(mode): recursive same-name selection keeps both exact source URLs",
              paths(browser.fileView.selectedItems.map(\.url)) == paths([first, second]))
        browser.duplicate(nil)
        guard let task = browser.lastTransferTask,
              let row = TransferTasksWindowController.shared.row(for: task.id),
              let undo = wc.window?.undoManager else {
            check("\(mode): search Duplicate starts the shared task controls", false); return
        }
        await wait("\(mode) duplicate reaches interior bytes") { task.snapshot.completedBytes >= 64 * 1024 && !task.snapshot.isTerminal }
        TransferTasksWindowController.shared.refresh()
        row.pauseButton.performClick(nil)
        await wait("\(mode) duplicate pause is acknowledged") { task.snapshot.state == .paused }
        TransferTasksWindowController.shared.refresh()
        let pausedBytes = task.snapshot.completedBytes
        try await Task.sleep(nanoseconds: 80_000_000)
        check("\(mode): search Duplicate pauses inside a file without changing the query",
              task.snapshot.completedBytes == pausedBytes && browser.isSearching && row.pauseButton.title == "Resume")
        row.pauseButton.performClick(nil)
        let firstCopy = firstParent.appendingPathComponent("needle copy.bin")
        let secondCopy = secondParent.appendingPathComponent("needle copy.bin")
        await wait("\(mode) duplicate publishes beside each real source and registers undo") {
            task.snapshot.isTerminal && undo.canUndo && exists(firstCopy) && exists(secondCopy)
                && !browser.searchSession.status.isSearching
        }
        check("\(mode): completed same-name Duplicate preserves bytes and full-URL result selection",
              task.snapshot.state == .completed
              && (try? Data(contentsOf: firstCopy)) == firstBytes && (try? Data(contentsOf: secondCopy)) == secondBytes
              && paths(browser.fileView.selectedItems.map(\.url)) == paths([firstCopy, secondCopy])
              && browser.isSearching && browser.viewMode == mode && browser.groupKey == .kind && browser.nameFilter == "needle")
        undo.undo()
        await wait("\(mode) duplicate undo refreshes recursive results") {
            !exists(firstCopy) && !exists(secondCopy) && !browser.searchSession.status.isSearching
                && !browser.model.items.contains { paths([firstCopy, secondCopy]).contains($0.url.standardizedFileURL.path) }
        }
        check("\(mode): search Duplicate undo preserves both original same-name files",
              (try? Data(contentsOf: first)) == firstBytes && (try? Data(contentsOf: second)) == secondBytes && browser.isSearching)
        undo.removeAllActions()

        // Copy a selected parent and child through the actual other-pane action.
        // Cancellation must remove its staged subtree without touching sources.
        browser.fileView.select(urls: [tree, child])
        browser.copyToOtherPane(nil)
        guard let cancelled = browser.lastTransferTask, cancelled.id != task.id,
              let cancelRow = TransferTasksWindowController.shared.row(for: cancelled.id) else {
            check("\(mode): search parent/child Copy starts an independent task", false); return
        }
        await wait("\(mode) subtree copy reaches interior bytes") { cancelled.snapshot.completedBytes >= 64 * 1024 && !cancelled.snapshot.isTerminal }
        cancelRow.cancelButton.performClick(nil)
        await wait("\(mode) cancelled subtree is cleaned") { cancelled.snapshot.isTerminal }
        await searched(browser)
        check("\(mode): cancelling parent/child search Copy preserves sources and publishes no partial tree",
              cancelled.snapshot.state == .cancelled
              && (try? fm.contentsOfDirectory(atPath: destination.path)) == []
              && (try? Data(contentsOf: child)) == firstBytes && !undo.canUndo && browser.isSearching)

        browser.fileView.select(urls: [tree, child])
        browser.copyToOtherPane(nil)
        guard let copied = browser.lastTransferTask, copied.id != cancelled.id else {
            check("\(mode): second parent/child Copy starts a new task", false); return
        }
        let copiedTree = destination.appendingPathComponent(tree.lastPathComponent)
        let copiedChild = copiedTree.appendingPathComponent(child.lastPathComponent)
        await wait("\(mode) parent/child Copy completes once") {
            copied.snapshot.isTerminal && undo.canUndo && exists(copiedChild)
        }
        await wait("\(mode) destination pane sees copied tree") { peer.model.items.contains { $0.url.standardizedFileURL == copiedTree.standardizedFileURL } }
        check("\(mode): overlapping recursive Copy publishes one complete subtree with a single byte total",
              copied.snapshot.state == .completed && copied.snapshot.totalBytes == Int64(firstBytes.count)
              && copied.snapshot.completedBytes == Int64(firstBytes.count)
              && (try? fm.contentsOfDirectory(atPath: destination.path)) == [tree.lastPathComponent]
              && (try? Data(contentsOf: copiedChild)) == firstBytes && browser.isSearching)
        undo.undo()
        await wait("\(mode) subtree Copy undo refreshes the destination") {
            !exists(copiedTree) && peer.model.items.isEmpty && !browser.searchSession.status.isSearching
        }
        check("\(mode): subtree Copy Undo retains recursive source identity and active query",
              (try? Data(contentsOf: child)) == firstBytes && exists(tree) && browser.isSearching)
    }

    @MainActor private static func apply(_ properties: DirectoryViewProperties, to browser: BrowserViewController) {
        browser.setViewMode(.details)
        browser.setZoomIndex(properties.detailsZoomIndex)
        browser.setViewMode(.icons)
        browser.setZoomIndex(properties.iconsZoomIndex)
        browser.setViewMode(properties.viewMode)
        browser.fileList.setSort(key: properties.sortKey, ascending: properties.ascending)
        browser.setGroupKey(properties.groupKey)
        browser.showsHiddenFiles = properties.showHidden
        browser.setShowsPreviews(properties.showPreviews)
    }

    @MainActor private static func listed(_ browser: BrowserViewController, at url: URL) async {
        await wait("directory listing") {
            browser.currentURL?.standardizedFileURL == url.standardizedFileURL
                && browser.model.url?.standardizedFileURL == url.standardizedFileURL
                && browser.model.generation > 0 && !browser.model.isSearchResults
                && browser.model.items.allSatisfy { $0.url.deletingLastPathComponent().standardizedFileURL == url.standardizedFileURL }
        }
        browser.view.layoutSubtreeIfNeeded()
    }

    @MainActor private static func searched(_ browser: BrowserViewController) async {
        await wait("recursive search finishes", detail: { browser.searchSession.status.message }) {
            browser.isSearching && browser.model.isSearchResults && !browser.searchSession.status.isSearching
        }
        guard case .finished = browser.searchSession.status else {
            check("recursive search succeeds", false, browser.searchSession.status.message); return
        }
        browser.view.layoutSubtreeIfNeeded()
    }

    @MainActor private static func wait(_ name: String, detail: () -> String = { "" }, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > deadline { check(name, false, detail()); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private static func paths(_ urls: [URL]) -> Set<String> { Set(urls.map { $0.standardizedFileURL.path }) }
    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        print("\(success ? "ok  " : "FAIL") integrated search: \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !success { fflush(stdout); exit(1) }
    }
}

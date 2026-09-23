import AppKit

/// Deterministic search conditions and lifecycle checks, followed by real pane actions.
/// Spotlight result timing is deliberately excluded: the system index is not a fixture.
enum SearchSmokeTests: SmokeSuite {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            await runChecks()
            completion()
        }
    }

    @MainActor private static func runChecks() async {
        print("== recursive and saved search ==")
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("tursora-search-" + UUID().uuidString).resolvingSymlinksInPath()
        let defaultsName = "Tursora.SearchSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        let previousZIP = AppPreferences.experimentalZIPBrowsingEnabled
        var window: MainWindowController?
        defer {
            window?.close()
            AppPreferences.experimentalZIPBrowsingEnabled = previousZIP
            defaults.removePersistentDomain(forName: defaultsName)
            try? fm.removeItem(at: fixture)
        }
        do {
            let root = fixture.appendingPathComponent("Root")
            let firstDirectory = root.appendingPathComponent("First")
            let secondDirectory = root.appendingPathComponent("Second/Deep")
            let outside = fixture.appendingPathComponent("Outside")
            let packageContents = root.appendingPathComponent("Sample.app/Contents")
            for directory in [firstDirectory, secondDirectory, outside, packageContents] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let stamp = Date(timeIntervalSince1970: 1_700_000_000)
            func write(_ url: URL, _ contents: String, date: Date? = nil) throws {
                try Data(contents.utf8).write(to: url)
                try fm.setAttributes([.modificationDate: date ?? stamp], ofItemAtPath: url.path)
            }
            let rootFile = root.appendingPathComponent("needle.txt")
            let firstFile = firstDirectory.appendingPathComponent("needle.txt")
            let secondFile = secondDirectory.appendingPathComponent("needle.txt")
            let contentOnly = root.appendingPathComponent("ordinary.txt")
            let oldFile = root.appendingPathComponent("needle-old.txt")
            let picture = root.appendingPathComponent("needle.png")
            let matchingFolder = root.appendingPathComponent("needle folder")
            try write(rootFile, "root marker")
            try write(firstFile, "first marker")
            try write(secondFile, "second marker")
            try write(contentOnly, "A NEEDLE is in this body; café.")
            try write(oldFile, "old marker", date: stamp.addingTimeInterval(-86_400))
            try write(picture, "image fixture identified by its extension")
            try fm.createDirectory(at: matchingFolder, withIntermediateDirectories: false)
            try write(matchingFolder.appendingPathComponent("inside.txt"), "not part of the folder-name results")
            try write(outside.appendingPathComponent("needle-outside.txt"), "outside the requested root")
            try write(packageContents.appendingPathComponent("needle.txt"), "inside an excluded package")
            try fm.createSymbolicLink(at: root.appendingPathComponent("portal"), withDestinationURL: outside)

            let rootItem = FileItem(url: rootFile)!
            let contentItem = FileItem(url: contentOnly)!
            let oldItem = FileItem(url: oldFile)!
            let imageItem = FileItem(url: picture)!
            let folderItem = FileItem(url: matchingFolder)!
            let fileRequest = SearchRequest(rootURL: root, name: "needle.txt")
            let contentRequest = SearchRequest(rootURL: root, content: "needle")
            let combined = SearchRequest(rootURL: root, name: "needle", kind: .document,
                                         modifiedAfter: stamp, modifiedBefore: stamp.addingTimeInterval(1))
            check("search name conditions match case-insensitively", SearchRequest(rootURL: root, name: "NEEDLE").matchesMetadata(rootItem))
            check("name search does not inspect file contents", !fileRequest.matchesMetadata(contentItem))
            check("content search does not substitute a matching filename", !contentRequest.matches(rootItem, contentText: "root marker"))
            check("content search matches an unrelated filename's body", contentRequest.matches(contentItem, contentText: "A NEEDLE is in this body"))
            check("content matching folds diacritics", SearchRequest(rootURL: root, content: "CAFE").matches(contentItem, contentText: "café"))
            check("content search never fabricates unavailable text", !contentRequest.matches(contentItem, contentText: nil))
            check("combined name, document and date conditions include the lower bound", combined.matchesMetadata(rootItem))
            check("combined conditions exclude stale modification dates", !combined.matchesMetadata(oldItem))
            check("combined conditions exclude images and folders", !combined.matchesMetadata(imageItem) && !combined.matchesMetadata(folderItem))
            check("modification upper bound is exclusive", !SearchRequest(rootURL: root, modifiedBefore: stamp).matchesMetadata(rootItem))
            check("folder type condition excludes regular files", SearchRequest(rootURL: root, kind: .folder).matchesMetadata(folderItem) && !SearchRequest(rootURL: root, kind: .folder).matchesMetadata(rootItem))
            check("broader search resolves the home scope explicitly", SearchRequest(rootURL: root, scope: .home).effectiveRootURL.standardizedFileURL == fm.homeDirectoryForCurrentUser.standardizedFileURL)
            let quoted = SearchRequest(rootURL: root, name: "\" OR TRUEPREDICATE OR \"")
            check("Spotlight binds quoted names as data instead of predicate syntax", !quoted.metadataPredicate.evaluate(with: ["kMDItemFSName": "ordinary.txt"]) && quoted.metadataPredicate.evaluate(with: ["kMDItemFSName": quoted.name]))
            check("name-only searches select traversal while content selects Spotlight", !fileRequest.usesSpotlight && contentRequest.usesSpotlight && !SearchRequest(rootURL: root, content: " \n ").usesSpotlight)
            check("Search reserves Shift Command F without changing the default filter shortcut", AppPreferences.Shortcut(keyEquivalent: "f", modifierFlags: [.command, .shift]).validationError() != nil && AppPreferences.Shortcut.defaultFilter == AppPreferences.Shortcut(keyEquivalent: "f", modifierFlags: .command))
            let predicateCases: [(String, SearchRequest)] = [
                ("empty", SearchRequest(rootURL: root)),
                ("name only", fileRequest),
                ("content only", contentRequest),
                ("PDF only", SearchRequest(rootURL: root, kind: .pdf)),
                ("content and PDF", SearchRequest(rootURL: root, content: "needle", kind: .pdf)),
                ("content and image", SearchRequest(rootURL: root, content: "needle", kind: .image)),
                ("content and folder", SearchRequest(rootURL: root, content: "needle", kind: .folder)),
                ("content and document", SearchRequest(rootURL: root, content: "needle", kind: .document)),
                ("date only", SearchRequest(rootURL: root, modifiedAfter: stamp)),
                ("content and dates", SearchRequest(rootURL: root, content: "needle", modifiedAfter: stamp, modifiedBefore: stamp.addingTimeInterval(1))),
                ("content, kind and dates", SearchRequest(rootURL: root, content: "needle", kind: .pdf, modifiedAfter: stamp, modifiedBefore: stamp.addingTimeInterval(1))),
            ]
            for (label, request) in predicateCases {
                let predicate = request.metadataPredicate
                check("Spotlight \(label) predicate has no invalid singleton compound groups", validCompoundGroups(predicate), predicate.predicateFormat)
            }
            let unrestrictedPredicate = SearchRequest(rootURL: root).metadataPredicate
            check("unrestricted Spotlight conditions use a native comparison instead of TRUEPREDICATE", unrestrictedPredicate is NSComparisonPredicate && unrestrictedPredicate.evaluate(with: ["kMDItemFSName": "any-name.txt"]))
            mutationSources(root: root)

            let savedStore = SavedSearchStore(defaults: defaults)
            let saved = savedStore.save(name: "Recent named documents", request: combined)
            let reopened = SavedSearchStore(defaults: defaults)
            check("saved search survives a fresh store instance with all conditions", reopened.items.first?.request == combined && reopened.items.first?.name == saved.name)
            let encoded = try JSONEncoder().encode(SearchRequest(rootURL: root, scope: .home, name: "literal \"needle\"", content: "body", kind: .pdf,
                                                                modifiedAfter: stamp, modifiedBefore: stamp.addingTimeInterval(100)))
            let decoded = try JSONDecoder().decode(SearchRequest.self, from: encoded)
            check("search serialization preserves scope, quotes, content, type and date bounds", decoded.scope == .home && decoded.rootURL == root && decoded.name == "literal \"needle\"" && decoded.content == "body" && decoded.kind == .pdf && decoded.modifiedAfter == stamp && decoded.modifiedBefore == stamp.addingTimeInterval(100))
            reopened.delete(id: saved.id)
            check("deleting saved conditions persists without deleting source files", SavedSearchStore(defaults: defaults).items.isEmpty && fm.fileExists(atPath: rootFile.path) && fm.fileExists(atPath: contentOnly.path))
            panelActions(store: reopened, request: combined, sourceFile: rootFile)

            await lifecycle(root: root, first: rootItem, second: contentItem)
            await injectedContent(root: root, named: rootItem, body: contentItem, old: oldItem, picture: imageItem, stamp: stamp)

            let recursive = SearchSession()
            recursive.start(fileRequest)
            await finished(recursive, label: "recursive name search")
            let sameNameURLs = [rootFile, firstFile, secondFile]
            check("recursive name traversal finds nested duplicate basenames without Spotlight", paths(recursive.results.map(\.url)) == paths(sameNameURLs), recursive.results.map(\.url).description)
            check("a sibling directory symlink does not suppress traversal of the next real folder", recursive.results.contains { sameLocation($0.url, firstFile) })
            check("recursive search excludes package descendants", !recursive.results.contains { $0.url.path.contains("Sample.app/") })
            recursive.start(SearchRequest(rootURL: root, name: "needle"))
            await finished(recursive, label: "recursive scope containment")
            check("recursive search does not follow a directory symlink outside its scope", !recursive.results.contains { $0.url.path.contains("needle-outside") })
            recursive.start(combined)
            await finished(recursive, label: "recursive combined conditions")
            check("recursive backend applies name, type and date together", paths(recursive.results.map(\.url)) == paths(sameNameURLs))
            recursive.start(SearchRequest(rootURL: root, name: "no-such-entry-" + UUID().uuidString))
            await finished(recursive, label: "empty recursive search")
            check("empty recursive search completes with an explicit terminal state", recursive.results.isEmpty && isFinished(recursive.status))
            recursive.start(SearchRequest(rootURL: root.appendingPathComponent("missing"), name: "needle"))
            await finished(recursive, label: "missing search root")
            check("missing search root reports a failure instead of an empty success", isFailed(recursive.status))

            let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root)
            window = wc
            wc.window?.setContentSize(NSSize(width: 1100, height: 750))
            let browser = wc.browser
            var openedFiles: [URL] = []
            browser.fileOpener = { openedFiles.append($0); return true }
            await listed(browser, at: root)
            for mode: ViewMode in [.details, .icons] {
                browser.setViewMode(mode)
                browser.setGroupKey(.kind)
                browser.nameFilter = "ordinary"
                browser.fileView.select(urls: [contentOnly])
                let beforeOriginReload = browser.model.generation
                browser.reload()
                await waitUntil("record ordinary directory selection") { browser.model.generation > beforeOriginReload }
                browser.showSearch()
                browser.searchPanel.clearButton.performClick(nil)
                browser.searchPanel.nameField.stringValue = "needle.txt"
                browser.searchPanel.search(nil)
                await searched(browser, label: "\(mode) Search submission")
                check("\(mode): search exercises the intended concrete view after directory property restoration",
                      browser.viewMode == mode && (mode == .icons ? browser.fileView === browser.iconGrid : browser.fileView === browser.fileList))
                check("\(mode): real Search controls start a recursive result context", browser.isSearching && browser.model.isSearchResults && paths(browser.model.items.map(\.url)) == paths(sameNameURLs))
                check("\(mode): starting Search retains grouping and clears the old directory filter", browser.groupKey == .kind && !browser.isFiltering && browser.model.isGrouped)
                browser.searchPanel.contentField.stringValue = "unsubmitted content draft"
                browser.searchPanel.clearButton.performClick(nil)
                let clearedGeneration = browser.searchSession.generation
                await drainMainQueue()
                check("\(mode): Clear removes completed results and conditions without launching another query", browser.searchPanel.currentRequest.name.isEmpty && browser.searchPanel.currentRequest.content.isEmpty && browser.searchSession.request == nil && browser.searchSession.status == .idle && browser.searchSession.generation == clearedGeneration && browser.model.items.isEmpty && browser.model.isSearchResults && browser.model.url == nil && browser.isSearching)
                browser.startSearch(fileRequest)
                await searched(browser, label: "\(mode) Search after Clear")
                browser.nameFilter = "absent"
                check("\(mode): the existing pane filter narrows search results", browser.model.items.isEmpty && browser.searchSession.results.count == 3)
                browser.nameFilter = "needle"
                check("\(mode): clearing a narrower filter restores all same-name results", browser.model.items.count == 3)
                browser.fileView.select(urls: [secondFile])
                check("\(mode): selection identifies the exact nested result", paths(browser.fileView.selectedItems.map(\.url)) == paths([secondFile]))
                check("\(mode): search has no ordinary directory or background drop destination", browser.model.url == nil && browser.fileList.dropDestination(item: nil, childIndex: 0) == nil)
                if mode == .details {
                    let column = browser.fileList.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("location"))
                    let node = browser.model.node(for: secondFile)!
                    let cell = browser.fileList.outlineView(browser.fileList.tableView, viewFor: column, item: node) as? NSTableCellView
                    let displayedPath = cell?.textField?.stringValue ?? ""
                    check("list results show the original enclosing directory in a visible Location column", column?.isHidden == false && displayedPath == node.url.deletingLastPathComponent().path && sameLocation(URL(fileURLWithPath: displayedPath), secondDirectory),
                          "hidden=\(String(describing: column?.isHidden)), columns=\(browser.fileList.tableView.tableColumns.map { $0.identifier.rawValue }), cell=\(String(describing: cell)), text=\(cell?.textField?.stringValue ?? "nil"), expected=\(secondDirectory.path), node=\(node.url.path), results=\(browser.model.isSearchResults), loaded=\(browser.fileList.isViewLoaded)")
                    check("list Location truncates the middle to retain the enclosing folder name", cell?.textField?.lineBreakMode == .byTruncatingMiddle)
                } else if let selected = browser.iconGrid.collectionView.selectionIndexPaths.first {
                    let cell = browser.iconGrid.collectionView(browser.iconGrid.collectionView, itemForRepresentedObjectAt: selected) as? FileCollectionItem
                    let actualParent = browser.fileView.selectedItems[0].url.deletingLastPathComponent()
                    check("icon results show each original enclosing directory", cell?.locationLabel.isHidden == false && cell?.locationLabel.lineBreakMode == .byTruncatingMiddle && cell?.locationLabel.stringValue == (actualParent.path as NSString).abbreviatingWithTildeInPath && sameLocation(actualParent, secondDirectory))
                } else { check("icon search selection has a collection item", false) }
                check("\(mode): Quick Look, Share and Info retain the real source URL", sameLocation(browser.previewPanel(nil, previewItemAt: 0)?.previewItemURL, secondFile) && paths(wc.sharingItems.compactMap { $0 as? URL }) == paths([secondFile]) && paths(browser.infoTargets) == paths([secondFile]))
                let beforeOpen = openedFiles.count
                browser.openSelection()
                check("\(mode): Open launches the exact nested file and retains its search context", openedFiles.count == beforeOpen + 1 && sameLocation(openedFiles.last, secondFile) && browser.isSearching && browser.model.isSearchResults)
                let menu = browser.buildContextMenu(for: browser.fileView.selectedItems)
                check("\(mode): search results expose Reveal in Enclosing Folder", menu.items.contains { $0.title == "Reveal in Enclosing Folder" })
                check("\(mode): search results omit destination-dependent Compress", !menu.items.contains { $0.title.hasPrefix("Compress") })
                check("\(mode): result mutations are separate from destination-only commands", browser.canModifySelectedItems && !browser.canModifyCurrentLocation && browser.newFolder() == nil)
                check("\(mode): a refused New Folder arms no inline edit", !browser.hasPendingRename && !browser.fileView.isRenaming)

                let alternate: ViewMode = mode == .details ? .icons : .details
                browser.setViewMode(alternate)
                check("\(mode): switching views preserves a full-URL selection across duplicate names", paths(browser.fileView.selectedItems.map(\.url)) == paths([secondFile]))
                browser.setViewMode(mode)
                await lateRenameCallback(browser, window: wc, target: secondFile, peers: [rootFile, firstFile])
                menuSnapshot(browser, original: secondFile, replacement: rootFile)
                browser.revealSearchResult(secondFile)
                await listed(browser, at: secondDirectory)
                await waitUntil("reveal result selection") { paths(browser.fileView.selectedItems.map(\.url)) == paths([secondFile]) }
                check("\(mode): reveal leaves Search and opens the exact enclosing folder", !browser.isSearching && !browser.model.isSearchResults && paths(browser.fileView.selectedItems.map(\.url)) == paths([secondFile]))
                check("\(mode): leaving Search does not write a result basename into origin history", browser.history.backEntries().first?.entry.selectedName == contentOnly.lastPathComponent)

                browser.navigate(to: root)
                await listed(browser, at: root)
                browser.startSearch(SearchRequest(rootURL: root, name: "needle"))
                await searched(browser, label: "\(mode) rename setup")
                check("\(mode): returning to the source directory restores the intended rename view",
                      browser.viewMode == mode && (mode == .icons ? browser.fileView === browser.iconGrid : browser.fileView === browser.fileList))
                browser.fileView.select(urls: [firstFile])
                browser.nameFilter = "needle.txt"
                check("\(mode): filtering away other kinds preserves a result's full-URL selection", paths(browser.fileView.selectedItems.map(\.url)) == paths([firstFile]))
                browser.setGroupKey(.none)
                browser.setGroupKey(.kind)
                check("\(mode): regrouping preserves the same nested selected result", paths(browser.fileView.selectedItems.map(\.url)) == paths([firstFile]))
                browser.nameFilter = "needle"
                let renameTarget = browser.fileView.selectedItems[0]
                let renamed = firstDirectory.appendingPathComponent("needle-renamed.txt")
                browser.rename(renameTarget, to: renamed.lastPathComponent)
                await waitUntil("\(mode) renamed result refresh") { fm.fileExists(atPath: renamed.path) && browser.model.items.contains { sameLocation($0.url, renamed) } && !browser.searchSession.status.isSearching }
                check("\(mode): renaming a duplicate result modifies only its actual source", !fm.fileExists(atPath: firstFile.path) && (try? String(contentsOf: secondFile)) == "second marker" && (try? String(contentsOf: rootFile)) == "root marker")
                check("\(mode): rename refresh retains exact result selection", paths(browser.fileView.selectedItems.map(\.url)) == paths([renamed]))
                wc.window?.undoManager?.undo()
                await waitUntil("\(mode) search rename undo") { fm.fileExists(atPath: firstFile.path) && !fm.fileExists(atPath: renamed.path) && browser.model.items.contains { sameLocation($0.url, firstFile) } && !browser.searchSession.status.isSearching }
                check("\(mode): undo restores the selected nested file and keeps its peers untouched", (try? String(contentsOf: firstFile)) == "first marker" && (try? String(contentsOf: secondFile)) == "second marker" && (try? String(contentsOf: rootFile)) == "root marker")

                await overlappingTrash(browser, window: wc, root: root, folder: firstDirectory, child: firstFile, peer: secondFile)

                browser.nameFilter = ""
                browser.startSearch(SearchRequest(rootURL: root, name: "needle folder", kind: .folder))
                await searched(browser, label: "\(mode) directory result")
                if let node = browser.model.node(for: matchingFolder) {
                    check("\(mode): result folders cannot expand into an ambiguous mixed tree", !browser.fileList.outlineView(browser.fileList.tableView, isItemExpandable: node) && browser.model.loadChildren(of: node).isEmpty)
                } else { check("\(mode): directory search returns its matching folder", false) }
                browser.fileView.select(urls: [matchingFolder])
                browser.openSelection()
                await listed(browser, at: matchingFolder)
                check("\(mode): opening a directory result exits Search into its real URL", !browser.isSearching && !browser.model.isSearchResults && sameLocation(browser.currentURL, matchingFolder))
                browser.navigate(to: root)
                await listed(browser, at: root)
            }

            await paneIsolation(wc, root: root, firstDirectory: firstDirectory, fileRequest: fileRequest)
            try await archiveBoundary(wc.browser, root: root, folder: firstDirectory)
        } catch { check("search fixture and operations", false, error.localizedDescription) }
    }

    @MainActor private static func lifecycle(root: URL, first: FileItem, second: FileItem) async {
        let backend = ControlledBackend()
        let session = SearchSession(backend: backend)
        let initial = SearchRequest(rootURL: root, name: "initial")
        let replacement = SearchRequest(rootURL: root, name: "replacement")
        session.start(initial)
        backend.tasks[0].onCancel = { [weak backend] in
            backend?.emit(.batch([first]), at: 0)
            backend?.emit(.failed("callback synchronously emitted by cancellation"), at: 0)
        }
        let firstGeneration = session.generation
        backend.emit(.batch([first, first]), at: 0)
        await waitUntil("first injectable search batch") { session.results.count == 1 }
        check("search batches deduplicate by full URL", session.results.count == 1)
        backend.emit(.batch([second]), at: 0)
        session.start(replacement)
        backend.emit(.batch([first]), at: 0)
        backend.emit(.finished("old request finished"), at: 0)
        backend.emit(.failed("old request failed"), at: 0)
        backend.emit(.batch([second]), at: 1)
        backend.emit(.finished("replacement finished"), at: 1)
        await finished(session, label: "replacement injectable search")
        check("replacing a request cancels its backend and advances generation", backend.tasks[0].cancelCount == 1 && session.generation > firstGeneration)
        check("queued old batches and terminal callbacks cannot replace newer results", session.request == replacement && session.results.map(\.url) == [second.url] && session.status.message.contains("replacement"))
        backend.emit(.batch([first]), at: 1)
        backend.emit(.failed("late failure after finish"), at: 1)
        await drainMainQueue()
        check("a finished search ignores callbacks after its terminal event", session.results.map(\.url) == [second.url] && isFinished(session.status))
        session.start(initial)
        backend.emit(.batch([first]), at: 2)
        await waitUntil("cancellable partial search batch") { session.results.count == 1 }
        session.cancel()
        backend.emit(.batch([second]), at: 2)
        backend.emit(.finished("late completion after cancel"), at: 2)
        backend.emit(.failed("late failure after cancel"), at: 2)
        await drainMainQueue()
        check("cancelling retains partial results and ignores all late callbacks", session.status == .cancelled && session.results.map(\.url) == [first.url] && backend.tasks[2].cancelCount == 1)
        session.start(initial)
        backend.emit(.batch([first]), at: 3)
        session.clear()
        backend.emit(.finished("late completion after clear"), at: 3)
        await drainMainQueue()
        check("clearing cancels the task and cannot be repopulated by queued callbacks", session.request == nil && session.results.isEmpty && session.status == .idle && backend.tasks[3].cancelCount == 1)

        let synchronous = SearchSession(backend: ImmediateBackend(item: first))
        synchronous.start(initial)
        await finished(synchronous, label: "synchronous backend")
        check("synchronous backend callbacks are accepted after request installation", synchronous.results.map(\.url) == [first.url] && isFinished(synchronous.status))
        let failing = SearchSession(backend: FailureBackend())
        failing.start(initial)
        await finished(failing, label: "injectable permission failure")
        check("backend permission failures are a visible state without a modal", isFailed(failing.status) && failing.status.message.contains("permission"))
        let invalidBackend = ControlledBackend()
        let invalid = SearchSession(backend: invalidBackend)
        invalid.start(SearchRequest(rootURL: root, modifiedAfter: Date(timeIntervalSince1970: 10), modifiedBefore: Date(timeIntervalSince1970: 10)))
        check("invalid date ranges fail before launching any backend", isFailed(invalid.status) && invalidBackend.tasks.isEmpty)
    }

    @MainActor private static func lateRenameCallback(_ browser: BrowserViewController, window: MainWindowController, target: URL, peers: [URL]) async {
        let fm = FileManager.default
        window.window?.makeFirstResponder(browser.focusView)
        browser.fileView.select(urls: [target])
        browser.fileView.beginRename(item: browser.fileView.selectedItems[0])
        let editor = window.window?.firstResponder as? NSTextView
        let field = editor?.delegate as? NSTextField
        check("\(browser.viewMode): search result starts a real filename editor", editor?.string == target.lastPathComponent && field != nil)
        editor?.string = "needle-danger.txt"
        let originals = peers + [target]
        let originalBytes = originals.map { try! Data(contentsOf: $0) }
        // A new batch removes the edited result and changes the row/index path.
        browser.model.replaceSearchResults(Array(peers.compactMap { FileItem(url: $0) }.reversed()))
        if let field {
            field.stringValue = "needle-danger.txt"
            let notification = Notification(name: NSControl.textDidEndEditingNotification, object: field)
            if browser.viewMode == .details { browser.fileList.controlTextDidEndEditing(notification) }
            else { browser.iconGrid.controlTextDidEndEditing(notification) }
        }
        await drainMainQueue()
        check("\(browser.viewMode): result replacement cancels rename and ignores a late editor commit", field?.isEditable == false && zip(originals, originalBytes).allSatisfy { (try? Data(contentsOf: $0.0)) == $0.1 } && originals.allSatisfy { !fm.fileExists(atPath: $0.deletingLastPathComponent().appendingPathComponent("needle-danger.txt").path) })
        browser.model.replaceSearchResults(browser.searchSession.results)
        browser.fileView.select(urls: [target])
        window.window?.makeFirstResponder(browser.focusView)
    }

    @MainActor private static func menuSnapshot(_ browser: BrowserViewController, original: URL, replacement: URL) {
        let previousOpener = browser.fileOpener
        let originalResults = browser.searchSession.results
        var opened: [URL] = []
        browser.fileOpener = { opened.append($0); return true }
        defer {
            browser.fileOpener = previousOpener
            browser.model.replaceSearchResults(originalResults)
            browser.fileView.select(urls: [original])
        }
        browser.fileView.select(urls: [original])
        let firstMenu = browser.buildContextMenu(for: browser.fileView.selectedItems)
        browser.menuWillOpen(firstMenu)
        browser.model.replaceSearchResults([FileItem(url: replacement)!])
        browser.fileView.select(urls: [replacement])
        // AppKit closes a contextual menu before sending its selected action.
        browser.menuDidClose(firstMenu)
        let firstOpen = firstMenu.indexOfItem(withTitle: "Open")
        if firstOpen >= 0 { firstMenu.performActionForItem(at: firstOpen) }
        check("\(browser.viewMode): a menu action keeps its original URL after results change and the menu closes", opened.count == 1 && sameLocation(opened.last, original))

        let nextMenu = browser.buildContextMenu(for: browser.fileView.selectedItems)
        browser.menuWillOpen(nextMenu)
        browser.model.replaceSearchResults(originalResults)
        browser.fileView.select(urls: [original])
        browser.menuDidClose(nextMenu)
        let nextOpen = nextMenu.indexOfItem(withTitle: "Open")
        if nextOpen >= 0 { nextMenu.performActionForItem(at: nextOpen) }
        check("\(browser.viewMode): the next context menu captures its new URL independently", opened.count == 2 && sameLocation(opened.last, replacement))
        if firstOpen >= 0 { firstMenu.performActionForItem(at: firstOpen) }
        check("\(browser.viewMode): retaining an older menu cannot retarget its action to a newer menu's file", opened.count == 3 && sameLocation(opened.last, original))
        let multiple = browser.buildContextMenu(for: [FileItem(url: original)!, FileItem(url: replacement)!])
        browser.fileView.select(urls: [replacement])
        let singleReveal = firstMenu.item(withTitle: "Reveal in Enclosing Folder")
        let multipleReveal = multiple.item(withTitle: "Reveal in Enclosing Folder")
        check("\(browser.viewMode): Reveal validation uses its captured menu's target count", singleReveal.map { browser.validateMenuItem($0) } == true && multipleReveal.map { browser.validateMenuItem($0) } == false)
    }

    /// `mutationSources` only lets actual directories cover their descendants,
    /// so the fixture creates the folders (the files need not exist).
    private static func mutationSources(root: URL) {
        let folder = root.appendingPathComponent("parent")
        let child = folder.appendingPathComponent("nested/file.txt")
        let sibling = root.appendingPathComponent("parent-sibling/file.txt")
        let other = root.appendingPathComponent("other.txt")
        let equivalentFolder = URL(fileURLWithPath: folder.path + "/.")
        for directory in [child, sibling] {
            try? FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        check("overlapping sources collapse a selected parent and descendant", FileOperations.mutationSources([folder, child]) == [folder])
        check("overlapping sources collapse descendants even when the parent appears later", FileOperations.mutationSources([child, folder]) == [folder])
        check("source ancestry respects path-component boundaries", FileOperations.mutationSources([folder, sibling]) == [folder, sibling])
        check("source normalization deduplicates paths and preserves surviving input order", FileOperations.mutationSources([child, other, folder, equivalentFolder, sibling, other]) == [other, folder, sibling])
        check("an empty source selection remains empty", FileOperations.mutationSources([]).isEmpty)
    }

    @MainActor private static func overlappingTrash(_ browser: BrowserViewController, window: MainWindowController, root: URL, folder: URL, child: URL, peer: URL) async {
        let fm = FileManager.default
        let childBytes = try! Data(contentsOf: child)
        let peerBytes = try! Data(contentsOf: peer)
        browser.startSearch(SearchRequest(rootURL: root))
        await searched(browser, label: "\(browser.viewMode) overlapping selection search")
        browser.fileView.select(urls: [folder, child])
        check("\(browser.viewMode): recursive results can select a folder and its descendant together", paths(browser.fileView.selectedItems.map(\.url)) == paths([folder, child]))
        browser.moveToTrash(nil)
        await waitUntil("\(browser.viewMode) overlapping selection Trash") {
            !fm.fileExists(atPath: folder.path) && !fm.fileExists(atPath: child.path)
                && !browser.searchSession.status.isSearching
                && !browser.model.items.contains { sameLocation($0.url, folder) || sameLocation($0.url, child) }
        }
        check("\(browser.viewMode): Trash handles the overlapping selection once and preserves other results", !fm.fileExists(atPath: folder.path) && !fm.fileExists(atPath: child.path) && (try? Data(contentsOf: peer)) == peerBytes && browser.isSearching && window.window?.undoManager?.canUndo == true)
        window.window?.undoManager?.undo()
        await waitUntil("\(browser.viewMode) overlapping selection Undo") {
            fm.fileExists(atPath: child.path) && !browser.searchSession.status.isSearching
                && browser.model.items.contains { sameLocation($0.url, folder) }
                && browser.model.items.contains { sameLocation($0.url, child) }
        }
        check("\(browser.viewMode): Undo restores the complete selected subtree and keeps its peer unchanged", fm.fileExists(atPath: folder.path) && (try? Data(contentsOf: child)) == childBytes && (try? Data(contentsOf: peer)) == peerBytes && browser.isSearching)
    }

    @MainActor private static func panelActions(store: SavedSearchStore, request: SearchRequest, sourceFile: URL) {
        let panel = SearchPanelController(store: store)
        panel.configure(rootURL: request.rootURL)
        var searches: [SearchRequest] = []
        var cancels = 0
        var closes = 0
        panel.onSearch = { searches.append($0) }
        panel.onCancel = { cancels += 1 }
        panel.onClose = { closes += 1 }
        panel.present(request: request)
        check("search controls round-trip custom type and date bounds", panel.currentRequest == request)
        check("editing a condition does not search when focus leaves the field", panel.nameField.cell?.sendsActionOnEndEditing == false && panel.contentField.cell?.sendsActionOnEndEditing == false && searches.isEmpty)
        panel.search(nil)
        check("Search submission dispatches all configured conditions", searches == [request])
        panel.update(status: "Searching", resultCount: 0, isRunning: true)
        panel.cancelButton.performClick(nil)
        check("Cancel button dispatches cancellation without changing the draft", cancels == 1 && panel.currentRequest == request)
        panel.savedDisclosure.performClick(nil)
        panel.saveNameField.stringValue = "Smoke saved conditions"
        panel.saveButton.performClick(nil)
        check("the visible Save action persists the draft's full conditions", store.items.count == 1 && store.items.first?.request == request)
        panel.present(request: SearchRequest(rootURL: request.rootURL, scope: .home, name: "different", content: "body", kind: .image))
        panel.clearButton.performClick(nil)
        check("Clear cancels and resets conditions while retaining the selected scope", cancels == 2 && panel.currentRequest == SearchRequest(rootURL: request.rootURL, scope: .home) && searches.count == 1)
        panel.savedPopup.selectItem(at: 1)
        panel.openSavedButton.performClick(nil)
        check("Open Saved restores the saved folder, scope and conditions then runs", searches.count == 2 && searches.last == request && panel.currentRequest == request)
        panel.deleteSavedButton.performClick(nil)
        check("Delete Saved removes only saved conditions through its real action", store.items.isEmpty && FileManager.default.fileExists(atPath: sourceFile.path) && panel.savedPopup.numberOfItems == 1)
        panel.present(request: SearchRequest(rootURL: request.rootURL, modifiedAfter: Date(timeIntervalSince1970: 100), modifiedBefore: Date(timeIntervalSince1970: 50)))
        panel.search(nil)
        check("invalid custom dates show an inline error without dispatching Search", searches.count == 2 && panel.statusLabel.textColor == .systemRed)
        panel.update(status: SearchRequest.contentLimitMessage, resultCount: 0, isRunning: false)
        check("zero content results retain the index and format limitation", panel.statusLabel.stringValue.contains("indexed") && panel.statusLabel.stringValue.contains("supported") && !panel.cancelButton.isEnabled)
        panel.closeButton.performClick(nil)
        check("Close button dispatches the pane close action", closes == 1)
    }

    @MainActor private static func injectedContent(root: URL, named: FileItem, body: FileItem, old: FileItem, picture: FileItem, stamp: Date) async {
        let backend = IndexedFixtureBackend(rows: [(named, "root marker"), (body, "a NEEDLE in the body"), (old, "a NEEDLE in an old body"), (picture, "a NEEDLE in image metadata")])
        let session = SearchSession(backend: backend)
        session.start(SearchRequest(rootURL: root, content: "needle", kind: .document, modifiedAfter: stamp))
        await finished(session, label: "deterministic indexed content conditions")
        check("injectable content backend combines body, kind and date without filename substitution", session.results.map(\.url) == [body.url])
        session.start(SearchRequest(rootURL: root, name: "needle", content: "needle", kind: .document, modifiedAfter: stamp))
        await finished(session, label: "deterministic name and content conjunction")
        check("name and body conditions are conjunctive rather than alternatives", session.results.isEmpty && isFinished(session.status))
    }

    @MainActor private static func paneIsolation(_ wc: MainWindowController, root: URL, firstDirectory: URL, fileRequest: SearchRequest) async {
        let original = wc.browser
        original.startSearch(fileRequest)
        await searched(original, label: "original pane search")
        original.nameFilter = "needle"
        wc.tabs.toggleSplit()
        let other = wc.browser
        await listed(other, at: root)
        check("a split pane has its own search session and ordinary context", other !== original && !other.isSearching && other.searchSession.request == nil && original.isSearching)
        other.startSearch(SearchRequest(rootURL: root, name: "ordinary"))
        await searched(other, label: "second pane search")
        check("split panes retain independent requests and results", original.searchSession.request == fileRequest && original.model.items.count == 3 && other.model.items.map(\.name) == ["ordinary.txt"])
        other.startSearch(SearchRequest(rootURL: root, name: "restart before cancellation"))
        other.searchPanel.cancelButton.performClick(nil)
        check("cancelling the other pane leaves the original results and filter intact", original.isSearching && original.nameFilter == "needle" && original.model.items.count == 3)
        check("the mounted Cancel control stops the active pane query", other.searchSession.status == .cancelled && other.isSearching)
        let tab = wc.tabs.newTab(at: firstDirectory)
        await listed(tab, at: firstDirectory)
        check("a new tab does not inherit a search result context", !tab.isSearching && !tab.model.isSearchResults && original.isSearching && other.isSearching)
        wc.tabs.selectTab(at: 0)
        check("returning to a split tab restores each pane's search state", wc.tabs.isSplit && original.isSearching && other.isSearching)
        other.startSearch(fileRequest)
        other.navigate(to: firstDirectory)
        await listed(other, at: firstDirectory)
        await drainMainQueue()
        check("navigation cancels a pending search without later results replacing the directory", !other.isSearching && !other.model.isSearchResults && sameLocation(other.currentURL, firstDirectory) && other.model.items.allSatisfy { sameLocation($0.url.deletingLastPathComponent(), firstDirectory) })
        original.closeSearch()
        await listed(original, at: root)
        check("Close Search restores the original ordinary directory", !original.isSearching && !original.model.isSearchResults && sameLocation(original.currentURL, root))
    }

    @MainActor private static func archiveBoundary(_ browser: BrowserViewController, root: URL, folder: URL) async throws {
        let archive = try await SmokeFixtures.compress([folder], to: root)
        let before = try Data(contentsOf: archive)
        AppPreferences.experimentalZIPBrowsingEnabled = true
        browser.navigate(to: archive)
        await listed(browser, at: archive)
        browser.showSearch()
        browser.startSearch(SearchRequest(rootURL: archive, name: "needle"))
        check("ZIP browsing rejects Search and keeps its read-only logical context", browser.isBrowsingArchive && !browser.isSearching && !browser.model.isSearchResults && browser.fileView.isReadOnly && sameLocation(browser.currentURL, archive))
        browser.navigate(to: root)
        await listed(browser, at: root)
        browser.startSearch(SearchRequest(rootURL: archive.appendingPathComponent(folder.lastPathComponent), content: "marker"))
        check("a saved archive-member scope cannot bypass the ZIP search boundary", !browser.isSearching && !browser.isBrowsingArchive && sameLocation(browser.currentURL, root) && (try? Data(contentsOf: archive)) == before)
    }

    private final class Cancellation: SearchCancellable {
        var cancelCount = 0
        var onCancel: (() -> Void)?
        func cancel() { cancelCount += 1; onCancel?() }
    }
    private final class ControlledBackend: SearchBackend {
        var callbacks: [(SearchEvent) -> Void] = []
        var tasks: [Cancellation] = []
        func start(_ request: SearchRequest, event: @escaping (SearchEvent) -> Void) -> SearchCancellable {
            callbacks.append(event)
            let task = Cancellation()
            tasks.append(task)
            return task
        }
        func emit(_ event: SearchEvent, at index: Int) { callbacks[index](event) }
    }
    private struct ImmediateBackend: SearchBackend {
        let item: FileItem
        func start(_ request: SearchRequest, event: @escaping (SearchEvent) -> Void) -> SearchCancellable {
            event(.batch([item]))
            event(.finished("Immediate search completed"))
            return Cancellation()
        }
    }
    private struct FailureBackend: SearchBackend {
        func start(_ request: SearchRequest, event: @escaping (SearchEvent) -> Void) -> SearchCancellable {
            event(.failed("Search permission denied"))
            return Cancellation()
        }
    }
    private struct IndexedFixtureBackend: SearchBackend {
        let rows: [(FileItem, String)]
        func start(_ request: SearchRequest, event: @escaping (SearchEvent) -> Void) -> SearchCancellable {
            event(.batch(rows.compactMap { request.matches($0.0, contentText: $0.1) ? $0.0 : nil }))
            event(.finished("Fixture metadata search completed"))
            return Cancellation()
        }
    }

    @MainActor private static func searched(_ browser: BrowserViewController, label: String) async {
        await waitUntil(label, detail: { browser.searchSession.status.message }) {
            browser.isSearching && browser.model.isSearchResults && !browser.searchSession.status.isSearching
        }
        check("\(label) finishes without an error", isFinished(browser.searchSession.status), browser.searchSession.status.message)
        browser.view.layoutSubtreeIfNeeded()
    }
    @MainActor private static func finished(_ session: SearchSession, label: String) async {
        await waitUntil(label, detail: { session.status.message }) { !session.status.isSearching }
    }
    @MainActor private static func listed(_ browser: BrowserViewController, at url: URL) async {
        await waitUntil("search UI directory listing", detail: { "current=\(browser.currentURL?.path ?? "nil"), expected=\(url.path)" }) {
            browser.currentURL?.standardizedFileURL.path == url.standardizedFileURL.path
                && browser.model.url?.standardizedFileURL.path == url.standardizedFileURL.path
                && browser.model.generation > 0 && !browser.isPreparingArchive && !browser.model.isSearchResults
                && browser.model.items.allSatisfy { $0.url.deletingLastPathComponent().standardizedFileURL.path == url.standardizedFileURL.path }
        }
        browser.view.layoutSubtreeIfNeeded()
    }
    private static func isFinished(_ status: SearchStatus) -> Bool {
        if case .finished = status { return true }; return false
    }
    private static func isFailed(_ status: SearchStatus) -> Bool {
        if case .failed = status { return true }; return false
    }
    private static func paths(_ urls: [URL]) -> Set<String> { Set(urls.map { $0.standardizedFileURL.path }) }
    private static func sameLocation(_ lhs: URL?, _ rhs: URL) -> Bool { lhs?.standardizedFileURL.path == rhs.standardizedFileURL.path }
    private static func validCompoundGroups(_ predicate: NSPredicate) -> Bool {
        guard let compound = predicate as? NSCompoundPredicate else { return true }
        let children = compound.subpredicates.compactMap { $0 as? NSPredicate }
        return children.count == compound.subpredicates.count && children.count >= 2 && children.allSatisfy(validCompoundGroups)
    }
}

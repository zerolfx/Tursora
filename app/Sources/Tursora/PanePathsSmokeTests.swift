import AppKit

/// Pane-owned navigation must keep both visible locations, editors and result
/// contexts independent, including when the window's field editor is shared.
enum PanePathsSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("tursora-pane-paths-" + UUID().uuidString)
                .resolvingSymlinksInPath()
            let previousZIPPreference = AppPreferences.experimentalZIPBrowsingEnabled
            defer {
                AppPreferences.experimentalZIPBrowsingEnabled = previousZIPPreference
                try? FileManager.default.removeItem(at: fixture)
            }
            do {
                print("== Independent pane address bars ==")
                try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                let archiveSource = fixture.appendingPathComponent("Archive Documents")
                let archiveInnerSource = archiveSource.appendingPathComponent("Inner")
                for folder in [archiveSource, archiveInnerSource] { try makeFolder(folder) }
                let archive = try await compress([archiveSource], to: fixture)
                let archiveBytes = try Data(contentsOf: archive)
                AppPreferences.experimentalZIPBrowsingEnabled = true
                minimumWidthControls(at: archiveInnerSource)
                for mode: ViewMode in [.details, .icons] {
                    try await paneNavigation(mode: mode, fixture: fixture, archive: archive)
                }
                check("address navigation preserves the original ZIP bytes", try Data(contentsOf: archive) == archiveBytes)
                completion()
            } catch {
                check("fixtures complete", false, error.localizedDescription)
            }
        }
    }

    @MainActor private static func paneNavigation(mode: ViewMode, fixture: URL, archive: URL) async throws {
        let root = fixture.appendingPathComponent(mode.rawValue)
        let leftURL = root.appendingPathComponent("Left")
        let leftChild = leftURL.appendingPathComponent("Alpha One")
        let leftAlternative = leftURL.appendingPathComponent("Alternative")
        let rightURL = root.appendingPathComponent("Right")
        let rightChild = rightURL.appendingPathComponent("Beta One")
        let thirdURL = root.appendingPathComponent("Third Tab")
        for folder in [leftURL, leftChild, leftAlternative, rightURL, rightChild, thirdURL] {
            try makeFolder(folder)
        }
        let needle = rightChild.appendingPathComponent("needle.txt")
        try Data("recursive result owned by the right pane".utf8).write(to: needle)
        var defaults = DirectoryViewProperties()
        defaults.viewMode = mode
        defaults.groupKey = .kind
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"), initialDefaults: defaults)
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: leftURL,
                                      viewPropertiesStore: store)
        defer {
            for pane in wc.tabs.pages.flatMap(\.panes) { pane.addressBar.endEditing() }
            wc.close()
            try? store.flush()
        }
        guard let window = wc.window else { check("\(mode): browser window exists", false); return }
        // Completion uses the real window field editor and child-panel focus.
        // A never-shown window cannot establish this native interaction path.
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        let left = wc.browser
        await listed(left, at: leftURL)
        wc.tabs.openInOtherPane(rightURL)
        let right = wc.browser
        await listed(right, at: rightURL)
        let page = wc.tabs.currentPage
        check("\(mode): each visible pane owns its address bar and actual file view",
              left !== right && left.addressBar !== right.addressBar
              && left.addressBar.isDescendant(of: left.view) && right.addressBar.isDescendant(of: right.view)
              && (mode == .details ? left.fileView === left.fileList : left.fileView === left.iconGrid)
              && (mode == .details ? right.fileView === right.fileList : right.fileView === right.iconGrid))
        check("\(mode): both paths remain visible while the compatibility accessor follows focus",
              samePath(left.addressBar.url, leftURL) && samePath(right.addressBar.url, rightURL)
              && !left.addressBar.isHidden && !right.addressBar.isHidden && wc.tabs.addressBar === right.addressBar)

        for width: CGFloat in [1000, 680, 1120] {
            window.setContentSize(NSSize(width: width, height: 640))
            window.contentView?.layoutSubtreeIfNeeded()
            page.splitView.adjustSubviews()
            window.contentView?.layoutSubtreeIfNeeded()
            for pane in [left, right] { pane.addressBar.layoutSubtreeIfNeeded() }
            let leftBar = left.addressBar.convert(left.addressBar.bounds, to: nil)
            let rightBar = right.addressBar.convert(right.addressBar.bounds, to: nil)
            let leftFrame = left.view.convert(left.view.bounds, to: nil)
            let rightFrame = right.view.convert(right.view.bounds, to: nil)
            check("\(mode): address rows align with their panes at width \(Int(width))",
                  aligned(leftBar, with: leftFrame) && aligned(rightBar, with: rightFrame)
                  && leftBar.maxX <= rightBar.minX + 1 && abs(leftBar.minY - rightBar.minY) < 1,
                  "left=\(leftBar) in \(leftFrame); right=\(rightBar) in \(rightFrame)")
            check("\(mode): breadcrumb controls stay inside their own pane at width \(Int(width))",
                  [left, right].allSatisfy { pane in
                      !pane.addressBar.visibleNavigationFrames.isEmpty
                          && pane.addressBar.visibleNavigationFrames.allSatisfy {
                              $0.minX >= 0 && $0.maxX <= pane.addressBar.bounds.width + 1
                          }
                  })
        }

        left.nameFilter = "marker"
        right.nameFilter = "Beta"
        left.addressBar.beginEditing()
        check("\(mode): editing an inactive pane activates that owner and its field editor",
              wc.browser === left && wc.tabs.addressBar === left.addressBar
              && left.addressBar.isEditing && !right.addressBar.isEditing
              && left.addressBar.textField.currentEditor() is NSTextView
              && window.firstResponder === left.addressBar.textField.currentEditor()
              && samePath(left.currentURL, leftURL) && samePath(right.currentURL, rightURL))
        check("\(mode): the left relative address resolves from the left folder", left.addressBar.commit("Alpha One"))
        await listed(left, at: leftChild)
        check("\(mode): left navigation clears only its own filter and updates only its own path",
              wc.browser === left && left.nameFilter.isEmpty && right.nameFilter == "Beta"
              && samePath(left.addressBar.url, leftChild) && samePath(right.addressBar.url, rightURL)
              && historyPaths(right) == [rightURL.path] && !left.addressBar.isEditing)
        check("\(mode): a direct inactive right address commit resolves against the right folder",
              right.addressBar.commit("Beta One"))
        await listed(right, at: rightChild)
        check("\(mode): right address commit activates the right pane without retargeting the left",
              wc.browser === right && wc.tabs.addressBar === right.addressBar
              && samePath(left.currentURL, leftChild) && samePath(right.addressBar.url, rightChild)
              && historyPaths(left) == [leftURL.path, leftChild.path]
              && historyPaths(right) == [rightURL.path, rightChild.path])
        right.nameFilter = "needle"
        page.activate(left)
        left.goBack()
        await listed(left, at: leftURL)
        check("\(mode): Back in the left pane leaves the right history, selection filter and address intact",
              left.canGoForward && samePath(right.currentURL, rightChild)
              && right.history.index == 1 && right.nameFilter == "needle"
              && samePath(left.addressBar.url, leftURL) && samePath(right.addressBar.url, rightChild))
        left.goForward()
        await listed(left, at: leftChild)
        check("\(mode): Forward restores only the left location",
              samePath(left.addressBar.url, leftChild) && samePath(right.addressBar.url, rightChild)
              && right.nameFilter == "needle" && right.history.index == 1)
        left.goBack()
        await listed(left, at: leftURL)
        page.activate(right)
        right.goBack()
        await listed(right, at: rightURL)

        left.addressBar.beginEditing()
        check("\(mode): reopening the same address editor survives the old field-editor end callback",
              left.addressBar.isEditing && left.addressBar.textField.currentEditor() is NSTextView
              && window.firstResponder === left.addressBar.textField.currentEditor())
        type("Al", in: left.addressBar)
        check("\(mode): left completion uses its own current directory",
              wc.browser === left && left.addressBar.completion.isVisible
              && Set(left.addressBar.completion.candidates) == ["Alpha One/", "Alternative/"])
        right.addressBar.beginEditing()
        check("\(mode): switching address editors cancels the earlier draft and popup without navigation",
              wc.browser === right && !left.addressBar.isEditing && !left.addressBar.completion.isVisible
              && right.addressBar.isEditing && right.addressBar.textField.currentEditor() is NSTextView
              && window.firstResponder === right.addressBar.textField.currentEditor()
              && samePath(left.currentURL, leftURL) && samePath(right.currentURL, rightURL))
        type("Be", in: right.addressBar)
        check("\(mode): the new editor completes from the other pane's directory",
              right.addressBar.completion.isVisible && right.addressBar.completion.candidates == ["Beta One/"])
        let third = wc.tabs.newTab(at: thirdURL)
        await listed(third, at: thirdURL)
        check("\(mode): switching tabs cancels every hidden pane editor and child popup",
              page.view.isHidden && wc.browser === third && wc.tabs.addressBar === third.addressBar
              && [left, right].allSatisfy { !$0.addressBar.isEditing && !$0.addressBar.completion.isVisible }
              && samePath(left.currentURL, leftURL) && samePath(right.currentURL, rightURL))
        // The field editor belongs to the window and can send delayed end-edit
        // notifications after a tab changed; these must never navigate a pane.
        right.addressBar.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                                              object: right.addressBar.textField))
        check("\(mode): a delayed hidden-editor notification leaves the visible tab untouched",
              wc.browser === third && samePath(third.currentURL, thirdURL) && !third.addressBar.isEditing)
        wc.tabs.selectTab(at: 0)
        check("\(mode): returning to the split restores both original address bars",
              !page.view.isHidden && wc.tabs.currentPage === page && wc.browser === right
              && samePath(left.addressBar.url, leftURL) && samePath(right.addressBar.url, rightURL))

        let request = SearchRequest(rootURL: rightURL, name: "needle")
        right.startSearch(request)
        await searched(right)
        right.nameFilter = "needle"
        right.fileView.select(urls: [needle])
        let rightHistory = historyPaths(right)
        check("\(mode): the right search finds its nested file by the exact URL",
              right.model.items.map { $0.url.standardizedFileURL.path } == [needle.standardizedFileURL.path]
              && right.fileView.selectedItems.map { $0.url.standardizedFileURL.path } == [needle.standardizedFileURL.path],
              "expected=\(needle.absoluteString); session=\(right.searchSession.results.map { $0.url.absoluteString }); "
              + "model=\(right.model.items.map { $0.url.absoluteString }); selected=\(right.fileView.selectedItems.map { $0.url.absoluteString }); "
              + "status=\(right.searchSession.status.message); mode=\(right.viewMode); filter=\(right.nameFilter); "
              + "group=\(right.groupKey); rows=\(right.fileList.tableView.numberOfRows); firstResponder=\(String(describing: window.firstResponder))")
        check("\(mode): left address navigation remains available beside recursive search",
              left.addressBar.commit("Alpha One"))
        await listed(left, at: leftChild)
        check("\(mode): changing the other path preserves search results, request, filter and selection",
              wc.browser === left && right.isSearching && right.model.isSearchResults
              && right.searchSession.request == request && right.nameFilter == "needle"
              && right.fileView.selectedItems.map { $0.url.standardizedFileURL.path } == [needle.standardizedFileURL.path]
              && historyPaths(right) == rightHistory
              && samePath(right.addressBar.url, rightURL) && samePath(left.addressBar.url, leftChild))
        let rightCrumb = right.addressBar.subviews.compactMap { $0 as? NSButton }
            .first { $0.toolTip == rightURL.path }
        check("\(mode): the inactive search pane exposes its own location breadcrumb", rightCrumb != nil)
        rightCrumb?.performClick(nil)
        await listed(right, at: rightURL)
        check("\(mode): clicking the inactive breadcrumb activates and navigates only its owner",
              wc.browser === right && !right.isSearching && samePath(left.currentURL, leftChild)
              && samePath(right.addressBar.url, rightURL))

        let archiveFolder = archive.appendingPathComponent("Archive Documents")
        let archiveInner = archiveFolder.appendingPathComponent("Inner")
        check("\(mode): the inactive pane accepts a logical ZIP address", left.addressBar.commit(archiveFolder.path))
        await listed(left, at: archiveFolder)
        check("\(mode): both bars distinguish archive and ordinary locations",
              wc.browser === left && left.isBrowsingArchive && !right.isBrowsingArchive
              && samePath(left.addressBar.url, archiveFolder) && samePath(right.addressBar.url, rightURL)
              && left.addressBar.segmentTitles.suffix(2) == [archive.lastPathComponent, "Archive Documents"])
        left.addressBar.beginEditing()
        check("\(mode): ZIP address editing shows the original logical location",
              left.addressBar.textField.stringValue == archiveFolder.path)
        check("\(mode): ZIP relative navigation resolves inside its owning archive", left.addressBar.commit("Inner"))
        await listed(left, at: archiveInner)
        check("\(mode): ZIP member navigation leaves the ordinary pane path and history intact",
              samePath(left.addressBar.url, archiveInner) && samePath(right.addressBar.url, rightURL)
              && left.isBrowsingArchive && left.fileView.isReadOnly && historyPaths(right) == rightHistory)
        left.goBack()
        await listed(left, at: archiveFolder)
        check("\(mode): ZIP Back updates that pane's logical address independently",
              samePath(left.addressBar.url, archiveFolder) && samePath(right.currentURL, rightURL))
    }

    private static func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("listing marker".utf8).write(to: url.appendingPathComponent("marker.txt"))
    }

    @MainActor private static func minimumWidthControls(at url: URL) {
        let bar = BreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 160, height: BreadcrumbBar.height))
        bar.url = url
        bar.layoutSubtreeIfNeeded()
        let controls = bar.visibleNavigationFrames
        check("captions, folder menus and overflow all fit a 160-point pane",
              bar.hasOverflowMenu && !controls.isEmpty
              && controls.allSatisfy { $0.minX >= 0 && $0.maxX <= 160 && $0.width >= 0 },
              "controls=\(controls)")
        let originalSubviews = bar.subviews.map(ObjectIdentifier.init)
        for width: CGFloat in [220, 360, 160, 160] {
            bar.frame.size.width = width
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            check("repeated breadcrumb layout reuses its controls at width \(Int(width))",
                  bar.subviews.map(ObjectIdentifier.init) == originalSubviews
                  && bar.visibleNavigationFrames.allSatisfy { $0.minX >= 0 && $0.maxX <= width + 1 })
        }
    }

    @MainActor private static func type(_ value: String, in bar: BreadcrumbBar) {
        bar.layoutSubtreeIfNeeded()
        guard let editor = bar.textField.currentEditor() as? NSTextView else {
            check("address field editor exists", false,
                  "editing=\(bar.isEditing), fieldHidden=\(bar.textField.isHidden), ancestorHidden=\(bar.isHiddenOrHasHiddenAncestor), "
                  + "windowVisible=\(bar.window?.isVisible ?? false), windowKey=\(bar.window?.isKeyWindow ?? false), "
                  + "fieldFrame=\(bar.textField.frame), firstResponder=\(String(describing: bar.window?.firstResponder))")
            return
        }
        editor.string = value
        editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        bar.textChanged()
    }

    private static func aligned(_ bar: NSRect, with pane: NSRect) -> Bool {
        bar.width > 100 && abs(bar.minX - pane.minX) < 1 && abs(bar.maxX - pane.maxX) < 1
            && abs(bar.height - BreadcrumbBar.height) < 1 && bar.minY >= pane.minY && bar.maxY <= pane.maxY + 1
    }

    private static func samePath(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private static func historyPaths(_ browser: BrowserViewController) -> [String] {
        browser.history.entries.map { $0.url.standardizedFileURL.path }
    }

    @MainActor private static func listed(_ browser: BrowserViewController, at url: URL) async {
        await wait("listing \(url.lastPathComponent)", detail: {
            "current=\(String(describing: browser.currentURL)), address=\(String(describing: browser.addressBar.url)), model=\(String(describing: browser.model.url))"
        }) {
            samePath(browser.currentURL, url) && samePath(browser.model.url, url)
                && !browser.isPreparingArchive && !browser.model.isSearchResults
                && browser.model.allNodes.contains { $0.item.name == "marker.txt" }
                && browser.model.allNodes.allSatisfy { samePath($0.url.deletingLastPathComponent(), url) }
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

    private static func compress(_ urls: [URL], to directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            FileOperations.compress(urls: urls, to: directory) { continuation.resume(with: $0) }
        }
    }

    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        print("\(success ? "ok  " : "FAIL") pane paths: \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !success { fflush(stdout); exit(1) }
    }
}

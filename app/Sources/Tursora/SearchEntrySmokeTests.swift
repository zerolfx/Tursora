import AppKit

/// The one toolbar field starts as a local filter and keeps its pane identity
/// when the user expands recursive search options or another pane becomes active.
enum SearchEntrySmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            print("== unified filter and search entry ==")
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("tursora-search-entry-" + UUID().uuidString).resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: fixture) }
            do {
                let root = fixture.appendingPathComponent("Root"), child = root.appendingPathComponent("Child")
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
                try "root match".write(to: root.appendingPathComponent("needle.txt"), atomically: true, encoding: .utf8)
                try "other match".write(to: root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
                try "nested match".write(to: child.appendingPathComponent("needle-child.txt"), atomically: true, encoding: .utf8)
                await savedQueries(root: root)
                for mode: ViewMode in [.details, .icons] {
                    await entry(mode: mode, root: root, child: child, fixture: fixture)
                }
                completion()
            } catch { check("temporary search entry fixtures are available", false, error.localizedDescription) }
        }
    }

    @MainActor private static func entry(mode: ViewMode, root: URL, child: URL, fixture: URL) async {
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("\(mode)-views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root, viewPropertiesStore: store)
        defer { wc.close() }
        wc.window?.makeKeyAndOrderFront(nil)
        let browser = wc.browser
        await listed(browser, at: root)
        browser.setViewMode(mode)
        let page = wc.tabs.currentPage
        guard let field = wc.searchField, let toolbar = wc.window?.toolbar else {
            check("\(mode): the window has its search entry", false); return
        }
        check("\(mode): only one search toolbar item remains", toolbar.items.filter { $0 is NSSearchToolbarItem }.count == 1 && !toolbar.items.contains { $0.itemIdentifier.rawValue == "tursora.recursiveSearch" })
        check("\(mode): empty filter has no accessory panel", browser.searchPanel.view.isHidden && !browser.searchPanel.isShowingOptions)
        check("\(mode): ordinary entry describes filtering", field.placeholderString == "Filter by Name")
        type("needle", in: wc)
        check("\(mode): toolbar typing filters this folder immediately", browser.nameFilter == "needle" && browser.model.items.map(\.name) == ["needle.txt"] && !browser.isSearching,
              "filter=\(browser.nameFilter.debugDescription), items=\(browser.model.items.map(\.name)), searching=\(browser.isSearching), field=\(field.stringValue.debugDescription), paneText=\(browser.searchFieldText.debugDescription), unfiltered=\(browser.model.unfilteredCount)")
        check("\(mode): typing reveals only the compact options affordance", !browser.searchPanel.view.isHidden && !browser.searchPanel.isShowingOptions && !browser.searchPanel.optionsButton.isHiddenOrHasHiddenAncestor)
        await pause(0.65)
        check("\(mode): filtering never schedules recursive work", !browser.isSearching && browser.searchSession.request == nil)
        let beforeSameDirectory = browser.model.generation
        browser.navigate(to: root)
        await wait("\(mode): same-directory navigation finishes") { browser.model.generation > beforeSameDirectory }
        check("\(mode): same-directory navigation preserves filter text and its compact hint", browser.nameFilter == "needle" && field.stringValue == "needle" && !browser.searchPanel.view.isHidden && !browser.searchPanel.isShowingOptions && browser.model.items.map(\.name) == ["needle.txt"])
        browser.searchPanel.optionsButton.performClick(nil)
        check("\(mode): expanding options preserves the existing query", browser.searchPanel.isShowingOptions && browser.searchPanel.currentRequest.name == "needle" && field.stringValue == "needle")
        check("\(mode): advanced entry describes name search", field.placeholderString == "Search by Name")
        check("\(mode): advanced options contain no second name entry", !browser.searchPanel.nameField.isDescendant(of: browser.searchPanel.view) || browser.searchPanel.nameField.isHiddenOrHasHiddenAncestor)
        check("\(mode): advanced options contain no Search submit button", !descendants(of: browser.searchPanel.view).contains { ($0 as? NSButton)?.title == "Search" && !$0.isHiddenOrHasHiddenAncestor })
        let focusedEditor = field.currentEditor()
        check("\(mode): expansion focuses the existing toolbar editor", focusedEditor is NSTextView && wc.window?.firstResponder === focusedEditor)
        await searched(browser, name: "needle")
        check("\(mode): expanded search includes matching descendants", Set(browser.model.items.map(\.name)) == ["needle.txt", "needle-child.txt"] && !browser.isFiltering)
        check("\(mode): automatic search keeps the toolbar text and editor", field.stringValue == "needle" && wc.window?.firstResponder === focusedEditor)
        await compositionCommit(mode: mode, in: wc)
        type("needle", in: wc)
        browser.searchPanel.search(nil)
        await searched(browser, name: "needle")

        type("other", in: wc)
        let fallback = wc.tabs.newTab(at: root)
        _ = wc.tabs.closeTab(at: wc.tabs.pages.firstIndex { $0 === page }!)
        await listed(fallback, at: root)
        await pause(0.65)
        check("\(mode): closing a tab cancels its delayed draft without losing it", browser.searchPanel.currentRequest.name == "other" && browser.searchSession.request?.name == "needle")
        check("\(mode): reopening restores the original pane and draft", wc.tabs.reopenClosedTab() && wc.browser === browser && field.stringValue == "other")
        await searched(browser, name: "other")
        check("\(mode): reopened draft replaces the older submitted results", browser.model.items.map(\.name) == ["other.txt"] && browser.searchSession.request?.name == browser.searchPanel.currentRequest.name)
        if let index = wc.tabs.pages.firstIndex(where: { $0 !== page }) { _ = wc.tabs.closeTab(at: index) }
        type("needle", in: wc)
        browser.searchPanel.search(nil)
        await searched(browser, name: "needle")

        type("other", in: wc)
        let other = page.split(with: root)
        await listed(other, at: root)
        check("\(mode): the new pane owns an empty filter entry", wc.browser === other && field.stringValue.isEmpty && !other.searchPanel.isShowingOptions)
        await searched(browser, name: "other")
        check("\(mode): a pending query stays attached to its original pane", browser.model.items.map(\.name) == ["other.txt"] && !other.isSearching && other.searchSession.request == nil && field.stringValue.isEmpty)
        page.activate(browser)
        check("\(mode): returning to the pane restores its recursive draft", field.stringValue == "other" && browser.searchPanel.isShowingOptions && field.placeholderString == "Search by Name")
        let additional = wc.tabs.newTab(at: root)
        await listed(additional, at: root)
        check("\(mode): a new tab does not inherit the search draft", field.stringValue.isEmpty && !additional.searchPanel.isShowingOptions && !additional.isSearching)
        wc.tabs.selectTab(at: wc.tabs.pages.firstIndex { $0 === page }!)
        check("\(mode): returning to the tab restores its active pane entry", wc.browser === browser && field.stringValue == "other")
        if let index = wc.tabs.pages.firstIndex(where: { $0 !== page }) { _ = wc.tabs.closeTab(at: index) }

        let panel = browser.searchPanel
        panel.kindPopup.selectItem(at: SearchKind.allCases.firstIndex(of: .document)!)
        dispatch(panel.kindPopup)
        await wait("\(mode): type changes automatically start a query") {
            browser.searchSession.request?.kind == .document && !browser.searchSession.status.isSearching
        }
        check("\(mode): type changes preserve the name and search root", browser.searchSession.request?.name == "other" && browser.searchSession.request?.rootURL == root)
        panel.datePopup.selectItem(at: 1)
        dispatch(panel.datePopup)
        await wait("\(mode): date changes automatically start a query") {
            browser.searchSession.request?.modifiedAfter != nil && !browser.searchSession.status.isSearching
        }
        check("\(mode): date changes preserve type and name", browser.searchSession.request?.kind == .document && browser.searchSession.request?.name == "other")

        type("needle", in: wc)
        let beforeReturn = browser.searchSession.generation
        guard let editor = field.currentEditor() as? NSTextView else { check("\(mode): Return has a real field editor", false); return }
        let handled = wc.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check("\(mode): Return submits immediately instead of waiting for debounce", handled && browser.searchSession.generation > beforeReturn && browser.searchSession.request?.name == "needle")
        await searched(browser, name: "needle")
        let returnGeneration = browser.searchSession.generation
        await pause(0.65)
        check("\(mode): Return consumes the pending delayed submission", browser.searchSession.generation == returnGeneration,
              "generation=\(returnGeneration)→\(browser.searchSession.generation), query=\(String(describing: browser.searchSession.request)), status=\(browser.searchSession.status.message)")

        type("other", in: wc)
        panel.clear(nil)
        let clearGeneration = browser.searchSession.generation
        await pause(0.65)
        check("\(mode): Clear cancels pending work and resets every condition", browser.searchSession.generation == clearGeneration && browser.searchSession.request == nil && panel.currentRequest.name.isEmpty && panel.currentRequest.content.isEmpty && panel.currentRequest.kind == .any && panel.currentRequest.modifiedAfter == nil && panel.currentRequest.modifiedBefore == nil)
        check("\(mode): Clear synchronizes the single toolbar entry", field.stringValue.isEmpty && browser.searchFieldText.isEmpty && browser.model.items.isEmpty)
        wc.window?.makeFirstResponder(panel.contentField)
        wc.searchFieldDidEndSearching(field)
        check("\(mode): blurring an empty name preserves advanced options", panel.isShowingOptions && !panel.view.isHidden && browser.isSearching && field.stringValue.isEmpty)
        panel.kindPopup.selectItem(at: SearchKind.allCases.firstIndex(of: .document)!)
        dispatch(panel.kindPopup)
        await wait("\(mode): an empty name can search by type") {
            browser.searchSession.request?.name == "" && browser.searchSession.request?.kind == .document
                && !browser.searchSession.status.isSearching
        }
        check("\(mode): a type-only query keeps options open and finds descendants", panel.isShowingOptions && Set(browser.model.items.map(\.name)) == ["needle.txt", "other.txt", "needle-child.txt"])
        panel.clear(nil)
        type("", in: wc)
        let emptyGeneration = browser.searchSession.generation
        await pause(0.65)
        check("\(mode): an empty draft never starts an unrestricted recursive scan", browser.searchSession.request == nil && browser.searchSession.generation == emptyGeneration && browser.model.items.isEmpty)

        type("needle", in: wc)
        browser.navigate(to: child)
        await listed(browser, at: child)
        let navigationGeneration = browser.searchSession.generation
        await pause(0.65)
        check("\(mode): navigation cancels the pending query and collapses options", !browser.isSearching && !browser.searchPanel.isShowingOptions && browser.searchPanel.view.isHidden && browser.searchSession.request == nil && browser.searchSession.generation == navigationGeneration)
        check("\(mode): navigation clears the toolbar and restores filtering mode", field.stringValue.isEmpty && field.placeholderString == "Filter by Name")
        type("needle", in: wc)
        browser.searchPanel.optionsButton.performClick(nil)
        await searched(browser, name: "needle")
        check("\(mode): reopening options uses the new directory and fresh conditions", browser.searchSession.request?.rootURL == child && browser.searchSession.request?.kind == .any && browser.searchSession.request?.modifiedAfter == nil && browser.model.items.map(\.name) == ["needle-child.txt"])
        type("other", in: wc)
        // Blur and cancel are distinct when the name is empty. Dispatch the
        // installed cancel cell's actual target/action instead of a blur hook.
        panel.update(status: "Searching…", resultCount: browser.model.items.count, isRunning: true)
        guard let cancelCell = (field.cell as? NSSearchFieldCell)?.cancelButtonCell,
              let cancelAction = cancelCell.action else { check("\(mode): the field has an explicit cancel action", false); return }
        check("\(mode): the field cancel action is dispatched", NSApp.sendAction(cancelAction, to: cancelCell.target, from: field))
        check("\(mode): native cancel leaves recursive mode", !browser.isSearching && !panel.isShowingOptions && field.stringValue.isEmpty,
              "searching=\(browser.isSearching), options=\(panel.isShowingOptions), field=\(field.stringValue.debugDescription), draft=\(browser.searchFieldText.debugDescription), filter=\(browser.nameFilter.debugDescription)")
        check("\(mode): leaving search resets its running presentation", !panel.isRunning && !panel.cancelButton.isEnabled)
        await listed(browser, at: child)
        let closeGeneration = browser.searchSession.generation
        await pause(0.65)
        check("\(mode): cancelling the field leaves search without a delayed restart", !browser.isSearching && !browser.searchPanel.isShowingOptions && browser.searchPanel.view.isHidden && browser.searchSession.generation == closeGeneration && field.stringValue.isEmpty)
        check("\(mode): cancelling returns keyboard focus to the file view", wc.window?.firstResponder === browser.focusView)
    }

    @MainActor private static func compositionCommit(mode: ViewMode, in wc: MainWindowController) async {
        let browser = wc.browser
        wc.focusFilter(nil)
        guard let field = wc.searchField, let editor = field.currentEditor() as? NSTextView else {
            check("\(mode): IME regression has the real toolbar editor", false); return
        }
        let notification = Notification(name: NSControl.textDidChangeNotification, object: field)
        let beforeComposition = browser.searchSession.generation
        let candidate = "文档"
        editor.setMarkedText(candidate, selectedRange: NSRange(location: candidate.utf16.count, length: 0),
                             replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.didChangeText()
        wc.controlTextDidChange(notification)
        check("\(mode): the candidate is stored while the editor still has marked text",
              editor.hasMarkedText() && field.stringValue == candidate && browser.searchPanel.currentRequest.name == candidate)
        await pause(0.65)
        check("\(mode): marked name text never starts a recursive query",
              browser.searchSession.generation == beforeComposition && browser.searchSession.request?.name == "needle")
        editor.unmarkText()
        wc.controlTextDidChange(notification)
        check("\(mode): committing preserves the candidate characters", !editor.hasMarkedText() && field.stringValue == candidate)
        await searched(browser, name: candidate)
        let committedGeneration = browser.searchSession.generation
        check("\(mode): unchanged IME commit starts exactly one query and keeps editing focus",
              committedGeneration == beforeComposition + 1 && wc.window?.firstResponder === editor)
        wc.controlTextDidChange(notification)
        await pause(0.65)
        check("\(mode): duplicate committed-text notification does not repeat the query",
              browser.searchSession.generation == committedGeneration)

        // Return can execute before a final unchanged text notification. It
        // must consume the remembered composition as well as the timer.
        editor.setMarkedText("other", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.didChangeText()
        wc.controlTextDidChange(notification)
        editor.unmarkText()
        let handled = wc.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        let returnGeneration = browser.searchSession.generation
        check("\(mode): Return immediately submits the committed IME candidate",
              handled && returnGeneration == committedGeneration + 1 && browser.searchSession.request?.name == "other")
        wc.controlTextDidChange(notification)
        await searched(browser, name: "other")
        await pause(0.65)
        check("\(mode): the post-Return text notification cannot queue another IME query",
              browser.searchSession.generation == returnGeneration)
    }

    @MainActor private static func savedQueries(root: URL) async {
        let suite = "com.tursora.smoke.search-entry-saved." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedSearchStore(defaults: defaults)
        let panel = SearchPanelController(store: store)
        panel.configure(rootURL: root)
        panel.setShowsOptions(true)
        var requests: [SearchRequest] = []
        var clears = 0
        panel.onSearch = { requests.append($0) }
        panel.onClear = { clears += 1 }
        let empty = store.save(name: "Empty Conditions", request: SearchRequest(rootURL: root))
        panel.refreshSavedSearches(selecting: empty.id)
        panel.openSavedButton.performClick(nil)
        await pause(0.65)
        check("opening empty saved conditions clears instead of scanning all files", requests.isEmpty && clears == 1 && panel.currentRequest == empty.request)
        let typed = store.save(name: "Documents", request: SearchRequest(rootURL: root, kind: .document))
        panel.refreshSavedSearches(selecting: typed.id)
        panel.openSavedButton.performClick(nil)
        check("opening saved type-only conditions still starts a valid query", requests == [typed.request] && clears == 1)
    }

    @MainActor private static func type(_ value: String, in wc: MainWindowController) {
        wc.focusFilter(nil)
        guard let field = wc.searchField else { check("typing has a toolbar field", false); return }
        field.stringValue = value
        field.currentEditor()?.string = value
        wc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor private static func dispatch(_ control: NSControl) {
        guard let action = control.action else { check("condition control has a production action", false); return }
        check("condition control dispatches through its target", NSApp.sendAction(action, to: control.target, from: control))
    }

    @MainActor private static func listed(_ browser: BrowserViewController, at url: URL) async {
        let expectedName = url.lastPathComponent == "Child" ? "needle-child.txt" : "needle.txt"
        await wait("directory listing finishes") {
            browser.currentURL?.standardizedFileURL == url.standardizedFileURL
                && browser.model.url?.standardizedFileURL == url.standardizedFileURL
                && browser.model.generation > 0 && !browser.model.isSearchResults && !browser.isSearching
                && browser.model.items.contains { $0.name == expectedName }
        }
    }

    @MainActor private static func searched(_ browser: BrowserViewController, name: String) async {
        await wait("recursive query for \(name) finishes") {
            browser.isSearching && browser.model.isSearchResults && browser.searchSession.request?.name == name && !browser.searchSession.status.isSearching
        }
        guard case .finished = browser.searchSession.status else {
            check("recursive query succeeds", false, browser.searchSession.status.message); return
        }
    }

    @MainActor private static func wait(_ label: String, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { await pause(0.04) }
        check(label, condition())
    }

    @MainActor private static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        print("\(success ? "ok  " : "FAIL") search entry: \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !success { exit(1) }
    }
}

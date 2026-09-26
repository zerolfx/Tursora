import AppKit
import Quartz

/// Headless-ish self check, enabled with TURSORA_SMOKE_TEST=1. Exercises the
/// real window, model, history, tabs and address bar, reports assertions and
/// suite timings, and exits non-zero on the first failure. Used because CI (and
/// sandboxed terminals) cannot look at the screen.
enum SmokeTest: SmokeSuite {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["TURSORA_SMOKE_TEST"] != nil }

    static func run(_ wc: MainWindowController) {
        // Keep the last completed check available even if AppKit catches an
        // Objective-C exception before the asynchronous suite can report it.
        setvbuf(stdout, nil, _IOLBF, 0)
        atexit {
            try? DirectoryViewPropertiesStore.shared.flush()
            try? FileManager.default.removeItem(at: DirectoryViewPropertiesStore.shared.fileURL.deletingLastPathComponent())
            ArchiveWorkspace.shared.shutdownAll()
            try? FileManager.default.removeItem(at: TrashOrigins.shared.fileURL.deletingLastPathComponent())
        }
        AppPreferences.showFileExtensions = true
        AppPreferences.restoreWorkspaceOnLaunch = true
        // Exercise the legacy opt-out routes in the general suite. Dedicated
        // ZIP and workspace suites remove these keys to cover fresh defaults.
        AppPreferences.experimentalTerminalEnabled = false
        AppPreferences.experimentalZIPBrowsingEnabled = false
        AppPreferences.shared.shortcuts.resetAll()
        AppPreferences.shared.resetFilterShortcut()
        // A ZIP's private copy is let go only when a check asks (D103), so no
        // suite loses a session to a timer mid-check.
        ArchiveWorkspace.shared.evictionSchedule = .manual
        // A failed earlier run may have left view state behind; start from defaults.
        wc.browser.setGroupKey(.none)
        wc.browser.setViewMode(.details)
        // Each named step owns its asynchronous continuation and timing.
        // The legacy navigation chain closes its final timing at run completion.
        typealias Step = (name: String, run: (@escaping () -> Void) -> Void)
        let steps: [Step] = [
            ("Preferences isolation", { done in PreferencesIsolationSmokeTests.run(); done() }),
            ("Dock menu", DockMenuSmokeTests.run),
            ("Directory view properties", DirectoryViewPropertiesSmokeTests.run),
            ("View options and column widths", ViewOptionsSmokeTests.run),
            ("Directory loading", DirectoryLoadingSmokeTests.run),
            ("Path completion", PathCompletionSmokeTests.run),
            ("File mutation safety", FileMutationSafetySmokeTests.run),
            ("Sort, columns and sizes", SortColumnSizesSmokeTests.run),
            ("Markdown rendering", { done in MarkdownRendererSmokeTests.run(); done() }),
            ("Icon assets", { done in IconAssetsSmokeTests.run(); done() }),
            ("Server connections", { done in ServerConnectionSmokeTests.run(); done() }),
            ("Settings", { done in SettingsSmokeTests.run(); done() }),
            ("Updates", { done in UpdateSmokeTests.run(); done() }),
            ("Workspace session model", { done in WorkspaceSessionModelSmokeTests.run(); done() }),
            ("Preview pane", PreviewPaneSmokeTests.run),
            ("Column view", ColumnViewSmokeTests.run),
            ("Workspace session UI", WorkspaceSessionSmokeTests.run),
            ("Workspace restoration races", WorkspaceRaceSmokeTests.run),
            ("Workspace continuity", WorkspaceContinuitySmokeTests.run),
            ("Tab appearance", { done in TabAppearanceSmokeTests.run(); done() }),
            ("Info disclosures", { done in InfoDisclosureSmokeTests.run(); done() }),
            ("Appearance", { done in AppearanceSmokeTests.run(browser: wc.browser, completion: done) }),
            ("Text thumbnails", TextThumbnailSmokeTests.run),
            ("Transfers", { done in TransferSmokeTests.run(wc, completion: done) }),
            ("Archive operations", ArchiveSmokeTests.run),
            ("Archive workspace", ArchiveWorkspaceSmokeTests.run),
            ("Archive preparation", ArchivePreparationSmokeTests.run),
            ("Archive browser", ArchiveBrowserSmokeTests.run),
            ("Extract task", ExtractTaskSmokeTests.run),
            ("Compression task", CompressionTaskSmokeTests.run),
            ("Lazy archive", LazyArchiveSmokeTests.run),
            ("Archive open", ArchiveOpenSmokeTests.run),
            ("Archive eviction", ArchiveEvictionSmokeTests.run),
            ("Archive export", ArchiveExportSmokeTests.run),
            ("Split toolbar", SplitToolbarSmokeTests.run),
            ("Folder tree", FolderTreeSmokeTests.run),
            ("Trash", TrashSmokeTests.run),
            ("Shortcuts", ShortcutSmokeTests.run),
            ("Command palette", CommandPaletteSmokeTests.run),
            ("Terminal toolbar", TerminalToolbarSmokeTests.run),
            ("Terminal", TerminalSmokeTests.run),
            ("Terminal directory sync", TerminalDirectorySyncSmokeTests.run),
            ("Terminal shell sync", TerminalShellSyncSmokeTests.run),
            ("Terminal preferences", TerminalPreferencesSmokeTests.run),
            ("Terminal activity", TerminalActivitySmokeTests.run),
            ("Status bar", StatusBarSmokeTests.run),
            ("Terminal session", TerminalSessionSmokeTests.run),
            ("Search entry", SearchEntrySmokeTests.run),
            ("Content search", ContentSearchSmokeTests.run),
            ("Search", SearchSmokeTests.run),
            ("Integrated search", IntegratedSearchSmokeTests.run),
            ("Pane paths", PanePathsSmokeTests.run),
            ("Tab actions", TabActionsSmokeTests.run),
            ("Batch rename", BatchRenameSmokeTests.run),
            ("Everyday commands", EverydayCommandsSmokeTests.run),
            ("Drag and drop", DragAndDropSmokeTests.run),
            ("Delayed listing", delayedListing),
            ("Legacy navigation and file operations", { _ in
                infoSectionLayout()
                savedViewModes(wc.provider)
                preferencesIntegration(wc) { windowChrome(wc) { navigation(wc) } }
            }),
        ]
        func runSteps(_ remaining: ArraySlice<Step>) {
            guard let step = remaining.first else { return }
            SmokeReport.shared.beginSuite(step.name)
            step.run {
                SmokeReport.shared.endSuite()
                runSteps(remaining.dropFirst())
            }
        }
        // A cold directory listing can outlive the old one-second delay.
        // Generation records completion, including an empty result or an error.
        awaitInitialListing(wc.browser.model) { runSteps(steps[...]) }
    }

    private static func after(_ s: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
    }

    private static func awaitCondition(_ name: String, timeout: TimeInterval = 5,
                                       recordsSuccess: Bool = true,
                                       condition: @escaping () -> Bool, completion: @escaping () -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func poll() {
            if condition() { if recordsSuccess { check(name, true) }; completion() }
            else if ProcessInfo.processInfo.systemUptime >= deadline { check(name, false, "Timed out after \(timeout)s") }
            else { after(0.05, poll) }
        }
        poll()
    }

    /// Let coalesced filesystem notifications from the previous mutation settle
    /// before testing an unrelated click-to-rename timer.
    private static func awaitQuietListing(_ model: DirectoryModel, completion: @escaping () -> Void) {
        var generation = model.generation
        var quietSince = ProcessInfo.processInfo.systemUptime
        awaitCondition("filesystem refresh settles before delayed rename", condition: {
            let now = ProcessInfo.processInfo.systemUptime
            if model.generation != generation { generation = model.generation; quietSince = now }
            return now - quietSince >= 0.75
        }, completion: completion)
    }

    private static func awaitInitialListing(_ model: DirectoryModel, timeout: TimeInterval = 15,
                                            completion: @escaping () -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func poll() {
            if model.generation > 0 {
                completion()
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                check("initial directory listing completed", false,
                      "Timed out after \(timeout)s: \(model.url?.path ?? "not started"), generation=\(model.generation)")
            } else {
                after(0.05, poll)
            }
        }
        poll()
    }

    private static func delayedListing(completion: @escaping () -> Void) {
        print("== asynchronous startup listing ==")
        // Empty results still complete; waiting for a nonzero item count would
        // hang. The delay runs on the background provider, never the main run loop.
        let provider = SmokeFixtures.EmptyProvider(listingDelay: 1.25)
        let model = DirectoryModel(provider: provider)
        var passedOldDeadline = false
        model.load(provider.homeURL)
        after(1) {
            passedOldDeadline = true
            check("slow listing is still pending after one second", model.generation == 0)
        }
        awaitInitialListing(model) {
            check("listing wait keeps the main run loop responsive", passedOldDeadline)
            check("listing wait accepts an empty completed directory", model.generation == 1 && model.items.isEmpty)
            completion()
        }
    }

    private static func infoSectionLayout() {
        print("== Info section layout ==")
        let key = "smoke-layout"
        let preferenceKey = InfoSection.explicitPreferenceKey(for: key)
        let remembered = AppDefaults.shared.object(forKey: preferenceKey)
        defer { AppDefaults.shared.set(remembered, forKey: preferenceKey) }
        let content = NSView()
        content.heightAnchor.constraint(equalToConstant: 200).isActive = true
        let section = InfoSection(key: key, title: "Preview:", content: content)
        section.isExpanded = true
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        host.addSubview(section)
        section.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            section.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            section.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        check("Info section content fills the inset width", abs(content.frame.width - 328) < 1,
              "content=\(content.frame), section=\(section.frame)")
        check("Info section content starts at the left inset", abs(content.convert(content.bounds, to: section).minX - 16) < 1)
        check("Info section header fills the inset width", abs((section.arrangedSubviews.first?.frame.width ?? 0) - 328) < 1)
        section.toggle()
        host.layoutSubtreeIfNeeded()
        check("Info section collapse reduces its height", section.frame.height < 80)
        section.toggle()
        host.setFrameSize(NSSize(width: 440, height: 300))
        host.layoutSubtreeIfNeeded()
        check("Info section expands and follows resize", abs(content.frame.width - 408) < 1 && section.frame.height > 200)
    }

    private static func savedViewModes(_ provider: FileProvider) {
        print("== saved view modes ==")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-saved-mode-" + UUID().uuidString).appendingPathComponent("views.json")
        let store = DirectoryViewPropertiesStore(fileURL: file)
        defer { try? store.flush(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for mode in ViewMode.allCases {
            var properties = DirectoryViewProperties()
            properties.viewMode = mode
            store.setDefault(properties)
            let pane = BrowserViewController(provider: provider, initialURL: provider.homeURL, viewPropertiesStore: store)
            _ = pane.view
            let expected: FileViewing
            switch mode {
            case .icons: expected = pane.iconGrid
            case .details: expected = pane.fileList
            case .columns: expected = pane.columnView
            }
            check("new pane mounts saved \(mode) view", pane.viewMode == mode && pane.fileView === expected)
            check("saved \(mode) view is attached", expected.viewController.parent === pane && expected.viewController.view.superview != nil)
            check("saved \(mode) zoom matches the view", pane.zoomIndex == properties.zoomIndex(for: mode))
        }
    }

    private static func preferencesIntegration(_ wc: MainWindowController, completion: @escaping () -> Void) {
        print("== settings integration ==")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-settings-" + UUID().uuidString).resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("sample.txt")
        try! Data("sample".utf8).write(to: file)
        let folder = directory.appendingPathComponent("folder.v1")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let nestedFile = folder.appendingPathComponent("sample.txt")
        try! Data("nested".utf8).write(to: nestedFile)
        let b = wc.tabs.newTab(at: directory)
        awaitInitialListing(b.model) {
            check("explicit terminal opt-out leaves no panel", wc.terminalPanel == nil && !AppPreferences.experimentalTerminalEnabled)
            check("explicit ZIP browsing opt-out remains effective", !AppPreferences.experimentalZIPBrowsingEnabled)
            func menuItem(_ action: Selector, in menu: NSMenu?) -> NSMenuItem? {
                for item in menu?.items ?? [] {
                    if item.action == action { return item }
                    if let found = menuItem(action, in: item.submenu) { return found }
                }
                return nil
            }
            let filterItem = menuItem(#selector(MainWindowController.focusFilter(_:)), in: NSApp.mainMenu)
            let terminalItem = menuItem(#selector(MainWindowController.toggleTerminal(_:)), in: NSApp.mainMenu)
            check("terminal command hidden while disabled", terminalItem?.isHidden == true)
            try! AppPreferences.shared.setFilterShortcut(.init(keyEquivalent: "f", modifierFlags: [.command, .option, .shift]), menu: NSApp.mainMenu)
            check("filter shortcut updates the real menu immediately", filterItem?.keyEquivalent == "f" && filterItem?.keyEquivalentModifierMask == [.command, .option, .shift])
            AppPreferences.shared.resetFilterShortcut()
            check("filter shortcut reset restores Command F", filterItem?.keyEquivalentModifierMask == .command)
            b.setViewMode(.details)
            if let folderNode = b.model.node(for: folder) {
                b.fileList.expand(folderNode)
                b.fileView.select(urls: [nestedFile])
                check("exact selection distinguishes nested duplicate names", b.fileView.selectedItems.map { $0.url.standardizedFileURL } == [nestedFile.standardizedFileURL])
                b.fileList.cutURLs = [nestedFile]
                check("cut appearance preserves nested file identity", b.fileView.selectedItems.map { $0.url.standardizedFileURL } == [nestedFile.standardizedFileURL])
                b.fileList.cutURLs = []
                b.fileList.collapse(folderNode)
            }
            for mode in ViewMode.allCases {
                b.setViewMode(mode)
                wc.window?.contentView?.layoutSubtreeIfNeeded()
                b.fileView.select(urls: [file])
                AppPreferences.showFileExtensions = false
                check("\(mode.rawValue): hiding extensions keeps exact selection", b.fileView.selectedItems.map { $0.url.standardizedFileURL } == [file.standardizedFileURL], "selected=\(b.fileView.selectedItems.map(\.url)) expected=\(file) rows=\(b.fileList.tableView.numberOfRows) items=\(b.model.items.map(\.url))")
                check("\(mode.rawValue): filename display hides extension only", b.model.items.first { $0.url.standardizedFileURL == file.standardizedFileURL }?.displayName == "sample" && FileItem(url: folder)?.displayName == "folder.v1")
                if let item = b.model.items.first(where: { $0.url.standardizedFileURL == file.standardizedFileURL }) {
                    b.fileView.beginRename(item: item)
                    let editor = wc.window?.firstResponder as? NSTextView
                    check("\(mode.rawValue): rename retains the full extension", editor?.string == "sample.txt", editor?.string ?? "no editor")
                    // Finder preselects the base name so typing keeps the
                    // extension; selecting the whole string would turn a typed
                    // word into a file with no extension at all.
                    check("\(mode.rawValue): rename preselects the base name, not the extension",
                          editor?.selectedRange() == NSRange(location: 0, length: 6),
                          "\(editor?.selectedRange() ?? NSRange(location: -1, length: -1))")
                    editor?.string = "changed-name.txt"
                    if let editor, let delegate = editor.delegate as? NSTextField {
                        _ = delegate.delegate?.control?(delegate, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
                    } else {
                        // NSTextView does not implement cancelOperation: itself; a real
                        // Escape reaches it through doCommand(by:), which walks the
                        // responder chain — the column view's browser handles it there.
                        editor?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                    }
                    check("\(mode.rawValue): Escape cancels typed rename", FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("changed-name.txt").path))
                    wc.window?.makeFirstResponder(b.focusView)
                }
                AppPreferences.showFileExtensions = true
                check("\(mode.rawValue): showing extensions restores full display name", FileItem(url: file)?.displayName == "sample.txt")
            }
            AppPreferences.experimentalTerminalEnabled = true
            check("enabling experiment reveals terminal command", terminalItem?.isHidden == false)
            wc.toggleTerminal(nil)
            check("terminal panel opens without a user shell in smoke mode", wc.terminalPanel != nil && wc.terminalPanel?.isRunning == false)
            check("terminal starts in active folder", wc.terminalPanel?.pendingDirectory.standardizedFileURL == directory.standardizedFileURL)
            AppPreferences.experimentalTerminalEnabled = false
            check("disabling terminal hides its retained session immediately", !wc.isTerminalVisible && wc.terminalPanel != nil && terminalItem?.isHidden == true)
            check("display preference does not rename the actual file", FileManager.default.fileExists(atPath: file.path))
            b.setViewMode(.details)
            if let folderNode = b.model.node(for: folder) { b.fileList.expand(folderNode) }
            b.fileView.select(urls: [nestedFile])
            let generation = b.model.generation
            b.refreshPreservingSelection()
            awaitCondition("external refresh completes with duplicate filenames", condition: { b.model.generation > generation }) {
                check("external refresh keeps the nested file selected", b.fileView.selectedItems.map { $0.url.standardizedFileURL } == [nestedFile.standardizedFileURL])
                _ = wc.tabs.closeCurrentTab()
                try? FileManager.default.removeItem(at: directory)
                completion()
            }
        }
    }

    private static func windowChrome(_ wc: MainWindowController, completion: @escaping () -> Void) {
        print("== window chrome ==")
        guard let window = wc.window else { check("window exists", false); return }
        window.contentView?.layoutSubtreeIfNeeded()
        let sidebar = wc.sidebar.outlineView
        let symbol = wc.sidebar.symbolView(atRow: wc.sidebar.row(for: wc.provider.homeURL))
        symbol?.superview?.layoutSubtreeIfNeeded()
        check("Home symbol uses the shared 18pt sidebar canvas", symbol.map { $0.alignmentRect(forFrame: $0.frame).size } == NSSize(width: 18, height: 18), "\(String(describing: symbol?.frame))")
        check("small SF Symbols can scale up", symbol?.imageScaling == .scaleProportionallyUpOrDown)
        let side = wc.sidebar.view.convert(wc.sidebar.view.bounds, to: nil)
        let content = wc.tabs.view.convert(wc.tabs.view.bounds, to: nil)
        check("sidebar and content share full-height edges", abs(side.minY - content.minY) < 1 && abs(side.maxY - content.maxY) < 1)
        check("sidebar starts at a practical width", (160...220).contains(side.width), "\(side.width)")
        let item = window.toolbar?.items.first
        check("sidebar toggle is a fixed leading navigation item", item?.itemIdentifier.rawValue == "tursora.sidebar" && item?.isNavigational == true)
        let originalWindowFrame = window.frame
        let originalButtonFrame = item?.view.map { $0.convert($0.bounds, to: nil) }
        window.makeFirstResponder(sidebar)
        wc.toggleSidebar(nil)
        after(0.2) {
            window.contentView?.layoutSubtreeIfNeeded()
            check("sidebar collapses without moving the window", wc.isSidebarCollapsed && window.frame == originalWindowFrame)
            check("collapsing restores visible browser focus", window.firstResponder === wc.browser.focusView)
            if let originalButtonFrame, let view = item?.view {
                check("sidebar toggle does not move after collapse", view.convert(view.bounds, to: nil) == originalButtonFrame)
            }
            wc.toggleSidebar(nil)
            after(0.2) {
                window.contentView?.layoutSubtreeIfNeeded()
                check("sidebar expands without moving the window", !wc.isSidebarCollapsed && window.frame == originalWindowFrame)
                if let originalButtonFrame, let view = item?.view {
                    check("sidebar toggle does not move after expansion", view.convert(view.bounds, to: nil) == originalButtonFrame)
                }
                completion()
            }
        }
    }

    // MARK: 1. Navigation, sidebar, list

    private static func navigation(_ wc: MainWindowController) {
        let b = wc.browser
        let home = b.provider.homeURL
        print("== navigation ==")
        check("window title", wc.window?.title == b.provider.displayName(for: home), "\(wc.window?.title ?? "nil")")
        check("window does not repeat the breadcrumb path", wc.window?.subtitle == "", "\(wc.window?.subtitle ?? "nil")")
        check("home listed", b.model.items.count > 0, "\(b.model.items.count) items")
        check("sidebar rows", wc.sidebar.outlineView.numberOfRows > 2, "\(wc.sidebar.outlineView.numberOfRows) rows")
        check("sidebar synced to Home", wc.sidebar.outlineView.selectedRow >= 0)
        check("table rows match model", b.fileList.tableView.numberOfRows == b.model.items.count)
        // Home is listed under the default Name key, where folders do lead.
        check("folders sorted first when sorting by name", {
            let items = b.model.items
            guard let firstFile = items.firstIndex(where: { !$0.isNavigable }) else { return true }
            return !items[firstFile...].contains { $0.isNavigable }
        }())
        check("hidden files hidden", !b.model.items.contains { $0.isHidden })
        // Regression: the first tab's view was attached hidden and never shown.
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        check("browser view is visible", !b.view.isHidden)
        check("browser view has size", b.view.frame.height > 150 && b.view.frame.width > 300,
              "\(b.view.frame.size)")
        check("file list fills the browser", b.fileList.view.frame.height > 150, "\(b.fileList.view.frame.size)")
        check("table is inside the window", b.fileList.tableView.window === wc.window)
        check("no history yet", !b.canGoBack && !b.canGoForward)
        check("address bar: home is one segment", wc.tabs.addressBar.segmentCount == 1,
              "\(wc.tabs.addressBar.segmentTitles)")
        check("tab bar stays visible with one tab", !wc.tabs.tabBar.isHidden)

        guard let folder = b.model.items.first(where: { $0.isNavigable }) else {
            fail("navigation fixture has a subfolder", "Home contains no navigable folder; the remaining integration checks cannot run")
        }
        print("→ select \(folder.name) and Open (double-click / ⌘↓ path)")
        b.fileList.select(name: folder.name)
        check("selection applied", b.fileList.selectedItems.first?.name == folder.name)
        wc.openSelection(nil)
        after(0.6) { insideFolder(wc, folder) }
    }

    private static func insideFolder(_ wc: MainWindowController, _ folder: FileItem) {
        let b = wc.browser
        check("currentURL updated", b.currentURL?.standardizedFileURL == folder.url.standardizedFileURL)
        check("title follows folder", wc.window?.title == b.provider.displayName(for: folder.url))
        check("representedURL set", wc.window?.representedURL == folder.url)
        check("can go back", b.canGoBack && !b.canGoForward)
        let bar = wc.tabs.addressBar
        check("address bar: two segments", bar.segmentCount == 2, "\(bar.segmentTitles)")
        check("address bar: last segment is folder", bar.segmentTitles.last == b.provider.displayName(for: folder.url))
        let menu = bar.subfolderMenu(of: b.provider.homeURL, current: folder.url)
        check("sibling menu lists home's subfolders", menu.items.count >= 1, "\(menu.items.count) items")
        check("sibling menu ticks the current one", menu.items.first { $0.state == .on }?.title == folder.name)

        print("→ go up")
        b.goUp()
        after(0.6) { backHome(wc, folder) }
    }

    private static func backHome(_ wc: MainWindowController, _ folder: FileItem) {
        let b = wc.browser
        check("back at home", b.currentURL?.standardizedFileURL == b.provider.homeURL.standardizedFileURL)
        check("left folder selected after go-up", b.fileList.selectedItems.first?.name == folder.name)
        check("history: home, folder, home", b.history.entries.count == 3 && b.history.index == 2)
        b.goBack()
        after(0.5) {
            check("goBack landed in folder", b.currentURL?.lastPathComponent == folder.name)
            b.goForward()
            after(0.5) {
                check("goForward landed home", b.currentURL?.standardizedFileURL == b.provider.homeURL.standardizedFileURL)
                b.showsHiddenFiles = true
                check("hidden files now visible", b.model.items.contains { $0.isHidden })
                b.showsHiddenFiles = false
                tabs(wc, folder)
            }
        }
    }

    // MARK: 2. Tabs

    private static func tabs(_ wc: MainWindowController, _ folder: FileItem) {
        print("== tabs ==")
        let t = wc.tabs
        let first = t.current
        t.newTab(at: folder.url)
        check("newTab: count 2, current is new", t.count == 2 && t.currentIndex == 1)
        check("tab bar visible with two tabs", !t.tabBar.isHidden)
        check("tabs have independent history", t.current !== first && t.current.history.entries.count <= 1)
        after(0.5) {
            check("new tab loaded its folder", t.current.currentURL?.lastPathComponent == folder.name)
            check("window title follows current tab", wc.window?.title == wc.provider.displayName(for: folder.url))
            check("address bar follows current tab", t.addressBar.segmentTitles.last == wc.provider.displayName(for: folder.url))
            check("tab titles", t.tabBar.titles.count == 2 && t.tabBar.titles[1] == wc.provider.displayName(for: folder.url), "\(t.tabBar.titles)")
            t.selectTab(at: 0)
            check("selectTab(0)", t.currentIndex == 0 && t.current === first)
            check("window title back to first tab", wc.window?.title == wc.provider.displayName(for: wc.provider.homeURL))
            t.selectNext(); check("selectNext wraps forward", t.currentIndex == 1)
            t.selectNext(); check("selectNext wraps around", t.currentIndex == 0)
            t.selectPrevious(); check("selectPrevious wraps around", t.currentIndex == 1)
            t.moveTab(from: 1, to: 0)
            check("moveTab keeps current tab current", t.currentIndex == 0 && t.current !== first)
            t.moveTab(from: 0, to: 1)
            check("closeCurrentTab", t.closeCurrentTab() && t.count == 1)
            check("single tab keeps its title and context menu visible", !t.tabBar.isHidden)
            check("can reopen", t.canReopenClosedTab)
            check("reopenClosedTab restores it", t.reopenClosedTab() && t.count == 2 && t.current.currentURL?.lastPathComponent == folder.name)
            check("reopened tab kept its history", t.current.history.entries.count == 1)
            check("last tab cannot be closed via closeTab", { t.closeTab(at: 1); return !t.closeCurrentTab() && t.count == 1 }())
            addressBarEditing(wc, folder)
        }
    }

    // MARK: 3. Address bar edit mode + completion

    private static func addressBarEditing(_ wc: MainWindowController, _ folder: FileItem) {
        Task { @MainActor in
            print("== address bar ==")
            let home = wc.provider.homeURL
            let bar = wc.tabs.addressBar
            check("resolve ~", PathCompleter.resolveDirectory("~", cwd: home, home: home) == home.standardizedFileURL)
            check("resolve ~/folder", PathCompleter.resolveDirectory("~/\(folder.name)", cwd: home, home: home)?.lastPathComponent == folder.name)
            check("resolve relative", PathCompleter.resolveDirectory(folder.name, cwd: home, home: home)?.lastPathComponent == folder.name)
            check("resolve rejects a file / nonsense", PathCompleter.resolveDirectory("/definitely/not/here", cwd: home, home: home) == nil)
            let partial = String(folder.name.prefix(2))
            let comps = PathCompleter.completions(for: "~/\(partial)", cwd: home, home: home)
            check("completion for ~/\(partial) contains \(folder.name)/", comps.contains(folder.name + "/"), "\(comps)")
            check("completions end with /", comps.allSatisfy { $0.hasSuffix("/") })
            check("split last component", PathCompleter.splitLastComponent("~/Work/Do") == ("~/Work/", "Do"))

            bar.beginEditing()
            check("beginEditing enters edit mode", bar.isEditing)
            check("text field is first responder", wc.window?.firstResponder is NSTextView)
            check("commit rejects bad path", !bar.commit("/definitely/not/here") && bar.isEditing)

            // inline completion: type "~/Ap" (two chars of the folder name) after select-all
            guard let ed = bar.textField.currentEditor() as? NSTextView else { check("field editor", false); return }
            let typed = "~/" + partial
            ed.string = typed; ed.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
            bar.textChanged()
            await waitUntil("address completion finishes") { !bar.isCompletingPath }
            check("inline fill completes the folder name", bar.textField.stringValue == "~/\(folder.name)/", bar.textField.stringValue)
            check("typed part stays before the caret", bar.typedText == typed, bar.typedText)
            check("completed tail is selected", bar.inlineCompletion == String(folder.name.dropFirst(partial.count)) + "/", "\(bar.inlineCompletion ?? "nil")")
            check("candidate list is showing", bar.completion.isVisible && bar.completion.candidates.first == folder.name + "/", "\(bar.completion.candidates)")
            let g = bar.completion.geometryForTesting
            check("popup height fits its rows", g.panelHeight == CGFloat(bar.completion.candidates.count) * 22 + 8 && g.clipHeight >= g.tableHeight - 0.5, "panel \(g.panelHeight) clip \(g.clipHeight) table \(g.tableHeight)")
            check("first row is fully inside the popup", g.firstRow.minY >= 0 && g.firstRow.maxY <= g.panelHeight + 0.5, "\(g.firstRow) in \(g.panelHeight)")
            check("first row sits at the top, not the bottom", abs(g.firstRow.maxY - (g.panelHeight - 4)) < 1, "row maxY \(g.firstRow.maxY), expected \(g.panelHeight - 4)")
            // deleting must not re-fill
            ed.string = "~/" + String(partial.prefix(1)); ed.setSelectedRange(NSRange(location: 3, length: 0))
            bar.textChanged()
            await waitUntil("address completion finishes") { !bar.isCompletingPath }
            check("no inline fill while deleting", bar.textField.stringValue == "~/" + String(partial.prefix(1)), bar.textField.stringValue)
            // Tab accepts, then the list moves on to the folder's children
            ed.string = typed; ed.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0)); bar.textChanged()
            await waitUntil("address completion finishes") { !bar.isCompletingPath }
            check("Tab accepts the inline completion", bar.acceptCompletion() && bar.inlineCompletion == nil && bar.textField.stringValue == "~/\(folder.name)/")
            await waitUntil("accepted completion lists subfolders") { !bar.isCompletingPath }
            let inside = PathCompleter.completions(for: "~/\(folder.name)/", cwd: home, home: home)
            check("after accept the list shows the folder's subfolders", bar.completion.candidates == inside, "\(bar.completion.candidates.count) vs \(inside.count)")
            if !inside.isEmpty {
                let g2 = bar.completion.geometryForTesting
                check("re-shown list is pinned to the top too", abs(g2.firstRow.maxY - (g2.panelHeight - 4)) < 1 && g2.firstRow.minY >= 0, "row \(g2.firstRow) panel \(g2.panelHeight)")
            }
            // ↓ selects in the list, Return accepts and navigates
            ed.string = typed; ed.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0)); bar.textChanged()
            await waitUntil("address completion finishes") { !bar.isCompletingPath }
            _ = bar.control(bar.textField, textView: ed, doCommandBy: #selector(NSResponder.moveDown(_:)))
            check("↓ selects the first candidate", bar.completion.selectedCandidate == folder.name + "/")
            _ = bar.control(bar.textField, textView: ed, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            check("Return commits the completed path", !bar.isEditing && !bar.completion.isVisible)
            after(0.5) {
                check("edit-commit landed", wc.browser.currentURL?.lastPathComponent == folder.name)
                check("focus returned to list", wc.window?.firstResponder === wc.browser.fileList.tableView)
                narrowAddressBar(wc)
                contextMenus(wc, folder)
            }
        }
    }

    /// A standalone bar at 260pt showing a deep path: leading segments must
    /// fold into "…" and nothing may run past the right edge.
    private static func narrowAddressBar(_ wc: MainWindowController) {
        print("== narrow address bar ==")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-narrow-\(getpid())")
        let deep = tmp.appendingPathComponent("A very long folder name number one")
            .appendingPathComponent("Another quite long folder name two").appendingPathComponent("third")
        try? FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let bar = BreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 260, height: BreadcrumbBar.height))
        bar.url = deep
        bar.layout()
        let frames = bar.visibleSegmentFrames
        check("deep path folds leading segments", bar.hasOverflowMenu && frames.count < bar.segmentCount, "\(frames.count) of \(bar.segmentCount) visible")
        check("nothing runs past the right edge", (frames.map(\.maxX).max() ?? 0) <= 260 - 6 + 20, "max x \(frames.map(\.maxX).max() ?? 0)")
        // two very long segments cannot fold (root is kept): they must shrink instead
        let two = BreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 220, height: BreadcrumbBar.height))
        two.url = deep.deletingLastPathComponent().deletingLastPathComponent()   // volume › …tmp… › "A very long…"
        two.layout()
        let f2 = two.visibleSegmentFrames
        check("long segments shrink to fit", (f2.map(\.maxX).max() ?? 0) <= 220, "max x \(f2.map(\.maxX).max() ?? 0), \(f2.count) visible")
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: 4. Context menus + new folder

    private static func contextMenus(_ wc: MainWindowController, _ folder: FileItem) {
        print("== context menu ==")
        let b = wc.browser
        let bg = b.buildContextMenu(for: []).items.map(\.title)
        check("background menu has New Folder / Sort By", bg.contains("New Folder") && bg.contains("Sort By"), "\(bg)")
        let onFolder = b.buildContextMenu(for: [folder]).items.map(\.title)
        check("folder menu stays in Tursora with Open in New Tab / Copy Path / Favourites",
              onFolder.contains("Open in New Tab") && !onFolder.contains("Reveal in Finder")
              && onFolder.contains("Copy Path") && onFolder.contains { $0.hasSuffix("Favourites") }, "\(onFolder)")
        if let file = b.model.items.first(where: { !$0.isNavigable }) {
            let onFile = b.buildContextMenu(for: [file])
            check("file menu has Open With submenu", onFile.items.contains { $0.title == "Open With" && $0.submenu != nil })
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-smoke-\(getpid())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        b.navigate(to: tmp)
        after(0.4) {
            guard let created = b.newFolder() else { check("newFolder returned a URL", false); return }
            check("newFolder created on disk", FileManager.default.fileExists(atPath: created.path))
            check("newFolder used the default name", created.lastPathComponent == "untitled folder")
            let second = b.newFolder()
            check("second newFolder increments", second?.lastPathComponent == "untitled folder 2")
            after(0.4) {
                check("new folder is selected", b.fileList.selectedItems.first?.name == "untitled folder 2")
                newFolderRename(wc, tmp)
            }
        }
    }

    // MARK: 4a. New Folder opens the name for editing (Finder)

    /// Finder starts an inline edit on the folder it just created
    /// (`setPendingNodesToSelect:startEditing:runNewFolderAnimation:renameOp:`,
    /// docs/research/finder-new-folder-rename.md). The editor has to survive
    /// the three listings the creation itself provokes.
    private static func newFolderRename(_ wc: MainWindowController, _ tmp: URL) {
        print("== new folder rename ==")
        let b = wc.browser, fm = FileManager.default
        // Its own directory: the caller's fixture, two "untitled folder"s
        // included, is what `fileOperations` asserts against afterwards.
        let cases = tmp.appendingPathComponent("new-folder-cases")
        try? fm.createDirectory(at: cases, withIntermediateDirectories: true)
        // `editColumn` opens no editor without a key window.
        NSApp.activate(ignoringOtherApps: true)
        wc.window?.makeKeyAndOrderFront(nil)

        /// The caller's own New Folder calls armed an edit of their own.
        func clearEditingState() {
            b.cancelPendingRename()
            b.fileView.endRename(commit: false)
        }

        func editorField() -> NSTextField? {
            wc.window?.fieldEditor(false, for: nil)?.delegate as? NSTextField
        }
        func editorText() -> String? { (wc.window?.firstResponder as? NSTextView)?.string }

        func run(_ modes: ArraySlice<ViewMode>) {
            guard let mode = modes.first else { groupingCase([.details, .icons][...]); return }
            b.setViewMode(mode)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            let name = "untitled folder"
            clearEditingState()
            try? fm.removeItem(at: cases.appendingPathComponent(name))
            awaitQuietListing(b.model) {
                clearEditingState()
                guard let created = b.newFolder() else {
                    check("\(mode.rawValue): newFolder returned a URL", false); return
                }
                check("\(mode.rawValue): New Folder arms a pending edit", b.hasPendingRename)
                awaitCondition("\(mode.rawValue): New Folder opens the name for editing",
                               condition: { b.fileView.isRenaming }) {
                    check("\(mode.rawValue): the editor holds the new folder's name",
                          editorText() == name, editorText() ?? "no editor")
                    // "untitled folder" has no extension, so the whole name is
                    // preselected — 15 characters, ready to type over.
                    let selection = (wc.window?.firstResponder as? NSTextView)?.selectedRange()
                    check("\(mode.rawValue): the whole default name is preselected",
                          selection == NSRange(location: 0, length: 15),
                          "\(selection ?? NSRange(location: -1, length: -1))")
                    if mode == .details {
                        check("the editing field belongs to the file view, not a stray text view",
                              editorField() != nil)
                    }
                    // Escape keeps the default name and the folder itself.
                    b.fileView.endRename(commit: false)
                    check("\(mode.rawValue): abandoning the edit keeps the default name",
                          fm.fileExists(atPath: created.path) && !b.fileView.isRenaming)
                    renameCommit(mode, created) { run(modes.dropFirst()) }
                }
            }
        }

        /// Type over the default name and end the edit the way clicking away does.
        func renameCommit(_ mode: ViewMode, _ created: URL, _ next: @escaping () -> Void) {
            let typed = "renamed-\(mode.rawValue)"
            b.fileView.beginRename(item: b.model.items.first { $0.url.standardizedFileURL == created.standardizedFileURL } ?? b.model.items[0])
            guard b.fileView.isRenaming, let editor = wc.window?.firstResponder as? NSTextView else {
                check("\(mode.rawValue): the new folder can be renamed again", false); return
            }
            editor.string = typed
            if let field = editor.delegate as? NSTextField { field.stringValue = typed }
            b.fileView.endRename(commit: true)
            awaitCondition("\(mode.rawValue): the typed name is committed to disk",
                           condition: { fm.fileExists(atPath: cases.appendingPathComponent(typed).path) }) {
                check("\(mode.rawValue): the default name is gone", !fm.fileExists(atPath: created.path))
                try? fm.removeItem(at: cases.appendingPathComponent(typed))
                next()
            }
        }

        /// `reloadData()` re-expands group rows, so a row index taken before
        /// that pass points at the wrong item. The editor must still land on
        /// the new folder itself.
        func groupingCase(_ modes: ArraySlice<ViewMode>) {
            guard let mode = modes.first else { splitPaneCase(); return }
            b.setViewMode(mode)
            b.setGroupKey(.kind)
            clearEditingState()
            try? fm.removeItem(at: cases.appendingPathComponent("untitled folder"))
            awaitQuietListing(b.model) {
                clearEditingState()
                guard let created = b.newFolder() else {
                    check("\(mode.rawValue): grouped newFolder returned a URL", false); return
                }
                awaitCondition("\(mode.rawValue): grouping still opens the editor",
                               condition: { b.fileView.isRenaming }) {
                    check("\(mode.rawValue): the grouped editor holds the new folder's name",
                          editorText() == "untitled folder", editorText() ?? "no editor")
                    check("\(mode.rawValue): the grouped pane selects the new folder",
                          b.fileView.selectedItems.map { $0.url.standardizedFileURL } == [created.standardizedFileURL],
                          "\(b.fileView.selectedItems.map(\.name))")
                    b.fileView.endRename(commit: false)
                    b.setGroupKey(.none)
                    try? fm.removeItem(at: created)
                    groupingCase(modes.dropFirst())
                }
            }
        }

        /// Two panes on the same folder: only the pane that asked for the
        /// folder edits it, and the other pane's selection is left alone.
        func splitPaneCase() {
            let tabs = wc.tabs
            clearEditingState()
            try? fm.removeItem(at: cases.appendingPathComponent("untitled folder"))
            // The earlier cases left this pane selecting a folder of the same
            // name; `refreshPreservingSelection` restores a selection by URL,
            // so it would re-select the new folder for reasons of its own.
            b.fileView.select(urls: [])
            tabs.toggleSplit()
            let right = tabs.current
            guard right !== b else { check("split: the second pane is a different pane", false); return }
            right.setViewMode(.details)
            awaitCondition("split: both panes list the fixture directory",
                           condition: { right.currentURL?.standardizedFileURL == cases.standardizedFileURL
                                        && b.currentURL?.standardizedFileURL == cases.standardizedFileURL
                                        && b.fileView.selectedItems.isEmpty }) {
                guard let created = right.newFolder() else {
                    check("split: newFolder returned a URL", false); tabs.toggleSplit(); return
                }
                awaitCondition("split: the pane that asked for the folder opens the editor",
                               condition: { right.fileView.isRenaming }) {
                    check("split: the other pane does not open an editor", !b.fileView.isRenaming)
                    check("split: the other pane did not select the new folder",
                          !b.fileView.selectedItems.contains { $0.url.standardizedFileURL == created.standardizedFileURL },
                          "\(b.fileView.selectedItems.map(\.name))")
                    right.fileView.endRename(commit: false)
                    try? fm.removeItem(at: created)
                    tabs.toggleSplit()
                    after(0.3) { filterCase() }
                }
            }
        }

        /// The folder the user just asked for must be visible, so an active
        /// filter it does not match is cleared rather than hiding it.
        func filterCase() {
            b.setViewMode(.details)
            clearEditingState()
            b.nameFilter = "zzz-no-match"
            check("the pane is filtering before New Folder", b.isFiltering)
            guard let created = b.newFolder() else { check("filtered newFolder returned a URL", false); return }
            check("New Folder clears a filter that would hide it", !b.isFiltering)
            awaitCondition("a filtered pane still opens the editor",
                           condition: { b.fileView.isRenaming }) {
                b.fileView.endRename(commit: false)
                try? fm.removeItem(at: created)
                reloadAbortsRename()
            }
        }

        /// The regression the feature depends on: a listing arriving under an
        /// open editor must never let a half-typed name commit — and must not
        /// throw the user's typing away either.
        func reloadAbortsRename() {
            b.setViewMode(.details)
            clearEditingState()
            guard let created = b.newFolder() else { check("reload-case newFolder returned a URL", false); return }
            awaitCondition("reload case: the editor opens", condition: { b.fileView.isRenaming }) {
                let half = "half-typed"
                if let editor = wc.window?.firstResponder as? NSTextView {
                    editor.string = half
                    if let field = editor.delegate as? NSTextField { field.stringValue = half }
                }
                b.fileView.reloadData()
                check("a listing refresh commits no half-typed name",
                      !fm.fileExists(atPath: cases.appendingPathComponent(half).path)
                      && fm.fileExists(atPath: created.path))
                // The edit is re-opened on the next run-loop pass, once the
                // pane has restored its own selection.
                awaitCondition("a listing refresh re-opens the rename it interrupted",
                               condition: { b.fileView.isRenaming }) {
                    check("the re-opened editor still holds what was typed",
                          (wc.window?.firstResponder as? NSTextView)?.string == half,
                          (wc.window?.firstResponder as? NSTextView)?.string ?? "no editor")
                    check("the folder on disk is still untouched",
                          fm.fileExists(atPath: created.path)
                          && !fm.fileExists(atPath: cases.appendingPathComponent(half).path))
                    clearEditingState()
                    b.navigate(to: tmp)
                    awaitCondition("the pane returns to the fixture directory",
                                   condition: { b.currentURL?.standardizedFileURL == tmp.standardizedFileURL }) {
                        try? fm.removeItem(at: cases)
                        b.reload()
                        after(0.4) { fileOperations(wc, tmp) }
                    }
                }
            }
        }

        b.navigate(to: cases)
        awaitCondition("the pane opens the New Folder fixture directory",
                       condition: { b.currentURL?.standardizedFileURL == cases.standardizedFileURL }) {
            run(ViewMode.allCases[...])
        }
    }

    // MARK: 4b. Expand-in-place and delayed rename

    private static func expansion(_ wc: MainWindowController, _ tmp: URL) {
        print("== expand in place ==")
        let b = wc.browser, fm = FileManager.default, list = b.fileList
        let inner = tmp.appendingPathComponent("sub").appendingPathComponent("deeper")
        try? fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try? "z".write(to: tmp.appendingPathComponent("sub").appendingPathComponent("zeta.txt"), atomically: true, encoding: .utf8)
        try? "h".write(to: tmp.appendingPathComponent("sub").appendingPathComponent(".hiddenfile"), atomically: true, encoding: .utf8)
        b.reload()
        after(0.4) {
            let before = list.tableView.numberOfRows
            guard let sub = b.model.nodes.first(where: { $0.item.name == "sub" }) else { check("find sub", false); return }
            check("folder is expandable", list.tableView.isExpandable(sub))
            list.expand(sub)
            check("expand adds rows", list.tableView.numberOfRows == before + 2, "\(before) → \(list.tableView.numberOfRows)")
            check("children folders-first", sub.children.map(\.item.name) == ["deeper", "zeta.txt"], "\(sub.children.map(\.item.name))")
            check("hidden child filtered", !sub.children.contains { $0.item.name == ".hiddenfile" })
            let subRow = list.tableView.row(forItem: sub)
            check("nested row resolves to child", list.item(atRow: subRow + 1)?.name == "deeper")
            check("nested row is indented", list.tableView.level(forRow: subRow + 1) == 1)
            b.showsHiddenFiles = true
            check("hidden toggle reaches expanded children", sub.children.contains { $0.item.name == ".hiddenfile" } && list.isExpanded(sub))
            b.showsHiddenFiles = false
            // reload keeps expansion and picks up changes inside the expanded folder
            try? "n".write(to: tmp.appendingPathComponent("sub").appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            b.reload()
            after(0.4) {
                guard let sub2 = b.model.nodes.first(where: { $0.item.name == "sub" }) else { check("find sub after reload", false); return }
                check("reload reuses the node object", sub2 === sub)
                check("reload keeps folder expanded", list.isExpanded(sub2))
                check("reload refreshes expanded children", sub2.children.contains { $0.item.name == "new.txt" })
                // rename inside an expanded folder, via the controller
                guard let child = sub2.children.first(where: { $0.item.name == "zeta.txt" }) else { check("find child", false); return }
                b.rename(child.item, to: "omega.txt")
                after(0.4) {
                    let subNow = b.model.nodes.first { $0.item.name == "sub" }
                    print("   [diag] sub expanded=\(subNow.map { list.isExpanded($0) } ?? false) children=\(subNow?.children.map(\.item.name) ?? []) rows=\(list.tableView.numberOfRows) selected=\(b.fileList.selectedItems.map(\.name)) visible=\((0..<list.tableView.numberOfRows).compactMap { list.item(atRow: $0)?.name })")
                    check("nested rename happened on disk", fm.fileExists(atPath: inner.deletingLastPathComponent().appendingPathComponent("omega.txt").path))
                    check("nested rename reselects the renamed child", b.fileList.selectedItems.first?.name == "omega.txt", "\(b.fileList.selectedItems.map(\.name))")
                    list.collapse(sub2)
                    check("collapse removes rows", list.tableView.numberOfRows == before)
                    // delayed click-to-rename: scheduled, then fires; cancelled by selection change.
                    // editColumn needs a key window — another app may have come forward meanwhile.
                    awaitQuietListing(b.model) {
                    NSApp.activate(ignoringOtherApps: true)
                    wc.window?.makeKeyAndOrderFront(nil)
                    list.select(name: "note.txt")
                    let row = list.tableView.selectedRow
                    list.tableView.scheduleRename(row: row, after: 0.2)
                    check("rename is pending, not immediate", list.tableView.hasPendingRename && !(wc.window?.firstResponder is NSTextView))
                    after(0.4) {
                        check("rename fires after the delay", wc.window?.firstResponder is NSTextView)
                        let cell = list.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
                        let sel = cell?.textField?.currentEditor()?.selectedRange
                        check("base name preselected (not the extension)", sel == NSRange(location: 0, length: 4), "\(String(describing: sel))")
                        wc.window?.makeFirstResponder(list.tableView)      // ends editing without change
                        check("field editable only while editing", cell?.textField?.isEditable == false)
                        list.tableView.scheduleRename(row: row, after: 0.2)
                        list.select(name: "sub")
                        check("selection change cancels pending rename", !list.tableView.hasPendingRename)
                        after(0.3) {
                            check("cancelled rename never fired", !(wc.window?.firstResponder is NSTextView))
                            splitView(wc, tmp)
                        }
                    }
                    }
                }
            }
        }
    }

    // MARK: 4c. Split view (Dolphin: tabs on top, one or two panes per tab)

    private static func splitView(_ wc: MainWindowController, _ tmp: URL) {
        print("== split view ==")
        let t = wc.tabs, fm = FileManager.default
        let sub = tmp.appendingPathComponent("sub")
        check("starts unsplit, no indicator", !t.isSplit && t.currentPage.panes.count == 1)
        let left = t.current
        t.toggleSplit()
        check("toggle opens a second pane", t.isSplit && t.currentPage.panes.count == 2)
        let rightForViewCheck = t.current
        rightForViewCheck.viewAsIcons(nil)
        check("toolbar follows the active split pane's view", wc.selectedToolbarViewModeForTesting == .icons)
        left.viewAsIcons(nil)
        left.viewAsList(nil)
        check("inactive pane cannot change the toolbar view", wc.selectedToolbarViewModeForTesting == .icons)
        t.focusOtherPane()
        check("toolbar follows switching to the list pane", wc.selectedToolbarViewModeForTesting == .details)
        t.focusOtherPane()
        check("toolbar follows switching back to the icon pane", wc.selectedToolbarViewModeForTesting == .icons)
        rightForViewCheck.viewAsList(nil)
        check("new (right) pane is active", t.current !== left && t.currentPage.activeSide == .right)
        check("menu title names the active side", { let mi = NSMenuItem(title: "", action: #selector(MainWindowController.toggleSplit(_:)), keyEquivalent: ""); _ = wc.validateMenuItem(mi); return mi.title == "Close Right Pane" }())
        after(0.5) {
            check("second pane opened at the same folder", t.current.currentURL?.standardizedFileURL == left.currentURL?.standardizedFileURL)
            check("both panes laid out side by side", left.view.frame.width > 50 && t.current.view.frame.width > 50 && t.current.view.frame.minX >= left.view.frame.maxX - 1, "\(left.view.frame) | \(t.current.view.frame)")
            // activation: clicking/focusing the left pane makes it active; the address bar follows
            t.currentPage.activate(left)
            check("activate(left)", t.current === left && t.currentPage.activeSide == .left)
            t.focusOtherPane()
            check("focusOtherPane flips back", t.current !== left)
            check("keyboard focus moved with it", wc.window?.firstResponder === t.current.fileList.tableView)
            // open in other pane: right is active, so the LEFT pane should navigate and become active
            t.openInOtherPane(sub)
            after(0.5) {
                check("openInOtherPane navigates the other pane", left.currentURL?.lastPathComponent == "sub", "\(left.currentURL?.lastPathComponent ?? "nil")")
                check("…and activates it", t.current === left)
                check("address bar follows the active pane", t.addressBar.segmentTitles.last == "sub", "\(t.addressBar.segmentTitles)")
                check("split tab title shows both paths without focus punctuation", t.tabBar.titles[t.currentIndex] == "sub | \(wc.provider.displayName(for: tmp))", "\(t.tabBar.titles)")
                check("window title follows the active pane", wc.window?.title == "sub")
                // copy to other pane: active = left (sub), other = right (tmp); copy sub/note copy.txt? use tmp/note.txt from right→ do it from right
                t.focusOtherPane()                       // right (tmp) active
                t.current.fileList.select(name: "note.txt")
                wc.transferToOtherPane([tmp.appendingPathComponent("note.txt")], move: false)
                after(0.8) {
                    check("copy to other pane landed in its folder", fm.fileExists(atPath: sub.appendingPathComponent("note.txt").path))
                    check("copy menu item enabled only when split with a selection", t.current.validateMenuItem(NSMenuItem(title: "", action: #selector(BrowserViewController.copyToOtherPane(_:)), keyEquivalent: "")))
                    // close the active pane (Dolphin semantics): right closes, left remains
                    t.toggleSplit()
                    check("toggle closes the active pane", !t.isSplit && t.current === left)
                    check("remaining pane fills the tab", left.view.frame.width > 200, "\(left.view.frame.width)")
                    tabDragSplit(wc, tmp)
                }
            }
        }
    }

    private static func tabDragSplit(_ wc: MainWindowController, _ tmp: URL) {
        let t = wc.tabs
        let sub = tmp.appendingPathComponent("sub")
        let first = t.current
        t.newTab(at: sub)                     // tab 1, active
        after(0.4) {
            let dragged = t.current
            t.selectTab(at: 0)
            // side detection in window coordinates
            let c = t.view.window!
            let bounds = t.currentPage.view.bounds
            let leftPt = t.currentPage.view.convert(NSPoint(x: bounds.width * 0.1, y: bounds.midY), to: nil)
            let midPt = t.currentPage.view.convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let rightPt = t.currentPage.view.convert(NSPoint(x: bounds.width * 0.9, y: bounds.midY), to: nil)
            _ = c
            check("left third → .left", t.splitSide(at: leftPt) == .left)
            check("middle band → no split", t.splitSide(at: midPt) == nil)
            check("right third → .right", t.splitSide(at: rightPt) == .right)
            check("cannot split with the current tab itself", !t.canSplit(withTab: 0) && t.canSplit(withTab: 1))
            check("drag tab 1 into the left half splits tab 0", t.splitCurrentPage(withTab: 1, side: .left) && t.count == 1 && t.isSplit)
            check("adopted pane is on the left and active", t.currentPage.activeSide == .left && t.current === dragged && t.current.currentURL?.lastPathComponent == "sub")
            check("original pane is on the right", t.currentPage.panes[1] === first)
            check("single split tab keeps both directory names visible", !t.tabBar.isHidden)
            // a closed split tab comes back split
            t.newTab(at: tmp)                 // tab 1 (unsplit) becomes current
            t.selectTab(at: 0)
            check("closing the split tab", t.closeCurrentTab() && t.count == 1)
            check("reopened tab is still split, same panes", t.reopenClosedTab() && t.isSplit && t.currentPage.panes[0] === dragged && t.currentPage.panes[1] === first)
            t.toggleSplit()                   // close active (left = dragged)
            check("back to a single pane", !t.isSplit && t.current === first)
            _ = t.closeTab(at: 0)             // the spare tmp tab, not the one we are in
            check("one tab, one pane, original browser current", t.count == 1 && !t.isSplit && t.current === first)
            after(0.3) { viewModes(wc, tmp) }
        }
    }

    // MARK: 4d. View modes, zoom, previews

    private static func viewModes(_ wc: MainWindowController, _ tmp: URL) {
        print("== view modes ==")
        let b = wc.browser
        // Start from known view state: an earlier failed run must not leak zoom steps in.
        b.setViewMode(.details)
        b.zoomActualSize(nil)
        b.navigate(to: tmp)
        after(0.4) {
            check("starts in details", b.viewMode == .details && b.fileView === b.fileList)
            check("details at default zoom", b.iconSize == 16 && b.fileList.tableView.rowHeight == 24, "\(b.iconSize) / \(b.fileList.tableView.rowHeight)")
            b.fileView.select(name: "note.txt")
            b.setViewMode(.icons)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            check("switched to icons", b.viewMode == .icons && b.fileView === b.iconGrid)
            check("toolbar follows the Icons action", wc.selectedToolbarViewModeForTesting == .icons)
            check("grid shows every top-level item", b.iconGrid.collectionView.numberOfItems(inSection: 0) == b.model.items.count, "\(b.iconGrid.collectionView.numberOfItems(inSection: 0)) vs \(b.model.items.count)")
            check("selection carried over", b.fileView.selectedItems.map(\.name) == ["note.txt"], "\(b.fileView.selectedItems.map(\.name))")
            check("grid has size", b.iconGrid.view.frame.width > 200 && b.iconGrid.view.frame.height > 100, "\(b.iconGrid.view.frame.size)")
            check("keyboard focus went to the grid", wc.window?.firstResponder === b.iconGrid.collectionView)
            let size0 = b.iconSize
            b.zoom(by: 1)
            check("zoom in enlarges icons", b.iconSize > size0, "\(size0) → \(b.iconSize)")
            check("slider follows zoom", Int(b.statusBar.zoomSlider.doubleValue.rounded()) == b.zoomIndex)
            b.iconGrid.onZoomGesture?(-1)
            check("⌘-scroll / pinch gesture zooms out", b.iconSize == size0)
            b.zoomActualSize(nil)
            check("actual size resets", b.zoomIndex == ZoomLevel.defaultIndex(for: .icons))
            b.setZoomIndex(99)
            check("zoom clamps at the largest step", b.zoomIndex == ZoomLevel.iconSizes.count - 1 && b.iconSize == 512)
            b.zoomActualSize(nil)
            check("item frame on screen is real", b.fileView.frameOnScreen(for: tmp.appendingPathComponent("note.txt")).width > 0)
            check("Quick Look counts the grid selection", b.numberOfPreviewItems(in: QLPreviewPanel.shared()) == 1)
            check("no clicked item → background context menu", b.fileView.clickedItems.isEmpty)
            guard let note = b.model.items.first(where: { $0.name == "note.txt" }),
                  let folder = b.model.items.first(where: { $0.isNavigable }) else { check("find items", false); return }
            var got: NSImage? = nil, done = false
            let cached = ThumbnailProvider.shared.thumbnail(for: note, size: 128, scale: 2) { img in got = img; done = true }
            awaitCondition("thumbnail completion", timeout: 15, recordsSuccess: false,
                           condition: { cached != nil || done }) {
                check("thumbnail generated for a text file", cached != nil || (done && got != nil), "cached=\(cached != nil) done=\(done) got=\(got != nil)")
                check("thumbnail cached on the second ask", ThumbnailProvider.shared.thumbnail(for: note, size: 128, scale: 2) { _ in } != nil)
                check("folders never get thumbnails", !ThumbnailProvider.canPreview(folder))
                b.setViewMode(.details)
                check("toolbar follows the List action", wc.selectedToolbarViewModeForTesting == .details)
                check("back to details keeps selection", b.viewMode == .details && b.fileView.selectedItems.map(\.name) == ["note.txt"], "\(b.fileView.selectedItems.map(\.name))")
                check("focus went back to the list", wc.window?.firstResponder === b.fileList.tableView)
                b.zoom(by: 2)
                check("details zoom: 32pt icons, taller rows", b.iconSize == 32 && b.fileList.tableView.rowHeight == 40, "\(b.iconSize) / \(b.fileList.tableView.rowHeight)")
                check("zoom remembered per mode", b.currentViewProperties.detailsZoomIndex == 2 && b.currentViewProperties.iconsZoomIndex == ZoomLevel.defaultIndex(for: .icons))
                b.zoomActualSize(nil)
                check("details back to 16pt", b.iconSize == 16 && b.fileList.tableView.rowHeight == 24)
                b.togglePreviews(nil)
                check("previews toggle off", !b.showsPreviews && !b.currentViewProperties.showPreviews)
                b.togglePreviews(nil)
                liveRefresh(wc, tmp)
            }
        }
    }

    // MARK: 4e. Directory watching and cross-pane refresh

    private static func liveRefresh(_ wc: MainWindowController, _ tmp: URL) {
        print("== live refresh ==")
        let b = wc.browser, t = wc.tabs
        let sub = tmp.appendingPathComponent("sub")
        // a drag session must never end in a rename
        let list = b.fileList.tableView
        list.noteDragSessionBegan()
        check("no rename after a drag session", !list.renameAllowedAfterMouseUp(candidate: true, pointerTravelled: 0))
        check("drag flag is consumed", list.renameAllowedAfterMouseUp(candidate: true, pointerTravelled: 0))
        check("no rename when the pointer travelled", !list.renameAllowedAfterMouseUp(candidate: true, pointerTravelled: 12))
        check("no rename without a candidate", !list.renameAllowedAfterMouseUp(candidate: false, pointerTravelled: 0))
        b.fileView.select(name: "note.txt")
        list.scheduleRename(row: list.selectedRow, after: 0.3)
        list.noteDragSessionBegan()
        check("a drag session cancels an already scheduled rename", !list.hasPendingRename)
        list.scheduleRename(row: list.selectedRow, after: 0.2)
        list.noteDragSessionEnded()
        check("a drag session ending cancels it too", !list.hasPendingRename)
        _ = list.renameAllowedAfterMouseUp(candidate: false, pointerTravelled: 0)   // clears the flag

        b.fileView.select(name: "note.txt")
        // 1. something outside the app creates a file in the shown folder
        try? "x".write(to: tmp.appendingPathComponent("external.txt"), atomically: true, encoding: .utf8)
        awaitCondition("external file appears", timeout: 15, recordsSuccess: false,
                       condition: { b.model.items.contains { $0.name == "external.txt" } }) {
            check("external change shows up via FSEvents", b.model.items.contains { $0.name == "external.txt" }, "\(b.model.items.map(\.name))")
            check("refresh kept the selection", b.fileView.selectedItems.map(\.name) == ["note.txt"], "\(b.fileView.selectedItems.map(\.name))")
            // 2. an expanded subfolder is watched too
            guard let subNode = b.model.nodes.first(where: { $0.item.name == "sub" }) else { check("find sub", false); return }
            b.fileList.expand(subNode)
            check("expanded folder is a displayed directory", b.displayedDirectories.contains { $0.standardizedFileURL == sub.standardizedFileURL })
            try? "y".write(to: sub.appendingPathComponent("inner-external.txt"), atomically: true, encoding: .utf8)
            awaitCondition("external child appears", timeout: 15, recordsSuccess: false,
                           condition: { subNode.children.contains { $0.item.name == "inner-external.txt" } }) {
                check("change inside an expanded folder shows up", subNode.children.contains { $0.item.name == "inner-external.txt" }, "\(subNode.children.map(\.item.name))")
                b.fileList.collapse(subNode)
                // 3. a move performed by the OTHER pane refreshes this one at once
                try? "m".write(to: tmp.appendingPathComponent("moveme.txt"), atomically: true, encoding: .utf8)
                b.reload()
                after(0.4) {
                    check("moveme.txt listed in source pane", b.model.items.contains { $0.name == "moveme.txt" })
                    let right = t.currentPage.split(with: sub)          // right pane at sub, active
                    after(0.5) {
                        right.dropFiles([tmp.appendingPathComponent("moveme.txt")], to: sub, op: .move)   // drop on the right pane
                        after(0.9) {
                            check("moved into the destination pane", right.model.items.contains { $0.name == "moveme.txt" })
                            check("source pane refreshed without being asked", !b.model.items.contains { $0.name == "moveme.txt" }, "\(b.model.items.map(\.name))")
                            t.currentPage.activate(right)
                            t.toggleSplit()                             // close the right pane
                            check("back to one pane", !t.isSplit && t.current === b)
                            crossTabDrag(wc, tmp)
                        }
                    }
                }
            }
        }
    }

    // MARK: 4f. Files dragged onto tabs

    private static func crossTabDrag(_ wc: MainWindowController, _ tmp: URL) {
        print("== cross-tab drag ==")
        let t = wc.tabs, fm = FileManager.default, bar = t.tabBar
        let sub = tmp.appendingPathComponent("sub")
        try? "c".write(to: tmp.appendingPathComponent("crosstab.txt"), atomically: true, encoding: .utf8)
        t.newTab(at: sub, activate: false)                       // tab 1 = sub, tab 0 (tmp) stays current
        check("two tabs, first current", t.count == 2 && t.currentIndex == 0)
        after(0.5) {                                              // the new tab's first listing is async
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let frames = (0..<2).map { bar.tabFrameForTesting($0) }
        check("tab frames laid out", frames.allSatisfy { $0.width > 0 })
        check("hit-testing finds tab 1", bar.tabIndex(at: NSPoint(x: frames[1].midX, y: frames[1].midY)) == 1)
        check("empty strip space is no tab", bar.tabIndex(at: NSPoint(x: bar.bounds.width - 2, y: 3)) == nil)
        let file = tmp.appendingPathComponent("crosstab.txt")
        check("hover badge: same-volume move onto tab 1", bar.dropOperationForTab?(1, [file], [.copy, .move]) == .move)
        check("hover badge: ⌥ copies", bar.dropOperationForTab?(1, [file], .copy) == .copy)
        check("hover badge: file onto empty space refused", bar.dropOperationForTab?(nil, [file], [.copy, .move]) == [])
        check("hover badge: folder onto empty space opens a tab", bar.dropOperationForTab?(nil, [sub], [.copy, .move]) == .generic)
        // drop the file on tab 1 → moved into sub; tab 0 (source, current) refreshes
        check("drop on tab 1 accepted", bar.performDrop(urls: [file], sourceMask: [.copy, .move], onTabAt: 1))
        after(0.9) {
            check("file moved into tab 1's folder", fm.fileExists(atPath: sub.appendingPathComponent("crosstab.txt").path))
            check("source tab's pane refreshed", !t.current.model.items.contains { $0.name == "crosstab.txt" }, "\(t.current.model.items.map(\.name))")
            check("drop did not switch tabs", t.currentIndex == 0)
            // hovering a tab activates it after Dolphin's 800 ms
            bar.beginAutoActivation(1)
            check("auto-activation pending", bar.hasPendingAutoActivation)
            bar.hoverTabIndexForTesting = 1
            after(TabBarView.autoActivationDelay + 0.3) {
                check("hovered tab became current", t.currentIndex == 1)
                // a folder dropped on empty strip space opens as a new background tab
                let before = t.count
                check("folder drop on empty space accepted", bar.performDrop(urls: [tmp.appendingPathComponent("renamed")], sourceMask: [.copy, .move], onTabAt: nil))
                check("…opened a new tab, not activated", t.count == before + 1 && t.currentIndex == 1)
                _ = t.closeTab(at: t.count - 1)
                t.selectTab(at: 0)
                _ = t.closeTab(at: 1)
                check("back to one tab", t.count == 1)
                filterAndConflicts(wc, tmp)
            }
        }
        }
    }

    // MARK: 4g. Filter bar and batch conflict policy

    private static func filterAndConflicts(_ wc: MainWindowController, _ tmp: URL) {
        print("== current-directory toolbar filter ==")
        let b = wc.browser, t = wc.tabs
        b.navigate(to: tmp)
        after(0.4) {
            let total = b.model.items.count
            check("toolbar has a search field", wc.searchField != nil)
            let originalAddressFrame = t.addressBar.frame
            check("filter field explains its scope", wc.searchField?.toolTip?.contains("this folder") == true)
            wc.focusFilter(nil)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            check("⌘F focuses the toolbar field", wc.window?.firstResponder is NSTextView && wc.searchField?.currentEditor() != nil)
            check("focusing filter preserves address layout", t.addressBar.frame == originalAddressFrame)
            // focus must be able to leave an empty field, and an expanded-from-icon field must fold back
            wc.window?.makeFirstResponder(b.focusView)
            check("focus can leave the empty field", wc.window?.firstResponder === b.focusView, "\(String(describing: wc.window?.firstResponder.map { type(of: $0) }))")
            after(0.2) {
            check("search interaction ended on empty blur", !wc.searchInteractionActiveForTesting)
            wc.focusFilter(nil)
            check("⌘F focuses again", wc.window?.firstResponder is NSTextView)
            wc.applyFilter("note")
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            check("filtering does not insert a redundant scope row", t.addressBar.frame == originalAddressFrame)
            check("substring filter, case-insensitive", b.model.items.map(\.name).sorted() == ["note copy 2.txt", "note copy.txt", "note.txt"], "\(b.model.items.map(\.name))")
            check("filter summary", b.filterSummary == "3 of \(total) items", b.filterSummary)
            check("View ▸ Filter shows the on state", { let mi = NSMenuItem(title: "", action: #selector(MainWindowController.focusFilter(_:)), keyEquivalent: ""); _ = wc.validateMenuItem(mi); return mi.state == .on }())
            wc.applyFilter("NOTE COPY")
            check("filter ignores case", b.model.items.count == 2)
            wc.applyFilter("*.txt")
            check("wildcard pattern", b.model.items.allSatisfy { $0.name.hasSuffix(".txt") } && b.model.items.count >= 3, "\(b.model.items.map(\.name))")
            wc.applyFilter("n?te")
            check("? wildcard", b.model.items.contains { $0.name == "note.txt" })
            // the filter belongs to the pane; the field follows whichever pane is active
            wc.applyFilter("sub")
            let left = b
            t.toggleSplit()                                    // right pane opens at tmp, active
            after(0.5) {
                check("new pane starts unfiltered, field follows it", !t.current.isFiltering && wc.searchField?.stringValue == "", "\(wc.searchField?.stringValue ?? "nil")")
                check("left pane kept its own filter", left.nameFilter == "sub")
                t.currentPage.activate(left)
                check("switching back restores the field text", wc.searchField?.stringValue == "sub",
                      "field='\(wc.searchField?.stringValue ?? "nil")' left.filter='\(left.nameFilter)' current===left:\(t.current === left) fieldFocused=\(wc.isSearchFieldFocusedForTesting) firstResponder=\(String(describing: wc.window?.firstResponder.map { type(of: $0) }))")
                t.currentPage.activate(t.currentPage.inactive!)
                t.toggleSplit()                                // close the right pane
                check("back on the filtered pane", t.current === left && wc.searchField?.stringValue == "sub")
                // navigating clears the filter (Dolphin) and the field
                left.navigate(to: tmp.appendingPathComponent("sub"))
                after(0.4) {
                    check("changing directory clears the filter and the field", !left.isFiltering && wc.searchField?.stringValue == "")
                    left.goBack()
                    after(0.4) {
                        wc.applyFilter("note")
                        wc.cancelFilter()                       // what Esc / the ⓧ button do
                        check("cancel clears everything and returns focus to the list", !left.isFiltering && wc.searchField?.stringValue == "" && wc.window?.firstResponder === left.focusView)
                        check("model unfiltered after cancel", left.model.items.count == total)
                        scrollClamp(wc, tmp)
                    }
                }
            }
            }
        }
    }

    // MARK: 4g2. Scroll offset never leaves blank space above the rows

    private static func scrollClamp(_ wc: MainWindowController, _ tmp: URL) {
        print("== scroll clamp ==")
        let b = wc.browser
        let clip = b.fileList.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -80))                       // what a rubber-band bounce looks like
        b.fileList.scrollView.reflectScrolledClipView(clip)
        check("getter never reports a bounce as negative", b.fileList.scrollOffset == 0)
        b.fileList.scrollOffset = -80
        check("setting a negative offset lands at the top", b.fileList.scrollOffset == 0, "\(clip.bounds.origin.y)")
        b.fileList.scrollOffset = 100_000
        var bottom = clip.bounds
        bottom.origin.y = 100_000
        let maxY = clip.constrainBoundsRect(bottom).origin.y
        check("setting a huge offset clamps to the end", clip.bounds.origin.y == maxY, "\(clip.bounds.origin.y) vs \(maxY)")
        b.fileList.scrollOffset = 0
        // The same top-relative position survives a real navigation round trip.
        b.goUp()
        after(0.4) {
            b.goBack()
            after(0.4) {
                check("restored offset is clamped, first row at the top", b.fileList.scrollOffset == 0 && b.fileList.tableView.rect(ofRow: 0).minY == 0, "\(b.fileList.scrollView.contentView.bounds.origin.y)")
                let grid = b.iconGrid
                grid.scrollOffset = -50
                check("icon grid clamps too", grid.scrollView.contentView.bounds.origin.y >= 0)
                scrollAfterOpeningFolder(wc, tmp) {
                    listInsetRestoration(wc, tmp) { groupingFromFavorites(wc, tmp) { groups(wc, tmp) } }
                }
            }
        }
    }

    /// Opening a folder and pressing Back is the one navigation that always
    /// remembers a selection — the folder you opened. Restoring only the
    /// selection scrolls its row barely into view, which is not where the user
    /// was, so the recorded offset has to be restored as well.
    private static func scrollAfterOpeningFolder(_ wc: MainWindowController, _ tmp: URL,
                                                 completion: @escaping () -> Void) {
        print("== scroll after opening a folder ==")
        // Folders lead under the Name sort, so a lone folder among files would
        // sit at row 0 and selecting it would scroll the list back to the top —
        // recording an offset of 0 and testing nothing. The fixture is all
        // folders, and the one that gets opened sits inside the viewport at the
        // offset we scroll to, which is the situation the user described.
        let fixture = tmp.appendingPathComponent("scroll-back")
        let manager = FileManager.default
        for index in 0..<60 {
            try? manager.createDirectory(at: fixture.appendingPathComponent(String(format: "dir-%02d", index)),
                                         withIntermediateDirectories: true)
        }
        let b = wc.browser
        b.navigate(to: fixture)
        after(0.5) {
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            b.fileList.scrollOffset = 400
            let before = b.fileList.scrollOffset
            check("the fixture is long enough to scroll", before > 0, "\(before)")
            guard let folder = b.model.nodes.first(where: { $0.item.name == "dir-20" })?.item else {
                check("the fixture has a folder to open", false); completion(); return
            }
            b.fileView.select(urls: [folder.url])
            b.navigate(to: folder.url)
            after(0.5) {
                check("opening the folder navigated", b.currentURL?.lastPathComponent == "dir-20",
                      b.currentURL?.lastPathComponent ?? "nil")
                b.goBack()
                after(0.6) {
                    let restored = b.fileList.scrollOffset
                    check("Back restores where the user was, not just the selected row",
                          abs(restored - before) < 4, "left at \(before), came back to \(restored)")
                    check("and the folder that was opened is selected again",
                          b.fileView.selectedItems.first?.name == "dir-20",
                          b.fileView.selectedItems.first?.name ?? "nil")
                    // The recorded offset is taken against whatever listing was
                    // on screen, and a directory change clears the filter. A
                    // folder left filtered records ~0, which must not then be
                    // replayed over a selection far down the unfiltered list.
                    b.nameFilter = "dir-45"
                    after(0.4) {
                        guard let target = b.model.nodes.first(where: { $0.item.name == "dir-45" })?.item else {
                            check("the filtered fixture still has its target", false); completion(); return
                        }
                        b.fileView.select(urls: [target.url])
                        b.navigate(to: target.url)
                        after(0.5) {
                            b.goBack()
                            after(0.6) {
                                let rect = b.fileList.tableView.rect(ofRow: b.fileList.tableView.selectedRow)
                                let visible = b.fileList.scrollView.contentView.bounds
                                check("Back from a filtered folder still shows the row it selected",
                                      b.fileList.tableView.selectedRow >= 0 && visible.intersects(rect),
                                      "row=\(b.fileList.tableView.selectedRow) rect=\(rect) visible=\(visible)")
                                b.nameFilter = ""
                                after(0.3) { completion() }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A real outline document with a controlled native inset reproduces the
    /// macOS header coordinate system even on older CI hosts.
    private static func listInsetRestoration(_ wc: MainWindowController, _ tmp: URL,
                                             completion: @escaping () -> Void) {
        let fixture = tmp.appendingPathComponent("list-scroll-insets")
        try! FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        for index in 0..<40 {
            try! Data().write(to: fixture.appendingPathComponent(String(format: "row-%02d.txt", index)))
        }
        let model = DirectoryModel(provider: wc.provider)
        let list = FileListViewController(model: model)
        list.loadViewIfNeeded()
        list.view.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        model.load(fixture) {
            list.reloadData()
            list.view.layoutSubtreeIfNeeded()
            let clip = list.scrollView.contentView
            clip.automaticallyAdjustsContentInsets = false
            clip.contentInsets = NSEdgeInsets(top: 34, left: 0, bottom: 0, right: 0)
            list.scrollOffset = 0
            check("list native header inset is the logical top", abs(clip.bounds.minY + 34) < 0.5 && list.scrollOffset == 0, "\(clip.bounds)")
            list.scrollOffset = 120
            let offset = list.scrollOffset
            check("list reports a nonzero top-relative distance", abs(offset - 120) < 0.5, "\(offset)")
            list.reloadData()
            list.scrollOffset = offset
            check("list restores nonzero distance through reload", abs(list.scrollOffset - 120) < 0.5, "\(list.scrollOffset)")
            var horizontal = clip.bounds
            horizontal.origin.x = 70
            clip.scroll(to: clip.constrainBoundsRect(horizontal).origin)
            let savedX = clip.bounds.minX
            list.scrollOffset = 0
            check("list vertical restoration preserves horizontal scroll", savedX > 0 && abs(clip.bounds.minX - savedX) < 0.5, "\(savedX) -> \(clip.bounds.minX)")
            list.scrollOffset = 100_000
            let oldBottom = list.scrollOffset
            model.nameFilter = "row-00"
            list.reloadData()
            list.scrollOffset = oldBottom
            check("shortened list clamps to its inset-aware top", list.scrollOffset == 0 && abs(clip.bounds.minY + 34) < 0.5, "\(clip.bounds)")
            completion()
        }
    }

    /// Compare rendered rows with the actual native header, not a duplicate of
    /// the scroll-offset formula. AX row counts alone missed this regression.
    private static func checkListHeaderGeometry(_ browser: BrowserViewController, _ stage: String) {
        guard browser.viewMode == .details else { return }
        let list = browser.fileList, table = list.tableView
        list.view.layoutSubtreeIfNeeded()
        let clip = list.scrollView.contentView
        let rows = (0..<table.numberOfRows).map { table.rect(ofRow: $0) }
        let header = table.headerView.map { $0.convert($0.bounds, to: table) } ?? .zero
        let validRows = rows.enumerated().allSatisfy { index, rect in
            rect.height > 0 && table.row(at: NSPoint(x: rect.midX, y: rect.midY)) == index
                && (index == 0 || rect.minY >= rows[index - 1].maxY)
        }
        let first = rows.first ?? .zero
        let firstVisible = first.height > 0 && !first.intersects(header)
            && table.visibleRect.intersects(first)
        check("\(stage): first list row stays below header and rows remain hittable", validRows && firstVisible,
              "clip=\(clip.bounds) inset=\(clip.contentInsets) header=\(header) rows=\(rows)")
    }

    // MARK: 4h. Finder's Use Groups / Group By

    private static func groups(_ wc: MainWindowController, _ tmp: URL) {
        print("== groups ==")
        let b = wc.browser, fm = FileManager.default
        let dir = tmp.appendingPathComponent("grouped")
        try? fm.createDirectory(at: dir.appendingPathComponent("Zeta folder"), withIntermediateDirectories: true)
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("photo.png"))
        try? "%PDF-1.4".write(to: dir.appendingPathComponent("paper.pdf"), atomically: true, encoding: .utf8)
        try? "hello".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try? Data(repeating: 0, count: 5000).write(to: dir.appendingPathComponent("archive.zip"))
        try? "1".write(to: dir.appendingPathComponent("42.txt"), atomically: true, encoding: .utf8)
        let cal = Calendar.current, now = Date()
        func stamp(_ name: String, daysAgo: Int) {
            var u = dir.appendingPathComponent(name); var v = URLResourceValues()
            v.contentModificationDate = cal.date(byAdding: .day, value: -daysAgo, to: now); try? u.setResourceValues(v)
        }
        stamp("photo.png", daysAgo: 1); stamp("paper.pdf", daysAgo: 5); stamp("notes.txt", daysAgo: 20); stamp("archive.zip", daysAgo: 400)

        // pure rules
        check("date buckets", Grouping.dateBucket(now).title == "Today" && Grouping.dateBucket(cal.date(byAdding: .day, value: -1, to: now)!).title == "Yesterday"
              && Grouping.dateBucket(cal.date(byAdding: .day, value: -5, to: now)!).title == "Previous 7 Days"
              && Grouping.dateBucket(cal.date(byAdding: .day, value: -20, to: now)!).title == "Previous 30 Days")
        let lastYear = cal.date(byAdding: .year, value: -1, to: now)!
        check("older dates bucket by year", Grouping.dateBucket(lastYear).title == String(cal.component(.year, from: lastYear)))
        check("date groups are newest first", Grouping.dateBucket(now).order < Grouping.dateBucket(lastYear).order)
        check("name buckets: letters, # for digits", Grouping.nameBucket("apple").title == "A" && Grouping.nameBucket("42.txt").title == "#" && Grouping.nameBucket("42.txt").order > Grouping.nameBucket("apple").order)
        check("no groups → one untitled group", Grouping.split([], by: .none).count == 1)

        b.navigate(to: dir)
        after(0.5) {
            check("ungrouped: one group, list has plain rows", !b.model.isGrouped && b.model.groups.count == 1 && b.fileList.item(atRow: 0) != nil)
            b.setGroupKey(.kind)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            let titles = b.model.groups.map(\.title)
            check("kind groups use Finder's category names, sorted by name", titles == ["Folders", "Images", "Other", "PDF Documents", "Text"], "\(titles)")
            check("every item is in exactly one group", b.model.groups.flatMap(\.nodes).count == b.model.nodes.count)
            check("list: group header rows are not items", b.fileList.item(atRow: 0) == nil && b.fileList.tableView.numberOfRows == b.model.nodes.count + b.model.groups.count, "rows \(b.fileList.tableView.numberOfRows)")
            check("list: header row is a group row", b.fileList.tableView.item(atRow: 0) is GroupNode && (b.fileList.tableView.delegate?.outlineView?(b.fileList.tableView, isGroupItem: b.fileList.tableView.item(atRow: 0)!) ?? false))
            check("list: first item under Folders", b.fileList.item(atRow: 1)?.name == "Zeta folder")
            check("future dates go to No Date (Finder's GROUP_FUTURE)", Grouping.dateBucket(cal.date(byAdding: .day, value: 3, to: now)!).title == "No Date")
            b.fileView.select(name: "paper.pdf")
            check("select by name across groups", b.fileView.selectedItems.map(\.name) == ["paper.pdf"])
            check("group rows are not selectable", { let t = b.fileList.tableView; let g = t.item(atRow: 0)!
                return t.delegate?.outlineView?(t, shouldSelectItem: g) == false
                    && t.delegate?.outlineView?(t, selectionIndexesForProposedSelection: IndexSet([0, 1])) == IndexSet([1]) }())
            check("View ▸ Use Groups is on", { let mi = NSMenuItem(title: "", action: #selector(BrowserViewController.toggleGroups(_:)), keyEquivalent: ""); _ = b.validateMenuItem(mi); return mi.state == .on }())
            check("Group By ▸ Kind is checked", { let mi = NSMenuItem(title: "", action: #selector(BrowserViewController.groupBy(_:)), keyEquivalent: ""); mi.representedObject = "kind"; _ = b.validateMenuItem(mi); return mi.state == .on }())
            // expanding a folder inside a group still works
            if let z = b.model.node(for: dir.appendingPathComponent("Zeta folder")) {
                try? "x".write(to: dir.appendingPathComponent("Zeta folder/inner.txt"), atomically: true, encoding: .utf8)
                b.fileList.expand(z)
                check("folder inside a group expands", b.fileList.item(atRow: 2)?.name == "inner.txt", "\(b.fileList.item(atRow: 2)?.name ?? "nil")")
                b.fileList.collapse(z)
            }
            b.setGroupKey(.dateModified)
            let dates = b.model.groups.map(\.title)
            check("date-modified groups in Finder order", dates.first == "Today" && dates.contains("Yesterday") && dates.contains("Previous 7 Days") && dates.contains("Previous 30 Days") && dates.last == String(cal.component(.year, from: cal.date(byAdding: .day, value: -400, to: now)!)), "\(dates)")
            b.setGroupKey(.name)
            check("name groups end with #", b.model.groups.last?.title == "#" && b.model.groups.first?.title == "A", "\(b.model.groups.map(\.title))")
            b.setGroupKey(.size)
            check("size groups: Folders first, then Finder's decade labels, bigger first", b.model.groups.map(\.title) == ["Folders", "From 1 KB to 10 KB", "Under 1 KB"], "\(b.model.groups.map(\.title))")
            b.setGroupKey(.application)
            check("application groups: folders under Finder", b.model.groups.first?.title == "Finder", "\(b.model.groups.map(\.title))")
            check("Tags grouping is excluded by design", GroupKey(rawValue: "tags") == nil && MainMenu.groupByMenuItem().submenu?.items.contains { $0.title == "Tags" } == false)
            // icon view: one section per group with headers
            b.setGroupKey(.kind)
            b.setViewMode(.icons)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            let cv = b.iconGrid.collectionView
            check("grid: one section per group", cv.numberOfSections == b.model.groups.count && cv.numberOfItems(inSection: 0) == 1)
            // Supplementary views are materialized on a later AppKit layout pass.
            awaitCondition("grid: sticky header views", condition: {
                cv.layoutSubtreeIfNeeded()
                return !cv.visibleSupplementaryViews(ofKind: NSCollectionView.elementKindSectionHeader).isEmpty
            }) {
            b.fileView.select(name: "paper.pdf")
            let pdfSection = b.model.groups.firstIndex { $0.title == "PDF Documents" }
            check("grid: select across sections", b.fileView.selectedItems.map(\.name) == ["paper.pdf"] && cv.selectionIndexPaths.first?.section == pdfSection, "section \(cv.selectionIndexPaths.first?.section ?? -1) vs \(pdfSection ?? -1)")
            check("grid: frame on screen across sections", b.fileView.frameOnScreen(for: dir.appendingPathComponent("paper.pdf")).width > 0)
            b.toggleGroups(nil)
            check("Use Groups off → ungrouped, one section", !b.usesGroups && cv.numberOfSections == 1 && cv.numberOfItems(inSection: 0) == b.model.nodes.count)
            b.toggleGroups(nil)
            check("Use Groups on → back to the last key", b.groupKey == .kind)
            b.setGroupKey(.none)
            b.setViewMode(.details)
            check("persisted folder grouping", b.viewPropertiesStore.properties(forKey: b.viewPropertiesKey).groupKey == .none && b.currentViewProperties.lastGroupKey == .kind)
            try? fm.removeItem(at: dir)
            conflicts(wc, tmp)
            }
        }
    }

    private static func groupingFromFavorites(_ wc: MainWindowController, _ tmp: URL,
                                               completion: @escaping () -> Void) {
        print("== grouping with Favorites focus ==")
        let tabs = wc.tabs
        let original = wc.browser
        let originalGroup = original.groupKey
        tabs.newTab(at: tmp)
        let inactive = wc.browser
        awaitInitialListing(inactive.model) {
        inactive.setGroupKey(.name)
        tabs.toggleSplit()
        let active = wc.browser
        let sidebar = wc.sidebar.outlineView
        let homeRow = wc.sidebar.row(for: wc.provider.homeURL)
        check("Favorites home row exists", homeRow >= 0)
        guard let toolbarMenu = wc.window?.toolbar?.items.compactMap({ $0 as? NSMenuToolbarItem }).first?.menu else {
            check("toolbar Group menu exists", false); return
        }

        func exercise(_ mode: ViewMode, then next: @escaping () -> Void) {
            sidebar.deselectAll(nil)
            wc.window?.makeFirstResponder(sidebar)
            sidebar.selectRowIndexes(IndexSet(integer: homeRow), byExtendingSelection: false)
            after(0.6) {
                active.setViewMode(mode)
                check("\(mode): Favorites navigates only the active pane", active.currentURL == wc.provider.homeURL && inactive.currentURL == tmp)
                check("\(mode): Favorites retains keyboard focus", wc.window?.firstResponder === sidebar)
                wc.applyFilter("Doc")
                let kind = toolbarMenu.items.first { ($0.representedObject as? String) == GroupKey.kind.rawValue }!
                check("\(mode): toolbar grouping dispatches from Favorites", sidebar.tryToPerform(kind.action!, with: kind))
                check("\(mode): toolbar groups the filtered active pane", active.groupKey == .kind && active.nameFilter == "Doc")
                check("\(mode): toolbar checkmark follows active grouping", wc.validateMenuItem(kind) && kind.state == .on)
                let menu = MainMenu.groupByMenuItem().submenu!
                let size = menu.items.first { ($0.representedObject as? String) == GroupKey.size.rawValue }!
                check("\(mode): View menu grouping dispatches from Favorites", sidebar.tryToPerform(size.action!, with: size) && active.groupKey == .size)
                let toggle = NSMenuItem(title: "Use Groups", action: #selector(BrowserViewController.toggleGroups(_:)), keyEquivalent: "0")
                check("\(mode): Use Groups validates with Favorites focus", wc.validateMenuItem(toggle) && toggle.state == .on)
                check("\(mode): Use Groups toggles from Favorites", sidebar.tryToPerform(toggle.action!, with: toggle) && active.groupKey == .none)
                check("\(mode): grouping preserves sidebar focus and other panes", wc.window?.firstResponder === sidebar && inactive.groupKey == .name && original.groupKey == originalGroup)
                let more = MainMenu.actionsMenu(target: wc)
                check("\(mode): More excludes Tags and iPhone import", !more.items.contains { $0.title.localizedCaseInsensitiveContains("tag") || $0.title.contains("iPhone") })
                let rename = more.items.first { ($0.representedObject as? String) == MainMenu.FileAction.rename.rawValue }!
                let copy = more.items.first { ($0.representedObject as? String) == MainMenu.FileAction.copy.rawValue }!
                active.fileView.select(names: [])
                check("\(mode): selection commands and sharing disable without files", !wc.validateMenuItem(rename) && wc.sharingItems.isEmpty)
                if let first = active.model.items.first {
                    active.fileView.select(names: [first.name])
                    check("\(mode): More validates the active selection with sidebar focus", wc.validateMenuItem(rename) && copy.target === wc)
                    wc.performFileAction(copy)
                    let copied = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                    check("\(mode): More Copy dispatches to the active pane", copied == [first.url])
                    let share = wc.window!.toolbar!.items.compactMap { $0 as? NSSharingServicePickerToolbarItem }.first!
                    check("\(mode): native Share receives the active pane selection", (wc.items(for: share) as? [URL]) == [first.url] && share.isEnabled, "items=\(wc.sharingItems), expected=\(first.url), enabled=\(share.isEnabled)")
                    active.fileView.select(names: [])
                    check("\(mode): native Share disables after deselection", !share.isEnabled)
                }
                wc.cancelFilter()
                next()
            }
        }
        exercise(.details) {
            exercise(.icons) {
                _ = tabs.closeCurrentTab()
                original.setGroupKey(.none)
                wc.window?.makeFirstResponder(original.focusView)
                completion()
            }
        }
        }
    }

    private static func conflicts(_ wc: MainWindowController, _ tmp: URL) {
        print("== conflicts ==")
        let fm = FileManager.default
        let src = tmp.appendingPathComponent("csrc"), dst = tmp.appendingPathComponent("cdst")
        for d in [src, dst] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for n in ["a.txt", "b.txt", "c.txt"] {
            try? "src".write(to: src.appendingPathComponent(n), atomically: true, encoding: .utf8)
            try? "dst".write(to: dst.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        let files = ["a.txt", "b.txt", "c.txt"].map { src.appendingPathComponent($0) }
        var asked: [FileOperations.Conflict] = []
        // 1. keep both + apply to all: asked once, three "X 2" copies
        FileOperations.transfer(files, to: dst, kind: .copy, conflict: { c in
            asked.append(c); return .init(resolution: .keepBoth, applyToAll: true)
        }) { r in
            check("apply-to-all asks once", asked.count == 1 && asked[0].remaining == 3, "\(asked.count) asks, remaining \(asked.map(\.remaining))")
            check("keep both made three renamed copies", r.created.map(\.lastPathComponent).sorted() == ["a 2.txt", "b 2.txt", "c 2.txt"], "\(r.created.map(\.lastPathComponent))")
            asked = []
            // 2. skip all: asked once, nothing copied, originals intact
            FileOperations.transfer(files, to: dst, kind: .copy, conflict: { c in
                asked.append(c); return .init(resolution: .skip, applyToAll: true)
            }) { r in
                check("skip-all asks once and copies nothing", asked.count == 1 && r.created.isEmpty && !r.cancelled)
                check("destination untouched", (try? String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8)) == "dst")
                asked = []
                // 3. per-file answers: replace a, stop at b → c never asked
                FileOperations.transfer(files, to: dst, kind: .copy, conflict: { c in
                    asked.append(c)
                    return .init(resolution: c.source.lastPathComponent == "a.txt" ? .replace : .cancel)
                }) { r in
                    check("remaining counts down per conflict", asked.map(\.remaining) == [3, 2], "\(asked.map(\.remaining))")
                    check("stop cancels the rest", r.cancelled && asked.count == 2)
                    check("replace overwrote a.txt", (try? String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8)) == "src")
                    // 4. merge folders: src folder into an existing folder of the same name
                    let outer = tmp.appendingPathComponent("mergeout")
                    try? fm.createDirectory(at: outer.appendingPathComponent("csrc"), withIntermediateDirectories: true)
                    try? "old".write(to: outer.appendingPathComponent("csrc/b.txt"), atomically: true, encoding: .utf8)
                    asked = []
                    FileOperations.transfer([src], to: outer, kind: .copy, conflict: { c in
                        asked.append(c)
                        return .init(resolution: c.bothFolders ? .merge : .keepBoth)
                    }) { r in
                        check("folder conflict offers merge", asked.first?.bothFolders == true)
                        check("merge copied the new children", fm.fileExists(atPath: outer.appendingPathComponent("csrc/a.txt").path) && fm.fileExists(atPath: outer.appendingPathComponent("csrc/c.txt").path))
                        check("merge asked about the inner conflict and kept both", asked.count == 2 && fm.fileExists(atPath: outer.appendingPathComponent("csrc/b 2.txt").path) && (try? String(contentsOf: outer.appendingPathComponent("csrc/b.txt"), encoding: .utf8)) == "old")
                        try? fm.removeItem(at: outer); try? fm.removeItem(at: src); try? fm.removeItem(at: dst)
                        getInfo(wc, tmp)
                    }
                }
            }
        }
    }

    // MARK: 7. Get Info — FileInfo facts, Info window, Summary, Inspector, menu icons

    private static func getInfo(_ wc: MainWindowController, _ tmp: URL) {
        print("== get info ==")
        let b = wc.browser, fm = FileManager.default
        let dir = tmp.appendingPathComponent("infoDir")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("info.txt")
        try? "hello world".write(to: file, atomically: true, encoding: .utf8)
        try? "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "bb".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        // Facts, Finder's wording
        let whereLine = FileInfo.whereString(for: file)
        check("Where: ends with the parent's name", whereLine.hasSuffix(tmp.lastPathComponent), whereLine)
        check("Where: starts at the volume", whereLine.hasPrefix(fm.componentsToDisplay(forPath: "/")?.first ?? "Macintosh HD"), whereLine)
        check("privilege 644 owner", FileInfo.privilege(mode: 0o644, who: .owner) == .readWrite)
        check("privilege 644 group/everyone", FileInfo.privilege(mode: 0o644, who: .group) == .readOnly && FileInfo.privilege(mode: 0o644, who: .everyone) == .readOnly)
        check("privilege 733 everyone is a drop box", FileInfo.privilege(mode: 0o733, who: .everyone) == .writeOnly)
        check("No Access for everyone → 640", FileInfo.mode(0o644, setting: .noAccess, for: .everyone, isFolder: false) == 0o640)
        check("a file keeps its execute bit", FileInfo.mode(0o755, setting: .readOnly, for: .group, isFolder: false) == 0o755)
        check("a folder's Read only keeps x", FileInfo.mode(0o755, setting: .readOnly, for: .everyone, isFolder: true) == 0o755)
        check("a folder's No Access drops x", FileInfo.mode(0o755, setting: .noAccess, for: .everyone, isFolder: true) == 0o750)
        let fileSize = FileInfo.sizeString(FileInfo.Size(bytes: 6148, onDisk: 8192, items: 0, isFolder: false, finished: true))
        check("file size string", fileSize == "6,148 bytes (8 KB on disk)", fileSize)
        check("zero size string", FileInfo.sizeString(FileInfo.Size(bytes: 0, onDisk: 0, items: 0, isFolder: false, finished: true)) == "Zero bytes (Zero bytes on disk)")
        let folderSize = FileInfo.sizeString(FileInfo.Size(bytes: 3, onDisk: 8192, items: 2, isFolder: true, finished: true))
        check("folder size string", folderSize == "8 KB on disk (3 bytes) for 2 items", folderSize)
        check("summary kind", FileInfo.summaryKind(for: [file, dir]) == "1 document, 1 folder", FileInfo.summaryKind(for: [file, dir]))
        try? FileInfo.setComment("hello comment", for: file)
        check("comment round-trips through the xattr", FileInfo.comment(for: file) == "hello comment", FileInfo.comment(for: file))
        try? FileInfo.setComment("", for: file)
        check("empty comment removes the xattr", FileInfo.comment(for: file) == "")
        check("kind of a text file", FileInfo.kind(of: file).lowercased().contains("text"), FileInfo.kind(of: file))
        check("bundle info has a version", FileInfo.bundleInfo(for: URL(fileURLWithPath: "/System/Applications/Calculator.app")).contains { $0.0 == "Version" })
        check("volume info for /", FileInfo.volumeInfo(for: URL(fileURLWithPath: "/")).contains { $0.0 == "Capacity" })
        FileInfo.computeSize(of: [dir], countingChildren: true) { size in
            guard size.finished else { return }
            check("folder size counts 2 items and 3 bytes", size.items == 2 && size.bytes == 3, "\(size)")
        }

        // Menus: Finder's icons and the new items
        let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu
        check("File ▸ New Folder has Finder's icon", fileMenu?.item(withTitle: "New Folder")?.image != nil)
        check("File ▸ Get Info is ⌘I", fileMenu?.item(withTitle: "Get Info")?.keyEquivalent == "i")
        check("File ▸ Show Inspector is the ⌥ alternate", fileMenu?.item(withTitle: "Show Inspector")?.isAlternate == true)
        let background = b.buildContextMenu(for: [])
        check("background menu: New Folder has an icon", background.items.first?.title == "New Folder" && background.items.first?.image != nil)
        check("background menu offers Get Info", background.item(withTitle: "Get Info") != nil)

        b.navigate(to: tmp)
        after(0.5) {
            let itemMenu = b.buildContextMenu(for: b.model.items.filter { $0.name == "info.txt" })
            check("item menu offers Get Info", itemMenu.item(withTitle: "Get Info") != nil)
            b.fileList.select(name: "info.txt")
            AppDefaults.shared.set(false, forKey: InfoSection.explicitPreferenceKey(for: "comments"))
            b.getInfo(nil)
            after(0.4) { infoWindow(wc, tmp, file, dir) }
        }
    }

    private static func infoWindow(_ wc: MainWindowController, _ tmp: URL, _ file: URL, _ dir: URL) {
        let fm = FileManager.default
        guard let info = InfoWindowController.openWindows.first else { check("info window opened", false); return }
        check("one info window", InfoWindowController.openWindows.count == 1)
        check("title is '<name> Info'", info.window?.title == "info.txt Info", info.window?.title ?? "nil")
        check("header shows the name", info.displayedName == "info.txt")
        let keys = info.sectionKeys.filter { $0 != "moreInfo" }
        check("sections in Finder's order", keys == ["general", "name", "comments", "openWith", "preview", "sharing"], "\(info.sectionKeys)")
        check("General has Kind/Where/Created/Modified", ["Kind", "Where", "Created", "Modified"].allSatisfy { info.value(for: $0)?.isEmpty == false })
        check("name field holds the full name", info.nameFieldValue == "info.txt")
        check("Open with lists at least one app", info.openWithTitles.count >= 1, "\(info.openWithTitles)")
        check("permissions table has three rows", info.permissionRowCount == 3)
        check("window fits its content", (info.window?.frame.height ?? 0) > 300, "\(info.window?.frame.height ?? 0)")
        info.window?.contentView?.layoutSubtreeIfNeeded()
        let infoWidth = (info.window?.contentView as? NSScrollView)?.contentView.bounds.width ?? 0
        check("Info sections fill the scroll viewport", infoWidth > 0 && info.sectionKeys.allSatisfy {
            abs((info.section($0)?.frame.width ?? 0) - infoWidth) < 1
        })
        check("Info preview has the full inset width", abs((info.section("preview")?.content.frame.width ?? 0) - (infoWidth - 32)) < 1)
        check("a section remembered collapsed opens collapsed", info.section("comments")?.isExpanded == false && info.section("comments")?.content.isHidden == true)
        check("sections show a chevron", info.section("general")?.hasChevron == true)
        info.section("comments")?.toggle()
        check("toggling expands it", info.section("comments")?.isExpanded == true && info.section("comments")?.content.isHidden == false)
        AppDefaults.shared.removeObject(forKey: InfoSection.explicitPreferenceKey(for: "comments"))
        check("the Info window never becomes main", NSApp.mainWindow !== info.window,
              "active=\(NSApp.isActive) main=\(NSApp.mainWindow?.title ?? "nil") key=\(NSApp.keyWindow?.title ?? "nil")")
        after(0.6) {
            check("size finished", info.isSizeFinished)
            check("Size: is the file form", info.value(for: "Size") == "11 bytes (4 KB on disk)", info.value(for: "Size") ?? "nil")
            check("header size is short", info.displayedHeaderSize == "4 KB", info.displayedHeaderSize)
            info.setLocked(true)
            check("Locked sets the immutable flag", FileInfo.isLocked(file))
            info.setLocked(false)
            check("unlocked again", !FileInfo.isLocked(file))
            info.setHiddenExtension(true)
            check("Hide extension sets the flag", FileInfo.hasHiddenExtension(file))
            info.setHiddenExtension(false)
            func mode() -> Int { ((try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int) ?? -1 }
            info.setPrivilege(.noAccess, for: .everyone)
            check("everyone → No Access clears the bits", mode() & 0o7 == 0, String(mode(), radix: 8))
            info.setPrivilege(.readOnly, for: .everyone)
            check("everyone → Read only", mode() & 0o7 == 0o4, String(mode(), radix: 8))
            info.commitRename("info2.txt")
            after(0.5) {
                check("rename from the Info window", fm.fileExists(atPath: tmp.appendingPathComponent("info2.txt").path) && info.urls.first?.lastPathComponent == "info2.txt",
                      "exists=\(fm.fileExists(atPath: tmp.appendingPathComponent("info2.txt").path)) urls=\(info.urls.map(\.lastPathComponent)) open=\(InfoWindowController.openWindows.count)")
                check("title follows the rename", info.window?.title == "info2.txt Info", info.window?.title ?? "nil")
                check("undo is registered on the Info window", info.window?.undoManager?.undoActionName == "Rename")
                info.window?.undoManager?.undo()
                after(0.5) {
                    check("undo rename", fm.fileExists(atPath: file.path) && info.window?.title == "info.txt Info", info.window?.title ?? "nil")
                    // A change in the folder while a name is being typed must neither commit nor drop the edit.
                    info.section("name")?.isExpanded = true
                    info.beginEditingName()
                    info.typeName("half")
                    check("name field is being edited", info.isEditing)
                    try? "x".write(to: tmp.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)
                    DirectoryChanges.post([tmp])
                    after(0.5) {
                        check("rebuild waits while typing", info.isEditing && info.nameFieldValue == "half" && fm.fileExists(atPath: file.path) && !fm.fileExists(atPath: tmp.appendingPathComponent("half").path))
                        info.window?.makeFirstResponder(nil)            // done typing
                        after(0.5) {
                            check("ending the edit commits and rebuilds", fm.fileExists(atPath: tmp.appendingPathComponent("half").path) && info.window?.title == "half Info" && !info.isEditing, info.window?.title ?? "nil")
                            info.commitRename("info.txt")
                            after(0.5) { infoWindowFollows(wc, tmp, file, dir, info) }
                        }
                    }
                }
            }
        }
    }

    private static func infoWindowFollows(_ wc: MainWindowController, _ tmp: URL, _ file: URL, _ dir: URL, _ info: InfoWindowController) {
        let b = wc.browser, fm = FileManager.default
        check("renamed back", fm.fileExists(atPath: file.path) && info.window?.title == "info.txt Info", info.window?.title ?? "nil")
        b.fileList.select(name: "info.txt")
        b.getInfo(nil)
        check("⌘I on the same item reuses its window", InfoWindowController.openWindows.count == 1, "windows=\(InfoWindowController.openWindows.map(\.urls)) targets=\(b.infoTargets)")
        b.fileList.select(names: ["info.txt", "infoDir"])
        b.getSummaryInfo(nil)
        guard let summary = InfoWindowController.openWindows.first(where: { $0.mode == .summary }) else { check("summary window", false); return }
        check("summary title", summary.window?.title == "Multiple Item Info")
        check("summary header counts items", summary.displayedName == "2 items")
        check("summary Kind:", summary.value(for: "Kind") == "1 document, 1 folder", summary.value(for: "Kind") ?? "nil")
        check("summary has only General", summary.sectionKeys == ["general"], "\(summary.sectionKeys)")
        b.showInspector(nil)
        guard let inspector = InfoWindowController.inspectorWindow else { check("inspector", false); return }
        after(0.4) {
            check("inspector shows the selection as a summary", inspector.isSummary && inspector.displayedName == "2 items", "\(inspector.displayedName) urls=\(inspector.urls.map(\.lastPathComponent))")
            b.fileList.select(name: "infoDir")
            after(0.4) {
                check("inspector follows a new selection", inspector.window?.title == "infoDir Info", inspector.window?.title ?? "nil")
                check("inspector shows a folder's Size: form", inspector.value(for: "Size")?.hasSuffix("for 2 items") == true, inspector.value(for: "Size") ?? "nil")
                // A rename in the browser: its Info window and the Inspector follow, the selection too.
                b.getInfo(nil)
                guard let dirItem = b.model.items.first(where: { $0.name == "infoDir" }),
                      let dirWindow = InfoWindowController.openWindows.first(where: { $0.mode == .item && $0.urls == [dirItem.url] }) else { check("Info window for infoDir", false); return }
                b.rename(dirItem, to: "infoDir2")
                after(0.6) {
                    check("browser rename keeps the item selected", b.fileList.selectedItems.map(\.name) == ["infoDir2"], "\(b.fileList.selectedItems.map(\.name))")
                    check("Info window follows a browser rename", dirWindow.window?.title == "infoDir2 Info", dirWindow.window?.title ?? "nil")
                    check("Inspector follows a browser rename", inspector.window?.title == "infoDir2 Info", inspector.window?.title ?? "nil")
                    // A rename made outside the app (mv) is found by inode.
                    let dir3 = tmp.appendingPathComponent("infoDir3")
                    try? fm.moveItem(at: tmp.appendingPathComponent("infoDir2"), to: dir3)
                    after(1.0) {
                        check("Info window follows an outside rename", dirWindow.window?.title == "infoDir3 Info", dirWindow.window?.title ?? "nil")
                        dirWindow.typeComment("closing note")
                        // The outside rename already emptied the browser's selection; click something, then nothing.
                        b.fileList.select(name: "sibling.txt")
                        b.fileList.select(name: nil)
                        after(0.4) {
                            check("inspector shows the folder when nothing is selected", inspector.window?.title == "\(tmp.lastPathComponent) Info", inspector.window?.title ?? "nil")
                            try? fm.removeItem(at: file)
                            DirectoryChanges.post([tmp])
                            after(0.5) {
                                check("deleting the item closes its Info windows", !InfoWindowController.openWindows.contains { $0.urls.contains(file) }, "\(InfoWindowController.openWindows.map { $0.window?.title ?? "" })")
                                InfoWindowController.closeAll()
                                check("closeAll empties the registry", InfoWindowController.openWindows.isEmpty && InfoWindowController.inspectorWindow == nil)
                                check("closing saves a comment still being typed", FileInfo.comment(for: dir3) == "closing note", FileInfo.comment(for: dir3))
                                try? fm.removeItem(at: dir3)
                                b.navigate(to: tmp)
                                after(0.3) { favouritesAndHistory(wc, tmp) }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 5. M4 — history menu, favourites reorder

    private static func favouritesAndHistory(_ wc: MainWindowController, _ tmp: URL) {
        print("== quick navigation ==")
        let b = wc.browser
        let back = b.historyMenu(back: true)
        check("back history menu lists earlier folders", back.items.count >= 2, "\(back.items.map(\.title))")
        check("history menu items carry slots", back.items.allSatisfy { $0.tag >= 0 })
        let places = wc.places
        let a = tmp.appendingPathComponent("favA"), c = tmp.appendingPathComponent("favB")
        try? FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        places.resetFavourites()
        let builtInCount = places.sections[0].places.count
        places.addFavourite(a); places.addFavourite(c)
        check("favourites appended in order", places.favouriteIndex(of: a) == builtInCount && places.favouriteIndex(of: c) == builtInCount + 1)
        check("sidebar shows added favourites", wc.sidebar.outlineView.numberOfRows >= builtInCount + 4, "\(wc.sidebar.outlineView.numberOfRows)")
        let sb = wc.sidebar
        SidebarContextSmokeTests.run(sb, firstURL: a, secondURL: c)
        let rowA = sb.row(for: a), rowC = sb.row(for: c)
        check("favourite rows found", rowA >= 0 && rowC == rowA + 1, "\(rowA) \(rowC)")
        let itemA = sb.outlineView.item(atRow: rowA), rectA = sb.outlineView.rect(ofRow: rowA)
        check("hover on upper half of A → before A", sb.reorderTargetIndex(item: itemA, childIndex: -1, pointerY: rectA.minY + 2) == builtInCount)
        check("hover on lower half of A → after A", sb.reorderTargetIndex(item: itemA, childIndex: -1, pointerY: rectA.maxY - 2) == builtInCount + 1)
        let itemHome = sb.outlineView.item(atRow: 1), rectHome = sb.outlineView.rect(ofRow: 1)
        check("hover on the first built-in → slot 0 (no clamp)", sb.reorderTargetIndex(item: itemHome, childIndex: -1, pointerY: rectHome.minY + 2) == 0)
        check("gap between rows → that index", sb.reorderTargetIndex(item: sb.outlineView.parent(forItem: itemA), childIndex: 2, pointerY: 0) == 2)
        // move a user favourite to the very top, above the built-ins
        places.moveFavourite(from: places.favouriteIndex(of: c)!, to: 0)
        check("user favourite moved above built-ins", places.favouriteIndex(of: c) == 0 && sb.row(for: c) == 1, "\(places.sections[0].places.map(\.name))")
        // move a built-in (home) down below A
        let home = wc.provider.homeURL
        let fromHome = places.favouriteIndex(of: home)!, toAfterA = places.favouriteIndex(of: a)! + 1
        places.moveFavourite(from: fromHome, to: toAfterA)
        check("built-in moved after a user favourite", places.favouriteIndex(of: home) == places.favouriteIndex(of: a)! + 1, "\(places.sections[0].places.map(\.name))")
        // built-ins can be removed, and reset brings them back
        let desktop = places.sections[0].places.first { $0.isBuiltIn && $0.name == "Desktop" }?.url
        if let desktop {
            places.removeFavourite(desktop)
            check("built-in can be removed", !places.isFavourite(desktop))
        }
        places.removeFavourite(a); places.removeFavourite(c)
        check("favourites removed", !places.isFavourite(a) && !places.isFavourite(c))
        places.resetFavourites()
        check("reset restores the built-ins", places.sections[0].places.count == builtInCount && places.favouriteIndex(of: home) == 0)
        archiveUI(wc, tmp) {
            try? FileManager.default.removeItem(at: tmp)
            // Across the whole run, the archive tool never ran on the main
            // thread: listing never extracts, and everything that does
            // extracts off it (D102).
            check("the archive tool never ran on the main thread in the whole run",
                  SystemArchiveToolRunner.shared.mainThreadInvocations == 0,
                  "\(SystemArchiveToolRunner.shared.mainThreadInvocations) of \(SystemArchiveToolRunner.shared.invocations) runs")
            PreferencesIsolationSmokeTests.verifyProductionUnchanged()
            check("all grouped matrices completed", SmokeReport.shared.allGroupsFinished)
            SmokeReport.shared.finishRun()
            print("SMOKE TEST PASSED")
            exit(0)
        }
    }

    private static func archiveUI(_ wc: MainWindowController, _ tmp: URL, completion: @escaping () -> Void) {
        print("== archive UI, selection and undo ==")
        let fm = FileManager.default
        let root = tmp.appendingPathComponent("archive-ui")
        try! fm.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("sample.txt")
        try! "archive UI contents".write(to: source, atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("sample.txt.zip")
        let extracted = root.appendingPathComponent("sample 2.txt")
        let original = wc.browser
        wc.tabs.newTab(at: root)
        let inactive = wc.browser
        awaitInitialListing(inactive.model) {
        wc.tabs.toggleSplit()
        let active = wc.browser
        let undo = wc.window!.undoManager!
        func exercise(_ mode: ViewMode, next: @escaping () -> Void) {
            active.setViewMode(mode)
            active.setGroupKey(.kind)
            active.nameFilter = "sample"
            awaitCondition("\(mode): archive fixture loaded", condition: { active.model.items.contains { $0.url.standardizedFileURL == source.standardizedFileURL } }) {
                active.fileView.select(names: ["sample.txt"])
                wc.window?.makeFirstResponder(wc.sidebar.outlineView)
                let menu = MainMenu.actionsMenu(target: wc)
                let compress = menu.items.first { ($0.representedObject as? String) == MainMenu.FileAction.compress.rawValue }!
                check("\(mode): Compress names the active file", wc.validateMenuItem(compress) && compress.title.contains("sample.txt"))
                check("\(mode): context menu offers Compress", active.buildContextMenu(for: active.fileView.selectedItems).items.contains { $0.title == compress.title })
                wc.performFileAction(compress)
                awaitCondition("\(mode): More creates ZIP and registers undo", condition: {
                    fm.fileExists(atPath: zip.path) && undo.undoActionName == "Compress" && active.model.items.contains { $0.url.standardizedFileURL == zip.standardizedFileURL }
                }) {
                    checkListHeaderGeometry(active, "\(mode) compression")
                    check("\(mode): compression preserves source and inactive pane", (try? String(contentsOf: source)) == "archive UI contents" && wc.browser === active && inactive.currentURL == root && original !== active)
                    undo.undo()
                    awaitCondition("\(mode): undo compression removes only ZIP", condition: { !fm.fileExists(atPath: zip.path) && fm.fileExists(atPath: source.path) }) {
                        undo.redo()
                        awaitCondition("\(mode): redo compression restores ZIP", condition: { fm.fileExists(atPath: zip.path) && active.model.items.contains { $0.url.standardizedFileURL == zip.standardizedFileURL } }) {
                            checkListHeaderGeometry(active, "\(mode) compression redo")
                            active.fileView.select(names: [zip.lastPathComponent])
                            let extract = menu.items.first { ($0.representedObject as? String) == MainMenu.FileAction.extract.rawValue }!
                            check("\(mode): ZIP enables extraction in both menus", wc.validateMenuItem(extract) && active.buildContextMenu(for: active.fileView.selectedItems).items.contains { $0.title == "Extract" })
                            wc.performFileAction(extract)
                            awaitCondition("\(mode): extraction publishes a non-overwriting result", condition: { fm.fileExists(atPath: extracted.path) && undo.undoActionName == "Extract" }) {
                                check("\(mode): extraction contents and archive preserved", (try? String(contentsOf: extracted)) == "archive UI contents" && fm.fileExists(atPath: zip.path))
                                undo.undo()
                                awaitCondition("\(mode): undo extraction preserves ZIP", condition: { !fm.fileExists(atPath: extracted.path) && fm.fileExists(atPath: zip.path) }) {
                                    undo.redo()
                                    awaitCondition("\(mode): redo extraction restores output", condition: { fm.fileExists(atPath: extracted.path) }) {
                                        let generation = active.model.generation
                                        active.refreshPreservingSelection()
                                        awaitCondition("\(mode): archive refresh completes", condition: { active.model.generation > generation }) {
                                            checkListHeaderGeometry(active, "\(mode) extraction redo refresh")
                                            active.setGroupKey(.none)
                                            let plainGeneration = active.model.generation
                                            active.refreshPreservingSelection()
                                            awaitCondition("\(mode): ungrouped archive refresh completes", condition: { active.model.generation > plainGeneration }) {
                                                checkListHeaderGeometry(active, "\(mode) ungrouped refresh")
                                                try! fm.removeItem(at: zip)
                                                try! fm.removeItem(at: extracted)
                                                undo.removeAllActions()
                                                active.reload()
                                                next()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        awaitInitialListing(active.model) {
        exercise(.details) {
            exercise(.icons) {
                _ = wc.tabs.closeCurrentTab()
                original.setGroupKey(.none)
                completion()
            }
        }
        }
        }
    }

    // MARK: 6. M5 — rename, trash, copy/paste, cut/paste, duplicate, undo, Quick Look

    private static func fileOperations(_ wc: MainWindowController, _ tmp: URL) {
        print("== file operations ==")
        let b = wc.browser
        let fm = FileManager.default
        let f1 = tmp.appendingPathComponent("untitled folder")

        // naming helpers
        check("uniqueURL appends 2", FileOperations.uniqueURL(for: f1).lastPathComponent == "untitled folder 3")
        let note = tmp.appendingPathComponent("note.txt")
        try? "hello".write(to: note, atomically: true, encoding: .utf8)
        check("duplicateURL uses ' copy'", FileOperations.duplicateURL(for: note).lastPathComponent == "note copy.txt")

        // rename incl. case-only rename on case-insensitive APFS (the audit's R11)
        let renamed = try? FileOperations.rename(f1, to: "Renamed")
        check("rename", renamed?.lastPathComponent == "Renamed" && fm.fileExists(atPath: tmp.appendingPathComponent("Renamed").path))
        let lower = try? FileOperations.rename(tmp.appendingPathComponent("Renamed"), to: "renamed")
        let actual = (try? fm.contentsOfDirectory(atPath: tmp.path))?.first { $0.lowercased() == "renamed" }
        check("case-only rename works on APFS", lower != nil && actual == "renamed", "\(actual ?? "nil")")

        b.reload()
        after(0.4) {
            // rename through the controller, then undo
            guard let item = b.model.items.first(where: { $0.name == "renamed" }) else { check("find renamed", false); return }
            b.rename(item, to: "Alpha")
            after(0.4) {
                check("controller rename + reselect", b.fileList.selectedItems.first?.name == "Alpha" && fm.fileExists(atPath: tmp.appendingPathComponent("Alpha").path))
                check("undo manager has Rename", wc.window?.undoManager?.canUndo == true && wc.window?.undoManager?.undoActionName == "Rename")
                wc.window?.undoManager?.undo()
                after(0.4) {
                    check("undo rename", fm.fileExists(atPath: tmp.appendingPathComponent("renamed").path) && !fm.fileExists(atPath: tmp.appendingPathComponent("Alpha").path))
                    copyPaste(wc, tmp)
                }
            }
        }
    }

    private static func copyPaste(_ wc: MainWindowController, _ tmp: URL) {
        let b = wc.browser, fm = FileManager.default
        b.fileList.select(name: "note.txt")
        check("Quick Look data source counts selection", b.numberOfPreviewItems(in: QLPreviewPanel.shared()) == 1)
        check("Quick Look item is the file URL", (b.previewPanel(QLPreviewPanel.shared(), previewItemAt: 0) as? NSURL)?.lastPathComponent == "note.txt")
        check("paste disabled with empty pasteboard", { NSPasteboard.general.clearContents(); return !b.validateMenuItem(NSMenuItem(title: "", action: #selector(BrowserViewController.paste(_:)), keyEquivalent: "")) }())
        b.copy(nil)
        check("copy put a file URL on the pasteboard", NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]))
        b.paste(nil)                                                  // same folder → "note copy.txt"
        after(0.8) {
            check("paste into same folder makes a copy", fm.fileExists(atPath: tmp.appendingPathComponent("note copy.txt").path))
            check("pasted copy is selected", b.fileList.selectedItems.first?.name == "note copy.txt")
            // cut → paste into a subfolder = move
            let sub = tmp.appendingPathComponent("sub")
            try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
            b.reload()
            after(0.4) {
                b.fileList.select(name: "note copy.txt")
                b.cut(nil)
                check("cut marks the item", b.fileList.cutURLs.count == 1)
                b.navigate(to: sub)
                after(0.4) {
                    b.paste(nil)
                    after(0.8) {
                        check("cut+paste moved the file", fm.fileExists(atPath: sub.appendingPathComponent("note copy.txt").path) && !fm.fileExists(atPath: tmp.appendingPathComponent("note copy.txt").path))
                        check("cut marker cleared after paste", b.fileList.cutURLs.isEmpty)
                        check("Move is its own undo group", wc.window?.undoManager?.undoActionName == "Move" && wc.window?.undoManager?.groupingLevel == 0)
                        wc.window?.undoManager?.undo()
                        after(0.6) {
                            check("undo move puts it back", fm.fileExists(atPath: tmp.appendingPathComponent("note copy.txt").path))
                            b.navigate(to: tmp)
                            after(0.4) { duplicateAndTrash(wc, tmp) }
                        }
                    }
                }
            }
        }
    }

    private static func duplicateAndTrash(_ wc: MainWindowController, _ tmp: URL) {
        let b = wc.browser, fm = FileManager.default
        b.fileList.select(name: "note.txt")
        b.duplicate(nil)
        after(0.5) {
            check("duplicate creates 'note copy 2.txt' (copy exists already)", fm.fileExists(atPath: tmp.appendingPathComponent("note copy 2.txt").path))
            check("duplicate selects the new file", b.fileList.selectedItems.first?.name == "note copy 2.txt")
            b.fileList.select(names: ["note copy 2.txt"])
            b.moveToTrash(nil)
            after(0.5) {
                check("trash removed the file", !fm.fileExists(atPath: tmp.appendingPathComponent("note copy 2.txt").path))
                check("undo action is Move to Trash", wc.window?.undoManager?.undoActionName == "Move to Trash")
                wc.window?.undoManager?.undo()
                after(0.5) {
                    check("undo trash restores the file", fm.fileExists(atPath: tmp.appendingPathComponent("note copy 2.txt").path))
                    // drop-operation rules (Finder semantics)
                    check("drop into own folder is a no-op", FileOperations.dropOperation(for: [tmp.appendingPathComponent("note.txt")], into: tmp, sourceMask: [.copy, .move]).isEmpty)
                    check("⌥-drop copies", FileOperations.dropOperation(for: [tmp.appendingPathComponent("note.txt")], into: tmp.appendingPathComponent("sub"), sourceMask: .copy) == .copy)
                    check("same-volume drop moves", FileOperations.dropOperation(for: [tmp.appendingPathComponent("note.txt")], into: tmp.appendingPathComponent("sub"), sourceMask: [.copy, .move]) == .move)
                    check("drop onto itself is a no-op", FileOperations.dropOperation(for: [tmp.appendingPathComponent("sub")], into: tmp.appendingPathComponent("sub"), sourceMask: [.copy, .move]).isEmpty)
                    expansion(wc, tmp)
                }
            }
        }
    }
}

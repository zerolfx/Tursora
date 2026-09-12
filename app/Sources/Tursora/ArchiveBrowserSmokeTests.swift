import AppKit

/// Real browser paths, including shared chrome, tabs and both file views.
enum ArchiveBrowserSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            let fixture = fm.temporaryDirectory.appendingPathComponent("tursora-zip-pane-" + UUID().uuidString).resolvingSymlinksInPath()
            let oldFlag = AppPreferences.experimentalZIPBrowsingEnabled
            let oldTerminal = AppPreferences.experimentalTerminalEnabled
            let oldMode = ViewPreferences.viewMode
            let oldGroup = ViewPreferences.groupKey
            let oldLastGroup = ViewPreferences.lastGroupKey
            let viewStore = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("views/state.json"))
            var window: MainWindowController?
            defer {
                window?.close()
                AppPreferences.experimentalZIPBrowsingEnabled = oldFlag
                AppPreferences.experimentalTerminalEnabled = oldTerminal
                ViewPreferences.viewMode = oldMode
                ViewPreferences.groupKey = oldGroup
                ViewPreferences.lastGroupKey = oldLastGroup
                try? viewStore.flush()
                try? fm.removeItem(at: fixture)
            }
            do {
                print("== ZIP browsing in the current pane ==")
                let docs = fixture.appendingPathComponent("Docs")
                let inner = docs.appendingPathComponent("Inner Folder")
                try fm.createDirectory(at: inner, withIntermediateDirectories: true)
                try Data("original note".utf8).write(to: docs.appendingPathComponent("notes.txt"))
                try Data("nested duplicate name".utf8).write(to: inner.appendingPathComponent("notes.txt"))
                try Data("nested note".utf8).write(to: inner.appendingPathComponent("nested.txt"))
                let welcome = fixture.appendingPathComponent("welcome.txt")
                try Data("welcome".utf8).write(to: welcome)
                try fm.createSymbolicLink(atPath: docs.appendingPathComponent("outside-link").path, withDestinationPath: welcome.path)
                let archive = try await compress([docs, welcome], to: fixture)
                let sourceBytes = try Data(contentsOf: archive)
                let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: fixture, viewPropertiesStore: viewStore)
                window = wc
                let browser = wc.browser
                let originalWindow = wc.window!
                wc.window?.setContentSize(NSSize(width: 1000, height: 650))
                await listed(browser, at: fixture)
                windowIdentityChecks()
                var opened: [URL] = []
                browser.archiveFileOpener = { opened.append($0); return true }
                AppPreferences.experimentalZIPBrowsingEnabled = true
                let archiveDocs = archive.appendingPathComponent("Docs")
                let archiveInner = archiveDocs.appendingPathComponent("Inner Folder")

                for mode: ViewMode in [.details, .icons] {
                    browser.navigate(to: fixture)
                    await listed(browser, at: fixture)
                    browser.setViewMode(mode)
                    browser.setGroupKey(.kind)
                    // Virtual pages start from the explicit default on entry.
                    browser.useCurrentViewAsDefault()
                    browser.nameFilter = "*.zip"
                    browser.fileView.select(urls: [archive])
                    check("\(mode): select source ZIP before Open", browser.fileView.selectedItems.count == 1)
                    let windowsBeforeOpen = NSApp.windows
                    browser.openSelection()
                    await listed(browser, at: archive)
                    let windowsAfterOpen = NSApp.windows
                    check("\(mode): Open reuses the current browser and window",
                          wc.browser === browser && wc.tabs.count == 1 && wc.window === originalWindow
                          && browser.view.window === originalWindow
                          && addedWindows(before: windowsBeforeOpen, after: windowsAfterOpen).isEmpty,
                          "sameBrowser=\(wc.browser === browser), tabs=\(wc.tabs.count), sameWindow=\(wc.window === originalWindow), paneWindow=\(browser.view.window === originalWindow); "
                          + windowChanges(before: windowsBeforeOpen, after: windowsAfterOpen))
                    check("\(mode): archive root retains original structure and presentation", Set(browser.model.items.map(\.name)) == ["Docs", "welcome.txt"] && browser.viewMode == mode && browser.groupKey == .kind && !browser.isFiltering)
                    check("\(mode): archive URLs never expose snapshot paths", browser.currentURL == archive && browser.model.items.allSatisfy { $0.url.path.hasPrefix(archive.path + "/") && $0.url != $0.contentURL })
                    check("\(mode): chrome identifies the archive and read-only state", wc.tabs.addressBar.url == archive && wc.tabs.addressBar.segmentTitles.last == archive.lastPathComponent && wc.window?.representedURL == archive && browser.statusBar.statusText.contains("ZIP · Read-only"))
                    check("\(mode): normal listing and opening ZIP do not launch members", opened.isEmpty)
                    if mode == .details {
                        let docsNode = browser.model.node(for: archiveDocs)!
                        browser.fileList.expand(docsNode)
                        let innerNode = browser.model.node(for: archiveInner)!
                        browser.fileList.expand(innerNode)
                        let childURL = archiveInner.appendingPathComponent("notes.txt")
                        let child = browser.model.node(for: childURL)!.item
                        browser.selectContextTargets([child])
                        check("expanded ZIP tree keeps same-name context targets distinct", browser.fileView.selectedItems.map(\.url) == [childURL] && browser.fileView.isReadOnly)
                        browser.copy(nil)
                        let treeCopy = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                        check("expanded ZIP tree copies the selected nested member", treeCopy?.map(\.standardizedFileURL) == [child.readableContentURL!.standardizedFileURL] && (try? String(contentsOf: child.contentURL)) == "nested duplicate name")
                    }
                    browser.fileView.select(name: "Docs")
                    browser.openSelection()
                    await listed(browser, at: archiveDocs)
                    check("\(mode): folder opening stays inside the same pane", wc.browser === browser && browser.fileView.isReadOnly && browser.canGoBack && browser.canGoUp)
                    check("\(mode): breadcrumbs and completion use archive member names", wc.tabs.addressBar.segmentTitles.suffix(2) == [archive.lastPathComponent, "Docs"] && PathCompleter.completions(for: "In", cwd: archiveDocs, home: fixture) == ["Inner Folder/"])
                    check("\(mode): CmdL accepts an archive folder and rejects a member file", wc.tabs.addressBar.commit(archiveInner.path) && !wc.tabs.addressBar.commit(archiveDocs.appendingPathComponent("notes.txt").path))
                    await listed(browser, at: archiveInner)
                    browser.goBack()
                    await listed(browser, at: archiveDocs)
                    browser.goForward()
                    await listed(browser, at: archiveInner)
                    browser.goUp()
                    await listed(browser, at: archiveDocs)
                    check("\(mode): Up selects the enclosed folder just left", browser.fileView.selectedItems.map(\.name) == ["Inner Folder"])
                    browser.nameFilter = "notes*"
                    check("\(mode): archive members use the normal filter", browser.model.items.map(\.name) == ["notes.txt"])
                    browser.nameFilter = ""
                    browser.fileView.select(name: "notes.txt")
                    let note = browser.fileView.selectedItems[0]
                    let noteCopy = note.readableContentURL!
                    let originalOpened = opened.count
                    browser.openSelection()
                    check("\(mode): deliberate Open launches the validated temporary copy", opened.count == originalOpened + 1 && opened.last == noteCopy && opened.last != docs.appendingPathComponent("notes.txt"))
                    check("\(mode): Share and Quick Look receive the copy", wc.sharingItems == [noteCopy] && browser.numberOfPreviewItems(in: nil) == 1 && browser.previewPanel(nil, previewItemAt: 0)?.previewItemURL == noteCopy)
                    browser.copy(nil)
                    let copied = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                    check("\(mode): Copy exports the snapshot member", copied?.map(\.standardizedFileURL) == [noteCopy.standardizedFileURL])
                    let changeCount = NSPasteboard.general.changeCount
                    browser.cut(nil)
                    check("\(mode): Cut is inert in an archive", NSPasteboard.general.changeCount == changeCount)
                    browser.fileView.beginRename(item: note)
                    browser.rename(note, to: "changed.txt")
                    browser.duplicate(nil)
                    browser.moveToTrash(nil)
                    browser.deletePermanently(nil)
                    browser.paste(nil)
                    check("\(mode): write actions cannot modify archive contents", browser.newFolder() == nil && (try? String(contentsOf: note.contentURL)) == "original note" && (try? Data(contentsOf: archive)) == sourceBytes)
                    let menu = browser.buildContextMenu(for: [note])
                    check("\(mode): archive context menu offers reads without mutations", menu.items.contains { $0.title == "Copy" } && !menu.items.contains { ["Rename", "Duplicate", "Paste", "Move to Trash", "Cut", "Get Info"].contains($0.title) })
                    for action: MainMenu.FileAction in [.rename, .duplicate, .trash, .paste, .compress, .extract, .getInfo, .newFolder] {
                        let item = NSMenuItem(title: "", action: #selector(MainWindowController.performFileAction(_:)), keyEquivalent: "")
                        item.representedObject = action.rawValue
                        check("\(mode): More disables \(action.rawValue) in ZIP", !wc.validateMenuItem(item))
                    }
                    browser.fileView.select(name: "outside-link")
                    let beforeBlocked = opened.count
                    browser.openSelection()
                    check("\(mode): escaped links cannot open, preview or share", opened.count == beforeBlocked && browser.readableSelectionURLs.isEmpty && !browser.canPreviewSelection && wc.sharingItems.isEmpty)
                    browser.goUp()
                    await listed(browser, at: archive)
                    browser.goUp()
                    await listed(browser, at: fixture)
                    check("\(mode): Up exits ZIP and selects the original archive", browser.fileView.selectedItems.map { $0.url.standardizedFileURL } == [archive.standardizedFileURL] && browser.canModifyCurrentLocation && !browser.fileView.isReadOnly)
                    browser.copy(nil)
                    let copiedArchive = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                    check("\(mode): copying a previously browsed ZIP copies the ZIP file", copiedArchive?.map(\.standardizedFileURL) == [archive.standardizedFileURL] && wc.sharingItems.map(\.standardizedFileURL) == [archive.standardizedFileURL])
                    opened.removeAll()
                }

                browser.navigate(to: archiveInner)
                await listed(browser, at: archiveInner)
                let tab = wc.tabs.newTab(at: archiveInner)
                await listed(tab, at: archiveInner)
                check("new tab preserves the logical archive folder", tab !== browser && tab.isBrowsingArchive && wc.tabs.addressBar.segmentTitles.last == "Inner Folder")
                let windowsBeforeSplit = NSApp.windows
                wc.tabs.toggleSplit()
                let split = wc.browser
                await listed(split, at: archiveInner)
                let windowsAfterSplit = NSApp.windows
                check("splitting an archive clones its location without a new window",
                      split !== tab && wc.tabs.isSplit && split.isBrowsingArchive && wc.window === originalWindow
                      && split.view.window === originalWindow
                      && addedWindows(before: windowsBeforeSplit, after: windowsAfterSplit).isEmpty,
                      "newPane=\(split !== tab), split=\(wc.tabs.isSplit), archive=\(split.isBrowsingArchive), sameWindow=\(wc.window === originalWindow), paneWindow=\(split.view.window === originalWindow); "
                      + windowChanges(before: windowsBeforeSplit, after: windowsAfterSplit))
                split.navigate(to: fixture)
                await listed(split, at: fixture)
                let archived = wc.tabs.currentPage.inactive!
                check("archive state stays independent across split panes", !split.isBrowsingArchive && archived.isBrowsingArchive && archived.currentURL == archiveInner)
                archived.fileView.select(name: "nested.txt")
                wc.tabs.focusOtherPane()
                let output = fixture.appendingPathComponent("nested.txt")
                wc.browser.copyToOtherPane(nil)
                await waitUntil("copy out to sibling pane") { fm.fileExists(atPath: output.path) }
                check("copying out uses a writable destination and preserves ZIP", (try? String(contentsOf: output)) == "nested note" && (try? Data(contentsOf: archive)) == sourceBytes)
                let archiveBeforeDrop = archived.model.items.map(\.name)
                archived.dropFiles([welcome], to: archiveInner, op: .copy)
                check("drop into archive is inert", archived.model.items.map(\.name) == archiveBeforeDrop && !fm.fileExists(atPath: try! ArchiveWorkspace.shared.readableURL(for: archiveInner).appendingPathComponent("welcome.txt").path))
                AppPreferences.experimentalTerminalEnabled = true
                wc.toggleTerminal(nil)
                check("terminal uses the original archive parent", wc.terminalPanel?.pendingDirectory.standardizedFileURL.path == fixture.standardizedFileURL.path)
                wc.hideTerminal()
                AppPreferences.experimentalZIPBrowsingEnabled = false
                archived.goUp()
                await listed(archived, at: archiveDocs)
                check("disabling the experiment leaves existing ZIP pages read-only", archived.isBrowsingArchive && archived.fileView.isReadOnly)
                let retainedCopy = try ArchiveWorkspace.shared.readableURL(for: archiveDocs.appendingPathComponent("notes.txt"))
                _ = wc.tabs.closeCurrentTab()
                check("closing archive tabs retains externally readable copies", fm.fileExists(atPath: retainedCopy.path))
                check("closed archive tab can be reopened with its location", wc.tabs.reopenClosedTab() && wc.browser.currentURL == archiveDocs && wc.browser.isBrowsingArchive)

                wc.browser.navigate(to: fixture)
                await listed(wc.browser, at: fixture)
                wc.browser.setGroupKey(.none)
                wc.browser.fileView.select(urls: [archive])
                wc.browser.openSelection()
                let extracted = fixture.appendingPathComponent("Archive")
                await waitUntil("default extraction") { fm.fileExists(atPath: extracted.path) && wc.browser.fileView.selectedItems.map { $0.url.standardizedFileURL.path } == [extracted.standardizedFileURL.path] }
                check("disabled experiment keeps normal ZIP Open as extraction", !wc.browser.isBrowsingArchive && fm.fileExists(atPath: extracted.appendingPathComponent("Docs/notes.txt").path))

                AppPreferences.experimentalZIPBrowsingEnabled = true
                let second = fixture.appendingPathComponent("Second.zip")
                try fm.copyItem(at: archive, to: second)
                let current = wc.browser
                current.navigate(to: second)
                current.navigate(to: fixture)
                await listed(current, at: fixture)
                await waitUntil("cancelled preparation finishes") { ArchiveWorkspace.shared.session(for: second) != nil }
                check("late archive preparation cannot replace a newer navigation", current.currentURL?.standardizedFileURL.path == fixture.standardizedFileURL.path && !current.isPreparingArchive && !current.fileView.isReadOnly)
                let third = fixture.appendingPathComponent("Third.zip")
                try fm.copyItem(at: archive, to: third)
                current.navigate(to: third.appendingPathComponent("Docs/Inner Folder"))
                await listed(current, at: third.appendingPathComponent("Docs/Inner Folder"))
                check("typed unprepared ZIP child enters the requested folder", Set(current.model.items.map(\.name)) == ["nested.txt", "notes.txt"])
                current.navigate(to: fixture)
                await listed(current, at: fixture)
                let cancelled = fixture.appendingPathComponent("Cancelled.zip")
                try fm.copyItem(at: archive, to: cancelled)
                current.navigate(to: cancelled)
                current.navigate(to: archive.appendingPathComponent("missing-folder"))
                await waitUntil("cancelled archive snapshot finishes") { ArchiveWorkspace.shared.session(for: cancelled) != nil }
                check("failed replacement navigation clears pending read-only state", current.currentURL?.standardizedFileURL.path == fixture.standardizedFileURL.path && !current.isPreparingArchive && !current.fileView.isReadOnly && current.canModifyCurrentLocation)
                let fresh = BrowserViewController(provider: LocalFileProvider(), initialURL: fixture)
                _ = fresh.view
                fresh.navigate(to: archiveInner)
                await listed(fresh, at: archiveInner)
                check("deferred initial navigation cannot replace an explicit destination", fresh.currentURL == archiveInner && fresh.isBrowsingArchive)
                check("all browsing and mutations preserve source bytes", (try? Data(contentsOf: archive)) == sourceBytes && (try? String(contentsOf: docs.appendingPathComponent("notes.txt"))) == "original note")
                DispatchQueue.main.async(execute: completion)
            } catch { check("same-pane ZIP setup and operations", false, error.localizedDescription) }
        }
    }

    /// Earlier suites can release closed AppKit windows while ZIP preparation
    /// yields. Pane-local navigators also allocate hidden completion panels.
    /// Their existence is harmless; visible panels and new browser windows are not.
    /// Retaining each before-snapshot also prevents object-identifier reuse.
    @MainActor private static func addedWindows(before: [NSWindow], after: [NSWindow]) -> [NSWindow] {
        after.filter { window in
            !before.contains { $0 === window }
                && !(window is CompletionPopup.NonKeyPanel && !window.isVisible)
        }
    }

    @MainActor private static func windowChanges(before: [NSWindow], after: [NSWindow]) -> String {
        func describe(_ windows: [NSWindow]) -> String {
            windows.map { window in
                "\(ObjectIdentifier(window)) \(type(of: window)) title=\(window.title.debugDescription) controller=\(window.windowController.map { String(describing: type(of: $0)) } ?? "nil")"
            }.joined(separator: "; ")
        }
        return "windows before=\(before.count) after=\(after.count), added=[\(describe(addedWindows(before: before, after: after)))], removed=[\(describe(addedWindows(before: after, after: before)))]"
    }

    @MainActor private static func windowIdentityChecks() {
        let earlier = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let replacement = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let completion = CompletionPopup.NonKeyPanel(contentRect: .zero, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
        earlier.isReleasedWhenClosed = false
        replacement.isReleasedWhenClosed = false
        completion.isReleasedWhenClosed = false
        defer { earlier.close(); replacement.close(); completion.close() }
        check("window tracking permits an earlier suite's window to disappear",
              addedWindows(before: [earlier], after: []).isEmpty)
        check("window tracking catches a new window even when total count stays equal",
              addedWindows(before: [earlier], after: [replacement]).first === replacement)
        check("window tracking permits a pane's hidden completion panel",
              addedWindows(before: [earlier], after: [earlier, completion]).isEmpty)
        completion.orderFront(nil)
        check("window tracking still catches a visible completion panel",
              addedWindows(before: [earlier], after: [earlier, completion]).first === completion)
    }

    @MainActor private static func listed(_ browser: BrowserViewController, at url: URL) async {
        await waitUntil("listing \(url.lastPathComponent)", detail: { "current=\(String(describing: browser.currentURL)) expected=\(url) model=\(String(describing: browser.model.url)) items=\(browser.model.items.map(\.url))" }) {
            browser.currentURL?.standardizedFileURL.path == url.standardizedFileURL.path && browser.model.url?.standardizedFileURL.path == url.standardizedFileURL.path && browser.model.generation > 0 && !browser.isPreparingArchive
                && browser.model.items.allSatisfy { $0.url.deletingLastPathComponent().standardizedFileURL.path == url.standardizedFileURL.path }
        }
        browser.view.layoutSubtreeIfNeeded()
    }
    @MainActor private static func waitUntil(_ label: String, detail: () -> String = { "" }, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > deadline { check("\(label) completes", false, detail()); return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        print("\(success ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !success { fflush(stdout); exit(1) }
    }
    private static func compress(_ urls: [URL], to directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            FileOperations.compress(urls: urls, to: directory) { continuation.resume(with: $0) }
        }
    }
}

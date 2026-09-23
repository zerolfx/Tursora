import AppKit

/// Real browser paths, including shared chrome, tabs and both file views.
enum ArchiveBrowserSmokeTests: SmokeSuite {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            let fixture = fm.temporaryDirectory.appendingPathComponent("tursora-zip-pane-" + UUID().uuidString).resolvingSymlinksInPath()
            let zipKey = "experimentalZIPBrowsingEnabled"
            let terminalKey = "experimentalTerminalEnabled"
            let oldFlag = UserDefaults.standard.object(forKey: zipKey)
            let oldTerminal = UserDefaults.standard.object(forKey: terminalKey)
            let viewStore = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("views/state.json"))
            var window: MainWindowController?
            defer {
                window?.close()
                restorePreference(oldFlag, forKey: zipKey)
                restorePreference(oldTerminal, forKey: terminalKey)
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
                let archive = try await SmokeFixtures.compress([docs, welcome], to: fixture)
                let sourceBytes = try Data(contentsOf: archive)
                restorePreference(nil, forKey: zipKey)
                restorePreference(nil, forKey: terminalKey)
                check("fresh preferences enable ZIP browsing and the terminal command", AppPreferences.experimentalZIPBrowsingEnabled && AppPreferences.experimentalTerminalEnabled)
                let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: fixture, viewPropertiesStore: viewStore)
                window = wc
                let browser = wc.browser
                let originalWindow = wc.window!
                wc.window?.setContentSize(NSSize(width: 1000, height: 650))
                await listed(browser, at: fixture)
                let terminalItem = menuItem(#selector(MainWindowController.toggleTerminal(_:)), in: NSApp.mainMenu)
                check("the default terminal command is visible and enabled without creating a panel", terminalItem.map { !$0.isHidden && wc.validateMenuItem($0) } == true && wc.terminalPanel == nil)
                check("a first directory disables the actual toolbar Back button", !browser.canGoBack && wc.backToolbarButtonForTesting?.isEnabled == false)
                browser.fileView.select(urls: [archive])
                wc.openSelection(nil)
                check("opening a ZIP enables toolbar Back even with no directory history", browser.isPreparingArchive && browser.canGoBack && wc.backToolbarButtonForTesting?.isEnabled == true)
                if let back = wc.backToolbarButtonForTesting { dispatch(back) }
                check("toolbar Back cancels ZIP opening and disables itself without adding history", !browser.isPreparingArchive && !browser.canGoBack && wc.backToolbarButtonForTesting?.isEnabled == false && sameFileLocation(browser.currentURL, fixture) && browser.fileView.selectedItems.count == 1 && sameFileLocation(browser.fileView.selectedItems.first?.url, archive) && browser.archiveNotice.superview == nil,
                      "preparing=\(browser.isPreparingArchive) canBack=\(browser.canGoBack) enabled=\(String(describing: wc.backToolbarButtonForTesting?.isEnabled)) current=\(String(describing: browser.currentURL?.path)) fixture=\(fixture.path) selection=\(browser.fileView.selectedItems.map(\.url.path)) archive=\(archive.path) notice=\(browser.archiveNotice.superview != nil)")
                await waitUntil("toolbar cancellation cleans its ZIP worker") { !ArchiveWorkspace.shared.hasPendingPreparation(for: archive) }
                check("toolbar cancellation retains the first listing after worker cleanup", sameFileLocation(browser.currentURL, fixture) && ArchiveWorkspace.shared.session(for: archive) == nil)
                windowIdentityChecks()
                recoveryNoticeLayoutChecks()
                var opened: [URL] = []
                browser.archiveFileOpener = { opened.append($0); return true }
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
                    check("\(mode): default Open reuses the current browser and window",
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
                        check("expanded ZIP tree copies the selected nested member", treeCopy?.map(\.standardizedFileURL) == [child.publishedContentURL!.standardizedFileURL] && (try? String(contentsOf: child.contentURL)) == "nested duplicate name")
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
                    let noteCopy = note.publishedContentURL!
                    let originalOpened = opened.count
                    browser.openSelection()
                    check("\(mode): deliberate Open launches the validated temporary copy", opened.count == originalOpened + 1 && opened.last == noteCopy && opened.last != docs.appendingPathComponent("notes.txt"))
                    check("\(mode): Share and Quick Look receive the copy", (wc.sharingItems as? [URL]) == [noteCopy] && browser.numberOfPreviewItems(in: nil) == 1 && browser.previewPanel(nil, previewItemAt: 0)?.previewItemURL == noteCopy)
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
                    check("\(mode): a refused New Folder arms no inline edit", !browser.hasPendingRename && !browser.fileView.isRenaming)
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
                    check("\(mode): escaped links cannot open, preview or share", opened.count == beforeBlocked && browser.publishedSelectionURLs.isEmpty && !browser.canPreviewSelection && wc.sharingItems.isEmpty)
                    browser.goUp()
                    await listed(browser, at: archive)
                    browser.goUp()
                    await listed(browser, at: fixture)
                    check("\(mode): Up exits ZIP and selects the original archive", browser.fileView.selectedItems.map { $0.url.standardizedFileURL } == [archive.standardizedFileURL] && browser.canModifyCurrentLocation && !browser.fileView.isReadOnly)
                    browser.copy(nil)
                    let copiedArchive = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                    check("\(mode): copying a previously browsed ZIP copies the ZIP file", copiedArchive?.map(\.standardizedFileURL) == [archive.standardizedFileURL] && wc.sharingItems.compactMap { ($0 as? URL)?.standardizedFileURL } == [archive.standardizedFileURL])
                    let extractItem = MainMenu.actionsMenu(target: wc).items.first { ($0.representedObject as? String) == MainMenu.FileAction.extract.rawValue }!
                    check("\(mode): default browsing keeps explicit Extract in both menus", wc.validateMenuItem(extractItem) && browser.buildContextMenu(for: browser.fileView.selectedItems).items.contains { $0.title == "Extract" })
                    wc.performFileAction(extractItem)
                    let extracted = fixture.appendingPathComponent("Archive")
                    await waitUntil("\(mode): explicit extraction with default browsing") {
                        fm.fileExists(atPath: extracted.appendingPathComponent("Docs/notes.txt").path)
                            && originalWindow.undoManager?.undoActionName == "Extract"
                    }
                    check("\(mode): explicit Extract publishes files without entering ZIP", !browser.isBrowsingArchive && sameFileLocation(browser.currentURL, fixture) && (try? String(contentsOf: extracted.appendingPathComponent("Docs/notes.txt"))) == "original note" && (try? Data(contentsOf: archive)) == sourceBytes)
                    originalWindow.undoManager?.undo()
                    await waitUntil("\(mode): undo explicit extraction") { !fm.fileExists(atPath: extracted.path) }
                    check("\(mode): undo explicit Extract preserves the ZIP and original files", (try? Data(contentsOf: archive)) == sourceBytes && (try? String(contentsOf: docs.appendingPathComponent("notes.txt"))) == "original note")
                    check("\(mode): ordinary and ZIP navigation leave the default terminal uncreated", wc.terminalPanel == nil)
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
                check("drop into archive is inert", archived.model.items.map(\.name) == archiveBeforeDrop && !fm.fileExists(atPath: try! ArchiveWorkspace.shared.physicalURL(for: archiveInner).appendingPathComponent("welcome.txt").path))
                wc.toggleTerminal(nil)
                check("terminal uses the original archive parent", wc.terminalPanel?.pendingDirectory.standardizedFileURL.path == fixture.standardizedFileURL.path)
                wc.hideTerminal()
                AppPreferences.experimentalZIPBrowsingEnabled = false
                archived.goUp()
                await listed(archived, at: archiveDocs)
                check("opting out leaves existing ZIP pages read-only", archived.isBrowsingArchive && archived.fileView.isReadOnly)
                let retainedCopy = try ArchiveWorkspace.shared.physicalURL(for: archiveDocs.appendingPathComponent("notes.txt"))
                _ = wc.tabs.closeCurrentTab()
                check("closing archive tabs retains externally readable copies", fm.fileExists(atPath: retainedCopy.path))
                check("closed archive tab can be reopened with its location", wc.tabs.reopenClosedTab() && wc.browser.currentURL == archiveDocs && wc.browser.isBrowsingArchive)

                for mode: ViewMode in [.details, .icons] {
                    wc.browser.navigate(to: fixture)
                    await listed(wc.browser, at: fixture)
                    wc.browser.setViewMode(mode)
                    wc.browser.setGroupKey(.none)
                    wc.browser.fileView.select(urls: [archive])
                    wc.openSelection(nil)
                    let extracted = fixture.appendingPathComponent("Archive")
                    await waitUntil("\(mode): opt-out Open extracts") {
                        fm.fileExists(atPath: extracted.path)
                            && originalWindow.undoManager?.undoActionName == "Extract"
                            && wc.browser.fileView.selectedItems.map { $0.url.standardizedFileURL.path } == [extracted.standardizedFileURL.path]
                    }
                    check("\(mode): ZIP browsing opt-out routes normal Open to extraction", !wc.browser.isBrowsingArchive && (try? String(contentsOf: extracted.appendingPathComponent("Docs/notes.txt"))) == "original note" && (try? Data(contentsOf: archive)) == sourceBytes)
                    originalWindow.undoManager?.undo()
                    await waitUntil("\(mode): undo opt-out extraction") { !fm.fileExists(atPath: extracted.path) }
                }

                AppPreferences.experimentalZIPBrowsingEnabled = true
                let second = fixture.appendingPathComponent("Second.zip")
                try fm.copyItem(at: archive, to: second)
                let current = wc.browser
                current.navigate(to: second)
                current.navigate(to: fixture)
                await listed(current, at: fixture)
                await waitUntil("cancelled preparation finishes cleanup") { !ArchiveWorkspace.shared.hasPendingPreparation(for: second) }
                check("late archive preparation cannot replace a newer navigation or retain a snapshot", current.currentURL?.standardizedFileURL.path == fixture.standardizedFileURL.path && !current.isPreparingArchive && !current.fileView.isReadOnly && ArchiveWorkspace.shared.session(for: second) == nil)
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
                await waitUntil("cancelled archive snapshot finishes cleanup") { !ArchiveWorkspace.shared.hasPendingPreparation(for: cancelled) }
                check("failed replacement navigation clears pending read-only state without a cancelled snapshot", current.currentURL?.standardizedFileURL.path == fixture.standardizedFileURL.path && !current.isPreparingArchive && !current.fileView.isReadOnly && current.canModifyCurrentLocation && ArchiveWorkspace.shared.session(for: cancelled) == nil)
                await openingAndRecovery(wc, archiveBytes: sourceBytes, fixture: fixture, viewStore: viewStore)
                let fresh = BrowserViewController(provider: LocalFileProvider(), initialURL: fixture, viewPropertiesStore: viewStore)
                _ = fresh.view
                fresh.navigate(to: archiveInner)
                await listed(fresh, at: archiveInner)
                check("deferred initial navigation cannot replace an explicit destination", fresh.currentURL == archiveInner && fresh.isBrowsingArchive)
                check("all browsing and mutations preserve source bytes", (try? Data(contentsOf: archive)) == sourceBytes && (try? String(contentsOf: docs.appendingPathComponent("notes.txt"))) == "original note")
                DispatchQueue.main.async(execute: completion)
            } catch { check("same-pane ZIP setup and operations", false, error.localizedDescription) }
        }
    }

    @MainActor private static func openingAndRecovery(_ wc: MainWindowController, archiveBytes: Data,
                                                      fixture: URL, viewStore: DirectoryViewPropertiesStore) async {
        let workspace = ArchiveWorkspace.shared
        let browser = wc.browser
        for mode: ViewMode in [.details, .icons] {
            let cancelZIP = fixture.appendingPathComponent("Cancel-\(mode.rawValue).zip")
            let badZIP = fixture.appendingPathComponent("Broken-\(mode.rawValue).zip")
            let startupZIP = fixture.appendingPathComponent("Startup-\(mode.rawValue).zip")
            do {
                try archiveBytes.write(to: cancelZIP)
                try Data("invalid ZIP".utf8).write(to: badZIP)
                try Data("invalid startup ZIP".utf8).write(to: startupZIP)
            } catch { check("recovery fixtures are writable", false, error.localizedDescription); return }
            browser.navigate(to: fixture)
            await listed(browser, at: fixture)
            await waitUntil("\(mode): recovery files appear") { browser.model.items.contains { sameFileLocation($0.url, cancelZIP) } && browser.model.items.contains { sameFileLocation($0.url, badZIP) } }
            browser.setViewMode(mode)
            browser.setGroupKey(.none)
            browser.fileView.select(urls: [cancelZIP])
            wc.openSelection(nil)
            check("\(mode): opening a ZIP names the file and exposes Cancel", browser.isPreparingArchive && browser.archiveNotice.superview != nil && browser.archiveNotice.messageLabel.stringValue.contains(cancelZIP.lastPathComponent) && !browser.archiveNotice.cancelButton.isHidden && browser.archiveNotice.retryButton.isHidden)
            check("\(mode): pending ZIP preserves the old listing while protecting it from writes", sameFileLocation(browser.currentURL, fixture) && browser.fileView.selectedItems.count == 1 && sameFileLocation(browser.fileView.selectedItems.first?.url, cancelZIP) && browser.fileView.isReadOnly && !browser.canModifyCurrentLocation && sameFileLocation(browser.workspacePaneState.url, cancelZIP))
            if mode == .details { dispatch(browser.archiveNotice.cancelButton) }
            else { browser.cancelOperation(nil) }
            check("\(mode): Cancel or Escape restores the old directory and selection immediately", !browser.isPreparingArchive && browser.archiveNotice.superview == nil && sameFileLocation(browser.currentURL, fixture) && browser.fileView.selectedItems.count == 1 && sameFileLocation(browser.fileView.selectedItems.first?.url, cancelZIP) && !browser.fileView.isReadOnly && browser.canModifyCurrentLocation && sameFileLocation(browser.workspacePaneState.url, fixture))
            await waitUntil("\(mode): cancelled opening cleans its worker") { !workspace.hasPendingPreparation(for: cancelZIP) }
            check("\(mode): cancelled opening leaves no snapshot or late navigation", workspace.session(for: cancelZIP) == nil && sameFileLocation(browser.currentURL, fixture) && browser.failedArchiveURL == nil)

            browser.fileView.select(urls: [badZIP])
            wc.openSelection(nil)
            await waitUntil("\(mode): invalid ZIP reports failure") { !browser.isPreparingArchive && sameFileLocation(browser.failedArchiveURL, badZIP) }
            check("\(mode): failed ZIP offers a named inline error and recovery actions", browser.archiveNotice.superview != nil && browser.archiveNotice.messageLabel.stringValue.contains(badZIP.lastPathComponent) && !browser.archiveNotice.detailLabel.stringValue.isEmpty && !browser.archiveNotice.retryButton.isHidden && !browser.archiveNotice.enclosingFolderButton.isHidden && browser.archiveNotice.cancelButton.isHidden && NSApp.modalWindow == nil && wc.window?.attachedSheet == nil)
            check("\(mode): failed ZIP preserves the previous writable listing and selection", sameFileLocation(browser.currentURL, fixture) && browser.fileView.selectedItems.count == 1 && sameFileLocation(browser.fileView.selectedItems.first?.url, badZIP) && browser.canModifyCurrentLocation && !browser.fileView.isReadOnly)
            let search = SearchRequest(rootURL: fixture, name: "welcome")
            browser.startSearch(search)
            await waitUntil("\(mode): search after failed ZIP completes") { !browser.searchSession.status.isSearching && browser.model.items.contains { sameFileLocation($0.url, fixture.appendingPathComponent("welcome.txt")) } }
            check("\(mode): starting a search clears failed ZIP recovery controls", browser.isSearching && browser.failedArchiveURL == nil && browser.archiveNotice.superview == nil && browser.workspacePaneState.search == search)
            browser.reload()
            check("\(mode): Reload restarts the search instead of retrying the previous ZIP", browser.isSearching && !browser.isPreparingArchive && browser.searchSession.request == search && browser.failedArchiveURL == nil && browser.archiveNotice.superview == nil)
            await waitUntil("\(mode): reloaded search after failed ZIP completes") { !browser.searchSession.status.isSearching && browser.model.items.contains { sameFileLocation($0.url, fixture.appendingPathComponent("welcome.txt")) } }
            check("\(mode): completed Reload keeps the search and its original browsing folder", browser.isSearching && sameFileLocation(browser.currentURL, fixture) && browser.workspacePaneState.search == search && browser.archiveNotice.superview == nil)
            browser.navigate(to: fixture)
            await listed(browser, at: fixture)
            await waitUntil("\(mode): leaving search restores the ordinary ZIP listing") {
                !browser.model.isSearchResults && browser.model.items.contains { sameFileLocation($0.url, badZIP) }
            }
            browser.fileView.select(urls: [badZIP])
            wc.openSelection(nil)
            await waitUntil("\(mode): invalid ZIP can be retried after leaving search") { !browser.isPreparingArchive && sameFileLocation(browser.failedArchiveURL, badZIP) }
            do { try archiveBytes.write(to: badZIP, options: .atomic) }
            catch { check("replacement ZIP is writable", false, error.localizedDescription); return }
            if mode == .details { dispatch(browser.archiveNotice.retryButton) }
            else { browser.reload() }
            check("\(mode): Retry or Reload targets the failed ZIP", browser.isPreparingArchive && browser.failedArchiveURL == nil && sameFileLocation(browser.workspacePaneState.url, badZIP))
            await listed(browser, at: badZIP)
            check("\(mode): retry opens the repaired ZIP and removes recovery controls", browser.isBrowsingArchive && browser.archiveNotice.superview == nil && Set(browser.model.items.map(\.name)) == ["Docs", "welcome.txt"])

            let startupTarget = startupZIP.appendingPathComponent("Docs/Inner Folder")
            let fresh = BrowserViewController(provider: LocalFileProvider(), initialURL: startupTarget, viewPropertiesStore: viewStore)
            _ = fresh.view
            await waitUntil("\(mode): startup ZIP reports failure") { !fresh.isPreparingArchive && fresh.failedArchiveURL?.path == startupTarget.path }
            fresh.setViewMode(mode)
            check("\(mode): startup ZIP failure retains its requested logical folder without inventing a location", fresh.currentURL == nil && fresh.workspacePaneState.url.path == startupTarget.path && fresh.archiveNotice.superview != nil && !fresh.archiveNotice.retryButton.isHidden)
            do { try archiveBytes.write(to: startupZIP, options: .atomic) }
            catch { check("startup replacement ZIP is writable", false, error.localizedDescription); return }
            if mode == .details { fresh.reload() }
            else { dispatch(fresh.archiveNotice.retryButton) }
            await listed(fresh, at: startupTarget)
            check("\(mode): a startup failure can retry its exact nested location", fresh.currentURL?.path == startupTarget.path && fresh.isBrowsingArchive && fresh.archiveNotice.superview == nil && Set(fresh.model.items.map(\.name)) == ["notes.txt", "nested.txt"])
            browser.navigate(to: fixture)
            await listed(browser, at: fixture)
            browser.navigate(to: startupZIP.appendingPathComponent("missing-folder"))
            await waitUntil("\(mode): missing member reports failure") { browser.failedArchiveURL != nil }
            dispatch(browser.archiveNotice.enclosingFolderButton)
            await listed(browser, at: fixture)
            check("\(mode): Open Enclosing Folder returns to the original archive's parent", sameFileLocation(browser.currentURL, fixture) && browser.failedArchiveURL == nil && browser.archiveNotice.superview == nil && browser.canModifyCurrentLocation)
        }

        let startupCancel = fixture.appendingPathComponent("Cancel-Startup.zip")
        let closedPaneZIP = fixture.appendingPathComponent("Closed-Pane.zip")
        let closedTabZIP = fixture.appendingPathComponent("Closed-Tab.zip")
        let sharedPaneZIP = fixture.appendingPathComponent("Shared-Panes.zip")
        do {
            for url in [startupCancel, closedPaneZIP, closedTabZIP, sharedPaneZIP] { try archiveBytes.write(to: url) }
        } catch { check("cancellation lifecycle fixtures are writable", false, error.localizedDescription); return }
        let fresh = BrowserViewController(provider: LocalFileProvider(), initialURL: startupCancel, viewPropertiesStore: viewStore)
        _ = fresh.view
        fresh.navigate(to: startupCancel)
        check("startup cancellation fixture is preparing without a previous directory", fresh.currentURL == nil && fresh.isPreparingArchive)
        dispatch(fresh.archiveNotice.cancelButton)
        await listed(fresh, at: fixture)
        await waitUntil("startup cancellation cleans its worker") { !workspace.hasPendingPreparation(for: startupCancel) }
        check("cancelling initial ZIP navigation opens its enclosing folder", sameFileLocation(fresh.currentURL, fixture) && workspace.session(for: startupCancel) == nil && fresh.archiveNotice.superview == nil)

        let paneTab = wc.tabs.newTab(at: fixture)
        await listed(paneTab, at: fixture)
        let page = wc.tabs.currentPage
        let closingPane = page.split(with: fixture)
        await listed(closingPane, at: fixture)
        closingPane.navigate(to: closedPaneZIP)
        check("closing-pane fixture starts ZIP preparation", closingPane.isPreparingArchive)
        page.closePane(closingPane)
        await waitUntil("closed pane cancels its ZIP worker") { !workspace.hasPendingPreparation(for: closedPaneZIP) }
        check("closing a pane cancels its preparation and preserves the surviving pane", !closingPane.isPreparingArchive && workspace.session(for: closedPaneZIP) == nil && !page.isSplit && wc.browser === paneTab && sameFileLocation(paneTab.currentURL, fixture))
        let sharedPeer = page.split(with: fixture)
        await listed(sharedPeer, at: fixture)
        let sharedTarget = sharedPaneZIP.appendingPathComponent("Docs/Inner Folder")
        paneTab.navigate(to: sharedTarget)
        sharedPeer.navigate(to: sharedPaneZIP)
        check("split panes can request the same unprepared archive concurrently", paneTab.isPreparingArchive && sharedPeer.isPreparingArchive)
        page.closePane(sharedPeer)
        check("closing one archive waiter leaves its peer preparing", !sharedPeer.isPreparingArchive && paneTab.isPreparingArchive)
        await listed(paneTab, at: sharedTarget)
        check("the surviving pane finishes its shared ZIP request", paneTab.isBrowsingArchive && workspace.session(for: sharedPaneZIP) != nil && Set(paneTab.model.items.map(\.name)) == ["notes.txt", "nested.txt"])
        paneTab.navigate(to: fixture)
        await listed(paneTab, at: fixture)
        paneTab.navigate(to: closedTabZIP.appendingPathComponent("Docs/Inner Folder"))
        check("closing-tab fixture starts ZIP preparation", paneTab.isPreparingArchive)
        check("pending archive tab closes normally", wc.tabs.closeCurrentTab())
        await waitUntil("closed tab cancels its ZIP worker") { !workspace.hasPendingPreparation(for: closedTabZIP) }
        check("closed tab retains no background worker or snapshot", !paneTab.isPreparingArchive && workspace.session(for: closedTabZIP) == nil)
        check("reopening a cancelled tab resumes its requested ZIP", wc.tabs.reopenClosedTab() && wc.browser === paneTab && paneTab.isPreparingArchive)
        await listed(paneTab, at: closedTabZIP.appendingPathComponent("Docs/Inner Folder"))
        check("reopened tab finishes at its requested nested archive folder", paneTab.isBrowsingArchive && Set(paneTab.model.items.map(\.name)) == ["notes.txt", "nested.txt"])
        _ = wc.tabs.closeCurrentTab()
        await startupTitleChecks(fixture: fixture, viewStore: viewStore)
    }

    @MainActor private static func startupTitleChecks(fixture: URL, viewStore: DirectoryViewPropertiesStore) async {
        let archive = fixture.appendingPathComponent("Title-Startup.zip")
        let member = archive.appendingPathComponent("Notes")
        do { try Data("invalid ZIP for startup title".utf8).write(to: archive) }
        catch { check("startup title fixture is writable", false, error.localizedDescription); return }
        let window = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: archive,
                                          viewPropertiesStore: viewStore)
        defer { window.close() }
        window.restoreWorkspaceSession(WorkspaceWindowState(tabs: [
            WorkspaceTabState(panes: [WorkspacePaneState(url: archive)]),
            WorkspaceTabState(panes: [WorkspacePaneState(url: member)]),
        ], selectedTabIndex: 1))
        let panes = window.tabs.pages.map(\.active)
        let titles = [archive.lastPathComponent, member.lastPathComponent]
        check("restored ZIP tabs name their requested archive or member while opening", panes.allSatisfy { $0.currentURL == nil && $0.isPreparingArchive } && window.tabs.tabBar.titles == titles && window.window?.title == member.lastPathComponent && window.window?.representedURL?.path == member.path)
        await waitUntil("startup title fixtures report ZIP failure") { panes.allSatisfy { !$0.isPreparingArchive && $0.failedArchiveURL != nil } }
        check("failed startup ZIP tabs retain named chrome without inventing a current folder", panes.allSatisfy { $0.currentURL == nil && $0.archiveNotice.superview != nil } && window.tabs.tabBar.titles == titles && window.tabs.currentPage.tabToolTip == member.path && window.window?.title == member.lastPathComponent)
        window.tabs.selectTab(at: 0)
        check("switching to a failed archive root updates the window title", window.window?.title == archive.lastPathComponent && window.window?.representedURL?.path == archive.path)
        window.tabs.selectTab(at: 1)
        check("switching back to a failed member restores its window title and path", window.window?.title == member.lastPathComponent && window.window?.representedURL?.path == member.path && window.browser.currentURL == nil)
    }

    /// Real fixture locations may be reported through /var or /private/var.
    /// Compare the complete resolved path; logical ZIP-member paths stay separate.
    private static func sameFileLocation(_ actual: URL?, _ expected: URL) -> Bool {
        guard let actual else { return false }
        return actual.resolvingSymlinksInPath().standardizedFileURL.path
            == expected.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @MainActor private static func dispatch(_ button: NSButton) {
        guard let action = button.action else { check("archive recovery button has an action", false); return }
        check("\(button.title) dispatches through its actual control target", NSApp.sendAction(action, to: button.target, from: button))
    }

    @MainActor private static func recoveryNoticeLayoutChecks() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView = host
        let notice = ArchiveNavigationNotice()
        notice.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: host.topAnchor),
            notice.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        notice.showFailure(URL(fileURLWithPath: "/tmp/An archive with a long filename.zip"),
                           error: NSError(domain: "ArchiveNoticeLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: "This ZIP could not be read. Try a different archive."]))
        // Resize the same mounted notice in both directions, as a user would
        // when moving the split divider while an archive error is visible.
        for width: CGFloat in [160, 560, 160] {
            window.setContentSize(NSSize(width: width, height: 300))
            host.layoutSubtreeIfNeeded()
            let controls: [NSView] = [notice.messageLabel, notice.detailLabel, notice.retryButton, notice.enclosingFolderButton]
            let frames = controls.map { $0.convert($0.bounds, to: notice) }
            let detail = "notice=\(notice.bounds), controls=\(frames)"
            check("ZIP recovery controls fit a \(Int(width))-point pane", abs(notice.bounds.width - width) < 1 && frames.allSatisfy { $0.width > 0 && $0.height > 0 && notice.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) }, detail)
            let overlaps = frames.indices.contains { left in
                frames.indices.contains { right in right > left && frames[left].intersects(frames[right]) }
            }
            check("ZIP recovery controls do not overlap at \(Int(width)) points", !overlaps, detail)
            check("ZIP recovery action labels remain fully visible at \(Int(width)) points", [notice.retryButton, notice.enclosingFolderButton].allSatisfy { $0.bounds.width + 0.5 >= $0.intrinsicContentSize.width }, detail)
            let sameRow = abs(frames[2].midY - frames[3].midY) < 1
            check("ZIP recovery actions adapt when the pane is resized to \(Int(width)) points", width < 300 ? !sameRow : sameRow, detail)
        }
    }

    private static func restorePreference(_ value: Any?, forKey key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .tursoraPreferencesChanged, object: AppPreferences.shared)
    }

    @MainActor private static func menuItem(_ action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let found = menuItem(action, in: item.submenu) { return found }
        }
        return nil
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
}

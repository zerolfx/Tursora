import AppKit

/// Letting a ZIP's private copy go once no pane shows it (D103): what holds
/// it, what brings it back, and what must survive it.
enum ArchiveEvictionSmokeTests: SmokeSuite {
    static let checkPrefix = "eviction: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            guard let root = try? SmokeFixtures.temporaryDirectory("archive-eviction") else {
                check("fixture created", false); completion(); return
            }
            let runner = SystemArchiveToolRunner.shared
            let previousBrowsing = AppPreferences.experimentalZIPBrowsingEnabled
            var window: MainWindowController?
            var openedArchives: [URL] = []
            let viewStore = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
            defer {
                runner.beforeRunForTesting = nil
                window?.close()
                try? viewStore.flush()
                AppPreferences.experimentalZIPBrowsingEnabled = previousBrowsing
                openedArchives.forEach { ArchiveWorkspace.shared.discard(archive: $0) }
                try? fm.removeItem(at: root)
                completion()
            }
            do {
                print("== letting a ZIP's private copy go ==")
                AppPreferences.experimentalZIPBrowsingEnabled = true
                try await modelChecks(root: root)
                try await paneChecks(root: root, viewStore: viewStore, window: &window, openedArchives: &openedArchives)
            } catch {
                check("unexpected error", false, "\(error)")
            }
        }
    }

    private static func archive(_ name: String, in root: URL, _ entries: [(name: String, contents: String)]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try SmokeFixtures.zip(entries).write(to: url)
        return url
    }

    @MainActor private static func prepare(_ archive: URL, in workspace: ArchiveWorkspace) async throws -> ArchiveBrowsingSession {
        try await withCheckedThrowingContinuation { continuation in
            workspace.prepare(archive: archive) { continuation.resume(with: $0) }
        }
    }

    /// The registry's own rules, on private workspaces.
    @MainActor private static func modelChecks(root: URL) async throws {
        let fm = FileManager.default
        let workspace = ArchiveWorkspace()
        workspace.evictionSchedule = .manual
        defer { workspace.shutdownAll() }
        let owner = NSObject(), other = NSObject()

        // The last displayer leaving lets it go; a second one keeps it.
        let first = try archive("first.zip", in: root, [("d/a.txt", "a")])
        let session = try await prepare(first, in: workspace)
        workspace.setDisplayed(first.appendingPathComponent("d"), by: owner)
        workspace.setDisplayed(first, by: other)
        workspace.runEvictionsForTesting()
        check("a ZIP a pane shows is kept", workspace.session(for: first) === session && !session.isClosed)
        workspace.setDisplayed(nil, by: owner)
        workspace.runEvictionsForTesting()
        check("it is kept while a second pane still shows it", workspace.session(for: first) === session,
              "\(workspace.retentionForTesting(first))")
        workspace.setDisplayed(root, by: other)
        workspace.runEvictionsForTesting()
        // Closed off the main thread: removing a large copy takes time.
        check("once no pane shows it, it leaves the registry at once", workspace.session(for: first) == nil)
        await waitUntil("the let-go session closes") { session.isClosed }
        await waitUntil("the let-go copy is removed", detail: { session.storageURL.path }) {
            !fm.fileExists(atPath: session.storageURL.path)
        }

        // A lease holds it.
        let leased = try archive("leased.zip", in: root, [("d/a.txt", "a")])
        let leasedSession = try await prepare(leased, in: workspace)
        let lease = workspace.lease([leased.appendingPathComponent("d/a.txt")])
        let second = workspace.lease([leased])
        workspace.runEvictionsForTesting()
        check("work holding a lease keeps it, though no pane shows it", workspace.session(for: leased) === leasedSession)
        lease.release()
        lease.release()
        await drainMainQueue()
        workspace.runEvictionsForTesting()
        check("releasing one lease twice does not release another", workspace.session(for: leased) === leasedSession
              && workspace.retentionForTesting(leased).leases == 1, "\(workspace.retentionForTesting(leased))")
        second.release()
        await drainMainQueue()
        workspace.runEvictionsForTesting()
        check("once every lease is released, it is let go", workspace.session(for: leased) == nil,
              "\(workspace.retentionForTesting(leased))")
        await waitUntil("the released session closes") { leasedSession.isClosed }

        // A hand-off copy outlives it.
        let handed = try archive("handed.zip", in: root, [("d/a.txt", "handed")])
        let handedSession = try await prepare(handed, in: workspace)
        try await SmokeFixtures.materialize(handedSession, ["d/a.txt"])
        let store = ArchiveHandoffStore(root: root)
        defer { store.removeAll() }
        let extracted = handedSession.rootURL.appendingPathComponent("d/a.txt")
        let copy = store.handOff(extracted, logical: handed.appendingPathComponent("d/a.txt"))
        check("a hand-off copy lives outside the ZIP's private copy, and says where it came from",
              copy.map { !$0.path.hasPrefix(handedSession.storageURL.resolvingSymlinksInPath().path) && !$0.path.hasPrefix(handedSession.storageURL.path) } == true
              && copy.flatMap(store.logicalURL(forHandOff:)) == handed.appendingPathComponent("d/a.txt")
              && store.handOff(extracted, logical: handed.appendingPathComponent("d/a.txt")) == copy)
        // A link is handed off as a copy of what it leads to, under its own
        // name; a copy an application changed is not handed out again.
        let links = root.appendingPathComponent("links", isDirectory: true)
        try fm.createDirectory(at: links, withIntermediateDirectories: true)
        try Data("target".utf8).write(to: links.appendingPathComponent("target.txt"))
        try fm.createSymbolicLink(atPath: links.appendingPathComponent("link.txt").path, withDestinationPath: "target.txt")
        let linkCopy = store.handOff(links.appendingPathComponent("link.txt"), logical: handed.appendingPathComponent("d/link.txt"))
        check("a link is handed off under its own name, as a copy of what it leads to",
              linkCopy?.lastPathComponent == "link.txt" && linkCopy.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "target"
              && linkCopy.map { (try? fm.destinationOfSymbolicLink(atPath: $0.path)) == nil } == true)
        if let copy { try Data("edited in another application".utf8).write(to: copy) }
        let again = store.handOff(extracted, logical: handed.appendingPathComponent("d/a.txt"))
        check("a copy an application changed is not handed out again; a fresh one is",
              again != copy && again.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "handed")
        workspace.runEvictionsForTesting()
        await waitUntil("the handed ZIP's copy is removed") { !fm.fileExists(atPath: handedSession.storageURL.path) }
        check("hand-off copies survive the ZIP's copy being let go",
              copy.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "edited in another application"
              && again.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "handed")
        // Owned like session storage: another launch's sweep spares it, and
        // quitting removes it.
        let handoffDirectory = store.directoryForTesting
        FileOperations.sweepOrphanedStorage(in: root)
        check("the launch sweep spares hand-off copies a live process owns",
              handoffDirectory.map { fm.fileExists(atPath: $0.path) } == true)
        let orphan = root.appendingPathComponent(ArchiveHandoffStore.prefix + "orphan", isDirectory: true)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: false)
        FileOperations.sweepOrphanedStorage(in: root)
        check("and removes hand-off copies a crashed run left", !fm.fileExists(atPath: orphan.path))
        store.removeAll()
        check("quitting removes the hand-off copies", handoffDirectory.map { !fm.fileExists(atPath: $0.path) } == true)

        // The real timer, including a session nobody ever showed.
        let timed = ArchiveWorkspace()
        timed.evictionSchedule = .after(0.2)
        defer { timed.shutdownAll() }
        let shown = try archive("timed.zip", in: root, [("d/a.txt", "a")])
        let never = try archive("never.zip", in: root, [("d/a.txt", "a")])
        let shownSession = try await prepare(shown, in: timed)
        // Shown straight away, before its own delay can end.
        timed.setDisplayed(shown, by: owner)
        let neverSession = try await prepare(never, in: timed)
        try await Task.sleep(nanoseconds: 600_000_000)
        check("on the timer, a ZIP shown is kept and one nobody showed is let go",
              timed.session(for: shown) === shownSession && timed.session(for: never) == nil)
        await waitUntil("the session nobody showed closes") { neverSession.isClosed }
        timed.setDisplayed(nil, by: owner)
        await waitUntil("the timer lets the last one go") { timed.session(for: shown) == nil }

        // Quit waits for a copy still being let go.
        let busy = try archive("busy.zip", in: root, [("b/a.txt", "a"), ("b/b.txt", "b")])
        let quitting = ArchiveWorkspace()
        quitting.evictionSchedule = .manual
        let busySession = try await prepare(busy, in: quitting)
        let gate = WorkerGate()
        SystemArchiveToolRunner.shared.beforeRunForTesting = { gate.arriveAndWait() }
        DispatchQueue.global().async { try? busySession.materializer.materialize(busySession.tree.prefetchPlan(for: "b")) }
        await waitUntil("the busy session's run is held") { gate.arrived }
        SystemArchiveToolRunner.shared.beforeRunForTesting = nil
        quitting.runEvictionsForTesting()
        var quitDone = false
        quitting.shutdownAll { quitDone = true }
        try await Task.sleep(nanoseconds: 300_000_000)
        check("a copy being let go while its tool runs outlives the run, and quit waits for it",
              quitting.session(for: busy) == nil && fm.fileExists(atPath: busySession.storageURL.path) && !quitDone)
        gate.release()
        await waitUntil("quit completes once the let-go copy has drained") { quitDone }
        check("then the copy is gone", !fm.fileExists(atPath: busySession.storageURL.path))
    }

    /// Through real panes on the shared workspace, whose eviction the suite
    /// runs by hand.
    @MainActor private static func paneChecks(root: URL, viewStore: DirectoryViewPropertiesStore,
                                              window: inout MainWindowController?, openedArchives: inout [URL]) async throws {
        let fm = FileManager.default
        let workspace = ArchiveWorkspace.shared
        let runner = SystemArchiveToolRunner.shared
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                      viewPropertiesStore: viewStore)
        window = wc
        wc.window?.makeKeyAndOrderFront(nil)
        await waitUntil("the fixture folder lists") { wc.browser.model.generation > 0 }
        let pane = wc.browser
        func show(_ url: URL, _ name: String) async {
            pane.navigate(to: url)
            await waitUntil("\(name) lists") {
                pane.currentURL?.standardizedFileURL == url.standardizedFileURL && !pane.isPreparingArchive
                    && pane.model.url?.standardizedFileURL == url.standardizedFileURL
            }
        }

        // Back into a ZIP that was let go mounts it again, even with ZIP
        // browsing turned off, since the location was browsable.
        let backZIP = try archive("back.zip", in: root, [("d/a.txt", "a")])
        openedArchives.append(backZIP)
        let folder = backZIP.appendingPathComponent("d")
        await show(folder, "the ZIP folder")
        guard let before = workspace.session(for: backZIP) else { check("a session exists", false); return }
        await show(root, "the ordinary folder")
        let entries = pane.history.entries.count
        workspace.runEvictionsForTesting()
        check("leaving a ZIP lets its copy go", workspace.session(for: backZIP) == nil)
        await waitUntil("the left ZIP's session closes") { before.isClosed }
        AppPreferences.experimentalZIPBrowsingEnabled = false
        pane.goBack()
        await waitUntil("Back mounts the ZIP again", detail: { "\(pane.model.items.map(\.name)) preparing=\(pane.isPreparingArchive)" }) {
            !pane.isPreparingArchive && pane.model.url?.standardizedFileURL == folder.standardizedFileURL
                && pane.model.items.map(\.name) == ["a.txt"]
        }
        AppPreferences.experimentalZIPBrowsingEnabled = true
        check("Back into a ZIP let go mounts it afresh, read-only, without changing history",
              workspace.session(for: backZIP).map { $0 !== before } == true && pane.isBrowsingArchive
              && !pane.canModifyCurrentLocation && pane.history.entries.count == entries && pane.canGoForward)

        // A failed open elsewhere keeps the ZIP on screen registered.
        let broken = root.appendingPathComponent("broken.zip")
        try Data("not a ZIP".utf8).write(to: broken)
        pane.navigate(to: broken)
        await waitUntil("the broken ZIP fails") { !pane.isPreparingArchive && pane.failedArchiveURL != nil }
        workspace.runEvictionsForTesting()
        check("a failed open elsewhere keeps the ZIP still on screen", workspace.session(for: backZIP) != nil
              && workspace.retentionForTesting(backZIP).displayers == 1, "\(workspace.retentionForTesting(backZIP))")

        // Reopen Closed Tab mounts a ZIP let go since the tab was closed.
        let tabZIP = try archive("tab.zip", in: root, [("d/a.txt", "a")])
        openedArchives.append(tabZIP)
        let tab = wc.tabs.newTab(at: tabZIP.appendingPathComponent("d"))
        await waitUntil("the new tab lists the ZIP") { tab.model.items.map(\.name) == ["a.txt"] && !tab.isPreparingArchive }
        let tabSession = workspace.session(for: tabZIP)
        _ = wc.tabs.closeCurrentTab()
        workspace.runEvictionsForTesting()
        check("closing the only tab showing a ZIP lets it go", workspace.session(for: tabZIP) == nil)
        await waitUntil("the closed tab's session closes") { tabSession?.isClosed == true }
        check("the tab can be reopened", wc.tabs.reopenClosedTab())
        let reopened = wc.browser
        await waitUntil("the reopened tab mounts the ZIP again") {
            !reopened.isPreparingArchive && workspace.session(for: tabZIP) != nil && reopened.model.items.map(\.name) == ["a.txt"]
        }
        check("a reopened tab browses its ZIP again, read-only", reopened.isBrowsingArchive && !reopened.canModifyCurrentLocation
              && workspace.retentionForTesting(tabZIP).displayers == 1)
        _ = wc.tabs.closeCurrentTab()

        // Forward during a remount from history cancels it, and the cursor
        // stays on the entry still on screen.
        let heldZIP = try archive("held.zip", in: root, [("d/a.txt", "a")])
        openedArchives.append(heldZIP)
        await show(heldZIP.appendingPathComponent("d"), "the held ZIP")
        await show(root, "the ordinary folder")
        workspace.runEvictionsForTesting()
        await waitUntil("the held ZIP is let go") { workspace.session(for: heldZIP) == nil }
        let onScreen = pane.history.index
        let cloneGate = WorkerGate()
        let savedClone = FileOperations.cloneArchive
        FileOperations.cloneArchive = { source, clone in cloneGate.arriveAndWait(); return savedClone(source, clone) }
        pane.goBack()
        await waitUntil("the remount reaches its clone") { cloneGate.arrived }
        let movedTo = pane.history.index
        pane.goForward()
        FileOperations.cloneArchive = savedClone
        cloneGate.release()
        check("Forward during a remount from history cancels it and leaves the cursor on the entry on screen",
              movedTo == onScreen - 1 && !pane.isPreparingArchive && pane.history.index == onScreen
              && pane.currentURL?.standardizedFileURL == root.standardizedFileURL,
              "moved \(movedTo) now \(pane.history.index) screen \(onScreen)")
        await waitUntil("the cancelled remount cleans up") { !workspace.hasPendingPreparation(for: heldZIP) }

        // Reopening a tab whose ZIP is still mounted only shows it again.
        let keepZIP = try archive("keep.zip", in: root, [("d/a.txt", "a"), ("d/b.txt", "b")])
        openedArchives.append(keepZIP)
        let keepTab = wc.tabs.newTab(at: keepZIP.appendingPathComponent("d"))
        await waitUntil("the keep tab lists") { keepTab.model.items.count == 2 && !keepTab.isPreparingArchive }
        keepTab.fileView.select(urls: [keepZIP.appendingPathComponent("d/b.txt")])
        let keepSession = workspace.session(for: keepZIP)
        _ = wc.tabs.closeCurrentTab()
        _ = wc.tabs.reopenClosedTab()
        let keptPane = wc.browser
        await drainMainQueue()
        check("a reopened tab whose ZIP is still mounted keeps its session, rows and selection",
              workspace.session(for: keepZIP) === keepSession && !keptPane.isPreparingArchive
              && keptPane.fileView.selectedItems.map(\.name) == ["b.txt"] && workspace.retentionForTesting(keepZIP).displayers == 1)
        _ = wc.tabs.closeCurrentTab()

        // A reopened tab whose ZIP was let go and then moved lists it as
        // missing rather than showing a closed session's rows.
        let movingZIP = try archive("moving.zip", in: root, [("d/a.txt", "a")])
        let movingTab = wc.tabs.newTab(at: movingZIP.appendingPathComponent("d"))
        await waitUntil("the moving tab lists") { movingTab.model.items.map(\.name) == ["a.txt"] && !movingTab.isPreparingArchive }
        _ = wc.tabs.closeCurrentTab()
        workspace.runEvictionsForTesting()
        await waitUntil("the moving ZIP is let go") { workspace.session(for: movingZIP) == nil }
        try fm.moveItem(at: movingZIP, to: root.appendingPathComponent("moved-away.zip"))
        _ = wc.tabs.reopenClosedTab()
        let movedPane = wc.browser
        await waitUntil("the reopened tab settles", detail: { "\(movedPane.model.items.map(\.name)) preparing=\(movedPane.isPreparingArchive)" }) {
            !movedPane.isPreparingArchive && movedPane.model.items.isEmpty
        }
        check("a reopened tab whose ZIP has moved shows no rows from the closed session", movedPane.model.items.isEmpty)
        _ = wc.tabs.closeCurrentTab()

        // An extracted folder dropped on the tab strip opens a tab inside the
        // ZIP, not in the hand-off copy.
        let dropZIP = try archive("drop.zip", in: root, [("Folder/x.txt", "x")])
        openedArchives.append(dropZIP)
        await show(dropZIP, "the drop ZIP")
        await waitUntil("the drop ZIP's rows arrive") { pane.model.items.map(\.name) == ["Folder"] }
        guard let dropSession = workspace.session(for: dropZIP) else { check("a session exists", false); return }
        try await SmokeFixtures.materialize(dropSession, ["Folder"])
        guard let folderItem = pane.model.items.first, let writer = ArchiveDragExport.writer(for: folderItem) else {
            check("the extracted folder can be dragged", false); return
        }
        let dragBoard = NSPasteboard(name: NSPasteboard.Name("tursora-tab-drop-\(UUID().uuidString)"))
        defer { dragBoard.releaseGlobally() }
        dragBoard.clearContents()
        dragBoard.writeObjects([writer])
        let tabsBefore = wc.tabs.count
        wc.tabs.filesDropped(dragBoard.fileURLs, onTabAt: nil, op: .copy)
        check("a folder dropped on the tab strip opens one tab", wc.tabs.count == tabsBefore + 1)
        wc.tabs.selectTab(at: wc.tabs.count - 1)
        let dropped = wc.browser
        await waitUntil("the dropped folder's tab lists") { dropped.model.items.map(\.name) == ["x.txt"] && !dropped.isPreparingArchive }
        check("an extracted ZIP folder dropped on the tab strip opens inside the ZIP, not in a hand-off copy",
              dropped.isBrowsingArchive && dropped.currentURL?.standardizedFileURL == dropZIP.appendingPathComponent("Folder").standardizedFileURL,
              "\(dropped.currentURL?.path ?? "nil")")
        _ = wc.tabs.closeCurrentTab()

        // Files handed out survive the ZIP's copy being let go.
        let handZIP = try archive("hand.zip", in: root, [("d/open.txt", "opened"), ("d/copy.txt", "copied")])
        openedArchives.append(handZIP)
        let handFolder = handZIP.appendingPathComponent("d")
        await show(handFolder, "the hand-off ZIP")
        await waitUntil("the hand-off ZIP's rows arrive") { pane.model.items.map(\.name).sorted() == ["copy.txt", "open.txt"] }
        var opened: [URL] = []
        pane.archiveFileOpener = { opened.append($0); return true }
        pane.fileView.select(urls: [handFolder.appendingPathComponent("open.txt")])
        pane.openSelection()
        await waitUntil("the file opens") { opened.count == 1 }
        pane.fileView.select(urls: [handFolder.appendingPathComponent("copy.txt")])
        pane.copy(nil)
        await waitUntil("the file is copied") { NSPasteboard.general.externalFileURLs.count == 1 }
        let copied = NSPasteboard.general.externalFileURLs.first
        guard let handSession = workspace.session(for: handZIP) else { check("a session exists", false); return }
        await show(root, "the ordinary folder")
        workspace.runEvictionsForTesting()
        await waitUntil("the hand-off ZIP's copy is removed") { !fm.fileExists(atPath: handSession.storageURL.path) }
        check("a file opened in another application, and one copied, survive the ZIP's copy being let go",
              opened.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "opened"
              && copied.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "copied")

        // A copy out that is still running holds its source.
        let copyZIP = try archive("copy.zip", in: root, [("Box/one.txt", "one"), ("Box/sub/two.txt", "two")])
        openedArchives.append(copyZIP)
        let destination = root.appendingPathComponent("copied-out", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        wc.tabs.toggleSplit()
        guard let other = wc.tabs.currentPage.inactive else { check("a split pane is open", false); return }
        let source = wc.browser
        other.navigate(to: destination)
        await waitUntil("the other pane shows the destination") { other.model.url?.standardizedFileURL == destination.standardizedFileURL }
        source.navigate(to: copyZIP)
        await waitUntil("the copy ZIP lists") { source.model.items.map(\.name) == ["Box"] && !source.isPreparingArchive }
        let gate = WorkerGate()
        runner.beforeRunForTesting = { gate.arriveAndWait() }
        source.fileView.select(urls: [copyZIP.appendingPathComponent("Box")])
        source.copyToOtherPane(nil)
        await waitUntil("the copy reaches the archive tool") { gate.arrived }
        let task = source.lastTransferTask
        source.navigate(to: root)
        await waitUntil("the source pane leaves the ZIP") { source.currentURL?.standardizedFileURL == root.standardizedFileURL }
        workspace.runEvictionsForTesting()
        check("a copy still reading from a ZIP keeps its copy, though no pane shows it",
              workspace.session(for: copyZIP) != nil && workspace.retentionForTesting(copyZIP).leases > 0)
        runner.beforeRunForTesting = nil
        gate.release()
        await waitUntil("the copy finishes") { task?.snapshot.isTerminal == true }
        await drainMainQueue()
        workspace.runEvictionsForTesting()
        check("the copy arrives whole, and afterwards the ZIP's copy is let go",
              (try? String(contentsOf: destination.appendingPathComponent("Box/sub/two.txt"), encoding: .utf8)) == "two"
              && workspace.session(for: copyZIP) == nil)
        wc.tabs.toggleSplit()
    }
}

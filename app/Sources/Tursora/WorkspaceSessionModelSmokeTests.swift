import Foundation

/// Independent document, validation and storage checks. No browser, updater,
/// defaults domain or production session file is involved.
enum WorkspaceSessionModelSmokeTests: SmokeSuite {
    static func run() {
        print("== workspace session model and storage ==")
        do {
            let fixture = try SmokeFixtures.temporaryDirectory("workspace-model")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try modelChecks(fixture)
            try decodingChecks(fixture)
            try storageChecks(fixture)
            try failureChecks(fixture)
            try saveLimitChecks(fixture)
        } catch { check("workspace session fixture completes", false, error.localizedDescription) }
    }

    private static func sample(_ fixture: URL) -> WorkspaceSessionState {
        let first = fixture.appendingPathComponent("not-created/work")
        let second = fixture.appendingPathComponent("not-mounted/Archive.zip/Nested")
        let search = SearchRequest(rootURL: first, scope: .currentFolder, name: "report", content: "budget",
                                   kind: .document, modifiedAfter: Date(timeIntervalSince1970: 1_700_000_000),
                                   modifiedBefore: Date(timeIntervalSince1970: 1_780_000_000))
        let split = WorkspaceTabState(panes: [.init(url: first, search: search), .init(url: second)],
                                      activePaneIndex: 1, customTitle: "Research", splitFraction: 0.37)
        return .init(windows: [
            .init(tabs: [.init(panes: [.init(url: fixture)]), split], selectedTabIndex: 1,
                  frame: .init(x: -1200, y: 70, width: 1100, height: 700), sidebarWidth: 230,
                  sidebarCollapsed: true),
            .init(tabs: [.init(panes: [.init(url: second)])], isMiniaturized: true)
        ], activeWindowIndex: 1)
    }

    private static func modelChecks(_ fixture: URL) throws {
        let original = sample(fixture)
        check("workspace model: a complete workspace survives normalization", original.sanitized() == original)
        let roundTrip = try JSONDecoder().decode(WorkspaceSessionState.self, from: JSONEncoder().encode(original))
        check("workspace model: Codable retains windows, order, selected tab and active pane", roundTrip == original)
        check("workspace model: search conditions survive without persisting results",
              roundTrip.windows[0].tabs[1].panes[0].search == original.windows[0].tabs[1].panes[0].search)
        let encoded = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        check("workspace model: transient history, tasks and filters are absent",
              ["history", "nameFilter", "terminal", "transfer", "undo"].allSatisfy { !encoded.contains("\"\($0)\"") })
        check("workspace model: unavailable paths and logical ZIP members are retained",
              !FileManager.default.fileExists(atPath: original.windows[0].tabs[1].panes[1].url.path)
              && roundTrip.windows[0].tabs[1].panes[1].url == original.windows[0].tabs[1].panes[1].url)

        let invalidURLs = ["https://example.com/folder", "file://other-host/folder", "file:relative",
                           "file:///folder%00name", "file://user@localhost/folder"].compactMap(URL.init(string:))
        check("workspace model: nonlocal, relative, NUL and credential-bearing URLs are rejected",
              invalidURLs.count == 5 && invalidURLs.allSatisfy { WorkspacePaneState(url: $0).sanitized() == nil })
        let relative = URL(string: "child", relativeTo: fixture)!
        check("workspace model: a URL depending on a base cannot become a saved absolute location",
              WorkspacePaneState.localURL(relative) == nil)
        let decorated = URL(string: "file://localhost/private/tmp/Folder%20A/../Folder%20B?view=icons#row")!
        check("workspace model: local URL decorations and dot components do not alter navigation identity",
              WorkspacePaneState.localURL(decorated) == URL(fileURLWithPath: "/private/tmp/Folder B"))
        let link = fixture.appendingPathComponent("logical-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.appendingPathComponent("missing-target"))
        check("workspace model: symlink paths are retained without resolving an unavailable target",
              WorkspacePaneState.localURL(link) == link.standardizedFileURL)

        var badSearch = original.windows[0].tabs[1].panes[0]
        badSearch.search?.rootURL = URL(string: "https://example.com")!
        check("workspace model: an invalid search is discarded independently of its valid pane",
              badSearch.sanitized()?.url == badSearch.url && badSearch.sanitized()?.search == nil)
        badSearch = original.windows[0].tabs[1].panes[0]
        let endDate = badSearch.search?.modifiedBefore
        badSearch.search?.modifiedAfter = endDate
        check("workspace model: inverted or empty search date intervals are discarded", badSearch.sanitized()?.search == nil)
        badSearch.search?.modifiedAfter = Date(timeIntervalSinceReferenceDate: .nan)
        check("workspace model: nonfinite search dates cannot prevent JSON encoding", badSearch.sanitized()?.search == nil)
        badSearch = original.windows[0].tabs[1].panes[0]
        badSearch.search?.name = String(repeating: "x", count: 8_193)
        check("workspace model: unbounded search text is not restored", badSearch.sanitized()?.search == nil)

        var broken = original
        broken.activeWindowIndex = Int.max
        broken.windows[0].selectedTabIndex = -100
        broken.windows[0].sidebarWidth = .infinity
        broken.windows[0].frame?.x = .nan
        broken.windows[0].tabs[1].activePaneIndex = Int.max
        broken.windows[0].tabs[1].splitFraction = .nan
        broken.windows[0].tabs[1].customTitle = " \n "
        let clean = broken.sanitized()
        check("workspace model: indexes clamp independently to existing entries",
              clean.activeWindowIndex == 1 && clean.windows[0].selectedTabIndex == 0
              && clean.windows[0].tabs[1].activePaneIndex == 1)
        check("workspace model: nonfinite geometry falls back before encoding",
              clean.windows[0].frame == nil && clean.windows[0].sidebarWidth == 190
              && clean.windows[0].tabs[1].splitFraction == 0.5 && (try? JSONEncoder().encode(clean)) != nil)
        check("workspace model: blank custom titles restore the automatic title", clean.windows[0].tabs[1].customTitle == nil)
        var geometry = original.windows[0]
        geometry.sidebarWidth = 2_000
        geometry.frame = .init(x: 40, y: -100, width: 100_000, height: 100_000)
        geometry.tabs[1].splitFraction = -2
        geometry.tabs[1].customTitle = String(repeating: "名", count: 600)
        let limited = geometry.sanitized()!
        check("workspace model: geometry and title bounds constrain malformed but finite values",
              limited.sidebarWidth == 600 && limited.frame?.width == 16_384 && limited.frame?.height == 16_384
              && limited.tabs[1].splitFraction == 0.01 && limited.tabs[1].customTitle?.count == 512)
        check("workspace model: nonpositive sizes and extreme origins do not yield a window frame",
              WorkspaceWindowFrame(x: 0, y: 0, width: 0, height: 700).sanitized == nil
              && WorkspaceWindowFrame(x: 1_000_001, y: 0, width: 800, height: 700).sanitized == nil)

        let pane = WorkspacePaneState(url: fixture)
        let overflowTab = WorkspaceTabState(panes: Array(repeating: pane, count: 3), activePaneIndex: 2)
        let overflowWindow = WorkspaceWindowState(tabs: Array(repeating: overflowTab, count: 40), selectedTabIndex: 39)
        let overflow = WorkspaceSessionState(windows: Array(repeating: overflowWindow, count: 20), activeWindowIndex: 19).sanitized()
        check("workspace model: restoration is bounded to sixteen windows, thirty-two tabs and two panes",
              overflow.windows.count == 16 && overflow.windows.allSatisfy {
                  $0.tabs.count == 32 && $0.tabs.allSatisfy { $0.panes.count == 2 }
              })
        check("workspace model: selected entries outside the safety limits select the last retained entry",
              overflow.activeWindowIndex == 15 && overflow.windows[0].selectedTabIndex == 31
              && overflow.windows[0].tabs[0].activePaneIndex == 1)
        let invalid = WorkspacePaneState(url: URL(string: "https://example.com")!)
        let mixed = WorkspaceSessionState(windows: [
            .init(tabs: [.init(panes: [invalid])]),
            .init(tabs: [.init(panes: [invalid]), .init(panes: [invalid, pane], activePaneIndex: 1)], selectedTabIndex: 1)
        ], activeWindowIndex: 1).sanitized()
        check("workspace model: dropping invalid siblings preserves the selected surviving identity",
              mixed.windows.count == 1 && mixed.activeWindowIndex == 0 && mixed.windows[0].tabs.count == 1
              && mixed.windows[0].selectedTabIndex == 0 && mixed.windows[0].tabs[0].panes == [pane]
              && mixed.windows[0].tabs[0].activePaneIndex == 0)
    }

    private static func decodingChecks(_ fixture: URL) throws {
        let a: [String: Any] = ["url": fixture.appendingPathComponent("a").absoluteString]
        let b: [String: Any] = ["url": fixture.appendingPathComponent("b").absoluteString]
        let value: [String: Any] = ["version": 1, "activeWindowIndex": 2, "windows": [
            "broken window",
            ["tabs": [NSNull(), ["panes": [a]]], "selectedTabIndex": 1],
            ["tabs": [["panes": [false, a, b], "activePaneIndex": 2]], "sidebarWidth": "bad",
             "sidebarCollapsed": true, "frame": ["x": 20, "width": 500]],
            ["tabs": [["panes": [["url": "https://example.com"]]]]]
        ]]
        let decoded = try JSONDecoder().decode(WorkspaceSessionState.self, from: JSONSerialization.data(withJSONObject: value))
        check("workspace decoding: malformed windows, tabs and panes fail independently",
              decoded.windows.count == 2 && decoded.windows[0].tabs.count == 1 && decoded.windows[1].tabs[0].panes.count == 2)
        check("workspace decoding: lossy arrays retain original selections after corrupt siblings",
              decoded.activeWindowIndex == 1 && decoded.windows[0].selectedTabIndex == 0
              && decoded.windows[1].tabs[0].activePaneIndex == 1)
        check("workspace decoding: optional malformed fields keep independent valid fields and defaults",
              decoded.windows[1].sidebarWidth == 190 && decoded.windows[1].sidebarCollapsed
              && decoded.windows[1].frame == nil && !decoded.windows[1].isMiniaturized)
        let pane: [String: Any] = ["url": fixture.absoluteString, "search": ["kind": "future-kind"]]
        let tab: [String: Any] = ["panes": [pane], "splitFraction": "bad", "customTitle": 17, "activePaneIndex": "bad"]
        let tabState = try JSONDecoder().decode(WorkspaceTabState.self, from: JSONSerialization.data(withJSONObject: tab))
        check("workspace decoding: invalid search conditions leave an ordinary pane at its stored URL",
              tabState.panes.first?.url == fixture && tabState.panes.first?.search == nil)
        check("workspace decoding: malformed tab presentation fields use usable defaults",
              tabState.activePaneIndex == 0 && tabState.splitFraction == 0.5 && tabState.customTitle == nil)
        check("workspace decoding: an explicitly empty workspace is a valid closed-window session",
              try JSONDecoder().decode(WorkspaceSessionState.self, from: Data("{\"version\":1,\"windows\":[]}".utf8)) == .init())
        check("workspace decoding: an entirely malformed nonempty workspace is not mistaken for a valid empty session",
              (try? JSONDecoder().decode(WorkspaceSessionState.self,
                                        from: Data("{\"version\":1,\"windows\":[false,{\"tabs\":[]}]}".utf8))) == nil)
    }

    private static func storageChecks(_ fixture: URL) throws {
        let original = sample(fixture)
        let memory = WorkspaceSessionStore(fileURL: nil)
        check("workspace storage: memory store starts missing without production I/O", memory.fileURL == nil && memory.load() == .missing)
        check("workspace storage: memory save and reload retain the complete state", memory.save(original) && memory.load() == .loaded(original))
        check("workspace storage: memory clear is immediate and flush has no pending work",
              memory.clear() && memory.flush() && memory.load() == .missing)
        check("workspace storage: the shared smoke store is isolated from the user's workspace",
              SmokeTest.isRequested && WorkspaceSessionStore.shared.fileURL == nil)

        let file = fixture.appendingPathComponent("store/WorkspaceSession.json")
        let store = WorkspaceSessionStore(fileURL: file)
        check("workspace storage: reading and flushing a missing store do not create directories",
              store.load() == .missing && store.flush() && !FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        check("workspace storage: saving creates a private atomic document", store.save(original) && store.lastError == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        check("workspace storage: saved path and search data are owner-readable only", permissions?.intValue == 0o600)
        check("workspace storage: a newly created service reads the complete prior workspace",
              WorkspaceSessionStore(fileURL: file).load() == .loaded(original))
        var updated = original
        updated.activeWindowIndex = 0
        updated.windows[0].tabs[1].customTitle = "Changed workspace"
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        check("workspace storage: replacing a snapshot keeps the latest complete document", store.save(updated) && store.flush())
        let replacedMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        check("workspace storage: replacement also repairs overly broad file permissions",
              replacedMode?.intValue == 0o600 && WorkspaceSessionStore(fileURL: file).load() == .loaded(updated))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        check("workspace storage: atomic publication leaves no temporary document", siblings == ["WorkspaceSession.json"])
        check("workspace storage: clearing removes only the saved document and is repeatable",
              store.clear() && store.load() == .missing && store.clear())
    }

    private static func failureChecks(_ fixture: URL) throws {
        let original = sample(fixture)
        let damaged: [(String, WorkspaceSessionLoadResult)] = [
            ("not JSON", .corrupt), ("{}", .corrupt), ("{\"version\":1,\"windows\":{}}", .corrupt),
            ("{\"version\":999,\"futureStructure\":true}", .unsupported(version: 999)),
            ("{\"version\":0}", .unsupported(version: 0))
        ]
        for (index, item) in damaged.enumerated() {
            let file = fixture.appendingPathComponent("damaged-\(index).json")
            let bytes = Data(item.0.utf8)
            try bytes.write(to: file)
            let store = WorkspaceSessionStore(fileURL: file)
            check("workspace storage: damaged document \(index) reports its precise load state",
                  store.load() == item.1 && store.lastError != nil)
            check("workspace storage: load and flush preserve damaged document \(index) byte for byte",
                  store.flush() && (try? Data(contentsOf: file)) == bytes)
            check("workspace storage: explicit replacement can recover damaged document \(index)",
                  store.save(original) && store.lastError == nil && store.load() == .loaded(original))
        }
        let large = fixture.appendingPathComponent("too-large.json")
        let largeBytes = Data(repeating: 32, count: WorkspaceSessionStore.maximumFileSize + 1)
        try largeBytes.write(to: large)
        let largeStore = WorkspaceSessionStore(fileURL: large)
        check("workspace storage: oversized input is rejected without mutation",
              largeStore.load() == .corrupt && largeStore.flush() && (try? Data(contentsOf: large))?.count == largeBytes.count)

        let blocker = fixture.appendingPathComponent("parent-is-file")
        try Data("preserve parent".utf8).write(to: blocker)
        let retryStore = WorkspaceSessionStore(fileURL: blocker.appendingPathComponent("WorkspaceSession.json"))
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(forName: WorkspaceSessionStore.didChange,
                                                             object: retryStore, queue: nil) { _ in counter.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        check("workspace storage: a failed write reports an error without damaging its parent",
              !retryStore.save(original) && retryStore.lastError != nil && (try? Data(contentsOf: blocker)) == Data("preserve parent".utf8))
        check("workspace storage: a failed mutation notifies settings", counter.value == 1)
        try FileManager.default.removeItem(at: blocker)
        check("workspace storage: flush retries the pending complete snapshot after recovery",
              retryStore.flush() && retryStore.lastError == nil && retryStore.load() == .loaded(original))
        check("workspace storage: recovery notifies settings once", counter.value == 2)

        let occupied = fixture.appendingPathComponent("session-is-directory")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let occupant = occupied.appendingPathComponent("preserve.txt")
        try Data("not a session".utf8).write(to: occupant)
        let occupiedStore = WorkspaceSessionStore(fileURL: occupied)
        if case .readError = occupiedStore.load() { check("workspace storage: a directory at the file path reports a read error", true) }
        else { check("workspace storage: a directory at the file path reports a read error", false) }
        check("workspace storage: atomic write failure leaves the prior directory intact",
              !occupiedStore.save(original) && (try? Data(contentsOf: occupant)) == Data("not a session".utf8))
        check("workspace storage: clear never recursively deletes a directory at the session path",
              !occupiedStore.clear() && (try? Data(contentsOf: occupant)) == Data("not a session".utf8))
        let leftover = try FileManager.default.contentsOfDirectory(atPath: fixture.path)
        check("workspace storage: failed publication removes its private temporary file",
              !leftover.contains { $0.hasPrefix(".workspace-session-") })
        let originalBytes = try Data(contentsOf: retryStore.fileURL!)
        check("workspace storage: saving an unsupported version cannot overwrite a valid document",
              !retryStore.save(.init(version: 999)) && (try? Data(contentsOf: retryStore.fileURL!)) == originalBytes)
    }

    private static func saveLimitChecks(_ fixture: URL) throws {
        let original = sample(fixture)
        let file = fixture.appendingPathComponent("write-limits/session.json")
        let store = WorkspaceSessionStore(fileURL: file)
        check("workspace storage: write-limit fixture saves the original workspace", store.save(original))
        let originalBytes = try Data(contentsOf: file)
        let tooManyWindows = WorkspaceSessionState(windows: Array(repeating: original.windows[0],
                                                                  count: WorkspaceSessionState.maximumWindows + 1))
        check("workspace storage: a live workspace over the window limit is rejected with an actionable error",
              !store.save(tooManyWindows) && store.lastError?.contains("16 windows") == true
              && store.lastError?.contains("Close some windows") == true)
        check("workspace storage: rejecting excess windows preserves the previous document even after flush",
              store.flush() && (try? Data(contentsOf: file)) == originalBytes)
        let tooManyTabs = WorkspaceSessionState(windows: [.init(tabs: Array(repeating: original.windows[0].tabs[0],
                                                                           count: WorkspaceSessionState.maximumTabsPerWindow + 1))])
        check("workspace storage: a live window over the tab limit is rejected with an actionable error",
              !store.save(tooManyTabs) && store.lastError?.contains("32 tabs") == true
              && store.lastError?.contains("Close some tabs") == true)
        check("workspace storage: rejecting excess tabs preserves the previous document even after flush",
              store.flush() && (try? Data(contentsOf: file)) == originalBytes)
        var recovered = original
        recovered.windows[0].tabs[0].customTitle = "Within the limit again"
        check("workspace storage: returning within the limits saves the complete workspace and clears the error",
              store.save(recovered) && store.lastError == nil && store.load() == .loaded(recovered))

        let blocker = fixture.appendingPathComponent("write-limit-blocker")
        try Data("block creation".utf8).write(to: blocker)
        let pendingFile = blocker.appendingPathComponent("session.json")
        let pendingStore = WorkspaceSessionStore(fileURL: pendingFile)
        check("workspace storage: a prior failed write is retained for the pending-write fixture", !pendingStore.save(original))
        try FileManager.default.removeItem(at: blocker)
        check("workspace storage: an over-limit request supersedes the prior failed snapshot",
              !pendingStore.save(tooManyWindows) && pendingStore.flush()
              && !FileManager.default.fileExists(atPath: pendingFile.path))
        check("workspace storage: a valid request recovers after rejecting a newer over-limit snapshot",
              pendingStore.save(recovered) && pendingStore.lastError == nil
              && pendingStore.load() == .loaded(recovered))
    }

    private final class Counter { var value = 0 }
}

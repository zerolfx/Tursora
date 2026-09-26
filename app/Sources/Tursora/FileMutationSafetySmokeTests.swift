import AppKit

/// Rename must never replace a sibling, and a failed item in a Trash batch
/// must not erase the undo/Put Back history of items that already succeeded.
enum FileMutationSafetySmokeTests: SmokeSuite {
    static let checkPrefix = "mutation safety: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            do {
                let fixture = try SmokeFixtures.temporaryDirectory("mutation-safety")
                defer { try? FileManager.default.removeItem(at: fixture) }
                print("== file mutation safety ==")
                try renameModel(in: fixture)
                try trashModel(in: fixture)
                try infoRename(in: fixture)
                for mode in ViewMode.allCases { try await paneFlow(mode: mode, in: fixture) }
                completion()
            } catch {
                check("fixtures complete", false, error.localizedDescription)
            }
        }
    }

    private static func contents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private static func names(_ url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }
    private static func write(_ value: String, to url: URL) throws { try Data(value.utf8).write(to: url) }

    private static func hasTrashOrigin(_ original: URL, trashed: URL) -> Bool {
        // The journal deliberately resolves /var to /private/var, including
        // after a source has moved away. Compare against that stored identity.
        TrashOrigins.shared.origin(ofTrashed: trashed)?.path == TrashLocation.canonicalPath(original)
    }

    private static func trashOriginDetails(_ originals: [URL], trashed: [URL]) -> String {
        zip(originals, trashed).map { original, destination in
            "\(destination.lastPathComponent): expected \(TrashLocation.canonicalPath(original)), recorded \(TrashOrigins.shared.origin(ofTrashed: destination)?.path ?? "nil")"
        }.joined(separator: "; ")
    }

    private static func renameModel(in fixture: URL) throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("rename-model")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        let occupied = root.appendingPathComponent("occupied.txt")
        try write("source bytes", to: source)
        try write("occupied bytes", to: occupied)
        do { _ = try FileOperations.rename(source, to: occupied.lastPathComponent); check("occupied file is refused", false) }
        catch { check("occupied file is refused", true) }
        check("refused rename preserves both files", contents(source) == "source bytes" && contents(occupied) == "occupied bytes")

        let dangling = root.appendingPathComponent("dangling.txt")
        try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: "absent.txt")
        do { _ = try FileOperations.rename(source, to: dangling.lastPathComponent); check("dangling destination is refused", false) }
        catch { check("dangling destination is refused", true) }
        check("refused rename preserves a dangling link",
              (try? fm.destinationOfSymbolicLink(atPath: dangling.path)) == "absent.txt" && contents(source) == "source bytes")

        for invalid in ["", ".", "..", "nested/file", "name:part", "name\0suffix"] {
            do { _ = try FileOperations.rename(source, to: invalid); check("invalid name is refused", false, invalid) }
            catch { check("invalid name is refused", contents(source) == "source bytes") }
        }
        let renamed = try FileOperations.rename(source, to: "SOURCE.txt")
        check("case-only rename uses the requested spelling", names(root).contains("SOURCE.txt") && !names(root).contains("source.txt"))
        check("case-only rename keeps bytes", contents(renamed) == "source bytes")
        _ = try FileOperations.rename(renamed, to: source.lastPathComponent)
        check("case-only rename reverses", names(root).contains("source.txt") && !names(root).contains("SOURCE.txt"))

        let link = root.appendingPathComponent("source-link.txt")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: source.lastPathComponent)
        let movedLink = try FileOperations.rename(link, to: "renamed-link.txt")
        check("renaming a link leaves its target untouched",
              (try? fm.destinationOfSymbolicLink(atPath: movedLink.path)) == source.lastPathComponent
                  && contents(source) == "source bytes" && !FileOperations.itemExists(link))
    }

    private static func trashModel(in fixture: URL) throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("trash-model")
        let trash = root.appendingPathComponent("Trash")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let previousTrash = TrashLocation.userTrashOverride
        TrashLocation.userTrashOverride = trash
        defer { TrashLocation.userTrashOverride = previousTrash }
        let first = root.appendingPathComponent("first.txt")
        let missing = root.appendingPathComponent("missing.txt")
        let last = root.appendingPathComponent("last.txt")
        try write("first", to: first)
        try write("last", to: last)
        let result = FileOperations.trash([first, missing, last])
        check("partial trash returns every successful pair",
              result.moved.map(\.original) == [first, last]
                  && result.moved.map(\.trashed.lastPathComponent) == ["first.txt", "last.txt"])
        check("partial trash returns the failing source", result.failures.count == 1 && result.failures.first?.url == missing)
        check("trash continues after the failure",
              contents(trash.appendingPathComponent("first.txt")) == "first"
                  && contents(trash.appendingPathComponent("last.txt")) == "last"
                  && !FileOperations.itemExists(first) && !FileOperations.itemExists(last))
    }

    @MainActor private static func infoRename(in fixture: URL) throws {
        let root = fixture.appendingPathComponent("info")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        let occupied = root.appendingPathComponent("occupied.txt")
        let renamed = root.appendingPathComponent("renamed.txt")
        try write("info source", to: source)
        try write("info occupied", to: occupied)
        let info = InfoWindowController(mode: .item, urls: [source])
        defer { info.close() }
        info.commitRename(occupied.lastPathComponent)
        check("Get Info refuses a conflicting name",
              contents(source) == "info source" && contents(occupied) == "info occupied"
                  && info.nameFieldValue == source.lastPathComponent)
        info.commitRename(renamed.lastPathComponent)
        guard let undo = info.window?.undoManager else { check("Get Info owns undo", false); return }
        check("Get Info accepts an available name", contents(renamed) == "info source" && undo.canUndo)
        try write("new source", to: source)
        undo.undo()
        check("Get Info undo preserves a newly occupied original name",
              contents(source) == "new source" && contents(renamed) == "info source")
    }

    @MainActor private static func paneFlow(mode: ViewMode, in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("pane-\(mode)")
        let origin = root.appendingPathComponent("origin")
        let trash = root.appendingPathComponent("Trash")
        for url in [origin, trash] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let source = origin.appendingPathComponent("source.txt")
        let occupied = origin.appendingPathComponent("occupied.txt")
        let renamed = origin.appendingPathComponent("renamed.txt")
        let trashSources = ["a-trash.txt", "b-trash.txt", "c-trash.txt"].map { origin.appendingPathComponent($0) }
        try write("source bytes", to: source)
        try write("occupied bytes", to: occupied)
        for url in trashSources { try write(url.lastPathComponent, to: url) }
        let previousTrash = TrashLocation.userTrashOverride
        TrashLocation.userTrashOverride = trash
        defer { TrashLocation.userTrashOverride = previousTrash }
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: origin,
                                      viewPropertiesStore: store)
        defer { wc.close(); try? store.flush() }
        wc.window?.setContentSize(NSSize(width: 1300, height: 700))
        wc.window?.makeKeyAndOrderFront(nil)
        let browser = wc.browser
        await waitUntil("\(mode) initial listing") { browser.model.items.count == 5 }
        browser.setViewMode(mode)
        let peer = wc.tabs.currentPage.split(with: origin)
        await waitUntil("\(mode) peer listing") { peer.model.items.count == 5 }
        let background = wc.tabs.newTab(at: origin, activate: false)
        await waitUntil("\(mode) background listing") { background.model.items.count == 5 }
        wc.tabs.currentPage.activate(browser)
        browser.nameFilter = "*.txt"
        browser.setGroupKey(.kind)
        guard let undo = wc.window?.undoManager else { check("\(mode) window owns undo", false); return }
        undo.removeAllActions()

        inlineRename(source, to: occupied.lastPathComponent, in: browser, context: "\(mode) conflict")
        check("\(mode) inline conflict preserves both files", contents(source) == "source bytes" && contents(occupied) == "occupied bytes")
        check("\(mode) failed rename creates no undo action", !undo.canUndo)
        await listed(source, in: browser)
        inlineRename(source, to: renamed.lastPathComponent, in: browser, context: "\(mode) rename")
        await listed(renamed, in: browser)
        check("\(mode) successful rename registers Undo", contents(renamed) == "source bytes" && undo.undoActionName == "Rename")
        try write("new original", to: source)
        undo.undo()
        check("\(mode) Undo refuses an occupied original", contents(source) == "new original" && contents(renamed) == "source bytes")
        try fm.removeItem(at: source)
        _ = try FileOperations.rename(renamed, to: source.lastPathComponent)
        browser.reload()
        await listed(source, in: browser)
        undo.removeAllActions()

        inlineRename(source, to: "SOURCE.txt", in: browser, context: "\(mode) case-only")
        check("\(mode) inline case-only spelling is applied", names(origin).contains("SOURCE.txt") && !names(origin).contains("source.txt"))
        undo.undo()
        check("\(mode) case-only Undo works", names(origin).contains("source.txt") && !names(origin).contains("SOURCE.txt"))
        undo.redo()
        check("\(mode) case-only Redo works", names(origin).contains("SOURCE.txt") && !names(origin).contains("source.txt"))
        undo.undo()
        await listed(source, in: browser)
        undo.removeAllActions()

        inlineRename(source, to: renamed.lastPathComponent, in: browser, context: "\(mode) redo setup")
        undo.undo()
        try write("new redo target", to: renamed)
        undo.redo()
        check("\(mode) Redo refuses an occupied destination", contents(source) == "source bytes" && contents(renamed) == "new redo target")
        try fm.removeItem(at: renamed)
        undo.removeAllActions()
        browser.reload()
        await waitUntil("\(mode) listing settled for Trash") {
            Set(browser.model.items.map(\.name)) == Set(["source.txt", "occupied.txt"] + trashSources.map(\.lastPathComponent))
        }
        check("\(mode) rename preserves filter, groups and view", browser.nameFilter == "*.txt" && browser.groupKey == .kind && browser.viewMode == mode)

        // Remove one selected file without yielding to the watcher: it models
        // a stale selection when another process removes a file just before Trash.
        browser.fileView.select(urls: trashSources)
        check("\(mode) three selected Trash sources", browser.fileView.selectedItems.count == 3)
        try fm.removeItem(at: trashSources[1])
        browser.moveToTrash(nil)
        let successful = [trashSources[0], trashSources[2]]
        let destinations = successful.map { trash.appendingPathComponent($0.lastPathComponent) }
        check("\(mode) partial Trash moved both available sources",
              zip(successful, destinations).allSatisfy { !FileOperations.itemExists($0) && contents($1) == $0.lastPathComponent })
        let originsRecorded = zip(successful, destinations).allSatisfy { hasTrashOrigin($0, trashed: $1) }
        check("\(mode) partial Trash recorded Put Back for both successes", originsRecorded,
              originsRecorded ? "" : trashOriginDetails(successful, trashed: destinations))
        check("\(mode) partial Trash registered Undo", undo.canUndo && undo.undoActionName == "Move to Trash")
        await waitUntil("\(mode) peer sees partial Trash") { peer.model.items.allSatisfy { !$0.name.hasSuffix("-trash.txt") } }
        await waitUntil("\(mode) background tab sees partial Trash") { background.model.items.allSatisfy { !$0.name.hasSuffix("-trash.txt") } }
        check("\(mode) partial Trash refreshes peers", peer.model.items.count == 2 && background.model.items.count == 2)
        undo.undo()
        check("\(mode) partial Trash Undo restores both successes", successful.allSatisfy { contents($0) == $0.lastPathComponent })
        check("\(mode) Trash Undo removes stale origins", destinations.allSatisfy { TrashOrigins.shared.origin(ofTrashed: $0) == nil })
        undo.redo()
        let redoOriginsRecorded = zip(successful, destinations).allSatisfy {
            contents($1) == $0.lastPathComponent && hasTrashOrigin($0, trashed: $1)
        }
        check("\(mode) partial Trash Redo restores Put Back entries", redoOriginsRecorded,
              redoOriginsRecorded ? "" : trashOriginDetails(successful, trashed: destinations))
        let beforeTrashNavigation = browser.model.generation
        let expectedTrashPaths = Set(destinations.map(TrashLocation.canonicalPath))
        browser.navigate(to: trash)
        // The old origin listing also has two rows. currentURL changes before
        // loading finishes, so neither the location nor the count proves that
        // the Trash rows are ready to select.
        await waitUntil("\(mode) Trash listing", detail: {
            "generation \(browser.model.generation), rows \(browser.model.items.map(\.url.path))"
        }) {
            browser.model.generation > beforeTrashNavigation && browser.isBrowsingTrash
                && Set(browser.model.items.map { TrashLocation.canonicalPath($0.url) }) == expectedTrashPaths
        }
        browser.fileView.select(urls: browser.model.items.map(\.url))
        let putBackURLs = browser.fileView.selectedItems.map(\.url)
        let selectedTrashPaths = Set(putBackURLs.map(TrashLocation.canonicalPath))
        check("\(mode) selects both actual Trash rows", selectedTrashPaths == expectedTrashPaths,
              selectedTrashPaths == expectedTrashPaths ? "" : "selected \(putBackURLs.map(\.path)), expected \(destinations.map(\.path))")
        check("\(mode) partial successes enable Put Back", browser.putBackEnablement(for: putBackURLs).enabled)
        browser.putBackSelection(nil)
        let restored = successful.allSatisfy { contents($0) == $0.lastPathComponent }
        check("\(mode) Put Back restores the partial batch", restored,
              restored ? "" : successful.map { "\($0.path): \(contents($0) ?? "missing")" }.joined(separator: "; "))
        check("\(mode) unrelated rename destination survives Trash", contents(occupied) == "occupied bytes")

        // Undo belongs to the surviving window even after the originating
        // pane's view has been detached; the inverse must use that manager.
        browser.navigate(to: origin)
        await listed(source, in: browser)
        undo.removeAllActions()
        inlineRename(source, to: renamed.lastPathComponent, in: browser, context: "\(mode) closing-tab rename")
        guard let sourceTab = wc.tabs.pages.firstIndex(where: { page in page.panes.contains { $0 === browser } }) else {
            check("\(mode) originating tab exists", false); return
        }
        check("\(mode) closes the originating tab with another tab surviving", wc.tabs.closeTab(at: sourceTab))
        check("\(mode) renamed pane is detached", browser.view.window == nil && wc.browser === background)
        undo.undo()
        check("\(mode) closed-tab rename Undo restores original bytes", contents(source) == "source bytes" && !FileOperations.itemExists(renamed))
        check("\(mode) closed-tab rename retains Redo in the same window", undo.canRedo && undo.redoActionName == "Rename")
        undo.redo()
        check("\(mode) closed-tab rename Redo restores renamed bytes", contents(renamed) == "source bytes" && !FileOperations.itemExists(source))
        undo.undo()
        check("\(mode) closed-tab rename remains reversible", contents(source) == "source bytes" && !FileOperations.itemExists(renamed))
    }

    @MainActor private static func listed(_ url: URL, in browser: BrowserViewController) async {
        await waitUntil("listing contains \(url.lastPathComponent)") { browser.model.items.contains { $0.name == url.lastPathComponent } }
    }

    @MainActor private static func inlineRename(_ url: URL, to name: String, in browser: BrowserViewController, context: String) {
        guard let item = browser.model.items.first(where: { $0.name == url.lastPathComponent }) else {
            check("\(context) source is listed", false); return
        }
        browser.fileView.select(urls: [item.url])
        browser.view.window?.makeFirstResponder(browser.focusView)
        browser.fileView.beginRename(item: item)
        guard browser.fileView.isRenaming, let editor = browser.view.window?.firstResponder as? NSTextView else {
            check("\(context) owns an inline editor", false); return
        }
        check("\(context) owns an inline editor", true)
        editor.string = name
        browser.fileView.endRename(commit: true)
    }
}

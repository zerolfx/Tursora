import AppKit

enum EverydayCommandsSmokeTests: SmokeSuite {
    static let checkPrefix = "everyday commands: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            do {
                let fixture = try SmokeFixtures.temporaryDirectory("everyday-commands").resolvingSymlinksInPath()
                let previousTrash = TrashLocation.userTrashOverride
                defer {
                    TrashLocation.userTrashOverride = previousTrash
                    try? FileManager.default.removeItem(at: fixture)
                }
                TrashLocation.userTrashOverride = fixture.appendingPathComponent("trash")
                menuBindings()
                try await folderJournal(in: fixture)
                for mode in ViewMode.allCases { try await paneFlow(mode, in: fixture) }
            } catch { fail("fixtures", error.localizedDescription) }
            completion()
        }
    }

    private static func menuBindings() {
        for (id, key, mods) in [("menu.moveItemsHere", "v", NSEvent.ModifierFlags([.command, .option])),
                                ("menu.deselectAllFiles", "a", [.command, .option]),
                                ("menu.newFolderWithSelection", "n", [.command, .control])] {
            check("\(id) has its default binding", ShortcutCatalog.action(id)?.defaultShortcut == .init(keyEquivalent: key, modifierFlags: mods))
        }
        check("unbound commands are customizable",
              ShortcutCatalog.action("menu.invertFileSelection") != nil && ShortcutCatalog.action("menu.showPackageContents") != nil)
    }

    @MainActor private static func folderJournal(in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("journal")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: source)
        let folder = try FileOperations.createFolder(in: root)
        let result: FileOperations.TransferResult = await withCheckedContinuation { continuation in
            FileOperations.transfer([source], to: folder, kind: .move, conflict: { _ in .init(resolution: .cancel) }) {
                continuation.resume(returning: $0)
            }
        }
        try require("folder fixture transfer succeeds", result.failures.isEmpty && result.moved.count == 1)
        let journal = try FileOperations.journalIncludingCreatedDirectory(folder, after: result.journal)
        let redo = try FileOperations.replay(journal)
        try require("one journal restores the source and removes the empty folder",
                    fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: folder.path))
        let undo = try FileOperations.replay(redo)
        try require("one journal re-creates the folder and moves its contents back",
                    !fm.fileExists(atPath: source.path) && (try? String(contentsOf: folder.appendingPathComponent(source.lastPathComponent))) == "original")
        let foreign = folder.appendingPathComponent("new-work.txt")
        try Data("keep".utf8).write(to: foreign)
        do {
            _ = try FileOperations.replay(undo)
            try require("foreign contents prevent folder undo", false)
        } catch let error as TransferReplayError {
            defer { for directory in error.recoveryDirectories { try? fm.removeItem(at: directory) } }
            try require("failed folder undo rolls back its earlier file moves",
                        !fm.fileExists(atPath: source.path)
                        && (try? String(contentsOf: folder.appendingPathComponent(source.lastPathComponent))) == "original"
                        && (try? String(contentsOf: foreign)) == "keep")
        }
    }

    @MainActor private static func paneFlow(_ mode: ViewMode, in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("pane-\(mode)")
        let other = fixture.appendingPathComponent("other-\(mode)")
        let package = root.appendingPathComponent("Demo.app")
        for directory in [root, other, package] { try fm.createDirectory(at: directory, withIntermediateDirectories: false) }
        for name in ["a.txt", "b.txt", "hidden.dat"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        try Data("package".utf8).write(to: package.appendingPathComponent("inside.txt"))
        let incoming = other.appendingPathComponent("incoming.txt")
        try Data("incoming".utf8).write(to: incoming)
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("\(mode)-views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                      viewPropertiesStore: store)
        defer {
            for page in wc.tabs.pages { for pane in page.panes {
                pane.cancelPendingRename(); pane.fileView.endRename(commit: false)
                pane.model.folderSizes.cancel(); pane.model.folderSizes.onUpdate = nil
                pane.model.onChange = nil; pane.model.onLoadSuccess = nil
                pane.onWorkspaceSessionChanged = nil
            } }
            wc.window?.undoManager?.removeAllActions()
            wc.close()
            try? store.flush()
        }
        wc.window?.setContentSize(NSSize(width: 1100, height: 700))
        wc.window?.makeKeyAndOrderFront(nil)
        let pane = wc.browser
        try await listed(pane, at: root, names: ["a.txt", "b.txt", "hidden.dat", "Demo.app"])
        pane.setViewMode(mode)
        let peer = wc.tabs.currentPage.split(with: other)
        try await listed(peer, at: other, names: ["incoming.txt"])
        wc.tabs.newTab(at: other)
        let background = wc.browser
        try await listed(background, at: other, names: ["incoming.txt"])
        wc.tabs.selectTab(at: 0)
        wc.tabs.currentPage.activate(pane)
        wc.window?.makeFirstResponder(pane.focusView)
        pane.nameFilter = "*.txt"
        pane.setGroupKey(.kind)
        pane.fileView.select(names: ["a.txt"])
        try require("\(mode) filtered selection domain excludes hidden rows and group headings",
                    Set(pane.fileView.selectionScopeItems.map(\.name)) == ["a.txt", "b.txt"])
        pane.invertFileSelection(nil)
        try require("\(mode) inversion selects only the visible complement", pane.fileView.selectedItems.map(\.name) == ["b.txt"])
        pane.deselectAllFiles(nil)
        try require("\(mode) Deselect All empties the actual view selection", pane.fileView.selectedItems.isEmpty)
        pane.invertFileSelection(nil)
        try require("\(mode) inversion from empty selects every visible file", pane.fileView.selectedItems.count == 2)
        wc.focusFilter(nil)
        let deselect = NSMenuItem(title: "", action: #selector(BrowserViewController.deselectAllFiles(_:)), keyEquivalent: "")
        let move = NSMenuItem(title: "", action: #selector(BrowserViewController.moveItemsHere(_:)), keyEquivalent: "")
        try require("\(mode) file commands decline text-input focus", !pane.validateMenuItem(deselect) && !pane.validateMenuItem(move))
        pane.deselectAllFiles(nil)
        try require("\(mode) text focus cannot clear the file selection", pane.fileView.selectedItems.count == 2)
        wc.window?.makeFirstResponder(pane.focusView)

        let undo = wc.window!.undoManager!
        undo.removeAllActions()
        guard let empty = pane.newFolder() else { throw SmokeFailure("new folder failed") }
        pane.cancelPendingRename()
        try require("\(mode) New Folder registers its own undo", undo.undoActionName == "New Folder")
        undo.undo()
        try require("\(mode) New Folder undo removes only its folder", !fm.fileExists(atPath: empty.path) && fm.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        undo.redo()
        try require("\(mode) New Folder redo restores its folder", fm.fileExists(atPath: empty.path))
        undo.undo()
        undo.removeAllActions()
        pane.nameFilter = "*.txt"
        let sourceGeneration = pane.model.generation
        pane.reload()
        try await listed(pane, at: root, after: sourceGeneration, names: ["a.txt", "b.txt"])
        pane.fileView.select(names: ["a.txt", "b.txt"])
        wc.window?.makeFirstResponder(pane.focusView)
        let previousGroupingTask = pane.lastTransferTask?.id
        pane.newFolderWithSelection(nil)
        try await requireEventually("\(mode) folder transfer completes",
                                    detail: { "\(listingDetail(pane)); undo \(undo.undoActionName)" }) {
            pane.lastTransferTask?.id != previousGroupingTask
                && pane.lastTransferTask?.snapshot.isTerminal == true
                && undo.undoActionName == "New Folder with Selection"
        }
        pane.cancelPendingRename()
        pane.fileView.endRename(commit: false)
        let grouped = root.appendingPathComponent("untitled folder")
        try require("\(mode) New Folder with Selection moves the chosen files",
                    !fm.fileExists(atPath: root.appendingPathComponent("a.txt").path)
                    && (try? fm.contentsOfDirectory(atPath: grouped.path).sorted()) == ["a.txt", "b.txt"])
        try require("\(mode) folder grouping clears only the active pane filter",
                    pane.nameFilter.isEmpty
                        && peer.currentURL?.standardizedFileURL.path == other.standardizedFileURL.path
                        && background.currentURL?.standardizedFileURL.path == other.standardizedFileURL.path,
                    "filter \(pane.nameFilter); peer \(peer.currentURL?.path ?? "nil"); background \(background.currentURL?.path ?? "nil")")
        undo.undo()
        try require("\(mode) grouping undoes as one action", !fm.fileExists(atPath: grouped.path) && fm.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        undo.redo()
        try require("\(mode) grouping redoes as one action", fm.fileExists(atPath: grouped.appendingPathComponent("a.txt").path))
        undo.undo()
        undo.removeAllActions()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([incoming as NSURL])
        wc.window?.makeFirstResponder(pane.focusView)
        try require("\(mode) Move Items Here accepts a copied file", pane.validateMenuItem(move))
        let previousMoveTask = pane.lastTransferTask?.id
        pane.moveItemsHere(nil)
        let moved = root.appendingPathComponent(incoming.lastPathComponent)
        try await requireEventually("\(mode) Move Items Here completes",
                                    detail: { "\(listingDetail(pane)); destination exists \(fm.fileExists(atPath: moved.path)); undo \(undo.undoActionName)" }) {
            pane.lastTransferTask?.id != previousMoveTask
                && pane.lastTransferTask?.snapshot.isTerminal == true
                && fm.fileExists(atPath: moved.path) && undo.undoActionName == "Move"
        }
        try require("\(mode) Move Items Here moves without a preceding Cut",
                    !fm.fileExists(atPath: incoming.path) && NSPasteboard.general.fileURLs.isEmpty)
        undo.undo()
        try require("\(mode) Move Items Here can be undone", fm.fileExists(atPath: incoming.path) && !fm.fileExists(atPath: moved.path))
        undo.removeAllActions()

        pane.nameFilter = ""
        let unfilteredGeneration = pane.model.generation
        pane.reload()
        try await listed(pane, at: root, after: unfilteredGeneration,
                         names: ["a.txt", "b.txt", "hidden.dat", "Demo.app"])
        try require("\(mode) package appears at its full path",
                    pane.model.items.contains { $0.url.standardizedFileURL.path == package.standardizedFileURL.path },
                    "expected \(package.standardizedFileURL.path); \(listingDetail(pane))")
        pane.fileView.select(urls: [package])
        wc.window?.makeFirstResponder(pane.focusView)
        let show = NSMenuItem(title: "", action: #selector(BrowserViewController.showPackageContents(_:)), keyEquivalent: "")
        try require("\(mode) package command validates", pane.validateMenuItem(show))
        let packageGeneration = pane.model.generation
        pane.showPackageContents(nil)
        try await listed(pane, at: package, after: packageGeneration, names: ["inside.txt"])
        try require("\(mode) package contents open inside the active pane",
                    pane.model.items.map(\.name) == ["inside.txt"]
                        && peer.currentURL?.standardizedFileURL.path == other.standardizedFileURL.path
                        && background.currentURL?.standardizedFileURL.path == other.standardizedFileURL.path,
                    "\(listingDetail(pane)); peer \(peer.currentURL?.path ?? "nil"); background \(background.currentURL?.path ?? "nil")")
    }

    @MainActor private static func listed(_ pane: BrowserViewController, at url: URL,
                                         after generation: Int = 0, names: Set<String>) async throws {
        try await requireEventually("directory listing arrives",
                                    detail: { "expected \(url.standardizedFileURL.path), generation > \(generation), names \(names.sorted()); \(listingDetail(pane))" }) {
            pane.currentURL?.standardizedFileURL.path == url.standardizedFileURL.path
                && pane.model.url?.standardizedFileURL.path == url.standardizedFileURL.path
                && pane.model.generation > generation && !pane.hasListingError
                && !pane.isPreparingArchive && !pane.model.isSearchResults
                && Set(pane.model.items.map(\.name)) == names
        }
    }

    @MainActor private static func listingDetail(_ pane: BrowserViewController) -> String {
        "current \(pane.currentURL?.standardizedFileURL.path ?? "nil"); model \(pane.model.url?.standardizedFileURL.path ?? "nil"); generation \(pane.model.generation); error \(pane.hasListingError); items \(pane.model.items.map { $0.url.standardizedFileURL.path }); selected \(pane.fileView.selectedItems.map { $0.url.standardizedFileURL.path }); task \(String(describing: pane.lastTransferTask?.snapshot.state))"
    }
}

import AppKit

/// Trash: the pure location and journal helpers first, then the real pane in
/// both file views — trashing through the browser, browsing the Trash with a
/// split pane, a second tab, a filter and grouping, Put Back with undo/redo,
/// the disabled reasons, Empty Trash through the injected confirmation hook,
/// and the refused-listing banner.
///
/// Every check runs against an injected fixture trash
/// (`TrashLocation.userTrashOverride`), so no check lists, moves into or
/// empties the real `~/.Trash`.
enum TrashSmokeTests: SmokeSuite {
    static let checkPrefix = "trash: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            // Canonical from the start, so every fixture path is spelled the
            // way TrashLocation spells it.
            let fixture = URL(fileURLWithPath: TrashLocation.canonicalPath(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("tursora-trash-" + UUID().uuidString)))
            defer {
                TrashLocation.userTrashOverride = nil
                BrowserViewController.emptyTrashConfirmation = nil
                try? FileManager.default.removeItem(at: fixture)
            }
            do {
                print("== trash ==")
                try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                pureLocations(in: fixture)
                pureWording()
                menuBinding()
                purePutBackRules()
                try journalFile(in: fixture)
                for mode: ViewMode in [.details, .icons] {
                    try await paneFlow(mode: mode, in: fixture)
                }
                try await accessBanner(in: fixture)
                TrashLocation.userTrashOverride = nil
                completion()
            } catch {
                TrashLocation.userTrashOverride = nil
                check("fixtures complete", false, error.localizedDescription)
            }
        }
    }

    // MARK: - Pure: where the Trash is

    private static func pureLocations(in fixture: URL) {
        let trash = fixture.appendingPathComponent("pure-trash")
        let other = fixture.appendingPathComponent("pure-trash-elsewhere")

        check("canonical path drops a trailing slash",
              TrashLocation.canonicalPath(URL(fileURLWithPath: "/var/tmp/", isDirectory: true))
              == TrashLocation.canonicalPath(URL(fileURLWithPath: "/var/tmp")))
        check("canonical path resolves a symlinked prefix Foundation leaves alone",
              TrashLocation.canonicalPath(URL(fileURLWithPath: "/tmp/a/b")) == "/private/tmp/a/b",
              TrashLocation.canonicalPath(URL(fileURLWithPath: "/tmp/a/b")))
        check("canonical path resolves an existing symlinked directory",
              TrashLocation.canonicalPath(URL(fileURLWithPath: "/tmp")) == "/private/tmp",
              TrashLocation.canonicalPath(URL(fileURLWithPath: "/tmp")))
        check("canonical path removes dot segments",
              TrashLocation.canonicalPath(URL(fileURLWithPath: "/private/tmp/a/./b")) == "/private/tmp/a/b")

        let roots = [trash]
        check("the trash root is a trash directory", TrashLocation.isTrashDirectory(trash, roots: roots))
        check("a folder inside the trash is not the trash directory itself",
              !TrashLocation.isTrashDirectory(trash.appendingPathComponent("inner"), roots: roots))
        check("the root contains itself",
              TrashLocation.trashRoot(containing: trash, roots: roots)?.path == trash.path)
        check("a descendant resolves to its root",
              TrashLocation.trashRoot(containing: trash.appendingPathComponent("inner/leaf.txt"), roots: roots)?.path == trash.path)
        check("a sibling sharing the path prefix is outside the trash",
              TrashLocation.trashRoot(containing: other, roots: roots) == nil)
        check("an unrelated folder is outside the trash",
              TrashLocation.trashRoot(containing: fixture, roots: roots) == nil)
        check("no roots means nothing is in the trash",
              TrashLocation.trashRoot(containing: trash, roots: []) == nil)

        let saved = TrashLocation.userTrashOverride
        TrashLocation.userTrashOverride = trash
        check("the override replaces the user trash", TrashLocation.userTrash()?.path == trash.standardizedFileURL.path)
        check("knownRoots follows the override", TrashLocation.knownRoots().map(\.path) == [trash.standardizedFileURL.path])
        check("a volume trash follows the override too",
              TrashLocation.volumeTrash(containing: fixture)?.path == trash.standardizedFileURL.path)
        check("isInTrash uses the override roots", TrashLocation.isInTrash(trash.appendingPathComponent("x")) && !TrashLocation.isInTrash(fixture))
        TrashLocation.userTrashOverride = nil
        check("without an override the user trash is ~/.Trash",
              TrashLocation.userTrash()?.lastPathComponent == ".Trash",
              TrashLocation.userTrash()?.path ?? "nil")
        TrashLocation.userTrashOverride = saved

        check("EACCES is a permission failure",
              TrashLocation.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        check("EPERM is a permission failure",
              TrashLocation.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        check("Cocoa's no-permission error counts",
              TrashLocation.isPermissionDenied(CocoaError(.fileReadNoPermission)))
        check("a wrapped POSIX denial counts",
              TrashLocation.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                                                       userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])))
        check("a missing folder is not a permission failure",
              !TrashLocation.isPermissionDenied(CocoaError(.fileNoSuchFile))
              && !TrashLocation.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        check("the privacy target is Full Disk Access",
              TrashLocation.privacySettingsURL.absoluteString
              == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    /// NSMenu ignores Shift for a ⌫ key equivalent, so Empty Trash ships unbound
    /// (D74). Probed with a standalone AppKit program; kept here so the reason
    /// fails loudly if someone gives the destructive command a shortcut again.
    @MainActor private static func menuBinding() {
        guard let menu = NSApp.mainMenu, let empty = findItem("menu.emptyTrash", in: menu) else {
            check("the Empty Trash menu item exists", false); return
        }
        check("Empty Trash ships without a key equivalent", empty.keyEquivalent.isEmpty,
              "keyEquivalent=\(empty.keyEquivalent.unicodeScalars.map { "U+\(String($0.value, radix: 16))" }.joined())")
        let probe = NSMenu()
        probe.autoenablesItems = false
        let shifted = NSMenuItem(title: "probe", action: nil, keyEquivalent: "\u{8}")
        shifted.keyEquivalentModifierMask = [.command, .shift]
        probe.addItem(shifted)
        let plainBackspace = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             characters: "\u{8}", charactersIgnoringModifiers: "\u{8}",
                                             isARepeat: false, keyCode: 51)!
        check("AppKit still ignores Shift for a Backspace key equivalent",
              probe.performKeyEquivalent(with: plainBackspace),
              "if this fails AppKit changed and D74 can be revisited")
    }

    @MainActor private static func findItem(_ id: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier?.rawValue == id { return item }
            if let submenu = item.submenu, let found = findItem(id, in: submenu) { return found }
        }
        return nil
    }

    /// Finder's own strings, from Localizable (see docs/research/trash.md).
    private static func pureWording() {
        check("the place uses Finder's name", TrashLocation.placeName == "Trash")
        check("the File menu row is Finder's A3 wording", TrashLocation.emptyTrashMenuTitle == "Empty Trash…")
        check("the confirmation is Finder's A15 wording",
              TrashLocation.emptyTrashMessageText == "Are you sure you want to permanently erase the items in the Trash?")
        check("the informative text is Finder's A16 wording",
              TrashLocation.emptyTrashInformativeText == "You can’t undo this action.")
        check("the confirm button is Finder's N157 wording", TrashLocation.emptyTrashButtonTitle == "Empty Trash")
        check("Put Back is Finder's N153.1 wording", TrashLocation.putBackTitle == "Put Back")
        check("the status context matches the pane label", TrashLocation.statusContext == "Trash")
    }

    // MARK: - Pure: the Put Back rule

    private static func purePutBackRules() {
        let origin = URL(fileURLWithPath: "/parent/report.pdf")
        // deletingLastPathComponent keeps the directory URL's trailing slash,
        // so the expectation is built the same way the rule builds it.
        let parent = origin.deletingLastPathComponent()
        check("a known origin with a live parent and a free name can go back",
              TrashOrigins.putBack(origin: origin, parentExists: true, destinationOccupied: false)
              == .available(origin))
        check("no journal entry means an unknown origin",
              TrashOrigins.putBack(origin: nil, parentExists: true, destinationOccupied: false) == .unknownOrigin)
        check("a vanished parent blocks Put Back",
              TrashOrigins.putBack(origin: origin, parentExists: false, destinationOccupied: false)
              == .missingParent(parent))
        check("a taken name blocks Put Back",
              TrashOrigins.putBack(origin: origin, parentExists: true, destinationOccupied: true)
              == .nameTaken(origin))
        check("a vanished parent wins over a taken name",
              TrashOrigins.putBack(origin: origin, parentExists: false, destinationOccupied: true)
              == .missingParent(parent))
        check("only the available case carries a destination",
              TrashOrigins.putBack(origin: origin, parentExists: true, destinationOccupied: false).destination == origin
              && TrashOrigins.PutBack.unknownOrigin.destination == nil)
        check("available has no reason and every refusal explains itself",
              TrashOrigins.PutBack.available(origin).reason == nil
              && TrashOrigins.PutBack.unknownOrigin.reason?.contains("Tursora moved to the Trash") == true
              && TrashOrigins.PutBack.missingParent(parent).reason?.contains("“parent”") == true
              && TrashOrigins.PutBack.nameTaken(origin).reason?.contains("“report.pdf”") == true)
    }

    // MARK: - The journal file

    private static func journalFile(in fixture: URL) throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("journal")
        let trash = root.appendingPathComponent("Trash")
        let origin = root.appendingPathComponent("origin")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try fm.createDirectory(at: origin, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("TrashOrigins.json")
        let journal = TrashOrigins(fileURL: file)
        check("a fresh journal is empty and writes nothing", journal.count == 0 && !fm.fileExists(atPath: file.path))

        let trashedA = trash.appendingPathComponent("a.txt")
        let trashedB = trash.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: trashedA)
        try Data("b".utf8).write(to: trashedB)
        journal.record([(original: origin.appendingPathComponent("a.txt"), trashed: trashedA),
                        (original: origin.appendingPathComponent("b.txt"), trashed: trashedB)])
        check("recording keeps one entry per trashed item", journal.count == 2)
        check("the journal answers with the original path",
              journal.origin(ofTrashed: trashedA)?.path == origin.appendingPathComponent("a.txt").path,
              journal.origin(ofTrashed: trashedA)?.path ?? "nil")
        check("an item Tursora never trashed has no origin",
              journal.origin(ofTrashed: trash.appendingPathComponent("stranger.txt")) == nil)
        check("the journal is written atomically to its injected file",
              fm.fileExists(atPath: file.path) && journal.lastWriteError == nil)

        let reloaded = TrashOrigins(fileURL: file)
        check("a new instance reads the same entries back",
              reloaded.count == 2 && reloaded.origin(ofTrashed: trashedB)?.lastPathComponent == "b.txt")
        check("entries sort newest first and carry both paths",
              Set(reloaded.entries.map(\.trashedPath))
              == Set([TrashLocation.canonicalPath(trashedA), TrashLocation.canonicalPath(trashedB)]))

        check("a live parent with a free name is available",
              journal.putBack(for: trashedA) == .available(origin.appendingPathComponent("a.txt")))
        try Data("taken".utf8).write(to: origin.appendingPathComponent("b.txt"))
        check("an occupied original path is refused",
              journal.putBack(for: trashedB) == .nameTaken(origin.appendingPathComponent("b.txt")))
        check("an item with no entry is refused as unknown",
              journal.putBack(for: trash.appendingPathComponent("stranger.txt")) == .unknownOrigin)

        journal.forget([trashedA])
        check("forgetting one entry leaves the other", journal.count == 1 && journal.origin(ofTrashed: trashedA) == nil)

        journal.record([(original: origin.appendingPathComponent("a.txt"), trashed: trashedA)])
        try fm.removeItem(at: trashedA)
        check("pruning drops entries whose trashed item is gone",
              journal.pruneMissing(under: trash) == 1 && journal.origin(ofTrashed: trashedA) == nil)
        check("pruning again reports nothing to do", journal.pruneMissing(under: trash) == 0)

        journal.forgetAll(under: trash)
        check("emptying the trash forgets every entry under it", journal.count == 0)

        let limitJournal = TrashOrigins(fileURL: root.appendingPathComponent("limit.json"))
        let overflow = TrashOrigins.entryLimit + 10
        limitJournal.record((0..<overflow).map {
            (original: origin.appendingPathComponent("o\($0)"), trashed: trash.appendingPathComponent("t\($0)"))
        })
        check("the journal never grows past its entry limit", limitJournal.count == TrashOrigins.entryLimit,
              "\(limitJournal.count)")
    }

    // MARK: - The pane, in both views

    @MainActor private static func paneFlow(mode: ViewMode, in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("pane-\(mode)")
        let trash = root.appendingPathComponent("Trash")
        let origin = root.appendingPathComponent("origin")
        let keep = root.appendingPathComponent("keep")
        for url in [trash, origin, keep] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        for name in ["a.txt", "b.txt"] { try Data(name.utf8).write(to: origin.appendingPathComponent(name)) }
        try Data("c".utf8).write(to: keep.appendingPathComponent("c.txt"))
        // Trashed outside Tursora: no journal entry, so no Put Back.
        try Data("stranger".utf8).write(to: trash.appendingPathComponent("stranger.txt"))

        TrashLocation.userTrashOverride = trash
        defer { TrashLocation.userTrashOverride = nil }

        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: origin,
                                      viewPropertiesStore: store)
        defer { wc.close(); try? store.flush() }
        wc.window?.setContentSize(NSSize(width: 1000, height: 640))
        wc.window?.center()
        wc.window?.makeKeyAndOrderFront(nil)
        let browser = wc.browser
        await listed(browser, at: origin)
        await waitUntil("\(mode) the origin listing arrives") { browser.model.items.count == 2 }
        browser.setViewMode(mode)

        // The sidebar offers the Trash at the end of Locations.
        let locations = wc.places.sections.first { $0.title == "Locations" }
        check("\(mode): Locations ends with a non-removable Trash place",
              locations?.places.last?.name == "Trash"
              && locations?.places.last?.url.path == trash.standardizedFileURL.path
              && locations?.places.last?.symbolName == "trash"
              && locations?.places.last?.isRemovable == false,
              locations?.places.map(\.name).joined(separator: ",") ?? "nil")

        // 1. Trash two files through the browser; the journal records both.
        browser.fileView.select(names: ["a.txt", "b.txt"])
        browser.moveToTrash(nil)
        await waitUntil("\(mode) both files reach the fixture trash") {
            fm.fileExists(atPath: trash.appendingPathComponent("a.txt").path)
                && fm.fileExists(atPath: trash.appendingPathComponent("b.txt").path)
        }
        check("\(mode): trashing moved both files into the injected trash",
              names(in: origin).isEmpty && Set(names(in: trash)).isSuperset(of: ["a.txt", "b.txt"]),
              "\(names(in: trash))")
        check("\(mode): the journal recorded both origins",
              TrashOrigins.shared.origin(ofTrashed: trash.appendingPathComponent("a.txt"))?.path
              == origin.appendingPathComponent("a.txt").path
              && TrashOrigins.shared.origin(ofTrashed: trash.appendingPathComponent("b.txt"))?.path
              == origin.appendingPathComponent("b.txt").path)

        // A file whose original name is taken again once it is restored.
        let keepBrowser = wc.tabs.newTab(at: keep, activate: false)
        await listed(keepBrowser, at: keep)
        await waitUntil("\(mode) the second tab's listing arrives") { keepBrowser.model.items.count == 1 }
        keepBrowser.fileView.select(names: ["c.txt"])
        keepBrowser.moveToTrash(nil)
        await waitUntil("\(mode) the second tab's file reaches the trash") {
            fm.fileExists(atPath: trash.appendingPathComponent("c.txt").path)
        }
        try Data("new c".utf8).write(to: keep.appendingPathComponent("c.txt"))
        check("\(mode): a second tab trashes into the same journal",
              TrashOrigins.shared.origin(ofTrashed: trash.appendingPathComponent("c.txt"))?.path
              == keep.appendingPathComponent("c.txt").path)

        // 2. Browse the trash: an ordinary listing, with its own status context.
        browser.navigate(to: trash)
        await listed(browser, at: trash)
        await waitUntil("\(mode) the trash listing arrives",
                        detail: { "\(browser.model.items.map(\.name))" }) { browser.model.items.count == 4 }
        check("\(mode): the pane knows it is in the Trash",
              browser.isBrowsingTrash && browser.currentTrashRoot?.path == trash.standardizedFileURL.path)
        check("\(mode): the trash lists its items",
              Set(browser.model.items.map(\.name)) == ["a.txt", "b.txt", "c.txt", "stranger.txt"],
              "\(browser.model.items.map(\.name))")
        check("\(mode): the status bar shows the Trash context",
              browser.statusBar.statusText.hasPrefix("Trash — "), browser.statusBar.statusText)

        // Split pane, filter and grouping all keep working.
        let peer = wc.tabs.currentPage.split(with: trash)
        await listed(peer, at: trash)
        await waitUntil("\(mode) the other pane lists the trash") { peer.model.items.count == 4 }
        check("\(mode): the other pane also reports the Trash", peer.isBrowsingTrash)
        wc.tabs.currentPage.activate(browser)
        browser.nameFilter = "*.txt"
        browser.setGroupKey(.kind)
        await waitUntil("\(mode) the filtered, grouped trash listing settles") { browser.model.items.count == 4 }
        check("\(mode): filtering and grouping work inside the Trash",
              browser.isFiltering && browser.groupKey == .kind && browser.model.items.count == 4)

        // 3. What Finder allows and refuses in the Trash.
        browser.fileView.select(names: ["a.txt"])
        await waitUntil("\(mode) the trashed item is selected") { browser.fileView.selectedItems.map(\.name) == ["a.txt"] }
        func validates(_ selector: Selector) -> Bool {
            browser.validateMenuItem(NSMenuItem(title: "", action: selector, keyEquivalent: ""))
        }
        check("\(mode): New Folder, Paste and Compress are refused in the Trash",
              !browser.canModifyCurrentLocation && !validates(#selector(BrowserViewController.paste(_:)))
              && !validates(#selector(BrowserViewController.compressSelection(_:)))
              && !wc.validateMenuItem(NSMenuItem(title: "", action: #selector(MainWindowController.newFolder(_:)), keyEquivalent: "")))
        check("\(mode): Rename, Duplicate, Cut and Move to Trash are refused",
              !validates(#selector(BrowserViewController.renameSelection(_:)))
              && !validates(#selector(BrowserViewController.duplicate(_:)))
              && !validates(#selector(BrowserViewController.cut(_:)))
              && !validates(#selector(BrowserViewController.moveToTrash(_:))))
        check("\(mode): Copy, Quick Look, Get Info and Delete Immediately stay available",
              validates(#selector(BrowserViewController.copy(_:)))
              && validates(#selector(BrowserViewController.quickLook(_:)))
              && validates(#selector(BrowserViewController.deletePermanently(_:)))
              && wc.validateMenuItem(NSMenuItem(title: "", action: #selector(MainWindowController.getInfo(_:)), keyEquivalent: "")))
        check("\(mode): the view refuses to start an inline rename", !browser.fileView.allowsRenaming)
        check("\(mode): New Folder is refused in the Trash", browser.newFolder() == nil)
        check("\(mode): a refused New Folder arms no inline edit", !browser.hasPendingRename && !browser.fileView.isRenaming)
        browser.duplicate(nil)
        check("\(mode): the refused commands changed nothing on disk",
              Set(names(in: trash)) == ["a.txt", "b.txt", "c.txt", "stranger.txt"], "\(names(in: trash))")

        // 4. The Trash's context menus.
        let itemMenu = browser.buildContextMenu(for: browser.fileView.selectedItems)
        let itemTitles = itemMenu.items.map(\.title)
        check("\(mode): the item menu offers Put Back, Delete Immediately… and Empty Trash…",
              itemTitles.contains("Put Back") && itemTitles.contains("Delete Immediately…")
              && itemTitles.contains("Empty Trash…"), itemTitles.joined(separator: ","))
        check("\(mode): the item menu drops Rename, Duplicate, Compress and Move to Trash",
              !itemTitles.contains { $0.hasPrefix("Rename") || $0.hasPrefix("Compress") }
              && !itemTitles.contains("Duplicate") && !itemTitles.contains("Move to Trash"),
              itemTitles.joined(separator: ","))
        let backgroundTitles = browser.buildContextMenu(for: []).items.map(\.title)
        check("\(mode): the background menu offers Empty Trash… and no New Folder or Paste",
              backgroundTitles.contains("Empty Trash…") && !backgroundTitles.contains("New Folder")
              && !backgroundTitles.contains("Paste"), backgroundTitles.joined(separator: ","))

        // 5. Put Back, with undo and redo.
        check("\(mode): Put Back is enabled for a recorded item",
              browser.putBackEnablement(for: [trash.appendingPathComponent("a.txt")]).enabled)
        browser.putBackSelection(nil)
        await waitUntil("\(mode) a.txt returns to its original folder") {
            fm.fileExists(atPath: origin.appendingPathComponent("a.txt").path)
        }
        check("\(mode): Put Back restored the item to its original path",
              names(in: origin) == ["a.txt"] && !fm.fileExists(atPath: trash.appendingPathComponent("a.txt").path),
              "\(names(in: origin)) / \(names(in: trash))")
        check("\(mode): the journal entry is gone once the item is back",
              TrashOrigins.shared.origin(ofTrashed: trash.appendingPathComponent("a.txt")) == nil)

        guard let undo = wc.window?.undoManager else { check("\(mode): the window has an undo manager", false); return }
        check("\(mode): undo names the operation Put Back", undo.canUndo && undo.undoActionName == "Put Back",
              undo.undoActionName)
        undo.undo()
        await waitUntil("\(mode) undo returns a.txt to the trash") {
            fm.fileExists(atPath: trash.appendingPathComponent("a.txt").path)
        }
        check("\(mode): ⌘Z puts the item back in the Trash at the same path",
              names(in: origin).isEmpty && fm.fileExists(atPath: trash.appendingPathComponent("a.txt").path))
        check("\(mode): undo restores the journal entry",
              TrashOrigins.shared.origin(ofTrashed: trash.appendingPathComponent("a.txt"))?.path
              == origin.appendingPathComponent("a.txt").path)
        check("\(mode): redo is available", undo.canRedo)
        undo.redo()
        await waitUntil("\(mode) redo restores a.txt again") {
            fm.fileExists(atPath: origin.appendingPathComponent("a.txt").path)
        }
        check("\(mode): redo puts the item back again and drops the entry",
              names(in: origin) == ["a.txt"]
              && TrashOrigins.shared.origin(ofTrashed: trash.appendingPathComponent("a.txt")) == nil)

        // 6. The three reasons Put Back is disabled.
        await waitUntil("\(mode) the trash listing settles after the restore") { browser.model.items.count == 3 }
        browser.fileView.select(names: ["stranger.txt"])
        await waitUntil("\(mode) the stranger is selected") { browser.fileView.selectedItems.map(\.name) == ["stranger.txt"] }
        let unknown = browser.putBackEnablement(for: [trash.appendingPathComponent("stranger.txt")])
        check("\(mode): an item Tursora never trashed has Put Back disabled with a reason",
              !unknown.enabled && unknown.tooltip?.contains("Only items Tursora moved to the Trash") == true,
              unknown.tooltip ?? "nil")
        let taken = browser.putBackEnablement(for: [trash.appendingPathComponent("c.txt")])
        check("\(mode): a retaken name disables Put Back with its own reason",
              !taken.enabled && taken.tooltip?.contains("already in the folder it came from") == true,
              taken.tooltip ?? "nil")
        try fm.removeItem(at: origin)
        let orphan = browser.putBackEnablement(for: [trash.appendingPathComponent("b.txt")])
        check("\(mode): a vanished original folder disables Put Back with its own reason",
              !orphan.enabled && orphan.tooltip?.contains("no longer exists") == true, orphan.tooltip ?? "nil")
        let disabledRow = browser.buildContextMenu(for: browser.fileView.selectedItems)
            .items.first { $0.title == "Put Back" }
        check("\(mode): the contextual Put Back row is disabled and carries the reason",
              disabledRow?.isEnabled == false && disabledRow?.toolTip?.isEmpty == false,
              disabledRow?.toolTip ?? "nil")
        browser.putBack([trash.appendingPathComponent("b.txt")])
        check("\(mode): a refused Put Back moves nothing",
              fm.fileExists(atPath: trash.appendingPathComponent("b.txt").path))

        // 7. Empty Trash — Cancel first, then confirm.
        let menuRow = NSMenuItem(title: "", action: #selector(BrowserViewController.emptyTrash(_:)), keyEquivalent: "")
        check("\(mode): File ▸ Empty Trash… is enabled and uses Finder's wording",
              browser.validateMenuItem(menuRow) && menuRow.title == "Empty Trash…", menuRow.title)
        BrowserViewController.emptyTrashConfirmation = { _ in false }
        await emptied(browser)
        check("\(mode): cancelling the confirmation keeps every item",
              Set(names(in: trash)) == ["b.txt", "c.txt", "stranger.txt"], "\(names(in: trash))")
        BrowserViewController.emptyTrashConfirmation = { _ in true }
        await emptied(browser)
        await waitUntil("\(mode) the trash empties") { names(in: trash).isEmpty }
        check("\(mode): Empty Trash removed every top-level item", names(in: trash).isEmpty, "\(names(in: trash))")
        check("\(mode): Empty Trash forgot every journal entry under it",
              TrashOrigins.shared.origin(ofTrashed: trash.appendingPathComponent("b.txt")) == nil
              && TrashOrigins.shared.origin(ofTrashed: trash.appendingPathComponent("c.txt")) == nil)
        await waitUntil("\(mode) the emptied trash shows no rows") { browser.model.items.isEmpty }
        check("\(mode): the pane shows the empty Trash and dims Empty Trash…",
              browser.model.items.isEmpty && !browser.canEmptyTrash)
        BrowserViewController.emptyTrashConfirmation = nil

        // Leaving the Trash restores the ordinary rules.
        try fm.createDirectory(at: origin, withIntermediateDirectories: true)
        browser.navigate(to: origin)
        await listed(browser, at: origin)
        await waitUntil("\(mode) the plain folder listing arrives") { !browser.isBrowsingTrash }
        check("\(mode): leaving the Trash restores New Folder, renaming and the plain status bar",
              browser.canModifyCurrentLocation && browser.fileView.allowsRenaming && !browser.isBrowsingTrash
              && !browser.statusBar.statusText.contains("Trash"), browser.statusBar.statusText)
    }

    /// Runs Empty Trash and waits for its background pass to report back.
    @MainActor private static func emptied(_ browser: BrowserViewController) async {
        await withCheckedContinuation { continuation in
            browser.emptyTrash { continuation.resume() }
        }
    }

    // MARK: - A Trash that cannot be listed

    @MainActor private static func accessBanner(in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("denied")
        let trash = root.appendingPathComponent("Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: trash.appendingPathComponent("secret.txt"))
        TrashLocation.userTrashOverride = trash
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trash.path)
            TrashLocation.userTrashOverride = nil
        }

        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                      viewPropertiesStore: store)
        defer { wc.close(); try? store.flush() }
        wc.window?.setContentSize(NSSize(width: 900, height: 600))
        wc.window?.makeKeyAndOrderFront(nil)
        let browser = wc.browser
        await listed(browser, at: root)

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: trash.path)
        guard (try? fm.contentsOfDirectory(atPath: trash.path)) == nil else {
            // A process with Full Disk Access can still read a 000 directory.
            check("an unreadable trash is refused to this process", true, "skipped: the listing succeeded anyway")
            return
        }
        check("an unreadable trash is refused to this process", true)

        browser.goTrash()
        await waitUntil("the refused listing reports back") { browser.locationNotice != nil }
        guard let notice = browser.locationNotice else {
            check("a refused Trash listing shows the banner", false); return
        }
        check("a refused Trash listing shows the banner instead of a modal", true)
        check("the banner names the folder and offers both recoveries",
              notice.messageLabel.stringValue == LocationNotice.accessDeniedMessage(for: trash)
              && notice.settingsButton.title == "Open Privacy Settings"
              && notice.retryButton.title == "Try Again"
              && notice.detailLabel.stringValue.contains("Full Disk Access"),
              notice.messageLabel.stringValue)
        check("the banner is mounted in the pane, not in a window of its own",
              notice.superview != nil && notice.window === wc.window)
        check("Open Privacy Settings never opens a modal on a headless run",
              NSApp.modalWindow == nil && { browser.openPrivacySettings(nil); return NSApp.modalWindow == nil }())
        check("the pane still knows it is in the Trash with no rows",
              browser.isBrowsingTrash && browser.model.items.isEmpty)

        // Try Again after the permission is restored recovers the listing.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trash.path)
        browser.retryListing(nil)
        await waitUntil("the retried listing recovers") { browser.model.items.count == 1 }
        check("Try Again lists the Trash once the permission is back",
              browser.model.items.map(\.name) == ["secret.txt"] && browser.locationNotice == nil,
              "\(browser.model.items.map(\.name))")
    }

    // MARK: - Helpers

    private static func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0 != ".DS_Store" }.sorted()
    }

    @MainActor private static func listed(_ pane: BrowserViewController, at url: URL) async {
        await waitUntil("directory listing", detail: { "\(pane.currentURL?.path ?? "nil") vs \(url.path)" }) {
            pane.currentURL?.standardizedFileURL == url.standardizedFileURL
                && pane.model.url?.standardizedFileURL == url.standardizedFileURL
                && pane.model.generation > 0 && !pane.isPreparingArchive && !pane.model.isSearchResults
        }
    }
}

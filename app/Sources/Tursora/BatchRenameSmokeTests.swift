import AppKit

/// Finder-style batch rename: the pure planner and validator first, then the
/// two-pass filesystem helper (chains, swaps, case-only names, rollback), then
/// the real sheet in both file views, with a split pane, filtering, grouping,
/// undo/redo and search results.
enum BatchRenameSmokeTests: SmokeSuite {
    static let checkPrefix = "batch rename: "
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("tursora-batch-rename-" + UUID().uuidString)
                .resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: fixture) }
            do {
                print("== batch rename ==")
                try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                pureNames()
                pureLabels()
                pureValidation()
                try operations(in: fixture)
                for mode: ViewMode in [.details, .icons] {
                    try await sheetFlow(mode: mode, in: fixture)
                }
                try await searchResults(in: fixture)
                completion()
            } catch {
                check("fixtures complete", false, error.localizedDescription)
            }
        }
    }

    // MARK: - Pure planning

    private static let stamp = Date(timeIntervalSince1970: 1_789_000_000)

    private static func pureNames() {
        check("split keeps a multi-dot base", BatchRename.split("archive.tar.gz") == ("archive.tar", "gz"))
        check("split treats a dotfile as base only", BatchRename.split(".profile") == (".profile", ""))
        check("split without a dot has no extension", BatchRename.split("README") == ("README", ""))
        check("split ignores a trailing dot", BatchRename.split("draft.") == ("draft.", ""))

        let names = ["IMG_001.jpg", "IMG_002.jpg", "IMG_003.jpg"]
        check("Replace Text rewrites every occurrence in order",
              BatchRename.plan(names: names, mode: .replace(find: "IMG_", replacement: "Photo ")) == ["Photo 001.jpg", "Photo 002.jpg", "Photo 003.jpg"])
        check("Replace Text can change an extension like Finder",
              BatchRename.plan(names: ["note.txt"], mode: .replace(find: ".txt", replacement: ".md")) == ["note.md"])
        check("Replace Text with an empty Find leaves names alone",
              BatchRename.plan(names: names, mode: .replace(find: "", replacement: "x")) == names)

        check("Add Text after name keeps the extension",
              BatchRename.plan(names: names, mode: .add(text: " copy", position: .afterName)) == ["IMG_001 copy.jpg", "IMG_002 copy.jpg", "IMG_003 copy.jpg"])
        check("Add Text before name keeps the extension",
              BatchRename.plan(names: ["archive.tar.gz"], mode: .add(text: "old ", position: .beforeName)) == ["old archive.tar.gz"])
        check("Add Text with empty text leaves names alone",
              BatchRename.plan(names: names, mode: .add(text: "", position: .afterName)) == names)

        check("Name and Index counts from the start number without padding",
              BatchRename.plan(names: names, mode: .format(kind: .nameAndIndex, custom: "Custom", start: 1, position: .afterName)) == ["Custom 1.jpg", "Custom 2.jpg", "Custom 3.jpg"])
        check("Name and Index before name and from 9",
              BatchRename.plan(names: names, mode: .format(kind: .nameAndIndex, custom: "Custom", start: 9, position: .beforeName)) == ["9 Custom.jpg", "10 Custom.jpg", "11 Custom.jpg"])
        check("Name and Index with an empty custom text is just the number",
              BatchRename.plan(names: names, mode: .format(kind: .nameAndIndex, custom: "", start: 1, position: .afterName)) == ["1.jpg", "2.jpg", "3.jpg"])
        check("Name and Counter pads to five digits",
              BatchRename.plan(names: names, mode: .format(kind: .nameAndCounter, custom: "Custom", start: 1, position: .afterName)) == ["Custom 00001.jpg", "Custom 00002.jpg", "Custom 00003.jpg"])
        check("Name and Counter never truncates a wide number",
              BatchRename.padded(123_456, width: 5) == "123456" && BatchRename.padded(7, width: 5) == "00007")

        let text = BatchRename.dateStamp(stamp, timeZone: TimeZone(identifier: "UTC")!)
        check("date stamp matches Finder's form", text == "2026-09-10 at 00.26.40", text)
        let dated = BatchRename.plan(names: ["a.jpg", "b.jpg"], mode: .format(kind: .nameAndDate, custom: "Custom", start: 1, position: .afterName),
                                     dates: [stamp, stamp.addingTimeInterval(3600)])
        check("Name and Date uses the injected date and keeps the extension",
              dated == ["Custom \(BatchRename.dateStamp(stamp)).jpg", "Custom \(BatchRename.dateStamp(stamp.addingTimeInterval(3600))).jpg"], "\(dated)")
        let before = BatchRename.plan(names: ["a.jpg"], mode: .format(kind: .nameAndDate, custom: "Custom", start: 1, position: .beforeName), dates: [stamp])
        check("Name and Date before name", before == ["\(BatchRename.dateStamp(stamp)) Custom.jpg"], "\(before)")
        let shared = BatchRename.plan(names: ["a.jpg", "b.jpg"], mode: .format(kind: .nameAndDate, custom: "Custom", start: 1, position: .afterName),
                                      dates: [stamp, stamp])
        check("Name and Date disambiguates a shared stamp within the batch",
              shared[0] != shared[1] && shared[1] == "Custom \(BatchRename.dateStamp(stamp)) 2.jpg", "\(shared)")
        check("plan returns one name per input",
              BatchRename.plan(names: names, mode: .format(kind: .nameAndIndex, custom: "x", start: 1, position: .afterName)).count == names.count)
    }

    private static func pureLabels() {
        check("menu title is singular for one item", BatchRename.menuTitle(count: 1) == "Rename" && BatchRename.menuTitle(count: 0) == "Rename")
        check("menu title is Finder's plural for several", BatchRename.menuTitle(count: 3) == "Rename 3 Items…")
        check("sheet title is Finder's label", BatchRename.sheetTitle == "Rename Finder Items:")
        check("mode popup lists Finder's three entries", BatchRename.Mode.titles == ["Replace Text", "Add Text", "Format"])
        check("Where popup lists after name first", BatchRename.Position.allCases.map(\.title) == ["after name", "before name"])
        check("Name Format popup lists Index, Counter, Date",
              BatchRename.FormatKind.allCases.map(\.title) == ["Name and Index", "Name and Counter", "Name and Date"])
    }

    // MARK: - Pure validation

    private static func entries(_ names: [String], in directory: String = "/parent") -> [BatchRename.Entry] {
        names.map { BatchRename.Entry(directory: URL(fileURLWithPath: directory), name: $0) }
    }

    private static func pureValidation() {
        let three = entries(["a.txt", "b.txt", "c.txt"])
        let siblings = ["/parent": Set(["a.txt", "b.txt", "c.txt", "keep.txt", ".hidden"])]
        check("distinct new names pass",
              BatchRename.validate(["x.txt", "y.txt", "z.txt"], for: three, siblings: siblings) == nil)
        check("unchanged names pass",
              BatchRename.validate(["a.txt", "b.txt", "c.txt"], for: three, siblings: siblings) == nil)

        let empty = BatchRename.validate(["", "y.txt", "z.txt"], for: three, siblings: siblings)
        check("empty name is reported", empty?.kind == .empty && empty?.index == 0)
        check("whitespace-only name is reported", BatchRename.validate(["   ", "y.txt", "z.txt"], for: three)?.kind == .empty)
        check("empty message is inline wording", empty?.message == "The name can’t be empty.", empty?.message ?? "nil")

        check("slash is invalid", BatchRename.validate(["x/y.txt", "y.txt", "z.txt"], for: three)?.kind == .invalid)
        check("colon is invalid", BatchRename.validate(["x:y.txt", "y.txt", "z.txt"], for: three)?.kind == .invalid)
        check("dot names are invalid",
              BatchRename.validate([".", "y.txt", "z.txt"], for: three)?.kind == .invalid
              && BatchRename.validate(["..", "y.txt", "z.txt"], for: three)?.kind == .invalid)
        let invalid = BatchRename.validate(["x/y.txt", "y.txt", "z.txt"], for: three)
        check("invalid message uses Finder's RN31 wording",
              invalid?.message == "The name “x/y.txt” can’t be used.", invalid?.message ?? "nil")

        let duplicate = BatchRename.validate(["same.txt", "same.txt", "z.txt"], for: three, siblings: siblings)
        check("duplicate within the batch is reported", duplicate?.kind == .taken && duplicate?.index == 1)
        check("duplicate compares case-insensitively",
              BatchRename.validate(["same.txt", "SAME.txt", "z.txt"], for: three, siblings: siblings)?.kind == .taken)
        check("a case-sensitive volume may keep both cases",
              BatchRename.validate(["same.txt", "SAME.txt", "z.txt"], for: three, siblings: siblings, caseSensitive: true) == nil)

        let taken = BatchRename.validate(["keep.txt", "y.txt", "z.txt"], for: three, siblings: siblings)
        check("collision with a sibling outside the batch is reported", taken?.kind == .taken && taken?.index == 0)
        check("collision with a hidden sibling is reported",
              BatchRename.validate([".hidden", "y.txt", "z.txt"], for: three, siblings: siblings)?.kind == .taken)
        check("collision compares case-insensitively",
              BatchRename.validate(["KEEP.TXT", "y.txt", "z.txt"], for: three, siblings: siblings)?.kind == .taken)
        check("taken message uses Finder's RN17 wording",
              taken?.message == "The name “keep.txt” is already taken. Please choose a different name.", taken?.message ?? "nil")

        check("a chain inside the batch is allowed (a→b while b→c)",
              BatchRename.validate(["b.txt", "c.txt", "d.txt"], for: three, siblings: siblings) == nil)
        check("a swap inside the batch is allowed",
              BatchRename.validate(["b.txt", "a.txt", "c.txt"], for: three, siblings: siblings) == nil)
        check("a case-only rename of an item is allowed",
              BatchRename.validate(["A.txt", "b.txt", "c.txt"], for: three, siblings: siblings) == nil)

        let split = [BatchRename.Entry(directory: URL(fileURLWithPath: "/one"), name: "draft.txt"),
                     BatchRename.Entry(directory: URL(fileURLWithPath: "/two"), name: "draft.txt")]
        let splitSiblings = ["/one": Set(["draft.txt"]), "/two": Set(["draft.txt", "final.txt"])]
        check("the same new name in different directories is allowed",
              BatchRename.validate(["final.txt", "report.txt"], for: split, siblings: splitSiblings) == nil)
        let scoped = BatchRename.validate(["report.txt", "final.txt"], for: split, siblings: splitSiblings)
        check("collision is scoped to the item's own directory", scoped?.kind == .taken && scoped?.index == 1)

        let entry = BatchRename.Entry(url: URL(fileURLWithPath: "/parent/child/file.txt"))
        check("Entry derives directory and name from a URL",
              entry.name == "file.txt" && entry.directoryKey == "/parent/child")
    }

    // MARK: - The filesystem helper

    private static func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private static func operations(in fixture: URL) throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("ops")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        func reset(_ files: [String: String]) throws {
            for name in names(in: root) { try fm.removeItem(at: root.appendingPathComponent(name)) }
            for (name, content) in files { try Data(content.utf8).write(to: root.appendingPathComponent(name)) }
        }
        func request(_ name: String, _ newName: String) -> FileOperations.RenameRequest {
            .init(url: root.appendingPathComponent(name), newName: newName)
        }

        try reset(["a.txt": "A", "b.txt": "B", "c.txt": "C"])
        let chain = try FileOperations.renameBatch([request("a.txt", "b.txt"), request("b.txt", "c.txt"), request("c.txt", "d.txt")])
        check("chain a→b, b→c, c→d renames every item", names(in: root) == ["b.txt", "c.txt", "d.txt"], "\(names(in: root))")
        check("chain keeps each item's content",
              (try? String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8)) == "A"
              && (try? String(contentsOf: root.appendingPathComponent("d.txt"), encoding: .utf8)) == "C")
        check("chain returns (from, to) pairs in request order",
              chain.map { ($0.from.lastPathComponent, $0.to.lastPathComponent) }.map { "\($0)→\($1)" } == ["a.txt→b.txt", "b.txt→c.txt", "c.txt→d.txt"])
        let back = try FileOperations.reverseRenameBatch(chain)
        check("reverse-order replay restores the originals", names(in: root) == ["a.txt", "b.txt", "c.txt"] && back.count == 3, "\(names(in: root))")

        try reset(["a.txt": "A", "b.txt": "B"])
        _ = try FileOperations.renameBatch([request("a.txt", "b.txt"), request("b.txt", "a.txt")])
        check("swap exchanges two names",
              (try? String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)) == "B"
              && (try? String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8)) == "A")

        try reset(["a.txt": "A", "b.txt": "B", "c.txt": "C"])
        let cased = try FileOperations.renameBatch([request("a.txt", "A.txt"), request("b.txt", "b.txt")])
        check("case-only rename works on APFS and unchanged items are skipped",
              names(in: root) == ["A.txt", "b.txt", "c.txt"] && cased.count == 1, "\(names(in: root))")
        check("no-op batch returns no pairs", try FileOperations.renameBatch([request("c.txt", "c.txt")]).isEmpty)

        try reset(["a.txt": "A", "b.txt": "B", "c.txt": "C"])
        do {
            _ = try FileOperations.renameBatch([request("a.txt", "x.txt"), request("b.txt", "c.txt")])
            check("occupied final name is refused instead of overwriting", false, "no error")
        } catch {
            check("occupied final name is refused instead of overwriting", true, "\(error)")
        }
        check("failure rolls every item back",
              names(in: root) == ["a.txt", "b.txt", "c.txt"]
              && (try? String(contentsOf: root.appendingPathComponent("c.txt"), encoding: .utf8)) == "C", "\(names(in: root))")
        do {
            _ = try FileOperations.renameBatch([request("a.txt", "x.txt"), request("b.txt", "y/z.txt")])
            check("invalid name is refused before any change", false, "no error")
        } catch {
            check("invalid name is refused before any change", names(in: root) == ["a.txt", "b.txt", "c.txt"], "\(names(in: root))")
        }

        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
        let siblings = FileOperations.siblingNames(in: root)
        check("sibling names include hidden files per directory",
              siblings == Set([".hidden", "a.txt", "b.txt", "c.txt"]), "\(siblings.sorted())")
        let mapped = FileOperations.siblingNames(forEntries: [BatchRename.Entry(url: root.appendingPathComponent("a.txt"))])
        check("sibling map is keyed by directory path", mapped[root.path] == siblings, "\(mapped.keys)")
        try fm.removeItem(at: root)
    }

    // MARK: - The sheet, in both file views

    @MainActor private static func sheetFlow(mode: ViewMode, in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("ui-\(mode)")
        let other = fixture.appendingPathComponent("other-\(mode)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let originals = ["IMG_001.jpg", "IMG_002.jpg", "IMG_003.jpg"]
        for name in originals { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        try Data("dup".utf8).write(to: root.appendingPathComponent("dup.jpg"))

        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("\(mode)-views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                      viewPropertiesStore: store)
        defer { wc.close() }
        wc.window?.setContentSize(NSSize(width: 1000, height: 640))
        wc.window?.center()
        wc.window?.makeKeyAndOrderFront(nil)
        let browser = wc.browser
        await listed(browser, at: root)
        browser.setViewMode(mode)
        // A second pane on the same folder must follow the renamed items too.
        let peer = wc.tabs.currentPage.split(with: root)
        await listed(peer, at: root)
        wc.tabs.currentPage.activate(browser)
        // A filter that matches the names before and after the rename, so the
        // renamed items stay visible in a filtered, grouped pane.
        browser.nameFilter = "*.jpg"
        browser.setGroupKey(.kind)
        await waitUntil("\(mode) filter narrows the listing") { browser.model.items.count == originals.count + 1 }
        browser.fileView.select(names: originals)
        check("\(mode): three items are selected", browser.fileView.selectedItems.map(\.name) == originals, "\(browser.fileView.selectedItems.map(\.name))")

        // Menu wording and enablement
        let menuItem = NSMenuItem(title: "Rename", action: #selector(BrowserViewController.renameSelection(_:)), keyEquivalent: "")
        check("\(mode): three items enable Finder's plural title",
              browser.validateMenuItem(menuItem) && menuItem.title == "Rename 3 Items…", menuItem.title)
        let actionsItem = MainMenu.actionsMenu(target: wc).items.first { ($0.representedObject as? String) == MainMenu.FileAction.rename.rawValue }!
        check("\(mode): Actions menu Rename validates for several items",
              wc.validateMenuItem(actionsItem) && actionsItem.title == "Rename 3 Items…", actionsItem.title)
        let contextTitles = browser.buildContextMenu(for: browser.fileView.selectedItems).items.map(\.title)
        check("\(mode): context menu offers Rename 3 Items…", contextTitles.contains("Rename 3 Items…"), contextTitles.joined(separator: ","))

        // Return keeps the inline editor and never opens the sheet.
        browser.renameSelectionInline(nil)
        check("\(mode): Return path never opens the sheet for several items", browser.batchRenameSheet == nil)

        // File ▸ Rename
        check("\(mode): File ▸ Rename dispatches to the pane",
              NSApp.sendAction(#selector(BrowserViewController.renameSelection(_:)), to: browser, from: menuItem))
        guard let sheet = browser.batchRenameSheet, let sheetWindow = sheet.window else {
            check("\(mode): File ▸ Rename presents the sheet", false); return
        }
        check("\(mode): File ▸ Rename presents the sheet", true)
        check("\(mode): sheet is attached to the pane's window", sheetWindow.sheetParent === wc.window)
        check("\(mode): sheet title and default mode follow Finder",
              sheetWindow.title == "Rename Finder Items:" && sheet.modePopup.itemTitles == BatchRename.Mode.titles && sheet.modeIndex == 0)
        check("\(mode): sheet lists the selection in view order", sheet.previewRows.map(\.old) == originals, "\(sheet.previewRows.map(\.old))")
        check("\(mode): preview starts unchanged and Rename is enabled",
              sheet.previewRows.allSatisfy { $0.old == $0.new } && sheet.canRename && sheet.validationMessage == nil)
        check("\(mode): preview table shows one row per item", sheet.previewTable.numberOfRows == originals.count)

        sheet.type("IMG_", into: sheet.findField)
        check("\(mode): typing in Find updates the preview",
              sheet.previewRows.map(\.new) == ["001.jpg", "002.jpg", "003.jpg"], "\(sheet.previewRows.map(\.new))")
        sheet.type("Photo ", into: sheet.replaceField)
        check("\(mode): typing in Replace with updates the preview and the example",
              sheet.previewRows.map(\.new) == ["Photo 001.jpg", "Photo 002.jpg", "Photo 003.jpg"]
              && sheet.exampleLabel.stringValue == "Example: Photo 001.jpg", sheet.exampleLabel.stringValue)

        // Validation, live
        sheet.type("IMG_001", into: sheet.findField)
        sheet.type("dup", into: sheet.replaceField)
        check("\(mode): collision with a sibling disables Rename with the reason",
              !sheet.canRename && sheet.validationMessage == "The name “dup.jpg” is already taken. Please choose a different name.",
              sheet.validationMessage ?? "nil")
        sheet.performRename(nil)
        check("\(mode): Rename does nothing while invalid",
              browser.batchRenameSheet === sheet && names(in: root).contains("IMG_001.jpg"), "\(names(in: root))")
        sheet.type("IMG_002", into: sheet.replaceField)
        check("\(mode): duplicate within the batch disables Rename",
              !sheet.canRename && sheet.validationMessage == "The name “IMG_002.jpg” is already taken. Please choose a different name.",
              sheet.validationMessage ?? "nil")
        sheet.type("IMG_001.jpg", into: sheet.findField)
        sheet.type("", into: sheet.replaceField)
        check("\(mode): an empty name disables Rename",
              !sheet.canRename && sheet.validationMessage == "The name can’t be empty.", sheet.validationMessage ?? "nil")

        // The other two modes
        sheet.selectMode(1)
        sheet.type(" copy", into: sheet.addTextField)
        check("\(mode): Add Text shows its panel and keeps extensions",
              sheet.previewRows.map(\.new) == ["IMG_001 copy.jpg", "IMG_002 copy.jpg", "IMG_003 copy.jpg"], "\(sheet.previewRows.map(\.new))")
        sheet.selectMode(2)
        sheet.selectFormatKind(.nameAndDate)
        check("\(mode): Name and Date hides Start numbers at", !sheet.isStartNumberVisible)
        sheet.selectFormatKind(.nameAndCounter)
        sheet.type("Photo", into: sheet.customFormatField)
        sheet.type("7", into: sheet.startNumberField)
        check("\(mode): Name and Counter previews padded numbers",
              sheet.isStartNumberVisible && sheet.previewRows.map(\.new) == ["Photo 00007.jpg", "Photo 00008.jpg", "Photo 00009.jpg"],
              "\(sheet.previewRows.map(\.new))")

        // Apply
        sheet.selectMode(0)
        sheet.type("IMG_", into: sheet.findField)
        sheet.type("Photo ", into: sheet.replaceField)
        let renamed = ["Photo 001.jpg", "Photo 002.jpg", "Photo 003.jpg"]
        sheet.performRename(nil)
        await waitUntil("\(mode) batch rename lands on disk") { Set(names(in: root)).isSuperset(of: renamed) }
        check("\(mode): Rename applies every name on disk",
              names(in: root) == (renamed + ["dup.jpg"]).sorted(), "\(names(in: root))")
        check("\(mode): the sheet is dismissed", browser.batchRenameSheet == nil && sheet.isDismissed)
        await waitUntil("\(mode) renamed items are reselected",
                        detail: { "\(browser.fileView.selectedItems.map(\.name))" }) {
            browser.fileView.selectedItems.map(\.name).sorted() == renamed
        }
        check("\(mode): renamed items stay selected in the active pane",
              browser.fileView.selectedItems.map(\.name).sorted() == renamed, "\(browser.fileView.selectedItems.map(\.name))")
        check("\(mode): filter and groups survive the rename",
              browser.nameFilter == "*.jpg" && browser.groupKey == .kind && browser.viewMode == mode)
        await waitUntil("\(mode) the other pane follows the renamed items") {
            Set(peer.model.items.map(\.name)).isSuperset(of: renamed)
        }
        check("\(mode): the other pane follows the renamed selection", true)

        // Undo / redo, one group for the whole batch
        guard let undo = wc.window?.undoManager else { check("\(mode): the window has an undo manager", false); return }
        check("\(mode): undo names the batch Rename as one group", undo.canUndo && undo.undoActionName == "Rename", undo.undoActionName)
        undo.undo()
        await waitUntil("\(mode) undo restores the original names") { Set(names(in: root)).isSuperset(of: originals) }
        check("\(mode): ⌘Z restores all original names", names(in: root) == (originals + ["dup.jpg"]).sorted(), "\(names(in: root))")
        await waitUntil("\(mode) undo reselects the originals",
                        detail: { "\(browser.fileView.selectedItems.map(\.name))" }) {
            browser.fileView.selectedItems.map(\.name).sorted() == originals
        }
        check("\(mode): undo reselects the originals",
              browser.fileView.selectedItems.map(\.name).sorted() == originals, "\(browser.fileView.selectedItems.map(\.name))")
        check("\(mode): redo is available", undo.canRedo)
        undo.redo()
        await waitUntil("\(mode) redo reapplies the batch") { Set(names(in: root)).isSuperset(of: renamed) }
        check("\(mode): redo reapplies the batch", names(in: root) == (renamed + ["dup.jpg"]).sorted(), "\(names(in: root))")
        undo.undo()
        await waitUntil("\(mode) a second undo restores the originals") { Set(names(in: root)).isSuperset(of: originals) }
        check("\(mode): a second undo restores the originals again", names(in: root) == (originals + ["dup.jpg"]).sorted(), "\(names(in: root))")

        // The context-menu entry presents the same sheet; Cancel changes nothing.
        await waitUntil("\(mode) the selection settles before the context menu") {
            browser.fileView.selectedItems.map(\.name).sorted() == originals
        }
        let contextItem = browser.buildContextMenu(for: browser.fileView.selectedItems).items.first { $0.title == "Rename 3 Items…" }
        guard let contextItem, let contextAction = contextItem.action else {
            check("\(mode): context menu carries a batch rename action", false); return
        }
        check("\(mode): context menu dispatch reaches the pane", NSApp.sendAction(contextAction, to: browser, from: contextItem))
        guard let second = browser.batchRenameSheet else {
            check("\(mode): context menu presents the sheet for the clicked items", false); return
        }
        check("\(mode): context menu presents the sheet for the clicked items", second.previewRows.map(\.old).sorted() == originals)
        second.cancelRename(nil)
        check("\(mode): Cancel closes the sheet without renaming",
              browser.batchRenameSheet == nil && second.isDismissed
              && names(in: root) == (originals + ["dup.jpg"]).sorted(), "\(names(in: root))")
    }

    // MARK: - Search results (items in different directories)

    @MainActor private static func searchResults(in fixture: URL) async throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("search")
        let one = root.appendingPathComponent("one")
        let two = root.appendingPathComponent("two")
        for url in [one, two] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("one".utf8).write(to: one.appendingPathComponent("draft.txt"))
        try Data("two".utf8).write(to: two.appendingPathComponent("draft.txt"))
        try Data("existing".utf8).write(to: two.appendingPathComponent("final.txt"))

        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("search-views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                      viewPropertiesStore: store)
        defer { wc.close() }
        wc.window?.setContentSize(NSSize(width: 1000, height: 640))
        wc.window?.makeKeyAndOrderFront(nil)
        let browser = wc.browser
        await listed(browser, at: root)
        browser.startSearch(SearchRequest(rootURL: root, name: "draft"))
        await waitUntil("search results arrive") {
            browser.isSearching && !browser.searchSession.status.isSearching && browser.model.items.count == 2
        }
        let drafts = browser.model.items.map(\.url).sorted { $0.path < $1.path }
        check("search: both drafts are results", drafts.count == 2 && drafts.allSatisfy { $0.lastPathComponent == "draft.txt" },
              "\(drafts.map(\.path))")
        browser.fileView.select(urls: drafts)
        await waitUntil("both results are selected") {
            browser.fileView.selectedItems.count == 2 && browser.fileView.selectedItems.allSatisfy { $0.name == "draft.txt" }
        }

        // final.txt exists in "two" only: the collision is scoped to that folder.
        check("search: the sheet opens on results", browser.presentBatchRename(for: browser.fileView.selectedItems) != nil)
        guard let sheet = browser.batchRenameSheet else { check("search: sheet present", false); return }
        sheet.type("draft", into: sheet.findField)
        sheet.type("final", into: sheet.replaceField)
        check("search: collision is scoped to the result's own directory (two/final.txt exists)",
              !sheet.canRename && sheet.validationMessage == "The name “final.txt” is already taken. Please choose a different name.",
              sheet.validationMessage ?? "nil")
        sheet.cancelRename(nil)

        try fm.removeItem(at: two.appendingPathComponent("final.txt"))
        browser.fileView.select(urls: drafts)
        await waitUntil("the results are selected again") {
            browser.fileView.selectedItems.count == 2 && browser.fileView.selectedItems.allSatisfy { $0.name == "draft.txt" }
        }
        _ = browser.presentBatchRename(for: browser.fileView.selectedItems)
        guard let second = browser.batchRenameSheet else { check("search: second sheet present", false); return }
        second.type("draft", into: second.findField)
        second.type("final", into: second.replaceField)
        check("search: the same name in two directories is allowed",
              second.canRename && second.previewRows.map(\.new) == ["final.txt", "final.txt"],
              second.validationMessage ?? "\(second.previewRows.map(\.new))")
        second.performRename(nil)
        await waitUntil("search results rename on disk") {
            fm.fileExists(atPath: one.appendingPathComponent("final.txt").path)
                && fm.fileExists(atPath: two.appendingPathComponent("final.txt").path)
        }
        check("search: results rename in their own directories",
              names(in: one) == ["final.txt"] && names(in: two) == ["final.txt"], "\(names(in: one)) \(names(in: two))")
        await waitUntil("the search reruns after the rename") { !browser.searchSession.status.isSearching }
        check("search: still searching after the rename", browser.isSearching && browser.model.isSearchResults)

        guard let undo = wc.window?.undoManager else { check("search: the window has an undo manager", false); return }
        undo.undo()
        await waitUntil("search undo restores both drafts") {
            fm.fileExists(atPath: one.appendingPathComponent("draft.txt").path)
                && fm.fileExists(atPath: two.appendingPathComponent("draft.txt").path)
        }
        check("search: undo restores both drafts",
              names(in: one) == ["draft.txt"] && names(in: two) == ["draft.txt"], "\(names(in: one)) \(names(in: two))")
    }

    // MARK: - Helpers

    @MainActor private static func listed(_ pane: BrowserViewController, at url: URL) async {
        await waitUntil("directory listing", detail: { "\(pane.currentURL?.path ?? "nil") vs \(url.path)" }) {
            pane.currentURL?.standardizedFileURL == url.standardizedFileURL
                && pane.model.url?.standardizedFileURL == url.standardizedFileURL
                && pane.model.generation > 0 && !pane.isPreparingArchive && !pane.model.isSearchResults
        }
    }

}

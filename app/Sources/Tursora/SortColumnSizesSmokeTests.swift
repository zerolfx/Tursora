import AppKit

/// The three date sort keys, the optional list columns and folder sizes:
/// the pure comparator and wording first, then the stored column set, then the
/// real list — header menu, Size column text, Size sorting and cancellation.
enum SortColumnSizesSmokeTests: SmokeSuite {
    static let checkPrefix = "sort/columns/sizes: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            print("== sort keys, list columns and folder sizes ==")
            comparatorDates()
            sortKeyCatalog()
            itemCountWording()
            menus()
            do {
                let fixture = try SmokeFixtures.temporaryDirectory("sort-columns-sizes")
                    .resolvingSymlinksInPath()
                defer { try? FileManager.default.removeItem(at: fixture) }
                try columnPersistence(fixture: fixture)
                let dates = try makeDateFixture(fixture)
                let sizes = try makeSizeFixture(fixture)
                try await folderMetrics(sizes)
                try await cancellation(sizes)
                try await sorting(dates)
                try await listColumns(dates)
                try await sizeColumn(sizes, other: dates)
                completion()
            } catch let failure as SmokeFailure {
                fail(failure.description)
            } catch {
                fail("fixtures complete", error.localizedDescription)
            }
        }
    }

    // MARK: - Pure comparator

    /// `DirectoryModel.compareDates` is the whole rule for the three keys
    /// Finder added after Date Modified: equal dates fall back to the name,
    /// and an item with no date stays at the bottom in *both* directions.
    private static func comparatorDates() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        func order(_ a: Date?, _ b: Date?, nameAscending: Bool = true, ascending: Bool = true) -> Bool {
            DirectoryModel.compareDates(a, b, nameAscending: nameAscending, ascending: ascending)
        }
        check("an earlier date leads when ascending", order(early, late))
        check("an earlier date follows when descending", !order(early, late, ascending: false))
        check("a later date leads when descending", order(late, early, ascending: false))
        check("equal dates fall back to the name", order(early, early) && !order(early, early, nameAscending: false))
        check("the name tie-break reverses with the sort direction",
              !order(early, early, ascending: false) && order(early, early, nameAscending: false, ascending: false))
        check("an item with no date never leads an item that has one",
              !order(nil, early) && !order(nil, early, ascending: false))
        check("an item with a date always leads one without",
              order(early, nil) && order(early, nil, ascending: false))
        check("two undated items fall back to the name in both directions",
              order(nil, nil) && !order(nil, nil, ascending: false)
              && !order(nil, nil, nameAscending: false) && order(nil, nil, nameAscending: false, ascending: false))
        check("the comparator is strict: nothing precedes itself under either rule",
              !(order(early, early) && order(early, early, nameAscending: false)))
    }

    /// The raw values are what `DirectoryViewProperties` stores and what the
    /// menus carry, so they must stay stable and match `GroupKey`'s spelling.
    private static func sortKeyCatalog() {
        for raw in ["dateCreated", "dateAdded", "dateLastOpened"] {
            check("\(raw) is a sort key", DirectoryModel.SortKey(rawValue: raw) != nil)
            check("\(raw) is spelled like the group key of the same name", GroupKey(rawValue: raw) != nil)
        }
        check("an unknown sort key is not invented", DirectoryModel.SortKey(rawValue: "dateBurned") == nil)
    }

    /// Finder's `I_ITEMS_V2` / `I_ITEMS_V1` wording.
    private static func itemCountWording() {
        check("an empty folder reads \"0 items\"", FolderSizes.itemCountText(0) == "0 items")
        check("one child reads \"1 item\"", FolderSizes.itemCountText(1) == "1 item")
        check("several children read \"N items\"", FolderSizes.itemCountText(7) == "7 items")
        check("a folder's calculated size uses the file byte formatter",
              FolderSizes.byteSizeText(5_000)
              == ByteCountFormatter.string(fromByteCount: 5_000, countStyle: .file))
    }

    // MARK: - Menus

    @MainActor private static func menus() {
        guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu,
              let sort = view.items.first(where: { $0.title == "Sort By" })?.submenu else {
            fail("the View menu carries Sort By")
        }
        let titles = sort.items.filter { $0.action == #selector(MainWindowController.sortBy(_:)) }.map(\.title)
        check("View ▸ Sort By offers Finder's seven keys",
              titles == ["Name", "Date Modified", "Date Created", "Date Last Opened", "Date Added", "Size", "Kind"],
              titles.joined(separator: ", "))
        for (title, raw) in [("Date Created", "dateCreated"), ("Date Last Opened", "dateLastOpened"),
                             ("Date Added", "dateAdded")] {
            check("Sort By ▸ \(title) carries \(raw)",
                  sort.items.first { $0.title == title }?.representedObject as? String == raw)
        }
        guard let settings = view.items.first(where: { $0.title == "Folder View Settings" })?.submenu else {
            fail("View ▸ Folder View Settings exists")
        }
        check("Folder View Settings carries Finder's \"Calculate all sizes\"",
              settings.items.contains { $0.title == "Calculate all sizes"
                  && $0.action == #selector(MainWindowController.toggleCalculateAllSizes(_:)) },
              settings.items.map(\.title).joined(separator: ", "))
        let columns = FileListViewController.optionalColumns.map(\.title)
        check("the optional columns are Finder's, in Finder's Show Columns order",
              columns == ["Date Modified", "Date Created", "Date Last Opened", "Date Added", "Size", "Kind"],
              columns.joined(separator: ", "))
    }

    // MARK: - Stored columns

    private static func columnPersistence(fixture: URL) throws {
        var properties = DirectoryViewProperties()
        check("a folder starts with Finder's three default columns beside Name",
              properties.listColumns == ["dateModified", "kind", "size"], properties.listColumns.joined(separator: ", "))
        check("\"Calculate all sizes\" is off by default", !properties.calculateAllSizes)

        let file = fixture.appendingPathComponent("columns.json")
        let store = DirectoryViewPropertiesStore(fileURL: file)
        properties.listColumns = ["size", "dateAdded", "dateCreated"]
        properties.calculateAllSizes = true
        properties.sortKey = .dateLastOpened
        properties.ascending = false
        store.save(properties, forKey: "/fixture")
        try store.flush()

        let reopened = DirectoryViewPropertiesStore(fileURL: file)
        let read = reopened.properties(forKey: "/fixture")
        check("the visible column set survives a store round-trip",
              read.listColumns == ["dateAdded", "dateCreated", "size"], read.listColumns.joined(separator: ", "))
        check("\"Calculate all sizes\" survives a store round-trip", read.calculateAllSizes)
        check("a new sort key survives a store round-trip",
              read.sortKey == .dateLastOpened && !read.ascending, read.sortKey.rawValue)
        var reordered = properties
        reordered.listColumns = ["dateCreated", "size", "dateAdded"]
        store.save(reordered, forKey: "/fixture")
        check("a column set is stored the same however it was ordered",
              store.properties(forKey: "/fixture") == read,
              store.properties(forKey: "/fixture").listColumns.joined(separator: ", "))

        // A record written before columns were optional carries neither key.
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(properties)) as? [String: Any] ?? [:]
        object.removeValue(forKey: "listColumns")
        object.removeValue(forKey: "calculateAllSizes")
        let legacy = try JSONDecoder().decode(
            DirectoryViewProperties.self, from: JSONSerialization.data(withJSONObject: object))
        check("a record written by the current version still loads",
              legacy.sortKey == .dateLastOpened && !legacy.ascending && legacy.viewMode == properties.viewMode)
        check("it falls back to the default columns and no size calculation",
              legacy.listColumns == DirectoryViewProperties.defaultListColumns && !legacy.calculateAllSizes,
              legacy.listColumns.joined(separator: ", "))

        object["listColumns"] = ["dateCreated", "tags", "dateCreated"]
        object["sortKey"] = "dateInvented"
        let tolerant = try JSONDecoder().decode(
            DirectoryViewProperties.self, from: JSONSerialization.data(withJSONObject: object))
        check("an unknown sort key falls back to Name", tolerant.sortKey == .name)
        check("a duplicated column is stored once", tolerant.listColumns == ["dateCreated", "tags"],
              tolerant.listColumns.joined(separator: ", "))
    }

    // MARK: - Fixtures

    private struct DateFixture {
        let root: URL
        let store: URL
    }

    private struct SizeFixture {
        let root: URL
        let store: URL
        let empty: URL
        let wide: URL
        let deep: URL
        /// Bytes the recursive walk must report for `wide` and `deep`.
        let wideBytes: Int64
        let deepBytes: Int64
    }

    /// Access and creation times are set explicitly; `addedToDirectoryDate` is
    /// the kernel's and cannot be, so every expectation below is computed from
    /// the items the model actually listed.
    private static func setTimes(_ url: URL, created: Date, accessed: Date) throws {
        var times = [timeval(tv_sec: Int(accessed.timeIntervalSince1970), tv_usec: 0),
                     timeval(tv_sec: Int(accessed.timeIntervalSince1970), tv_usec: 0)]
        _ = utimes(url.path, &times)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
    }

    private static func makeDateFixture(_ fixture: URL) throws -> DateFixture {
        let manager = FileManager.default
        let root = fixture.appendingPathComponent("dates", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Creation and access order deliberately disagree with the name order.
        let plan: [(String, Bool, TimeInterval, TimeInterval)] = [
            ("Alpha", true, 3_000, 1_000),
            ("Beta", true, 1_000, 3_000),
            ("delta.txt", false, 4_000, 1_000),
            ("epsilon.txt", false, 1_000, 3_000),
            ("gamma.txt", false, 2_000, 4_000),
        ]
        for (name, isDirectory, created, accessed) in plan {
            let url = root.appendingPathComponent(name, isDirectory: isDirectory)
            if isDirectory {
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data(repeating: 0x61, count: 8).write(to: url)
            }
            try setTimes(url, created: base.addingTimeInterval(created),
                         accessed: base.addingTimeInterval(accessed))
        }
        return DateFixture(root: root, store: fixture.appendingPathComponent("dates-views.json"))
    }

    private static func makeSizeFixture(_ fixture: URL) throws -> SizeFixture {
        let manager = FileManager.default
        let root = fixture.appendingPathComponent("sizes", isDirectory: true)
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        let wide = root.appendingPathComponent("Wide", isDirectory: true)
        let deep = root.appendingPathComponent("Deep", isDirectory: true)
        let inner = deep.appendingPathComponent("inner", isDirectory: true)
        for url in [empty, wide, inner] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for index in 1...4 {
            try Data(repeating: 0x62, count: 1).write(to: wide.appendingPathComponent("a\(index).txt"))
        }
        try Data(repeating: 0x63, count: 2).write(to: wide.appendingPathComponent(".hidden"))
        try Data(repeating: 0x64, count: 5_000).write(to: inner.appendingPathComponent("big.bin"))
        // A symlink is counted as an entry but contributes no bytes.
        try manager.createSymbolicLink(at: wide.appendingPathComponent("link"),
                                       withDestinationURL: inner.appendingPathComponent("big.bin"))
        try Data(repeating: 0x65, count: 9_000).write(to: root.appendingPathComponent("zfile.bin"))
        return SizeFixture(root: root, store: fixture.appendingPathComponent("sizes-views.json"),
                           empty: empty, wide: wide, deep: deep, wideBytes: 6, deepBytes: 5_000)
    }

    // MARK: - The calculator on its own

    @MainActor private static func folderMetrics(_ fixture: SizeFixture) async throws {
        guard let empty = FileItem(url: fixture.empty), let wide = FileItem(url: fixture.wide),
              let deep = FileItem(url: fixture.deep) else { fail("the size fixture lists") }

        let counts = FolderSizes()
        var updates = 0
        counts.onUpdate = { updates += 1 }
        counts.request([empty, wide, deep], allowsRecursiveSizes: true)
        await expectEventually("item counts arrive for every folder", detail: {
            "empty=\(String(describing: counts.metrics(for: empty)))"
        }) {
            counts.metrics(for: empty)?.itemCount != nil && counts.metrics(for: wide)?.itemCount != nil
                && counts.metrics(for: deep)?.itemCount != nil
        }
        check("an empty folder counts nothing", counts.metrics(for: empty)?.itemCount == 0)
        check("a count skips dotfiles and includes symlinks",
              counts.metrics(for: wide)?.itemCount == 5, "\(counts.metrics(for: wide)?.itemCount ?? -1)")
        check("a folder holding one subfolder counts one item", counts.metrics(for: deep)?.itemCount == 1)
        check("counts arrive without calculating sizes",
              counts.metrics(for: wide)?.byteSize == nil && counts.metrics(for: deep)?.byteSize == nil)
        check("the Size column shows the count while sizes are off",
              counts.displaySize(for: wide) == "5 items" && counts.displaySize(for: deep) == "1 item"
              && counts.displaySize(for: empty) == "0 items")
        check("counts alone order a Size sort", counts.sortValue(for: empty) == 0
              && counts.sortValue(for: deep) == 1 && counts.sortValue(for: wide) == 5)
        check("the calculator reported its results at least once", updates > 0)

        // Turning the option on measures the same folders recursively.
        counts.calculatesAllSizes = true
        await expectEventually("recursive sizes arrive once \"Calculate all sizes\" is on", detail: {
            "wide=\(String(describing: counts.metrics(for: wide)?.byteSize)), "
            + "deep=\(String(describing: counts.metrics(for: deep)?.byteSize))"
        }) {
            counts.metrics(for: wide)?.byteSize != nil && counts.metrics(for: deep)?.byteSize != nil
                && counts.metrics(for: empty)?.byteSize != nil
        }
        check("the walk skips symlinks and counts hidden bytes",
              counts.metrics(for: wide)?.byteSize == fixture.wideBytes,
              "\(counts.metrics(for: wide)?.byteSize ?? -1)")
        check("the walk descends into subfolders",
              counts.metrics(for: deep)?.byteSize == fixture.deepBytes,
              "\(counts.metrics(for: deep)?.byteSize ?? -1)")
        check("an empty folder measures zero bytes", counts.metrics(for: empty)?.byteSize == 0)
        check("the Size column switches to the calculated size",
              counts.displaySize(for: deep) == FolderSizes.byteSizeText(fixture.deepBytes),
              counts.displaySize(for: deep))
        check("a Size sort now compares bytes, not counts",
              counts.sortValue(for: wide) == fixture.wideBytes && counts.sortValue(for: deep) == fixture.deepBytes)
        check("a file keeps its own size in both modes",
              counts.displaySize(for: FileItem(url: fixture.root.appendingPathComponent("zfile.bin"))!)
              == ByteCountFormatter.string(fromByteCount: 9_000, countStyle: .file))

        // ZIP listings and search results get counts only.
        let listing = FolderSizes()
        listing.calculatesAllSizes = true
        listing.allowsRecursiveSizes = false
        listing.request([deep], allowsRecursiveSizes: true)
        await expectEventually("a refused listing still counts its folders") {
            listing.metrics(for: deep)?.itemCount == 1
        }
        check("a ZIP listing never walks a folder recursively", listing.metrics(for: deep)?.byteSize == nil)
        check("it still shows Finder's item count", listing.displaySize(for: deep) == "1 item")

        let results = FolderSizes()
        results.calculatesAllSizes = true
        results.request([deep], allowsRecursiveSizes: false)
        await expectEventually("search results count their folders") {
            results.metrics(for: deep)?.itemCount == 1
        }
        check("search results never walk a folder recursively", results.metrics(for: deep)?.byteSize == nil)
    }

    /// Navigating away must stop the walk, and the result it was about to
    /// deliver must never land in the directory the user moved to.
    @MainActor private static func cancellation(_ fixture: SizeFixture) async throws {
        guard let deep = FileItem(url: fixture.deep), let wide = FileItem(url: fixture.wide) else {
            fail("the size fixture lists for cancellation")
        }
        let sizes = FolderSizes()
        sizes.calculatesAllSizes = true
        // The option's own "redraw the column" notification is not a result;
        // let it land before counting what the cancelled walk delivers.
        await drainMainQueue()
        var updates = 0
        sizes.onUpdate = { updates += 1 }
        sizes.request([deep], allowsRecursiveSizes: true)
        sizes.cancel()
        // Long enough for the worker to finish the small fixture and try to
        // deliver; the generation check is what must drop it.
        try await Task.sleep(nanoseconds: 400_000_000)
        await drainMainQueue()
        check("a cancelled walk delivers no metrics", sizes.metrics(for: deep) == nil)
        check("a cancelled walk reports no update", updates == 0, "\(updates) updates")

        sizes.request([wide], allowsRecursiveSizes: true)
        await expectEventually("the next directory's folders still get measured") {
            sizes.metrics(for: wide)?.byteSize == fixture.wideBytes
        }
        check("the cancelled folder never arrives late in the new listing", sizes.metrics(for: deep) == nil)

        sizes.reset()
        check("a reset forgets every measured folder",
              sizes.metrics(for: wide) == nil && sizes.displaySize(for: wide) == "--")
    }

    // MARK: - Sorting in both views

    @MainActor private static func sorting(_ fixture: DateFixture) async throws {
        let store = DirectoryViewPropertiesStore(fileURL: fixture.store)
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(),
                                      initialURL: fixture.root, viewPropertiesStore: store)
        defer { wc.close() }
        wc.window?.setContentSize(NSSize(width: 1100, height: 640))
        wc.window?.makeKeyAndOrderFront(nil)
        await listed(wc.browser, at: fixture.root)
        let browser = wc.browser
        check("the date fixture listed every entry", browser.model.items.count == 5,
              browser.model.items.map(\.name).joined(separator: ", "))

        for mode: ViewMode in [.details, .icons] {
            browser.setViewMode(mode)
            for (key, date) in Self.dateKeys {
                for ascending in [true, false] {
                    browser.fileList.setSort(key: key, ascending: ascending)
                    await drainMainQueue()
                    let shown = browser.model.items
                    let expected = expectedOrder(browser.model.allNodes.map(\.item), date: date, ascending: ascending)
                    check("\(mode)/\(key.rawValue)/\(ascending ? "ascending" : "descending"): the listing follows the key",
                          shown.map(\.name) == expected.map(\.name),
                          "got \(shown.map(\.name)) want \(expected.map(\.name))")
                    check("\(mode)/\(key.rawValue)/\(ascending ? "ascending" : "descending"): folders still lead",
                          shown.prefix(2).allSatisfy(\.isNavigable),
                          shown.map { "\($0.name)\($0.isNavigable ? "/" : "")" }.joined(separator: ", "))
                }
            }
        }

        browser.setViewMode(.details)
        browser.fileList.setSort(key: .dateCreated, ascending: true)
        await drainMainQueue()
        check("the fixture's creation dates really were set apart",
              Set(browser.model.items.map { $0.creationDate?.timeIntervalSince1970 ?? 0 }).count >= 3,
              browser.model.items.map { "\($0.name)=\($0.creationDate?.description ?? "nil")" }.joined(separator: ", "))
        check("Date Created is not the same order as Name",
              browser.model.items.map(\.name) != browser.model.items.map(\.name).sorted(),
              browser.model.items.map(\.name).joined(separator: ", "))
        check("the header indicator follows the model's key",
              browser.fileList.tableView.sortDescriptors.first?.key == "dateCreated")

        // The header itself drives the same change, as a real click would.
        guard let column = browser.fileList.tableView.tableColumn(
            withIdentifier: FileListViewController.Column.dateAdded.id) else {
            fail("the Date Added column exists")
        }
        browser.fileList.tableView.sortDescriptors = [NSSortDescriptor(key: column.identifier.rawValue, ascending: false)]
        await drainMainQueue()
        check("clicking a date header re-sorts the model",
              browser.model.sortKey == .dateAdded && !browser.model.ascending,
              "\(browser.model.sortKey.rawValue) ascending=\(browser.model.ascending)")

        // The context menu offers the same keys and dispatches through the pane.
        let menu = browser.buildContextMenu(for: [])
        guard let sort = menu.items.first(where: { $0.title == "Sort By" })?.submenu else {
            fail("the context menu carries Sort By")
        }
        let titles = sort.items.filter { $0.action != nil && $0.title != "Ascending" }.map(\.title)
        check("the context menu offers the same seven keys",
              titles == ["Name", "Date Modified", "Date Created", "Date Last Opened", "Date Added", "Size", "Kind"],
              titles.joined(separator: ", "))
        guard let index = sort.items.firstIndex(where: { $0.title == "Date Last Opened" }) else {
            fail("the context menu carries Date Last Opened")
        }
        sort.performActionForItem(at: index)
        await drainMainQueue()
        check("the context menu's Date Last Opened reaches the model",
              browser.model.sortKey == .dateLastOpened, browser.model.sortKey.rawValue)

        // The window menu's own Sort By command, through its real validation.
        guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu,
              let windowSort = view.items.first(where: { $0.title == "Sort By" })?.submenu,
              let created = windowSort.items.first(where: { $0.title == "Date Created" }),
              let action = created.action else { fail("View ▸ Sort By ▸ Date Created exists") }
        let validated = windowSort.items
            .filter { $0.action == #selector(MainWindowController.sortBy(_:)) }
            .allSatisfy { wc.validateMenuItem($0) }
        check("View ▸ Sort By checks the model's current key and nothing else",
              validated && windowSort.items.first { $0.title == "Date Last Opened" }?.state == .on
              && windowSort.items.first { $0.title == "Name" }?.state == .off,
              windowSort.items.filter { $0.state == .on }.map(\.title).joined(separator: ", "))
        check("View ▸ Sort By ▸ Date Created dispatches to the window",
              NSApp.sendAction(action, to: wc, from: created))
        await drainMainQueue()
        check("it changes the model's key", browser.model.sortKey == .dateCreated)
    }

    /// The three keys this suite adds, with the field each one reads.
    private static let dateKeys: [(DirectoryModel.SortKey, KeyPath<FileItem, Date?>)] = [
        (.dateCreated, \FileItem.creationDate),
        (.dateAdded, \FileItem.addedDate),
        (.dateLastOpened, \FileItem.accessDate),
    ]

    /// The order the model should produce: folders first, then the key, with
    /// undated items last and the name as the tie-break.
    private static func expectedOrder(_ items: [FileItem], date: KeyPath<FileItem, Date?>,
                                      ascending: Bool) -> [FileItem] {
        items.sorted { a, b in
            if a.isNavigable != b.isNavigable { return a.isNavigable }
            let nameOrder = a.name.localizedStandardCompare(b.name)
            let nameAscending = nameOrder == .orderedSame
                ? a.url.path.compare(b.url.path) == .orderedAscending : nameOrder == .orderedAscending
            return DirectoryModel.compareDates(a[keyPath: date], b[keyPath: date],
                                               nameAscending: nameAscending, ascending: ascending)
        }
    }

    // MARK: - The header menu and the stored column set

    @MainActor private static func listColumns(_ fixture: DateFixture) async throws {
        let store = DirectoryViewPropertiesStore(fileURL: fixture.store.deletingLastPathComponent()
            .appendingPathComponent("columns-views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(),
                                      initialURL: fixture.root, viewPropertiesStore: store)
        defer { wc.close() }
        wc.window?.setContentSize(NSSize(width: 1100, height: 640))
        wc.window?.makeKeyAndOrderFront(nil)
        await listed(wc.browser, at: fixture.root)
        let list = wc.browser.fileList
        _ = list.view

        func isHidden(_ column: FileListViewController.Column) -> Bool {
            list.tableView.tableColumn(withIdentifier: column.id)?.isHidden ?? true
        }
        check("the list still has a header to right-click", list.tableView.headerView != nil)
        check("the header's menu is its own, not the file context menu",
              list.tableView.headerView?.menu === list.headerMenu.menu
              && list.tableView.headerView?.menu !== list.tableView.menu)
        check("Name, Date Modified, Size and Kind start visible",
              !isHidden(.name) && !isHidden(.dateModified) && !isHidden(.size) && !isHidden(.kind))
        check("the three new date columns start hidden",
              isHidden(.dateCreated) && isHidden(.dateAdded) && isHidden(.dateLastOpened))
        check("Location stays hidden outside search results", isHidden(.location))

        let menu = list.headerMenu.menu
        list.headerMenu.rebuild()
        check("the header menu lists every optional column plus the size option",
              menu.items.map(\.title) == ["Date Modified", "Date Created", "Date Last Opened", "Date Added",
                                          "Size", "Kind", "", "Calculate all sizes"],
              menu.items.map(\.title).joined(separator: " | "))
        check("Name and Location are never offered",
              !menu.items.contains { $0.title == "Name" || $0.title == "Location" })
        check("a shown column is checked and a hidden one is not",
              menu.items.first { $0.title == "Size" }?.state == .on
              && menu.items.first { $0.title == "Date Created" }?.state == .off)

        guard let createdIndex = menu.items.firstIndex(where: { $0.title == "Date Created" }) else {
            fail("the header menu offers Date Created")
        }
        menu.performActionForItem(at: createdIndex)
        check("choosing Date Created shows the column",
              !isHidden(.dateCreated) && list.visibleColumns.contains("dateCreated"))
        list.headerMenu.menuNeedsUpdate(menu)
        check("reopening the menu shows its checkmark",
              menu.items.first { $0.title == "Date Created" }?.state == .on)

        guard let kindIndex = menu.items.firstIndex(where: { $0.title == "Kind" }) else {
            fail("the header menu offers Kind")
        }
        menu.performActionForItem(at: kindIndex)
        check("choosing a shown column hides it",
              isHidden(.kind) && !list.visibleColumns.contains("kind"))
        list.headerMenu.menuNeedsUpdate(menu)
        check("its checkmark clears", menu.items.first { $0.title == "Kind" }?.state == .off)

        await expectEventually("the column set is remembered for this folder", detail: {
            store.properties(forKey: DirectoryViewPropertiesStore.directoryKey(for: fixture.root) ?? "")
                .listColumns.joined(separator: ", ")
        }) {
            store.properties(forKey: DirectoryViewPropertiesStore.directoryKey(for: fixture.root) ?? "")
                .listColumns == ["dateCreated", "dateModified", "size"]
        }

        // Navigating away and back restores it; a sibling keeps the default.
        let sibling = fixture.root.deletingLastPathComponent()
        wc.browser.navigate(to: sibling)
        await listed(wc.browser, at: sibling)
        check("a folder with no record keeps the default columns",
              isHidden(.dateCreated) && !isHidden(.kind),
              list.visibleColumns.sorted().joined(separator: ", "))
        wc.browser.navigate(to: fixture.root)
        await listed(wc.browser, at: fixture.root)
        check("returning restores the remembered columns",
              !isHidden(.dateCreated) && isHidden(.kind),
              list.visibleColumns.sorted().joined(separator: ", "))

        check("a stored set with an unknown identifier is ignored, not obeyed",
              { list.setVisibleColumns(["size", "tags"])
                return list.visibleColumns == ["size"] }(), list.visibleColumns.sorted().joined(separator: ", "))
        check("the Name column can never be hidden",
              { list.setColumn(.name, visible: false); return !isHidden(.name) }())

        // "Use Current Settings as Default" carries the columns to new folders.
        list.setVisibleColumns(["dateAdded", "size"])
        wc.browser.useCurrentViewAsDefault()
        check("the default view now carries the column set",
              store.defaultProperties.listColumns == ["dateAdded", "size"],
              store.defaultProperties.listColumns.joined(separator: ", "))
        wc.browser.restoreDirectoryViewDefaults()
        await drainMainQueue()
        check("restoring this folder to the default applies them",
              !isHidden(.dateAdded) && isHidden(.dateCreated) && isHidden(.kind),
              list.visibleColumns.sorted().joined(separator: ", "))
    }

    // MARK: - The Size column in the real list

    @MainActor private static func sizeColumn(_ fixture: SizeFixture, other: DateFixture) async throws {
        let store = DirectoryViewPropertiesStore(fileURL: fixture.store)
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(),
                                      initialURL: fixture.root, viewPropertiesStore: store)
        defer { wc.close() }
        wc.window?.setContentSize(NSSize(width: 1100, height: 640))
        wc.window?.makeKeyAndOrderFront(nil)
        await listed(wc.browser, at: fixture.root)
        let browser = wc.browser
        let list = browser.fileList
        _ = list.view

        func sizeText(_ name: String) -> String? {
            let column = list.tableView.column(withIdentifier: FileListViewController.Column.size.id)
            guard column >= 0 else { return nil }
            for row in 0..<list.tableView.numberOfRows
            where (list.tableView.item(atRow: row) as? FileNode)?.item.name == name {
                return (list.tableView.view(atColumn: column, row: row, makeIfNecessary: true)
                    as? NSTableCellView)?.textField?.stringValue
            }
            return nil
        }

        await expectEventually("folders show Finder's item count instead of \"--\"", detail: {
            "Empty=\(sizeText("Empty") ?? "nil") Wide=\(sizeText("Wide") ?? "nil") Deep=\(sizeText("Deep") ?? "nil")"
        }) {
            sizeText("Empty") == "0 items" && sizeText("Wide") == "5 items" && sizeText("Deep") == "1 item"
        }
        check("a file still shows its byte size",
              sizeText("zfile.bin") == ByteCountFormatter.string(fromByteCount: 9_000, countStyle: .file),
              sizeText("zfile.bin") ?? "nil")

        browser.fileList.setSort(key: .size, ascending: true)
        await drainMainQueue()
        check("sorting by Size orders folders by their item count",
              browser.model.items.map(\.name) == ["Empty", "Deep", "Wide", "zfile.bin"],
              browser.model.items.map(\.name).joined(separator: ", "))

        // "Calculate all sizes" from the header menu, the way a user reaches it.
        let menu = list.headerMenu.menu
        list.headerMenu.rebuild()
        guard let index = menu.items.firstIndex(where: { $0.title == "Calculate all sizes" }) else {
            fail("the header menu offers Calculate all sizes")
        }
        check("it is off and available in an ordinary folder",
              menu.items[index].state == .off && menu.items[index].isEnabled && browser.canCalculateFolderSizes)
        menu.performActionForItem(at: index)
        list.headerMenu.menuNeedsUpdate(menu)
        check("choosing it turns the option on",
              browser.model.folderSizes.calculatesAllSizes
              && menu.items.first { $0.title == "Calculate all sizes" }?.state == .on)

        await expectEventually("recursive sizes replace the counts as they arrive", detail: {
            "Wide=\(sizeText("Wide") ?? "nil") Deep=\(sizeText("Deep") ?? "nil")"
        }) {
            sizeText("Wide") == FolderSizes.byteSizeText(fixture.wideBytes)
                && sizeText("Deep") == FolderSizes.byteSizeText(fixture.deepBytes)
                && sizeText("Empty") == FolderSizes.byteSizeText(0)
        }
        await expectEventually("the Size sort reorders itself once the sizes are known", detail: {
            browser.model.items.map(\.name).joined(separator: ", ")
        }) {
            browser.model.items.map(\.name) == ["Empty", "Wide", "Deep", "zfile.bin"]
        }
        check("the option is remembered for this folder",
              store.properties(forKey: DirectoryViewPropertiesStore.directoryKey(for: fixture.root) ?? "")
                  .calculateAllSizes)

        // The View menu shows and toggles the same state.
        guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu,
              let settings = view.items.first(where: { $0.title == "Folder View Settings" })?.submenu,
              let item = settings.items.first(where: { $0.title == "Calculate all sizes" }),
              let action = item.action else { fail("View ▸ Folder View Settings ▸ Calculate all sizes exists") }
        check("the menu item reports the folder's current state",
              wc.validateMenuItem(item) && item.state == .on)
        check("the menu item dispatches to the window", NSApp.sendAction(action, to: wc, from: item))
        await drainMainQueue()
        check("turning it off returns the Size column to item counts",
              !browser.model.folderSizes.calculatesAllSizes && sizeText("Deep") == "1 item",
              sizeText("Deep") ?? "nil")
        await expectEventually("and the Size sort returns to count order", detail: {
            browser.model.items.map(\.name).joined(separator: ", ")
        }) {
            browser.model.items.map(\.name) == ["Empty", "Deep", "Wide", "zfile.bin"]
        }

        // Navigating away mid-calculation must not deliver into the new folder.
        list.headerMenu.menuNeedsUpdate(menu)
        if let on = menu.items.firstIndex(where: { $0.title == "Calculate all sizes" }) {
            menu.performActionForItem(at: on)
        }
        check("the option is on again before navigating away",
              browser.model.folderSizes.calculatesAllSizes)
        browser.navigate(to: other.root)
        await listed(browser, at: other.root)
        await drainMainQueue()
        check("the new listing survives the cancelled walk",
              browser.model.items.count == 5 && browser.currentURL?.standardizedFileURL == other.root.standardizedFileURL,
              browser.model.items.map(\.name).joined(separator: ", "))
        check("the new folder starts from its own settings, not the previous one's",
              !browser.model.folderSizes.calculatesAllSizes)
        await expectEventually("its own folders are counted instead", detail: {
            "Alpha=\(sizeText("Alpha") ?? "nil") Beta=\(sizeText("Beta") ?? "nil")"
        }) {
            sizeText("Alpha") == "0 items" && sizeText("Beta") == "0 items"
        }
        check("no row from the previous folder is left behind",
              sizeText("Wide") == nil && sizeText("Deep") == nil)

        // A split pane and a second tab keep their own column and size state.
        let page = wc.tabs.currentPage
        let right = page.split(with: fixture.root)
        await listed(right, at: fixture.root)
        check("the other pane restored its own remembered size option",
              right.model.folderSizes.calculatesAllSizes
              && right !== browser, "\(right.model.folderSizes.calculatesAllSizes)")
        right.fileList.setVisibleColumns(["dateLastOpened", "size"])
        check("each pane keeps its own column set",
              right.fileList.visibleColumns == ["dateLastOpened", "size"]
              && !browser.fileList.visibleColumns.contains("dateLastOpened"),
              browser.fileList.visibleColumns.sorted().joined(separator: ", "))
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

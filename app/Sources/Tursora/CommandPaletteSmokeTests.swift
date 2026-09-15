import AppKit

/// The command palette: the pure fuzzy ranking first, then the real panel over
/// a real window — filtering, Return, folder rows, Escape and refusal of
/// disabled commands — in both file views and in a split.
enum CommandPaletteSmokeTests: SmokeSuite {
    static let checkPrefix = "command palette: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            print("== command palette ==")
            matcher()
            entries()
            do {
                let fixture = try SmokeFixtures.temporaryDirectory("command-palette")
                    .resolvingSymlinksInPath()
                defer { try? FileManager.default.removeItem(at: fixture) }
                catalog()
                for mode: ViewMode in [.details, .icons] {
                    try await panel(mode: mode, fixture: fixture)
                }
                try await split(fixture: fixture)
                completion()
            } catch let failure as SmokeFailure {
                fail(failure.description)
            } catch {
                fail("fixtures complete", error.localizedDescription)
            }
        }
    }

    // MARK: - Pure matcher

    private static func score(_ query: String, _ candidate: String) -> Int? {
        FuzzyMatcher.match(query, in: candidate)?.score
    }

    private static func matcher() {
        check("an unmatched query scores nothing", FuzzyMatcher.match("zqx", in: "New Folder") == nil)
        check("a query longer than the candidate never matches", FuzzyMatcher.match("newer folder name", in: "New") == nil)
        check("an empty query keeps every row at score zero",
              FuzzyMatcher.match("", in: "New Folder") == FuzzyMatcher.Match(score: 0, matchedOffsets: []))
        check("whitespace in the query is ignored", score("new f", "New Folder") == score("newf", "New Folder"))
        let prefix = score("new", "New Folder")
        let infix = score("new", "Show New Item")
        check("a prefix hit outranks the same word found later",
              prefix != nil && infix != nil && prefix! > infix!, "prefix=\(prefix ?? 0) infix=\(infix ?? 0)")
        check("matching is case-insensitive in both directions",
              score("NEW", "New Folder") == prefix && score("new", "NEW FOLDER") == prefix)
        let boundary = score("f", "New Folder")
        let inside = score("f", "Shuffle")
        check("a word-boundary hit outranks a mid-word hit",
              boundary != nil && inside != nil && boundary! > inside!, "boundary=\(boundary ?? 0) inside=\(inside ?? 0)")
        check("gapped subsequences match and report their offsets",
              FuzzyMatcher.match("nf", in: "New Folder")?.matchedOffsets == [0, 4])
        check("a consecutive run is preferred over a scattered one",
              FuzzyMatcher.match("ne", in: "New Folder")?.matchedOffsets == [0, 1])
        let leading = score("dow", "Go to Downloads")
        let buried = score("dow", "Shadow Window")
        check("a run that starts a word outranks the same letters buried in one",
              leading != nil && buried != nil && leading! > buried!, "leading=\(leading ?? 0) buried=\(buried ?? 0)")
        check("matched offsets stay inside the candidate",
              FuzzyMatcher.match("gtd", in: "Go to Downloads")?.matchedOffsets == [0, 3, 6])
    }

    // MARK: - Pure entry list

    private static func sampleActions() -> [ShortcutAction] {
        [ShortcutAction(id: "menu.newFolder", title: "New Folder", category: "File", selector: nil,
                        representedObject: nil,
                        defaultShortcut: .init(keyEquivalent: "n", modifierFlags: [.command, .shift]), context: .application),
         ShortcutAction(id: "menu.reload", title: "Reload", category: "View", selector: nil, representedObject: nil,
                        defaultShortcut: nil, context: .application),
         ShortcutAction(id: CommandPalette.commandID, title: "Command Palette…", category: "View", selector: nil,
                        representedObject: nil, defaultShortcut: nil, context: .application)]
    }

    private static func entries() {
        let downloads = URL(fileURLWithPath: "/Users/example/Downloads", isDirectory: true)
        let notes = URL(fileURLWithPath: "/Users/example/Notes", isDirectory: true)
        let places = [PlacesModel.Place(name: "Downloads", url: downloads, symbolName: "arrow.down.circle")]
        let bindings = ["menu.newFolder": AppPreferences.Shortcut(keyEquivalent: "n", modifierFlags: [.command, .shift])]
        let rows = CommandPalette.entries(actions: sampleActions(), bindings: bindings,
                                          favourites: places, recentFolders: [notes, notes])
        check("the palette's own command is left out of its list",
              !rows.contains { $0.id == CommandPalette.commandID })
        check("a command row carries its title, category and current shortcut",
              rows.first == PaletteEntry(id: "menu.newFolder", title: "New Folder", category: "File",
                                         shortcut: "⇧⌘N", url: nil, kind: .command))
        check("an unbound command shows no shortcut", rows[1].shortcut.isEmpty && rows[1].kind == .command)
        check("a favourite becomes a Go to row in the Favourites category",
              rows.contains { $0.kind == .favourite && $0.title == "Go to Downloads"
                  && $0.category == CommandPalette.favouriteCategory && $0.url == downloads })
        check("a history folder becomes a Recent row with an abbreviated path",
              rows.contains { $0.kind == .recent && $0.category == CommandPalette.recentCategory && $0.url == notes }
              && CommandPalette.recentTitle(for: URL(fileURLWithPath: NSHomeDirectory() + "/Notes")) == "Recent: ~/Notes")
        check("a repeated history folder is listed once",
              rows.filter { $0.kind == .recent }.count == 1)

        let ranked = CommandPalette.filter(rows, query: "new folder")
        check("typing a command name ranks it first",
              ranked.first?.entry.id == "menu.newFolder", ranked.prefix(3).map(\.entry.title).joined(separator: ", "))
        check("a query nothing matches produces no rows", CommandPalette.filter(rows, query: "zzqq").isEmpty)
        check("an empty query keeps every row", CommandPalette.filter(rows, query: "").count == rows.count)
        let tie = CommandPalette.filter(rows, query: "")
        check("equal scores are ordered by category, then title",
              tie.map { "\($0.entry.category)/\($0.entry.title)" }
              == tie.map { "\($0.entry.category)/\($0.entry.title)" }.sorted(),
              tie.map(\.entry.category).joined(separator: ", "))
    }

    // MARK: - Menu registration

    @MainActor private static func catalog() {
        // Earlier suites exercise rebinding; the palette's rows show the
        // user's current bindings, so start this section from the defaults.
        AppPreferences.shared.shortcuts.resetAll()
        let action = ShortcutCatalog.action(CommandPalette.commandID)
        check("the palette is a customisable catalog command",
              action?.title == "Command Palette…" && action?.category == "View" && action?.context == .application)
        // ⇧⌘P went to the preview pane in D82, matching Finder, and the
        // thumbnail toggle moved to ⌃⌘P. The palette keeps ⇧⌘O either way;
        // what this pins is that no two of the three collide.
        check("its default shortcut is ⇧⌘O and the P bindings do not collide",
              action?.defaultShortcut == .init(keyEquivalent: "o", modifierFlags: [.command, .shift])
              && ShortcutCatalog.action("menu.togglePreviews")?.defaultShortcut
                  == .init(keyEquivalent: "p", modifierFlags: [.command, .control]),
              "previews=\(String(describing: ShortcutCatalog.action("menu.togglePreviews")?.defaultShortcut))")
        let item = CommandPaletteRunner.menuItem(id: CommandPalette.commandID, in: NSApp.mainMenu)
        check("the View menu carries the item the palette dispatches through",
              item?.title == "Command Palette…" && item?.menu?.title == "View",
              "menu=\(item?.menu?.title ?? "none")")
        check("no other command claims ⇧⌘O", AppPreferences.shared.shortcuts.bindings
            .filter { $0.value.isEquivalent(to: .init(keyEquivalent: "o", modifierFlags: [.command, .shift])) }
            .map(\.key) == [CommandPalette.commandID])
    }

    // MARK: - The real panel

    @MainActor private static func panel(mode: ViewMode, fixture: URL) async throws {
        let root = fixture.appendingPathComponent("panel-\(mode)", isDirectory: true)
        let visited = root.appendingPathComponent("Visited", isDirectory: true)
        try FileManager.default.createDirectory(at: visited, withIntermediateDirectories: true)
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("\(mode)-palette-views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(),
                                      initialURL: root, viewPropertiesStore: store)
        defer { wc.commandPalette.close(); wc.close() }
        wc.window?.setContentSize(NSSize(width: 1000, height: 640))
        wc.window?.center()
        wc.window?.makeKeyAndOrderFront(nil)
        await listed(wc.browser, at: root)
        wc.browser.setViewMode(mode)

        // A short history so the palette has a Recent row with a fixture path.
        wc.browser.navigate(to: visited)
        await listed(wc.browser, at: visited)
        wc.browser.goBack()
        await listed(wc.browser, at: root)

        let palette = wc.commandPalette
        palette.show()
        check("\(mode): the palette opens over its window",
              palette.isVisible && palette.panelForTesting.parent === wc.window)
        check("\(mode): the search field starts empty and every row is listed",
              palette.queryForTesting.isEmpty && palette.visibleEntries.count > 20,
              "\(palette.visibleEntries.count) rows")
        check("\(mode): the list mirrors the sidebar's favourites",
              Set(palette.visibleEntries.filter { $0.kind == .favourite }.map(\.title))
              == Set((wc.places.sections.first { $0.title == CommandPalette.favouriteCategory }?.places ?? [])
                  .map { "Go to \($0.name)" }))
        check("\(mode): the active pane's history appears as a Recent row",
              palette.visibleEntries.contains { $0.kind == .recent && $0.url?.standardizedFileURL == visited.standardizedFileURL },
              palette.visibleEntries.filter { $0.kind == .recent }.map(\.title).joined(separator: ", "))

        palette.applyQuery("new folder")
        check("\(mode): typing narrows the list to the matching command",
              palette.visibleEntries.first?.id == "menu.newFolder" && palette.selectedEntry?.id == "menu.newFolder",
              palette.visibleEntries.prefix(3).map(\.title).joined(separator: ", "))
        check("\(mode): the row shows the command's current shortcut",
              palette.visibleEntries.first?.shortcut == "⇧⌘N")
        let rowCount = palette.visibleEntries.count
        palette.moveSelection(by: 1)
        let second = palette.selectedEntry?.id
        palette.moveSelection(by: -1)
        check("\(mode): the arrow keys move and return to the first row",
              rowCount < 2 || (second != "menu.newFolder" && palette.selectedEntry?.id == "menu.newFolder"))

        // Return runs the highlighted command in the active pane.
        check("\(mode): Return runs the highlighted command",
              palette.handleCommand(#selector(NSResponder.insertNewline(_:))))
        check("\(mode): running a command closes the palette", !palette.isVisible)
        check("\(mode): focus returns to the file view",
              wc.window?.firstResponder === wc.browser.focusView)
        await expectEventually("\(mode): New Folder created the folder in the active pane", detail: {
            (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.joined(separator: ", ") ?? "unreadable"
        }) {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .contains { $0.hasPrefix("untitled folder") }
        }

        // A folder row navigates the active pane.
        palette.show()
        palette.applyQuery("Recent: " + visited.path)
        check("\(mode): a folder row is selected by its path",
              palette.selectedEntry?.url?.standardizedFileURL == visited.standardizedFileURL,
              palette.visibleEntries.prefix(3).map(\.title).joined(separator: ", "))
        palette.handleCommand(#selector(NSResponder.insertNewline(_:)))
        await listed(wc.browser, at: visited)
        check("\(mode): a folder row navigates the active pane", !palette.isVisible)

        // Escape closes without running anything.
        palette.show()
        palette.applyQuery("reload")
        let generation = wc.browser.model.generation
        check("\(mode): Escape is handled by the palette",
              palette.handleCommand(#selector(NSResponder.cancelOperation(_:))))
        check("\(mode): Escape closes and hands focus back to the file view",
              !palette.isVisible && wc.window?.firstResponder === wc.browser.focusView)
        check("\(mode): Escape ran nothing", wc.browser.model.generation == generation)

        // A disabled command is shown dimmed and refuses to run.
        palette.show()
        palette.applyQuery("reopen closed tab")
        guard let reopen = palette.selectedEntry, reopen.id == "menu.reopenClosedTab" else {
            fail("\(mode): the disabled command is listed",
                 palette.visibleEntries.prefix(3).map(\.title).joined(separator: ", "))
        }
        check("\(mode): an unavailable command is listed but marked disabled",
              !palette.isEnabled(reopen) && !wc.tabs.canReopenClosedTab)
        check("\(mode): Return refuses a disabled command and keeps the palette open",
              palette.activateSelection() == false && palette.isVisible)
        check("\(mode): the refused command did not open a tab", wc.tabs.count == 1)
        palette.close()

        // Clicking a row runs it, through the same path as Return.
        palette.show()
        palette.applyQuery("show hidden files")
        let hidden = wc.browser.showsHiddenFiles
        check("\(mode): the clickable row is the hidden-files command",
              palette.selectedEntry?.id == "menu.toggleHiddenFiles",
              palette.visibleEntries.prefix(3).map(\.title).joined(separator: ", "))
        palette.activateSelection()
        check("\(mode): running a listed toggle reaches the active pane",
              wc.browser.showsHiddenFiles != hidden)
        wc.browser.showsHiddenFiles = hidden

        // Favourites reach the pane through the same runner.
        let favourite = CommandPalette.entries(actions: [], bindings: [:],
                                               favourites: [.init(name: "Visited", url: visited, symbolName: "folder")],
                                               recentFolders: [])[0]
        wc.browser.navigate(to: root)
        await listed(wc.browser, at: root)
        check("\(mode): a favourite row runs", CommandPaletteRunner.run(favourite, in: wc))
        await listed(wc.browser, at: visited)
        check("\(mode): a favourite navigates the active pane",
              wc.browser.currentURL?.standardizedFileURL == visited.standardizedFileURL)
    }

    // MARK: - Split panes

    @MainActor private static func split(fixture: URL) async throws {
        let left = fixture.appendingPathComponent("split-left", isDirectory: true)
        let right = fixture.appendingPathComponent("split-right", isDirectory: true)
        for url in [left, right] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("split-palette-views.json"))
        let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(),
                                      initialURL: left, viewPropertiesStore: store)
        defer { wc.commandPalette.close(); wc.close() }
        wc.window?.setContentSize(NSSize(width: 1000, height: 640))
        wc.window?.center()
        wc.window?.makeKeyAndOrderFront(nil)
        await listed(wc.browser, at: left)
        let page = wc.tabs.currentPage
        let other = page.split(with: right)
        await listed(other, at: right)
        page.activate(other)
        check("split: the right pane is active", wc.browser === other)

        let palette = wc.commandPalette
        palette.show()
        palette.applyQuery("new folder")
        check("split: the command is selected", palette.selectedEntry?.id == "menu.newFolder")
        palette.handleCommand(#selector(NSResponder.insertNewline(_:)))
        await expectEventually("split: the folder is created in the active pane", detail: {
            "left=\((try? FileManager.default.contentsOfDirectory(atPath: left.path)) ?? []), "
            + "right=\((try? FileManager.default.contentsOfDirectory(atPath: right.path)) ?? [])"
        }) {
            ((try? FileManager.default.contentsOfDirectory(atPath: right.path)) ?? [])
                .contains { $0.hasPrefix("untitled folder") }
        }
        check("split: the inactive pane is untouched",
              ((try? FileManager.default.contentsOfDirectory(atPath: left.path)) ?? []).isEmpty)

        page.activate(page.panes[0])
        palette.show()
        palette.applyQuery("new folder")
        palette.handleCommand(#selector(NSResponder.insertNewline(_:)))
        await expectEventually("split: switching the active pane moves the target", detail: {
            (try? FileManager.default.contentsOfDirectory(atPath: left.path))?.joined(separator: ", ") ?? "unreadable"
        }) {
            ((try? FileManager.default.contentsOfDirectory(atPath: left.path)) ?? [])
                .contains { $0.hasPrefix("untitled folder") }
        }
    }

    @MainActor private static func listed(_ pane: BrowserViewController, at url: URL) async {
        await waitUntil("directory listing", detail: { "\(pane.currentURL?.path ?? "nil") vs \(url.path)" }) {
            pane.currentURL?.standardizedFileURL == url.standardizedFileURL
                && pane.model.url?.standardizedFileURL == url.standardizedFileURL
                && pane.model.generation > 0 && !pane.isPreparingArchive && !pane.model.isSearchResults
        }
    }
}

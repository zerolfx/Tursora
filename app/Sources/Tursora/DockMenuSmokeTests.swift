import AppKit

/// Dock commands open independent windows even when no browser owns focus.
enum DockMenuSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            print("== Dock menu destinations and window ownership ==")
            let previousKey = NSApp.keyWindow
            let previousMain = NSApp.mainWindow
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("tursora-dock-menu-" + UUID().uuidString).resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: fixture) }
            do {
                let home = fixture.appendingPathComponent("Home")
                let downloads = fixture.appendingPathComponent("Downloads")
                let applications = fixture.appendingPathComponent("Applications")
                let folders = [home, downloads, applications]
                for folder in folders {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data("selected document".utf8).write(to: folder.appendingPathComponent("keep.txt"))
                    try Data("other document".utf8).write(to: folder.appendingPathComponent("other.md"))
                }
                let directories = DockMenuDirectories(home: home, downloads: downloads, applications: applications)
                pureDestinations(directories)
                let provider = FixtureProvider(home: home, root: fixture)
                await withoutWindows(provider: provider, directories: directories)
                unavailableDestinations(provider: provider, home: home)
                for mode: ViewMode in [.details, .icons] {
                    await existingContext(mode: mode, provider: provider, directories: directories, fixture: fixture)
                }
                check("the provider listed only the isolated fixture", !provider.listedPaths.isEmpty && provider.listedPaths.allSatisfy {
                    $0 == fixture.path || $0.hasPrefix(fixture.path + "/")
                })
            } catch { check("temporary Dock fixtures are available", false, error.localizedDescription) }
            if previousMain?.isVisible == true { previousMain?.makeMain() }
            if previousKey?.isVisible == true { previousKey?.makeKeyAndOrderFront(nil) }
            completion()
        }
    }

    private static func pureDestinations(_ directories: DockMenuDirectories) {
        check("custom commands have the intended order and labels", DockMenuCommand.allCases.map(\.title) == ["New Window", "Downloads", "Applications"])
        check("New Window resolves the injected home", DockMenuCommand.newWindow.destination(in: directories) == directories.home)
        check("Downloads resolves independently of the current pane", DockMenuCommand.downloads.destination(in: directories) == directories.downloads)
        check("Applications resolves independently of home", DockMenuCommand.applications.destination(in: directories) == directories.applications)
        let lookup = DirectoryLookup(downloads: directories.downloads.map { [$0] } ?? [], applications: directories.applications.map { [$0] } ?? [])
        let system = DockMenuDirectories.system(home: directories.home, fileManager: lookup)
        check("system lookup preserves the supplied home and standard destinations", system.home == directories.home && system.downloads == directories.downloads && system.applications == directories.applications)
        check("Downloads uses the user domain and Applications the local domain", lookup.requests.count == 2 && lookup.requests[0].0 == .downloadsDirectory && lookup.requests[0].1 == .userDomainMask && lookup.requests[1].0 == .applicationDirectory && lookup.requests[1].1 == .localDomainMask)
        let missing = DockMenuDirectories.system(home: directories.home, fileManager: DirectoryLookup(downloads: [], applications: []))
        check("unavailable standard destinations stay absent", missing.downloads == nil && missing.applications == nil)
        check("unavailable shortcuts never fall back to a different directory", DockMenuCommand.downloads.destination(in: missing) == nil && DockMenuCommand.applications.destination(in: missing) == nil && DockMenuCommand.newWindow.destination(in: missing) == directories.home)
    }

    @MainActor private static func withoutWindows(provider: FixtureProvider, directories: DockMenuDirectories) async {
        let delegate = AppDelegate(provider: provider, places: PlacesModel(), dockDirectories: directories)
        defer { closeWindows(delegate) }
        let menu = dockMenu(delegate)
        check("the custom menu contains exactly three commands and one separator", menu.items.map(\.title) == ["New Window", "", "Downloads", "Applications"] && menu.items.enumerated().filter { $0.element.isSeparatorItem }.map(\.offset) == [1])
        check("system-managed Dock commands and window lists are not duplicated", menu.items.count == 4 && menu.items.allSatisfy { $0.submenu == nil } && !menu.items.contains { ["Options", "Show All Windows", "Hide", "Quit"].contains($0.title) })
        check("Dock items introduce no keyboard shortcuts", menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
        check("Dock items retain explicit availability", !menu.autoenablesItems && menu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled))
        let selectors = menu.items.compactMap(\.action).map(NSStringFromSelector)
        check("nil-sender dispatch has distinct destination selectors", selectors == ["newWindowFromDock:", "openDownloadsFromDock:", "openApplicationsFromDock:"])
        check("every command explicitly targets its application delegate", menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target === delegate })

        for command in DockMenuCommand.allCases {
            check("\(command.title): no previously owned window is required", delegate.windowControllers.isEmpty)
            let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            dispatch(command, in: menu)
            guard let wc = delegate.windowControllers.first else { check("\(command.title): creates an owned window", false); return }
            await listed(wc.browser, at: command.destination(in: directories)!)
            check("\(command.title): creates exactly one fresh visible window", delegate.windowControllers.count == 1 && wc.window?.isVisible == true && wc.window.map { !previousWindows.contains(ObjectIdentifier($0)) } == true)
            check("\(command.title): opens the requested fixture with a fresh unsplit tab", wc.tabs.count == 1 && !wc.tabs.isSplit && wc.browser.currentURL == command.destination(in: directories) && wc.browser.history.entries.count == 1 && !wc.browser.isFiltering && !wc.browser.isSearching)
            closeWindows(delegate)
            check("\(command.title): closing releases its registered window", delegate.windowControllers.isEmpty)
        }
    }

    @MainActor private static func unavailableDestinations(provider: FixtureProvider, home: URL) {
        let delegate = AppDelegate(provider: provider, places: PlacesModel(), dockDirectories: .init(home: home, downloads: nil, applications: nil))
        defer { closeWindows(delegate) }
        let menu = dockMenu(delegate)
        menu.update()
        check("missing destinations disable only their own commands", menu.item(withTitle: "New Window")?.isEnabled == true && menu.item(withTitle: "Downloads")?.isEnabled == false && menu.item(withTitle: "Applications")?.isEnabled == false)
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        for command: DockMenuCommand in [.downloads, .applications] {
            // Direct action dispatch bypasses menu validation, as a stale Dock
            // request can; absent destinations must still be harmless.
            dispatch(command, in: menu)
            check("\(command.title): unavailable direct dispatch creates no window", delegate.windowControllers.isEmpty && Set(NSApp.windows.map(ObjectIdentifier.init)).subtracting(previousWindows).isEmpty)
        }
    }

    @MainActor private static func existingContext(mode: ViewMode, provider: FixtureProvider, directories: DockMenuDirectories, fixture: URL) async {
        let delegate = AppDelegate(provider: provider, places: PlacesModel(), dockDirectories: directories)
        defer { closeWindows(delegate) }
        let store = DirectoryViewPropertiesStore(fileURL: fixture.appendingPathComponent("\(mode)-dock-views.json"))
        let original = delegate.newWindow(at: directories.home, viewPropertiesStore: store)
        let tabs = original.tabs
        let split = tabs.currentPage
        let left = original.browser
        await listed(left, at: directories.home)
        let right = split.split(with: directories.downloads!)
        await listed(right, at: directories.downloads!)
        let backgroundPane = tabs.newTab(at: directories.applications!)
        let background = tabs.currentPage
        await listed(backgroundPane, at: directories.applications!)
        for pane in [left, right, backgroundPane] {
            pane.setViewMode(mode)
            pane.setGroupKey(.kind)
            pane.nameFilter = "keep"
            pane.fileView.select(names: ["keep.txt"])
        }
        tabs.setTitle("Background context", for: background)
        tabs.selectTab(at: 0)
        split.activate(right)
        guard let backgroundMenu = tabs.tabContextMenu(at: 1) else { check("\(mode): background tab context exists", false); return }
        let menuTitles = backgroundMenu.items.map(\.title)
        let before = [left, right, backgroundPane].map(PaneState.init)
        check("\(mode): context fixture has filtered grouped selections in both views", [left, right, backgroundPane].allSatisfy { $0.viewMode == mode && $0.groupKey == .kind && $0.nameFilter == "keep" && $0.fileView.selectedItems.map(\.name) == ["keep.txt"] })
        let pages = tabs.pages.map(ObjectIdentifier.init)
        let dock = dockMenu(delegate)
        for (offset, command) in DockMenuCommand.allCases.enumerated() {
            let existing = Set(delegate.windowControllers.map(ObjectIdentifier.init))
            dispatch(command, in: dock)
            let added = delegate.windowControllers.filter { !existing.contains(ObjectIdentifier($0)) }
            check("\(mode), \(command.title): opens a new registered window", added.count == 1 && delegate.windowControllers.count == offset + 2)
            guard let fresh = added.first else { return }
            await listed(fresh.browser, at: command.destination(in: directories)!)
            check("\(mode), \(command.title): destination opens without inheriting pane state", fresh.browser.currentURL == command.destination(in: directories) && fresh.tabs.count == 1 && !fresh.tabs.isSplit && !fresh.browser.isFiltering && !fresh.browser.isSearching && fresh.browser.fileView.selectedItems.isEmpty && fresh.browser.history.entries.count == 1)
            check("\(mode), \(command.title): original tab and active split identities survive", tabs.pages.map(ObjectIdentifier.init) == pages && tabs.currentPage === split && split.panes.count == 2 && split.panes[0] === left && split.panes[1] === right && split.active === right && background.customTitle == "Background context")
            check("\(mode), \(command.title): locations, filtering, grouping, selection and history survive", [left, right, backgroundPane].map(PaneState.init) == before)
            check("\(mode), \(command.title): the captured background menu stays attached to its page", backgroundMenu.items.map(\.title) == menuTitles && tabs.canPerformTabAction(.rename, on: background) && tabs.currentPage !== background)
        }
        tabs.renameTabTitleProvider = { _, reply in reply("Renamed after Dock") }
        guard let rename = backgroundMenu.item(withTitle: TabContextAction.rename.title), let action = rename.action else { check("\(mode): background rename remains dispatchable", false); return }
        check("\(mode): a captured background action dispatches after Dock focus moves", NSApp.sendAction(action, to: rename.target, from: rename))
        check("\(mode): that action still targets the original background tab", background.customTitle == "Renamed after Dock" && split.customTitle == nil && tabs.currentPage === split && delegate.windowControllers.dropFirst().allSatisfy { $0.tabs.currentPage.customTitle == nil })
        closeWindows(delegate)
        check("\(mode): all test-owned windows close and unregister", delegate.windowControllers.isEmpty)
    }

    private struct PaneState: Equatable {
        let url: URL?
        let mode: ViewMode
        let group: GroupKey
        let filter: String
        let selected: [URL]
        let items: [URL]
        let history: [URL]
        let historyIndex: Int
        init(_ pane: BrowserViewController) {
            url = pane.currentURL; mode = pane.viewMode; group = pane.groupKey; filter = pane.nameFilter
            selected = pane.fileView.selectedItems.map(\.url); items = pane.model.items.map(\.url)
            history = pane.history.entries.map(\.url); historyIndex = pane.history.index
        }
    }

    @MainActor private static func dockMenu(_ delegate: AppDelegate) -> NSMenu {
        guard let menu = delegate.applicationDockMenu(NSApp) else { check("application delegate provides its Dock menu", false); return NSMenu() }
        return menu
    }

    @MainActor private static func dispatch(_ command: DockMenuCommand, in menu: NSMenu) {
        guard let item = menu.item(withTitle: command.title), let action = item.action else { check("\(command.title) has an action", false); return }
        check("\(command.title): nil-sender action reaches its explicit target", NSApp.sendAction(action, to: item.target, from: nil))
    }

    @MainActor private static func closeWindows(_ delegate: AppDelegate) {
        let windows = delegate.windowControllers
        windows.forEach { $0.close() }
    }

    @MainActor private static func listed(_ browser: BrowserViewController, at url: URL) async {
        let deadline = Date().addingTimeInterval(15)
        while browser.currentURL?.standardizedFileURL != url.standardizedFileURL || browser.model.url?.standardizedFileURL != url.standardizedFileURL || browser.model.generation == 0 || browser.isPreparingArchive {
            if Date() > deadline { check("directory listing completes", false, "expected=\(url.path), current=\(browser.currentURL?.path ?? "nil"), generation=\(browser.model.generation)"); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private final class DirectoryLookup: FileManager, @unchecked Sendable {
        let downloads: [URL]
        let applications: [URL]
        private(set) var requests: [(FileManager.SearchPathDirectory, FileManager.SearchPathDomainMask)] = []
        init(downloads: [URL], applications: [URL]) { self.downloads = downloads; self.applications = applications; super.init() }
        override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            requests.append((directory, domainMask))
            return directory == .downloadsDirectory ? downloads : applications
        }
    }

    private final class FixtureProvider: FileProvider {
        let homeURL: URL
        let root: URL
        private let local = LocalFileProvider()
        private let lock = NSLock()
        private var paths: [String] = []
        var listedPaths: [String] { lock.lock(); defer { lock.unlock() }; return paths }
        init(home: URL, root: URL) { homeURL = home; self.root = root }
        func displayName(for url: URL) -> String { url.lastPathComponent }
        func listDirectory(_ url: URL) throws -> [FileItem] {
            let path = url.standardizedFileURL.path
            lock.lock(); paths.append(path); lock.unlock()
            guard path == root.path || path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            return try local.listDirectory(url)
        }
    }

    private static func check(_ name: String, _ success: Bool, _ detail: String = "") {
        print("\(success ? "ok  " : "FAIL") Dock menu: \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !success { fflush(stdout); exit(1) }
    }
}

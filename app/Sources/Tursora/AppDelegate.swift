import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var preferencesObserver: NSObjectProtocol?
    private(set) var windowControllers: [MainWindowController] = []
    let provider: FileProvider
    let places: PlacesModel
    private let dockDirectories: DockMenuDirectories
    private let updater: AppUpdater

    init(provider: FileProvider = LocalFileProvider(), places: PlacesModel = PlacesModel(),
         dockDirectories: DockMenuDirectories? = nil, updater: AppUpdater = .shared) {
        self.updater = updater
        self.provider = provider
        self.places = places
        self.dockDirectories = dockDirectories ?? .system(home: provider.homeURL)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A process-local visual QA override leaves the user's system
        // appearance and the normally launched application unchanged.
        switch ProcessInfo.processInfo.environment["TURSORA_UI_TEST_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        NSApp.mainMenu = MainMenu.build()
        preferencesObserver = NotificationCenter.default.addObserver(forName: .tursoraPreferencesChanged, object: nil, queue: .main) { _ in
            if let menu = NSApp.mainMenu { MainMenu.applyPreferences(to: menu) }
        }
        let wc = newWindow(self)
        updater.start()
        NSApp.activate(ignoringOtherApps: true)
        if SmokeTest.isRequested { SmokeTest.run(wc) }
    }

    /// Info windows save a comment still being typed when they close; ⌘Q
    /// closes nothing by itself, so do it here.
    func applicationWillTerminate(_ notification: Notification) {
        do { try DirectoryViewPropertiesStore.shared.flush() }
        catch { NSLog("Could not save folder view settings: %@", error.localizedDescription) }
        InfoWindowController.closeAll()
        windowControllers.forEach {
            $0.hideTerminal()
            // Release transfer journals while the process is still alive so
            // private recovery storage is reclaimed on an ordinary quit.
            $0.window?.undoManager?.removeAllActions()
        }
        ArchiveWorkspace.shared.shutdownAll()
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show() }

    @objc func checkForUpdates(_ sender: Any?) { updater.checkForUpdates(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) { return updater.canCheckForUpdates }
        return true
    }

    @objc func showFileOperations(_ sender: Any?) { TransferTasksWindowController.shared.show() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard TransferTasksWindowController.shared.hasActiveTasks else { return .terminateNow }
        TransferTasksWindowController.shared.cancelAll {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// A file manager stays alive with no windows open, like Finder does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no windows open should give you one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(self) }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenu.make(target: self, directories: dockDirectories)
    }

    // Dock actions can arrive with a nil sender, so each destination has a
    // distinct selector instead of depending on an NSMenuItem payload.
    @objc func newWindowFromDock(_ sender: Any?) { openDockWindow(.newWindow) }
    @objc func openDownloadsFromDock(_ sender: Any?) { openDockWindow(.downloads) }
    @objc func openApplicationsFromDock(_ sender: Any?) { openDockWindow(.applications) }

    private func openDockWindow(_ command: DockMenuCommand) {
        guard let url = command.destination(in: dockDirectories) else { return }
        newWindow(at: url)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finder-style: dropping a folder on the Dock icon browses it.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let dir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                ? url : url.deletingLastPathComponent()
            newWindow(at: dir)
        }
    }

    @discardableResult @objc func newWindow(_ sender: Any?) -> MainWindowController {
        newWindow(at: provider.homeURL)
    }

    @discardableResult
    func newWindow(snapshot: TabSnapshot, viewPropertiesStore: DirectoryViewPropertiesStore) -> MainWindowController {
        let wc = newWindow(at: snapshot.panes.first?.url ?? provider.homeURL, viewPropertiesStore: viewPropertiesStore)
        snapshot.restore(in: wc.tabs)
        return wc
    }

    @discardableResult
    func newWindow(at url: URL, viewPropertiesStore: DirectoryViewPropertiesStore = .shared) -> MainWindowController {
        let wc = MainWindowController(provider: provider, places: places, initialURL: url, viewPropertiesStore: viewPropertiesStore)
        windowControllers.append(wc)
        wc.onClose = { [weak self, weak wc] in
            self?.windowControllers.removeAll { $0 === wc }
        }
        // Cascade new windows instead of stacking them exactly on top of each other.
        if let last = windowControllers.dropLast().last?.window, let w = wc.window {
            w.setFrameTopLeftPoint(last.cascadeTopLeft(from: last.frame.origin.applying(
                CGAffineTransform(translationX: 0, y: last.frame.height))))
        }
        wc.showWindow(self)
        return wc
    }
}

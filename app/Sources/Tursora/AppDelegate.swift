import AppKit

extension Notification.Name {
    static let tursoraWorkspaceSaveRequested = Notification.Name("Tursora.workspaceSaveRequested")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var preferencesObserver: NSObjectProtocol?
    private(set) var windowControllers: [MainWindowController] = []
    let provider: FileProvider
    let places: PlacesModel
    private let dockDirectories: DockMenuDirectories
    private let updater: AppUpdater
    let workspaceStore: WorkspaceSessionStore
    private let preferences: AppPreferences.Store
    private let defaultViewPropertiesStore: DirectoryViewPropertiesStore
    private var workspacePreferencesObserver: NSObjectProtocol?
    private var workspaceRetryObserver: NSObjectProtocol?
    private var workspaceSave: DispatchWorkItem?
    private var hasStartedWorkspace = false
    private var isRestoringWorkspace = false
    private var isTerminating = false
    private var canReplaceSavedWorkspace = true
    private var lastObservedWorkspace: WorkspaceSessionState?
    private var restoresWorkspace: Bool
    private weak var activeWorkspaceWindow: MainWindowController?

    init(provider: FileProvider = LocalFileProvider(), places: PlacesModel = PlacesModel(),
         dockDirectories: DockMenuDirectories? = nil, updater: AppUpdater = .shared,
         workspaceStore: WorkspaceSessionStore = .shared,
         preferences: AppPreferences.Store = AppPreferences.shared,
         viewPropertiesStore: DirectoryViewPropertiesStore = .shared) {
        self.updater = updater
        self.workspaceStore = workspaceStore
        self.preferences = preferences
        self.defaultViewPropertiesStore = viewPropertiesStore
        self.restoresWorkspace = preferences.restoreWorkspaceOnLaunch
        self.provider = provider
        self.places = places
        self.dockDirectories = dockDirectories ?? .system(home: provider.homeURL)
        super.init()
        workspacePreferencesObserver = preferences.notificationCenter.addObserver(forName: .tursoraPreferencesChanged, object: preferences, queue: .main) { [weak self] _ in
            self?.workspacePreferenceChanged()
        }
        workspaceRetryObserver = NotificationCenter.default.addObserver(forName: .tursoraWorkspaceSaveRequested, object: workspaceStore, queue: .main) { [weak self] _ in
            guard let self, self.hasStartedWorkspace else { return }
            if self.preferences.restoreWorkspaceOnLaunch { self.saveWorkspaceNow(replacingUnreadable: true) }
            else { self.workspaceStore.clear() }
        }
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
        if SmokeTest.isRequested { newWindow(self) }
        else { beginWorkspaceSession() }
        updater.start()
        NSApp.activate(ignoringOtherApps: true)
        if SmokeTest.isRequested, let wc = windowControllers.first { SmokeTest.run(wc) }
    }

    /// Info windows save a comment still being typed when they close; ⌘Q
    /// closes nothing by itself, so do it here.
    func applicationWillTerminate(_ notification: Notification) {
        // Capture logical archive locations before any shutdown removes their
        // temporary workspace, and before cleanup changes focus or window state.
        prepareWorkspaceForTermination()
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
    func newWindow(at url: URL, viewPropertiesStore: DirectoryViewPropertiesStore? = nil,
                   show: Bool = true, cascade: Bool = true) -> MainWindowController {
        let wc = MainWindowController(provider: provider, places: places, initialURL: url,
                                      viewPropertiesStore: viewPropertiesStore ?? defaultViewPropertiesStore)
        windowControllers.append(wc)
        wc.onClose = { [weak self, weak wc] in
            guard let self else { return }
            self.windowControllers.removeAll { $0 === wc }
            if self.activeWorkspaceWindow === wc { self.activeWorkspaceWindow = self.windowControllers.last }
            self.workspaceChanged()
        }
        wc.onSessionChanged = { [weak self, weak wc] in
            guard let self, let wc else { return }
            if wc.window?.isKeyWindow == true { self.activeWorkspaceWindow = wc }
            self.workspaceChanged()
        }
        // Cascade new windows instead of stacking them exactly on top of each other.
        if cascade, let last = windowControllers.dropLast().last?.window, let w = wc.window {
            w.setFrameTopLeftPoint(last.cascadeTopLeft(from: last.frame.origin.applying(
                CGAffineTransform(translationX: 0, y: last.frame.height))))
        }
        if show {
            activeWorkspaceWindow = wc
            wc.showWindow(self)
        }
        workspaceChanged()
        return wc
    }

    /// Called once at application launch, separately from menus/updater setup
    /// so lifecycle tests can use their own provider, preferences and disk file.
    func beginWorkspaceSession(showWindows: Bool = true) {
        guard !hasStartedWorkspace else { return }
        isRestoringWorkspace = true
        let explicitlyOpenedWindow = windowControllers.last
        var restored: [(MainWindowController, WorkspaceWindowState)] = []
        var restoredActiveIndex = 0
        if preferences.restoreWorkspaceOnLaunch {
            switch workspaceStore.load() {
            case .loaded(let state):
                restoredActiveIndex = state.activeWindowIndex
                for savedWindow in state.windows {
                    guard let initialURL = savedWindow.tabs.first?.panes.first?.url else { continue }
                    let wc = newWindow(at: initialURL, show: false, cascade: false)
                    wc.restoreWorkspaceSession(savedWindow)
                    restored.append((wc, savedWindow))
                }
            case .missing: break
            case .unsupported, .corrupt, .readError:
                // Keep an unreadable/newer file intact until an explicit retry
                // or toggling the preference starts a new saved workspace.
                canReplaceSavedWorkspace = false
            }
        } else {
            workspaceStore.clear()
        }
        if windowControllers.isEmpty { newWindow(at: provider.homeURL, show: false, cascade: false) }
        if showWindows {
            for (wc, saved) in restored {
                wc.window?.orderBack(nil)
                if saved.isMiniaturized { wc.window?.miniaturize(nil) }
            }
        }
        let selected = restored.indices.contains(restoredActiveIndex) ? restored[restoredActiveIndex].0 : windowControllers.first
        activeWorkspaceWindow = explicitlyOpenedWindow ?? selected
        if showWindows, let active = activeWorkspaceWindow {
            // Restoring an all-minimized workspace should not unminimize it.
            if active.window?.isMiniaturized != true {
                active.window?.makeKeyAndOrderFront(nil)
                active.window?.makeFirstResponder(active.browser.focusView)
            }
        }
        hasStartedWorkspace = true
        isRestoringWorkspace = false
        lastObservedWorkspace = currentWorkspaceState
    }

    var currentWorkspaceState: WorkspaceSessionState {
        WorkspaceSessionState(windows: windowControllers.map(\.workspaceSessionState),
                              activeWindowIndex: windowControllers.firstIndex { $0 === activeWorkspaceWindow } ?? 0)
    }

    private func workspaceChanged() {
        guard hasStartedWorkspace, !isRestoringWorkspace, !isTerminating,
              preferences.restoreWorkspaceOnLaunch, canReplaceSavedWorkspace else { return }
        let state = currentWorkspaceState
        guard state != lastObservedWorkspace else { return }
        lastObservedWorkspace = state
        workspaceSave?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.saveWorkspaceNow() }
        workspaceSave = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    @discardableResult
    func saveWorkspaceNow(replacingUnreadable: Bool = false) -> Bool {
        workspaceSave?.cancel()
        workspaceSave = nil
        guard hasStartedWorkspace, preferences.restoreWorkspaceOnLaunch else { return false }
        if replacingUnreadable { canReplaceSavedWorkspace = true }
        guard canReplaceSavedWorkspace else { return false }
        let state = currentWorkspaceState
        lastObservedWorkspace = state
        return workspaceStore.save(state)
    }

    func prepareWorkspaceForTermination() {
        isTerminating = true
        if preferences.restoreWorkspaceOnLaunch { saveWorkspaceNow() }
        else { workspaceStore.flush() } // Retry a previously failed clear on quit.
    }

    private func workspacePreferenceChanged() {
        let enabled = preferences.restoreWorkspaceOnLaunch
        guard enabled != restoresWorkspace else { return }
        restoresWorkspace = enabled
        guard hasStartedWorkspace else { return }
        workspaceSave?.cancel()
        workspaceSave = nil
        canReplaceSavedWorkspace = true
        if enabled { saveWorkspaceNow() }
        else { workspaceStore.clear() }
    }

    deinit {
        workspaceSave?.cancel()
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let workspacePreferencesObserver { preferences.notificationCenter.removeObserver(workspacePreferencesObserver) }
        if let workspaceRetryObserver { NotificationCenter.default.removeObserver(workspaceRetryObserver) }
    }
}

import AppKit

/// Footer presentation/layout and real pane ownership, without launching a
/// shell. Real asynchronous job status is covered by TerminalSessionSmokeTests.
enum TerminalStatusSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            print("== terminal footer status ==")
            presentationChecks()
            layoutChecks()
            await paneChecks()
            completion()
        }
    }

    private static func presentationChecks() {
        let ready = TerminalStatusPresentation.make(state: nil, visible: false, activity: nil, enabled: true)
        check("initial status offers opening without claiming a shell exists", ready.title == "Terminal"
            && ready.detail.contains("No shell") && ready.detail.contains("show") && !ready.hasTasks && ready.isEnabled)
        let running = TerminalStatusPresentation.make(state: .running, visible: true, activity: .idle, enabled: true)
        let hidden = TerminalStatusPresentation.make(state: .running, visible: false, activity: .idle, enabled: true)
        check("running and hidden session states describe the correct toggle", running.title.contains("Running") && running.detail.contains("hide")
            && hidden.title.contains("Hidden") && hidden.detail.contains("show") && hidden.detail.contains("keeps its work running"))
        let tasks = TerminalActivitySnapshot(tasks: [.init(pid: 71, name: "sleep", isStopped: false), .init(pid: 72, name: "editor", isStopped: true)], informationUnavailable: false)
        let busy = TerminalStatusPresentation.make(state: .running, visible: false, activity: tasks, enabled: true)
        check("background and stopped task counts remain visible when hidden", busy.title.contains("2 tasks") && busy.hasTasks
            && busy.detail.contains("hidden") && busy.detail.contains("1 stopped"))
        let disabled = TerminalStatusPresentation.make(state: .running, visible: false, activity: tasks, enabled: false)
        check("disabled feature still describes retained jobs", !disabled.isEnabled && disabled.hasTasks && disabled.detail.contains("Settings"))
        let unknown = TerminalStatusPresentation.make(state: .running, visible: false,
            activity: .init(tasks: [], informationUnavailable: true), enabled: true)
        check("unavailable activity is not reported as idle", unknown.title.contains("Check") && unknown.detail.contains("could not be checked"))
        let ended = TerminalStatusPresentation.make(state: .ended, visible: false, activity: .idle, enabled: true)
        let error = TerminalStatusPresentation.make(state: .failedToStart, visible: true, activity: .idle, enabled: true)
        check("ended and failed sessions have distinct status and retained-output guidance", ended.title.contains("Ended")
            && ended.detail.contains("output is retained") && error.title.contains("Error") && error.detail.contains("could not start"))
    }

    @MainActor
    private static func layoutChecks() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 720, height: StatusBarView.height))
        let button = bar.terminalStatusButton
        let busy = TerminalStatusPresentation.make(state: .running, visible: false,
            activity: .init(tasks: [.init(pid: 71, name: "sleep", isStopped: false)], informationUnavailable: false), enabled: true)
        bar.update(itemCount: 12, selectedCount: 0, directory: nil, archiveStatus: "Read-only ZIP")
        bar.beginBusy()
        bar.setTerminalStatus(busy)
        guard let label = bar.subviews.compactMap({ $0 as? NSTextField }).first,
              let spinner = bar.subviews.compactMap({ $0 as? NSProgressIndicator }).first else {
            check("footer retains its file label and operation spinner", false); return
        }
        for width: CGFloat in [178, 279, 280, 449, 450, 720] {
            bar.setFrameSize(NSSize(width: width, height: StatusBarView.height))
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            check("\(width)pt footer has separate bounded label, terminal and spinner", !button.isHidden && bar.bounds.contains(button.frame)
                && bar.bounds.contains(spinner.frame) && label.frame.width >= 72 && !label.frame.intersects(button.frame)
                && !button.frame.intersects(spinner.frame) && label.stringValue.hasPrefix("Read-only ZIP") && label.toolTip?.contains("temporary copies") == true)
            check("\(width)pt footer preserves full accessible terminal state", button.toolTip == busy.detail
                && button.accessibilityLabel()?.contains(busy.title) == true && button.accessibilityLabel()?.contains("hidden") == true)
            if width < 280 {
                check("\(width)pt footer uses a 24pt icon without losing archive context", button.frame.width == 24 && button.title.isEmpty
                    && button.imagePosition == .imageOnly && bar.zoomSlider.isHidden)
            } else {
                check("\(width)pt footer exposes the task count and adapts zoom", button.title.contains("1 task")
                    && button.imagePosition == .imageLeading && bar.zoomSlider.isHidden == (width < 450))
                if !bar.zoomSlider.isHidden {
                    check("\(width)pt zoom does not overlap the label or terminal", bar.bounds.contains(bar.zoomSlider.frame)
                        && !bar.zoomSlider.frame.intersects(label.frame) && !bar.zoomSlider.frame.intersects(button.frame))
                }
            }
        }
        check("active tasks use the status accent", button.contentTintColor?.isEqual(NSColor.controlAccentColor) == true)
        var clicks = 0
        bar.onTerminalToggle = { clicks += 1 }
        button.performClick(nil)
        check("footer button dispatches its toggle callback", clicks == 1)
        bar.setTerminalStatus(.make(state: .running, visible: false, activity: .idle, enabled: false))
        check("disabled footer cannot issue a toggle", !button.isEnabled)
        button.performClick(nil)
        check("disabled footer click does not invoke the action", clicks == 1)
        bar.setTerminalStatus(nil)
        bar.layoutSubtreeIfNeeded()
        check("removing window status preserves the original footer controls", button.isHidden && spinner.superview === bar
            && label.superview === bar && bar.zoomSlider.superview === bar && !bar.zoomSlider.isHidden)
        bar.endBusy()
    }

    @MainActor
    private static func paneChecks() async {
        let previousEnabled = AppPreferences.experimentalTerminalEnabled
        AppPreferences.experimentalTerminalEnabled = true
        let provider = EmptyProvider()
        let viewFile = provider.homeURL.appendingPathComponent("tursora-terminal-status-" + UUID().uuidString + ".json")
        let controller = MainWindowController(provider: provider, places: PlacesModel(), initialURL: provider.homeURL,
            viewPropertiesStore: DirectoryViewPropertiesStore(fileURL: viewFile))
        defer {
            controller.shutdownTerminal()
            controller.close()
            AppPreferences.experimentalTerminalEnabled = previousEnabled
            try? FileManager.default.removeItem(at: viewFile)
        }
        await loaded(controller.browser)
        for mode in [ViewMode.details, .icons] {
            controller.browser.setViewMode(mode)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            check("\(mode) initial footer does not construct a terminal", !controller.browser.statusBar.terminalStatusButton.isHidden
                && controller.terminalPanel == nil && !controller.isTerminalVisible)
        }
        let firstPage = controller.tabs.currentPage
        controller.toggleSplit(nil)
        await loaded(controller.browser)
        guard let right = firstPage.panes.last, firstPage.panes.count == 2 else { check("split creates two panes", false); return }
        check("only the rightmost pane hosts window terminal status", visibleHosts(controller) == [ObjectIdentifier(right.statusBar)])
        firstPage.activate(firstPage.panes[0])
        check("activating the left pane keeps terminal status at the right", visibleHosts(controller) == [ObjectIdentifier(right.statusBar)])
        controller.tabs.newTab(at: provider.homeURL)
        await loaded(controller.browser)
        let newHost = controller.browser.statusBar
        check("changing tabs moves the single status to the new rightmost pane", visibleHosts(controller) == [ObjectIdentifier(newHost)])
        controller.tabs.selectTab(at: 0)
        check("returning to a split tab restores its rightmost status", visibleHosts(controller) == [ObjectIdentifier(right.statusBar)])
        firstPage.closePane(right)
        check("closing the right pane moves status to the surviving pane", visibleHosts(controller) == [ObjectIdentifier(controller.browser.statusBar)])
        check("pane and tab status updates never launch a shell", controller.terminalPanel == nil && !controller.isTerminalVisible)
    }

    private static func visibleHosts(_ controller: MainWindowController) -> [ObjectIdentifier] {
        controller.tabs.pages.flatMap(\.panes).map(\.statusBar).filter { !$0.terminalStatusButton.isHidden }.map(ObjectIdentifier.init)
    }
    @MainActor private static func loaded(_ browser: BrowserViewController) async {
        let deadline = Date().addingTimeInterval(10)
        while browser.model.generation == 0 && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        check("footer pane fixture loads", browser.model.generation > 0)
    }
    private static func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "ok  " : "FAIL") terminal status: \(name)")
        if !condition { exit(1) }
    }
    private final class EmptyProvider: FileProvider {
        let homeURL = FileManager.default.temporaryDirectory
        func displayName(for url: URL) -> String { url.lastPathComponent }
        func listDirectory(_ url: URL) throws -> [FileItem] { [] }
    }
}

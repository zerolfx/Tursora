import AppKit

/// File-status wording and narrow-pane controls stay independent of terminal
/// visibility. Exact strings also reject accidental disk-capacity suffixes.
enum StatusBarSmokeTests: SmokeSuite {
    static let checkPrefix = "file status: "
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            print("== file status bar ==")
            textAndLayoutChecks()
            await paneChecks()
            completion()
        }
    }

    @MainActor private static func textAndLayoutChecks() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 720, height: StatusBarView.height))
        guard let label = bar.subviews.compactMap({ $0 as? NSTextField }).first,
              let spinner = bar.subviews.compactMap({ $0 as? NSProgressIndicator }).first else {
            check("file label and progress indicator exist", false); return
        }
        let cases: [(String, () -> Void)] = [
            ("12 items", { bar.update(itemCount: 12, selectedCount: 0) }),
            ("1 item", { bar.update(itemCount: 1, selectedCount: 0) }),
            ("3 of 12 items", { bar.update(itemCount: 3, totalCount: 12, selectedCount: 0) }),
            ("3 of 12 selected", { bar.update(itemCount: 12, selectedCount: 3) }),
            ("Search Results — 4 items", { bar.update(itemCount: 4, selectedCount: 0, searchStatus: "Search Results") }),
            ("ZIP · Read-only — 1 of 2 selected", { bar.update(itemCount: 2, selectedCount: 1, archiveStatus: "ZIP · Read-only") })
        ]
        bar.beginBusy()
        for (expected, update) in cases {
            update()
            check("exact file status: \(expected)", bar.statusText == expected)
        }
        // Geometry depends on pane width, independently of the status wording.
        // Keep both sides of the compact-layout boundary in this matrix.
        for width: CGFloat in [178, 220, 359, 360, 720] {
            bar.setFrameSize(NSSize(width: width, height: StatusBarView.height))
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            check("\(width)pt status keeps counts/context separate from file progress", label.frame.width >= 64
                && bar.bounds.contains(label.frame) && bar.bounds.contains(spinner.frame) && !label.frame.intersects(spinner.frame))
            check("\(width)pt zoom yields space in a narrow pane", bar.zoomSlider.isHidden == (width < 360))
            if !bar.zoomSlider.isHidden {
                check("\(width)pt visible zoom stays separate", bar.bounds.contains(bar.zoomSlider.frame)
                    && !bar.zoomSlider.frame.intersects(label.frame) && !bar.zoomSlider.frame.intersects(spinner.frame))
            }
        }
        check("ZIP context retains its read-only explanation", label.toolTip?.contains("temporary copies") == true)
        bar.update(itemCount: 4, selectedCount: 0, searchStatus: "Search Results")
        check("search context retains its file-location explanation", label.toolTip?.contains("original file locations") == true)
        bar.update(itemCount: 12, selectedCount: 0)
        check("normal status removes contextual tooltip", label.toolTip == nil && bar.toolTip == nil)
        check("footer contains only file text progress and zoom", bar.subviews.count == 3 && !bar.subviews.contains { $0 is NSButton })
        var zoom = -1
        bar.onZoomChanged = { zoom = $0 }
        bar.setZoom(index: 2, count: 7)
        bar.zoomSlider.doubleValue = 4
        check("real zoom action remains connected", bar.zoomSlider.action.map { NSApp.sendAction($0, to: bar.zoomSlider.target, from: bar.zoomSlider) } == true && zoom == 4)
        bar.endBusy()
    }

    @MainActor private static func paneChecks() async {
        let previousEnabled = AppPreferences.experimentalTerminalEnabled
        AppPreferences.experimentalTerminalEnabled = true
        let provider = SmokeFixtures.EmptyProvider()
        let viewFile = provider.homeURL.appendingPathComponent("tursora-file-status-" + UUID().uuidString + ".json")
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
            check("\(mode) pane shows counts without capacity or terminal controls", controller.browser.statusBar.statusText == "0 items" && noFooterButtons(controller))
        }
        controller.toggleSplit(nil)
        await loaded(controller.browser)
        controller.tabs.newTab(at: provider.homeURL)
        await loaded(controller.browser)
        controller.toggleTerminal(nil)
        check("opening terminal leaves every pane footer unchanged", controller.isTerminalVisible && noFooterButtons(controller)
            && controller.tabs.pages.flatMap(\.panes).allSatisfy { $0.statusBar.statusText == "0 items" })
        controller.hideTerminal()
        controller.tabs.selectTab(at: 0)
        check("hidden terminal and tab changes add no footer controls", !controller.isTerminalVisible && noFooterButtons(controller))
    }

    private static func noFooterButtons(_ controller: MainWindowController) -> Bool {
        controller.tabs.pages.flatMap(\.panes).allSatisfy { !$0.statusBar.subviews.contains { $0 is NSButton } }
    }
    @MainActor private static func loaded(_ browser: BrowserViewController) async {
        await expectEventually("pane fixture loads") { browser.model.generation > 0 }
    }
}

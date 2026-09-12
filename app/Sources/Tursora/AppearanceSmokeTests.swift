import AppKit

/// Exercise existing layer surfaces across appearance changes without changing
/// the application's or the user's system appearance preference.
enum AppearanceSmokeTests {
    static func run(browser: BrowserViewController, completion: @escaping () -> Void) {
        Task { @MainActor in
            await runChecks(browser: browser)
            completion()
        }
    }

    @MainActor private static func runChecks(browser: BrowserViewController) async {
        print("== adaptive appearance surfaces ==")
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = AdaptiveLayerView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        surface.semanticBackgroundColor = .windowBackgroundColor
        surface.semanticBorderColor = .separatorColor
        window.appearance = light
        window.contentView = surface
        window.orderFront(nil)
        // Resolve under a deliberately different ambient appearance: layers
        // must follow their owner even when another window is being drawn.
        dark.performAsCurrentDrawingAppearance { surface.updateLayer() }
        let lightFill = surface.layer?.backgroundColor
        check("semantic layer resolves its own light appearance",
              matches(lightFill, .windowBackgroundColor, in: light)
              && matches(surface.layer?.borderColor, .separatorColor, in: light))
        window.appearance = dark
        let darkRendered = await rendered(surface) {
            matches(surface.layer?.backgroundColor, .windowBackgroundColor, in: dark)
                && matches(surface.layer?.borderColor, .separatorColor, in: dark)
        }
        check("attached semantic layer redraws after a dark appearance change", darkRendered)
        check("light and dark surface fills differ", lightFill != surface.layer?.backgroundColor)
        window.appearance = light
        let lightRendered = await rendered(surface) {
            matches(surface.layer?.backgroundColor, .windowBackgroundColor, in: light)
                && matches(surface.layer?.borderColor, .separatorColor, in: light)
        }
        check("attached semantic layer redraws when light appearance returns", lightRendered)

        window.contentView = NSView()
        let task = TransferTask(sources: [URL(fileURLWithPath: "/tmp/appearance-source")],
                                destination: URL(fileURLWithPath: "/tmp"), kind: .copy)
        let row = TransferTaskRowView(task: task)
        window.contentView?.pinToEdges(row)
        for appearance in [light, dark, light] {
            window.appearance = appearance
            let didRender = await rendered(row) {
                matches(row.layer?.borderColor, .separatorColor, in: appearance)
            }
            check("transfer card border follows \(appearance.name.rawValue)",
                  didRender)
        }

        let popup = CompletionPopup()
        defer { popup.hide() }
        let candidates = ["Documents/", "Downloads/"]
        let anchor = NSRect(x: 80, y: 240, width: 240, height: 24)
        window.appearance = light
        popup.show(candidates, below: anchor, in: window)
        popup.moveSelection(by: 1)
        for appearance in [light, dark, light] {
            window.appearance = appearance
            let popupSurface = popup.appearanceSurfaceForTesting
            let didRender = await rendered(popupSurface) {
                popupSurface.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                    == appearance.bestMatch(from: [.aqua, .darkAqua])
                  && matches(popupSurface.layer?.backgroundColor, .windowBackgroundColor, in: appearance)
                  && matches(popupSurface.layer?.borderColor, .separatorColor, in: appearance)
            }
            check("open completion popup follows parent \(appearance.name.rawValue)", didRender)
            check("completion appearance change preserves candidates and selection",
                  popup.candidates == candidates && popup.selectedCandidate == candidates[0])
        }
        popup.hide()
        window.appearance = dark
        popup.show(candidates, below: anchor, in: window)
        let reopened = await rendered(popup.appearanceSurfaceForTesting) {
            matches(popup.appearanceSurfaceForTesting.layer?.backgroundColor, .windowBackgroundColor, in: dark)
        }
        check("completion popup reopened after a hidden theme change uses the new appearance",
              reopened)

        let previousAppearance = browser.view.appearance
        defer {
            browser.view.appearance = previousAppearance
            browser.setActiveIndicator(nil)
        }
        browser.setActiveIndicator(true)
        let indicator = browser.activeIndicatorForTesting
        for appearance in [light, dark, light] {
            browser.view.appearance = appearance
            let didRender = await rendered(indicator) {
                indicator.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                    == appearance.bestMatch(from: [.aqua, .darkAqua])
                    && matches(indicator.layer?.backgroundColor, .controlAccentColor, in: appearance)
            }
            check("active pane indicator follows \(appearance.name.rawValue)",
                  didRender)
        }
        browser.setActiveIndicator(false)
        let cleared = await rendered(indicator) { indicator.layer?.backgroundColor?.alpha == 0 }
        check("inactive pane indicator remains transparent", cleared)
    }

    /// Appearance invalidation is delivered through AppKit's display cycle.
    /// Check actual layer output while yielding the main run loop, without
    /// forcing needsDisplay or directly invoking the updateLayer override.
    @MainActor private static func rendered(_ view: NSView, matches condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            view.window?.contentView?.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            view.displayIfNeeded()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }

    private static func matches(_ actual: CGColor?, _ color: NSColor, in appearance: NSAppearance) -> Bool {
        var expected: CGColor?
        appearance.performAsCurrentDrawingAppearance { expected = color.cgColor }
        return actual != nil && actual == expected
    }

    private static func check(_ name: String, _ success: Bool) {
        print("\(success ? "ok  " : "FAIL") appearance: \(name)")
        if !success { fflush(stdout); exit(1) }
    }
}

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowControllers: [MainWindowController] = []
    let provider: FileProvider = LocalFileProvider()
    let places = PlacesModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        let wc = newWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        if SmokeTest.isRequested { SmokeTest.run(wc) }
    }

    /// Info windows save a comment still being typed when they close; ⌘Q
    /// closes nothing by itself, so do it here.
    func applicationWillTerminate(_ notification: Notification) {
        InfoWindowController.closeAll()
    }

    /// A file manager stays alive with no windows open, like Finder does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no windows open should give you one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(self) }
        return true
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
    func newWindow(at url: URL) -> MainWindowController {
        let wc = MainWindowController(provider: provider, places: places, initialURL: url)
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

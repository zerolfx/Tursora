import AppKit
import UniformTypeIdentifiers

enum SettingsSmokeTests: SmokeSuite {
    static func run() {
        print("== application settings ==")
        let domain = "com.tursora.settings-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let center = NotificationCenter()
        let store = AppPreferences.Store(defaults: defaults, notificationCenter: center)
        check("settings: new installs show extensions with terminal and ZIP browsing enabled",
              store.showFileExtensions && store.experimentalTerminalEnabled && store.experimentalZIPBrowsingEnabled)
        check("settings: filter defaults to Command F", store.filterShortcut == .defaultFilter)
        check("settings: workspace restoration defaults on", store.restoreWorkspaceOnLaunch)
        let freshController = SettingsWindowController(preferences: store, workspaceStore: WorkspaceSessionStore(fileURL: nil))
        check("settings UI: fresh controls enable both features without saving a choice",
              freshController.terminalCheckbox.state == .on && freshController.zipCheckbox.state == .on
              && defaults.object(forKey: "experimentalTerminalEnabled") == nil
              && defaults.object(forKey: "experimentalZIPBrowsingEnabled") == nil)
        freshController.close()
        let changes = Counter()
        let observer = center.addObserver(forName: .tursoraPreferencesChanged, object: store, queue: nil) { _ in
            changes.value += 1
        }
        defer { center.removeObserver(observer) }
        check("settings: reading defaults does not write feature choices",
              defaults.object(forKey: "experimentalTerminalEnabled") == nil
              && defaults.object(forKey: "experimentalZIPBrowsingEnabled") == nil)
        store.experimentalTerminalEnabled = true
        store.experimentalZIPBrowsingEnabled = true
        check("settings: explicit default choices are saved without unnecessary notifications",
              defaults.object(forKey: "experimentalTerminalEnabled") as? Bool == true
              && defaults.object(forKey: "experimentalZIPBrowsingEnabled") as? Bool == true
              && changes.value == 0)
        store.showFileExtensions = false
        store.experimentalTerminalEnabled = false
        store.experimentalZIPBrowsingEnabled = false
        let restored = AppPreferences.Store(defaults: defaults, notificationCenter: center)
        check("settings: all toggles persist across preference instances",
              !restored.showFileExtensions && !restored.experimentalTerminalEnabled && !restored.experimentalZIPBrowsingEnabled)
        check("settings: changes publish one notification each", changes.value == 3)
        store.experimentalTerminalEnabled = false
        check("settings: unchanged values do not cause redundant refreshes", changes.value == 3)

        let controlI = AppPreferences.Shortcut(keyEquivalent: "i", modifierFlags: .control)
        let modifiedF = AppPreferences.Shortcut(keyEquivalent: "f", modifierFlags: [.command, .option, .shift])
        check("settings: Control and additional Option/Shift shortcut combinations validate",
              controlI.validationError() == nil && modifiedF.validationError() == nil)
        check("settings: typing and Option-only combinations are rejected",
              AppPreferences.Shortcut(keyEquivalent: "f", modifierFlags: []).validationError() != nil
              && AppPreferences.Shortcut(keyEquivalent: "f", modifierFlags: .shift).validationError() != nil
              && AppPreferences.Shortcut(keyEquivalent: "f", modifierFlags: .option).validationError() != nil)
        check("settings: function keys can be assigned while terminal and system shortcuts conflict",
              AppPreferences.Shortcut(keyEquivalent: "\u{f70b}", modifierFlags: []).validationError() == nil
              && AppPreferences.Shortcut(keyEquivalent: "\u{f707}", modifierFlags: []).validationError() != nil
              && AppPreferences.Shortcut(keyEquivalent: " ", modifierFlags: .command).validationError() != nil)
        check("settings: existing app and system shortcuts are reserved",
              [("q", NSEvent.ModifierFlags.command), (",", .command), ("k", .command), ("1", .command),
               ("s", [.control, .command]), ("z", [.shift, .command]), ("`", .command)].allSatisfy {
                  AppPreferences.Shortcut(keyEquivalent: $0.0, modifierFlags: $0.1).validationError() != nil
              })
        check("settings: uppercase menu equivalents include Shift",
              AppPreferences.Shortcut(keyEquivalent: "Z", modifierFlags: .command)
              == AppPreferences.Shortcut(keyEquivalent: "z", modifierFlags: [.command, .shift]))
        check("settings: shortcut display uses standard modifier order", modifiedF.displayString == "⌥⇧⌘F")
        do { try store.setFilterShortcut(controlI) }
        catch { check("settings: valid shortcut saves", false) }
        check("settings: custom shortcut persists and publishes changes",
              restored.filterShortcut == controlI && changes.value == 4)
        do { try store.setFilterShortcut(AppPreferences.Shortcut(keyEquivalent: "q", modifierFlags: .command)) }
        catch { /* The existing valid shortcut must survive a rejected edit. */ }
        check("settings: rejected conflict leaves the previous shortcut intact", store.filterShortcut == controlI && changes.value == 4)
        let menu = NSMenu()
        let extraCommand = NSMenuItem(title: "Additional Command", action: Selector(("extraCommand:")), keyEquivalent: "i")
        extraCommand.keyEquivalentModifierMask = .control
        menu.addItem(extraCommand)
        check("settings: new menu bindings are also checked dynamically",
              controlI.validationError(in: menu)?.contains("Additional Command") == true)
        extraCommand.action = Selector(("focusFilter:"))
        check("settings: the filter does not conflict with its own menu binding", controlI.validationError(in: menu) == nil)

        let controller = SettingsWindowController(preferences: store, workspaceStore: WorkspaceSessionStore(fileURL: nil))
        check("settings UI: controls reflect persisted preferences",
              controller.extensionsCheckbox.state == .off && controller.terminalCheckbox.state == .off
              && controller.zipCheckbox.state == .off && controller.shortcutRecorder.shortcut == controlI)
        controller.extensionsCheckbox.state = .on
        controller.toggleExtensions(controller.extensionsCheckbox)
        controller.terminalCheckbox.state = .on
        controller.toggleTerminal(controller.terminalCheckbox)
        controller.zipCheckbox.state = .on
        controller.toggleZIPBrowsing(controller.zipCheckbox)
        check("settings UI: controls apply all three settings immediately",
              store.showFileExtensions && store.experimentalTerminalEnabled && store.experimentalZIPBrowsingEnabled)
        check("settings UI: startup option initially reflects the stored preference", controller.restoreWorkspaceCheckbox.state == .on)
        controller.restoreWorkspaceCheckbox.performClick(nil)
        check("settings UI: startup action persists and refreshes its control", !restored.restoreWorkspaceOnLaunch && controller.restoreWorkspaceCheckbox.state == .off)
        store.restoreWorkspaceOnLaunch = true
        check("settings UI: externally enabling restoration refreshes Startup", controller.restoreWorkspaceCheckbox.state == .on)
        check("settings UI: recorder applies a valid shortcut",
              controller.shortcutRecorder.record(keyEquivalent: "f", modifierFlags: [.command, .option, .shift])
              && store.filterShortcut == modifiedF)
        check("settings UI: recorder rejects conflicts with inline explanation",
              !controller.shortcutRecorder.record(keyEquivalent: "q", modifierFlags: .command)
              && !controller.shortcutMessage.stringValue.isEmpty && store.filterShortcut == modifiedF)
        controller.resetShortcut(nil)
        check("settings UI: Reset restores Command F and clears the error",
              store.filterShortcut == .defaultFilter && controller.shortcutRecorder.shortcut == .defaultFilter
              && controller.shortcutMessage.stringValue.isEmpty)
        store.experimentalTerminalEnabled = false
        check("settings UI: external preference changes refresh controls", controller.terminalCheckbox.state == .off)
        store.experimentalTerminalEnabled = true
        controller.shortcutRecorder.startRecording(nil)
        let recordedEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)!
        controller.shortcutRecorder.keyDown(with: recordedEvent)
        check("settings UI: a recorded keyboard event persists the combination and stops capture",
              store.filterShortcut == controlI && !controller.shortcutRecorder.isRecording)
        controller.shortcutRecorder.startRecording(nil)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        controller.shortcutRecorder.keyDown(with: escape)
        check("settings UI: Escape cancels recording without changing the shortcut",
              store.filterShortcut == controlI && !controller.shortcutRecorder.isRecording)
        controller.resetShortcut(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let controls = [controller.restoreWorkspaceCheckbox, controller.extensionsCheckbox, controller.terminalCheckbox, controller.zipCheckbox]
        check("settings UI: every General section is reachable within the scroll viewport",
              controls.allSatisfy { control in
                  guard let content = controller.window?.contentView else { return false }
                  control.scrollToVisible(control.bounds)
                  content.layoutSubtreeIfNeeded()
                  let rect = control.convert(control.bounds, to: content)
                  let clip = controller.generalScrollView.contentView
                  return content.bounds.contains(rect) && clip.bounds.contains(control.convert(control.bounds, to: clip))
                      && rect.width > 300 && rect.height >= 14
              })
        defaults.set("q", forKey: "filterShortcutKey")
        defaults.set(NSEvent.ModifierFlags.command.rawValue, forKey: "filterShortcutModifiers")
        check("settings: invalid persisted shortcut safely falls back", store.filterShortcut == .defaultFilter)
        controller.close()
        defaultFileManager()
    }

    private final class Counter { var value = 0 }

    /// The default-folder-handler setting. The parts that can be checked
    /// without changing the user's system are the wording, the enabled state
    /// and the identity rule; actually claiming the role opens a system
    /// confirmation and is never driven from a test.
    static func defaultFileManager() {
        print("== default folder handler ==")
        check("handler: the status names the application that opens folders",
              DefaultFileManager.statusText(isCurrent: false, currentName: "Finder") == "Folders open in Finder.")
        check("handler: it says so plainly once Tursora holds the role",
              DefaultFileManager.statusText(isCurrent: true, currentName: "Tursora") == "Tursora opens folders.")
        check("handler: an unknown handler still produces a sentence, not an empty line",
              DefaultFileManager.statusText(isCurrent: false, currentName: nil) == "Folders open in another application."
                  && DefaultFileManager.statusText(isCurrent: false, currentName: "") == "Folders open in another application.")
        check("handler: folders are the type macOS opens with a file manager",
              DefaultFileManager.folderType.identifier == "public.folder")
        check("handler: the system reports some handler for a folder today",
              DefaultFileManager.currentHandlerURL() != nil)

        // Identity is compared by bundle identifier, not by path: the same
        // application has a different URL from a build folder, a disk image and
        // /Applications, and a path comparison would call it "not the default".
        // Asserting that against the live system proves nothing — the handler
        // is Finder and this binary has no bundle identifier either way — so
        // the rule is driven with two stub bundles that differ only in path.
        let stubs = FileManager.default.temporaryDirectory
            .appendingPathComponent("tursora-handler-\(getpid())")
        defer { try? FileManager.default.removeItem(at: stubs) }
        func stub(_ name: String, identifier: String) -> Bundle? {
            let url = stubs.appendingPathComponent("\(name).app")
            let contents = url.appendingPathComponent("Contents")
            try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
                                        "CFBundleName": name, "CFBundleExecutable": name]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            else { return nil }
            try? data.write(to: contents.appendingPathComponent("Info.plist"))
            return Bundle(url: url)
        }
        final class FixedWorkspace: NSWorkspace {
            var handler: URL?
            override func urlForApplication(toOpen contentType: UTType) -> URL? { handler }
        }
        let installed = stub("Installed", identifier: "com.tursora.Tursora")
        let sameAppOtherPath = stub("BuildFolderCopy", identifier: "com.tursora.Tursora")
        let otherApp = stub("SomethingElse", identifier: "com.example.Other")
        let space = FixedWorkspace()
        if let installed, let sameAppOtherPath, let otherApp {
            space.handler = installed.bundleURL
            check("handler: the same application at a different path is still recognised as the default",
                  DefaultFileManager.isCurrent(workspace: space, bundle: sameAppOtherPath),
                  "\(sameAppOtherPath.bundleURL.lastPathComponent) vs \(installed.bundleURL.lastPathComponent)")
            space.handler = otherApp.bundleURL
            check("handler: a different application holding the role is not mistaken for us",
                  !DefaultFileManager.isCurrent(workspace: space, bundle: sameAppOtherPath))
            space.handler = nil
            check("handler: no handler at all is not us either",
                  !DefaultFileManager.isCurrent(workspace: space, bundle: sameAppOtherPath))
            space.handler = installed.bundleURL
            check("handler: the name shown is the handler's, read from the filesystem",
                  DefaultFileManager.currentHandlerName(workspace: space)?.hasPrefix("Installed") == true,
                  DefaultFileManager.currentHandlerName(workspace: space) ?? "nil")
        }

        // The controller is not synced by the test: it must arrive already
        // correct, or nothing here observes whether the controller syncs at all.
        let controller = SettingsWindowController()
        _ = controller.window
        let line = controller.defaultFileManagerStatus.stringValue
        let title = controller.defaultFileManagerButton.title
        check("handler: the settings line is one of the three sentences, never blank", [
            "Tursora opens folders.", "Folders open in another application.",
        ].contains(line) || (line.hasPrefix("Folders open in ") && line.hasSuffix(".")), line)
        // Button and line are two separate outputs of the same state; checking
        // them against each other catches a drift that re-deriving isCurrent()
        // in the assertion cannot, because that only compares code with itself.
        let claimsTheRole = line == "Tursora opens folders."
        check("handler: the button agrees with the line it sits under",
              title == (claimsTheRole ? "Tursora Is the Default" : "Set Tursora as Default")
                  && controller.defaultFileManagerButton.isEnabled == !claimsTheRole,
              "line=\(line) title=\(title) enabled=\(controller.defaultFileManagerButton.isEnabled)")
        // A pending system confirmation must not be re-armed by a refresh.
        controller.makeDefaultFileManager(nil)
        check("handler: the button stays disabled while a request is outstanding",
              !controller.defaultFileManagerButton.isEnabled || !controller.isClaimingFolderRole)
        controller.close()
    }

}

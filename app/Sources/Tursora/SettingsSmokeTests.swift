import AppKit

enum SettingsSmokeTests {
    static func run() {
        print("== application settings ==")
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "ok  " : "FAIL") \(name)")
            if !condition { exit(1) }
        }
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
        check("settings: navigation/function keys cannot replace file-view shortcuts",
              ["\t", " ", "\r", "\u{f707}"].allSatisfy {
                  AppPreferences.Shortcut(keyEquivalent: $0, modifierFlags: .command).validationError() != nil
              })
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
    }

    private final class Counter { var value = 0 }
}

import AppKit

/// Exercises our update policy and actual controls without constructing Sparkle.
enum UpdateSmokeTests: SmokeSuite {
    static func run() {
        print("== software updates ==")
        let domain = "com.tursora.updates-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: MockDriver.checksKey)
        defaults.set(true, forKey: MockDriver.downloadsKey)
        let driver = MockDriver(defaults: defaults)
        let center = NotificationCenter()
        let updater = AppUpdater(driver: driver, notificationCenter: center)
        let changes = Counter()
        let observer = center.addObserver(forName: AppUpdater.didChange, object: updater, queue: nil) { _ in
            changes.value += 1
        }
        defer { center.removeObserver(observer) }

        check("updates: construction does not start a driver or overwrite saved preferences",
              driver.startCount == 0 && driver.preferenceWriteCount == 0
              && !updater.automaticallyChecksForUpdates && defaults.bool(forKey: MockDriver.downloadsKey))
        check("updates: actions remain unavailable until startup succeeds",
              !updater.isAvailable && !updater.canCheckForUpdates && !updater.allowsAutomaticUpdates
              && updater.statusText == "Updates have not started.")
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = false
        updater.checkForUpdates(nil)
        check("updates: pre-start actions cannot write preferences or launch checks",
              driver.preferenceWriteCount == 0 && driver.checkCount == 0)
        updater.start()
        updater.start()
        check("updates: repeated startup starts once and preserves both saved choices",
              driver.startCount == 1 && driver.preferenceWriteCount == 0 && updater.isAvailable
              && !updater.automaticallyChecksForUpdates && defaults.bool(forKey: MockDriver.downloadsKey))
        check("updates: disabling automatic checks preserves manual checking",
              updater.canCheckForUpdates && !updater.allowsAutomaticUpdates
              && updater.statusText == "No update checks yet.")
        updater.automaticallyDownloadsUpdates = false
        check("updates: disabled automatic-download control cannot change its saved choice",
              driver.preferenceWriteCount == 0 && defaults.bool(forKey: MockDriver.downloadsKey)
              && !updater.automaticallyDownloadsUpdates)
        let unchangedCount = changes.value
        updater.automaticallyChecksForUpdates = false
        check("updates: assigning an unchanged setting neither writes nor refreshes",
              driver.preferenceWriteCount == 0 && changes.value == unchangedCount)
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = false
        let restoredDriver = MockDriver(defaults: defaults)
        let restored = AppUpdater(driver: restoredDriver, notificationCenter: NotificationCenter())
        restored.start()
        check("updates: settings pass through to driver persistence across service instances",
              restored.automaticallyChecksForUpdates && !restored.automaticallyDownloadsUpdates
              && restoredDriver.preferenceWriteCount == 0)
        driver.permitsAutomaticUpdates = false
        driver.onChange?()
        updater.automaticallyDownloadsUpdates = true
        check("updates: host policy can prohibit automatic downloads while manual checks remain usable",
              !updater.allowsAutomaticUpdates && !updater.automaticallyDownloadsUpdates && updater.canCheckForUpdates)
        driver.permitsAutomaticUpdates = true
        driver.onChange?()

        let preferences = AppPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
        let views = DirectoryViewPropertiesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tursora-update-views-\(UUID().uuidString).json"))
        let first = SettingsWindowController(preferences: preferences, viewPropertiesStore: views, updater: updater)
        let second = SettingsWindowController(preferences: preferences, viewPropertiesStore: views, updater: updater)
        defer { first.close(); second.close() }
        check("updates UI: both windows initially reflect driver state and available actions",
              [first, second].allSatisfy {
                  $0.automaticUpdateChecksCheckbox.state == .on && $0.automaticUpdateChecksCheckbox.isEnabled
                  && $0.automaticUpdateDownloadsCheckbox.state == .off && $0.automaticUpdateDownloadsCheckbox.isEnabled
                  && $0.checkForUpdatesButton.isEnabled && $0.updateStatus.stringValue == updater.statusText
              })
        check("updates UI: General stays the initial tab and Updates is independently selectable",
              first.settingsTabs.tabViewItems.map(\.label) == ["General", "Shortcuts", "Terminal", "Updates"]
              && first.settingsTabs.selectedTabViewItem?.identifier as? String == "general")
        first.settingsTabs.selectTabViewItem(withIdentifier: "updates")
        first.window?.contentView?.layoutSubtreeIfNeeded()
        checkUpdateLayout(first)
        first.automaticUpdateDownloadsCheckbox.performClick(nil)
        check("updates UI: clicking automatic installation saves and refreshes both windows",
              updater.automaticallyDownloadsUpdates
              && first.automaticUpdateDownloadsCheckbox.state == .on
              && second.automaticUpdateDownloadsCheckbox.state == .on)
        first.automaticUpdateChecksCheckbox.performClick(nil)
        check("updates UI: disabling checks disables installation while preserving its saved preference",
              !updater.automaticallyChecksForUpdates && !updater.automaticallyDownloadsUpdates
              && defaults.bool(forKey: MockDriver.downloadsKey)
              && [first, second].allSatisfy {
                  $0.automaticUpdateChecksCheckbox.state == .off
                  && $0.automaticUpdateDownloadsCheckbox.state == .off
                  && !$0.automaticUpdateDownloadsCheckbox.isEnabled && $0.checkForUpdatesButton.isEnabled
              })
        check("updates UI: manual button has a real updater target and unambiguous selector",
              first.checkForUpdatesButton.target === updater
              && first.checkForUpdatesButton.action == #selector(AppUpdater.checkForUpdates(_:)))
        first.checkForUpdatesButton.performClick(nil)
        updater.checkForUpdates(nil)
        check("updates UI: manual checking runs with scheduling off and rejects a busy repeat",
              driver.checkCount == 1 && !first.checkForUpdatesButton.isEnabled
              && !second.checkForUpdatesButton.isEnabled && !updater.canCheckForUpdates)
        let date = Date(timeIntervalSince1970: 1_789_200_000)
        driver.lastUpdateCheckDate = date
        driver.canCheckForUpdates = true
        driver.onChange?()
        let expectedStatus = "Last checked: " + DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        check("updates UI: completion refreshes the last-check date and re-enables both buttons",
              first.checkForUpdatesButton.isEnabled && second.checkForUpdatesButton.isEnabled
              && first.updateStatus.stringValue == expectedStatus && second.updateStatus.stringValue == expectedStatus)
        second.automaticUpdateChecksCheckbox.performClick(nil)
        check("updates UI: re-enabling checks restores saved automatic installation in both windows",
              updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
              && first.automaticUpdateDownloadsCheckbox.isEnabled && second.automaticUpdateDownloadsCheckbox.isEnabled)
        driver.permitsAutomaticUpdates = false
        driver.onChange?()
        check("updates UI: a driver policy change refreshes automatic-installation enablement",
              !first.automaticUpdateDownloadsCheckbox.isEnabled && !second.automaticUpdateDownloadsCheckbox.isEnabled
              && first.checkForUpdatesButton.isEnabled)

        failureChecks(defaults: defaults, preferences: preferences, views: views)
        headlessAndMenuChecks()
        injectedMenuChecks(updater: updater, driver: driver)
    }

    private static func failureChecks(defaults: UserDefaults, preferences: AppPreferences.Store,
                                      views: DirectoryViewPropertiesStore) {
        let driver = MockDriver(defaults: defaults)
        driver.startError = NSError(domain: "Tursora.UpdateSmokeTests", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "The update test configuration is unavailable."])
        let updater = AppUpdater(driver: driver, notificationCenter: NotificationCenter())
        let settings = SettingsWindowController(preferences: preferences, viewPropertiesStore: views, updater: updater)
        defer { settings.close() }
        updater.start()
        updater.checkForUpdates(nil)
        check("updates: a startup error disables actions and leaves the driver unstarted",
              !updater.isStarted && !updater.isAvailable && !updater.canCheckForUpdates && driver.checkCount == 0)
        check("updates UI: startup failure appears inline without a modal or sheet",
              settings.updateStatus.stringValue.contains("The update test configuration is unavailable.")
              && !settings.automaticUpdateChecksCheckbox.isEnabled
              && !settings.automaticUpdateDownloadsCheckbox.isEnabled && !settings.checkForUpdatesButton.isEnabled
              && settings.window?.attachedSheet == nil && NSApp.modalWindow == nil)
        driver.startError = nil
        updater.start()
        check("updates: retry after a startup error clears the failure and refreshes settings",
              driver.startCount == 2 && updater.isAvailable && updater.unavailableReason == nil
              && settings.checkForUpdatesButton.isEnabled
              && settings.updateStatus.stringValue == "No update checks yet.")
        updater.start()
        check("updates: a successful retry is also idempotent", driver.startCount == 2)
    }

    private static func headlessAndMenuChecks() {
        let updater = AppUpdater.shared
        updater.start()
        updater.checkForUpdates(nil)
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        check("updates: smoke shared service never starts or enables network-capable actions",
              SmokeTest.isRequested && !updater.isStarted && !updater.isAvailable
              && !updater.canCheckForUpdates && !updater.automaticallyChecksForUpdates
              && !updater.automaticallyDownloadsUpdates
              && updater.statusText == "Updates are disabled during automated tests.")
        guard let delegate = NSApp.delegate as? AppDelegate,
              let menu = NSApp.mainMenu?.items.first?.submenu,
              let item = menu.items.first(where: { $0.title == "Check for Updates…" }) else {
            check("updates menu: application menu contains the update command", false)
            return
        }
        check("updates menu: command routes to the application delegate without reserving a shortcut",
              item.action == #selector(AppDelegate.checkForUpdates(_:)) && item.target == nil
              && item.keyEquivalent.isEmpty && delegate.responds(to: item.action))
        menu.update()
        check("updates menu: actual menu validation disables checking during smoke runs",
              !delegate.validateMenuItem(item) && !item.isEnabled)
        let sent = NSApp.sendAction(item.action!, to: delegate, from: item)
        check("updates menu: real selector dispatch safely obeys headless unavailability",
              sent && !updater.isStarted && NSApp.modalWindow == nil)
        let unrelated = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        check("updates menu: updater availability does not disable other application commands",
              delegate.validateMenuItem(unrelated))
    }

    private static func checkUpdateLayout(_ settings: SettingsWindowController) {
        guard let content = settings.window?.contentView,
              let tab = settings.settingsTabs.selectedTabViewItem?.view else {
            check("updates UI: selected tab has content", false)
            return
        }
        let controls: [NSView] = [settings.automaticUpdateChecksCheckbox, settings.automaticUpdateDownloadsCheckbox,
                                 settings.checkForUpdatesButton, settings.updateStatus]
        check("updates UI: every update control has a usable frame inside its tab and window",
              controls.allSatisfy { view in
                  let frame = view.convert(view.bounds, to: tab)
                  return frame.width > 100 && frame.height >= 14 && tab.bounds.contains(frame)
                      && content.bounds.contains(view.convert(view.bounds, to: content))
              })
        let frames = controls.map { $0.convert($0.bounds, to: tab) }
        check("updates UI: checkboxes, manual action and status never overlap",
              frames.enumerated().allSatisfy { index, frame in
                  frames.dropFirst(index + 1).allSatisfy { !frame.intersects($0) }
              })
        check("updates UI: the automatic-installation checkbox title fits without truncation",
              settings.automaticUpdateDownloadsCheckbox.frame.width + 1
              >= settings.automaticUpdateDownloadsCheckbox.intrinsicContentSize.width)
    }

    private static func injectedMenuChecks(updater: AppUpdater, driver: MockDriver) {
        let delegate = AppDelegate(updater: updater)
        guard let menu = MainMenu.build().items.first?.submenu,
              let item = menu.items.first(where: { $0.action == #selector(AppDelegate.checkForUpdates(_:)) }) else {
            check("updates menu: injectable delegate uses the production command", false)
            return
        }
        // A detached menu has no application responder chain. Give its actual
        // production item the injected delegate while preserving its selector.
        item.target = delegate
        menu.update()
        check("updates menu: a ready driver enables the actual menu item",
              delegate.validateMenuItem(item) && item.isEnabled)
        let oldCount = driver.checkCount
        let sent = NSApp.sendAction(item.action!, to: item.target, from: item)
        menu.update()
        check("updates menu: real dispatch starts one check and disables a busy menu item",
              sent && driver.checkCount == oldCount + 1 && !item.isEnabled && !delegate.validateMenuItem(item))
        _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        check("updates menu: repeated dispatch while busy cannot create a second check",
              driver.checkCount == oldCount + 1)
        driver.canCheckForUpdates = true
        driver.onChange?()
        menu.update()
        check("updates menu: completing the check re-enables the command", item.isEnabled)
        updater.automaticallyChecksForUpdates = false
        menu.update()
        check("updates menu: opting out of scheduling leaves the manual menu command enabled", item.isEnabled)
    }

    private final class Counter { var value = 0 }

    private final class MockDriver: AppUpdateDriver {
        static let checksKey = "updateSmokeAutomaticallyChecks"
        static let downloadsKey = "updateSmokeAutomaticallyDownloads"
        private let defaults: UserDefaults
        var onChange: (() -> Void)?
        var permitsAutomaticUpdates = true
        var allowsAutomaticUpdates: Bool { permitsAutomaticUpdates && automaticallyChecksForUpdates }
        var canCheckForUpdates = true
        var lastUpdateCheckDate: Date?
        var startError: Error?
        private(set) var startCount = 0
        private(set) var checkCount = 0
        private(set) var preferenceWriteCount = 0

        init(defaults: UserDefaults) { self.defaults = defaults }

        var automaticallyChecksForUpdates: Bool {
            get { defaults.bool(forKey: Self.checksKey) }
            set { defaults.set(newValue, forKey: Self.checksKey); preferenceWriteCount += 1; onChange?() }
        }
        var automaticallyDownloadsUpdates: Bool {
            // Sparkle's effective value is false while automatic updates are
            // unavailable; its stored choice survives disabling checks.
            get { allowsAutomaticUpdates && defaults.bool(forKey: Self.downloadsKey) }
            set { defaults.set(newValue, forKey: Self.downloadsKey); preferenceWriteCount += 1; onChange?() }
        }
        func start() throws {
            startCount += 1
            if let startError { throw startError }
        }
        func checkForUpdates() {
            checkCount += 1
            canCheckForUpdates = false
            onChange?()
        }
    }
}

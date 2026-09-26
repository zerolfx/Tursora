import AppKit

enum PreferencesIsolationSmokeTests: SmokeSuite {
    static let checkPrefix = "preferences isolation: "
    private static var productionSnapshot: NSDictionary?
    private static var productionDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    /// Called before NSApplication and every application-owned store/window.
    static func captureProductionPreferences() {
        productionSnapshot = (UserDefaults.standard.persistentDomain(forName: productionDomain) ?? [:]) as NSDictionary
    }

    static func run() {
        print("== preferences isolation ==")
        check("smoke preferences have a fresh named suite",
              AppDefaults.isolatedDomain?.hasPrefix("com.tursora.smoke.") == true
                  && AppDefaults.shared !== UserDefaults.standard)
        verifyProductionUnchanged()
        let domain = AppDefaults.isolatedDomain!
        let saved = AppDefaults.shared.persistentDomain(forName: domain) ?? [:]
        defer {
            AppDefaults.shared.setPersistentDomain(saved, forName: domain)
            NotificationCenter.default.post(name: .tursoraPreferencesChanged, object: AppPreferences.shared)
        }

        let preferences = AppPreferences.Store()
        preferences.experimentalZIPBrowsingEnabled.toggle()
        check("default preference stores write only the smoke suite",
              AppDefaults.shared.persistentDomain(forName: domain)?["experimentalZIPBrowsingEnabled"] as? Bool
                  == preferences.experimentalZIPBrowsingEnabled)
        let places = PlacesModel()
        AppDefaults.shared.set(["path:/synthetic/favourite"], forKey: "favouritesOrder")
        places.resetFavourites()
        check("real favourites reset uses the isolated suite",
              AppDefaults.shared.object(forKey: "favouritesOrder") == nil)
        check("test windows cannot autosave into the production domain",
              NSApp.windows.allSatisfy { $0.frameAutosaveName.isEmpty })
        check("isolated launches do not start the real updater", !AppUpdater.shared.isStarted && !AppUpdater.shared.isAvailable)
        verifyProductionUnchanged()
    }

    static func verifyProductionUnchanged() {
        guard let productionSnapshot else { check("initial production snapshot exists", false); return }
        let current = (UserDefaults.standard.persistentDomain(forName: productionDomain) ?? [:]) as NSDictionary
        check("application preferences in the production domain are unchanged", productionSnapshot.isEqual(current))
    }
}

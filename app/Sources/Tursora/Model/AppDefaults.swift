import Foundation

/// Application-owned preferences have one entry point. Smoke runs get a fresh
/// suite before any shared store or window is created, so even a crash cannot
/// overwrite the installed application's preferences.
enum AppDefaults {
    static let isolatedDomain: String? = {
        if SmokeTest.isRequested { return "com.tursora.smoke.\(UUID().uuidString)" }
        // Packaged-app QA can retain an isolated suite across its own restarts.
        if let domain = ProcessInfo.processInfo.environment["TURSORA_UI_TEST_DEFAULTS_DOMAIN"],
           domain.hasPrefix("com.tursora.ui-test."), domain.count <= 200,
           domain.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-".unicodeScalars.contains($0) }) {
            return domain
        }
        return nil
    }()

    static let shared: UserDefaults = {
        guard let domain = isolatedDomain else { return .standard }
        guard let defaults = UserDefaults(suiteName: domain) else {
            fatalError("Could not create the isolated preferences suite")
        }
        if SmokeTest.isRequested {
            atexit { AppDefaults.removeSmokeDomain() }
        }
        return defaults
    }()

    private static func removeSmokeDomain() {
        guard SmokeTest.isRequested, let domain = isolatedDomain else { return }
        shared.removePersistentDomain(forName: domain)
        shared.synchronize()
    }
}

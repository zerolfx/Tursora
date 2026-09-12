import AppKit
import Sparkle

/// Sparkle owns scheduling, persistence, authenticated installation and relaunch.
/// This boundary lets the headless suite exercise our controls without networking.
protocol AppUpdateDriver: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var allowsAutomaticUpdates: Bool { get }
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    var onChange: (() -> Void)? { get set }
    func start() throws
    func checkForUpdates()
}

final class AppUpdater: NSObject {
    static let didChange = Notification.Name("Tursora.updaterChanged")
    static let shared: AppUpdater = {
        // Do not even construct Sparkle in a smoke run or an unbundled SPM tool:
        // it must never display permission/error UI or schedule network requests.
        if SmokeTest.isRequested {
            return AppUpdater(driver: nil, unavailableReason: "Updates are disabled during automated tests.")
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return AppUpdater(driver: nil, unavailableReason: "Open the packaged Tursora app to check for updates.")
        }
        return AppUpdater(driver: SparkleUpdateDriver())
    }()

    private let driver: AppUpdateDriver?
    private(set) var unavailableReason: String?
    private(set) var isStarted = false
    let notificationCenter: NotificationCenter

    init(driver: AppUpdateDriver?, unavailableReason: String? = nil,
         notificationCenter: NotificationCenter = .default) {
        self.driver = driver
        self.unavailableReason = unavailableReason
        self.notificationCenter = notificationCenter
        super.init()
        driver?.onChange = { [weak self] in self?.notify() }
    }

    func start() {
        guard let driver, !isStarted else { return }
        do {
            try driver.start()
            isStarted = true
            unavailableReason = nil
        } catch {
            unavailableReason = "Updates could not start. " + error.localizedDescription
            if SmokeTest.isRequested { print(unavailableReason!) }
            else { NSLog("%@", unavailableReason!) }
        }
        notify()
    }

    var isAvailable: Bool { isStarted && unavailableReason == nil }
    var canCheckForUpdates: Bool { isAvailable && driver?.canCheckForUpdates == true }
    var automaticallyChecksForUpdates: Bool {
        get { driver?.automaticallyChecksForUpdates ?? false }
        set {
            guard isAvailable, newValue != automaticallyChecksForUpdates else { return }
            driver?.automaticallyChecksForUpdates = newValue
            notify()
        }
    }
    var allowsAutomaticUpdates: Bool {
        isAvailable && automaticallyChecksForUpdates && driver?.allowsAutomaticUpdates == true
    }
    var automaticallyDownloadsUpdates: Bool {
        get { driver?.automaticallyDownloadsUpdates ?? false }
        set {
            guard allowsAutomaticUpdates, newValue != automaticallyDownloadsUpdates else { return }
            driver?.automaticallyDownloadsUpdates = newValue
            notify()
        }
    }
    var statusText: String {
        if let unavailableReason { return unavailableReason }
        guard isStarted else { return "Updates have not started." }
        if let date = driver?.lastUpdateCheckDate {
            return "Last checked: " + DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        }
        return "No update checks yet."
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        driver?.checkForUpdates()
    }

    private func notify() { notificationCenter.post(name: Self.didChange, object: self) }
}

private final class SparkleUpdateDriver: NSObject, AppUpdateDriver {
    private let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                          updaterDelegate: nil, userDriverDelegate: nil)
    private var observations: [NSKeyValueObservation] = []
    var onChange: (() -> Void)?

    override init() {
        super.init()
        let updater = controller.updater
        observations = [
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in self?.onChange?() },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in self?.onChange?() },
            updater.observe(\.allowsAutomaticUpdates, options: [.new]) { [weak self] _, _ in self?.onChange?() },
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in self?.onChange?() },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in self?.onChange?() },
        ]
    }

    func start() throws { try controller.updater.start() }
    func checkForUpdates() { controller.checkForUpdates(nil) }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
    var allowsAutomaticUpdates: Bool { controller.updater.allowsAutomaticUpdates }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }
}

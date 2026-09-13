import AppKit
import Darwin
import SwiftTerm

/// Directory paths are argv values, never interpolated into executable shell text.
struct TerminalLaunchConfiguration {
    let directory: URL
    let shell: String
    let environment: [String]

    var executable: String { "/bin/sh" }
    var arguments: [String] {
        // SwiftTerm's currentDirectory chdir is best effort. Check it again in
        // the child so an unmounted directory cannot silently open another cwd.
        ["-c", "cd -- \"$1\" || exit 1; exec \"$2\" -il", "tursora-terminal", directory.path, shell]
    }

    static func make(directory: URL, shell: String, environment: [String: String]) -> Self {
        var values = environment
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        values["TERM_PROGRAM"] = "Tursora"
        values["SHELL"] = shell
        values["PATH"] = values["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return Self(directory: directory, shell: shell, environment: values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
    }

    static var userShell: String {
        if let value = getpwuid(getuid())?.pointee.pw_shell {
            let path = String(cString: value)
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }
}

/// Display state is explicit: navigation must not erase a process exit, and a
/// launch directory is not evidence of the shell's current working directory.
struct TerminalPanelPresentation: Equatable {
    enum State: Equatable { case ready, running, ended, failedToStart }
    var state: State = .ready
    var startedDirectory: URL?
    var reportedDirectory: URL?

    var locationText: String {
        switch state {
        case .ready: return "Ready to start."
        case .running:
            if let reportedDirectory { return "Shell folder: \(Self.displayPath(reportedDirectory))" }
            return startedDirectory.map { "Started in: \(Self.displayPath($0))" } ?? "Session running."
        case .ended: return "Session ended. Output is kept below."
        case .failedToStart: return "Could not start the terminal."
        }
    }

    var actionTitle: String { state == .running ? "Restart Terminal" : "Start Terminal" }

    func destinationText(_ pendingDirectory: URL) -> String {
        "\(state == .running ? "Restart" : "Start") in: \(Self.displayPath(pendingDirectory))"
    }

    private static func displayPath(_ url: URL) -> String {
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        return String(path.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? "�" : Character(String(scalar))
        })
    }

    /// OSC 7 may use the machine's hostname. Accept only this host's names,
    /// localhost, or no host; never interpret a remote file URL as local state.
    static func localDirectory(_ value: String?, localHostNames: Set<String>) -> URL? {
        // Parse before constructing a file URL: Foundation can normalize a
        // relative file: path against the process cwd and discard decorations.
        guard let value, let components = URLComponents(string: value),
              components.scheme?.lowercased() == "file",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil, components.path.hasPrefix("/"),
              !components.path.contains("\0"), components.path.utf8.count <= 32_768 else { return nil }
        let host = components.host?.lowercased() ?? ""
        let names = Set(localHostNames.map { $0.lowercased() })
        guard host.isEmpty || host == "localhost" || names.contains(host) else { return nil }
        return URL(fileURLWithPath: components.path, isDirectory: true).standardizedFileURL
    }

    static var localHostNames: Set<String> {
        let hostname = ProcessInfo.processInfo.hostName.lowercased()
        var names: Set<String> = [hostname]
        if hostname.hasSuffix(".local") { names.insert(String(hostname.dropLast(6))) }
        return names
    }
}

/// One retained panel owns one interactive PTY. Directory synchronization uses
/// a shell-side line-editor channel, never synthetic terminal input.
final class TerminalPanelController: NSViewController, LocalProcessTerminalViewDelegate {
    private(set) var pendingDirectory: URL
    var sessionDirectory: URL? { presentation.reportedDirectory ?? presentation.startedDirectory }
    private(set) var terminalView: LocalProcessTerminalView?
    private let terminalContainer = NSView()
    let titleLabel = NSTextField(labelWithString: "Terminal")
    let restartButton = NSButton(title: "", target: nil, action: nil)
    private var presentation = TerminalPanelPresentation()
    private let localHostNames: Set<String>
    private let preferences: TerminalPreferences.Store
    private var preferencesObserver: NSObjectProtocol?
    private var launchError: String?
    private var isShutDown = false
    private var shutdownGeneration: UInt64 = 0
    private var activitySession: TerminalActivity.Session?
    private var stoppingProcess: LocalProcess?
    private var directorySync: TerminalDirectorySync?
    private(set) var directorySyncUpdate: TerminalDirectorySync.Update?
    private var directorySyncError: String?
    var onClose: (() -> Void)?

    var isRunning: Bool { terminalView?.process.running == true }
    var statusState: TerminalPanelPresentation.State { presentation.state }
    func activitySnapshot() -> TerminalActivitySnapshot {
        guard let process = terminalView?.process ?? stoppingProcess, process.shellPid > 0 else { return .idle }
        if activitySession == nil, process.running { activitySession = TerminalActivity.Session(process: process) }
        guard let activitySession else {
            // The library's running flag can become false on EOF before exit.
            // An uninspectable process therefore needs conservative confirmation.
            return TerminalActivitySnapshot(tasks: [], informationUnavailable: process.running || TerminalActivity.isAlive(process.shellPid))
        }
        return activitySession.snapshot()
    }

    init(initialDirectory: URL, localHostNames: Set<String> = TerminalPanelPresentation.localHostNames,
         preferences: TerminalPreferences.Store = TerminalPreferences.shared) {
        pendingDirectory = initialDirectory
        self.localHostNames = localHostNames
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
        preferencesObserver = preferences.notificationCenter.addObserver(forName: .tursoraTerminalPreferencesChanged, object: preferences, queue: nil) { [weak self] _ in
            self?.applyAppearancePreferences()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let preferencesObserver { preferences.notificationCenter.removeObserver(preferencesObserver) }
        directorySync?.invalidate()
        if let process = terminalView?.process { TerminalProcessLifecycle.stop(process, session: activitySession) }
    }

    override func loadView() {
        let root = TerminalPanelRootView()
        root.onAppearanceChanged = { [weak self] in self?.applyAppearancePreferences() }
        view = root
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        restartButton.bezelStyle = .inline
        restartButton.isBordered = false
        restartButton.controlSize = .small
        restartButton.target = self
        restartButton.action = #selector(restartHere(_:))
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide Terminal")!, target: self, action: #selector(closePanel(_:)))
        close.bezelStyle = .inline
        close.isBordered = false
        close.toolTip = "Hide Terminal; its shell and tasks keep running"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, spacer, restartButton, close])
        header.orientation = .horizontal
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(terminalContainer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            header.heightAnchor.constraint(equalToConstant: 24),
            terminalContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            terminalContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateLocation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startIfNeeded()
    }

    /// Hidden panels retain the same channel. A busy/editor-owned request stays
    /// pending in the shell until its next safe primary prompt.
    func followDirectory(_ url: URL) {
        guard TerminalPanelPresentation.localDirectory(url.absoluteString, localHostNames: localHostNames) != nil else { return }
        pendingDirectory = url
        if directorySync != nil {
            directorySyncUpdate = TerminalDirectorySync.Update(state: .waiting, directory: presentation.reportedDirectory,
                                                               requestedDirectory: url, isReady: directorySyncUpdate?.isReady == true)
        }
        directorySync?.request(url)
        if isViewLoaded { updateLocation() }
    }

    func focus() {
        startIfNeeded()
        if let terminalView { view.window?.makeFirstResponder(terminalView) }
    }

    func shutdown(completion: (() -> Void)? = nil) {
        shutdownGeneration &+= 1
        isShutDown = true
        directorySync?.invalidate()
        directorySync = nil
        directorySyncUpdate = nil
        directorySyncError = nil
        let process = terminalView?.process ?? stoppingProcess
        if let terminalView {
            terminalView.processDelegate = nil
            terminalView.removeFromSuperview()
        }
        terminalView = nil
        presentation = TerminalPanelPresentation()
        launchError = nil
        guard let process else { completion?(); return }
        stoppingProcess = process
        TerminalProcessLifecycle.stop(process, session: activitySession) { [weak self] in
            if self?.stoppingProcess === process {
                self?.stoppingProcess = nil
                self?.activitySession = nil
            }
            completion?()
        }
    }

    private func startIfNeeded() {
        guard !isShutDown, terminalView == nil, !SmokeTest.isRequested,
              AppPreferences.experimentalTerminalEnabled, isViewLoaded, view.window != nil, !view.isHidden else { return }
        start(in: pendingDirectory)
    }

    private func start(in directory: URL) {
        guard !SmokeTest.isRequested, AppPreferences.experimentalTerminalEnabled else { return }
        var configuration: TerminalLaunchConfiguration
        do { configuration = try launchConfiguration(in: directory) }
        catch {
            presentation = TerminalPanelPresentation(state: .failedToStart)
            launchError = error.localizedDescription + " Open Settings → Terminal to choose a shell."
            updateLocation()
            return
        }
        let terminal = LocalProcessTerminalView(frame: terminalContainer.bounds)
        installTerminal(terminal, in: directory)
        do {
            if let sync = try TerminalDirectorySync.make(shell: configuration.shell, environment: ProcessInfo.processInfo.environment) {
                configuration = TerminalLaunchConfiguration.make(directory: directory, shell: configuration.shell, environment: sync.environment)
                installDirectorySynchronization(sync, for: terminal)
            }
        } catch {
            directorySyncError = "Folder sync is unavailable: \(error.localizedDescription)"
        }
        terminal.startProcess(executable: configuration.executable, args: configuration.arguments,
                              environment: configuration.environment, currentDirectory: directory.path)
        activitySession = TerminalActivity.Session(process: terminal.process, expectedShell: configuration.shell)
        if !terminal.process.running { presentation.state = .failedToStart }
        updateLocation()
        view.window?.makeFirstResponder(terminal)
    }

    /// Resolve again for each start; a stored executable may since have moved.
    func launchConfiguration(in directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> TerminalLaunchConfiguration {
        let shell = try preferences.configuration.resolvedShell()
        return TerminalLaunchConfiguration.make(directory: directory, shell: shell, environment: environment)
    }

    private func applyAppearancePreferences() {
        guard let terminalView, isViewLoaded else { return }
        let value = preferences.configuration
        let font = value.font
        // SwiftTerm resets selection and cell geometry when assigning a font.
        // A shell-only edit must preserve both.
        if terminalView.font.fontName != font.fontName || terminalView.font.pointSize != font.pointSize {
            terminalView.font = font
        }
        let colors = value.colors(for: view.effectiveAppearance)
        terminalView.nativeBackgroundColor = colors.background
        terminalView.nativeForegroundColor = colors.foreground
        terminalView.caretColor = colors.foreground
        terminalView.needsDisplay = true
    }

    /// Attaching a terminal view is separate from launching its process, so a
    /// view and its delegate identity can be verified without a user shell.
    func installTerminal(_ terminal: LocalProcessTerminalView, in directory: URL) {
        guard !isShutDown, terminal !== terminalView else { return }
        _ = view
        directorySync?.invalidate()
        directorySync = nil
        directorySyncUpdate = nil
        directorySyncError = nil
        if let previous = terminalView, previous !== terminal {
            previous.processDelegate = nil
            TerminalProcessLifecycle.stop(previous.process, session: activitySession)
            previous.removeFromSuperview()
        }
        terminal.processDelegate = self
        terminalContainer.pinToEdges(terminal)
        terminalView = terminal
        activitySession = TerminalActivity.Session(process: terminal.process)
        launchError = nil
        applyAppearancePreferences()
        presentation = TerminalPanelPresentation(state: .running, startedDirectory: directory)
        updateLocation()
    }

    /// Also used by controlled PTY tests. A callback belongs to this exact view
    /// and channel; shutdown/replacement invalidates all queued file activity.
    func installDirectorySynchronization(_ sync: TerminalDirectorySync, for terminal: LocalProcessTerminalView) {
        guard !isShutDown, terminal === terminalView else { sync.invalidate(); return }
        directorySync?.invalidate()
        directorySync = sync
        directorySyncUpdate = nil
        sync.onChange = { [weak self, weak terminal, weak sync] update in
            guard let self, let sync, self.directorySync === sync, terminal === self.terminalView,
                  !self.isShutDown, self.presentation.state == .running else { return }
            self.directorySyncUpdate = update
            if let reported = update.directory { self.presentation.reportedDirectory = reported }
            self.updateLocation()
        }
        sync.request(pendingDirectory)
        updateLocation()
    }

    @objc private func restartHere(_ sender: Any?) {
        guard !isShutDown, TerminalTaskConfirmation.confirm(action: .restart, activities: [activitySnapshot()]) else { return }
        guard !SmokeTest.isRequested else { return }
        restartSession { [weak self] destination in self?.start(in: destination) }
    }

    /// A later close/quit invalidates this request while process cleanup is
    /// pending. The launch callback also lets smoke tests verify that barrier
    /// without starting a user-configured shell.
    func restartSession(start: @escaping (URL) -> Void) {
        let destination = pendingDirectory
        let generation = shutdownGeneration &+ 1
        shutdown { [weak self] in
            guard let self, self.shutdownGeneration == generation else { return }
            self.isShutDown = false
            start(destination)
        }
    }

    @objc private func closePanel(_ sender: Any?) { onClose?() }

    private func updateLocation() {
        let detail: String
        if let launchError { detail = launchError }
        else if presentation.state == .running {
            let location = presentation.reportedDirectory.map { "Shell folder: \($0.path). " } ?? ""
            if let directorySyncError { detail = location + directorySyncError }
            else if directorySync == nil {
                detail = location + "Automatic folder sync needs zsh integration. Restart to open \(pendingDirectory.path)."
            } else if directorySyncUpdate?.state == .synchronized {
                detail = location + "Follows browsing folders, including while hidden."
            } else if directorySyncUpdate?.state == .failed {
                detail = location + "Could not synchronize to \(pendingDirectory.path). The request is kept for the next prompt."
            } else {
                detail = location + "Folder sync pending: \(pendingDirectory.path). Waiting for an empty zsh prompt; commands and unfinished input are preserved."
            }
        } else { detail = presentation.locationText }
        titleLabel.toolTip = detail
        titleLabel.setAccessibilityHelp(detail)
        titleLabel.textColor = launchError == nil ? .secondaryLabelColor : .systemRed
        restartButton.image = NSImage(systemSymbolName: presentation.state == .running ? "arrow.clockwise" : "play", accessibilityDescription: presentation.actionTitle)
        restartButton.setAccessibilityLabel(presentation.actionTitle)
        restartButton.setAccessibilityHelp(detail)
        restartButton.toolTip = presentation.actionTitle + ". " + (presentation.state == .running
            ? "Ends this shell and its tasks, then starts in \(pendingDirectory.path). "
            : "Starts a shell in \(pendingDirectory.path). ") + detail
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Do not let terminal output trigger filesystem navigation.
        guard !isShutDown, source === terminalView, presentation.state == .running,
              let url = TerminalPanelPresentation.localDirectory(directory, localHostNames: localHostNames) else { return }
        presentation.reportedDirectory = url
        updateLocation()
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !isShutDown, source === terminalView else { return }
        directorySync?.invalidate()
        directorySync = nil
        presentation.state = .ended
        updateLocation()
    }
}

private final class TerminalPanelRootView: NSView {
    var onAppearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}

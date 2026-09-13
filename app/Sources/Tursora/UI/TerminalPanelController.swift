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

    var actionTitle: String { state == .running ? "Restart in Current Folder" : "Start in Current Folder" }

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

/// SwiftTerm stops its exit monitor in terminate(), so the owner must reap on
/// explicit shutdown. Only the session created by this PTY is ever signalled.
enum TerminalProcessLifecycle {
    private static let stopped = NSHashTable<AnyObject>.weakObjects()

    static func stop(_ process: LocalProcess, completion: (() -> Void)? = nil) {
        guard process.shellPid > 0, !stopped.contains(process) else { completion?(); return }
        stopped.add(process)
        let pid = process.shellPid
        // PTY EOF can clear `running` before the queued exit monitor reaps.
        // Check child ownership rather than that flag, and never signal a PID
        // the library already reaped (it may have been reused).
        var status: Int32 = 0
        var state: pid_t
        repeat { state = waitpid(pid, &status, WNOHANG) } while state < 0 && errno == EINTR
        guard state == 0 else { completion?(); return }
        let foreground = process.childfd >= 0 ? tcgetpgrp(process.childfd) : -1
        if foreground > 0, foreground != getpgrp(), getsid(foreground) == pid {
            kill(-foreground, SIGHUP)
            kill(-foreground, SIGKILL)
        }
        // Do this synchronously before cancelling the library's monitor: a
        // subsequently reused PID must never be signalled by a delayed timer.
        kill(pid, SIGKILL)
        process.terminate()
        DispatchQueue.global(qos: .utility).async { [process] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            // Keep the weak idempotence marker valid until reaping finishes.
            _ = process
            DispatchQueue.main.async { completion?() }
        }
    }
}

/// One visible panel owns one interactive PTY. Navigation never sends keystrokes
/// to an existing shell: even a foreground-shell check cannot detect `read`.
final class TerminalPanelController: NSViewController, LocalProcessTerminalViewDelegate {
    private(set) var pendingDirectory: URL
    var sessionDirectory: URL? { presentation.reportedDirectory ?? presentation.startedDirectory }
    private(set) var terminalView: LocalProcessTerminalView?
    private let terminalContainer = NSView()
    let locationLabel = NSTextField(labelWithString: "")
    let destinationLabel = NSTextField(labelWithString: "")
    let restartButton = NSButton(title: "Restart in Current Folder", target: nil, action: nil)
    private var presentation = TerminalPanelPresentation()
    private let localHostNames: Set<String>
    private let preferences: TerminalPreferences.Store
    private var preferencesObserver: NSObjectProtocol?
    private var launchError: String?
    private var isShutDown = false
    var onClose: (() -> Void)?

    var isRunning: Bool { terminalView?.process.running == true }
    var hasForegroundCommand: Bool {
        guard let process = terminalView?.process, process.running, process.childfd >= 0 else { return false }
        let foreground = tcgetpgrp(process.childfd)
        return foreground > 0 && foreground != process.shellPid
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
        if let process = terminalView?.process { TerminalProcessLifecycle.stop(process) }
    }

    override func loadView() {
        let root = TerminalPanelRootView()
        root.onAppearanceChanged = { [weak self] in self?.applyAppearancePreferences() }
        view = root
        let title = NSTextField(labelWithString: "Terminal")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        locationLabel.font = .systemFont(ofSize: 11)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        destinationLabel.font = .systemFont(ofSize: 11)
        destinationLabel.textColor = .secondaryLabelColor
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        destinationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        destinationLabel.translatesAutoresizingMaskIntoConstraints = false
        restartButton.bezelStyle = .rounded
        restartButton.controlSize = .small
        restartButton.target = self
        restartButton.action = #selector(restartHere(_:))
        restartButton.toolTip = "Ends this shell and its foreground command, then starts in the current folder."
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Terminal")!, target: self, action: #selector(closePanel(_:)))
        close.bezelStyle = .inline
        close.isBordered = false
        close.toolTip = "Close Terminal and end its session"
        let header = NSStackView(views: [title, locationLabel, restartButton, close])
        header.orientation = .horizontal
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(destinationLabel)
        view.addSubview(terminalContainer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            header.heightAnchor.constraint(equalToConstant: 24),
            destinationLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            destinationLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            destinationLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            destinationLabel.heightAnchor.constraint(equalToConstant: 15),
            terminalContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalContainer.topAnchor.constraint(equalTo: destinationLabel.bottomAnchor, constant: 5),
            terminalContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateLocation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startIfNeeded()
    }

    /// Called by navigation; deliberately updates only the restart destination.
    func followDirectory(_ url: URL) {
        guard TerminalPanelPresentation.localDirectory(url.absoluteString, localHostNames: localHostNames) != nil else { return }
        pendingDirectory = url
        if isViewLoaded { updateLocation() }
    }

    func focus() {
        startIfNeeded()
        if let terminalView { view.window?.makeFirstResponder(terminalView) }
    }

    func shutdown() {
        isShutDown = true
        if let terminalView {
            terminalView.processDelegate = nil
            TerminalProcessLifecycle.stop(terminalView.process)
            terminalView.removeFromSuperview()
        }
        terminalView = nil
        presentation = TerminalPanelPresentation()
        launchError = nil
    }

    private func startIfNeeded() {
        guard !isShutDown, terminalView == nil, !SmokeTest.isRequested,
              AppPreferences.experimentalTerminalEnabled, isViewLoaded, view.window != nil, !view.isHidden else { return }
        start(in: pendingDirectory)
    }

    private func start(in directory: URL) {
        guard !SmokeTest.isRequested, AppPreferences.experimentalTerminalEnabled else { return }
        let configuration: TerminalLaunchConfiguration
        do { configuration = try launchConfiguration(in: directory) }
        catch {
            presentation = TerminalPanelPresentation(state: .failedToStart)
            launchError = error.localizedDescription + " Open Settings → Terminal to choose a shell."
            updateLocation()
            return
        }
        let terminal = LocalProcessTerminalView(frame: terminalContainer.bounds)
        installTerminal(terminal, in: directory)
        terminal.startProcess(executable: configuration.executable, args: configuration.arguments,
                              environment: configuration.environment, currentDirectory: directory.path)
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
        if let previous = terminalView, previous !== terminal {
            previous.processDelegate = nil
            TerminalProcessLifecycle.stop(previous.process)
            previous.removeFromSuperview()
        }
        terminal.processDelegate = self
        terminalContainer.pinToEdges(terminal)
        terminalView = terminal
        launchError = nil
        applyAppearancePreferences()
        presentation = TerminalPanelPresentation(state: .running, startedDirectory: directory)
        updateLocation()
    }

    @objc private func restartHere(_ sender: Any?) {
        guard !SmokeTest.isRequested, !isShutDown else { return }
        let destination = pendingDirectory
        let restart = { [weak self] in
            guard let self else { return }
            self.shutdown()
            self.isShutDown = false
            self.start(in: destination)
        }
        if hasForegroundCommand, let window = view.window {
            let alert = NSAlert()
            alert.messageText = "Restart Terminal?"
            alert.informativeText = "This ends the running command and starts a new shell in the current folder."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { restart() } }
        } else { restart() }
    }

    @objc private func closePanel(_ sender: Any?) { onClose?() }

    private func updateLocation() {
        locationLabel.stringValue = launchError ?? presentation.locationText
        locationLabel.textColor = presentation.state == .failedToStart ? .systemRed : .secondaryLabelColor
        locationLabel.toolTip = launchError ?? presentation.reportedDirectory.map { "Shell-reported folder: \($0.path)" }
            ?? presentation.startedDirectory.map { "Started in \($0.path). The shell has not reported its current folder." }
        destinationLabel.stringValue = presentation.destinationText(pendingDirectory)
        destinationLabel.toolTip = "New shell destination: \(pendingDirectory.path). Browsing folders does not change the existing shell."
        restartButton.title = presentation.actionTitle
        restartButton.toolTip = presentation.state == .running
            ? "Ends this shell and its foreground command, then starts in \(pendingDirectory.path)."
            : "Starts a new shell in \(pendingDirectory.path)."
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

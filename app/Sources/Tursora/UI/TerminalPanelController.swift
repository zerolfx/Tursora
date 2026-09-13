import AppKit
import Darwin
import SwiftTerm

/// Directory paths are argv values, never interpolated into executable shell text.
struct TerminalLaunchConfiguration {
    let directory: URL
    let shell: String
    /// Interactive arguments for the chosen shell, including any integration
    /// file. They stay separate argv values and are never quoted into text.
    let shellArguments: [String]
    let environment: [String]

    var executable: String { "/bin/sh" }
    var arguments: [String] {
        // SwiftTerm's currentDirectory chdir is best effort. Check it again in
        // the child so an unmounted directory cannot silently open another cwd.
        ["-c", "cd -- \"$1\" || exit 1; tursora_shell=\"$2\"; shift 2; exec \"$tursora_shell\" \"$@\"",
         "tursora-terminal", directory.path, shell] + shellArguments
    }

    static func make(directory: URL, shell: String,
                     shellArguments: [String] = TerminalShellIntegration.plainArguments,
                     environment: [String: String]) -> Self {
        var values = environment
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        values["TERM_PROGRAM"] = "Tursora"
        values["SHELL"] = shell
        values["PATH"] = values["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return Self(directory: directory, shell: shell, shellArguments: shellArguments,
                    environment: values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
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
        // `standardized` only resolves "." and ".."; `standardizedFileURL` also
        // drops a leading /private, which would rename the folder the shell
        // actually reported. Loop protection compares both spellings instead.
        return URL(fileURLWithPath: components.path, isDirectory: true).standardized
    }

    /// Folder identity for sync decisions. A browsed URL and one rebuilt from
    /// an OSC 7 path describe the same place with different URL spellings, so
    /// loop protection compares standardized paths rather than URL values.
    static func isSameDirectory(_ first: URL?, _ second: URL?) -> Bool {
        guard let first, let second else { return false }
        return first.standardizedFileURL.path == second.standardizedFileURL.path
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
    /// The last folder this panel asked the shell for. A report that matches it
    /// is this panel's own request coming back and must not navigate again.
    private var requestedDirectory: URL?
    /// The last folder OSC 7 carried. Tracked apart from the presentation,
    /// which zsh's response file also writes, so a repeated report is still
    /// recognised as a repeat.
    private var reportedShellDirectory: URL?
    var onClose: (() -> Void)?
    /// A local folder the shell reported that neither the browser nor this
    /// panel asked for. The window navigates its active pane; the panel itself
    /// never reads or writes the filesystem for it.
    var onShellDirectoryChanged: ((URL) -> Void)?

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
        let root = AppearanceObservingView()
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
        // The restart target always follows browsing; only the request to the
        // running shell is what the preference turns off.
        if preferences.configuration.terminalFollowsBrowser {
            requestedDirectory = url
            if let sync = directorySync {
                // A shell that reports at its prompt is already there whenever
                // the browser asks for the folder it last reported; only zsh's
                // response file decides that for zsh.
                let settled = !sync.kind.appliesRequestsWhileIdle
                    && TerminalPanelPresentation.isSameDirectory(url, reportedShellDirectory)
                directorySyncUpdate = TerminalDirectorySync.Update(state: settled ? .synchronized : .waiting,
                                                                   directory: presentation.reportedDirectory)
            }
            directorySync?.request(url)
        }
        if isViewLoaded { updateLocation() }
    }

    /// Dolphin only mirrors its terminal while the panel is on screen; a hidden
    /// panel keeps its shell but stops steering the file views.
    private var isPanelVisible: Bool {
        isViewLoaded && view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    /// Reverse direction. Reports that repeat this panel's own request, or the
    /// folder the browser is already showing, cannot start a navigation loop.
    private func reportShellDirectory(_ url: URL) {
        guard preferences.configuration.browserFollowsShell, isPanelVisible,
              !TerminalPanelPresentation.isSameDirectory(url, requestedDirectory),
              !TerminalPanelPresentation.isSameDirectory(url, pendingDirectory) else { return }
        onShellDirectoryChanged?(url)
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
        requestedDirectory = nil
        reportedShellDirectory = nil
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
                configuration = TerminalLaunchConfiguration.make(directory: directory, shell: configuration.shell,
                                                                 shellArguments: sync.shellArguments, environment: sync.environment)
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
        requestedDirectory = nil
        reportedShellDirectory = nil
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
        requestedDirectory = pendingDirectory
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

    /// The reverse direction only runs while the panel is on screen, so the
    /// header says so where it explains the forward one.
    private var reverseDirectionText: String {
        guard preferences.configuration.browserFollowsShell else { return "" }
        return " A folder you change in the shell moves the active pane while this panel is visible."
    }

    private func updateLocation() {
        let detail: String
        if let launchError { detail = launchError }
        else if presentation.state == .running {
            let location = presentation.reportedDirectory.map { "Shell folder: \($0.path). " } ?? ""
            if let directorySyncError { detail = location + directorySyncError }
            else if !preferences.configuration.terminalFollowsBrowser {
                // The user's own choice explains the behaviour better than the
                // shell's capabilities, so it is said first.
                detail = location + "This shell does not follow browsing folders. Turn on \"Terminal follows the browser folder\" in Settings \u{2192} Terminal, or restart to open \(pendingDirectory.path)."
            } else if directorySync == nil {
                detail = location + "Automatic folder sync needs zsh, bash or fish. Restart to open \(pendingDirectory.path)."
            } else if directorySyncUpdate?.state == .synchronized {
                detail = location + "Follows browsing folders, including while hidden." + reverseDirectionText
            } else if directorySyncUpdate?.state == .failed {
                detail = location + "Could not synchronize to \(pendingDirectory.path). The request is kept for the next prompt."
            } else if directorySync?.kind.appliesRequestsWhileIdle == false {
                detail = location + "Folder sync pending: \(pendingDirectory.path). bash and fish apply it at the next prompt you draw; commands and unfinished input are preserved."
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
        // Shells report at every prompt, and fish reports twice because it has
        // its own OSC 7 hook. Only an actual change is news for the browser.
        let changed = !TerminalPanelPresentation.isSameDirectory(url, reportedShellDirectory)
        reportedShellDirectory = url
        presentation.reportedDirectory = url
        // bash and fish acknowledge a request by reporting where they ended up
        // rather than through the zsh response file.
        if let sync = directorySync, !sync.kind.appliesRequestsWhileIdle {
            let arrived = TerminalPanelPresentation.isSameDirectory(url, pendingDirectory)
            directorySyncUpdate = TerminalDirectorySync.Update(state: arrived ? .synchronized : .waiting, directory: url)
        }
        updateLocation()
        if changed { reportShellDirectory(url) }
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !isShutDown, source === terminalView else { return }
        directorySync?.invalidate()
        directorySync = nil
        presentation.state = .ended
        updateLocation()
    }
}

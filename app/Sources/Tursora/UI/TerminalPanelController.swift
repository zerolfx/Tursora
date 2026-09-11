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
    private(set) var sessionDirectory: URL?
    private(set) var terminalView: LocalProcessTerminalView?
    private let terminalContainer = NSView()
    private let locationLabel = NSTextField(labelWithString: "")
    private let restartButton = NSButton(title: "Restart in Current Folder", target: nil, action: nil)
    private var isShutDown = false
    var onClose: (() -> Void)?

    var isRunning: Bool { terminalView?.process.running == true }
    var hasForegroundCommand: Bool {
        guard let process = terminalView?.process, process.running, process.childfd >= 0 else { return false }
        let foreground = tcgetpgrp(process.childfd)
        return foreground > 0 && foreground != process.shellPid
    }

    init(initialDirectory: URL) {
        pendingDirectory = initialDirectory
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let process = terminalView?.process { TerminalProcessLifecycle.stop(process) } }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Terminal · Experimental")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        locationLabel.font = .systemFont(ofSize: 11)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        view.addSubview(terminalContainer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            header.heightAnchor.constraint(equalToConstant: 24),
            terminalContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
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
        guard url.isFileURL else { return }
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
        sessionDirectory = nil
    }

    private func startIfNeeded() {
        guard !isShutDown, terminalView == nil, !SmokeTest.isRequested,
              AppPreferences.experimentalTerminalEnabled, isViewLoaded, view.window != nil, !view.isHidden else { return }
        start(in: pendingDirectory)
    }

    private func start(in directory: URL) {
        guard !SmokeTest.isRequested, AppPreferences.experimentalTerminalEnabled else { return }
        let configuration = TerminalLaunchConfiguration.make(directory: directory, shell: TerminalLaunchConfiguration.userShell,
                                                              environment: ProcessInfo.processInfo.environment)
        let terminal = LocalProcessTerminalView(frame: terminalContainer.bounds)
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.nativeBackgroundColor = .textBackgroundColor
        terminal.nativeForegroundColor = .textColor
        terminal.processDelegate = self
        terminalContainer.pinToEdges(terminal)
        terminalView = terminal
        sessionDirectory = directory
        terminal.startProcess(executable: configuration.executable, args: configuration.arguments,
                              environment: configuration.environment, currentDirectory: directory.path)
        updateLocation()
        if !terminal.process.running { locationLabel.stringValue = "Could not start the terminal." }
        view.window?.makeFirstResponder(terminal)
    }

    @objc private func restartHere(_ sender: Any?) {
        guard !SmokeTest.isRequested else { return }
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
        let shown = sessionDirectory ?? pendingDirectory
        locationLabel.stringValue = (shown.path as NSString).abbreviatingWithTildeInPath
        locationLabel.toolTip = "Closing the panel ends its session. Restart destination: \(pendingDirectory.path)"
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Do not let terminal output trigger filesystem navigation.
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        sessionDirectory = url
        updateLocation()
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminalView else { return }
        locationLabel.stringValue = "Session ended — restart to open a new shell."
    }
}

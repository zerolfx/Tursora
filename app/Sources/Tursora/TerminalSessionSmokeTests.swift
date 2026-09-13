import AppKit
import Darwin
import SwiftTerm

/// A private workspace and a controlled /bin/sh PTY exercise retention and
/// destructive-action guards. No user shell files or actual app quit is used.
enum TerminalSessionSmokeTests: SmokeSuite {
    static let checkPrefix = "terminal sessions: "
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            do {
                try await runChecks()
                completion()
            } catch {
                // `require` already embeds the prefix into a SmokeFailure.
                print("FAIL \(error is SmokeFailure ? "" : checkPrefix)\(error)")
                exit(1)
            }
        }
    }

    @MainActor
    private static func runChecks() async throws {
        print("== terminal session retention ==")
        try confirmationChecks()
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("tursora-terminal-session-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try manager.createDirectory(at: root.appendingPathComponent("next"), withIntermediateDirectories: true)
        let suite = "Tursora.TerminalSessionSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
        let workspace = WorkspaceSessionStore(fileURL: nil)
        let owner = AppDelegate(provider: SmokeFixtures.EmptyProvider(homeURL: root),
            updater: AppUpdater(driver: nil, unavailableReason: "Terminal session test"),
            workspaceStore: workspace, preferences: preferences,
            viewPropertiesStore: DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json")))
        let savedEnabled = AppPreferences.experimentalTerminalEnabled
        AppPreferences.experimentalTerminalEnabled = true
        defer {
            // Cleanup remains bounded to this fixture even if a check throws.
            for controller in owner.windowControllers {
                controller.shutdownTerminal()
                controller.close()
            }
            AppPreferences.experimentalTerminalEnabled = savedEnabled
            defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: root)
        }
        owner.beginWorkspaceSession(showWindows: false)
        guard let controller = owner.windowControllers.first, let window = controller.window else {
            throw SmokeFailure("\(checkPrefix)private workspace creates a window")
        }
        try await requireEventually("private workspace loads", timeout: 15, interval: 30_000_000) { controller.browser.model.generation > 0 }
        try require("initial workspace can be saved", owner.saveWorkspaceNow())
        window.contentView?.layoutSubtreeIfNeeded()
        try require("initial footer has no terminal control and creates no session", hasNoFooterButton(controller) && controller.terminalPanel == nil)
        controller.toggleTerminal(nil)
        guard let panel = controller.terminalPanel else { throw SmokeFailure("\(checkPrefix)terminal panel opens") }
        try require("terminal action opens the panel without a headless shell", controller.isTerminalVisible && panel.terminalView == nil)
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 240))
        panel.installTerminal(terminal, in: root)
        terminal.startProcess(executable: "/bin/sh", args: ["-f", "-i"], environment: [
            "PATH=/usr/bin:/bin", "HOME=\(root.path)", "ENV=/dev/null", "TERM=xterm-256color", "PS1=$ "
        ], currentDirectory: root.path)
        let shellPID = terminal.process.shellPid
        try require("controlled session has a real owned PTY", shellPID > 0 && terminal.process.running && isatty(terminal.process.childfd) == 1)
        // macOS /bin/sh is Bash; its interactive history expansion would
        // interpret the later $!; assignment before parameter expansion.
        send("set +H; stty -echo; printf '\\n__SESSION_%s__\\n' READY\n", to: terminal)
        try await waitFor("__SESSION_READY__", in: terminal)
        try await requireEventually("an idle interactive shell needs no task warning", timeout: 15, interval: 30_000_000) { !panel.activitySnapshot().requiresConfirmation }

        // Keep a background job at the shell prompt: foreground-only checks
        // would miss it even though hiding or closing could still kill it.
        send("/bin/sleep 60 & TURSORA_JOB=$!; printf '\\n__BACKGROUND_PID_%s__\\n' \"$TURSORA_JOB\"\n", to: terminal)
        try await requireEventually("background task PID is reported", timeout: 15, interval: 30_000_000, detail: { output(terminal) }) { backgroundPID(in: terminal) != nil }
        guard let jobPID = backgroundPID(in: terminal) else { throw SmokeFailure("\(checkPrefix)owned background task PID") }
        try await requireEventually("background work is detected at the shell prompt", timeout: 15, interval: 30_000_000) {
            tcgetpgrp(terminal.process.childfd) == shellPID && panel.activitySnapshot().tasks.contains { $0.pid == jobPID }
        }
        try require("running terminal work adds no footer control", hasNoFooterButton(controller))
        controller.toggleTerminal(nil)
        try require("hide retains the controller, view and running PID", !controller.isTerminalVisible && controller.terminalPanel === panel
            && panel.terminalView === terminal && terminal.process.shellPid == shellPID && processExists(jobPID))
        send("kill -STOP \"$TURSORA_JOB\"; printf '\\n__STOPPED_%s__\\n' JOB\n", to: terminal)
        try await waitFor("__STOPPED_JOB__", in: terminal)
        try await requireEventually("controlled background job is stopped", timeout: 15, interval: 30_000_000) { panel.activitySnapshot().tasks.contains { $0.pid == jobPID && $0.isStopped } }
        try require("stopped work still requires shutdown confirmation", panel.activitySnapshot().requiresConfirmation)
        send("kill -CONT \"$TURSORA_JOB\"; printf '\\n__RESUMED_%s__\\n' JOB\n", to: terminal)
        try await waitFor("__RESUMED_JOB__", in: terminal)
        try await requireEventually("controlled background job resumes", timeout: 15, interval: 30_000_000) { panel.activitySnapshot().tasks.contains { $0.pid == jobPID && !$0.isStopped } }
        send("printf '\\n__HIDDEN_%s__\\n' OUTPUT\n", to: terminal)
        try await waitFor("__HIDDEN_OUTPUT__", in: terminal)
        controller.toggleTerminal(nil)
        try require("reopening restores the same output and background task", controller.isTerminalVisible && controller.terminalPanel === panel
            && panel.terminalView === terminal && terminal.process.shellPid == shellPID && output(terminal).contains("__HIDDEN_OUTPUT__")
            && processExists(jobPID))
        send("printf '\\n__RETAINED_%s__\\n' INPUT", to: terminal)
        controller.hideTerminal()
        controller.toggleTerminal(nil)
        send("\n", to: terminal)
        try await waitFor("__RETAINED_INPUT__", in: terminal)
        try require("hide and reopen preserve unfinished shell input", terminal.process.shellPid == shellPID && processExists(jobPID))

        AppPreferences.experimentalTerminalEnabled = false
        try require("Settings disable hides without ending retained work", !controller.isTerminalVisible && controller.terminalPanel === panel
            && panel.terminalView === terminal && terminal.process.running && processExists(jobPID))
        controller.toggleTerminal(nil)
        try require("disabled terminal action does not reveal or replace the session", !controller.isTerminalVisible && controller.terminalPanel === panel)
        AppPreferences.experimentalTerminalEnabled = true
        controller.toggleTerminal(nil)
        try require("Settings re-enable reuses the previous PTY", controller.isTerminalVisible && controller.terminalPanel === panel
            && terminal.process.shellPid == shellPID && output(terminal).contains("__RETAINED_INPUT__"))
        panel.onClose?()
        try require("panel close control only hides the live session", !controller.isTerminalVisible && controller.terminalPanel === panel && processExists(jobPID))

        let idleWindow = owner.newWindow(at: root, show: false, cascade: false)
        idleWindow.toggleTerminal(nil)
        try await requireEventually("second window loads independently", timeout: 15, interval: 30_000_000) { idleWindow.browser.model.generation > 0 }

        var quitRequests = 0
        var quitSawBackground = false
        var quitSawBothSessions = false
        var nestedQuitDenied = false
        owner.terminalTaskConfirmation = { [weak owner] action, activities in
            quitRequests += 1
            quitSawBackground = action == .quit && activities.contains { $0.tasks.contains { $0.pid == jobPID } }
            quitSawBothSessions = activities.count == 2 && activities.contains { !$0.requiresConfirmation }
            nestedQuitDenied = owner?.confirmTerminalTermination() == false
            return false
        }
        try require("application quit cancellation sees hidden background tasks", owner.applicationShouldTerminate(NSApp) == .terminateCancel
            && quitSawBackground && quitRequests == 1)
        try require("quit guard aggregates busy hidden and idle visible windows", quitSawBothSessions && idleWindow.isTerminalVisible)
        try require("reentrant quit confirmation is denied without a second prompt", nestedQuitDenied && quitRequests == 1)
        try require("a later quit request can ask again after cancellation", owner.applicationShouldTerminate(NSApp) == .terminateCancel && quitRequests == 2)
        try require("cancelled quit leaves the hidden session running", !controller.isTerminalVisible && controller.terminalPanel === panel
            && terminal.process.running && processExists(jobPID))
        controller.tabs.newTab(at: root.appendingPathComponent("next"))
        try await requireEventually("new tab loads after cancelled quit", timeout: 15, interval: 30_000_000) { controller.browser.model.generation > 0 }
        let expectedWorkspace = owner.currentWorkspaceState
        try await requireEventually("workspace autosave continues after cancelled quit", timeout: 15, interval: 30_000_000) {
            if case .loaded(let saved) = workspace.load() { return saved == expectedWorkspace }
            return false
        }
        try require("hidden navigation preserves the session directory", panel.sessionDirectory == root
            && panel.pendingDirectory == root.appendingPathComponent("next") && terminal.process.shellPid == shellPID)
        owner.terminalTaskConfirmation = { action, activities in action == .quit && activities.contains(where: \.requiresConfirmation) }
        try require("quit approval guard does not itself destroy sessions", owner.confirmTerminalTermination()
            && controller.terminalPanel === panel && terminal.process.running && processExists(jobPID))

        var closeRequests = 0
        var closeSawBackground = false
        var nestedCloseDenied = false
        controller.terminalTaskConfirmation = { [weak controller, weak window] action, activities in
            closeRequests += 1
            closeSawBackground = action == .closeWindow && activities.contains { $0.tasks.contains { $0.pid == jobPID } }
            if let window { nestedCloseDenied = controller?.windowShouldClose(window) == false }
            return false
        }
        window.performClose(nil)
        try require("window close cancellation checks hidden background tasks", closeSawBackground && closeRequests == 1
            && owner.windowControllers.contains { $0 === controller } && controller.terminalPanel === panel && processExists(jobPID))
        try require("reentrant window close is denied without a second prompt", nestedCloseDenied && closeRequests == 1)
        controller.terminalTaskConfirmation = { action, activities in action == .closeWindow && activities.contains(where: \.requiresConfirmation) }
        window.performClose(nil)
        try await requireEventually("approved close removes the window and retained terminal", timeout: 15, interval: 30_000_000) {
            !owner.windowControllers.contains { $0 === controller } && controller.terminalPanel == nil && panel.terminalView == nil
        }
        try await requireEventually("approved close ends and reaps its shell and background task", timeout: 15, interval: 30_000_000) {
            !processExists(shellPID) && !processExists(jobPID) && !terminal.process.running && terminal.process.childfd == -1
        }
        var status: Int32 = 0
        try require("approved session shutdown leaves no unreaped shell", waitpid(shellPID, &status, WNOHANG) == -1 && errno == ECHILD)

        // The remaining window exercises natural exit rather than synthesizing
        // a delegate callback. Ending the shell still preserves its output.
        guard let endedPanel = idleWindow.terminalPanel else { throw SmokeFailure("\(checkPrefix)second panel remains owned") }
        let endedTerminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 240))
        endedPanel.installTerminal(endedTerminal, in: root)
        endedTerminal.startProcess(executable: "/bin/sh", args: ["-f", "-i"], environment: [
            "PATH=/usr/bin:/bin", "HOME=\(root.path)", "ENV=/dev/null", "TERM=xterm-256color", "PS1=$ "
        ], currentDirectory: root.path)
        send("set +H; stty -echo; printf '\\n__ENDED_%s__\\n' READY\n", to: endedTerminal)
        try await waitFor("__ENDED_READY__", in: endedTerminal)
        send("printf '\\n__RETAINED_%s__\\n' OUTPUT; exit\n", to: endedTerminal)
        try await requireEventually("natural shell exit preserves final output", timeout: 15, interval: 30_000_000) {
            !endedTerminal.process.running && endedPanel.statusState == .ended && output(endedTerminal).contains("__RETAINED_OUTPUT__")
        }
        idleWindow.toggleTerminal(nil)
        idleWindow.toggleTerminal(nil)
        try require("ended-session terminal actions preserve the original view and final output", idleWindow.isTerminalVisible
            && endedPanel.terminalView === endedTerminal && !endedTerminal.process.running && output(endedTerminal).contains("__RETAINED_OUTPUT__")
            && hasNoFooterButton(idleWindow))
    }

    private static func hasNoFooterButton(_ controller: MainWindowController) -> Bool {
        controller.tabs.pages.flatMap(\.panes).allSatisfy { pane in
            !pane.statusBar.subviews.contains { $0 is NSButton }
        }
    }

    @MainActor
    private static func confirmationChecks() throws {
        let busy = TerminalActivitySnapshot(tasks: [.init(pid: 42, name: "sleep\u{1b}", isStopped: false)], informationUnavailable: false)
        for action in [TerminalTaskConfirmation.Action.quit, .closeWindow, .restart] {
            let alert = TerminalTaskConfirmation.makeAlert(action: action, activities: [busy])
            try require("\(action) confirmation defaults to Cancel", alert.buttons.count == 2 && alert.buttons[0].title == "Cancel"
                && alert.buttons[0].keyEquivalent == "\r" && alert.buttons[1].keyEquivalent.isEmpty && alert.buttons[1].hasDestructiveAction)
            try require("\(action) confirmation identifies hidden tasks without raw controls", alert.informativeText.contains("hidden")
                && alert.informativeText.contains("sleep") && !alert.informativeText.contains("\u{1b}"))
        }
        let unknown = TerminalActivitySnapshot(tasks: [], informationUnavailable: true)
        try require("unavailable activity information is explicit", TerminalTaskConfirmation.makeAlert(action: .quit, activities: [unknown])
            .informativeText.contains("could not be checked"))
        try require("idle sessions pass without a dialog", TerminalTaskConfirmation.confirm(action: .quit, activities: [.idle]))
        try require("headless active and unknown sessions cancel instead of opening a modal", !TerminalTaskConfirmation.confirm(action: .quit, activities: [busy])
            && !TerminalTaskConfirmation.confirm(action: .closeWindow, activities: [unknown]))
    }

    private static func send(_ text: String, to terminal: LocalProcessTerminalView) { terminal.process.send(data: Array(text.utf8)[...]) }
    private static func output(_ terminal: LocalProcessTerminalView) -> String { String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
    private static func backgroundPID(in terminal: LocalProcessTerminalView) -> pid_t? {
        let text = output(terminal)
        guard let start = text.range(of: "__BACKGROUND_PID_"), let end = text.range(of: "__", range: start.upperBound..<text.endIndex) else { return nil }
        return pid_t(text[start.upperBound..<end.lowerBound])
    }
    private static func processExists(_ pid: pid_t) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }
    @MainActor
    private static func waitFor(_ marker: String, in terminal: LocalProcessTerminalView) async throws {
        try await requireEventually("PTY receives \(marker)", timeout: 15, interval: 30_000_000, detail: { output(terminal) }) { output(terminal).contains(marker) }
    }
}

import AppKit
import Darwin
import SwiftTerm

/// A private workspace and a controlled /bin/sh PTY exercise retention and
/// destructive-action guards. No user shell files or actual app quit is used.
enum TerminalSessionSmokeTests {
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            do {
                try await runChecks()
                completion()
            } catch {
                print("FAIL terminal sessions: \(error)")
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
        let owner = AppDelegate(provider: EmptyProvider(homeURL: root),
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
            throw Failure("private workspace creates a window")
        }
        try await waitUntil("private workspace loads", { controller.browser.model.generation > 0 })
        try check("initial workspace can be saved", owner.saveWorkspaceNow())
        let statusButton = controller.browser.statusBar.terminalStatusButton
        window.contentView?.layoutSubtreeIfNeeded()
        try check("initial footer status creates no session", !statusButton.isHidden && statusButton.isEnabled
            && statusButton.title == "Terminal" && controller.terminalPanel == nil)
        statusButton.performClick(nil)
        guard let panel = controller.terminalPanel else { throw Failure("terminal panel opens") }
        try check("clicking the exact footer button opens the panel without a headless shell", controller.isTerminalVisible && panel.terminalView == nil)
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 240))
        panel.installTerminal(terminal, in: root)
        terminal.startProcess(executable: "/bin/sh", args: ["-f", "-i"], environment: [
            "PATH=/usr/bin:/bin", "HOME=\(root.path)", "ENV=/dev/null", "TERM=xterm-256color", "PS1=$ "
        ], currentDirectory: root.path)
        let shellPID = terminal.process.shellPid
        try check("controlled session has a real owned PTY", shellPID > 0 && terminal.process.running && isatty(terminal.process.childfd) == 1)
        // macOS /bin/sh is Bash; its interactive history expansion would
        // interpret the later $!; assignment before parameter expansion.
        send("set +H; stty -echo; printf '\\n__SESSION_%s__\\n' READY\n", to: terminal)
        try await waitFor("__SESSION_READY__", in: terminal)
        try await waitUntil("an idle interactive shell needs no task warning", { !panel.activitySnapshot().requiresConfirmation })

        // Keep a background job at the shell prompt: foreground-only checks
        // would miss it even though hiding or closing could still kill it.
        send("/bin/sleep 60 & TURSORA_JOB=$!; printf '\\n__BACKGROUND_PID_%s__\\n' \"$TURSORA_JOB\"\n", to: terminal)
        try await waitUntil("background task PID is reported", { backgroundPID(in: terminal) != nil }, detail: { output(terminal) })
        guard let jobPID = backgroundPID(in: terminal) else { throw Failure("owned background task PID") }
        try await waitUntil("background work is detected at the shell prompt", {
            tcgetpgrp(terminal.process.childfd) == shellPID && panel.activitySnapshot().tasks.contains { $0.pid == jobPID }
        })
        controller.refreshTerminalActivity()
        try await waitUntil("async footer refresh reports the real background task", {
            window.contentView?.layoutSubtreeIfNeeded()
            return statusButton.title.contains("1 task") && statusButton.toolTip?.contains("visible") == true
        }, detail: { statusButton.toolTip ?? "no terminal status" })
        statusButton.performClick(nil)
        try check("hide retains the controller, view and running PID", !controller.isTerminalVisible && controller.terminalPanel === panel
            && panel.terminalView === terminal && terminal.process.shellPid == shellPID && processExists(jobPID))
        try check("footer task status remains available while hidden", !statusButton.isHidden && statusButton.toolTip?.contains("hidden") == true)
        send("printf '\\n__HIDDEN_%s__\\n' OUTPUT\n", to: terminal)
        try await waitFor("__HIDDEN_OUTPUT__", in: terminal)
        statusButton.performClick(nil)
        try check("reopening restores the same output and background task", controller.isTerminalVisible && controller.terminalPanel === panel
            && panel.terminalView === terminal && terminal.process.shellPid == shellPID && output(terminal).contains("__HIDDEN_OUTPUT__")
            && processExists(jobPID))
        send("printf '\\n__RETAINED_%s__\\n' INPUT", to: terminal)
        controller.hideTerminal()
        controller.toggleTerminal(nil)
        send("\n", to: terminal)
        try await waitFor("__RETAINED_INPUT__", in: terminal)
        try check("hide and reopen preserve unfinished shell input", terminal.process.shellPid == shellPID && processExists(jobPID))

        AppPreferences.experimentalTerminalEnabled = false
        try check("Settings disable hides without ending retained work", !controller.isTerminalVisible && controller.terminalPanel === panel
            && panel.terminalView === terminal && terminal.process.running && processExists(jobPID))
        try check("disabled footer retains task information without accepting clicks", !statusButton.isHidden && !statusButton.isEnabled
            && statusButton.toolTip?.contains("Settings") == true)
        controller.toggleTerminal(nil)
        try check("disabled terminal action does not reveal or replace the session", !controller.isTerminalVisible && controller.terminalPanel === panel)
        AppPreferences.experimentalTerminalEnabled = true
        controller.toggleTerminal(nil)
        try check("Settings re-enable reuses the previous PTY", controller.isTerminalVisible && controller.terminalPanel === panel
            && terminal.process.shellPid == shellPID && output(terminal).contains("__RETAINED_INPUT__"))
        panel.onClose?()
        try check("panel close control only hides the live session", !controller.isTerminalVisible && controller.terminalPanel === panel && processExists(jobPID))

        let idleWindow = owner.newWindow(at: root, show: false, cascade: false)
        idleWindow.toggleTerminal(nil)
        try await waitUntil("second window loads independently", { idleWindow.browser.model.generation > 0 })

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
        try check("application quit cancellation sees hidden background tasks", owner.applicationShouldTerminate(NSApp) == .terminateCancel
            && quitSawBackground && quitRequests == 1)
        try check("quit guard aggregates busy hidden and idle visible windows", quitSawBothSessions && idleWindow.isTerminalVisible)
        try check("reentrant quit confirmation is denied without a second prompt", nestedQuitDenied && quitRequests == 1)
        try check("a later quit request can ask again after cancellation", owner.applicationShouldTerminate(NSApp) == .terminateCancel && quitRequests == 2)
        try check("cancelled quit leaves the hidden session running", !controller.isTerminalVisible && controller.terminalPanel === panel
            && terminal.process.running && processExists(jobPID))
        controller.tabs.newTab(at: root.appendingPathComponent("next"))
        try await waitUntil("new tab loads after cancelled quit", { controller.browser.model.generation > 0 })
        let expectedWorkspace = owner.currentWorkspaceState
        try await waitUntil("workspace autosave continues after cancelled quit", {
            if case .loaded(let saved) = workspace.load() { return saved == expectedWorkspace }
            return false
        })
        try check("hidden navigation preserves the session directory", panel.sessionDirectory == root
            && panel.pendingDirectory == root.appendingPathComponent("next") && terminal.process.shellPid == shellPID)
        owner.terminalTaskConfirmation = { action, activities in action == .quit && activities.contains(where: \.requiresConfirmation) }
        try check("quit approval guard does not itself destroy sessions", owner.confirmTerminalTermination()
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
        try check("window close cancellation checks hidden background tasks", closeSawBackground && closeRequests == 1
            && owner.windowControllers.contains { $0 === controller } && controller.terminalPanel === panel && processExists(jobPID))
        try check("reentrant window close is denied without a second prompt", nestedCloseDenied && closeRequests == 1)
        controller.terminalTaskConfirmation = { action, activities in action == .closeWindow && activities.contains(where: \.requiresConfirmation) }
        window.performClose(nil)
        try await waitUntil("approved close removes the window and retained terminal", {
            !owner.windowControllers.contains { $0 === controller } && controller.terminalPanel == nil && panel.terminalView == nil
        })
        try await waitUntil("approved close ends and reaps its shell and background task", {
            !processExists(shellPID) && !processExists(jobPID) && !terminal.process.running && terminal.process.childfd == -1
        })
        var status: Int32 = 0
        try check("approved session shutdown leaves no unreaped shell", waitpid(shellPID, &status, WNOHANG) == -1 && errno == ECHILD)

        // The remaining window exercises natural exit rather than synthesizing
        // a delegate callback. The footer must update while preserving output.
        guard let endedPanel = idleWindow.terminalPanel else { throw Failure("second panel remains owned") }
        let endedTerminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 240))
        endedPanel.installTerminal(endedTerminal, in: root)
        endedTerminal.startProcess(executable: "/bin/sh", args: ["-f", "-i"], environment: [
            "PATH=/usr/bin:/bin", "HOME=\(root.path)", "ENV=/dev/null", "TERM=xterm-256color", "PS1=$ "
        ], currentDirectory: root.path)
        send("set +H; stty -echo; printf '\\n__ENDED_%s__\\n' READY\n", to: endedTerminal)
        try await waitFor("__ENDED_READY__", in: endedTerminal)
        idleWindow.refreshTerminalActivity()
        send("printf '\\n__RETAINED_%s__\\n' OUTPUT; exit\n", to: endedTerminal)
        let endedStatus = idleWindow.browser.statusBar.terminalStatusButton
        try await waitUntil("natural shell exit updates footer status asynchronously", {
            idleWindow.window?.contentView?.layoutSubtreeIfNeeded()
            return !endedTerminal.process.running && endedStatus.title.contains("Ended")
        }, detail: { endedStatus.toolTip ?? "no ended status" })
        endedStatus.performClick(nil)
        endedStatus.performClick(nil)
        try check("ended-session footer toggles preserve the original view and final output", idleWindow.isTerminalVisible
            && endedPanel.terminalView === endedTerminal && !endedTerminal.process.running && output(endedTerminal).contains("__RETAINED_OUTPUT__")
            && endedStatus.toolTip?.contains("output is retained") == true)
    }

    @MainActor
    private static func confirmationChecks() throws {
        let busy = TerminalActivitySnapshot(tasks: [.init(pid: 42, name: "sleep\u{1b}", isStopped: false)], informationUnavailable: false)
        for action in [TerminalTaskConfirmation.Action.quit, .closeWindow, .restart] {
            let alert = TerminalTaskConfirmation.makeAlert(action: action, activities: [busy])
            try check("\(action) confirmation defaults to Cancel", alert.buttons.count == 2 && alert.buttons[0].title == "Cancel"
                && alert.buttons[0].keyEquivalent == "\r" && alert.buttons[1].keyEquivalent.isEmpty && alert.buttons[1].hasDestructiveAction)
            try check("\(action) confirmation identifies hidden tasks without raw controls", alert.informativeText.contains("hidden")
                && alert.informativeText.contains("sleep") && !alert.informativeText.contains("\u{1b}"))
        }
        let unknown = TerminalActivitySnapshot(tasks: [], informationUnavailable: true)
        try check("unavailable activity information is explicit", TerminalTaskConfirmation.makeAlert(action: .quit, activities: [unknown])
            .informativeText.contains("could not be checked"))
        try check("idle sessions pass without a dialog", TerminalTaskConfirmation.confirm(action: .quit, activities: [.idle]))
        try check("headless active and unknown sessions cancel instead of opening a modal", !TerminalTaskConfirmation.confirm(action: .quit, activities: [busy])
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
        try await waitUntil("PTY receives \(marker)", { output(terminal).contains(marker) }, detail: { output(terminal) })
    }
    @MainActor
    private static func waitUntil(_ name: String, _ condition: () -> Bool, detail: () -> String = { "" }) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { throw Failure(name + " — " + detail()) }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try check(name, true)
    }
    private static func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw Failure(name) }
        print("ok  terminal sessions: \(name)")
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private final class EmptyProvider: FileProvider {
        let homeURL: URL
        init(homeURL: URL) { self.homeURL = homeURL }
        func displayName(for url: URL) -> String { url.lastPathComponent }
        func listDirectory(_ url: URL) throws -> [FileItem] { [] }
    }
}

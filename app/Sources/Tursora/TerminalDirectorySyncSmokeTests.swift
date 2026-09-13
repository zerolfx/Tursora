import AppKit
import Darwin
import SwiftTerm

/// Real zsh sessions have an owned HOME and startup files. The same integration
/// and panel path as production is exercised without launching a user shell.
enum TerminalDirectorySyncSmokeTests: SmokeSuite {
    static let checkPrefix = "terminal directory sync: "
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            do {
                print("== terminal directory synchronization ==")
                try pureChecks()
                try await realSession()
                try await explicitZdotdir()
                completion()
            } catch {
                // `require` already embeds the prefix into a SmokeFailure.
                print("FAIL \(error is SmokeFailure ? "" : checkPrefix)\(error)")
                exit(1)
            }
        }
    }

    private static func pureChecks() throws {
        let token = "fixture"
        let path = "/tmp/quote ' ; $HOME\n雪"
        let data = Data("\(token)\04\0ok\0\(path)\0".utf8)
        try require("response preserves Unicode, newline and shell metacharacters as data", TerminalDirectorySync.parseResponse(data, token: token)?.directory.path == path)
        try require("response carries a request generation", TerminalDirectorySync.parseResponse(data, token: token)?.sequence == 4)
        let invalid = [Data("other\04\0ok\0/tmp\0".utf8), Data("fixture\0bad\0ok\0/tmp\0".utf8),
                       Data("fixture\04\0ok\0relative\0".utf8), Data("fixture\04\0ok\0/tmp".utf8),
                       Data("fixture\04\0ok\0/tmp\0extra\0".utf8)]
        try require("partial, wrong-session and malformed acknowledgements are rejected", invalid.allSatisfy { TerminalDirectorySync.parseResponse($0, token: token) == nil })
        try require("custom shells remain usable without adding zsh startup files", try TerminalDirectorySync.make(shell: "/bin/sh", environment: [:]) == nil)
        let script = TerminalDirectorySync.integrationScript(directory: URL(fileURLWithPath: "/tmp/' quoted"), token: "abc123")
        try require("integration does not inject terminal keys or claim signal handlers", !script.contains("TRAP") && !script.contains("kill ") && script.contains("zle -F -w") && script.contains("CONTEXT") && script.contains("-z \"$BUFFER\""))
        try require("wakeup and acknowledgement use builtins without spawning task processes", script.contains("builtin syswrite") && script.contains("builtin zf_mv") && !script.contains("command /bin/"))
    }

    @MainActor
    private static func realSession() async throws {
        let fixture = try Fixture(label: "main", explicitZdotdir: false)
        defer { fixture.dispose() }
        try await fixture.ready()
        try require("startup retains native file order after an unset ZDOTDIR", fixture.read("order") == "env:0\nprofile\nrc\nlogin\n")
        try require("private channel directory and files have owner-only permissions", fixture.channelPermissionsArePrivate)
        try require("idle synchronization helpers are not terminal tasks", !fixture.panel.activitySnapshot().requiresConfirmation)
        let originalPID = fixture.terminal.process.shellPid
        let special = try fixture.folder("space ' ; $HOME $(touch SHOULD_NOT_EXIST)\n雪")
        fixture.panel.followDirectory(special)
        try await fixture.synced(to: special)
        fixture.send("builtin print -rn -- \"$PWD\" > \"$HOME/observed\"\n")
        try await requireEventually("idle navigation changes the real shell cwd", timeout: 10, interval: 25_000_000, detail: { fixture.output }) { fixture.read("observed") == special.path }
        try require("path contents never become executable text", !FileManager.default.fileExists(atPath: special.appendingPathComponent("SHOULD_NOT_EXIST").path))

        let hidden = try fixture.folder("hidden")
        fixture.panel.view.isHidden = true
        fixture.panel.followDirectory(hidden)
        try await fixture.synced(to: hidden)
        try require("hidden synchronization retains the existing PTY", fixture.panel.terminalView === fixture.terminal && fixture.terminal.process.shellPid == originalPID && fixture.panel.isRunning)
        fixture.panel.view.isHidden = false

        let busy = try fixture.folder("after busy")
        fixture.send("sleep 0.8; builtin print -rn -- \"$PWD\" > \"$HOME/busy-result\"\n")
        try await requireEventually("foreground command owns PTY before navigation", timeout: 10, interval: 25_000_000) { tcgetpgrp(fixture.terminal.process.childfd) != originalPID }
        fixture.panel.followDirectory(busy)
        try await fixture.pending(keeping: hidden)
        try require("navigation cannot end the foreground command", fixture.read("busy-result") == nil)
        try await fixture.synced(to: busy)
        try require("running command keeps its cwd until completion", fixture.read("busy-result") == hidden.path)

        let reading = try fixture.folder("after read")
        let superseded = try fixture.folder("superseded")
        fixture.send("builtin print ready > \"$HOME/read-start\"; builtin read 'answer?ANSWER: '; builtin print -rn -- \"$answer\"$'\\0'\"$PWD\" > \"$HOME/read-result\"\n")
        try await requireEventually("shell builtin read has started", timeout: 10, interval: 25_000_000) { fixture.read("read-start") != nil }
        fixture.panel.followDirectory(superseded)
        fixture.panel.followDirectory(hidden)
        fixture.panel.followDirectory(reading)
        try await fixture.pending(keeping: busy)
        try require("builtin read receives no synthetic input", fixture.read("read-result") == nil && fixture.panel.isRunning)
        fixture.send("real answer ' ; $HOME\n")
        try await fixture.synced(to: reading)
        try require("read consumes exactly user input and latest navigation wins afterwards", fixture.readData("read-result") == Data("real answer ' ; $HOME\0\(busy.path)".utf8))

        let incomplete = try fixture.folder("after unfinished input")
        fixture.send("builtin print -rn -- PRESERVED > \"$HOME/incomplete-result\"")
        try await requireEventually("unfinished input is in the real line editor", timeout: 10, interval: 25_000_000) { fixture.output.contains("incomplete-result") }
        fixture.panel.followDirectory(incomplete)
        try await fixture.pending(keeping: reading)
        try require("unfinished command is neither cleared nor submitted", fixture.read("incomplete-result") == nil)
        fixture.send("\n")
        try await fixture.synced(to: incomplete)
        try require("the original unfinished command still executes once submitted", fixture.read("incomplete-result") == "PRESERVED")

        let continuation = try fixture.folder("after continuation")
        fixture.send("builtin print -rn -- '\n")
        try await requireEventually("secondary prompt is active", timeout: 10, interval: 25_000_000) { fixture.output.contains("MORE>") }
        fixture.panel.followDirectory(continuation)
        try await fixture.pending(keeping: incomplete)
        fixture.send("__MULTILINE__'\n")
        try await fixture.synced(to: continuation)
        try require("secondary prompt input is preserved", fixture.output.contains("__MULTILINE__"))

        let missing = fixture.root.appendingPathComponent("not created yet", isDirectory: true)
        fixture.panel.followDirectory(missing)
        try await requireEventually("failed cd is acknowledged without inventing a cwd", timeout: 10, interval: 25_000_000, detail: { fixture.output }) { fixture.panel.directorySyncUpdate?.state == .failed }
        try require("failure keeps the request and real previous cwd discoverable", fixture.panel.sessionDirectory?.path == continuation.path && fixture.panel.titleLabel.toolTip?.contains("Could not synchronize") == true)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
        fixture.send("\n")
        try await fixture.synced(to: missing)

        fixture.send("builtin print -rn -- \"$ZDOTDIR\" > \"$HOME/zdotdir-result\"; builtin functions TRAPUSR1 > \"$HOME/trap-result\"; false\n")
        try await requireEventually("startup-defined ZDOTDIR and trap remain accessible", timeout: 10, interval: 25_000_000) { fixture.read("trap-result")?.contains("USER_TRAP") == true }
        try require("user .zshenv ZDOTDIR changes survive integration", fixture.read("zdotdir-result") == fixture.config.path)
        try await requireEventually("integration preserves the previous command exit status", timeout: 10, interval: 25_000_000) { fixture.output.contains("SYNC:1>") }

        // Replacement invalidates a pending filesystem callback before the old
        // shell reaches a prompt. No stale report may rewrite the new view.
        fixture.send("builtin read 'last?LAST: '\n")
        try await requireEventually("last read is awaiting input", timeout: 10, interval: 25_000_000) { fixture.output.contains("LAST:") }
        fixture.panel.followDirectory(hidden)
        let replacement = LocalProcessTerminalView(frame: fixture.terminal.frame)
        fixture.panel.installTerminal(replacement, in: special)
        try await requireEventually("replaced session channel is removed", timeout: 10, interval: 25_000_000) { !FileManager.default.fileExists(atPath: fixture.sync.directory.path) }
        fixture.sync.request(reading)
        try await Task.sleep(nanoseconds: 200_000_000)
        try require("replacement and invalidation reject stale requests and acknowledgements", fixture.panel.terminalView === replacement && fixture.panel.sessionDirectory?.path == special.path && fixture.panel.directorySyncUpdate == nil)
        await fixture.stop()
        try await requireEventually("replaced shell is eventually reaped", timeout: 10, interval: 25_000_000) { !TerminalActivity.isAlive(originalPID) }
    }

    @MainActor
    private static func explicitZdotdir() async throws {
        let fixture = try Fixture(label: "explicit-zdotdir", explicitZdotdir: true)
        defer { fixture.dispose() }
        try await fixture.ready()
        try require("an explicit ZDOTDIR sources its own env then the updated native startup files", fixture.read("order") == "env:1\nprofile\nrc\nlogin\n")
        fixture.send("exit\n")
        try await requireEventually("natural shell exit retains ended state", timeout: 10, interval: 25_000_000) { fixture.panel.statusState == .ended }
        try require("native logout startup path is preserved", fixture.read("logout") == "logout\n")
        fixture.panel.followDirectory(fixture.config)
        try require("navigation never restarts an ended shell", fixture.panel.statusState == .ended && !fixture.panel.isRunning && fixture.panel.titleLabel.toolTip?.contains("Session ended") == true)
        await fixture.stop()
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let config: URL
        let panel: TerminalPanelController
        let terminal: LocalProcessTerminalView
        let sync: TerminalDirectorySync
        let window: NSWindow

        init(label: String, explicitZdotdir: Bool) throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("tursora-sync-test-\(label)-\(UUID().uuidString)", isDirectory: true)
            config = root.appendingPathComponent("native-config", isDirectory: true)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            let initialConfig = explicitZdotdir ? root.appendingPathComponent("initial-config", isDirectory: true) : root
            if explicitZdotdir { try FileManager.default.createDirectory(at: initialConfig, withIntermediateDirectories: false) }
            try "builtin print -r -- env:${+ZDOTDIR} >> \"$HOME/order\"\nbuiltin export ZDOTDIR=\"$HOME/native-config\"\n".write(to: initialConfig.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            try "builtin print profile >> \"$HOME/order\"\n".write(to: config.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
            try "PROMPT='SYNC:%?> '\nPROMPT2='MORE> '\nbindkey -e\nbuiltin print rc >> \"$HOME/order\"\nfunction TRAPUSR1() { builtin print USER_TRAP; }\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            try "builtin print login >> \"$HOME/order\"\n".write(to: config.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)
            try "builtin print logout > \"$HOME/logout\"\n".write(to: config.appendingPathComponent(".zlogout"), atomically: true, encoding: .utf8)
            var environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "ENV": "/dev/null", "TERM_PROGRAM": "Tursora"]
            if explicitZdotdir { environment["ZDOTDIR"] = initialConfig.path }
            sync = try TerminalDirectorySync.make(shell: "/bin/zsh", environment: environment)!
            panel = TerminalPanelController(initialDirectory: root)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = panel
            window.setContentSize(NSSize(width: 900, height: 260))
            terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 220))
            panel.installTerminal(terminal, in: root)
            panel.installDirectorySynchronization(sync, for: terminal)
            window.contentView?.layoutSubtreeIfNeeded()
            let launch = TerminalLaunchConfiguration.make(directory: root, shell: "/bin/zsh", environment: sync.environment)
            terminal.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment, currentDirectory: root.path)
        }

        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        func send(_ value: String) { terminal.process.send(data: Array(value.utf8)[...]) }
        var output: String { String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func read(_ name: String) -> String? { readData(name).flatMap { String(data: $0, encoding: .utf8) } }
        func readData(_ name: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(name)) }
        var channelPermissionsArePrivate: Bool {
            let paths = [sync.directory] + [".zshenv", "integration.zsh", "request", "response", "wake"].map { sync.directory.appendingPathComponent($0) }
            return paths.enumerated().allSatisfy { index, path in
                let permissions = (try? FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]) as? NSNumber
                return permissions?.intValue == (index == 0 ? 0o700 : 0o600)
            }
        }
        func ready() async throws {
            try await synced(to: root)
            try await requireEventually("real zsh primary prompt is ready", timeout: 10, interval: 25_000_000) { output.contains("SYNC:0>") }
        }
        func synced(to directory: URL) async throws {
            try await requireEventually("shell acknowledges \(directory.lastPathComponent)", timeout: 10, interval: 25_000_000,
                                        detail: { "update=\(String(describing: panel.directorySyncUpdate)) output=\(output)" }) {
                panel.directorySyncUpdate?.state == .synchronized && panel.sessionDirectory?.path == directory.path
            }
        }
        func pending(keeping directory: URL) async throws {
            try await requireEventually("request is explicitly pending", timeout: 10, interval: 25_000_000) { panel.directorySyncUpdate?.state == .waiting }
            try await Task.sleep(nanoseconds: 150_000_000)
            try require("busy or nonempty input retains the previous shell cwd", panel.sessionDirectory?.path == directory.path && panel.directorySyncUpdate?.state == .waiting && panel.titleLabel.toolTip?.contains("pending") == true)
        }
        func stop() async { await withCheckedContinuation { continuation in panel.shutdown { continuation.resume() } } }
        func dispose() {
            panel.shutdown()
            window.close()
            sync.invalidate()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

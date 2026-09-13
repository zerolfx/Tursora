import AppKit
import Darwin
import SwiftTerm

/// Real task fixtures run in isolated shells without user startup files. The
/// separate session suite covers the window's retain/hide/confirmation path.
enum TerminalActivitySmokeTests: SmokeSuite {
    static let checkPrefix = "terminal activity: "
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            print("== terminal activity ==")
            pureChecks()
            do {
                let root = try SmokeFixtures.temporaryDirectory("terminal-activity")
                defer { try? FileManager.default.removeItem(at: root) }
                await restartCancellationChecks(root)
                try await jobChecks(root)
                await execChecks(root)
                await orphanChecks(root)
                completion()
            } catch { check("controlled PTY fixtures complete", false, error.localizedDescription) }
        }
    }

    @MainActor private static func restartCancellationChecks(_ root: URL) async {
        let panel = TerminalPanelController(initialDirectory: root)
        panel.installTerminal(LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 120)), in: root)
        var launches: [URL] = []
        panel.restartSession { launches.append($0) }
        var finalShutdownFinished = false
        panel.shutdown { finalShutdownFinished = true }
        await expectEventually("explicit shutdown completes while an earlier restart is pending") { finalShutdownFinished }
        check("close or quit suppresses a pending restart launch", launches.isEmpty && panel.terminalView == nil && !panel.isRunning)

        let replacement = TerminalPanelController(initialDirectory: root)
        replacement.installTerminal(LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 120)), in: root)
        replacement.restartSession { launches.append($0) }
        await expectEventually("an uncancelled restart launches once after cleanup") { launches.count == 1 }
        check("restart retains the requested destination through asynchronous cleanup", launches == [root])
        replacement.shutdown()
    }

    private static func pureChecks() {
        typealias Record = TerminalActivity.ProcessRecord
        let shell = TerminalActivity.Identity(pid: 710001, startedSeconds: 100, startedMicroseconds: 2)
        func record(_ pid: Int32, _ parent: Int32, _ session: Int32, _ name: String,
                    status: Int32 = SRUN, seconds: UInt64 = 101) -> Record {
            Record(identity: pid == shell.pid && seconds == 101 ? shell : .init(pid: pid, startedSeconds: seconds, startedMicroseconds: 2),
                   parentPID: parent, sessionID: session, name: name, status: UInt32(status))
        }
        let idle = record(shell.pid, getpid(), shell.pid, "sh")
        let foreground = record(710002, shell.pid, shell.pid, "sleep")
        let background = record(710003, shell.pid, shell.pid, "worker")
        let stopped = record(710004, shell.pid, shell.pid, "editor", status: SSTOP)
        let orphan = record(710005, 1, shell.pid, "nohup")
        let changedSession = record(710006, background.pid, 710006, "child")
        let detached = record(710007, 1, 710007, "detached")
        let zombie = record(710008, shell.pid, shell.pid, "finished", status: SZOMB)
        let unrelated = record(710009, getpid(), getpgrp(), "unrelated")
        let members = TerminalActivity.Session.members(of: shell, in: [idle, foreground, background, stopped, orphan, changedSession, detached, zombie, unrelated])
        let activity = TerminalActivity.Session.classify(shell: shell, members: members, shellNames: ["sh"], informationUnavailable: false)
        check("classifier includes foreground, background, stopped, orphan and descendant jobs", Set(activity.tasks.map(\.pid)) == Set([foreground.pid, background.pid, stopped.pid, orphan.pid, changedSession.pid]))
        check("classifier identifies stopped work and excludes unrelated sessions and zombies", activity.tasks.filter(\.isStopped).map(\.pid) == [stopped.pid] && activity.requiresConfirmation)
        check("idle interactive shell does not require confirmation", !TerminalActivity.Session.classify(shell: shell, members: [idle], shellNames: ["sh"], informationUnavailable: false).requiresConfirmation)
        check("unavailable relevant process information requires confirmation", TerminalActivity.Session.classify(shell: shell, members: [idle], shellNames: ["sh"], informationUnavailable: true).requiresConfirmation)
        let exec = record(shell.pid, getpid(), shell.pid, "sleep")
        check("exec'ed command at shell PID is active work", TerminalActivity.Session.classify(shell: shell, members: [exec], shellNames: ["sh"], informationUnavailable: false).tasks.map(\.pid) == [shell.pid])
        let reused = record(shell.pid, getpid(), shell.pid, "sh", seconds: 999)
        check("reused leader PID cannot transfer ownership to a different process", TerminalActivity.Session.members(of: shell, in: [reused, foreground]).isEmpty)
        check("shutdown requires the captured birth identity before signalling or reaping a child", TerminalActivity.ownsShell(idle, expected: shell) && !TerminalActivity.ownsShell(reused, expected: shell) && !TerminalActivity.ownsShell(idle, expected: nil))
        check("unreadable leader metadata cannot be mistaken for an idle session", TerminalActivity.Session.missingShellInformation(shell: shell, table: .init(records: [], unavailablePIDs: [shell.pid], isComplete: true), shellIsAlive: true))
        check("missing live leader remains unknown even if enumeration claims completeness", TerminalActivity.Session.missingShellInformation(shell: shell, table: .init(records: [], unavailablePIDs: [], isComplete: true), shellIsAlive: true))
        if let current = TerminalActivity.readProcess(getpid()) {
            let stale = Record(identity: .init(pid: current.pid, startedSeconds: current.identity.startedSeconds + 1, startedMicroseconds: current.identity.startedMicroseconds), parentPID: current.parentPID, sessionID: current.sessionID, name: current.name, status: current.status)
            check("signal helper rejects the app and mismatched birth identities", !TerminalActivity.signal(current, 0) && !TerminalActivity.signal(stale, 0))
        } else { check("own process metadata is available", false) }
    }

    @MainActor private static func jobChecks(_ root: URL) async throws {
        let probe = await ready(root)
        let session = TerminalActivity.Session(process: probe.process)!
        defer { TerminalProcessLifecycle.stop(probe.process, session: session) }
        check("real idle PTY shell does not warn", !session.snapshot().requiresConfirmation)
        probe.send("/bin/sleep 30\n")
        await expectEventually("foreground job is detected independently of shell PID") {
            let value = session.snapshot()
            return tcgetpgrp(probe.process.childfd) != probe.process.shellPid && value.tasks.contains { $0.name == "sleep" }
        }
        probe.send("\u{1a}")
        await expectEventually("Control-Z leaves a stopped task at an idle shell prompt") {
            session.snapshot().tasks.contains( where: \.isStopped) && tcgetpgrp(probe.process.childfd) == probe.process.shellPid
        }
        probe.send("bg\nprintf '\\n__BACKGROUND_READY__\\n'\n")
        await expectEventually("background job continues while shell owns the foreground") {
            probe.output.contains("\r\n__BACKGROUND_READY__\r\n") && tcgetpgrp(probe.process.childfd) == probe.process.shellPid
                && session.snapshot().tasks.contains { $0.name == "sleep" && !$0.isStopped }
        }
        probe.send("/bin/sh -c 'trap \"\" HUP; /bin/sleep 30' &\nprintf '\\n__HUP_IGNORED__\\n'\n")
        await expectEventually("additional HUP-ignoring background work starts") {
            probe.output.contains("\r\n__HUP_IGNORED__\r\n") && session.snapshot().tasks.filter { $0.name == "sleep" }.count >= 2
        }
        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["30"]
        try sentinel.run()
        defer { if sentinel.isRunning { sentinel.terminate() }; sentinel.waitUntilExit() }
        let members = session.ownedProcesses().filter { !$0.isZombie }
        let shellPID = probe.process.shellPid
        var firstFinished = false
        var secondFinished = false
        var allFinished = false
        TerminalProcessLifecycle.stop(probe.process, session: session) { firstFinished = true }
        TerminalProcessLifecycle.stop(probe.process, session: session) { secondFinished = true }
        TerminalProcessLifecycle.whenAllStopped { allFinished = true }
        check("duplicate callers and the global shutdown barrier wait for cleanup", !firstFinished && !secondFinished && !allFinished)
        await expectEventually("owned shell shutdown and all completion barriers finish") { firstFinished && secondFinished && allFinished }
        await expectEventually("foreground and HUP-ignoring background jobs all stop") { members.allSatisfy(noLongerRunning) }
        check("shutdown does not signal an unrelated sibling process", sentinel.isRunning && kill(sentinel.processIdentifier, 0) == 0)
        var status: Int32 = 0
        let result = waitpid(shellPID, &status, WNOHANG)
        check("shutdown reaps only its direct shell child", result == -1 && errno == ECHILD && probe.process.childfd == -1 && !probe.process.running)
    }

    @MainActor private static func execChecks(_ root: URL) async {
        let probe = await ready(root)
        let session = TerminalActivity.Session(process: probe.process)!
        let shell = session.shell
        probe.send("exec /bin/sleep 30\n")
        await expectEventually("real exec preserves shell PID but still requires confirmation") {
            let value = session.snapshot()
            return tcgetpgrp(probe.process.childfd) == shell.pid && value.tasks.contains { $0.pid == shell.pid && $0.name == "sleep" }
        }
        await stop(probe.process, session: session)
        check("exec'ed command is reaped during confirmed shutdown", TerminalActivity.readProcess(shell.pid) == nil)
    }

    @MainActor private static func orphanChecks(_ root: URL) async {
        let probe = await ready(root)
        let session = TerminalActivity.Session(process: probe.process)!
        probe.send("/bin/sh -c 'trap \"\" HUP; /bin/sleep 30' &\nprintf '\\n__ORPHAN_READY__\\n'\n")
        await expectEventually("orphan fixture owns HUP-ignoring work") {
            probe.output.contains("\r\n__ORPHAN_READY__\r\n") && session.snapshot().tasks.contains { $0.name == "sleep" }
        }
        let jobs = session.ownedProcesses().filter { $0.pid != session.shell.pid && !$0.isZombie }
        probe.send("exit\n")
        await expectEventually("shell can exit while a background task retains the PTY session") {
            TerminalActivity.readProcess(session.shell.pid) == nil && session.snapshot().requiresConfirmation
        }
        await stop(probe.process, session: session)
        await expectEventually("natural shell exit does not abandon retained session jobs") { jobs.allSatisfy(noLongerRunning) }
    }

    private static func noLongerRunning(_ record: TerminalActivity.ProcessRecord) -> Bool {
        guard let current = TerminalActivity.readProcess(record.pid) else { return true }
        return current.identity != record.identity || current.isZombie
    }

    @MainActor private static func ready(_ root: URL) async -> Probe {
        let probe = Probe()
        probe.process.startProcess(executable: "/bin/sh", args: ["-f", "-i"],
                                   environment: ["PATH=/usr/bin:/bin", "HOME=\(root.path)", "ENV=/dev/null", "TERM=xterm-256color", "PS1=$ "], currentDirectory: root.path)
        probe.send("stty -echo; printf '\\n__ACTIVITY_READY__\\n'\n")
        await expectEventually("controlled shell is ready") { probe.output.contains("\r\n__ACTIVITY_READY__\r\n") }
        return probe
    }

    @MainActor private static func stop(_ process: LocalProcess, session: TerminalActivity.Session) async {
        await withCheckedContinuation { continuation in
            TerminalProcessLifecycle.stop(process, session: session) { continuation.resume() }
        }
    }

    private final class Probe: LocalProcessDelegate {
        lazy var process = LocalProcess(delegate: self)
        var output = ""
        func send(_ text: String) { process.send(data: Array(text.utf8)[...]) }
        func dataReceived(slice: ArraySlice<UInt8>) { output += String(decoding: slice, as: UTF8.self) }
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
        func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0) }
    }
}

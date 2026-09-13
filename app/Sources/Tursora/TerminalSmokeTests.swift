import AppKit
import Darwin
import SwiftTerm

/// Header/delegate checks use terminal views without processes. PTY checks use
/// an isolated /bin/sh and never read the user's shell configuration.
enum TerminalSmokeTests: SmokeSuite {
    static func run(completion: @escaping () -> Void) {
        print("== terminal ==")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-terminal-" + UUID().uuidString)
        let directory = root.appendingPathComponent("quoted ' folder; $HOME", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("second"), withIntermediateDirectories: true)
        } catch { fail("terminal fixture", error.localizedDescription) }
        let configuration = TerminalLaunchConfiguration.make(directory: directory, shell: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"])
        check("terminal: directory and shell are separate argv values", configuration.arguments[3] == directory.path && configuration.arguments[4] == "/bin/sh" && !configuration.arguments[1].contains(directory.path))
        check("terminal: wrapper refuses a failed directory change", configuration.arguments[1].contains("cd -- \"$1\" || exit 1"))
        check("terminal: terminal capabilities are explicit", configuration.environment.contains("TERM=xterm-256color") && configuration.environment.contains("COLORTERM=truecolor"))
        presentationChecks(in: directory)
        let controller = TerminalPanelController(initialDirectory: directory)
        _ = controller.view
        controller.followDirectory(root)
        controller.focus()
        check("terminal: view creation and directory following never launch in smoke mode", !controller.isRunning && controller.terminalView == nil && controller.pendingDirectory == root)
        controller.shutdown()
        controller.shutdown()
        check("terminal: shutdown before launch is idempotent", !controller.isRunning)
        headerChecks(in: directory, destination: root)

        let probe = PTYProbe()
        probe.process.startProcess(executable: "/bin/sh", args: ["-f", "-i"], environment: [
            "PATH=/usr/bin:/bin", "HOME=\(root.path)", "ENV=/dev/null", "TERM=xterm-256color", "PS1=$ "
        ], currentDirectory: directory.path)
        check("terminal: starts a real owned PTY", probe.process.running && probe.process.shellPid > 0 && isatty(probe.process.childfd) == 1)
        probe.send("stty -echo; test -t 0 && printf '\\n__PTY_READY__\\n'\n")
        wait(probe, for: "\r\n__PTY_READY__\r\n") {
            probe.output = ""
            probe.send("pwd; cd second; pwd; printf '\\n__PTY_CD__\\n'\n")
            wait(probe, for: "\r\n__PTY_CD__\r\n") {
                check("terminal: interactive pwd and cd preserve special-character initial path", probe.output.contains(directory.path) && probe.output.contains(directory.appendingPathComponent("second").path))
                probe.output = ""
                probe.send("sleep 30\n")
                waitUntil("terminal: child command owns the foreground PTY", condition: {
                    let foreground = tcgetpgrp(probe.process.childfd)
                    return foreground > 0 && foreground != probe.process.shellPid
                }) {
                    probe.send("\u{3}")
                    waitUntil("terminal: Control-C restores the shell foreground group", condition: {
                        tcgetpgrp(probe.process.childfd) == probe.process.shellPid
                    }) {
                      probe.send("printf '\\n__PTY_INTERRUPT__\\n'\n")
                      wait(probe, for: "\r\n__PTY_INTERRUPT__\r\n") {
                        check("terminal: Control-C interrupts a foreground command and returns to shell", probe.process.running)
                        let pid = probe.process.shellPid
                        TerminalProcessLifecycle.stop(probe.process) {
                            var status: Int32 = 0
                            let result = waitpid(pid, &status, WNOHANG)
                            check("terminal: shutdown closes the PTY and reaps its shell", !probe.process.running && probe.process.childfd == -1 && result == -1 && errno == ECHILD)
                            TerminalProcessLifecycle.stop(probe.process)
                            eofBeforeExitCallback(in: root) {
                                try? FileManager.default.removeItem(at: root)
                                completion()
                            }
                        }
                      }
                    }
                }
            }
        }
    }

    private static func presentationChecks(in directory: URL) {
        let destination = directory.appendingPathComponent("second", isDirectory: true)
        var display = TerminalPanelPresentation(state: .running, startedDirectory: directory)
        check("terminal: launch path is labelled as initial rather than current cwd", display.locationText.hasPrefix("Started in: ") && display.reportedDirectory == nil)
        check("terminal: restart destination is visible independently of shell location", display.destinationText(destination).hasPrefix("Restart in: ") && display.destinationText(destination).contains("second") && !display.locationText.contains("second"))
        display.reportedDirectory = destination
        check("terminal: a reported cwd has an explicit shell label", display.locationText.hasPrefix("Shell folder: ") && display.locationText.contains("second"))
        display.state = .ended
        let ended = display.locationText
        check("terminal: ended sessions offer Start while preserving their status", ended.contains("Session ended") && display.actionTitle == "Start Terminal" && display.destinationText(directory).hasPrefix("Start in: ") && display.locationText == ended)
        display.state = .failedToStart
        let failure = display.locationText
        check("terminal: failed starts survive destination changes", failure == "Could not start the terminal." && display.destinationText(destination).contains("second") && display.locationText == failure)
        display = TerminalPanelPresentation(state: .running, startedDirectory: URL(fileURLWithPath: "/tmp/folder\nnext"))
        check("terminal: path control characters cannot add header lines", !display.locationText.contains("\n") && display.locationText.contains("�"))

        let hosts: Set<String> = ["fixture-mac.local", "fixture-mac"]
        let valid = ["file:///tmp/Folder%20Name", "file://localhost/tmp/Folder%20Name", "file://FIXTURE-MAC.local/tmp/Folder%20Name"]
        check("terminal: local and known-host OSC paths decode safely", valid.allSatisfy { TerminalPanelPresentation.localDirectory($0, localHostNames: hosts)?.path == "/tmp/Folder Name" })
        let invalid = ["https://localhost/tmp", "file://other-mac.local/tmp", "file://user@localhost/tmp", "file://localhost:42/tmp", "file:///tmp/%00bad", "file:///tmp/name?query", "file:///tmp/name#fragment", "relative/path", "file:relative"]
        check("terminal: remote, decorated and malformed OSC paths are ignored", invalid.allSatisfy { TerminalPanelPresentation.localDirectory($0, localHostNames: hosts) == nil })
        check("terminal: missing cwd reports do not invent a location", TerminalPanelPresentation.localDirectory(nil, localHostNames: hosts) == nil)
    }

    private static func headerChecks(in directory: URL, destination: URL) {
        let controller = TerminalPanelController(initialDirectory: directory, localHostNames: ["fixture-mac.local"])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // Installing a controller adopts its fitting size. Set the intended
        // browser width afterwards before asserting its actual header layout.
        window.setContentSize(NSSize(width: 560, height: 180))
        defer { controller.shutdown(); window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        check("terminal: opening header never starts a shell in smoke mode", controller.terminalView == nil && !controller.isRunning)
        check("terminal: compact header exposes Start through accessibility and tooltip", controller.restartButton.accessibilityLabel() == "Start Terminal" && controller.restartButton.toolTip?.contains(directory.path) == true && controller.restartButton.title.isEmpty)

        let original = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 560, height: 120))
        controller.installTerminal(original, in: directory)
        check("terminal: view installation is separate from process launch", original.process.shellPid == 0 && !controller.isRunning)
        controller.followDirectory(destination)
        check("terminal: unsupported session keeps cwd and explains pending target in tooltip", controller.sessionDirectory?.path == directory.path && controller.titleLabel.toolTip?.contains("needs zsh integration") == true && controller.restartButton.toolTip?.contains(destination.path) == true)
        controller.hostCurrentDirectoryUpdate(source: original, directory: "file://fixture-mac.local/tmp/Shell%20Folder")
        check("terminal: active source updates the accessible shell folder", controller.sessionDirectory?.path == "/tmp/Shell Folder" && controller.titleLabel.toolTip?.contains("Shell folder: /tmp/Shell Folder") == true && controller.pendingDirectory == destination)
        controller.hostCurrentDirectoryUpdate(source: original, directory: "file://other-mac.local/tmp/Foreign")
        check("terminal: remote-host report cannot alter visible shell state", controller.sessionDirectory?.path == "/tmp/Shell Folder")

        let replacement = LocalProcessTerminalView(frame: original.frame)
        controller.installTerminal(replacement, in: destination)
        controller.hostCurrentDirectoryUpdate(source: original, directory: "file:///tmp/Stale")
        controller.processTerminated(source: original, exitCode: 0)
        check("terminal: old view callbacks cannot replace a restarted session", controller.terminalView === replacement && controller.sessionDirectory?.path == destination.path && controller.statusState == .running && original.superview == nil)
        controller.processTerminated(source: replacement, exitCode: 0)
        let ended = controller.titleLabel.toolTip
        controller.followDirectory(directory)
        controller.hostCurrentDirectoryUpdate(source: replacement, directory: "file:///tmp/TooLate")
        check("terminal: navigation and late cwd reports preserve natural exit", controller.titleLabel.toolTip == ended && ended?.contains("Session ended") == true && controller.sessionDirectory?.path == destination.path && controller.restartButton.accessibilityLabel() == "Start Terminal")
        check("terminal: natural exit keeps output view and next target in tooltip", controller.terminalView === replacement && replacement.superview != nil && controller.restartButton.toolTip?.contains(directory.path) == true && controller.pendingDirectory == directory)

        window.contentView?.layoutSubtreeIfNeeded()
        let bounds = controller.view.bounds
        let actionFrame = controller.view.convert(controller.restartButton.bounds, from: controller.restartButton)
        let titleFrame = controller.view.convert(controller.titleLabel.bounds, from: controller.titleLabel)
        check("terminal: single compact header leaves more room for output", bounds.contains(actionFrame) && bounds.contains(titleFrame) && replacement.frame.height >= 145 && abs(actionFrame.midY - titleFrame.midY) < 5,
              "bounds=\(bounds) action=\(actionFrame) title=\(titleFrame) terminal=\(replacement.frame)")
        controller.shutdown()
        controller.hostCurrentDirectoryUpdate(source: replacement, directory: "file:///tmp/AfterClose")
        controller.processTerminated(source: replacement, exitCode: 1)
        check("terminal: closed panel rejects late source callbacks", controller.terminalView == nil && controller.sessionDirectory == nil && !controller.isRunning)
    }

    private final class PTYProbe: LocalProcessDelegate {
        private let deliveryQueue: DispatchQueue?
        init(queue: DispatchQueue? = nil) { deliveryQueue = queue }
        lazy var process = LocalProcess(delegate: self, dispatchQueue: deliveryQueue)
        var output = ""
        func send(_ text: String) { process.send(data: Array(text.utf8)[...]) }
        func dataReceived(slice: ArraySlice<UInt8>) { output += String(decoding: slice, as: UTF8.self) }
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
        func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0) }
    }

    private static func eofBeforeExitCallback(in directory: URL, completion: @escaping () -> Void) {
        let delivery = DispatchQueue(label: "tursora-terminal-exit-regression")
        delivery.suspend()
        let probe = PTYProbe(queue: delivery)
        let ready = directory.appendingPathComponent("eof-ready-" + UUID().uuidString)
        // No prompt/echo output: SwiftTerm synchronously delivers nonempty
        // reads to this intentionally suspended alternate queue. A quiet
        // readiness file lets the read queue reach EOF before the exit monitor.
        probe.process.startProcess(executable: "/bin/sh", args: ["-c", "stty -echo; : > \"$1\"; read tursora_exit; exit 0", "tursora-eof", ready.path],
                                   environment: ["PATH=/usr/bin:/bin", "HOME=\(directory.path)", "ENV=/dev/null"],
                                   currentDirectory: directory.path)
        waitUntil("terminal: EOF fixture captures its shell identity while alive", condition: {
            guard FileManager.default.fileExists(atPath: ready.path),
                  let record = TerminalActivity.readProcess(probe.process.shellPid) else { return false }
            return probe.process.running && !record.isZombie && record.parentPID == getpid() && record.sessionID == record.pid
        }, detail: {
            "pid=\(probe.process.shellPid), running=\(probe.process.running), record=\(String(describing: TerminalActivity.readProcess(probe.process.shellPid))), owner=\(getpid()), ready=\(FileManager.default.fileExists(atPath: ready.path))"
        }) {
            let session = TerminalActivity.Session(process: probe.process)!
            probe.send("exit\n")
            waitUntil("terminal: EOF precedes the suspended exit callback", condition: {
                !probe.process.running && TerminalActivity.readProcess(probe.process.shellPid)?.isZombie == true
            }) {
                let pid = probe.process.shellPid
                check("terminal: unreaped zombie retains its captured birth identity", TerminalActivity.readProcess(pid)?.identity == session.shell)
                TerminalProcessLifecycle.stop(probe.process, session: session) {
                    var status: Int32 = 0
                    let outcome = waitpid(pid, &status, WNOHANG)
                    check("terminal: closing after EOF still reaps the owned shell", outcome == -1 && errno == ECHILD, "outcome=\(outcome), errno=\(errno)")
                    delivery.resume()
                    completion()
                }
            }
        }
    }

    private static func wait(_ probe: PTYProbe, for text: String, completion: @escaping () -> Void) {
        waitUntil("terminal: receives \(text.trimmingCharacters(in: .whitespacesAndNewlines))", condition: { probe.output.contains(text) }, detail: { probe.output }, completion: completion)
    }
    /// Callback form of `expectEventually` for this suite's completion chain;
    /// the PTY polling cadence is unchanged.
    private static func waitUntil(_ name: String, condition: @escaping () -> Bool, detail: @escaping () -> String = { "" }, completion: @escaping () -> Void) {
        Task { @MainActor in
            await expectEventually(name, timeout: 10, interval: 30_000_000, detail: detail, condition)
            completion()
        }
    }
}

import AppKit
import Darwin
import SwiftTerm

/// Exercises the PTY without creating a terminal view or reading user rc files.
enum TerminalSmokeTests {
    static func run(completion: @escaping () -> Void) {
        print("== experimental terminal ==")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-terminal-" + UUID().uuidString)
        let directory = root.appendingPathComponent("quoted ' folder; $HOME", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("second"), withIntermediateDirectories: true)
        } catch { fail("terminal fixture", error.localizedDescription) }
        let configuration = TerminalLaunchConfiguration.make(directory: directory, shell: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"])
        check("terminal: directory and shell are separate argv values", configuration.arguments[3] == directory.path && configuration.arguments[4] == "/bin/sh" && !configuration.arguments[1].contains(directory.path))
        check("terminal: wrapper refuses a failed directory change", configuration.arguments[1].contains("cd -- \"$1\" || exit 1"))
        check("terminal: terminal capabilities are explicit", configuration.environment.contains("TERM=xterm-256color") && configuration.environment.contains("COLORTERM=truecolor"))
        let controller = TerminalPanelController(initialDirectory: directory)
        _ = controller.view
        controller.followDirectory(root)
        controller.focus()
        check("terminal: view creation and directory following never launch in smoke mode", !controller.isRunning && controller.terminalView == nil && controller.pendingDirectory == root)
        controller.shutdown()
        controller.shutdown()
        check("terminal: shutdown before launch is idempotent", !controller.isRunning)

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
        probe.process.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"],
                                   environment: ["PATH=/usr/bin:/bin", "HOME=\(directory.path)", "ENV=/dev/null"],
                                   currentDirectory: directory.path)
        waitUntil("terminal: EOF precedes the suspended exit callback", condition: {
            probe.process.shellPid > 0 && !probe.process.running
        }) {
            let pid = probe.process.shellPid
            TerminalProcessLifecycle.stop(probe.process) {
                var status: Int32 = 0
                let outcome = waitpid(pid, &status, WNOHANG)
                check("terminal: closing after EOF still reaps the owned shell", outcome == -1 && errno == ECHILD)
                delivery.resume()
                completion()
            }
        }
    }

    private static func wait(_ probe: PTYProbe, for text: String, completion: @escaping () -> Void) {
        waitUntil("terminal: receives \(text.trimmingCharacters(in: .whitespacesAndNewlines))", condition: { probe.output.contains(text) }, detail: { probe.output }, completion: completion)
    }
    private static func waitUntil(_ name: String, condition: @escaping () -> Bool, detail: @escaping () -> String = { "" }, completion: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(10)
        func poll() {
            if condition() { check(name, true); completion(); return }
            if Date() >= deadline { fail(name, detail()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
        }
        poll()
    }
    private static func check(_ name: String, _ condition: Bool) {
        if condition { print("ok  \(name)") } else { fail(name, "") }
    }
    private static func fail(_ name: String, _ detail: String) -> Never {
        print("FAIL \(name) \(detail)")
        exit(1)
    }
}

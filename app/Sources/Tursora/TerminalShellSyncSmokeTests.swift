import AppKit
import Darwin
import SwiftTerm

/// Both directions of terminal ↔ browser folder sync, for every integrated
/// shell. Real zsh, bash and (when installed) fish sessions run in an owned
/// HOME with their own startup files; the user's shell configuration and
/// preferences are never read or written.
enum TerminalShellSyncSmokeTests: SmokeSuite {
    static let checkPrefix = "terminal shell sync: "
    static let fishPath = "/opt/homebrew/bin/fish"

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            do {
                print("== terminal shell sync ==")
                try pureChecks()
                try preferenceChecks()
                try await panelChecks()
                try await windowChecks()
                try await zshSession()
                try await bashSession()
                try await fishSession()
                completion()
            } catch {
                // `require` already embeds the prefix into a SmokeFailure.
                print("FAIL \(error is SmokeFailure ? "" : checkPrefix)\(error)")
                exit(1)
            }
        }
    }

    // MARK: - Pure helpers

    private static func pureChecks() throws {
        let kinds = ["/bin/zsh": TerminalShellIntegration.Kind.zsh, "/usr/local/bin/zsh": .zsh,
                     "/bin/bash": .bash, "/opt/homebrew/bin/bash": .bash, fishPath: .fish]
        try require("each integrated shell is recognised by executable name",
                    kinds.allSatisfy { TerminalShellIntegration.kind(forShell: $0.key) == $0.value })
        try require("uninstrumented shells stay plain interactive sessions",
                    ["/bin/sh", "/bin/ksh", "/bin/tcsh", "/tmp/zsh-copy", ""].allSatisfy { TerminalShellIntegration.kind(forShell: $0) == nil })
        try require("only zsh can act on a request at an idle prompt",
                    TerminalShellIntegration.Kind.zsh.appliesRequestsWhileIdle
                    && !TerminalShellIntegration.Kind.bash.appliesRequestsWhileIdle
                    && !TerminalShellIntegration.Kind.fish.appliesRequestsWhileIdle)

        // Foundation's file-URL standardization drops a leading /private, which
        // would rename the folder the shell actually reported.
        let hosts: Set<String> = ["fixture-mac.local"]
        try require("a reported path under /private keeps the shell's own spelling",
                    TerminalPanelPresentation.localDirectory("file:///private/tmp/Shell%20Folder", localHostNames: hosts)?.path
                        == "/private/tmp/Shell Folder")
        try require("dot segments in a reported path are still resolved",
                    TerminalPanelPresentation.localDirectory("file:///tmp/one/../two", localHostNames: hosts)?.path == "/tmp/two")
        try require("the same folder under both spellings is one folder",
                    TerminalPanelPresentation.isSameDirectory(URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                                                              URL(fileURLWithPath: "/tmp", isDirectory: true)))

        let directory = URL(fileURLWithPath: "/tmp/quoted ' folder; $HOME", isDirectory: true)
        let configuration = TerminalLaunchConfiguration.make(directory: directory, shell: "/bin/bash",
                                                            shellArguments: ["-i", "--rcfile", "/tmp/rc file"],
                                                            environment: ["PATH": "/usr/bin:/bin"])
        try require("integration arguments stay separate argv values after the shell",
                    Array(configuration.arguments.suffix(3)) == ["-i", "--rcfile", "/tmp/rc file"]
                    && configuration.arguments[3] == directory.path && configuration.arguments[4] == "/bin/bash"
                    && !configuration.arguments[1].contains("--rcfile"))
        try require("the wrapper still refuses a failed directory change",
                    configuration.arguments[1].contains("cd -- \"$1\" || exit 1"))
        // bash stops looking for long options at the first short one, so an
        // integration file passed after -i would be parsed as short options.
        let bashSync = try TerminalDirectorySync.make(shell: "/bin/bash", environment: [:])
        defer { bashSync?.invalidate() }
        try require("bash receives its integration file before any short option",
                    bashSync?.shellArguments.first == "--rcfile" && bashSync?.shellArguments.last == "-i"
                    && bashSync?.shellArguments.count == 3
                    && bashSync?.environment.keys.contains("ZDOTDIR") == false)

        let token = "abc123"
        let root = URL(fileURLWithPath: "/tmp/' quoted", isDirectory: true)
        let zsh = TerminalDirectorySync.integrationScript(directory: root, token: token)
        try require("zsh reports its folder from the precmd hook",
                    zsh.contains("_ts_\(token)_osc7") && zsh.contains("]7;file://") && zsh.contains("precmd_functions+=(_ts_\(token)_prompt)"))
        try require("zsh percent-encodes reported bytes rather than characters",
                    zsh.contains("no_multibyte") && zsh.contains("printf -v hex '%%%02X'"))

        let bash = TerminalShellIntegration.bashRunCommands(directory: root, token: token)
        try require("bash reads the user's own startup files first, in login order",
                    bash.contains("/etc/profile") && bash.contains("\"$HOME/.bash_profile\" \"$HOME/.bash_login\" \"$HOME/.profile\" \"$HOME/.bashrc\""))
        try require("bash keeps an existing PROMPT_COMMAND and adds the hook",
                    bash.contains("PROMPT_COMMAND=\"$PROMPT_COMMAND\"") && bash.contains("_ts_\(token)_prompt"))
        try require("bash reads the request as NUL-delimited data, never as commands",
                    bash.contains("read -r -d '' number") && bash.contains("builtin cd -- \"$target\"")
                    && !bash.contains("eval") && !bash.contains("$(") )
        try require("bash preserves the exit status the prompt shows",
                    bash.contains("local _ts_\(token)_status=$?") && bash.contains("return $_ts_\(token)_status"))

        let fish = TerminalShellIntegration.fishInitCommand(directory: root, token: token)
        try require("fish reports on every PWD change and again at each prompt",
                    fish.contains("_ts_\(token)_osc7 --on-variable PWD")
                    && fish.contains("function _ts_\(token)_prompt --on-event fish_prompt")
                    && fish.contains("    _ts_\(token)_osc7\nend"))
        try require("fish keeps path separators unescaped in the reported file URL",
                    fish.contains("string escape --style=url") && fish.contains("'%2[Ff]'"))
        try require("fish reads the request as data and never evaluates it",
                    fish.contains("read --null --local target") && fish.contains("builtin cd \"$target\"") && !fish.contains("eval"))
        for (name, script) in [("zsh", zsh), ("bash", bash), ("fish", fish)] {
            try require("\(name) quotes only its own channel path and claims no signals",
                        script.contains("'/tmp/'\\''" + " quoted'") && !script.contains("kill ") && !script.contains("trap "))
        }
    }

    private static func preferenceChecks() throws {
        let suite = "Tursora.TerminalShellSyncSmoke." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw SmokeFailure("\(checkPrefix)isolated defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
        try require("both directions are on by default",
                    store.configuration.terminalFollowsBrowser && store.configuration.browserFollowsShell)

        // A configuration written before the directions existed keeps the shell
        // and appearance the user chose instead of resetting everything.
        let legacy = ##"{"shellMode":"custom","customShell":"/bin/bash","fontName":"","fontSize":15,"theme":"dark","foreground":"#E6E6E6","background":"#17191D"}"##
        defaults.set(Data(legacy.utf8), forKey: TerminalPreferences.storageKey)
        let migrated = store.configuration
        try require("an older stored configuration keeps its shell and gains both directions on",
                    migrated.customShell == "/bin/bash" && migrated.fontSize == 15 && migrated.theme == .dark
                    && migrated.terminalFollowsBrowser && migrated.browserFollowsShell)

        let page = TerminalSettingsViewController(preferences: store)
        let second = TerminalSettingsViewController(preferences: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = page
        window.setContentSize(NSSize(width: 540, height: 660))
        defer { window.close() }
        _ = second.view
        try require("Terminal settings offer Finder-neutral wording for both directions",
                    page.terminalFollowsBrowserBox.title == "Terminal follows the browser folder"
                    && page.browserFollowsShellBox.title == "Browser follows the shell folder")
        try require("the forward checkbox explains when bash and fish apply a request",
                    page.terminalFollowsBrowserBox.toolTip?.contains("next prompt you draw") == true
                    && page.terminalFollowsBrowserBox.toolTip?.contains("Nothing is ever typed into the shell") == true)
        try require("the reverse checkbox explains that it needs a visible panel",
                    page.browserFollowsShellBox.toolTip?.contains("visible") == true)

        page.browserFollowsShellBox.state = .off
        guard let action = page.browserFollowsShellBox.action,
              NSApp.sendAction(action, to: page.browserFollowsShellBox.target, from: page.browserFollowsShellBox) else {
            throw SmokeFailure("\(checkPrefix)reverse checkbox dispatches its action")
        }
        try require("turning the reverse direction off saves and reaches another settings page",
                    !store.configuration.browserFollowsShell && store.configuration.terminalFollowsBrowser
                    && second.browserFollowsShellBox.state == .off && second.terminalFollowsBrowserBox.state == .on)
        page.terminalFollowsBrowserBox.state = .off
        _ = NSApp.sendAction(action, to: page.terminalFollowsBrowserBox.target, from: page.terminalFollowsBrowserBox)
        let reloaded = TerminalPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
        try require("both directions round-trip through storage",
                    !reloaded.configuration.terminalFollowsBrowser && !reloaded.configuration.browserFollowsShell)
        page.restoreDefaults(nil)
        try require("Restore Terminal Defaults turns both directions back on",
                    store.configuration.terminalFollowsBrowser && store.configuration.browserFollowsShell
                    && page.terminalFollowsBrowserBox.state == .on && second.browserFollowsShellBox.state == .on)

        window.contentView?.layoutSubtreeIfNeeded()
        for box in [page.terminalFollowsBrowserBox, page.browserFollowsShellBox] {
            let frame = page.view.convert(box.bounds, from: box)
            try require("direction checkbox fits the 540-point settings page: \(box.title)",
                        frame.width > 0 && page.view.bounds.contains(frame), "bounds=\(page.view.bounds) control=\(frame)")
        }
    }

    // MARK: - Panel behaviour without a shell

    @MainActor
    private static func panelChecks() async throws {
        let suite = "Tursora.TerminalShellSyncSmokePanel." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw SmokeFailure("\(checkPrefix)isolated panel defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
        let hosts: Set<String> = ["fixture-mac.local", "fixture-mac"]
        let start = URL(fileURLWithPath: "/tmp/Start", isDirectory: true)
        let panel = TerminalPanelController(initialDirectory: start, localHostNames: hosts, preferences: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = panel
        window.setContentSize(NSSize(width: 560, height: 200))
        defer { panel.shutdown(); window.close() }
        var reports: [URL] = []
        panel.onShellDirectoryChanged = { reports.append($0) }
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 560, height: 140))
        panel.installTerminal(terminal, in: start)
        window.contentView?.layoutSubtreeIfNeeded()

        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file://fixture-mac.local/tmp/Shell%20Folder")
        try require("a folder only the shell knows is offered to the browser",
                    reports.map(\.path) == ["/tmp/Shell Folder"] && panel.sessionDirectory?.path == "/tmp/Shell Folder")
        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file://other-mac.local/tmp/Remote")
        try require("a remote-host report never navigates", reports.count == 1)

        // The browser asking for a folder, and the shell confirming it, is this
        // panel's own round trip: it must not navigate the pane again.
        let requested = URL(fileURLWithPath: "/tmp/Requested", isDirectory: true)
        panel.followDirectory(requested)
        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file:///tmp/Requested")
        try require("the shell confirming this panel's own request cannot loop back",
                    reports.count == 1 && panel.sessionDirectory?.path == "/tmp/Requested")
        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file:///tmp/Requested/")
        try require("a differently spelled report of the same folder is still the same request", reports.count == 1)
        // Every prompt reports, and fish reports twice; only a move is news.
        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file:///tmp/Elsewhere")
        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file:///tmp/Elsewhere")
        try require("a folder reported again at the next prompt does not navigate twice",
                    reports.map(\.path) == ["/tmp/Shell Folder", "/tmp/Elsewhere"])

        panel.view.isHidden = true
        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file:///tmp/While%20Hidden")
        try require("a hidden panel keeps its shell folder but stops steering the browser",
                    reports.count == 2 && panel.sessionDirectory?.path == "/tmp/While Hidden")
        panel.view.isHidden = false
        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file:///tmp/After%20Showing")
        try require("showing the panel again resumes the reverse direction",
                    reports.map(\.path).last == "/tmp/After Showing" && reports.count == 3)

        var value = store.configuration
        value.browserFollowsShell = false
        try store.set(value)
        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file:///tmp/Preference%20Off")
        try require("the reverse direction turned off reports nothing to the browser",
                    reports.count == 3 && panel.sessionDirectory?.path == "/tmp/Preference Off")
        value.browserFollowsShell = true
        value.terminalFollowsBrowser = false
        try store.set(value)
        let ignored = URL(fileURLWithPath: "/tmp/Not Requested", isDirectory: true)
        panel.followDirectory(ignored)
        try require("the forward direction turned off still retargets restart and explains itself",
                    panel.pendingDirectory == ignored && panel.titleLabel.toolTip?.contains("does not follow browsing folders") == true)
        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file:///tmp/Elsewhere")
        try require("the reverse direction still works while the forward one is off",
                    reports.map(\.path).last == "/tmp/Elsewhere")
        await drainMainQueue()
    }

    // MARK: - The window's active pane

    @MainActor
    private static func windowChecks() async throws {
        let manager = FileManager.default
        let root = try SmokeFixtures.temporaryDirectory("terminal-shell-sync-window").resolvingSymlinksInPath()
        let first = root.appendingPathComponent("first target", isDirectory: true)
        let second = root.appendingPathComponent("second target", isDirectory: true)
        let third = root.appendingPathComponent("third target", isDirectory: true)
        let fourth = root.appendingPathComponent("fourth target", isDirectory: true)
        for url in [first, second, third, fourth] { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
        let suite = "Tursora.TerminalShellSyncSmokeWindow." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw SmokeFailure("\(checkPrefix)isolated window defaults") }
        let preferences = AppPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
        let workspace = WorkspaceSessionStore(fileURL: nil)
        let owner = AppDelegate(provider: SmokeFixtures.EmptyProvider(homeURL: root),
                                updater: AppUpdater(driver: nil, unavailableReason: "Terminal shell sync test"),
                                workspaceStore: workspace, preferences: preferences,
                                viewPropertiesStore: DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json")))
        let savedEnabled = AppPreferences.experimentalTerminalEnabled
        let savedTerminalPreferences = AppDefaults.shared.object(forKey: TerminalPreferences.storageKey)
        AppPreferences.experimentalTerminalEnabled = true
        // Panels created by a window use the shared store; start it from the
        // documented defaults and put the user's own value back afterwards.
        TerminalPreferences.shared.reset()
        defer {
            for controller in owner.windowControllers {
                controller.shutdownTerminal()
                controller.close()
            }
            AppPreferences.experimentalTerminalEnabled = savedEnabled
            AppDefaults.shared.set(savedTerminalPreferences, forKey: TerminalPreferences.storageKey)
            defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: root)
        }
        owner.beginWorkspaceSession(showWindows: false)
        guard let controller = owner.windowControllers.first, let window = controller.window else {
            throw SmokeFailure("\(checkPrefix)private workspace creates a window")
        }
        try await requireEventually("private workspace loads", timeout: 15, interval: 30_000_000) { controller.browser.model.generation > 0 }
        controller.toggleTerminal(nil)
        guard let panel = controller.terminalPanel else { throw SmokeFailure("\(checkPrefix)terminal panel opens") }
        window.contentView?.layoutSubtreeIfNeeded()
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 200))
        panel.installTerminal(terminal, in: root)

        controller.browser.setViewMode(.details)
        report(first, to: panel, from: terminal)
        try require("a shell folder moves the active pane in the details view",
                    controller.browser.currentURL?.path == first.path && panel.pendingDirectory.path == first.path)
        controller.browser.setViewMode(.icons)
        report(second, to: panel, from: terminal)
        try require("a shell folder moves the active pane in the icon view",
                    controller.browser.currentURL?.path == second.path)

        controller.tabs.toggleSplit()
        guard let inactive = controller.tabs.currentPage.inactive else { throw SmokeFailure("\(checkPrefix)split creates a second pane") }
        let otherURL = inactive.currentURL
        report(third, to: panel, from: terminal)
        try require("only the active pane of a split follows the shell",
                    controller.browser.currentURL?.path == third.path && inactive.currentURL?.path == otherURL?.path
                    && controller.browser !== inactive)
        controller.tabs.focusOtherPane()
        report(fourth, to: panel, from: terminal)
        try require("switching the active pane switches which pane follows",
                    controller.browser === inactive && inactive.currentURL?.path == fourth.path)

        let newTab = controller.tabs.newTab(at: root)
        report(first, to: panel, from: terminal)
        try require("a new tab's pane follows the shell once it is current",
                    controller.browser === newTab && newTab.currentURL?.path == first.path)

        controller.hideTerminal()
        report(second, to: panel, from: terminal)
        try require("hiding the terminal stops the window from following it",
                    controller.browser.currentURL?.path == first.path && panel.sessionDirectory?.path == second.path)
        await drainMainQueue()
    }

    private static func report(_ url: URL, to panel: TerminalPanelController, from terminal: LocalProcessTerminalView) {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/._-")
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path
        panel.hostCurrentDirectoryUpdate(source: terminal, directory: "file://" + encoded)
    }

    // MARK: - Real sessions

    @MainActor
    private static func zshSession() async throws {
        let fixture = try ShellFixture(label: "zsh", shell: "/bin/zsh")
        defer { fixture.dispose() }
        try fixture.writeStartupFile(".zshrc", "PROMPT='ZSYNC> '\nPROMPT2='MORE> '\nbindkey -e\nbuiltin export TURSORA_STARTUP=zsh\n")
        try fixture.start()
        try await fixture.requireEventually("zsh reaches its own prompt in the launch folder", timeout: 20) {
            fixture.output.contains("ZSYNC>") && fixture.panel.sessionDirectory?.path == fixture.root.path
        }
        try await fixture.requireEventually("zsh acknowledges the launch request", timeout: 20) {
            fixture.panel.directorySyncUpdate?.state == .synchronized
        }

        let manual = try fixture.folder("shell chose this")
        fixture.send("builtin cd -- 'shell chose this'\n")
        try await fixture.requireEventually("a cd typed in zsh reports its folder over OSC 7", timeout: 20) {
            fixture.reports.map(\.path) == [manual.path]
        }
        try require("the OSC 7 report is the shell's real folder", fixture.panel.sessionDirectory?.path == manual.path)

        let browsed = try fixture.folder("browser chose this")
        fixture.panel.followDirectory(browsed)
        try await fixture.requireEventually("zsh follows the browser at an idle prompt", timeout: 20) {
            fixture.panel.directorySyncUpdate?.state == .synchronized && fixture.panel.sessionDirectory?.path == browsed.path
        }
        try require("following the browser does not bounce back into a navigation", fixture.reports.count == 1)

        let hidden = try fixture.folder("hidden cd")
        fixture.panel.view.isHidden = true
        fixture.send("builtin cd -- '../hidden cd'\n")
        try await fixture.requireEventually("a hidden panel still tracks the shell folder", timeout: 20) {
            fixture.panel.sessionDirectory?.path == hidden.path
        }
        try require("a hidden panel does not navigate the browser", fixture.reports.count == 1)
        fixture.panel.view.isHidden = false

        var value = fixture.store.configuration
        value.browserFollowsShell = false
        try fixture.store.set(value)
        let disabled = try fixture.folder("preference off")
        fixture.send("builtin cd -- '../preference off'\n")
        try await fixture.requireEventually("the shell folder still shows with the reverse direction off", timeout: 20) {
            fixture.panel.sessionDirectory?.path == disabled.path
        }
        try require("the reverse direction turned off navigates nothing", fixture.reports.count == 1)
        value.browserFollowsShell = true
        try fixture.store.set(value)

        // What the window does after a reverse navigation: it points the panel
        // at the same folder, which must not produce another report.
        fixture.panel.followDirectory(disabled)
        fixture.send("\n")
        try await fixture.requireEventually("a prompt after the browser caught up reports nothing new", timeout: 20) {
            fixture.panel.directorySyncUpdate?.state == .synchronized
        }
        try require("browser and shell settle without a loop", fixture.reports.count == 1 && fixture.panel.sessionDirectory?.path == disabled.path)
        try require("the user's own startup file still ran", fixture.output.contains("ZSYNC>"))
        await fixture.stop()
    }

    @MainActor
    private static func bashSession() async throws {
        let fixture = try ShellFixture(label: "bash", shell: "/bin/bash")
        defer { fixture.dispose() }
        try fixture.writeStartupFile(".bash_profile", "PS1='BSYNC> '\nexport TURSORA_STARTUP=bash\n")
        try fixture.start()
        try await fixture.requireEventually("bash reaches its own prompt and reports the launch folder", timeout: 20) {
            fixture.output.contains("BSYNC>") && fixture.panel.sessionDirectory?.path == fixture.root.path
        }
        fixture.send("printf '%s' \"$TURSORA_STARTUP\" > \"$HOME/startup\"\n")
        try await fixture.requireEventually("the temporary rcfile reads the user's own bash startup file", timeout: 20) {
            fixture.read("startup") == "bash"
        }

        let browsed = try fixture.folder("browser chose this")
        fixture.panel.followDirectory(browsed)
        try await Task.sleep(nanoseconds: 400_000_000)
        try require("bash leaves an idle shell alone until the next prompt",
                    fixture.panel.sessionDirectory?.path == fixture.root.path && fixture.panel.directorySyncUpdate?.state == .waiting
                    && fixture.panel.titleLabel.toolTip?.contains("next prompt you draw") == true)
        fixture.send("\n")
        try await fixture.requireEventually("bash applies the request when the next prompt is drawn", timeout: 20) {
            fixture.panel.sessionDirectory?.path == browsed.path && fixture.panel.directorySyncUpdate?.state == .synchronized
        }
        try require("applying the browser's request does not navigate back", fixture.reports.isEmpty)

        let manual = try fixture.folder("shell chose this")
        fixture.send("builtin cd -- '../shell chose this'\n")
        try await fixture.requireEventually("a cd typed in bash reports its folder over OSC 7", timeout: 20) {
            fixture.reports.map(\.path) == [manual.path]
        }
        // What the window does after a reverse navigation: it points the panel
        // at the same folder, which must not produce another report.
        fixture.panel.followDirectory(manual)
        fixture.send("\n")
        try await fixture.requireEventually("bash and the browser settle without a loop", timeout: 20) {
            fixture.panel.directorySyncUpdate?.state == .synchronized && fixture.panel.sessionDirectory?.path == manual.path
        }
        try require("a consumed request does not undo the user's own cd", fixture.reports.count == 1)
        await fixture.stop()
    }

    @MainActor
    private static func fishSession() async throws {
        guard TerminalPreferences.isExecutableFile(fishPath) else {
            check("fish session skipped: \(fishPath) is not installed", true)
            return
        }
        let fixture = try ShellFixture(label: "fish", shell: fishPath)
        defer { fixture.dispose() }
        try fixture.writeStartupFile(".config/fish/config.fish",
                                     "set -g fish_greeting ''\nfunction fish_prompt\n    printf 'FSYNC> '\nend\nset -gx TURSORA_STARTUP fish\n")
        try fixture.start()
        try await fixture.requireEventually("fish reaches its own prompt and reports the launch folder", timeout: 25) {
            fixture.output.contains("FSYNC>") && fixture.panel.sessionDirectory?.path == fixture.root.path
        }
        fixture.send("printf '%s' \"$TURSORA_STARTUP\" > \"$HOME/startup\"\n")
        try await fixture.requireEventually("the init command leaves the user's own config.fish in charge", timeout: 20) {
            fixture.read("startup") == "fish"
        }

        let browsed = try fixture.folder("browser chose this")
        fixture.panel.followDirectory(browsed)
        try await Task.sleep(nanoseconds: 400_000_000)
        try require("fish leaves an idle shell alone until the next prompt",
                    fixture.panel.sessionDirectory?.path == fixture.root.path && fixture.panel.directorySyncUpdate?.state == .waiting)
        fixture.send("\n")
        try await fixture.requireEventually("fish applies the request when the next prompt is drawn", timeout: 20) {
            fixture.panel.sessionDirectory?.path == browsed.path && fixture.panel.directorySyncUpdate?.state == .synchronized
        }
        try require("applying the browser's request does not navigate back", fixture.reports.isEmpty)

        let manual = try fixture.folder("shell chose this")
        fixture.send("builtin cd '../shell chose this'\n")
        try await fixture.requireEventually("a cd typed in fish reports its folder over OSC 7", timeout: 20) {
            fixture.reports.map(\.path) == [manual.path]
        }
        fixture.panel.followDirectory(manual)
        fixture.send("\n")
        try await fixture.requireEventually("fish and the browser settle without a loop", timeout: 20) {
            fixture.panel.directorySyncUpdate?.state == .synchronized && fixture.panel.sessionDirectory?.path == manual.path
        }
        try require("a consumed request does not undo the user's own cd", fixture.reports.count == 1)
        await fixture.stop()
    }

    // MARK: - Fixture

    /// One real PTY with an owned HOME. The panel, channel and launch path are
    /// exactly the production ones; only the startup files are this fixture's.
    @MainActor
    private final class ShellFixture {
        let root: URL
        let shell: String
        let panel: TerminalPanelController
        let terminal: LocalProcessTerminalView
        let sync: TerminalDirectorySync
        let store: TerminalPreferences.Store
        let window: NSWindow
        private let suite: String
        private let defaults: UserDefaults
        var reports: [URL] = []

        init(label: String, shell: String) throws {
            self.shell = shell
            root = try SmokeFixtures.temporaryDirectory("terminal-shell-sync-\(label)").resolvingSymlinksInPath()
            suite = "Tursora.TerminalShellSyncSmoke.\(label)." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else { throw SmokeFailure("isolated \(label) defaults") }
            self.defaults = defaults
            store = TerminalPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
            let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "ENV": "/dev/null",
                               "TERM_PROGRAM": "Tursora", "XDG_CONFIG_HOME": root.appendingPathComponent(".config").path]
            guard let sync = try TerminalDirectorySync.make(shell: shell, environment: environment) else {
                throw SmokeFailure("\(shell) has a folder integration")
            }
            self.sync = sync
            panel = TerminalPanelController(initialDirectory: root, preferences: store)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = panel
            window.setContentSize(NSSize(width: 900, height: 260))
            terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 220))
            panel.installTerminal(terminal, in: root)
            panel.onShellDirectoryChanged = { [weak self] url in self?.reports.append(url) }
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func writeStartupFile(_ name: String, _ contents: String) throws {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        func start() throws {
            panel.installDirectorySynchronization(sync, for: terminal)
            let launch = TerminalLaunchConfiguration.make(directory: root, shell: shell,
                                                          shellArguments: sync.shellArguments, environment: sync.environment)
            terminal.startProcess(executable: launch.executable, args: launch.arguments,
                                  environment: launch.environment, currentDirectory: root.path)
            guard terminal.process.running else { throw SmokeFailure("\(shell) starts a real owned PTY") }
        }

        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
            return url
        }
        func send(_ value: String) { terminal.process.send(data: Array(value.utf8)[...]) }
        var output: String { String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func read(_ name: String) -> String? {
            (try? Data(contentsOf: root.appendingPathComponent(name))).flatMap { String(data: $0, encoding: .utf8) }
        }
        func requireEventually(_ name: String, timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
            try await TerminalShellSyncSmokeTests.requireEventually(name, timeout: timeout, interval: 30_000_000,
                                                                    detail: { "shell=\(self.shell) folder=\(String(describing: self.panel.sessionDirectory?.path)) update=\(String(describing: self.panel.directorySyncUpdate)) reports=\(self.reports.map(\.path)) output=\(self.output.suffix(600))" },
                                                                    condition)
        }
        func stop() async { await withCheckedContinuation { continuation in panel.shutdown { continuation.resume() } } }
        func dispose() {
            panel.shutdown()
            window.close()
            sync.invalidate()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

# Dolphin's terminal panel and Tursora's experimental feature

> 0.2.1 supersedes the directory following and terminal-bar layout described earlier in this record: zsh follows the browsing directory one way at a safe prompt, the top is reduced to a single line, and the bottom no longer shows terminal status or free capacity. For the current behaviour and its verification see the [0.2.1 record](terminal-navigation-0.2.1.md); the check counts, screenshots and operation notes in this record belong to their own historical stage, while retention on hide and the confirmation before terminating still hold.

> What follows keeps the first version from 2026-09-12 and its verification record. From 2026-09-13 both features are enabled by default, their switches remain, and the added cancel / retry and the terminal-status polish are in the [follow-up record](default-features-polish.md). The user then asked for collapsing to retain the session, which supersedes the collapse-terminates rule of the first version below; for the current behaviour and the added verification see the [session lifecycle](terminal-session-lifecycle.md).

2026-09-12. Compared against the local `upstream/dolphin/src`; the terminal is implemented with the official [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm/tree/v1.15.0), pinned in SPM at `1.15.0` (`dd2fb8ac5b861e7bf617c872895e338f38165648`).

## Source evidence

- `setupActions()` in `dolphinmainwindow.cpp`: `show_terminal_panel` uses F4 and docks at the bottom; opening a separate external terminal uses ⇧F4.
- `urlChanged()` in `panels/terminal/terminalpanel.cpp`: it follows the browsing directory only when the panel is visible, the sync is enabled and no foreground program is running.
- `sendCdToTerminal()`: it first sends Ctrl-E / Ctrl-U to clear the existing command line, then escapes the path with `KShell::quoteArg` and sends `cd`. The source states explicitly that appending to a command the user has not run yet causes data loss.
- `hasProgramRunning()` decides whether a program is running from Konsole's foreground-process information; that is a semantic interface Konsole provides, and it is not directly equivalent to a plain comparison of `tcgetpgrp()` with the shell PID on macOS.
- [SwiftTerm `MacLocalTerminalView.swift`](https://github.com/migueldeicaza/SwiftTerm/blob/v1.15.0/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift) provides a real PTY and an AppKit terminal view, forwarding key presses, control sequences and the window size.
- [SwiftTerm `LocalProcess.swift`](https://github.com/migueldeicaza/SwiftTerm/blob/v1.15.0/Sources/SwiftTerm/LocalProcess.swift) uses `forkpty`, DispatchIO and a process-exit watcher; `terminate()` cancels that watcher, so on an explicit close Tursora reaps the child process itself.

## Scope and trade-offs of the first version

The experimental terminal in Settings is off by default. An interactive PTY is created only once the user has enabled it and expanded the panel; launching the application, creating a window or hiding the panel never creates a shell in advance.

A new terminal starts in the current folder with the shell configured for the account, falling back to `/bin/zsh`, and keeps the environment of a normal interactive login shell. The directory is passed to a fixed script as its own argv entry; when the directory does not exist or has been unmounted it exits straight away rather than landing in some other working directory.

Normal `pwd`, `cd`, interactive output, Ctrl-C and terminal scrolling all work. Changing directory in the browser only updates the target of "Restart in Current Folder"; it does not inject a `cd` into the PTY automatically: with the shell's `read` builtin, or with input the user has not submitted, an automatic command cannot be received safely even though the process group is still the shell. The button ends the existing session and restarts it in the current directory; when a foreground command is detected, an in-app confirmation is shown first.

Closing the panel, closing the window, disabling the feature or quitting the application ends the owned shell and its foreground process group, closes the PTY and reaps the shell. A background daemon that deliberately detaches from the terminal falls outside this panel's session management. Konsole-style two-way directory sync, session saving and SSH terminals are not supported for now; a mounted remote directory is used as a local path.

SPM's `SwiftTerm_SwiftTerm.bundle` and the MIT licence are packaged with the application. SwiftTerm's CoreGraphics rendering is used by default; the experimental Metal rendering option is not enabled.

## Verification scope

`TerminalSmokeTests` starts no user login shell and creates no terminal UI. It verifies that the path is passed as its own argument and that headless mode starts no panel process, and it actually checks the PTY, `pwd` / `cd`, Ctrl-C and child-process reaping using a temporary HOME and `/bin/sh -f -i` with ENV configuration disabled.

computer-use measurements on the packaged application, 2026-09-12:

- With the terminal opened by F4, zsh renders normally and `pwd` shows the correct directory; a running `sleep 30` can be interrupted with Ctrl-C.
- With an uncommitted `printf terminal-input-kept` left in place, navigating in the browser to the `Sample Files` directory, whose name contains a space, left the input unchanged and injected no `cd` automatically.
- After clicking Restart in Current Folder, `pwd` shows the new directory; clicking Restart again while `sleep 30` is running shows the confirmation, and Cancel works.
- Hiding with F4 and opening it again gives a new session.

These measurements do not cover a real remote connection, nor session reaping after the owning browser window is closed; both still need verification of their own and cannot be substituted by the F4 results.

# Two-way sync between the terminal and the browsed directory, plus bash / fish support

2026-09-13. Two things are added on top of [the one-way following in 0.2.1](terminal-navigation-0.2.1.md): first, reverse sync, so that when the shell changes directory on its own the window's current pane follows it; and second, extending the automatic sync, until now zsh-only, to bash and fish, with all three shells reporting their own directory through OSC 7.

All of 0.2.1's hard limits stay in force: **no characters are typed into the shell, no signals are sent, and the user's startup files are not modified**; the panel neither reads nor writes the filesystem, navigation still goes through `MainWindowController → BrowserViewController.navigate`, and a directory change towards the shell happens only at a safe prompt.

## Evidence and sources

- Finder's resources contain no switch wording of the "directory following" kind. `plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings` has 2,129 entries, of which only `N67 = "Open in Terminal"` relates to the terminal; a `strings` scan of `Base.lproj/*.nib` found no match. **The wording of the two checkboxes, "Terminal follows the browser folder" and "Browser follows the shell folder", is this project's own neutral phrasing, not Finder's**, and is recorded as inferred.
- The Dolphin evidence carries over from [the 0.2.1 record](terminal-navigation-0.2.1.md): `urlChanged()` in `terminalpanel.cpp` requires the panel to be visible. There is no `upstream/dolphin` checkout in this working tree, so **Dolphin's implementation of reverse sync was not re-checked**; the rule "sync only while the panel is visible" carries over the visibility precondition already recorded, while Dolphin's actual code for the reverse direction was not verified in this stage and is recorded as unchecked.
- The receiving side of OSC 7 comes from SwiftTerm 1.15.0: `EscapeSequenceParser.swift:530` hands OSC 7 to `Terminal.oscSetCurrentDirectory`, which passes the raw string to `hostCurrentDirectoryUpdated` when `isProcessTrusted` is true, and `AppleTerminalView` then turns it into `hostCurrentDirectoryUpdate(source:directory:)`. On macOS, `MacTerminalView.isProcessTrusted` is always `true`, and `LocalProcess` delivers on the main queue by default, so the callback arrives on the main thread.
- fish 4.0.2 also emits OSC 7 by itself whenever PWD changes: in a controlled session, a single `cd` produced two completely identical reports (see "an unchanged directory is not news" below). This stage also observed fish sending OSC 133, which SwiftTerm logs as `Unknown OSC code: 133`; it does not affect behaviour.

## Design

### Reverse sync (shell → browser)

When `TerminalPanelController.hostCurrentDirectoryUpdate` receives a local OSC 7, it updates the title hint and also hands the directory to the window through the new `onShellDirectoryChanged`; `MainWindowController.followShellDirectory` calls `browser.navigate(to:)`, that is, the current pane of the current tab. Split panes, multiple tabs and both file views all follow naturally, because this is the same navigation path as everything else. The panel itself performs no filesystem access.

Four gates guard against feedback loops and noise:

1. **An invisible panel does not drive the browser.** This matches Dolphin's visibility precondition; a hidden panel still keeps its shell, its channel and its directory display, it just no longer changes the file view.
2. **A directory equal to the one this panel has just requested is ignored.** `requestedDirectory` records the last browser → shell request.
3. **A directory equal to the browser's current directory is ignored.** `pendingDirectory` always tracks the browsed directory; this is the strongest gate of the four.
4. **An unchanged directory is not news.** `reportedShellDirectory` separately records the directory OSC 7 reported last time. bash reports at every prompt, and fish reports twice because of its own built-in hook; the window is notified only when the directory has really changed. It has to be kept separate from `presentation.reportedDirectory`, because that one is also written by zsh's response file.

Directories are compared with `TerminalPanelPresentation.isSameDirectory`, which compares `standardizedFileURL.path`, so that the two spellings `/tmp` and `/private/tmp` count as the same place.

### The directory-path normalisation trap

`URL.standardizedFileURL` (equivalent to `NSString.standardizingPath`) **strips a leading `/private`** on macOS. Over OSC 7 the shell reports its real `$PWD`, and the old `localDirectory` used `standardizedFileURL`, rewriting `/private/tmp/x` into `/tmp/x`, so the directory the shell said and the directory that was requested no longer matched. It now uses only `URL.standardized` (purely lexical resolution of `.` and `..`), preserving the shell's own spelling; equality across spellings is left to `isSameDirectory`. This is now covered by an automated check.

### The two switches

`TerminalPreferences.Configuration` gains `terminalFollowsBrowser` and `browserFollowsShell`, both defaulting to true, and with `browserFollowsShell` true the existing behaviour of 0.2.1 is unchanged. `Configuration` now decodes field by field with `decodeIfPresent`: JSON saved by 0.2.1 has neither of these keys, and the synthesised decoder would fail the whole decode and reset the user's shell, font and colours along with it. Settings → Terminal gets two checkboxes; turning the forward sync off still updates the Restart target, and the title hint explains why.

### Integrating the three shells

`TerminalShellIntegration` recognises zsh, bash and fish by executable name; `/bin/sh` (which on macOS is really bash) and anything else still gets a plain interactive terminal. Launching still goes through argv: `TerminalLaunchConfiguration` gains `shellArguments`, and the wrapper script becomes `cd -- "$1" || exit 1; tursora_shell="$2"; shift 2; exec "$tursora_shell" "$@"`, so the directory, the shell path and the integration file path are all separate argv entries and never enter executable text.

| shell | How it is loaded | When a request takes effect | How it reports |
| --- | --- | --- | --- |
| zsh | a temporary `ZDOTDIR` (restores the original value before reading the user's `.zshenv`) | a FIFO wakes ZLE, so it takes effect immediately at an empty prompt | a response file plus OSC 7 from precmd |
| bash | a temporary `--rcfile` | the next prompt the user draws | OSC 7 from `PROMPT_COMMAND` |
| fish | `--init-command` | the next prompt the user draws | OSC 7 from `--on-variable PWD` |

- **zsh**: `_ts_<token>_prompt` calls the new `_ts_<token>_osc7` after `_ts_<token>_apply`. Encoding runs byte by byte under `emulate -L zsh -o no_multibyte`, with `printf -v hex '%%%02X' "'$char"` taking the byte value, so a non-ASCII path is percent-encoded as UTF-8 bytes. The ZLE wake-up path does not emit OSC 7, to avoid writing to the terminal from inside a widget.
- **bash**: bash does not read `--rcfile` for a login shell, so the session is now an interactive non-login shell, and the generated rcfile itself reads, in login order, `/etc/profile` and then the first readable of `~/.bash_profile` → `~/.bash_login` → `~/.profile` → `~/.bashrc`. **Another trap: bash parses long options only before the first short option**, so `-i --rcfile x` makes bash report `--: invalid option` and print its usage; the argument order therefore has to be `--rcfile <file> -i`. The encoding function uses `local LC_ALL=C` so that `${#s}` and `${s:i:1}` slice by bytes. `PROMPT_COMMAND` is appended to rather than overwritten, and the hook saves `$?` before it returns, so the exit code shown in the prompt is unaffected.
- **fish**: `--init-command` is evaluated after `config.fish`, so the user's configuration still has the last word. Percent-encoding uses `string escape --style=url` and then turns `%2F` back into `/`, which gives the right result whether or not fish escapes the separator. Requests are consumed in an `--on-event fish_prompt` hook, and the NUL-separated fields are read with `read --null --local`.

All three scripts put only the generated channel directory and the hexadecimal token into executable text; paths are read as data. None of them use `trap`, `kill` or `eval`. A request is recorded as consumed only after it has been applied successfully, so a manual `cd` by the user afterwards is not dragged back at the next prompt.

## Limits and known restrictions

- **Forward sync for bash and fish takes effect only when the user draws the next prompt**; nothing happens while the shell sits idle. Only zsh has the immediate FIFO/ZLE path. That sentence is written into the panel's title hint and into the tooltip of the forward checkbox in Settings.
- bash and fish have no acknowledgement channel: a failed `cd` (into a directory that does not exist, for example) is not reported as `failed` the way zsh does; the request is retried at every subsequent prompt and the interface keeps showing a wait.
- The bash session is no longer a login shell: `shopt login_shell` is off and `$0` is not `-bash`; user configurations that depend on either will see a difference. A user who later overwrites `PROMPT_COMMAND` themselves also removes the hook.
- Output from `_ts_<token>_osc7` inside fish's `fish_prompt` event hook was not observed reaching the terminal on this machine (the `cd` from apply did run), so the case where the browser requests the directory the shell is already in does not rely on it. The panel now records that case as synced directly, and `TerminalDirectorySync` no longer publishes `waiting` for bash and fish (there is no acknowledgement channel, and a late `waiting` would overwrite an OSC 7 result that had just arrived). **Why the fish event hook's output does not arrive was not investigated further** and is recorded as unexplained.
- bash's rcfile path and fish's entire init-command (including the channel directory and the token) are in argv, visible through `ps` to other users on the same machine. The channel directory itself is still 0700 and its files 0600; the token is used only to validate the format of zsh's responses, and fish uses no response file.
- fish is verified only when `/opt/homebrew/bin/fish` exists; when it is missing, the corresponding checks print a single `ok … skipped` line. Other install locations (MacPorts, `/usr/local`) are not verified.
- bash's byte encoding uses `local LC_ALL=C` and has been verified in this stage only with ASCII paths plus spaces; zsh's byte-encoding path is already covered by the existing `雪` and newline directories.
- Reverse sync changes only the current pane of the current tab, not the other half of a split and not other windows. A directory the shell moved to while the panel was hidden is not reported retroactively when the panel is shown again; that waits for the shell's next directory change.
- Multiple terminal sessions in one window are still not implemented, and are explicitly out of scope this time.

## Verification

`cd app && swift build` is clean, with no new warnings. The full smoke run passed on the first attempt once the implementation was complete: `exit=0 ok=3509 fail=0`, taking 176 seconds (the baseline at e202c2e was 3,432 checks). The 77 new checks cover:

- Pure functions: recognising the three shells and not recognising `/bin/sh`; argv assembly and bash's long-option ordering; content constraints on all three scripts (reading the user's startup files, preserving `PROMPT_COMMAND`, reading requests NUL-separated, containing no `eval`, `kill` or `trap`); and preserving the `/private` spelling while resolving `..`.
- Preferences: both directions on by default; migrating older JSON keeps the shell and the appearance; the two settings pages stay in sync with each other; storage round-trips; Restore Defaults; and the layout fitting inside a 540-point page.
- The panel (with no process): only a directory the shell knows is handed to the browser; a report from a remote host is ignored; the panel's own request coming back does not form a loop; a different spelling of the same directory does not count as a move; a report repeated at every prompt does not navigate repeatedly; nothing is driven while hidden; behaviour resumes once the panel is shown again; with reverse sync off nothing is reported; and with forward sync off the Restart target still changes and the reason is explained.
- The window: the current pane follows in both the details view and the icon view; in a split only the active pane follows; switching the active pane moves what follows along with it; a new tab follows once it becomes current; and the window stops following once the terminal is hidden.
- A real PTY: in zsh, a hand-typed `cd` reaches the panel as a directory over OSC 7, a browser request takes effect at an idle prompt without bouncing back, a hidden panel only updates the directory without navigating, nothing navigates once the reverse switch is off, and a prompt drawn after the browser has caught up produces no new report; in bash, a request does nothing while the shell is idle and is applied only at the next prompt, the temporary rcfile did read the user's `.bash_profile`, a hand-typed `cd` is reported over OSC 7, and a consumed request does not undo the user's `cd`; fish gets the same set of checks, skipped when it is missing.

Every problem fixed while diagnosing appears above under "Limits and known restrictions" and "Design": bash's long-option ordering, the fish event hook's output, `/private` normalisation, and deduplicating repeated reports. The `/private` fix also repaired the mismatch that appeared in the existing `TerminalDirectorySyncSmokeTests` once OSC 7 was added, and that suite's failure details now also include the actual directory and the expected directory.

**This stage has automated verification only.** There is no release package, no hands-on GUI or computer-use observation, no screenshot update, and no trial under a real user's shell configuration; none of these may be treated as done.

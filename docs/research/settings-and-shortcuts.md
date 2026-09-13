# Settings window, extension display and shortcuts

> What follows keeps the first version and the verification record from 2026-09-12; since 2026-09-13 both features are enabled by default, the switches remain, and the added cancel / retry and terminal status polish are described in the [follow-up record](default-features-polish.md).

2026-09-12. The new settings entry point comes from an explicit user request; these are Tursora's application-level settings, independent of each pane's grouping, hidden files and filter state.

## Data and defaults

| Setting | Default | Storage/API |
|---|---|---|
| File name extension display | on | `AppPreferences.showFileExtensions` |
| Filter by Name shortcut | ⌘F | `AppPreferences.filterShortcut` |
| Experimental terminal panel | off | `AppPreferences.experimentalTerminalEnabled` |
| Experimental ZIP browsing | off | `AppPreferences.experimentalZIPBrowsingEnabled` |

`AppPreferences.Store` uses UserDefaults and posts `.tursoraPreferencesChanged` after a real change. A checkbox in the settings window saves immediately; consumers receive the notification and update their interface. The extension switch only affects display: it does not modify file names or the filesystem's hidden-extension flag. Turning the terminal switch on only opens the entry point, it does not start a shell. With the ZIP switch on, a plain Open browses the archive in the current pane; with it off, a ZIP newly opened in an ordinary directory goes back to extraction, while archive pages and history already prepared remain navigable and completable read-only, without jumping away suddenly or clearing the copy. The setting's description says current pane explicitly; for the full behaviour see the [archive browsing research](archive-browsing.md).

## Shortcut recording

- The existing meaning of name filtering is kept, so the setting is called `Filter by Name`, which does not suggest a full-text indexed search.
- The button captures key-down once it enters recording; it intercepts ahead of menu dispatch, so recording ⌘Q reports a conflict instead of quitting the app. Escape, closing the settings window or the window losing focus ends recording.
- A single letter, digit or supported punctuation mark is allowed; Command or Control is required, and Option/Shift may be added. Option alone is used to type accented characters and therefore cannot be taken over; Tab, space, Return, the arrow keys and the function keys are not offered as bindings for this setting.
- The unmodified character is obtained through NSEvent according to the current keyboard layout, and the modifiers are stored separately; the display uses the order ⌃⌥⇧⌘.
- The existing menu and window monitor shortcuts are statically reserved, including number tab switching, ⌘K, ⌘comma, ⌃⌘S and others; saving also checks the real main menu, ignoring the Filter entry itself.
- Common system reservations include window switching, Help, lock screen and so on; there is no claim of detecting every global shortcut a user has customised in System Settings or in third-party tools. F4 is outside the range of allowed characters and is left to the experimental terminal.
- Invalid input is reported inside the settings window and does not overwrite the saved value. Reset restores ⌘F; a binding on disk that is invalid or already in conflict falls back to the default when read.

## Scope of the Finder comparison

Verification commands:

```bash
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/PreferencesWindow.nib
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
```

Finder's `MenuBar.nib` on this machine still keeps `Preferences` / `cmdPreferences:` / `gear`, while the window title in `PreferencesWindow.nib` is `Finder Settings`, with `General`, `Advanced` and `Show all filename extensions`. Tursora adopts the wording of that extension switch; the specific layout of General / Keyboard / Experimental is our own design and is not claimed to reproduce Finder's settings window. This feature introduces no Tags.

## Verification limits

`SettingsSmokeTests.run()` uses a separate temporary UserDefaults domain and NotificationCenter, and covers defaults, persistence, notifications, conflicting/invalid bindings, resetting, the settings controls writing and refreshing, recording events and Escape, and the layout inside the window. It does not open the settings window, nor trigger external programs, the terminal or real ZIP browsing. The main flow's `SmokeTest.preferencesIntegration` additionally covers the real menu bindings, the experimental switch entry points, extension display in both file views and renaming with the real name; the complete shortcut catalogue and the integration verification that followed are covered by the [shortcut research](custom-shortcuts.md) and the [customisation integration record](customization-integration.md) respectively.

Real operation of same-pane ZIP and of the settings, the sample screenshots and the preference restoration record are in the [real-machine record](computer-use-2026-09-12-inline-zip.md). The defaults are defined by the data table in this document, and are not inferred from demo screenshots or from one user's current preferences.

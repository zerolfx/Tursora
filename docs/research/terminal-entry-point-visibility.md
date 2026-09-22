# The terminal entry point is absent, not dimmed

2026-09-19. The owner reported a permanently grey Terminal button in the shipped 0.4.3 build and asked that the button not be shown at all when the feature is off, and that the Terminal settings then accept no changes. This record holds the diagnosis of the grey button, the AppKit facts the change turned up, and this round's verification. The decision itself is D87; the user-facing wording is in SPEC §16 and §17.

## Why the button was grey

- `experimentalTerminalEnabled` was explicitly stored `false` in the packaged app's domain `com.tursora.Tursora`. The getter in `AppPreferences.Store` returns **true when the key is absent**, so a grey button always means an explicitly written `false`, never a missing key or a shipped default. The only period where `false` was the default was 0.1.0.
- The only writer in production code is the Settings checkbox (`SettingsWindowController.toggleTerminal`), and `Store.set` records an explicit choice even when it matches today's default (D49). The domain's contents fit that: a single changed key beside untouched `favouritesOrder`, `savedSearches.v1`, `lastGroupKey` and the Sparkle keys.
- The competing explanation — a smoke run leaking its own setup into the real domain — was **excluded for this domain by fingerprint**. `SmokeTest.run` deletes every `InfoSection.*` key at startup and writes `restoreWorkspaceOnLaunch` and an empty `keyboardShortcutOverrides.v1`; `com.tursora.Tursora` shows the exact inverse (all six `InfoSection.*` keys present, the other two absent). The leak itself is real and was observed frozen in the *other* domain, `~/Library/Preferences/Tursora.plist`, which the unbundled SPM binary uses; that is a separate defect, recorded in [ROADMAP](../ROADMAP.md).
- The preference was switched back on by hand while this was being traced: the running process grew a `/bin/zsh -il` child at 09:18:37, and the app's only shell-spawning path is guarded by the same preference.

## What the change had to work around

- **`validateToolbarItem`'s terminal case was dead code.** `toggleItem` sets `item.autovalidates = false`, so `validateVisibleItems()` skips the terminal item entirely and `case ToolbarID.terminal` never ran. Only the imperative assignments in `syncTerminalToolbar` could grey the button. The dead case is removed.
- **`insertItem` only accepts an identifier the delegate allows.** So `toolbarAllowedItemIdentifiers` keeps naming the terminal even while it is absent, and `toolbarDefaultItemIdentifiers` — which is what a window opened while the panel is off builds from — filters it out. The two were previously the same list.
- **The item factory cannot drive presence.** `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` runs *inside* `insertItem`, where the item is not yet in `toolbar.items`; calling the presence sync from there inserts a second time and recurses. `syncTerminalToolbar` is therefore split, and the factory calls only the appearance half.
- **Toolbars that share an identifier share their item configuration.** Every window builds `NSToolbar(identifier: "TursoraMainToolbar")`, and one window's `removeItem` takes the item out of the other window's `items` as well, without that window's own code running. The first attempt cached `terminalButton = nil` in the branch that performed the removal, and a smoke check caught the second window still holding a detached button. The cached item and button are now read back from `toolbar.items` at the end of every presence sync, so they describe what is actually in the toolbar whoever removed it.
- The View menu already hid its command on this preference (`MainMenu.applyPreferences`), so the toolbar was the odd one out; both now change together, through the same `.tursoraPreferencesChanged` notification.

## Settings

Settings ▸ Terminal keeps showing the saved shell, folder-sync, font and colour values and disables every control, with a line naming the option that hands them back. Enabled state now has one owner, `applyAvailability`, which applies each control's own rule — a custom shell, a custom colour scheme — and then the panel switch above it. The shell-path rule reads the popup rather than the saved configuration, so a path typed but not yet applied survives the pane being switched off and on. The master checkbox stays in General, where it is the only route back.

## Verification

Automated: the suite grew 19 checks — the withdrawal from every open window and from `toolbarDefaultItemIdentifiers`, the released button reference, the menu command moving with it, the retained panel surviving, the withdrawn action being unable to reveal it, the return to the slot after Split View with the kept session, the overflow still working at the 560 pt minimum, the Terminal page going inert and coming back with each control's own rule, a click and a forced action on the inert page changing nothing, and the Settings window driving the page from the General checkbox. 4,395 checks over the new sources passed three times in a row, each exit 0.

Not done in this round: **no computer-use pass**. A throwaway bundle was packaged under `TURSORA_BUNDLE_ID=com.tursora.TursoraVerify`, so that its own defaults domain could not reach the installed app, but screen access was declined, and the bundle and its domain were removed again. Nothing in this record is a claim about how the change looks on screen; the withdrawal, the slot it returns to and the inert settings page are asserted only by the checks above.

# Dock context menu (2026-09-12)

The user asked for Tursora's Dock icon to offer common actions the way Finder's does. This round adds the application's own custom menu: `New Window`, a separator, `Downloads`, `Applications`. Every action opens a new Tursora window and never reuses or navigates an existing pane; New Window keeps the application's Home as its starting point. The entries for common directories are Tursora's own choice, and no claim is made that they reproduce the actual items or the order of Finder's Dock menu.

## Finder wording evidence from this machine

A read-only check against this machine's Finder resources:

```sh
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
```

| Resource on this machine | What was extracted | How far it is used this round |
|---|---|---|
| `LocalizableMerged.strings` | `N80 = New Finder Window`, `FR12 = New Window` | Tursora keeps the `New Window` of its own File menu and does not use Finder's application name |
| `MenuBar.nib` | `Downloads` and `cmdGoToDownloads:` near `300850.title` | The English label of a common directory |
| `MenuBar.nib` | `Applications` and `cmdGoToApplications:` near `258.title` | The English label of a common directory |
| `MenuBar.nib` / `LocalizableMerged.strings` | `Home`, `cmdGoHome:`; `FF21 = Home` | Cross-checks the Home semantics of the existing New Window; no duplicate Home item is added |

These resources can confirm the wording and the command names, but they cannot prove that the items appear in Finder's Dock menu, and nothing about the hierarchy or order of the current Finder Dock menu can be derived from them. This round does not pass resource strings off as observations of actual clicks in Finder's Dock.

## AppKit basis and implementation choices

[Apple's `applicationDockMenu(_:)` documentation](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationdockmenu%28_%3A%29) lets the application delegate return a dynamic `NSMenu`, with no need to add a nib to this project. The documentation says the Dock dispatches actions to the application through each menu item's target / action, and that the sender may be nil. Each item therefore uses a distinct selector and an explicit `AppDelegate` target, and never derives its destination from `sender`, the menu index or `representedObject`; another window taking focus does not change an action's target either.

[Apple's Dock menus guidance](https://developer.apple.com/design/human-interface-guidelines/dock-menus) recommends offering short, frequently used actions that remain useful when the application is not in front or has no windows, and keeping a matching entry point elsewhere in the interface. Tursora's New Window already exists in the File menu, and both directories can also be opened from the address bar. Only these three custom actions are returned here; the standard Dock items are managed by macOS, and no separate window list, recent directories, tags or Trash feature is built.

- `DockMenuDirectories.system` resolves Downloads (user domain) and Applications (local domain) in the model layer through `FileManager`'s standard directory API, while Home uses the existing `FileProvider.homeURL`. No user directory is hard-coded and no missing directory is created; when the system returns no destination the corresponding item is disabled, and dispatching that action directly does nothing either.
- `DockMenu.make` only builds the menu, with no filesystem reads or writes; `AppDelegate.applicationDockMenu` returns the menu. The fixed actions call the existing `newWindow(at:)`, keeping window registration, close cleanup and cascading behaviour, and then activate the application.
- Every action creates its own window and initial pane, and changes no existing split, active tab, path, filter, grouping, selection, search request or undo stack. No new file operation is added.
- The application keeps its existing Dock reopen and drag-in path handling; this round only adds the context menu.

## Verification status

`DockMenuSmokeTests.swift` is wired into the full smoke chain and uses a temporary directory with an injected provider / standard directory configuration, covering the destinations, an unavailable directory, menu order / separator / explicit actions, and dispatch with a nil sender when there is no window. The real window path checks also cover an existing split, background tabs, filtering, grouping and the selection being preserved under both file views, and the test closes only the windows it created itself.

The full smoke test on the final source (including the Dock work and the IME fix that followed) **passed three rounds in a row, 2,123 checks each**, all exiting 0 with empty stderr. The count has been rechecked against the `ok` lines of the three final logs, correcting the undercount of 16 in the original record; the source itself did not change. The `0.1.0` release bundle build, strict codesign, the plist, the arm64 architecture and the consistency of the ICNS inside the bundle all pass; the windows and directory navigation of a separate copy have been inspected visually.

**On-machine limits:** the interface tooling could not read the system Dock by any of the three routes — by bundle ID, by the Dock.app path, or by focusing the Dock first — so there is no real right-click on the Dock and no observation of the application being activated from the Dock. The menu contents, nil-sender dispatch, the new window's directory and the preservation of existing pane state are covered by the automation above, and that cannot be rewritten as a passing on-machine Dock verification. The earlier three rounds of 2,024 checks and the interface screenshots belong to the stage before the Dock work was added.

# Development

Tursora is a Swift Package with one executable target, built with the Command Line Tools only. There is no Xcode project, no nib, no asset catalog: every view, menu and toolbar is built in code.

## Requirements

| | |
|---|---|
| Toolchain | Xcode Command Line Tools with Swift 6.2+ and the macOS 26 SDK (`xcode-select --install`); tested with Swift 6.2.4 / SDK 26.2; full Xcode is not needed |
| Deployment target | macOS 14 (`Package.swift`); developed and tested on macOS 26 |
| Language mode | Swift 5 (`swift-tools-version:5.9`) — see [DECISIONS.md](DECISIONS.md) D7 |
| Frameworks | AppKit, Quartz (Quick Look UI), QuickLookThumbnailing, CoreServices (FSEvents, Spotlight MDItem), NetFS |
| Swift package dependency | SwiftTerm 1.15.0 (exact pin); fetched by SPM on the first build |

## Build, run, package

```bash
cd app && swift build                      # debug binary → app/.build/debug/Tursora
```

```bash
cd app && .build/debug/Tursora             # run it (no bundle: plain process, own UserDefaults domain)
```

```bash
cd app && tools/make-app.sh                # release build → app/build/Tursora.app (ad-hoc signed)
```

`app/Resources/AppIcon.png` is the 1024px RGBA icon master; `AppIcon.icns` is the checked-in macOS icon family. Run `app/tools/make-icon.sh` from the repository root after changing the master (uses system `sips` and `iconutil`). The smoke test checks PNG dimensions/alpha and the ICNS representations.

`make-app.sh [debug|release]` assembles the bundle: `Info.plist` (bundle id `com.tursora.Tursora`, TCC usage strings, version from `git rev-list --count`), the executable, `AppIcon.icns` registered through `CFBundleIconFile`, and an ad-hoc `codesign`. Override with `TURSORA_BUNDLE_ID`, `TURSORA_VERSION`, `TURSORA_BUILD`.

To try a change in the packaged app, rebuild and relaunch:

```bash
cd app && tools/make-app.sh && pkill -f "Tursora.app/Contents/MacOS/Tursora"; open "build/Tursora.app"
```

The debug binary and the packaged app have **different UserDefaults domains** (the bare process has no bundle id), so favourites, view preferences and Info-section state do not carry over between them.

The packaging script also includes `SwiftTerm_SwiftTerm.bundle` and `SwiftTerm-LICENSE.txt`. Keep the resource bundle in `Contents/Resources`; building only the executable is not a complete distributable. Experimental terminal support is compiled in but remains disabled until enabled in Settings and opened with F4.

## The smoke test

Automated verification uses an in-app self check ([DECISIONS.md](DECISIONS.md) D8). When screen access is available, also inspect the packaged app; visual checks supplement the smoke test. It drives the real window, model, tabs, address bar, file operations and Info windows, prints one line per check and exits non-zero on the first failure.

```bash
cd app && swift build && TURSORA_SMOKE_TEST=1 .build/debug/Tursora
```

Run it **three times** before committing; a few checks depend on timing (FSEvents, deferred rebuilds). Clean up leftovers if a run was interrupted:

```bash
find "$TMPDIR" -maxdepth 1 -name "tursora-*" -exec rm -rf {} +
```

How it is written (`SmokeTest.swift`):

- `SmokeTest.run(wc)` resets preferences (view mode, group key), then polls the initial model generation without blocking the main run loop (15-second deadline). It waits for a completed listing, including empty results, rather than assuming a cold home directory loads within one second. A delayed empty provider reproduces the old timing assumption; Info-section layout and new panes created with each saved view mode are also checked before navigation. Later sections are `private static func` s that chain into the next one, usually inside `after(seconds) { … }` closures so the run loop can deliver async work (directory loads, FSEvents, Quick Look).
- `check(name, condition, detail)` prints `ok`/`FAIL`; the detail autoclosure is only evaluated for the log, so put the interesting value there.
- Sections that need files create them under `$TMPDIR/tursora-smoke-<pid>` and remove them at the end.
- Nothing may show a modal: every error path checks `SmokeTest.isRequested` and prints (`report(_:context:)` in `BrowserViewController`, `report(_:)` in `InfoWindowController`, `FileOperations.report`). A modal in a headless run hangs the process and hides the message.
- The app is not active in a headless run: there is **no key or main window**. Code that needs one (`editColumn`, the Inspector's "follow the main window") has fallbacks; tests activate the window where required.
- Every feature adds a section or extends one. Test the model helpers as pure functions first (`FileOperations.uniqueURL`, `Grouping.bucket`, `FileInfo.mode`), then the UI path.

Section order today: navigation → insideFolder → backHome → tabs → addressBarEditing → narrowAddressBar → contextMenus → fileOperations → copyPaste → duplicateAndTrash → expansion → splitView → tabDragSplit → viewModes → liveRefresh → crossTabDrag → filterAndConflicts → scrollClamp → groups → conflicts → getInfo → infoWindow → infoWindowFollows → favouritesAndHistory.

`TURSORA_DND_DEBUG=1` prints drag-and-drop decisions.

## Conventions

- **Finder evidence rule.** Anything that claims to match Finder — a label, a group name, a menu icon, a dialog's wording — is taken from Finder's own resources (`strings` on its nibs, `plutil` on its `.strings` tables), not from memory. Record the extraction under [research/](research/) and mark what is still inferred. See D12.
- **Dolphin semantics, Finder shape.** Where the two disagree, the interaction semantics follow Dolphin (address bar, tabs, split, zoom ladders, filter matching) and the visual form follows Finder (toolbar search field, conflict dialog, groups, Get Info). Say which in the spec.
- **Views never touch the filesystem.** `FileOperations` does the work; `BrowserViewController` owns undo and refresh; the two file views only render `DirectoryModel` and report intent through the `FileViewing` callbacks.
- **One undo group per operation** (`asUndoGroup`), registered on the window's undo manager, and every operation posts `DirectoryChanges.post` so other panes and Info windows refresh without waiting for FSEvents.
- **Comments say why.** The code carries short comments where AppKit behaviour is surprising (see the pitfalls below); the spec carries the intended behaviour.
- **Commits**: `feat(tursora): …`, `fix(tursora): …`, `docs: …`; the body says what changed and why, and ends with the smoke-test count.
- Docs: specs and decisions in Chinese (product-facing), code-facing docs in English.

## AppKit pitfalls met so far

Each of these cost a debugging round; the fix is in the code with a comment.

| Symptom | Cause | Fix |
|---|---|---|
| Read-after-write of a file flag returns the old value | `URL.resourceValues` is cached for the rest of the run-loop pass | Read through `FileManager.attributesOfItem` (`FileInfo`) |
| FSEvents never matches the watched folder | Events carry real paths (`/private/var/…`) while the app holds `/var/…` | Resolve symlinks on both sides before comparing |
| Second pane never appears / split treated as collapsed | `NSSplitView` treats a zero-size subview as collapsed | Give the pane a real initial frame; the delegate refuses collapse; relayout on close |
| Crash on `reloadData` after a folder listing changed | Outline view queried stale rows | Refresh children before `reloadData`; track expansion via `itemDidExpand/Collapse` notifications |
| Details-view zoom ignored | `rowSizeStyle = .default` ignores `rowHeight` | `rowSizeStyle = .custom`; `loadView` must not overwrite the height |
| Completion popup rows cut off | `.inset` table style adds padding, unflipped clip view | `.plain` style, `rowSizeStyle = .custom`, flipped clip view, scroll to top |
| Undo merges several operations into one | `NSUndoManager` had an open automatic event group | `asUndoGroup` closes stale groups, then opens one per operation |
| Rename starts after a drag ends | Mouse-up after a drag session is indistinguishable by timing; `pressedMouseButtons` is unreliable with a mouse | Pointer travel > 3 pt cancels; drag session begin/end cancels |
| Group rows selectable by keyboard/rubber band | Programmatic `selectRowIndexes` bypasses `shouldSelectItem` | Also implement `selectionIndexesForProposedSelection` |
| Blank space above the rows after navigating | A negative bounce offset was restored via unconstrained `scroll(to:)` | Clamp `scrollOffset` to `[0, max]` |
| First tab showed an empty folder | The tab's view was attached hidden and never shown | `applyVisibility()` after inserting; the smoke test checks frame sizes |
| Search field never folds back | `beginSearchInteraction` called when already expanded; focus loss cancelled the filter | Only call it when collapsed; `endSearchInteraction` on empty blur; only an emptied field cancels |
| Inspector renamed the wrong file | A field ending editing after `urls` had changed committed to the new item | Fields remember the URL they were built for (`nameFieldURL`, `commentsURL`, …) |
| Info window rebuilt on every cache write under `~` | FSEvents streams the whole subtree of the watched parent | Filter events to the items and their siblings |
| Section chevrons missing, remembered state ignored | Property observers do not run when a class sets its own property in `init` | Call `applyExpansion()` explicitly from `init` |
| Name field focused as soon as an Info window opens | `NSWindow` picks the first key view as initial first responder | `makeFirstResponder(nil)` after ordering front |
| Alternates (⌥⌘I / ⌃⌘I) not shown | `isAlternate` items must be adjacent and share the key equivalent | Keep the triple together in `MainMenu` |
| Case-only rename fails on APFS | `moveItem` refuses `a` → `A` on a case-insensitive volume | Rename through `URLResourceValues.name` |
| Headless run hangs | A modal alert with no screen | `report(...)` prints in smoke mode |
| Info sections crowd the right edge; inline preview is too narrow | Stack alignment was used as a width/fill constraint | Use leading alignment and explicit leading/trailing anchors for every outer row and section header/content; test actual frames and resizing |
| A new pane claims Icons but shows a list | The saved mode was read, but `fileView` still held the list; calling `setViewMode` with the same mode returned early | Choose the initial `fileView` from the saved mode before `loadView` mounts it |
| Toolbar still selects List after the Icons shortcut | Pane view changes did not notify the window | Notify `BrowserHost` after mounting the view; only the active pane updates toolbar validation |

## Release checklist

1. `swift build` clean, smoke test green three times.
2. `tools/make-app.sh`, launch `build/Tursora.app`, click through what the smoke test cannot see (popups, overlays, Info window layout, menu icons).
3. Update [../CHANGELOG.md](../CHANGELOG.md), the spec if behaviour changed, and the gap lists if something moved to ✅.
4. Commit with the smoke-test count in the message.

## GitHub Actions

`.github/workflows/build.yml` builds a release application on `macos-26` (Apple Silicon) for main pushes, pull requests, or manual runs. It verifies the ad-hoc signature, plist, and icon, then archives the bundle with `ditto` so executable permissions survive. Each artifact includes a ZIP and SHA-256 checksum, retained for 14 days.

`.github/workflows/release.yml` has only `workflow_dispatch`. Run it on `main` with a version such as `0.1.0` or `0.2.0-beta.1` and the prerelease switch when appropriate. It rejects existing tags and unsafe/invalid version strings, packages the exact dispatch SHA, then creates the version tag and GitHub Release with generated notes. The bundle's short version uses the numeric portion; the filename and release retain the prerelease suffix. No automatic release is triggered by a push or tag.

The workflows validate packaging; run the AppKit smoke suite three times in a desktop session before committing. Hosted workflow execution is only verified once these files are pushed and a run completes. Current releases are ad-hoc signed, not Developer ID signed or notarized.

### Reusing icon layouts and measuring scroll content

On macOS 26, an offscreen `NSCollectionViewFlowLayout` can retain old ungrouped section attributes after both `reloadData()` and `invalidateLayout()`. Recreate the layout when the grouped flag or section item counts change. Smoke coverage checks actual supplementary headers and cross-section item frames after switching panes and view modes.

Info sections fill the scroll view's clip viewport, not its outer frame. A legacy vertical scroller consumes horizontal space when the document exceeds the screen-height cap; layout assertions must compare against `scrollView.contentView.bounds.width`.

Selection preservation and rename hints use full standardized URLs. Basenames alone can select an unrelated root file after extracting or refreshing an expanded folder containing the same name.

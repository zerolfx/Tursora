# Development

Tursora is a Swift Package with one executable target, built with the Command Line Tools only. There is no Xcode project or application nib/asset catalog: Tursora's views, menus and toolbars are built in code. Sparkle embeds its own updater UI and helper resources.

## Requirements

| | |
|---|---|
| Toolchain | Xcode Command Line Tools with Swift 6.2+ and the macOS 26 SDK (`xcode-select --install`); tested with Swift 6.2.4 / SDK 26.2; full Xcode is not needed |
| Deployment target | macOS 14 (`Package.swift`); developed and tested on macOS 26 |
| Language mode | Swift 5 (`swift-tools-version:5.9`) — see [DECISIONS.md](DECISIONS.md) D7 |
| Frameworks | AppKit, Quartz (Quick Look UI), QuickLookThumbnailing, CoreServices (FSEvents, Spotlight MDItem), NetFS |
| Swift package dependencies | SwiftTerm 1.15.0 and Sparkle 2.9.6 (exact pins); fetched by SPM on the first build |
| DMG packaging | Python 3.10+; workflows use 3.13. Hash-pinned dmgbuild 1.6.7, ds-store 1.3.3 and mac-alias 2.2.3 are installed into `app/.build/dmg-tools` |

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

`app/Resources/AppIcon-artwork.png` is the retained square artwork. Run `app/tools/make-icon.sh` from the repository root after changing it or the export geometry. The script first runs `render-icon.swift` with CoreGraphics to generate the 1024 px `AppIcon.png`: a single rounded tile at `(80, 80)`, sized `864 × 864`, with a `192` px corner radius and transparent exterior. The artwork keeps its original canvas-relative scale and position; the exporter adds no shadow or stroke. These dimensions are Tursora's chosen geometry, not a claim to reproduce Apple's exact mask.

The script then uses system `sips` and `iconutil` to regenerate the checked-in `AppIcon.icns` family. Both deliverable files must retain their alpha silhouette; do not restore opaque corners based on an assumption that the system will mask a manually packaged ICNS. `IconAssetsSmokeTests` decodes and normalizes pixels before checking transparent outer edges and corner regions, an opaque inset interior, an antialiased boundary, and transparent corners plus an opaque center in every decoded ICNS representation. The family must cover 16–1024 px. Inspect the packaged icon as well; pixel checks do not establish how every system surface or icon cache displays it. See [the icon evidence and current verification](research/app-icon-edges.md).

`make-app.sh [debug|release]` runs `make-icon.sh` before building Swift, so each package regenerates the PNG and ICNS from the retained artwork. It assembles the bundle: `Info.plist` (bundle id `com.tursora.Tursora`, TCC usage strings and updater configuration), the executable, `AppIcon.icns` registered through `CFBundleIconFile`, and an ad-hoc `codesign`. `CFBundleShortVersionString` defaults to `0.1.0`; `CFBundleVersion` defaults to the source commit's Unix committer timestamp (`git show -s --format=%ct HEAD`). `TURSORA_VERSION`, `TURSORA_BUILD` and `TURSORA_BUNDLE_ID` can override metadata for controlled local checks; the packaging validator receives that chosen identifier. Release validation independently requires `com.tursora.Tursora`. Changing public application identity is a separate migration, not a release setting.

To try a change in the packaged app, rebuild and relaunch:

```bash
cd app && tools/make-app.sh && pkill -f "Tursora.app/Contents/MacOS/Tursora"; open "build/Tursora.app"
```

The debug binary and the packaged app have **different UserDefaults domains** (the bare process has no bundle id), so favourites, saved searches, legacy view defaults, startup preferences and Info-section state do not carry over between them. The directory-view library and workspace session are application-owned files in Application Support, shared by ordinary debug and packaged runs. Smoke mode isolates their shared stores and uses injected temporary files for persistence checks.

The packaging script also includes `SwiftTerm_SwiftTerm.bundle` and `SwiftTerm-LICENSE.txt`. Keep the resource bundle in `Contents/Resources`; building only the executable is not a complete distributable. Terminal access is enabled by default; no shell starts until the user opens the panel with F4. Existing explicit opt-outs remain respected.

Sparkle's complete framework is copied with `ditto` to `Contents/Frameworks`, preserving helper signatures, XPC services, symlinks and executable modes. `Sparkle-LICENSE.txt` is included in Resources. Packaging removes SwiftPM's development-directory runtime search paths so the app must use its embedded framework. Only the outer app is ad-hoc signed; do not use `codesign --deep --sign` to replace Sparkle's nested signatures or entitlements. `update-metadata.py verify-bundle` validates the pinned public key, feed, defaults, runtime paths, framework layout and helpers; strict codesign verification remains a separate check. The bare SPM executable disables its updater and Settings explains that a packaged app is required.

For a distributable installer, run `tools/make-dmg.sh` after packaging. Set `TURSORA_PYTHON` if the default Python is older than 3.10. The script writes `app/dist/Tursora-<version>-macOS-arm64.dmg` using the pinned tools above, then mounts it read-only and validates the app, signature, metadata, Applications symlink, background license and saved Finder layout. `dmg-settings.py` defines a 640 × 280 two-icon window with an arrow; `verify-dmg-layout.py` reads its `.DS_Store` directly, so CI does not need Finder automation. See [RELEASING.md](RELEASING.md) for the exact layout and publication checks.

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

The chain begins with the initial-listing wait, isolated directory-view checks, icon/server/settings checks, transfer and archive/ZIP/split-toolbar/terminal suites, search and integrated-search suites, pane-path and tab-action suites, then delayed-listing, saved-view and preferences integration checks. The original navigation chain follows: navigation → insideFolder → backHome → tabs → addressBarEditing → narrowAddressBar → contextMenus → fileOperations → copyPaste → duplicateAndTrash → expansion → splitView → tabDragSplit → viewModes → liveRefresh → crossTabDrag → filterAndConflicts → scrollClamp → groups → conflicts → getInfo → infoWindow → infoWindowFollows → favouritesAndHistory.

`UpdateSmokeTests` runs alongside settings checks, using a fake driver and isolated defaults to exercise update policy, startup/retry, persistence, both Settings pages, cross-window refresh and actual menu/button dispatch. The shared updater never constructs Sparkle in smoke mode; no feed downloads, updater permission prompts or installer processes belong in these tests. Run release-tool tests with `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s app/tools -p 'test_*.py'` from the repository root.

`WorkspaceSessionModelSmokeTests` covers the versioned store, malformed data and bounds. `WorkspaceSessionSmokeTests` exercises actual window/tab/pane reconstruction, both file views, executed searches, logical ZIP locations, background navigation, split/sidebar geometry and the application startup/save/quit lifecycle with injected dependencies. Neither suite may read or overwrite the user's production workspace. The workspace feature passed 2,418 smoke checks three consecutive times and packaged restart checks in [workspace sessions](research/workspace-sessions.md).

For a real packaged-app quit/relaunch check, set **both** `TURSORA_UI_TEST_SESSION_FILE` and `TURSORA_UI_TEST_VIEW_PROPERTIES_FILE` to distinct absolute files under a task-owned temporary directory before launching the owned application process. The first redirects `WorkspaceSessionStore.shared`, the second redirects `DirectoryViewPropertiesStore.shared`; neither changes the normal production path. Smoke mode takes precedence over these overrides. Use the same files on the second launch to test continuity, and retain a separate copy of their pre-quit contents for comparison. Isolate or selectively restore the tested UserDefaults keys as well. Stop only the QA app's exact process, preserve user apps, and remove only task-owned fixtures after review. A restored screenshot alone does not prove a real process restart or saved-file integrity.

`ArchivePreparationSmokeTests` exercises independent subscriptions, cancellation before queued delivery, same-ZIP retries, real child termination, shutdown barriers and vanished-member listing races. `TerminalSmokeTests` mounts process-free terminal views for header/delegate checks and separately uses an isolated `/bin/sh` for actual PTY behavior. A controller assigned to a test NSWindow can change its fitting size; call `setContentSize` after assignment before checking minimum-width geometry. Compare physical fixture paths after resolving aliases, since macOS can use both `/var` and `/private/var`.

`TURSORA_DND_DEBUG=1` prints drag-and-drop decisions.

`TURSORA_TRANSFER_TEST_DELAY_MS=20` adds process-local pacing between real transfer blocks for packaged-app interaction checks. It keeps the production data/metadata/publication path and does not persist a preference. Record when using it; normal transfers have no injected delay. `TransferSmokeTests` separately uses injected block sizes, faults and lifecycle gates. Parallel worktrees must hold an exclusive `fcntl.flock` on `/private/tmp/tursora-shared-verification.lock` across smoke or packaged-app checks, save/restore preferences, and only manage their own application PID.

## Conventions

- **Finder evidence rule.** Anything that claims to match Finder — a label, a group name, a menu icon, a dialog's wording — is taken from Finder's own resources (`strings` on its nibs, `plutil` on its `.strings` tables), not from memory. Record the extraction under [research/](research/) and mark what is still inferred. See D12.
- **Dolphin semantics, Finder shape.** Where the two disagree, the interaction semantics follow Dolphin (address bar, tabs, split, zoom ladders, filter matching) and the visual form follows Finder (toolbar search field, conflict dialog, groups, Get Info). Say which in the spec.
- **Views never touch the filesystem.** `FileOperations` does the work; `BrowserViewController` owns undo and refresh; the two file views only render `DirectoryModel` and report intent through the `FileViewing` callbacks.
- **One undo group per operation** (`asUndoGroup`), registered on the window's undo manager, and every operation posts `DirectoryChanges.post` so other panes and Info windows refresh without waiting for FSEvents.
- **Comments say why.** The code carries short comments where AppKit behaviour is surprising (see the pitfalls below); the spec carries the intended behaviour.
- **Commits**: use a meaningful module scope, such as `feat(search): …`, `fix(transfers): …`, or `docs(view-settings): …`. Omit the scope for global or multi-module changes (`feat: …`, `fix: …`, `docs: …`); do not use `tursora` as a blanket scope. The body says what changed and why and ends with the smoke-test count.
- Docs: specs and decisions in Chinese (product-facing), code-facing docs in English.

## AppKit pitfalls met so far

Each of these cost a debugging round; the fix is in the code with a comment.

| Symptom | Cause | Fix |
|---|---|---|
| Read-after-write of a file flag returns the old value | `URL.resourceValues` is cached for the rest of the run-loop pass | Read through `FileManager.attributesOfItem` (`FileInfo`) |
| FSEvents never matches the watched folder | Events carry real paths (`/private/var/…`) while the app holds `/var/…` | Resolve symlinks on both sides before comparing |
| Second pane never appears / split treated as collapsed | `NSSplitView` treats a zero-size subview as collapsed | Give the pane a real initial frame; the delegate refuses collapse; relayout on close |
| Crash on `reloadData` after a folder listing changed | Outline view queried stale rows | Refresh children before `reloadData`; track expansion via `itemDidExpand/Collapse` notifications |
| Accessibility inspection gradually opens untouched tree branches | AppKit consults `shouldExpandItem` while querying available actions | Keep permission callbacks pure; load directories only after `outlineViewItemDidExpand` |
| Narrow split panes enter a layout loop | Recreating an overflow button and temporarily unhiding its replacement chevron invalidates layout on every pass | Reuse the control, calculate final visibility once, and update only changed frames or visibility |
| Headless AX checks trap while iterating `accessibilityRows()` | The imported Swift array expects `NSAccessibilityRow`, but AppKit returns legacy `NSOutlineRow` objects on macOS 26.3 | In the regression test, retain the Objective-C `NSArray` and query its legacy attributes without the incorrect typed bridge |
| Details-view zoom ignored | `rowSizeStyle = .default` ignores `rowHeight` | `rowSizeStyle = .custom`; `loadView` must not overwrite the height |
| Completion popup rows cut off | `.inset` table style adds padding, unflipped clip view | `.plain` style, `rowSizeStyle = .custom`, flipped clip view, scroll to top |
| Undo merges several operations into one | `NSUndoManager` had an open automatic event group | `asUndoGroup` closes stale groups, then opens one per operation |
| Rename starts after a drag ends | Mouse-up after a drag session is indistinguishable by timing; `pressedMouseButtons` is unreliable with a mouse | Pointer travel > 3 pt cancels; drag session begin/end cancels |
| Group rows selectable by keyboard/rubber band | Programmatic `selectRowIndexes` bypasses `shouldSelectItem` | Also implement `selectionIndexesForProposedSelection` |
| Blank space after navigation, or the first row hidden under its header after refresh | Raw clip coordinates can include bounce and a legitimate negative header inset; clamping raw y to zero hides the first row | Save a nonnegative offset relative to the native constrained top; restore through `NSClipView.constrainBoundsRect` |
| First tab showed an empty folder | The tab's view was attached hidden and never shown | `applyVisibility()` after inserting; the smoke test checks frame sizes |
| Search field never folds back | `beginSearchInteraction` called when already expanded; focus loss cancelled the filter | Only call it when collapsed; `endSearchInteraction` on empty blur; only an emptied field cancels |
| Deferred initial navigation replaces a newly chosen favorite | A new pane schedules its initial load after the owner wires callbacks | Run that initial load only while its navigation generation is still zero |
| ZIP root paths compare differently after Up | Removing a path component adds a directory hint to a URL that represents a ZIP file | Canonicalize prepared archive locations and ZIP ancestors; compare filesystem identity using standardized paths in tests |
| Inspector renamed the wrong file | A field ending editing after `urls` had changed committed to the new item | Fields remember the URL they were built for (`nameFieldURL`, `commentsURL`, …) |
| Info window rebuilt on every cache write under `~` | FSEvents streams the whole subtree of the watched parent | Filter events to the items and their siblings |
| Section chevrons missing, remembered state ignored | Property observers do not run when a class sets its own property in `init` | Call `applyExpansion()` explicitly from `init` |
| Name field focused as soon as an Info window opens | `NSWindow` picks the first key view as initial first responder | `makeFirstResponder(nil)` after ordering front |
| Alternates (⌥⌘I / ⌃⌘I) not shown | `isAlternate` items must be adjacent and share the key equivalent | Keep the triple together in `MainMenu` |
| Case-only rename fails on APFS | `moveItem` refuses `a` → `A` on a case-insensitive volume | Rename through `URLResourceValues.name` |
| Headless run hangs | A modal alert with no screen | `report(...)` prints in smoke mode |
| Info sections crowd the right edge; inline preview is too narrow | Stack alignment was used as a width/fill constraint | Use leading alignment and explicit leading/trailing anchors for every outer row and section header/content; test actual frames and resizing |
| A new pane claims Icons but shows a list | The saved mode was read, but `fileView` still held the list; calling `setViewMode` with the same mode returned early | Choose the initial `fileView` from the saved mode before `loadView` mounts it |
| A narrow pane loses its Name column when remembered properties switch Icons to List | Mounting the list before applying the final group key expands obsolete groups and can scroll horizontally | Apply the final arrangement before mounting, then restore the pane's captured list horizontal offset after layout; test both zero and intentional nonzero offsets |
| Toolbar still selects List after the Icons shortcut | Pane view changes did not notify the window | Notify `BrowserHost` after mounting the view; only the active pane updates toolbar validation |
| Re-entering a pane's path editor immediately hides it or loses typing focus | Acquiring the window's shared field editor can synchronously deliver the previous edit session's end notification | Guard field-editor acquisition with `isBeginningEditing`, accept end notifications only from the owning text field, and suppress focus return during pane changes. Tests show their owned window, require an actual `NSTextView`, and verify first-responder identity; `nil === nil` must not count as editing success |
| A detached split marks the left pane active but keys still reach the right pane, or closing an editing pane leaves no file focus | Creating the second pane changes the first responder; changing `activeIndex` or removing a view does not repair keyboard focus | After restoring a snapshot, focus its active pane explicitly. When closing the active pane, focus the survivor; closing the inactive pane must preserve the active path editor |
| A sidebar requested at 245 pt returns to 160 pt after layout, even in a 1000 pt window | Its `.defaultHigh` holding priority (750) exceeds AppKit's divider-drag priority (490); `setPosition` obeys the same constraints as dragging | Use holding priority 260: above the content's default 250 to preserve sidebar width during window resizing, below 490 to allow movement. The local SDK's `NSSplitView.h` documents both rules; this fix passed smoke and actual-drag verification in [workspace sessions](research/workspace-sessions.md#侧栏宽度诊断) |
| A tab menu action aborts with an invalid Objective-C selector | `#selector(Target.perform(_:))` can resolve to inherited `NSObject.perform(_:)`, passing the menu item as a selector | Use an unambiguous action name such as `invoke(_:)` and dispatch real `NSMenuItem` actions in smoke checks. Line-buffer smoke output so a runtime fault retains its last completed check |

## Release checklist

1. `swift build` clean, smoke test green three times.
2. `tools/make-app.sh`, launch `build/Tursora.app`, click through what the smoke test cannot see (popups, overlays, Info window layout, menu icons).
3. Update [../CHANGELOG.md](../CHANGELOG.md), the spec if behaviour changed, and the gap lists if something moved to ✅.
4. Commit with the smoke-test count in the message.

## GitHub Actions

`.github/workflows/build.yml` builds a release application on `macos-26` (Apple Silicon) for main pushes, pull requests, or manual runs. It runs release/update metadata tests, verifies the ad-hoc signature, plist, icon and updater components, then creates a DMG and checks its mounted contents and layout. Each artifact includes the DMG and SHA-256 checksum, retained for 14 days; GitHub wraps artifact downloads in an outer ZIP. This build does not require an update-signing secret.

`.github/workflows/release.yml` has only `workflow_dispatch`. Run it on `main` with a version such as `0.1.0` or `0.2.0-beta.1` and the prerelease switch when appropriate. It rejects existing tags, unsafe/invalid version strings and missing or empty dated changelog sections, packages the exact dispatch SHA, then creates the version tag and GitHub Release using that changelog section. The bundle's short version uses the numeric portion; the filename and release retain the prerelease suffix. No automatic release is triggered by a push or tag. Follow [RELEASING.md](RELEASING.md); add subsequent changes under Unreleased until the next release.

Stable releases require `SPARKLE_PRIVATE_KEY`, a higher stable semantic version and a higher build than the current appcast. They generate `appcast.xml` with an Ed25519 DMG signature, verify that signature and the feed's metadata, checksum the feed and DMG, and explicitly become GitHub's latest release. Release assets are the DMG directly, appcast and checksums; no application ZIP is additionally published. The feed XML itself is not signed and `SURequireSignedFeed` is not enabled. Prereleases do not publish an appcast or become latest. Build values come from the source commit timestamp in both workflows; they do not use independent workflow run numbers. Local signing-key and first-feed readiness are tracked in [the update research](research/app-updates.md).

`.github/workflows/pages.yml` validates relevant site changes on PRs and deploys `site/dist/` when they reach `main`; manual dispatch also deploys `main`. It uses the existing GitHub Actions Pages source and `github-pages` environment. Other branches and PRs never deploy. The stable updater feed is a Release asset, so a Pages deployment failure does not replace or publish update metadata.

The workflows validate packaging; run the AppKit smoke suite three times in a desktop session before committing. Hosted workflow execution is only verified once these files are pushed and a run completes. Current releases are ad-hoc signed, not Developer ID signed or notarized.

### Reusing icon layouts and measuring scroll content

On macOS 26, an offscreen `NSCollectionViewFlowLayout` can retain old ungrouped section attributes after both `reloadData()` and `invalidateLayout()`. Recreate the layout when the grouped flag or section item counts change. Smoke coverage checks actual supplementary headers and cross-section item frames after switching panes and view modes.

Info sections fill the scroll view's clip viewport, not its outer frame. A legacy vertical scroller consumes horizontal space when the document exceeds the screen-height cap; layout assertions must compare against `scrollView.contentView.bounds.width`.

Selection preservation and rename hints use full standardized URLs. Basenames alone can select an unrelated root file after extracting or refreshing an expanded folder containing the same name.

Keep the list name column's minimum width at 180 pt. In narrow split panes, allowing it to shrink like a metadata column can make the filename unreadable even when the row and item count are correct. Cover its minimum in smoke checks and inspect the actual split layout.

An editable server address must not submit when it merely loses focus. Otherwise clicking Cancel can dispatch the text field's Connect action before cancellation. Keep action-on-end-editing disabled and verify explicit Return / Connect separately from focus changes and cancellation. The corrected form passed the recorded Tab / Cancel / reopen / protocol-error / edit / Escape computer-use sequence; final integrated smoke results remain tracked in the dated computer-use record.

### Capturing the packaged application

Use a verified window ID with `screencapture -x -o -l<windowID>` for the target application window and relevant menu state, then inspect the saved result. During the current screenshot pass, rectangle-based `-R` captures accidentally included a background application and were replaced. Do not assume screen coordinates identify the intended window, and never treat a saved image alone as proof of a completed interaction. See [the current computer-use record](research/computer-use-2026-09-12-inline-zip.md) and [screenshot maintenance](images/README.md).

## Keep documentation in step with development

Update documentation in the same change as the behavior it describes:

- `SPEC.md` records what users can do, including disabled states and experimental limits.
- `DECISIONS.md` records meaningful trade-offs; `SHORTCUTS.md` records new controls and key bindings.
- Update `ARCHITECTURE.md` when ownership, routing or lifecycle changes, and close shipped items in the gap lists and roadmap.
- `HANDOFF.md` and research records distinguish implemented behavior, automated checks, actual computer-use verification and remaining gaps. Replace pending verification only after performing it.
- Refresh the root README and its feature screenshots when the visible workflow changes. Screenshots must come from the packaged application with demonstration files, never personal documents or invented UI. Each advertised feature group must retain its own relevant screenshot. See [image maintenance](images/README.md).
- Add a changelog entry with the resulting behavior. Historical research should remain historical; link to new evidence instead of rewriting old observations as current results.

## Build and preview the product page

The static page is independent of the Swift app. From the repository root, using Python 3.9 or later:

```sh
python3 site/build.py
python3 -m http.server 8080 --directory site/dist
```

Open `http://localhost:8080` and stop the server with Control-C. The builder uses only the standard library, recreates `site/dist/`, and refuses a symlink at that location. Generated output is ignored by Git. It copies the required icon and three canonical screenshots without editing their pixels, then validates local references, fragments, IDs, alt attributes and the three workflow panels. Static validation does not replace browser review or verify live GitHub downloads.

Use [site/README.md](../site/README.md) for the exact asset list and desktop/mobile, keyboard, dialog, reduced-motion and no-JavaScript review sequence. Record observed results in dated research and maintain current status in [HANDOFF](HANDOFF.md). Previewing or building the page does not deploy it; hosting and publication are separate actions.

## Search-specific filesystem and UI pitfalls

Darwin's URL directory enumerator does not follow symbolic links. Calling `skipDescendants()` on a symlink leaf can skip the *next sibling directory*, silently losing valid recursive search results. Use `.skipsPackageDescendants` and explicit result containment checks; the search smoke fixture includes a symlink before an ordinary sibling folder.

Search results have no directory URL, and both views retain full-URL selection through filtering, grouping and view changes. The icon grid snapshots displayed item identities before model arrangement changes; resolving old index paths against new groups can select another file. Inline rename remembers its original FileItem and cancels on streamed result reload, so a reused row cannot receive a late edit. Do not write a search selection into its originating directory's navigation history.

NSMetadataQuery rejects AND/OR compound predicates with only one child by throwing an Objective-C exception during `start()`, even though ordinary NSPredicate evaluation accepts them. Return the leaf predicate for a single condition; an unrestricted query must use a supported match-all filename comparison rather than TRUEPREDICATE. Validate the actual generated predicates against the native query service as well as using deterministic content fixtures.

Context menus snapshot full FileItems when built, retaining them through menu closure and action dispatch. Never re-resolve clicked rows after a search batch changes ordering. FileOperations normalizes overlapping selections through actual directory ancestors before mutations, so selecting a folder plus its ordinary search-result child cannot remove the parent and then throw before registering Undo. An intervening symlink prevents that coverage even if the link itself is not selected: selecting an actual `root` directory and `root/link/externalChild` retains both sources. A selected actual directory below a symlink still covers its own ordinary descendants; only the path from that selection to its child matters. Symbolic links do not cover explicit descendant sources. TransferTask applies the same source normalization before capturing its task context; Duplicate uses each retained source’s real parent. The integrated fixture covers source normalization and the real Copy worker for selected and intervening links; see the integration record for run status. Search completions and Undo/Redo reload the query with full-URL selection instead of selecting basenames in the originating folder.

Search retains the originating currentURL and viewPropertiesKey for returning to the folder, so a non-nil key alone does not permit view persistence. `canPersistViewProperties` also rejects `isSearching` and `model.isSearchResults`; use it for ordinary saves, store observers, default/reset commands and menu validation. Search initially inherits the pane’s current view and subsequent changes stay transient. Reload/refresh must handle search before directory-key retarget checks, and leaving search restores the folder’s current saved properties.

When checking that Open or Split creates no window, snapshot window object identities immediately around that operation and inspect additions plus the original pane/window identity. A process-wide window count can change as earlier suites release closed windows; equal counts can also hide a replacement window. The ZIP browser suite covers both cases without a fixed delay.

### Adaptive custom surfaces

Retain semantic NSColors, not once-resolved CGColors. `AdaptiveLayerView` resolves background and border in `updateLayer()` under its own `effectiveAppearance`; the tab strip resolves its draw palette per appearance and refreshes on window focus changes. Borderless completion panels explicitly follow their parent appearance while attached. Tab appearance smoke checks include both standard and high-contrast Light/Dark colors, actual bitmap background rendering, title refresh, scrolled mouse drag paths and overflow menu lifetime; appearance surface checks exercise existing popups, task cards and pane indicators.

For packaged visual QA without changing the user's global appearance, launch an owned test instance with `TURSORA_UI_TEST_APPEARANCE=light` or `dark`. This process-local override is not a saved preference; ordinary launches follow the system. Keep the same bundle identifier, use a separate owned bundle path, and only stop the test process. Do not restore an old full preference snapshot over changes the user made while testing; restore only settings owned by the verification workflow.

### Search-field delegate ordering

`NSSearchField.searchFieldDidStartSearching` may precede `controlTextDidChange`; adopt the new field value before syncing chrome or the old empty filter can erase the first edit. The end-search callback also occurs on blur, so an empty name is not a reliable cancel signal for content/type-only queries. Keep the native cancel-cell wiring (AppKit resets its internal target/action); distinguish a cleared non-empty draft from blur of an already empty draft, and handle Escape separately. Guard programmatic field/editor synchronization from delegate feedback. Ignore marked IME text for query scheduling, deduplicate unchanged name notifications, and give delayed searches a generation guard in addition to `DispatchWorkItem.cancel()`.

### Virtual ZIP paths and startup chrome

ZIP logical descendants are virtual paths. Foundation may standardize an existing `/private/tmp/Archive.zip` to `/tmp/Archive.zip` while retaining `/private/tmp/Archive.zip/Notes` for its nonexistent physical descendant. Match the registered archive’s resolved parent and preserve lexical member components; never resolve an untrusted member to establish ownership. Startup chrome may use the requested logical location before `currentURL` exists, but file actions must keep using the actual current location.

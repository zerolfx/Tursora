# Changelog

Historical entries record development dates and their smoke-test counts where available. Verification applies to the revision and scope recorded with each entry; integrating newer changes requires fresh checks (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)).

## Unreleased — persistent folder view settings

- Feature revision `eac9ffc` passed 854 full smoke checks three consecutive times after the packaged-app layout fix. After incorporating main revision `ae5e47a`, the integrated tree again passed 854 checks three consecutive times, each with exit 0 and empty stderr; debug/release builds and strict codesign passed. Revision-specific packaged-app observations, screenshots and the pending integrated UI recheck are tracked in [the feature verification record](docs/research/computer-use-2026-09-12-directory-views.md).
- Keep the Name column visible when restored settings switch a narrow pane from grouped icons to a list, while preserving intentional horizontal scrolling.

- Remember each folder's view mode, sorting and direction, separate list/icon zoom steps, grouping, hidden files and previews across navigation, new tabs/panes and application restarts.
- Add Settings and View menu choices for remembering each folder or using one default, plus explicit commands to save the current settings as default and restore a folder. Existing same-folder panes remain independent during ordinary per-folder edits; unified edits and explicit default/policy/reset commands synchronize affected panes.
- Store versioned, tolerant JSON in Application Support with immediate memory updates and coalesced atomic writes. Normalize local paths and symlinks; preserve unsupported files until an effective mutation. Keep ZIP logical locations, snapshot paths, filters, selections, scroll and history out of folder records.
- Add isolated model/storage and browser smoke coverage. Revision-specific build, smoke, packaged-app and signature results are tracked in [HANDOFF](docs/HANDOFF.md); the historical 739-check ZIP baseline does not verify this feature or the merged tree.

## Unreleased — cleanup and product page

- Remove an unused PlacesModel constant and simplify the archive readable-URL helper's always-enabled option without changing application behavior.
- Consolidate current verification status in HANDOFF and keep detailed evidence in dated research records.
- Improve the product page's secondary-text contrast and prevent the header from clipping content after direct anchor navigation.
- Add a Chinese product page for editable paths, tabs, split panes and read-only ZIP browsing, using actual application screenshots. A dependency-free Python builder produces portable static output and validates local references. Desktop and narrow-screen browser checks cover workflow selection, screenshot dialogs, direct fragments and the no-JavaScript fallback; the page is locally previewed and has not been deployed. See [the recorded scope](docs/research/computer-use-2026-09-12-inline-zip.md#整理阶段与产品页).

## 2026-09-12 baseline — settings, native services and optional workspaces

- Add a toolbar Split View toggle that follows the selected tab and active pane, plus sidebar Open in Other Pane using the existing split-navigation behavior. Sidebar commands retain the actual right-clicked place, fixing New Tab actions that lost their target after menu tracking.
- Prevent a new pane's deferred initial load from replacing a location explicitly selected before that load runs; the initial navigation only proceeds while the navigation generation is zero.
- Reuse existing Info and Summary windows for standardized URL variants of the same targets, avoiding duplicate windows from alternate path representations such as `/var` and `/private/var`.
- Inset the two glass panes within the app icon so their tips have more room inside macOS's rounded mask, preserving the single full-bleed background.
- Prevent server address-field focus loss or Cancel from starting a connection; only explicit Return / Connect submits, and editing clears stale validation errors.
- Keep the list name column at least 180 pt wide so filenames remain readable in narrow split panes.
- Fix the first list row becoming hidden under the column header after refresh or archive undo/redo; restore scroll positions relative to AppKit's native content top and preserve horizontal scrolling.
- Add a native Settings window (⌘,), immediate filename-extension display preferences, and a configurable name-filter shortcut with conflict checks and reset.
- Add two experiments, both disabled by default: a window-bottom SwiftTerm 1.15.0 PTY terminal (F4), and read-only ZIP browsing in the current pane. Navigation updates only the terminal's manual restart destination; hiding/restarting ends its session. ZIP files open as temporary copies without archive writeback.
- Replace the separate ZIP window with ordinary pane navigation: logical archive paths, Back / Forward / Up, tabs and splits, both views, grouping, sorting, name filtering, Quick Look, sharing and copy-only drag-out. Disable archive mutations and keep existing archive pages read-only when the experiment is turned off.
- Add ZIP Compress / Extract with undo/redo, safe unique output names and isolated processing; normal ZIP Open still extracts when browsing is disabled.
- Add Connect to Server (⌘K) through system NetFS, network-volume classification and Eject; no real server connection has been validated yet.
- Fix grouping after Favorites navigation, align sidebar/content edges, stabilize the sidebar toggle, remove the duplicate title-bar path and passive filter scope row, and correct Favorites icon sizing.
- Add the toolbar More menu and system sharing picker; remove file-tag functionality by design. Import from iPhone is also intentionally excluded.
- Redesign the app mark as two glass panes forming an abstract tail fin, with one full-bleed icon background.
- Expand the README and add a build-artifact workflow plus a separate manual Release workflow.
- Rewrite the README with 13 feature screenshot groups from the packaged application. Every image has been saved and inspected; the server screenshot uses the final corrected form.
- Require documentation and actual application screenshots to evolve with implementation, while keeping automated verification and computer-use evidence distinct.
- Preserve exact file selections through appearance and external refreshes, including same-named files in expanded folders; Escape cancels inline rename in both views.
- Rebuild stale icon-grid layouts when grouping changes; use the scroll viewport when verifying Info section widths.
- Verification and its limits are recorded in [the dated computer-use log](docs/research/computer-use-2026-09-12-inline-zip.md); [earlier evidence](docs/research/computer-use-2026-09-12.md) covers the previous standalone ZIP window.

## 2026-09-12 — application icon and squashed baseline

- Squashed the 42 existing commits into one baseline, preserving file contents and the GitHub noreply author identity. Historical entries below omit their superseded individual commit hashes.
- Added the blue glass folder application icon, a transparent 1024px PNG master, a 16–1024px ICNS family, and bundle icon registration. Master alpha/dimensions and icon-family sizes are covered by the smoke test. 392 checks.

## 2026-09-12 — startup verification and UI fixes

- Wait for the initial directory listing with a bounded timeout instead of assuming it completes in one second; add a delayed empty-directory regression.
- Keep the toolbar view selection in sync with the active pane, and mount the saved view mode when creating a pane.
- Give Info sections explicit full-width constraints, including their headers and preview content; verify collapse and resize layouts. 389 checks.
- Inspect the packaged app with computer use: navigation, tabs, split panes, views, filtering, grouping, Quick Look, and Info layout.

## 2026-09-11 — rename, documentation

- Renamed from "Otter File Manager" to **Tursora**: target, bundle id `com.tursora.Tursora`, menu titles, env vars (`TURSORA_SMOKE_TEST`, `TURSORA_DND_DEBUG`), notification names, toolbar and autosave identifiers.
- Documentation reorganised: `docs/SPEC.md`, `DECISIONS.md`, `ARCHITECTURE.md`, `DEVELOPMENT.md`, `SHORTCUTS.md`, `ROADMAP.md`, `HANDOFF.md`, `gaps/`, `research/`; `AGENTS.md` at the root.

## 2026-09-11 — Get Info

- Finder's Get Info (⌘I), Inspector (⌥⌘I) and Summary Info (⌃⌘I) windows with Finder's own sections and labels; SF Symbol icons on menu items taken from Finder's `MenuBar.nib`. 355 checks.
- Review fixes: FSEvents filtered to the item and its siblings; rebuilds deferred while typing; each section bound to the URL it was built for; renames followed (in-app hint, outside by inode); section expansion applied in `init`; comments saved on quit. 367 checks.

## 2026-09-11 — groups, filter, conflicts

- Filter bar; Finder-style conflict dialog with Keep Both / Skip / Stop / Replace / Merge and "Apply to all".
- Finder-style filter UI: toolbar search field and scope bar. the field folds back when focus leaves it empty.
- Finder's Use Groups / Group By in both views; group labels taken from Finder's string table.
- No blank space above the rows after navigating during a scroll bounce.
- Gap list against Finder's menu nib.

## 2026-09-11 — split view, icon view, live refresh

- Dolphin-style split view: one or two panes per tab, drag a tab into the content area to split.
- Icon view (`NSCollectionView`), Dolphin zoom ladders, Quick Look thumbnails as previews.
- Panes refresh on outside changes (FSEvents); no rename after a drag. Rename guard independent of drag timing; files drop onto tabs. Gap list against Dolphin.

## 2026-09-11 — M1 to M5

- M1: window, sidebar, file list, navigation, launchable `.app`.
- M2/M3: tabs, address bar, context menus, mouse navigation. First tab's view stayed hidden.
- M4/M5: quick navigation and file operations (copy/cut/paste, duplicate, rename, trash, drag & drop, Quick Look, undo).
- Folders expand in place; Finder-style delayed click-to-rename. Sidebar reorder target, address-bar overflow, real autocompletion. Completion rows cut off. Every favourite reorderable and removable.

## 2026-09-10 — pivot to a native rewrite

- v1 plan for a Swift + AppKit rewrite; model layer seeded.

## 2026-08-19 — Phase 0 audit of porting Dolphin/KIO

- … Source audit with twelve sections, adversarial verification, and the report that concluded a native rewrite was the better path ([docs/audit/](docs/audit/)).

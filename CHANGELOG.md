# Changelog

Historical entries record development dates and their smoke-test counts where available. The current unreleased changes are tracked separately until final integrated verification completes (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)).

## Unreleased — settings, native services and optional workspaces

- Add a native Settings window (⌘,), immediate filename-extension display preferences, and a configurable name-filter shortcut with conflict checks and reset.
- Add two experiments, both disabled by default: a window-bottom SwiftTerm 1.15.0 PTY terminal (F4), and a separate read-only ZIP browser. Navigation updates only the terminal's manual restart destination; hiding/restarting ends its session. ZIP files open as temporary copies without archive writeback.
- Add ZIP Compress / Extract with undo/redo, safe unique output names and isolated processing; normal ZIP Open still extracts when browsing is disabled.
- Add Connect to Server (⌘K) through system NetFS, network-volume classification and Eject; no real server connection has been validated yet.
- Fix grouping after Favorites navigation, align sidebar/content edges, stabilize the sidebar toggle, remove the duplicate title-bar path and passive filter scope row, and correct Favorites icon sizing.
- Add the toolbar More menu and system sharing picker; remove file-tag functionality by design. Import from iPhone is also intentionally excluded.
- Redesign the app mark as two glass panes forming an abstract tail fin, with one full-bleed icon background.
- Expand the README and add a build-artifact workflow plus a separate manual Release workflow.
- Preserve exact file selections through appearance and external refreshes, including same-named files in expanded folders; Escape cancels inline rename in both views.
- Rebuild stale icon-grid layouts when grouping changes; use the scroll viewport when verifying Info section widths.
- Verification: 605 checks passed three consecutive full runs; release bundle, signature, resources and ZIP round-trip checks passed. Additional computer-use checks for Settings, Terminal and ZIP browsing await an unlocked Mac.

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

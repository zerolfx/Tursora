# Changelog

Dates are commit dates. Every entry below was verified by the in-app smoke test (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)); the count at the end of an entry is the number of checks at that point.

## 2026-09-12 — startup verification and UI fixes

- Wait for the initial directory listing with a bounded timeout instead of assuming it completes in one second; add a delayed empty-directory regression.
- Keep the toolbar view selection in sync with the active pane, and mount the saved view mode when creating a pane.
- Give Info sections explicit full-width constraints, including their headers and preview content; verify collapse and resize layouts. 389 checks.
- Inspect the packaged app with computer use: navigation, tabs, split panes, views, filtering, grouping, Quick Look, and Info layout.

## 2026-09-11 — rename, documentation

- Renamed from "Otter File Manager" to **Tursora**: target, bundle id `com.tursora.Tursora`, menu titles, env vars (`TURSORA_SMOKE_TEST`, `TURSORA_DND_DEBUG`), notification names, toolbar and autosave identifiers.
- Documentation reorganised: `docs/SPEC.md`, `DECISIONS.md`, `ARCHITECTURE.md`, `DEVELOPMENT.md`, `SHORTCUTS.md`, `ROADMAP.md`, `HANDOFF.md`, `gaps/`, `research/`; `AGENTS.md` at the root.

## 2026-09-11 — Get Info

- `8841469` Finder's Get Info (⌘I), Inspector (⌥⌘I) and Summary Info (⌃⌘I) windows with Finder's own sections and labels; SF Symbol icons on menu items taken from Finder's `MenuBar.nib`. 355 checks.
- `b6d398f` Review fixes: FSEvents filtered to the item and its siblings; rebuilds deferred while typing; each section bound to the URL it was built for; renames followed (in-app hint, outside by inode); section expansion applied in `init`; comments saved on quit. 367 checks.

## 2026-09-11 — groups, filter, conflicts

- `a9065f0` Filter bar; Finder-style conflict dialog with Keep Both / Skip / Stop / Replace / Merge and "Apply to all".
- `aa56cbe` Finder-style filter UI: toolbar search field and scope bar. `c37b303` the field folds back when focus leaves it empty.
- `2434e57` Finder's Use Groups / Group By in both views; `cc6f3cf` group labels taken from Finder's string table.
- `d85975e` No blank space above the rows after navigating during a scroll bounce.
- `3e68e9e` Gap list against Finder's menu nib.

## 2026-09-11 — split view, icon view, live refresh

- `b905008` Dolphin-style split view: one or two panes per tab, drag a tab into the content area to split.
- `84fe1be` Icon view (`NSCollectionView`), Dolphin zoom ladders, Quick Look thumbnails as previews.
- `75e3564` Panes refresh on outside changes (FSEvents); no rename after a drag. `66201fd` Rename guard independent of drag timing; files drop onto tabs. `e7ab2e3` Gap list against Dolphin.

## 2026-09-11 — M1 to M5

- `fe83991` M1: window, sidebar, file list, navigation, launchable `.app`.
- `12ca3e1` M2/M3: tabs, address bar, context menus, mouse navigation. `eb26331` First tab's view stayed hidden.
- `657f974` M4/M5: quick navigation and file operations (copy/cut/paste, duplicate, rename, trash, drag & drop, Quick Look, undo).
- `3af5f90` Folders expand in place; Finder-style delayed click-to-rename. `4535a62` Sidebar reorder target, address-bar overflow, real autocompletion. `54cf04e` Completion rows cut off. `44b819c` Every favourite reorderable and removable.

## 2026-09-10 — pivot to a native rewrite

- `9dfd2aa` v1 plan for a Swift + AppKit rewrite; model layer seeded.

## 2026-08-19 — Phase 0 audit of porting Dolphin/KIO

- `2783774` … `076d244` Source audit with twelve sections, adversarial verification, and the report that concluded a native rewrite was the better path ([docs/audit/](docs/audit/)).

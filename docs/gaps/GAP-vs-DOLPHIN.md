# Tursora vs Dolphin — feature gap list

Compiled from the actions, panels, settings pages and context-menu entries actually registered in `upstream/dolphin/src`, checked item by item against what Tursora implements today.
**Bold** = frequently used and cheap to moderate in effort, so worth doing first. "(mac)" = macOS offers a better native equivalent.

## A. Views and browsing

| Dolphin feature | Tursora | Notes |
|---|---|---|
| A separate address bar for each split pane, with both sides shown at once in the tab title | ✅ | Each pane has an editable path; the title keeps the physical left-right order separated by a vertical bar, the active side is marked by the pane indicator line, and the tooltip shows the full logical path; [evidence and verification status](../research/pane-paths-and-tab-actions.md) |
| Tab context menu (New / Detach / Rename / Close Other / Close Left / Close Right / Close) | ✅ | Each action captures the identity of the tab that was right-clicked; a custom name can be cleared; Detach opens a new window from the locations and the search request, and carries over neither history nor tasks. Always showing the tab bar is this app's own default |
| Filter bar (`show_filter_bar`, filters the current view by name as you type) | ✅ `⌘F` by default, customizable | Substring plus wildcards, cleared when the directory changes |
| Grouping (`group_by`) | ✅ Follows Finder's Use Groups / Group By, 9 keys (including None; Tags is explicitly out of scope) | Group headers stick in the list, and the icon view is split into sections |
| **Additional information columns** (`additional_info`, about 30 columns: creation/access time, extension, permissions, owner, link target, path, rating, tags, comment, word count, line count, image dimensions, duration, artist…) | Ordinary directories have Name/Date Modified/Size/Kind; search adds Location | (mac) Most of these can come from Spotlight metadata (`kMDItem*`) |
| Sort options: descending / folders first / **hidden files last** | Ascending and descending ✅; folders lead under Name only | Matches Finder, whose "Keep folders on top" covers only name sorting, so folders take part in every other sort (D76). Still missing: "hidden last", and a switch for the name case |
| **Folder item count / recursive size column** (`KDirectoryContentsCounter`) | ✅ | The Size column shows the item count by default (Finder's "N items"), and shows recursive bytes once `Calculate all sizes` is on; calculated in the background, remembered per directory, and ZIP and search results only count items ([record](../research/sort-columns-folder-sizes.md)) |
| **Per-directory view properties** (mode / sorting / zoom / hidden files and restore defaults) | ✅ Per-directory memory / one shared default, save the current settings as the default, restore the current directory | Both zoom steps, grouping and previews are saved along with them; the app keeps its own versioned path store, with no `.directory` file and no xattr. Applying recursively to subdirectories, column widths / additional columns and following items as they move are still not implemented; for the evidence and the limits see the [research](../research/directory-view-properties.md) |
| Compact view (a third mode) | ❌ | Low priority |
| Hover tooltip (metadata plus preview) | ❌ | Quick Look partly covers this |
| `.hidden` file / `UF_HIDDEN` flag (Dolphin only recognises dot files) | ❌ | (mac) Has to be done: `/usr`, `Icon\r`, `.fseventsd` and so on |

## B. Panels

| Dolphin feature | Tursora | Notes |
|---|---|---|
| **Folders panel** (a directory tree that can follow the view) | ✅ Implemented and verified | A separate NSOutlineView tree below Places; F7, follows the active pane, reads on demand, hidden-files / Home options, and the vertical ratio and visibility remembered for the session; no free docking or floating, see the [record](../research/folder-tree.md) |
| Information panel (preview plus metadata plus media autoplay, "show on hover") | ❌ | (mac) Quick Look covers the preview; a metadata panel could be built as an Inspector |
| Terminal panel (an embedded terminal that follows the directory, `switch_terminal_url_sync`) | ✅ Enabled by default | Native SwiftTerm 1.15.0 plus a PTY, from the toolbar or F4 by default; the shell, the monospaced font and the text / background colors can be set. Hiding keeps the session, and the task confirmation before termination is in the [lifecycle record](../research/terminal-session-lifecycle.md). zsh, bash and fish all follow automatically in both directions: the browsed directory is handed to the shell (immediately at an empty prompt for zsh, at the next prompt for bash / fish), and when the shell changes directory itself the current pane follows; each direction has its own switch, both on by default, and running programs and uncommitted input are preserved. Other shells need a manual Restart. The top is compact, and the bottom carries no terminal status or capacity; [0.2.1 scope](../research/terminal-navigation-0.2.1.md), [two-way sync with bash / fish](../research/terminal-shell-sync.md) |
| Places: hide entries / show all, and the "recently used" and "search" groups | partial | We have add, remove, drag to reorder and eject ✅ |
| Panel locking / layout memory | partial | Session restore already covers sidebar width / collapsed state and the split ratio; this round adds Folders visibility / height ratio / options. Panel locking, free docking and restoring the terminal layout are still not implemented |

## C. File operations

| Dolphin feature | Tursora | Notes |
|---|---|---|
| **Batch rename** (Return on a multi-selection → `KIO::RenameFileDialog`, the `name#` pattern) | ✅ Finder-style | A multi-selection goes through the File ▸ Rename N Items… sheet (Dolphin uses Return); the `name#` placeholder is not implemented, and Name and Index / Name and Counter take its place; the preview list matches Dolphin |
| **New ▸ template** (`Create New`: text file/HTML/…, from the Templates directory) | New folder only | |
| **Invert selection** (`invert_selection`) | ❌ | A few lines of code |
| **Operation progress and cancellation** (KJob progress, pause/cancel, several tasks at once) | Copy / Move / Duplicate have per-task control; for the verification see the [dedicated record](../research/file-operation-tasks.md) | A large file can be paused / resumed / cancelled part way through (checked between chunks); conflicts are handled separately and undo is safe. Metadata system calls, same-volume atomic moves and the ZIP tool stage make no claim of byte-by-byte pausing; not every KIO backend is implemented |
| Bulk options in the conflict dialog (skip all/overwrite all/rename automatically) | ✅ Finder-style | Keep Both / Skip / Stop / Replace / Merge plus "Apply to all" |
| Properties dialog (`properties`: permissions, size statistics, open with, icon) | ✅ Get Info / Inspector | (mac) Finder's wording and the system preview; permissions are a POSIX subset |
| Show link target (`show_target`) | ❌ | |
| Empty Trash / browse `trash:/` / put back | ✅ The user trash | Entered from the sidebar or the Go menu and browsed as an ordinary list; Put Back uses our own log (Finder records put-back in the private `.DS_Store`), and Empty Trash… uses Finder's wording; per-volume trash is not implemented ([record](../research/trash.md)) |
| Releasing a drag pops up a copy/move/link menu | Decided automatically by Finder's rules | A design choice that could become a preference. ⌘ to force a move, spring-loaded folders and breadcrumb drops are implemented ([record](../research/drag-and-drop.md)) |
| Open in terminal (`open_terminal_here`) | ❌ | (mac) Terminal.app / iTerm |
| Compress/extract (the Ark service menu) | ✅ Plain ZIP | The system ditto / libarchive; passwords and other formats are not implemented |
| Compare files (Kompare), disk usage (Filelight) | ❌ | External tools, low priority |
| Undo/redo, copy/move to the other pane, copy path, Open With, copy/cut/paste | ✅ | |

## D. Navigation and finding

| Dolphin feature | Tursora | Notes |
|---|---|---|
| **Search** (`toggle_search`: file name/contents, with date/type/rating/tag chip filters) | Name / contents / type / date / saved conditions ✅; rating / tags ❌ | Names are searched recursively in the background; contents go through NSMetadataQuery and are limited by the system index. The scope is the current folder or Home, and ZIP archives are not searched; a single run is capped at 50,000 items, and there is no live incremental result stream and no interchange with Finder saved searches |
| **Session restore** (remember the open tabs/panes and restore them at launch) | ✅ Implemented and verified | By default it restores the window, the tab order / names / active tab, both pane locations / active side / ratio, and the sidebar / window layout; it can be turned off and cleared, and searches that had already been run are re-run. History, selections, filters, the terminal and tasks are not restored; [scope and verification](../research/workspace-sessions.md) |
| **List of recently closed tabs** (the `closed_tabs` menu, pick one to restore) | Only `⌘⇧T` to bring back the last one | |
| Bookmarks (the `bookmarks` menu) | ❌ | Overlaps with favorites; the two could be merged |
| An address bar rooted at a Place ("Downloads › …") | Home and volumes only | |
| Pop out split (move a pane into a new window), Split stash (the `stash:/` staging area) | ❌ | Low priority |
| Focus shortcuts such as `focus_places_panel` | ❌ | |
| Type-ahead in the icon view | List ✅ icons ❌ | |
| Selection mode (for touch screens) | Out of scope | A design decision |

## E. Remote access and protocols (KIO)

| Dolphin feature | Tursora | Notes |
|---|---|---|
| sftp / smb / webdav / ftp / fish | System mounts such as SMB / WebDAV ✅; SFTP / FTP / fish ❌ | Once NetFS has connected, ordinary local browsing takes over; NFS and legacy AFP are also supported. There is no KIO backend, and a real server is still to be verified |
| `archive://` archive browsing, `trash:/`, `recentlyused:/`, MTP, iOS(afc) | ZIP browsing ✅; the rest ❌ | ZIP is enabled by default, and once enabled it is browsed read-only in the current pane, reusing history / the address bar / both views / grouping / name filtering, and supporting copying and dragging out; it works on a temporary copy, and implements neither KIO virtual protocols nor writing back into the archive |

## F. Integration, settings and appearance

| Dolphin feature | Tursora | Notes |
|---|---|---|
| **Preferences window** (general/startup/view modes/context menu/trash/confirmation dialogs/previews) | ✅ General / Shortcuts / Terminal / Updates plus the directory view policy | Startup offers the session-restore switch, on by default, and a retry when saving fails; there are also showing extensions, shortcuts for every application command, terminal appearance / shell, the terminal and ZIP switches, and per-directory memory / one shared default. A separate Updates page offers the automatic-check switch, optional download and install, and a manual check. Updates are Tursora's own macOS distribution feature; the other behaviour policies are still to be implemented |
| **Localization** | The app's interface is English only; the website is English / Chinese | A Chinese interface for the app is still to be implemented; the website defaults to English and offers a separate Chinese page |
| Version-control plugins (git/svn status badges and commands) | ❌ | |
| Service menu / file-action plugins | ❌ | (mac) The equivalents are Finder extensions and the Services menu |
| Shortcut customization, toolbar customization | Shortcuts for application commands ✅; toolbar customization ❌ | Every main-menu command and the existing extra keyboard actions can be searched, recorded, cleared and reset one at a time or all at once, with a hint about which command owns a conflicting key; native text and shell controls are not redefined. For the combined three smoke runs and the on-device scope see the [customization integration record](../research/customization-integration.md) |
| Completion notifications (KNotification) | ❌ | (mac) `UNUserNotification` needs a signed bundle |
| Window color scheme | Out of scope | Follows the system appearance |
| Being the default file manager / "Show in Tursora" | partial (dragging a folder onto the Dock icon ✅) | |

## What Tursora has and Dolphin does not

Quick Look (space bar), moving to the system trash and undoing it, dragging into Finder or another app, inline address completion with a candidate panel, dragging a tab to split a pane, and native appearance and gestures. Trash browsing and Put Back are not yet implemented.

## Suggested next batch (by value for effort)

The user ranks continuity of work above small features; session restore was implemented in this round, and the job right now is to finish its build, three smoke runs and on-device verification, see the [record](../research/workspace-sessions.md). The cost ordering of the remaining candidates is kept below.

1. ~~Filter bar~~, invert selection, list of recently closed tabs, `.hidden`/`UF_HIDDEN` — small
2. New from template — medium
3. ~~Session restore (implemented and verified in this round)~~, ~~copy / move progress with per-task control~~, ~~bulk conflict options~~ — medium
4. Panel docking / floating, more preference policies, Chinese localization — medium to large
5. More information columns (Spotlight metadata), applying view properties recursively and persisting the column layout — medium to large
6. Multiple terminal sessions / restore, Compact view, version control, more remote protocols — large / later

## 2026-09-12 filter interaction review

- [x] Separate the interface semantics of filtering the current directory from those of a recursive search: drop the scope bar that did nothing, keep the status-bar count.
- [ ] Filter modes (plain text / wildcard / regular expression), a case switch, and a lock that keeps the filter across directories.
- [x] A separate recursive search with the scope / type / date / content conditions the backend supports; a saved search can be run again after a restart.

For the source evidence see the [filter and search comparison](../research/dolphin-filter-search.md). The boxes above mark implementation scope; for the verification of the separate search stage see the [search record](../research/search-verification.md), and for the combined verification with directory properties and operation tasks see the [PR integration record](../research/pr-integration-2026-09-12.md).

## 2026-09-12 update settings and public distribution

- [x] A native software-update entry point, the General / Updates settings pages, the daily automatic-check switch and a separate option for automatic download and install.
- [x] Turning automatic checks off keeps the manual entry point and the download preference; a network-free regression through the injected driver, plus validation of the in-bundle updater and the release metadata.
- [x] The GitHub Pages workflow for the public product page and the download entry point for the latest stable version.
- [x] Direct DMG distribution with the Tursora → Applications drag-to-install layout, and checks of the build and signing tools.
- [x] The signing private key is configured as a GitHub Actions secret, and the first stable 0.2.0 with an updater and its appcast are published; for the bytes and the signature see the [release record](../research/release-0.2.0.md).
- [x] Sparkle DMG download, verification, installation and restart completed with a temporary QA key and a local feed; plus offline signature negative tests with a wrong key and with a same-length tampered file.
- [ ] Complete download, install and restart verification against the live production feed. There is still no certificate for Developer ID / Apple notarization; that will be taken on separately later.
- The checkboxes mark implementation scope; they do not mean a new version or the website has been published. For this round's tool / smoke / on-device checks see the [software update record](../research/app-updates.md) and the [Pages record](../research/github-pages.md).

## 2026-09-12 per-directory view properties

- [x] Remember the mode, the sort key and direction, both zoom steps, grouping, hidden files and previews per directory; restored in a new tab / pane and on a repeat visit.
- [x] A separate default value, a shared policy, and restoring the default for the current directory; versioned storage with a fallback when it is corrupt, and no persistence for logical ZIP pages or temporary paths.
- [ ] Applying recursively to subdirectories, persisting the column layout, following renames / moves by volume and file identity, and dedicated persistence for special logical pages.
- The boxes above mark implementation scope; for this feature's three smoke runs and on-device verification see the [directory view verification record](../research/computer-use-2026-09-12-directory-views.md), which does not carry over the earlier 739-check result.

## 2026-09-12 split-pane paths and the tab menu

- [x] An editable path with completion for each pane, with both sides of the split visible at once; path, history, query and filter are independent.
- [x] A split title in a fixed left-right order, a separate active-pane indicator, custom tab names and a full-path tooltip.
- [x] Seven tab context-menu actions, a fixed target identity, background / bulk closing that keeps the active tab, and a custom name restored when a tab is reopened.
- [x] Detach opens a new window from one or two logical locations, keeping the active side and the search request; tasks and undo stay with the original window.
- [ ] Merging windows, popping out a single pane, and a preference for how much of the tab bar is shown; the launch session restore that was pending at that stage is covered by the new stage below.
- The checkboxes mark this round's implementation scope; for the completion status of the full automated checks and the test on the packaged app see the [dedicated record](../research/pane-paths-and-tab-actions.md), which does not carry over the previous round's 1,253-check result.

## 2026-09-13 workspace session restore

- [x] Reopen the window by default, restore tabs / custom names / selected items in order, both pane locations / active side / ratio, and the sidebar / window geometry and minimized state.
- [x] Logical ZIP addresses, re-running the conditions of searches that had been run, keeping offline paths, and asynchronous errors for ordinary directories.
- [x] The switch disables restore and clears what was saved, a 0.4-second debounce with a synchronous write on exit, corrupt / unknown versions kept until an explicit retry, and inline feedback on failure.
- [x] In the separate session-restore stage the 2,418-check smoke test passed three times in a row, and the build and the packaged app were tested with a real quit / relaunch and with the settings controls; for the evidence see the [session restore record](../research/workspace-sessions.md). The results after this round extended the directory tree are below.

## 2026-09-13 operation customization and open-source distribution

- [x] Customizing and persisting shortcuts for application commands, covering items with no default binding, and keeping the migration of the old Filter shortcut.
- [x] The terminal's startup shell, font / size, theme / text background color, and the toolbar entry point.
- [x] A separate Folders tree next to Places: this implementation sits below it, its height can be dragged, and favorites stay visible.
- [x] The MIT license, the free and open-source statement and our own Homebrew tap configuration; isolated install / uninstall passed.
- [x] The final 3,194-check smoke test over 95 Swift sources passed three times in a row, and the delivered app / DMG, the on-device check and all 29 transparent screenshots were checked; for the stage and its scope see the [customization integration record](../research/customization-integration.md).
- [x] Hiding keeps the terminal alive, with task confirmation on quit / window close / Restart; the 3,329-check smoke test over 101 sources passed three times in a row and the additional on-device verification passed; [lifecycle scope](../research/terminal-session-lifecycle.md).
- [x] The original tap on public main and the stable 0.2.0 release are published, and the download bytes, the signature and the install layout were verified.
- [x] For the 0.2.0 cask and the installation-wording follow-up, the isolated install / uninstall, the website build and the reference check passed; this is the local scope before merging. For the results submitted online see the [Homebrew runs](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml), the [Pages runs](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml) and the corresponding PRs; [release record](../research/release-0.2.0.md).

## 0.2.1 terminal directory following and a simplified status bar

- [x] zsh follows file browsing at a safe prompt; a private data channel preserves shell input, and a hidden terminal still follows. Several terminal sessions at once are still not implemented.
- [x] The terminal keeps only a single row with the title, Start or Restart, and Hide; the directory and error details are surfaced through tooltips and accessibility descriptions.
- [x] All terminal status and its polling in the bottom-right corner is gone, as are the available-capacity text and its filesystem query; the file count, context, zoom and operation progress remain.
- [x] 0.2.1 is released, and the actual assets and signature, the packaged app's launch and the latest version on the production feed were checked; [release verification](../research/release-0.2.1.md).
- The checkboxes mark implementation scope; for the full smoke test, the packaged on-device run and the release results see the [0.2.1 record](../research/terminal-navigation-0.2.1.md); 0.2.0's three runs do not count as this round's verification.

## Two-way terminal directory sync and bash / fish

- [x] Reverse sync: when the shell changes directory the window's active pane follows, only while the panel is visible, and it behaves the same in both file views, in a split and across several tabs; four guards against loops.
- [x] Automatic sync for bash and fish: a temporary `--rcfile` / `--init-command` reads the user's own startup files, and a request takes effect at the next prompt; all three shells report the directory with OSC 7.
- [x] Settings → Terminal has a switch for each direction (both on by default), and the migration of older preferences keeps the shell and the appearance.
- bash and fish do not follow while idle and send no failure reply; for the scope, the evidence and the limits see the [two-way sync record](../research/terminal-shell-sync.md).

## Command palette

- [x] A fuzzy command palette opened with ⇧⌘O, covering every command, the sidebar favorites and the current pane's history directories; commands run with menu semantics, and unavailable commands are listed greyed out. Dolphin has no such feature; it is Tursora's own.
- The visual check of the packaged app is still pending; for the scope and what is inferred see the [command palette record](../research/command-palette.md).

## Sorting, columns, folder sizes and drag and drop

- [x] The sort keys now include Date Created / Date Added / Date Last Opened, consistent across all three entry points; items with no date sort to the bottom in both directions.
- [x] Optional columns in the details view (ticked in the header context menu), persisted per directory; column widths are not persisted, and Version / Comments / Tags are not implemented.
- [x] Folder item counts and optional recursive size calculation, with background cancellation and cache invalidation; ZIP and search results only count items.
- [x] ⌘ to force a move, spring-loaded folders (list / icons / sidebar / folder tree) and drops onto breadcrumb segments.
- Dolphin's "releasing a drag pops up a copy/move/link menu" is still a design choice and is not implemented.

## Trash

- [x] Browsing the user trash, Put Back (our own log), Empty Trash… (Finder's wording plus a confirmation), and an in-pane banner when permission is missing.
- Per-volume trash, and putting back items that were moved in outside Finder, are still not implemented; for the scope see the [trash record](../research/trash.md).

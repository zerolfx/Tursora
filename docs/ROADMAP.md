# Roadmap

The v1 feature set (purely local) is complete: address bar, tabs, split panes, two views with zoom preview, file operations with undo, filtering, grouping, Get Info.
Newer work extends that to ZIP compression / extraction, system sharing, mounting system servers with the matching settings, plus per-directory view memory / a unified default, controllable file-operation tasks, and recursive and saved search; the terminal panel and read-only ZIP browsing in the current pane are enabled by default and can be turned off in Settings. The combined verification status of the three new features is in the [PR integration record](research/pr-integration-2026-09-12.md). What follows is ordered by "what users hit most often, at the lowest cost". The cost scale (S ≤ half a day / M 1–2 days / L 3–5 days / XL > 1 week) and the basis for each item are in the two gap lists:

Implementation and verification status for per-pane address bars, tab titles on both sides and tab context-menu actions are in a [dedicated record](research/pane-paths-and-tab-actions.md); merging windows and popping a pane out on its own are still left for later.

- [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md) — item by item against Finder's menu nib
- [gaps/GAP-vs-DOLPHIN.md](gaps/GAP-vs-DOLPHIN.md) — against the actions / panels / settings Dolphin registers

## Completed stage: 0.2.1 directory following and a simplified interface

- [x] Through a private request / FIFO, zsh follows the currently active pane at an empty primary prompt; a running program, read, a line continuation and uncommitted input are never interrupted, and hiding the panel keeps both the session and the sync channel. Other shells still need a manual Restart, and there is no reverse sync.
- [x] The top of the terminal became a single-row action bar; every terminal status, icon, animation, timer and poll at the bottom was removed, along with the status bar's available capacity and the query behind it, keeping the item / selection counts, filtering, search, ZIP, zoom and file-operation progress.
- [x] The website defaults to English, with a separate Chinese page reached through an ordinary link; the two pages share screenshots, installation steps and interactions, and the app's interface is still English.
- [x] 102 source files passed 3,435 checks on three consecutive runs, and the packaged app, directory following, hidden tasks and cancelling a quit were verified hands-on; 0.2.1 is released, and the actually downloaded files plus the production update check are in the [release verification](research/release-0.2.1.md).
- The ticks above mark implementation scope; this round's full smoke run, hands-on testing of the package, screenshots and release progress are in the [0.2.1 record](research/terminal-navigation-0.2.1.md), and the static / browser / deployment scope of the bilingual site is in the [site notes](../site/README.md); check counts from older versions are not reused.

## Completed stage: terminal sessions and the 0.2.0 release

- [x] Collapsing or disabling the entry point keeps the window's terminal alive; quitting, closing the window and Restart all confirm running tasks, and cancelling a quit preserves transfers and the workspace. The bottom-right status and its polling from that stage were removed in 0.2.1; session retention and the confirmations remain in effect. 101 source files passed 3,329 smoke checks on three consecutive runs plus hands-on verification, see the [lifecycle record](research/terminal-session-lifecycle.md).
- [x] Three smoke runs over the new sources, hands-on testing of the package and real General / Terminal screenshots are done; 0.2.0 is released, and re-downloading the assets plus the signature and layout verification passed, see the [release record](research/release-0.2.0.md).
- [x] The 0.2.0 cask and the installation-copy follow-up are prepared, and isolated install / uninstall, the site build and the reference check all passed. This tick covers the local scope before merging; the state of the upstream submissions is in [Homebrew runs](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml), [Pages runs](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml) and the matching PRs; downloading, installing and restarting the older version from the production feed is still recorded separately.

- [x] The terminal entry point and ZIP browsing are enabled by default, with the switches kept; ZIP preparation can be cancelled and a failure retried, and the terminal's directory / exit status were filled in during that stage, see the [historical record](research/default-features-polish.md); today's compact title bar and directory sync are covered by the 0.2.1 scope at the top of this page.

## Completed stage: action customization and directory navigation

- [x] Shortcuts for every app command can be searched, recorded, cleared and reset, while the native text / shell controls are preserved; [scope and verification](research/custom-shortcuts.md).
- [x] Terminal shell, monospaced font / size, appearance and custom text / background colors; expanding and collapsing straight from the toolbar; [implementation and limits](research/terminal-customization.md).
- [x] A separate Folders directory tree below Places, following the active pane, reading a single level in the background and remembering the session's layout; [Dolphin evidence](research/folder-tree.md).
- [x] The MIT license and the free, open-source wording, our own Homebrew cask, and local install / uninstall verification; the original 0.1.0 cask shipped with main, and the 0.2.0 follow-up is above.
- [x] The final 95 Swift source files passed 3,194 smoke checks on three consecutive runs, and the delivered app / DMG checks, hands-on use of the packaged app and the transparency pass over all 29 screenshots passed; the [customization integration record](research/customization-integration.md) records the scope, while remote CI / release are still handled separately.

## Completed: work continuity

Following user feedback, session restore was moved ahead of filling in the smaller features. This round restores windows, multiple tabs and two-pane workspaces by default, preserving the active location, names, split ratio, sidebar and window layout; Settings can turn it off and clear what was saved. An executed search is re-run, a missing directory keeps its original path, and terminals, transfers and undo operations are not replayed. **This round's build, 2,418 smoke checks on three consecutive runs and a real quit / restart of the packaged app are all verified**, and the exact scope is collected in the [session restore record](research/workspace-sessions.md). Whether to extend this to selection / scroll position, navigation history and remembering closed tabs should be assessed separately and is not part of what this round completed.

## Next batch (S, under half a day each)

Deselect All, Move Items Here (⌥⌘V), aligning the Copy as Pathname shortcut, New Folder with Selection, Show Package Contents, Always Open With, Print, Slideshow, Eject All, the standard folder shortcuts in the Go menu, Cycle Through Windows, the Services menu, Finder alias resolution, invert selection, open in Terminal.

## After that (M)

Batch rename, Make Alias / Show Original, Recent Folders, a preview pane on the right (reusing Get Info's FileInfo), Customize Toolbar, Toolbar / Path Bar / Status Bar / Tab Bar switches, Show All Tabs, Move Tab to New Window / Merge, spring-loaded folders, the warning when changing an extension, Paste Exactly, Show Clipboard, Add to Dock, a preset of Finder's default shortcuts (individual commands can already be customized one by one), a list of recently closed tabs, additional information columns, folder item-count / recursive-size columns.

## Agreed next, 2026-09-15

Chosen by the owner after comparing against Iruka. In order:

1. **Batch rename: the `#` placeholder.** KIO's Enumerate semantics — one run of `#` is replaced in place by the index and its length sets the zero padding, so `Photo ###.jpg` gives `Photo 001.jpg`. It subsumes Name and Index (`name #`) and Name and Counter (`name #####`) and adds free placement and padding, so Format collapses from three kinds to two: Number and Date. Date stays because `#` cannot express a timestamp and dropping it would regress a shipped 0.3.0 feature. The existing full-list live preview is kept — KIO shows only one read-only line, so this is a place Tursora is already ahead. Closes the deviation recorded in [GAP-vs-DOLPHIN](gaps/GAP-vs-DOLPHIN.md) line 36.
2. **A docked preview pane, with Markdown rendered.** Markdown rendering is a condition of the pane, not a follow-up: Quick Look shows Markdown as plain text. Syntax highlighting for code is explicitly excluded. The pane must dock beside the file view rather than float like the Inspector, survive navigation, and persist in `WorkspaceSession`; ⇧⌘P is taken by Show Previews and has to move first.
3. **Column view.** A third `FileViewing` conformer, with the per-mode zoom ladder and a store migration it drags along. ⌘3 is taken by tab selection, so the binding is ⌥⌘3.
4. **Content search that does not need an index.** Searching file contents where Spotlight has no index.

## Big items (L)

Column view, Gallery view, fuller preferences (confirmation policy and so on), free icon placement, a Trash view (needs Full Disk Access), Quick Actions, Chinese localization, docking / floating panels anywhere, server history / discovery / reconnect, multiple terminal sessions and terminal session restore. The core persistence of per-directory view attributes is implemented; the full Show View Options dialog, persisting the column layout and applying recursively are still to do.

## Not doing / waiting for a public API

Tags, Import from iPhone (explicitly excluded by the product design); Customize Folder (private storage), Finder `.savedSearch` interchange (in-app saved searches already exist), FinderSync badges (only iCloud is public), the desktop, selection mode.

Excluded by the product design, 2026-09-15: **git in any form** — branch state, staging, commits, or a diff review pane; and **developer-only remote access** — SFTP and SSHFS mounts, SCP transfers, S3 buckets, and "mount as root". Tursora is a file manager for everyday use, not a development console, and these carry credential handling and background-daemon problems out of proportion to their audience. Ordinary remote volumes stay supported and are unaffected: `ServerConnection` already mounts `smb://`, `nfs://`, `afp://` and `http(s)://` WebDAV through macOS itself. Comparing two arbitrary files or folders is **not** covered by this exclusion and remains open.

Also excluded, 2026-09-15, after comparing against Iruka: **Intel support** — Tursora ships Apple Silicon only and a Universal binary is a deliberate non-goal, so the arm64-only build in `app/tools/make-app.sh` and the `lipo -archs` assertion in CI are correct rather than a limitation to fix; **in-place text and code editing** — Tursora browses and manages files, it does not edit their contents; and **syntax highlighting** for code previews. Markdown rendering is *not* excluded: it is a condition of the preview pane below.

## Follow-up verification for the new features

- Per-task progress and pause / resume / cancel for copy / move / Duplicate are implemented; the dedicated automation and hands-on records are in [file operation tasks](research/file-operation-tasks.md). The cross-volume failure branch can be verified by injection, while dedicated hands-on tests on a real separate volume and a real server should each be recorded separately; cancelling the ZIP compression / extraction tools, recovering tasks after a crash, and turning Trash / delete into tasks are still not implemented.
- Per-directory view attributes use an app-private, path-keyed store; the three smoke runs, the package signing and the hands-on evidence produced after the standalone branch synced `ae5e47a` are in the [directory view verification record](research/computer-use-2026-09-12-directory-views.md), and the combination of the three features cannot reuse that check count. Later items include applying recursively to subdirectories, the column layout and attributes specific to logical pages; following a directory after a rename / move, or restoring across mount points, would require volume identity and bookmarks to be assessed separately, rather than quietly turning this path-keyed behaviour into inode following. Session restore uses its own store, and this round's verification is at the top of this page.

- When a user provides a server, verify authentication, read / write and disconnection for SMB / NFS / WebDAV / legacy AFP; so far only the system mount interface and the state transitions without a network have been verified.
- [0.1.0](https://github.com/zerolfx/Tursora/releases/tag/v0.1.0) is released; its ZIP checksum, signature, version, architecture and isolated-install verification are in the [Homebrew history](research/homebrew.md#local-verification-of-the-initial-010-cask-historical). A first install / launch of the downloaded artifact on another machine is still unverified; hands-on testing of a locally built package from the same source does not replace that check.
- GitHub Actions succeeded this round, but the v4 versions of checkout / upload-artifact produced a Node 20 runtime deprecation notice; upgrading those actions and verifying the build and release flow is a separate follow-up.
- The terminal's shell / font / color settings are implemented; further coverage of more third-party shells, full-screen programs, real multi-display layouts and long-running use is still to come. zsh already follows file navigation one way at a safe prompt, while automatic sync for other shells and two-way sync are still not implemented; the implementation and this round's verification are in the [0.2.1 record](research/terminal-navigation-0.2.1.md). Retention while hidden and the Restart task confirmation are in the [lifecycle record](research/terminal-session-lifecycle.md).
- Ghostty has been investigated from its official source and is left as a separate prototype for after 0.2.0: comparing Chinese input, complex TUIs, scrolling / redraw, and CPU / memory against the current SwiftTerm (and its optional experimental Metal path). The public VT library does not include drawing, the full Metal interface is still marked internal, and it cannot be dropped in as a stable Swift control; [evidence and scope](research/ghostty-embedding.md).
- Use the [documentation index](README.md) to find the verification record for a given version and feature; the early ZIP interaction evidence is in the [historical hands-on record](research/computer-use-2026-09-12-inline-zip.md); historical results do not replace the checks after this merge. Dedicated CUA passes for the drag-out-of-archive gesture, Quick Look / Share inside an archive, and existing pages after the switch is turned off can still be added.
- ZIP browsing still stages the whole archive; the space and responsiveness for large archives need further assessment. Password-protected archives, other formats, reloading automatically after the original ZIP changes externally, and writing back into an archive are not implemented.

## Known small gaps

- ⌘W does not close the Settings window; a window-level close command and a matching regression check still need to be added; found during this round's CUA pass on 2026-09-12.

- With a very narrow split or the largest icon size, the smoke test emits a layout warning that the collection-view item width exceeds the available width; a dedicated visual check and a layout regression check still need to be added (2026-09-12).

- The Return/Enter branch `case 36, 76 where plain` in the list and icon views produces a compiler warning: `plain` only constrains Enter; the Return path with modifier keys needs its own regression check (found during a build on 2026-09-12).
- A browser pane loses the selection after an **external** rename (the Info window can follow by inode, a pane cannot yet).
- Folder size in the Info window does not update live as the contents change (to avoid an FSEvents storm).
- The Size bucket boundaries and the Kind group order used by grouping are still inferred.

## Search limits and follow-ups

- Standalone recursive name search, Spotlight content search, AND conditions on type / date, and persisted saved searches are implemented. See [research and verification](research/search.md).
- Broader scopes and incremental live results will be assessed later; Finder `.savedSearch` interchange, searching inside ZIPs, and ratings / tags are out of scope for this round. Unindexed content still depends on the user's system indexing settings, and the app does not build its own full-text index. Both a single result set and the Spotlight candidates are capped at 50,000 items; a real positive content-search hit is still to be verified separately.

- Still to assess: the order of the sources when moving / deleting with a symbolic link and `link/child` both explicitly selected, since moving the link first invalidates the descendant path. Search does not traverse links, so this round's search results cannot produce that combination; an ordinary expanded view or the clipboard still can.

- Folders locates entries under the Home root by a directory's actual spelling; when a valid path is typed in with different casing, file browsing works, but making the tree selection follow still requires handling the volume's real file identity, and cannot simply lower-case every path.

# Shortcuts, menus and gestures

File Operations is available from the Window menu. Long transfers open its task window automatically; each row has Pause / Resume / Cancel and inline conflict choices. Closing this task window hides it. Closing the originating browser window cancels its active transfers and waits for cleanup; quitting does the same for all transfers. No new key binding is assigned.

Everything the user can press or click, as implemented. Main menu items use `nil` targets so the responder chain picks the handler; Dock items explicitly target the application delegate (see [ARCHITECTURE.md §4](ARCHITECTURE.md)). Where a binding deliberately follows Dolphin or Finder, it says so; the planned changes are in [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md).

## Customizing application shortcuts

**Settings → Shortcuts** lists every application menu command, including commands with no default shortcut, and all extra file-view/window keyboard actions. Search by command or menu category, select a row, click the recorder and press a combination. **Clear** removes the binding; **Reset** restores that row; **Reset All Shortcuts** restores the entire catalog. Settings, Terminal, tab selection, navigation, file operations, search, view/group/sort commands and application commands all participate. The tables below show factory defaults; current menu labels and toolbar hints reflect saved choices.

Conflicts identify the current owner and keep the previous value. Clear or change that owner first. Resetting one row also rejects a conflict; Reset All can always restore a consistent default set. The old custom Filter binding is retained on upgrade. Settings are global, persist between launches and take effect in open windows, tabs and panes.

Command or Control combinations and function keys can be recorded; the File View alternatives additionally accept Return, Tab, Space and Escape combinations. Plain Escape cancels recording, so use Reset to restore an Escape default. Known macOS-reserved shortcuts are rejected. The recorder uses the active keyboard layout for characters, displays named special keys, and checks equivalent combinations using the current keyboard layout without rewriting literal punctuation. For example, Plus and Shift–Equals conflict on a US layout, but remain distinct when another layout places Plus on an unshifted key.

Command bindings use AppKit's normal menu validation and responder chain, including standard editing commands in text fields. Control-only and function-key bindings pass through to text fields and SwiftTerm while typing, except the configured **Show/Hide Terminal** command, which remains available from the shell. File View alternatives only act while the list or icon view has focus. Native text editing, filename/path completion, arrow selection, dialog confirmation/cancellation, shell/readline controls and mouse/trackpad gestures remain owned by those native views; this catalog customizes Tursora's application commands.

Return/Enter rename and Space Quick Look are separately listed alternatives to their menu commands. Control-Tab, Control-Shift-Tab, the nine tab positions and Command-Equals also have individually editable rows. Clearing a primary menu binding does not silently clear a separately listed alternative. **Use Groups** retains Control-Command-0; **Group By → None** has no factory binding, removing the former duplicate.

## Dock menu

Right-click the running app's Dock icon for **New Window**, **Downloads** or **Applications**. Each opens a fresh window at its fixed destination and activates the app. Existing panes, tabs and searches stay in place. Standard window and application items are supplied by macOS. No new shortcut is assigned.

## Menu bar (`MainMenu.swift`)

### Tursora
| Item | Shortcut | Handler |
|---|---|---|
| About Tursora | — | `NSApplication` |
| Settings… | ⌘, | `AppDelegate.showSettings`; applies changes immediately |
| Check for Updates… | — | `AppDelegate.checkForUpdates` → shared `AppUpdater`; enabled while the packaged updater can accept a manual check, including when automatic checks are off |
| Hide Tursora / Hide Others / Show All | ⌘H / ⌥⌘H / — | `NSApplication` |
| Quit Tursora | ⌘Q | `NSApplication`; `AppDelegate.applicationShouldTerminate` cancels and waits for active transfers; `applicationWillTerminate` flushes the directory-view library, saves Info edits and releases owned resources |

### File
| Item | Shortcut | Icon | Does | Handler |
|---|---|---|---|---|
| New Window | ⌘N | `plus.rectangle` | New window at home, cascaded | `AppDelegate.newWindow` |
| New Tab | ⌘T | `macwindow.badge.plus` | Fresh single-pane tab at the active location; reruns its search when applicable | `MainWindowController.newTab` |
| New Folder | ⇧⌘N | `folder.badge.plus` | "untitled folder" (then " 2", …), selected | `BrowserViewController.newFolder` |
| Open | ⌘↓ | — | Opens the selection; disabled when empty | `MainWindowController.openSelection` |
| Quick Look | ⌘Y | `eye` | Toggles `QLPreviewPanel` | `BrowserViewController.quickLook` |
| Get Info | ⌘I | `info.circle` | One window per item (>10 → summary) | `InfoWindowController.show` |
| Show Inspector (⌥ alternate) | ⌥⌘I | `info.circle` | Floating panel following the selection | `InfoWindowController.showInspector` |
| Get Summary Info (⌃ alternate) | ⌃⌘I | `info.circle` | One window for all items | `InfoWindowController.showSummary` |
| Rename | — | `pencil` | Inline rename; enabled for exactly one item | `BrowserViewController.renameSelection` |
| Duplicate | ⌘D | `plus.square.on.square` | Undoable | `BrowserViewController.duplicate` |
| Compress / Extract | — | `doc.zipper` | ZIP creation/extraction with undo; also in More and context menus | `MainWindowController` → active `BrowserViewController` |
| Move to Trash | ⌘⌫ | `trash` | Undoable; selects the next item (Dolphin; Finder selects nothing) | `BrowserViewController.moveToTrash` |
| Delete Immediately… | ⌥⌘⌫ | `trash` | Confirmation, then unrecoverable | `BrowserViewController.deletePermanently` |
| Close Tab | ⌘W | — | Title flips to "Close Window" with one tab | `MainWindowController.closeTab` |
| Close Window | ⇧⌘W | — | | `NSWindow.performClose` |
| Reopen Closed Tab | ⇧⌘T | — | Up to 10 closed tabs kept whole (history + split + custom name) — Finder uses ⇧⌘T for the tab bar | `TabsController.reopenClosedTab` |

### Edit
| Item | Shortcut | Icon | Does |
|---|---|---|---|
| Undo / Redo | ⌘Z / ⇧⌘Z | `arrow.uturn.backward` / `.forward` | Window undo manager; each file operation is its own group |
| Cut | ⌘X | `scissors` | App-wide cut state; cut rows drawn at 0.45 alpha |
| Copy / Paste | ⌘C / ⌘V | `document.on.document` / `document.on.clipboard` | Paste = move if the pasteboard still matches the cut, else copy |
| Select All | ⌘A | `character.textbox` | |
| Copy to Other Pane / Move to Other Pane | ⇧⌘C / ⇧⌘M | — | Split only (Finder uses ⇧⌘C for Computer) |

### View
| Item | Shortcut | Icon | Does |
|---|---|---|---|
| as Icons / as List | ⌥⌘1 / ⌥⌘2 | `square.grid.2x2` / `list.bullet` | Swaps grid/outline, keeps selection and focus (Finder: ⌘1/⌘2; ours are taken by tabs) |
| Zoom In / Zoom Out | ⌘+ / ⌘- (⌘= also) | `plus.magnifyingglass` / `minus.magnifyingglass` | Steps the per-mode ladder (icons 32…512, list 16…64) |
| Actual Size | ⌘0 | — | 64 pt icons / 16 pt rows |
| Show Previews | ⇧⌘P | — | Thumbnails from 32 pt up (Finder's ⇧⌘P is the preview pane) |
| Filter | ⌘F | `magnifyingglass` | Focuses the toolbar name-filter field; checkmark while filtering |
| Search… | ⇧⌘F | `doc.text.magnifyingglass` | Expands recursive search options beside the existing toolbar query; unavailable inside ZIP locations |
| Show Hidden Files | ⇧⌘. | — | Saved by the selected folder-view policy; transient in ZIP and search pages |
| Reload | ⌘R | `arrow.clockwise` | (Finder: Show Original) |
| Use Groups | ⌃⌘0 | `square.grid.3x1.below.line.grid.1x2` | Off → back to the last key (Kind first) |
| Group By ▸ None · Name · Kind · Application · Date Last Opened · Date Added · Date Modified · Date Created · Size | — · ⌃⌘1 · ⌃⌘2 · — · ⌃⌘3 … ⌃⌘7 | `arrow.up.arrow.down` | Same submenu as the toolbar Group button |
| Sort By ▸ Name / Date Modified / Size / Kind · Ascending | — | — | Driven through the table so the header arrow stays in sync |
| Folder View Settings ▸ Remember Each Folder / Use One View for All Folders | — | — | Selects per-directory memory (default) or the existing shared default; also in Settings |
| Folder View Settings ▸ Use Current Settings as Default | — | — | Saves the active ordinary folder's complete view properties as the default; existing customized folders keep their records |
| Folder View Settings ▸ Restore This Folder to Default | — | — | Removes this folder's override and reapplies defaults; ordinary folders in per-directory policy only |
| Split View | ⇧⌘D | `rectangle.split.2x1` | Title becomes "Close Left/Right Pane" while split (Dolphin's toggle; Finder: ⇧⌘D = Desktop) |
| Focus Other Pane | ⌥⇥ | — | Split only |
| Show Sidebar | ⌃⌘S | `sidebar.leading` | (Finder: ⌥⌘S) |
| Show Folders | F7 | `list.bullet.indent` | Shows the optional directory tree alongside Places |
| Show / Hide Terminal | F4 | — | Present only when Terminal panel is enabled in Settings; hiding retains the session |

### Go
| Item | Shortcut | Icon |
|---|---|---|
| Back / Forward | ⌘[ / ⌘] | `chevron.backward` / `chevron.forward` |
| Enclosing Folder | ⌘↑ | `arrow.up.folder` (selects the folder you left) |
| Home | ⇧⌘H | `house` |
| Edit Location | ⌘L | — (Finder: Make Alias) |
| Go to Folder… | ⇧⌘G | `arrow.forward.folder` (opens the breadcrumb's edit mode, like ⌘L) |
| Connect to Server… | ⌘K | `rectangle.connected.to.line.below` |

### Window
Minimize ⌘M · Zoom · Show Previous Tab ⇧⌘[ · Show Next Tab ⇧⌘] (disabled with one tab) · File Operations (reopens task controls) · Bring All to Front. Help is empty.

## Context menus (`BrowserViewController.buildContextMenu`)

Targets: the selection if the clicked row is in it, otherwise the clicked row alone (Finder). Sidebar commands retain the right-clicked place even after menu tracking ends; Open in New Tab / Other Pane does not first select or navigate the source pane. The table below describes ordinary directories. Read-only ZIP pages offer Open / Open With, folder navigation, Quick Look, Copy / Copy to Other Pane, Copy Path, Reload, hidden-file visibility and sorting; writable file actions, editable Info and Favorites changes are omitted.

| Where | Items |
|---|---|
| Background (no item) | New Folder · Get Info · Paste (enabled only with file URLs on the pasteboard) · — · Reload · Show Hidden Files ✓ · Sort By ▸ · — · Add/Remove from Favourites (current folder) |
| A file | Open · Open With ▸ (default app first, "(default)", separator, up to 20 apps with icons; "No Applications" when none) · [split: Copy/Move to Other Pane] · — · Quick Look · Get Info · Rename · Duplicate · Move to Trash · — · Cut · Copy · — · Copy Path |
| A folder | Open · Open in New Tab (or "Open in N New Tabs") · Open in New Window · Open in Other/New Pane · then the file block · — · Add/Remove from Favourites |
| Several items | As above minus Open With and Rename; "Copy Paths" |
| Sidebar (`SidebarViewController`) | Open · Open in New Tab · Open in Other Pane · [removable: Remove from Favourites · Reset Favourites] · [volume: Eject "name"]; empty when no row was clicked |
| Tab | New Tab · Detach Tab · — · Rename Tab · — · Close Other Tabs · Close Tabs to the Left · Close Tabs to the Right · Close Tab; middle-click closes |

## Keyboard in the file views (`FileOutlineView` / `FileCollectionView`)

| Key | Effect |
|---|---|
| Return / Enter | Rename the one selected item; disabled inside read-only ZIPs (Finder; Dolphin uses F2). See [DECISIONS.md](DECISIONS.md) D3 |
| Space | Toggle Quick Look |
| ⌘↓ / ⌘↑ | Open the selection / enclosing folder |
| Arrows | Selection; inside the Quick Look panel ←→↑↓ are forwarded to the view so previews browse |
| Type-select | List view only |
| ⌘⌫ / ⌥⌘⌫ | Trash / delete immediately |
| Esc while renaming | Both views cancel the edit and restore the original filename, even after typing a different valid name |

## Address bar and completion (`BreadcrumbBar`, `CompletionPopup`)

Each pane has its own visible address bar above its search and file content. Clicking a bar activates its owner; navigation and completion remain bound to that pane. `⌘L` / `⇧⌘G` focus the active pane's bar. Switching panes or tabs dismisses the departing edit and popup without submitting unconfirmed text.

| Input | Effect |
|---|---|
| ⌘L / ⇧⌘G / click on empty bar space | Edit mode, path selected; placeholder "Type a folder path — ⌘L" |
| Typing | Inline completion filled only while typing forward, tail selected; candidate list (max 8 rows) below the field |
| ⇥ / ⇧⇥ | Accept the offered completion; otherwise normal focus move |
| → | Accept the inline tail if present |
| ↓ / ↑ | Move the popup selection, wrapping |
| Return | Accept a pending completion, then navigate; non-folder → beep |
| Esc | Hides the popup if open, otherwise leaves edit mode |
| Click a segment / `›` / `…` | Navigate / subfolder menu with the current child ticked ("No Subfolders" when empty) / menu of the folded-away segments |

## Tabs and split view

| Input | Effect |
|---|---|
| ⌃⇥ / ⌃⇧⇥ | Next / previous tab (window-level key monitor; no menu item can express ⌃⇥) |
| ⌘1 … ⌘8, ⌘9 | Jump by index; ⌘9 = last tab (Dolphin) |
| ⌘T / ⌘W / ⇧⌘T / ⇧⌘[ / ⇧⌘] | New / close / reopen / previous / next |
| Middle-click a tab | Close |
| Middle-click or ⌘-double-click a folder | Open in a background tab |
| Drag a tab | > 4 px reorders; dragged below the strip it becomes a split drop: left 35 % / right 65 % of the content area splits the current tab with that tab's pane, the middle band cancels |
| Toolbar Split View / ⇧⌘D | Split (second pane at the same folder) or close the **active** pane; toolbar state follows the current tab and its tooltip identifies the pane that will close |
| ⌥⇥ | Focus the other pane |
| Click anywhere in a pane (incl. its status bar) | Activates it; a 3 pt accent bar marks the active pane. Panes stay ≥ 160 pt and never collapse |

Closing a background tab preserves the current tab; closing the current tab prefers its right neighbor and falls back to the left. The strip stays visible with one tab; the `+` button's tooltip is "New Tab (⌘T)"; a tab's close button shows on hover. Split titles show both sides in physical order as `Left | Right`, unchanged when pane focus moves. A custom name overrides the title; tooltips retain full logical paths.

Right-clicking a tab opens the following Dolphin-inspired actions without first switching tabs. Each command captures the clicked page, so reordering tabs cannot change its target. The `+` button and `⌘T` use the same New Tab behavior for the current page, including rerunning a search. Opening an explicit folder in a new tab opens that folder. No additional shortcuts are assigned.

| Item | Effect / availability |
|---|---|
| New Tab | New activated single-pane tab at the clicked tab's active location; restarts its search request when applicable; disabled while that pane prepares a ZIP |
| Detach Tab | Reopen the clicked tab's one or two logical locations in a new window, keeping active side, custom name and searches, then close the original tab; disabled while either pane prepares a ZIP |
| Rename Tab | Change the tab name, not the folder name; an empty name restores the automatic title |
| Close Other Tabs | Keep the clicked tab; disabled when no others exist |
| Close Tabs to the Left | Close only the tabs before the target; disabled at the left edge |
| Close Tabs to the Right | Close only the tabs after the target; disabled at the right edge |
| Close Tab | Close the target; the last tab uses normal window close |

Detach starts fresh navigation histories, selections, filters and scroll positions. File transfers and undo history stay with the original window; closing that window cancels its active tasks and waits for cleanup. Closing and reopening an ordinary tab still restores its retained full page. Menu order and upstream differences are recorded in [the source comparison](research/pane-paths-and-tab-actions.md).

## Mouse and trackpad

| Gesture | Effect |
|---|---|
| Double-click | Open |
| Mouse buttons 4/5 | Back / forward (window-level monitor) |
| Two-finger page swipe | Right-to-left = forward, left-to-right = back |
| ⌘-scroll (≥ 8 accumulated) / pinch (≥ 0.12) | Zoom (stands in for Dolphin's Ctrl-wheel) |
| Status-bar slider | Zoom steps; tooltip "Icon size (⌘-scroll or pinch to zoom)" |
| Single click on the **name** of the sole selected row (list) | Rename after `NSEvent.doubleClickInterval`; cancelled by a double-click, a drag session, pointer travel > 3 pt, or a selection change |
| Toolbar back/forward | Click navigates; 0.35 s long-press or right-click shows the history menu |
| Right-click in the grid | Selects the clicked item if it wasn't selected |
| ⌘-click the title-bar proxy icon | Path menu (free via `window.representedURL`) |

## Drag and drop (`FileListViewController.dropOperation`, shared by grid, sidebar, tab strip)

- ⌥ held (source mask `.copy`) → **copy**, always.
- Otherwise **same volume → move, different volume → copy** (Finder's rule).
- Dropping items into the folder they already live in, or onto themselves → no-op.
- Targets in the list: a folder row, the gap between an expanded folder's children (= that folder), or the listed directory. The grid highlights a folder icon or the whole grid — never an insertion line.
- Source masks: ordinary files use local `[.copy, .move]` and external `[.copy, .move, .link]`. Read-only ZIP entries offer `.copy` only, including on the same volume. Archive panes and their tab targets reject incoming file drops.
- Sidebar: files onto a place follow the same rule; folders dropped **between** favourites are added there; dragging a favourite reorders it; volumes can't be dragged.
- Tab strip: hovering a tab with a drag activates it after **0.8 s** (`TabBarView.autoActivationDelay`, Dolphin); dropping on a tab lands in that tab's active pane; dropping on empty strip space opens each folder as a background tab.
- Cross-tab and cross-pane drags work; the source pane refreshes through `DirectoryChanges`.

## Filter (`MainWindowController`)

The configured filter shortcut (⌘F by default) focuses the toolbar field, expanding it via `beginSearchInteraction` when folded to an icon. Typing filters names live; the status bar shows "N of M items". Non-empty input reveals a pane-local Search Options entry for recursive conditions. Esc or ⓧ clears the filter and returns focus to the file view; leaving the field keeps a non-empty filter. It is per pane and clears on directory change. Filtering uses complete filenames even when extensions are hidden; it does not recursively search folders or file contents.

## Settings, terminal and ZIP browsing

Settings (⌘,) has **General**, **Shortcuts**, **Terminal** and **Updates** tabs and initially selects General. General offers startup workspace restoration, extension-label display, Folder View Settings, terminal access and ZIP browsing; both features are enabled by default. Folder View Settings chooses Remember Each Folder or Use One View for All Folders; the View submenu also saves the current view as default and restores a folder. Save errors appear inline with a retry action. The complete keyboard catalog is in Shortcuts; Terminal configures shell, font, font size and colors.

Updates provides **Automatically check for updates** (daily, default on), **Automatically download and install updates** (default off), **Check for Updates…**, and the last-check status. Disabling automatic checks disables the automatic-installation control without clearing its saved choice; manual checking remains available. Existing downloaded or deferred-install updates are not cancelled by changing these preferences. Startup failures appear inline and disable unavailable controls; bare debug binaries and smoke runs do not start Sparkle. No new keyboard shortcut is assigned to updating.

With **Terminal panel** enabled, F4 toggles a window-wide panel below the file panes. The bottom-right **Terminal** status button and toolbar button use the same action. Only the current tab's rightmost pane shows this window-wide status, including while the terminal is hidden; narrow panes show its icon with the full tooltip. Initial, running/hidden, task-count, ended/error and unknown states do not start a shell by themselves. Task counts refer to detected processes, not parsed shell jobs.

First opening starts an interactive shell in the active folder; inside a ZIP, it uses the original ZIP's containing folder rather than a temporary snapshot. The header distinguishes **Started in** from a reported **Shell folder** and preserves the ended state after exit. Navigation shows the destination for **Restart in Current Folder**; it never types `cd` into the running session. F4, the toolbar toggle and the panel close button only hide the terminal; show it again to resume the same shell and output. Disabling terminal access in Settings hides existing sessions without stopping them; re-enable it to show them again.

Restart, window close and application quit stop their owned sessions. Foreground, background or stopped jobs, and activity that cannot be established, require confirmation with **Cancel** as the default. Cancel leaves the session and current work intact. Application quit checks hidden terminals in every window before saving the final workspace or cancelling transfers. Sessions are not restored after quitting; detection limits and verification are in the [lifecycle record](research/terminal-session-lifecycle.md).

With **Browse ZIP archives** enabled, normal Open/double-click enters a ZIP in the current pane. ⌘↓ / double-click opens the selected entry; ⌘↑ goes up, returning from the ZIP root to its containing folder and selecting the ZIP. ⌘[ / ⌘] navigate history. ⌘L, breadcrumbs, tabs, splits, list / icon view, grouping, sorting and current-directory name filtering use the ordinary pane controls, with logical paths under the source ZIP. Each archive navigation starts from the saved default view; changes remain temporary and never write directory records or defaults. Return does not rename archive entries.

⌘C and copy-only drag-out can take archive files into a regular folder; ⇧⌘C requires a writable opposite pane. Space / ⌘Y previews readable copies, and Share uses the same temporary content. Archive pages disable mutation commands, incoming drops, and editable Info / Inspector. The status bar shows `ZIP · Read-only`, with temporary-copy and Save As details in its tooltip. External edits do not update the ZIP; copies stay until Tursora quits. Turning ZIP browsing off leaves existing archive pages and history read-only, while newly opened ZIPs in regular folders extract beside the original. Explicit Extract remains available for a ZIP selected in its containing folder; there is no separate Extract All button. While preparing a ZIP, Cancel or Escape with file-view focus stops this pane’s opening request; Back also cancels. Failure shows Retry and Open Enclosing Folder; Reload (⌘R) retries the requested ZIP, including failed startup restoration.

## Get Info (`InfoWindowController`)

⌘I opens one window per item and re-fronts an existing one; past 10 items it falls back to the summary window (Finder). ⌃⌘I makes a single "Multiple Item Info" window (one item falls back to ⌘I). ⌥⌘I opens the floating Inspector, which follows `.tursoraSelectionChanged` from the active pane and shows summary mode for several items. Targets are the selection, or the current folder when nothing is selected. Info windows take key but never main; they open with nothing focused. Inside: Return or focus-out in the name field renames (undoable with ⌘Z in that window); the Locked, Hide extension and privilege controls apply immediately; comments save on focus-out, close and quit.

## Toolbar actions

- More (ellipsis): New Folder, Open, Get Info, Quick Look, Rename, Duplicate, Copy, Paste, Move to Trash. Commands target the active pane even while the sidebar has focus.
- Share: the system sharing picker for selected files, using validated temporary copies inside a ZIP; disabled without a readable selection.
- Toggle Sidebar: fixed leading button; Show/Hide Sidebar (`⌃⌘S`) performs the same action.
- Split View: toggle alongside the view controls; selected when the current tab has two panes. Its tooltip and overflow menu read Close Left/Right Pane while split, following the active pane; it uses the same action as ⇧⌘D. Sidebar Open in Other Pane creates a split when needed, otherwise navigates and activates the opposite pane.
- Filter by Name: current-folder substring/wildcard filtering; non-empty input reveals Search Options.
- Compress: File / More / selection context menu. Name includes the single filename or selection count.
- Extract: File / More / ZIP context menu in ordinary directories; normal ZIP Open also extracts while ZIP browsing is off. Compress and Extract support Undo / Redo.

## Search

`⇧⌘F` (View → Search…) or Search Options after filtering expands the active pane’s recursive conditions while retaining the same toolbar query field. Filter defaults to `⌘F`; both Filter and Search bindings can be changed in Shortcuts. Queries run after a 500 ms typing pause or immediately on Return; Cancel / Clear / Close Search controls are pane-local. Completely empty conditions do not scan the tree. Escape or the toolbar cancel button returns to the folder. Inline Save / Saved Searches / Open / Delete manage the app-wide list of saved conditions; opening one runs it only in the active pane. Search is unavailable inside ZIP locations. While results are active, Folder View Settings cannot save the result view as a default or reset the originating folder; Close Search restores that folder’s current saved view.

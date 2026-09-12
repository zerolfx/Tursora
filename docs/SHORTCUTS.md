# Shortcuts, menus and gestures

Everything the user can press or click, as implemented. Menu items use `nil` targets, so the responder chain picks the handler (see [ARCHITECTURE.md §4](ARCHITECTURE.md)). Where a binding deliberately follows Dolphin or Finder, it says so; the planned changes are in [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md).

## Menu bar (`MainMenu.swift`)

### Tursora
| Item | Shortcut | Handler |
|---|---|---|
| About Tursora | — | `NSApplication` |
| Settings… | ⌘, | `AppDelegate.showSettings`; applies changes immediately |
| Hide Tursora / Hide Others / Show All | ⌘H / ⌥⌘H / — | `NSApplication` |
| Quit Tursora | ⌘Q | `NSApplication`; `AppDelegate.applicationWillTerminate` closes Info windows so a half-typed comment is saved and flushes the directory-view library |

### File
| Item | Shortcut | Icon | Does | Handler |
|---|---|---|---|---|
| New Window | ⌘N | `plus.rectangle` | New window at home, cascaded | `AppDelegate.newWindow` |
| New Tab | ⌘T | `macwindow.badge.plus` | Tab at the current folder | `MainWindowController.newTab` |
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
| Reopen Closed Tab | ⇧⌘T | — | Up to 10 closed tabs kept whole (history + split) — Finder uses ⇧⌘T for the tab bar | `TabsController.reopenClosedTab` |

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
| Filter | ⌘F by default; configurable | `magnifyingglass` | Focuses the toolbar name-filter field; checkmark while filtering |
| Show Hidden Files | ⇧⌘. | — | Saved by the selected folder-view policy; transient in ZIP pages |
| Reload | ⌘R | `arrow.clockwise` | (Finder: Show Original) |
| Use Groups | ⌃⌘0 | `square.grid.3x1.below.line.grid.1x2` | Off → back to the last key (Kind first) |
| Group By ▸ None · Name · Kind · Application · Date Last Opened · Date Added · Date Modified · Date Created · Size | ⌃⌘0 · ⌃⌘1 · ⌃⌘2 · — · ⌃⌘3 … ⌃⌘7 | `arrow.up.arrow.down` | Same submenu as the toolbar Group button |
| Sort By ▸ Name / Date Modified / Size / Kind · Ascending | — | — | Driven through the table so the header arrow stays in sync |
| Folder View Settings ▸ Remember Each Folder / Use One View for All Folders | — | — | Selects per-directory memory (default) or the existing shared default; also in Settings |
| Folder View Settings ▸ Use Current Settings as Default | — | — | Saves the active ordinary folder's complete view properties as the default; existing customized folders keep their records |
| Folder View Settings ▸ Restore This Folder to Default | — | — | Removes this folder's override and reapplies defaults; ordinary folders in per-directory policy only |
| Split View | ⇧⌘D | `rectangle.split.2x1` | Title becomes "Close Left/Right Pane" while split (Dolphin's toggle; Finder: ⇧⌘D = Desktop) |
| Focus Other Pane | ⌥⇥ | — | Split only |
| Show Sidebar | ⌃⌘S | `sidebar.leading` | (Finder: ⌥⌘S) |
| Show / Hide Terminal | F4 | — | Present only when Terminal panel is enabled in Settings; hiding ends the session |

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
Minimize ⌘M · Zoom · Show Previous Tab ⇧⌘[ · Show Next Tab ⇧⌘] (disabled with one tab) · Bring All to Front. Help is empty.

## Context menus (`BrowserViewController.buildContextMenu`)

Targets: the selection if the clicked row is in it, otherwise the clicked row alone (Finder). Sidebar commands retain the right-clicked place even after menu tracking ends; Open in New Tab / Other Pane does not first select or navigate the source pane. The table below describes ordinary directories. Read-only ZIP pages offer Open / Open With, folder navigation, Quick Look, Copy / Copy to Other Pane, Copy Path, Reload, hidden-file visibility and sorting; writable file actions, editable Info and Favorites changes are omitted.

| Where | Items |
|---|---|
| Background (no item) | New Folder · Get Info · Paste (enabled only with file URLs on the pasteboard) · — · Reload · Show Hidden Files ✓ · Sort By ▸ · — · Add/Remove from Favourites (current folder) |
| A file | Open · Open With ▸ (default app first, "(default)", separator, up to 20 apps with icons; "No Applications" when none) · [split: Copy/Move to Other Pane] · — · Quick Look · Get Info · Rename · Duplicate · Move to Trash · — · Cut · Copy · — · Reveal in Finder · Copy Path |
| A folder | Open · Open in New Tab (or "Open in N New Tabs") · Open in New Window · Open in Other/New Pane · then the file block · — · Add/Remove from Favourites |
| Several items | As above minus Open With and Rename; "Copy Paths" |
| Sidebar (`SidebarViewController`) | Open · Open in New Tab · Open in Other Pane · Reveal in Finder · [removable: Remove from Favourites · Reset Favourites] · [volume: Eject "name"]; empty when no row was clicked |
| Tab | No context menu; middle-click closes |

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

Closing a tab prefers the tab to the right (Safari). The strip hides itself with one tab; the `+` button's tooltip is "New Tab (⌘T)"; a tab's close button shows when selected or hovered.

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

The configured filter shortcut (⌘F by default) focuses the toolbar field, expanding it via `beginSearchInteraction` when folded to an icon. Typing filters names live; the status bar shows "N of M items" and no scope row is added. Esc or ⓧ clears the filter and returns focus to the file view; leaving the field keeps a non-empty filter. It is per pane and clears on directory change. Filtering uses complete filenames even when extensions are hidden; it does not recursively search folders or file contents.

## Settings and experimental features

Settings (⌘,) offers extension-label display, Folder View Settings, the Filter by Name shortcut recorder, and two experiments that default off. Folder View Settings chooses Remember Each Folder or Use One View for All Folders; the View submenu also saves the current view as default and restores a folder. If saving fails, Settings shows the error inline and offers Retry Saving View Settings; successful retry clears the error. Shortcut recording requires Command or Control, optionally Option/Shift; it rejects existing command conflicts. Escape cancels recording and Reset restores ⌘F. The menu binding updates immediately.

With **Terminal panel** enabled, F4 toggles a window-wide panel below the file panes. Opening starts an interactive shell in the active folder; inside a ZIP, it uses the original ZIP's containing folder rather than a temporary snapshot. Navigation changes only the destination for **Restart in Current Folder**; it never types `cd` into the running session. Restart ends the shell/current command and asks for confirmation when a foreground command is detected. F4 to hide, the panel close button, disabling the experiment, closing its window, or quitting Tursora ends the session.

With **Browse ZIP archives** enabled, normal Open/double-click enters a ZIP in the current pane. ⌘↓ / double-click opens the selected entry; ⌘↑ goes up, returning from the ZIP root to its containing folder and selecting the ZIP. ⌘[ / ⌘] navigate history. ⌘L, breadcrumbs, tabs, splits, list / icon view, grouping, sorting and current-directory name filtering use the ordinary pane controls, with logical paths under the source ZIP. Each archive navigation starts from the saved default view; changes remain temporary and never write directory records or defaults. Return does not rename archive entries.

⌘C and copy-only drag-out can take archive files into a regular folder; ⇧⌘C requires a writable opposite pane. Space / ⌘Y previews readable copies, and Share uses the same temporary content. Archive pages disable mutation commands, incoming drops, and editable Info / Inspector. The status bar shows `ZIP · Read-only`, with temporary-copy and Save As details in its tooltip. External edits do not update the ZIP; copies stay until Tursora quits. Turning the experiment off leaves existing archive pages and history read-only, while newly opened ZIPs in regular folders extract beside the original. Explicit Extract remains available for a ZIP selected in its containing folder; there is no separate Extract All button.

## Get Info (`InfoWindowController`)

⌘I opens one window per item and re-fronts an existing one; past 10 items it falls back to the summary window (Finder). ⌃⌘I makes a single "Multiple Item Info" window (one item falls back to ⌘I). ⌥⌘I opens the floating Inspector, which follows `.tursoraSelectionChanged` from the active pane and shows summary mode for several items. Targets are the selection, or the current folder when nothing is selected. Info windows take key but never main; they open with nothing focused. Inside: Return or focus-out in the name field renames (undoable with ⌘Z in that window); the Locked, Hide extension and privilege controls apply immediately; comments save on focus-out, close and quit.

## Toolbar actions

- More (ellipsis): New Folder, Open, Get Info, Quick Look, Rename, Duplicate, Copy, Paste, Move to Trash. Commands target the active pane even while the sidebar has focus.
- Share: the system sharing picker for selected files, using validated temporary copies inside a ZIP; disabled without a readable selection.
- Toggle Sidebar: fixed leading button; Show/Hide Sidebar (`⌃⌘S`) performs the same action.
- Split View: toggle alongside the view controls; selected when the current tab has two panes. Its tooltip and overflow menu read Close Left/Right Pane while split, following the active pane; it uses the same action as ⇧⌘D. Sidebar Open in Other Pane creates a split when needed, otherwise navigates and activates the opposite pane.
- Filter by Name: current-folder substring/wildcard filtering, without an additional scope row.
- Compress: File / More / selection context menu. Name includes the single filename or selection count.
- Extract: File / More / ZIP context menu in ordinary directories; normal ZIP Open also extracts while experimental browsing is off. Compress and Extract support Undo / Redo.

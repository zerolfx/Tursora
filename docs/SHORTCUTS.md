# Shortcuts, menus and gestures

Everything the user can press or click, as implemented. Menu items use `nil` targets, so the responder chain picks the handler (see [ARCHITECTURE.md §4](ARCHITECTURE.md)). Where a binding deliberately follows Dolphin or Finder, it says so; the planned changes are in [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md).

## Menu bar (`MainMenu.swift`)

### Tursora
| Item | Shortcut | Handler |
|---|---|---|
| About Tursora | — | `NSApplication` |
| Hide Tursora / Hide Others / Show All | ⌘H / ⌥⌘H / — | `NSApplication` |
| Quit Tursora | ⌘Q | `NSApplication`; `AppDelegate.applicationWillTerminate` closes Info windows so a half-typed comment is saved |

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
| Filter | ⌘F | `magnifyingglass` | Focuses the toolbar search field; checkmark while filtering |
| Show Hidden Files | ⇧⌘. | — | Per pane |
| Reload | ⌘R | `arrow.clockwise` | (Finder: Show Original) |
| Use Groups | ⌃⌘0 | `square.grid.3x1.below.line.grid.1x2` | Off → back to the last key (Kind first) |
| Group By ▸ None · Name · Kind · Application · Date Last Opened · Date Added · Date Modified · Date Created · Size · Tags | ⌃⌘0 · ⌃⌘1 · ⌃⌘2 · — · ⌃⌘3 … ⌃⌘8 | `arrow.up.arrow.down` | Same submenu as the toolbar Group button |
| Sort By ▸ Name / Date Modified / Size / Kind · Ascending | — | — | Driven through the table so the header arrow stays in sync |
| Split View | ⇧⌘D | `rectangle.split.2x1` | Title becomes "Close Left/Right Pane" while split (Dolphin's toggle; Finder: ⇧⌘D = Desktop) |
| Focus Other Pane | ⌥⇥ | — | Split only |
| Show Sidebar | ⌃⌘S | `sidebar.leading` | (Finder: ⌥⌘S) |

### Go
| Item | Shortcut | Icon |
|---|---|---|
| Back / Forward | ⌘[ / ⌘] | `chevron.backward` / `chevron.forward` |
| Enclosing Folder | ⌘↑ | `arrow.up.folder` (selects the folder you left) |
| Home | ⇧⌘H | `house` |
| Edit Location | ⌘L | — (Finder: Make Alias) |
| Go to Folder… | ⇧⌘G | `arrow.forward.folder` (opens the breadcrumb's edit mode, like ⌘L) |

### Window
Minimize ⌘M · Zoom · Show Previous Tab ⇧⌘[ · Show Next Tab ⇧⌘] (disabled with one tab) · Bring All to Front. Help is empty.

## Context menus (`BrowserViewController.buildContextMenu`)

Targets: the selection if the clicked row is in it, otherwise the clicked row alone (Finder).

| Where | Items |
|---|---|
| Background (no item) | New Folder · Get Info · Paste (enabled only with file URLs on the pasteboard) · — · Reload · Show Hidden Files ✓ · Sort By ▸ · — · Add/Remove from Favourites (current folder) |
| A file | Open · Open With ▸ (default app first, "(default)", separator, up to 20 apps with icons; "No Applications" when none) · [split: Copy/Move to Other Pane] · — · Quick Look · Get Info · Rename · Duplicate · Move to Trash · — · Cut · Copy · — · Reveal in Finder · Copy Path |
| A folder | Open · Open in New Tab (or "Open in N New Tabs") · Open in New Window · Open in Other/New Pane · then the file block · — · Add/Remove from Favourites |
| Several items | As above minus Open With and Rename; "Copy Paths" |
| Sidebar (`SidebarViewController`) | Open · Open in New Tab · Reveal in Finder · [removable: Remove from Favourites · Reset Favourites] · [volume: Eject "name"]; empty when no row was clicked |
| Tab | No context menu; middle-click closes |

## Keyboard in the file views (`FileOutlineView` / `FileCollectionView`)

| Key | Effect |
|---|---|
| Return / Enter | Rename the one selected item (Finder; Dolphin uses F2). See [DECISIONS.md](DECISIONS.md) D3 |
| Space | Toggle Quick Look |
| ⌘↓ / ⌘↑ | Open the selection / enclosing folder |
| Arrows | Selection; inside the Quick Look panel ←→↑↓ are forwarded to the view so previews browse |
| Type-select | List view only |
| ⌘⌫ / ⌥⌘⌫ | Trash / delete immediately |
| Esc while renaming | Grid: reverts the label. List: an empty, unchanged or `/`-containing name reverts |

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
| ⇧⌘D | Split (second pane at the same folder) or close the **active** pane |
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
- Source masks: local `[.copy, .move]`, external `[.copy, .move, .link]`.
- Sidebar: files onto a place follow the same rule; folders dropped **between** favourites are added there; dragging a favourite reorders it; volumes can't be dragged.
- Tab strip: hovering a tab with a drag activates it after **0.8 s** (`TabBarView.autoActivationDelay`, Dolphin); dropping on a tab lands in that tab's active pane; dropping on empty strip space opens each folder as a background tab.
- Cross-tab and cross-pane drags work; the source pane refreshes through `DirectoryChanges`.

## Filter (`MainWindowController`)

⌘F focuses the toolbar search field, expanding it via `beginSearchInteraction` when the toolbar has folded it to an icon. Typing filters live. Finder's scope bar appears once there is text ("Filter: [folder] · 3 of 12 items") and the status bar switches to "N of M items". Esc or ⓧ clears the filter and returns focus to the file view; merely leaving the field keeps a non-empty filter (Finder). The filter is per pane (Dolphin) and cleared on directory change.

## Get Info (`InfoWindowController`)

⌘I opens one window per item and re-fronts an existing one; past 10 items it falls back to the summary window (Finder). ⌃⌘I makes a single "Multiple Item Info" window (one item falls back to ⌘I). ⌥⌘I opens the floating Inspector, which follows `.tursoraSelectionChanged` from the active pane and shows summary mode for several items. Targets are the selection, or the current folder when nothing is selected. Info windows take key but never main; they open with nothing focused. Inside: Return or focus-out in the name field renames (undoable with ⌘Z in that window); the Locked, Hide extension and privilege controls apply immediately; comments save on focus-out, close and quit.

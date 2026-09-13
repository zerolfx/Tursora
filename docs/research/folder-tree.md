# The Folder Tree Compared with Dolphin Places (2026-09-13)

The user explicitly asked for a file tree on the grounds that Dolphin has one. It was developed on `codex/customization-and-distribution`; the final combined verification and the packaged-app evidence are at the end of this page.

## Pinned Basis

The local `upstream/dolphin` is pinned to commit `5e457ee9e88aa6277fbf056cd5c32462c5318866`:

- The Folders / Places dock creation code in `src/dolphinmainwindow.cpp`: the two are independent and both may dock left or right; Folders uses F7 and Places uses F9, Places is shown by default and Folders hidden, and the active URL is connected to the tree panel.
- `src/panels/folders/folderspanel.cpp`: the model is created only when the panel is first shown, `setShowDirectoriesOnly(true)`, with support for expansion and for opening a directory with a single click.
- `src/panels/folders/dolphin_folderspanelsettings.kcfg`: hidden folders are not shown by default, LimitToHome is on, and auto-scrolling is allowed.

The [official panel documentation](https://docs.kde.org/stable_kf6/en/dolphin/dolphin/panels.html) explains Places (favourite locations and devices) and Folders (the directory hierarchy) separately. They can be shown at the same time, and Places is not another name for the file tree.

## The Tursora Implementation and Its Trade-offs

- The existing Favorites / Locations lists are kept; View → Show Folders (F7 by default, customizable) opens a separate **Folders** section below them in the sidebar, with a draggable divider between the two. It is hidden by default, and collapsing the whole sidebar suspends the directory tree; opening it again resumes.
- It uses a native `NSOutlineView` and shows only folders that can be navigated into, without entering application bundles. Expanded nodes and the ancestors of the active path are loaded in the background on demand, with no recursive disk scan at launch; hiding the panel cancels stale results and file monitoring.
- A single click on a tree node navigates the currently active pane; switching pane, tab or normal directory expands and selects the active path. A ZIP maps to the directory containing the original archive; the temporary unpacked copy is not shown, and a logical ZIP path is not treated as a local directory.
- Right-click actions capture the actual target URL and offer Open, Open in New Tab and Open in Other Pane; dragging a file onto a directory follows the existing same-volume Move / cross-volume Copy / Option-forces-Copy decision, and the change goes through the Browser's FileOperations and undo flow.
- Show Hidden Folders and Limit to Home Directory are the directory tree's own options and do not change hiding, filtering, sorting or grouping in the file area. Inside Home the tree shows from Home by default, outside Home from `/`; a path that does not exist or fails to read is reported inside the panel, with no modal dialog.
- The session file stays compatible with the older version and adds the visibility state, the divider ratio inside the sidebar, and the two options; it does not store the whole directory tree, the full set of expansions or a file cache. Restoring a closed session keeps the existing policy of not saving those.
- Differences from Dolphin: this round uses a stacked layout within the same sidebar and does not implement a dock framework that can be detached or moved to the right; Dolphin's F9 default shortcut for Places was not added, so as to keep the existing Toggle Sidebar habit (the key can be changed by hand).

## Implementation Boundaries

`FolderTreeModel` handles provider reads, node identity, rejecting stale requests and refreshing on directory changes; `FoldersPanelController` handles the tree and the context menu; `SidebarViewController` combines the two panels; `MainWindowController` handles the active pane, the session and action routing. No provider enumeration starts while the tree is hidden, and a cache refresh keeps the identity of nodes that still exist; when a node is deleted the selection is cleared, so an old row number cannot be carried over to the next directory.

`NSOutlineView.shouldExpandItem` only answers whether expansion is permitted; it does not modify the expanded set or start a read, and AppKit accessibility queries call it as well. Only a real `outlineViewItemDidExpand` records the expansion and calls the model's load asynchronously, which avoids a Loading update rebuilding rows in the middle of an expansion. A synchronous reload / reselect suppresses the callbacks, path location is delivered only after the queued refresh finishes, and removing a node cleans up the waiting callbacks; the selected row is scrolled fully into view after the final layout.

## Verification Status

`FolderTreeSmokeTests` covers the model and the window path, including a regression that accessibility queries do not load other directories; the final 3,194 smoke checks over 95 Swift source files passed three times in a row (`smoke-7` / `8` / `9`), each exit 0 with empty stderr and unchanged sources. The delivered app / DMG build with its signing, the bundle contents and the installation layout passed their checks; the exact source manifest and the combined logs are in the [customization integration record](customization-integration.md).

The packaged-app measurements are complete: F7 opened a separate Folders section that expanded down the actual source hierarchy, and a single click on Model navigated, with the selected row fully visible, the other branches still collapsed and Loading finished; after the divider between the two sections was dragged it kept following, and the right-click UI → Open in Other Pane kept the left side and activated the right. After the address bar layout was fixed, dragging from 1100 × 740 down to the real window minimum of 560 × 380 kept the tree, the split panes and navigation responsive, and the original size was then restored. After a normal quit with only the QA copy reopened in light mode, tree visibility, the divider ratio, the split panes and both tabs were restored and no terminal was started; the system appearance and the production preferences were not changed.

The real `folders.png` and the workspace restore image have been made transparent with their protected interior pixels unchanged; all 29 screenshots passed the full check. For the original images, the exact operations and the stage boundaries see the [integration record](customization-integration.md) and the [screenshot audit](screenshot-audit-2026-09-13.md). This round does not extend the click and menu verification above into a claim that every native drag-and-drop gesture has been measured.

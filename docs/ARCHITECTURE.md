# Architecture

Tursora is one Swift executable target, `app/Sources/Tursora`, split into `Model/` (no AppKit views, headlessly testable) and `UI/` (AppKit). The terminal depends on SwiftTerm 1.15.0, pinned by SPM; the rest of the interface is AppKit. Everything is built in code — no nibs, no storyboards. This document is the code map; the intended behaviour is in [SPEC.md](SPEC.md), the reasons in [DECISIONS.md](DECISIONS.md).

## 1. Object graph at runtime

```
NSApplication
└─ AppDelegate                          shared LocalFileProvider + PlacesModel
   └─ MainWindowController ×N           window, toolbar, BrowserHost
      └─ contentSplitController         horizontal divider: browser above, optional terminal below
         ├─ splitViewController         vertical divider
         │  ├─ SidebarViewController    outline over PlacesModel
         │  └─ TabsController           tab bar, breadcrumb, TabPages, split drop overlay
         │     └─ TabPage ×tabs         1–2 panes, activeIndex
         │        └─ BrowserViewController ×pane
         │           ├─ DirectoryModel, NavigationHistory, DirectoryWatcher
         │           ├─ fileView: FileViewing = FileListViewController | IconGridViewController
         │           ├─ StatusBarView, active indicator, error label, context menu
         │           └─ Quick Look data source / delegate
         └─ TerminalPanelController?    SwiftTerm LocalProcessTerminalView + owned PTY
InfoWindowController ×open              registry + Inspector
SettingsWindowController                shared window over AppPreferences.Store
ServerConnectionController              shared address window + NetFS request
ArchiveWorkspace.shared                retained ZIP snapshots; logical locations in ordinary panes
```

- **`main.swift`** creates `NSApplication`, an `AppDelegate`, sets `.regular` activation policy, runs.
- **`AppDelegate`** owns the one `LocalFileProvider` and the one `PlacesModel`, plus `windowControllers`. `newWindow(at:)` builds a controller, cascades it and installs `wc.onClose`. On launch it builds `MainMenu.build()` and, if `SmokeTest.isRequested`, calls `SmokeTest.run(wc)`. `applicationWillTerminate` saves Info edits, shuts down owned terminal sessions, and closes temporary ZIP sessions. It also observes preference changes to update the actual menu shortcut and experimental terminal visibility.
- **`MainWindowController`** (one per window) owns the `NSWindow`, a vertical-divider split (sidebar + tabs) inside a horizontal-divider split (browser + optional terminal), the `NSToolbar` (it is the delegate), `SidebarViewController` and `TabsController`. It **is** the `BrowserHost` (`tabs.host = self`) and the delegate of the toolbar's `NSSearchToolbarItem`. It holds `backButton`/`forwardButton` (`LongPressMenuButton`), `viewModeControl`, `searchItem`, and two local `NSEvent` monitors (⌃Tab, ⌘1–9, ⌘=; mouse buttons 4/5).
- **`TabsController`** owns, top to bottom in one `NSStackView`: `TabBarView`, `BreadcrumbBar` (`addressBar`), and a container holding every `TabPage` view plus a `SplitDropOverlay`. State: `pages`, `currentIndex`, `closedTabs` (max 10). Callbacks out: `onCurrentLocationChanged`, `onTabsChanged`.
- **`TabPage`** = one tab: 1–2 `BrowserViewController`s in a vertical-divider `NSSplitView` (it is the delegate), `activeIndex`, and a click monitor that activates whichever pane was clicked. Callbacks out: `onActivePaneChanged`, `onPaneLocationChanged`.
- **`BrowserViewController`** = one pane. Wraps the supplied provider in `ArchiveFileProvider`, backed by the shared `ArchiveWorkspace`. Owns a `DirectoryModel`, a `NavigationHistory`, the two file views (current one as `fileView: FileViewing`), `StatusBarView`, the pane's context menu (it is the `NSMenuDelegate`) and a `DirectoryWatcher`. `weak var host: BrowserHost?` reaches the window.
- **`FileViewing`** is the protocol both file views implement; the browser is the sole consumer of their closures.
- **Chrome** (toolbar, breadcrumb, tab bar, completion popup) is window-level and always reflects `tabs.currentPage.active`. The terminal belongs to the window, not a tab: location updates change its pending restart destination, never write commands into its PTY. In an archive, the window represents the source ZIP and the terminal destination is its containing directory, never a temporary snapshot.

## 2. Per file

### Model/

| File | Responsibility |
|---|---|
| `FileProvider.swift` | `protocol FileProvider` (`listDirectory(_:)`, `homeURL`, `displayName(for:)`) — the single filesystem seam; `LocalFileProvider` implements it with `FileManager`. `listDirectory` blocks; callers run it off the main thread. |
| `FileItem.swift` | Immutable value for one listing entry: `url, name, isDirectory, isPackage, isHidden, isSymlink, size, modificationDate, creationDate, accessDate, addedDate, contentType`, all read once via `resourceKeys`. Derived: `isNavigable`, `displayName` (extension preference only), `icon(size:)`, `kindDescription`, `displaySize`, `displayDate`. Identity and rename always use `name` / URL. Archive entries retain a logical `url`, physical `contentURL`, access state and session; `readableContentURL` revalidates containment before use. Metadata is cached, while content access remains guarded. |
| `DirectoryModel.swift` | `FileNode` (class, identity-stable across reloads, keyed by URL) and `DirectoryModel`: `url`, `allNodes`, `nodes`, `groups`, `generation`, and the arrangement inputs `showHidden`, `nameFilter`, `groupKey`, `foldersFirst`, `sortKey`, `ascending` (each `didSet` → `resort()`). `load(_:completion:)` lists off-main with a `loadToken` guard and merges into existing nodes; `reload`, `setSort`, `loadChildren(of:refresh:)` (synchronous), `node(for:)`, `indexOf(url:)`, `item(at:)`, `matches(_:filter:)` (wildcards when `*`/`?`). Private `arrange` = hidden filter + name filter + sort, recursing into loaded children. Never mutates the filesystem. |
| `DirectoryWatcher.swift` | FSEvents wrapper (file events, 0.25 s latency, dispatched on main). Also defines `Notification.Name.tursoraDirectoriesChanged` and `enum DirectoryChanges` with `post(_:renamed:)` and `affected(sources:destination:)`. |
| `Grouping.swift` | `GroupKey` (nine keys including None; Tags excluded by design), `GroupNode` (title + nodes + sort order), and the pure `Grouping.split(_:by:now:)` with `nameBucket`, `kindBucket`, `applicationBucket`, `dateBucket`, `sizeBucket`. No UI, no I/O beyond `NSWorkspace.urlForApplication`. |
| `NavigationHistory.swift` | Linear `entries` + `index`; `push` (dedupes the current URL, truncates forward, trims to 100), `goBack`, `goForward`, `go(to:)`, `recordViewState(selectedName:scrollOffset:)`, `backEntries`/`forwardEntries` for the long-press menus. Knows nothing about views. |
| `FileOperations.swift` | All mutation: `uniqueURL`, `duplicateURL`, `rename` (via the name resource, so case-only renames work on APFS), `trash` (returns original/trashed pairs), `delete`, `sameVolume`, `duplicate`, and `transfer(_:to:kind:conflict:progress:completion:)` with `BatchPolicy` (apply-to-all) and recursive `merge`. UI-facing helpers: `askConflict(in:_:)` (Finder's conflict dialog rebuilt: Keep Both / Merge / Skip / Stop / Replace + "Apply to all") and `report(_:in:)`. |
| `FileInfo.swift` | Every fact behind Get Info, computed headlessly: `whereString`, `dateString`, `Size` + `computeSize(of:countingChildren:update:)` → cancellable `SizeCalculation`, `sizeString`/`headerSizeString`, `isLocked`/`setLocked`, `hasHiddenExtension`/`setHiddenExtension`, `comment`/`setComment` (xattr `com.apple.metadata:kMDItemFinderComment`), `moreInfo` (Spotlight), `bundleInfo`, `volumeInfo`, `original`, `applications(toOpen:)`, `Permissions`/`Privilege`/`Who`, `privilege`, `mode(_:setting:for:isFolder:)`, `setMode`, `accessSummary`, `fileID`/`sibling(of:withFileID:)`, `kind`, `summaryKind`. Reads flags through `FileManager.attributesOfItem`, not URL resource values (D15). |
| `PlacesModel.swift` | Sidebar data: `Section`/`Place`, rebuilt from `builtIns()` + user paths in one persisted order list, plus mounted volumes. `favouriteIndex(of:)`, `isFavourite`, `addFavourite(_:at:)`, `removeFavourite`, `moveFavourite(from:to:)`, `resetFavourites`, `isEjectable`. Posts `PlacesModel.didChange`; observes `NSWorkspace` mount/unmount/rename. |
| `PathCompleter.swift` | Path resolution and directory completion, including prepared logical ZIP locations. `resolveNavigationLocation(_:cwd:home:workspace:)` additionally accepts a pending ZIP directory candidate; the browser must prepare and validate it before navigation. `resolveDirectory` remains strict for prepared children; completion skips packages and uses safe archive entries. |
| `ThumbnailProvider.swift` | Singleton Quick Look thumbnail cache: `canPreview(_:)`, `thumbnail(for:size:scale:completion:)` returns a cached image synchronously or calls back on main; `NSCache` keyed by path·size·mtime·bytes, coalesced `pending`, remembered `unsupported`. |
| `ZoomLevel.swift` | `ViewMode`, the two zoom ladders, `defaultIndex`, `clamp`, `previewThreshold = 32`; `ViewPreferences` is the only reader/writer of the view-related `UserDefaults` keys. |
| `AppPreferences.swift` | Persistent extension-label display, validated filter shortcut, and default-off experimental flags. Injectable `Store` and `.tursoraPreferencesChanged`; no shell/archive work is triggered by a preference getter. |
| `ArchiveOperations.swift` | `FileOperations` ZIP creation/extraction, isolated staging, containment validation, exclusive publication, metadata/quarantine preservation. |
| `ArchiveBrowsingSession.swift` | Private extracted snapshot for read-only browsing, containment-checked navigation/opening, cleanup through `FileOperations`; never replaces the original ZIP. |
| `ArchiveWorkspace.swift` | Thread-safe shared session registry, coalesced asynchronous preparation, logical/readable URL mapping and application-exit cleanup. `ArchiveFileProvider` routes archive listings and preserves logical `FileItem` identity. |
| `ServerConnection.swift` | URL validation and asynchronous NetFS mount/cancel; system authentication; returns mounted file URLs. |

### UI/

| File | Responsibility |
|---|---|
| `MainWindowController.swift` | Window, toolbar, split view, sidebar wiring, the `BrowserHost` implementation (`isSplit`, `openInNewTab`, `openInNewWindow`, `openInOtherPane`, `transferToOtherPane`, `viewModeDidChange`), the toolbar filter field (`applyFilter`, `cancelFilter`, `focusFilter`, `syncFilterUI`), `locationChanged` (source-ZIP `representedURL` for archives, sidebar sync, terminal destination, validation), read-only action guards and sharing of readable selection URLs, the window-scope menu actions and `validateMenuItem`/`validateToolbarItem`. The Split View toolbar toggle, accessible title and overflow command follow the current tab and active pane through `syncSplitToolbar`; sidebar `onOpenInOtherPane` delegates to `tabs.openInOtherPane`. |
| `TabsController.swift` | Tab lifecycle (`newTab`, `closeTab(at:)`, `closeCurrentTab`, `reopenClosedTab`, `selectTab/Next/Previous`, `moveTab`), split operations (`isSplit`, `toggleSplit`, `openInOtherPane`, `focusOtherPane`, `canSplit(withTab:)`, `splitCurrentPage(withTab:side:)`, `splitSide(at:)`), file drops on the strip (`filesDropped`), and `refreshChrome()` (tab titles, tab-bar visibility, address-bar URL, `onTabsChanged`). Also `SplitDropOverlay`. |
| `TabPage.swift` | `PaneSide`, pane list, `split(with:side:)`, `adopt`, `releaseActivePane`, `closePane`/`closeActivePane`, `activate`/`activateOther`, `updateIndicators`, split-view constraints (min 160 pt, never collapses) and the click monitor. Wires each pane's `onLocationChanged`/`onFocus`. |
| `BrowserViewController.swift` | The pane controller and the responder for selection-scoped commands: `navigate(to:)`, `goBack/goForward/goUp/goHome/goToHistory(slot:)`, `reload()`, `historyMenu(back:)`, `nameFilter`/`isFiltering`/`filterSummary`, `setViewMode`, `setZoomIndex`/`zoom(by:)`, `setShowsPreviews`, `setGroupKey`, `newFolder()`, `copy/cut/paste/duplicate/moveToTrash/deletePermanently/renameSelection/quickLook`, `rename(_:to:)`, `trash(_:)`, `dropFiles(_:to:op:)`, `buildContextMenu(for:)`, `getInfo/getSummaryInfo/showInspector`, `infoTargets`, `updateStatus`, `displayedDirectories`, `scheduleRefresh`, `refreshPreservingSelection`, `report(_:context:)`. Private: `load`, `transfer`, `asUndoGroup`, `registerUndoMove/Trash/Rename`, `saveViewState`/`restoreViewState`. Exposes archive read-only capabilities, uses logical current/history URLs, prepares and validates ZIP directory navigation, and maps copy-out / preview / sharing to readable copies. **The only place panes talk to `FileOperations`.** |
| `FileViewing.swift` | The view-swap contract: closures in (`onOpen`, `onOpenInNewTab`, `onRenameCommitted`, `onSelectionChanged`, `onFocus`, `onQuickLook`, `onDropFiles`, `onZoomGesture`), commands out (`reloadData`, `select(name:)`/`select(names:)`, `openSelection`, `beginRename(item:)`, `itemAfterSelection`, `setIconSize(_:showPreviews:)`, `frameOnScreen(for:)`, `forwardKey`, `scrollOffset`, `selectedItems`, `clickedItems`, `cutURLs`, `contextMenu`, `isReadOnly`). Read-only mode blocks renaming and incoming drops in both views; archive drag sources revalidate readable copies and offer copy-only operations. Views must not navigate, mutate files, or drive Quick Look themselves. |
| `FileListViewController.swift` | Details view over `NSOutlineView` (`FileOutlineView`): four columns, group rows for `GroupNode`, expand-in-place with `expandedURLs` tracking, `reloadData()` that refreshes expanded children before `tableView.reloadData()` when `model.generation` changed, inline rename with Finder's base-name preselection, sort via `sortDescriptors`, drag source, and the static Finder rule `dropOperation(for:into:sourceMask:)` reused by the grid, sidebar and tab bar. `FileOutlineView` adds Return/Space, middle click, ⌘-scroll/pinch zoom, and the delayed click-to-rename with drag guards (`renameCandidate`, `renameAllowedAfterMouseUp`, `scheduleRename`, `cancelPendingRename`). |
| `IconGridViewController.swift` | Icon view over `NSCollectionView`; one section per `GroupNode` with sticky `GroupHeaderView`; `FileCollectionItem` draws Finder-style selection and does label rename; `FileCollectionView` adds Return/Space, zoom gestures and `clickedIndexPath`. Same `FileViewing` surface, including read-only rename/drop guards and validated copy-only archive drags; ordinary drop rules delegated to `FileListViewController.dropOperation`. |
| `SidebarViewController.swift` | Source-list outline over `PlacesModel`; `row(for:)`, `syncSelection(to:)`, `reorderTargetIndex(item:childIndex:pointerY:)`, context menu (Open / New Tab / Other Pane / Reveal / Remove / Reset / Eject), with each action retaining the right-clicked place instead of consulting transient `clickedRow`, three drop kinds: reorder a favourite (private `com.tursora.place` type), add dropped folders as favourites, drop files onto a place (`onDropFiles`). Never performs the transfer itself. |
| `BreadcrumbBar.swift` | Dolphin's URL navigator: `url`, `onNavigate`, `onEndEditing`, `beginEditing()`/`endEditing()`/`commit(_:)`, static `segments(for:home:)`, manual layout with overflow folding and shrinking, `subfolderMenu(of:current:)`, and edit-mode completion (`textChanged`, `accept(candidate:)`, `acceptCompletion`, `typedText`, `inlineCompletion`) driving `CompletionPopup`. |
| `CompletionPopup.swift` | Non-activating borderless child panel with a click-only table: `show(_:below:in:)`, `hide()`, `moveSelection(by:)`, `selectedCandidate`, `candidates`. |
| `TabBarView.swift` | Draws tabs; `reload(titles:selected:)`, reorder by drag, drag-below-the-strip reporting (`onDragOutside`/`onDropOutside`), file drops (`dropOperationForTab`, `performDrop(urls:sourceMask:onTabAt:)`, `beginAutoActivation`, `autoActivationDelay = 0.8`). `TabItemView` handles hover, close button, middle-click close. |
| `StatusBarView.swift` | `update(itemCount:totalCount:selectedCount:directory:archiveStatus:)` with compact read-only archive text and an explanatory tooltip, `setZoom(index:count:)`/`onZoomChanged`, `beginBusy`/`endBusy` (nested-safe spinner). |
| `InfoWindowController.swift` | Get Info / Summary / Inspector. Statics: `show(for:relativeTo:)` (>10 items → summary; an existing window matched by `standardizedFileURL` is re-fronted), `showSummary`, `showInspector`, `closeAll`, `openWindows`, `inspectorWindow`. Instance: `rebuild()` (tears down and rebuilds all sections), `scheduleRebuild()` (150 ms debounce), `isEditing`/`rebuildDeferred`, section builders (`generalContent`, `nameContent`, `commentsContent`, `openWithContent`, `previewContent`, `sharingContent`), `commitRename`, `saveComment`, `setLocked`, `setHiddenExtension`, `setPrivilege`, `setDefaultApplication`, `follow(_:to:)`, `parentsChanged`, `fitWindow`, `sync(with:force:)`/`syncWithMainWindow`, plus test accessors. Also `InfoSection` (collapsible, persists its own expansion) and the `canBecomeMain == false` window/panel subclasses. Defines `.tursoraSelectionChanged`. |
| `LongPressMenuButton.swift` | Click fires the action; long-press (0.35 s) or right-click pops `menuProvider()`. |
| `ViewHelpers.swift` | `NSView.pinToEdges(_:insets:)`, `NSTableCellView.make(identifier:withIcon:alignment:iconSize:)`. |
| `SettingsWindowController.swift` | Native settings controls and `ShortcutRecorderButton`; captures shortcuts before menu dispatch, rejects conflicts inline, persists via the store, and observes external changes. |
| `TerminalPanelController.swift` | Pinned SwiftTerm AppKit terminal and PTY lifecycle, safe argv-based launch configuration, restart target, explicit shutdown/reaping; no navigation-to-shell command injection. |
| `ServerConnectionController.swift` | Address input and inline errors, mount progress/cancellation, success callback to the initiating browser. |
| `MainMenu.swift` | Builds the whole menu bar in code with `nil` targets so the responder chain resolves them; `groupByMenuItem()` is shared with the toolbar Group item; `MenuIcons.image` resolves `"a|b"` SF Symbol fallbacks. |
| `SmokeTest.swift` and `*SmokeTests.swift` | Integration chain plus isolated settings, archive, ZIP-browser, server, and terminal checks; see §6 and [DEVELOPMENT.md](DEVELOPMENT.md). |

## 3. Data flow walkthroughs

**(a) Navigate to a folder.**
A new pane defers initial navigation until its owner has installed callbacks. That callback runs only while `navigationGeneration == 0`; an explicit navigation made first wins and cannot be replaced by the initial location.

1. `BrowserViewController.navigate(to:)` → `saveViewState()` (`history.recordViewState`) → `history.push(url)` → `load(url)`.
2. `load` sets `currentURL`, clears the error, cancels `refreshDebounce`, clears `nameFilter` if the directory changed, creates a `DirectoryWatcher` for ordinary directories (none for archive snapshots), calls `model.load(url) { restoreViewState() }`, then `onLocationChanged?(url)` and posts `.tursoraSelectionChanged`.
3. `DirectoryModel.load` lists off-main, merges, bumps `generation`, `resort()` → `Grouping.split` → `onChange`.
4. `onChange` → `fileView.reloadData()` + `updateStatus()`.
5. The completion runs `restoreViewState()` (pending selection, else the history entry's `selectedName`/`scrollOffset`).
6. `onLocationChanged` → `TabPage.onPaneLocationChanged` → `TabsController.refreshChrome()` (tab titles + `addressBar.url`) and, for the active pane of the current tab, `onCurrentLocationChanged` → `MainWindowController.locationChanged` → hidden window title and `representedURL` (empty subtitle), `sidebar.syncSelection(to:)`, terminal restart destination, `validateNavigation()`, `syncFilterUI()`.

**Archive navigation.** Before pushing history, `navigate(to:)` normalizes to the logical URL, prepares a ZIP if needed, and verifies that the requested location is a directory. `ArchiveFileProvider` lists its private snapshot while preserving logical entry URLs, so the existing model and both views handle arrangement and filtering. Back / Forward retain these logical entries; Up from the ZIP root selects the ZIP in its ordinary parent. Prepared sessions remain navigable after the experiment is disabled. Archive destinations reject writes; copy-out, Quick Look and Share receive validated readable URLs. There is no separate archive window.

**(b) Move by drag, with undo.**
1. `FileListViewController.acceptDrop` (or the grid / sidebar / tab bar) computes `dropOperation(for:into:sourceMask:)` and calls `onDropFiles`.
2. → `BrowserViewController.dropFiles(_:to:op:)` → private `transfer(...)`: `statusBar.beginBusy()`, `FileOperations.transfer` with `conflict: { FileOperations.askConflict(in: window, $0) }`.
3. Completion on main: `endBusy()`, `registerUndoMove(result.moved, actionName: "Move")` (or `registerUndoTrash` for copies) inside `asUndoGroup`.
4. `reloadSelecting(names)` if the destination is this pane, else `reload()`.
5. `DirectoryChanges.post(DirectoryChanges.affected(sources:destination:))` → every other pane and Info window observing `.tursoraDirectoriesChanged` refreshes.
6. `FileOperations.report(result.failures, in: window)`.

**(c) Outside change.** FSEvents → `DirectoryWatcher` handler on main → `BrowserViewController.fileSystemChanged(paths)` → `isDisplaying(path)` (symlinks resolved on both sides; matches `displayedDirectories` = current URL + `fileList.expandedFolderURLs`) → `scheduleRefresh(after: 0.15)` (debounced) → `refreshPreservingSelection()`: capture selected names (mapped through `pendingRenames`) and `scrollOffset`, `model.reload`, re-`select(names:)`, restore the offset. The in-app path is identical from `scheduleRefresh` on, entered via `directoriesChanged(_:)`.

**(d) Selection → status bar / Quick Look / Inspector.** View selection change → `FileViewing.onSelectionChanged` → browser closure: `updateStatus()`, post `.tursoraSelectionChanged` with `object: self`, `panel.reloadData()` if a visible `QLPreviewPanel` exists. The Inspector observes the notification, checks the poster is the active pane of the main (or key, or only) `MainWindowController`, then `sync(with:)` → `urls = selection` (or the folder when empty) → `scheduleRebuild()`.

**(e) Filter and groups.** Typing in the toolbar field → `controlTextDidChange` → `MainWindowController.applyFilter` → `browser.nameFilter` → `DirectoryModel.nameFilter` `didSet` → `resort()` → `arrange` → `Grouping.split` → `onChange` → `reloadData` + `updateStatus`; then `syncFilterUI()` follows the active pane in the toolbar field. Groups: View ▸ Group By / toolbar Group menu → `groupBy` or `toggleGroups` → `setGroupKey` → `model.groupKey` `didSet` → same path; `ViewPreferences.groupKey`/`lastGroupKey` are written. The list renders `model.groups` as group rows; the grid as one section per group.

Archive panes do not expose editable Info / Inspector targets; their Quick Look source resolves logical selections to readable snapshots.

**(f) Get Info build / rebuild.** ⌘I → `MainWindowController.getInfo` → `browser.getInfo` → `InfoWindowController.show(for: infoTargets, relativeTo:)` → registry check (standardized target URLs; summary matching preserves target order) → `init` → `buildChrome()` + `rebuild()`. `rebuild()` cancels the size calculation, saves any comment, empties the stack, adds header + `general`, `moreInfo`, `name`, `comments`, `openWith` (files only), `preview`, `sharing`, records `fileIDs`, starts the size calculation, watches the parent, fits the window. Rebuilds are deferred while `isEditing` and resumed from `controlTextDidEndEditing`/`textDidEndEditing`. Renames: in-app ones arrive as `.tursoraDirectoriesChanged` with `renamedFrom`/`renamedTo` → `follow(from:to:)` rewrites `urls` and every per-section URL; outside renames arrive via FSEvents → `parentsChanged()` → for missing items `FileInfo.sibling(of:withFileID:)` finds the same inode → `follow`. A truly deleted item closes the window (the Inspector re-syncs instead).

## 4. Cross-cutting conventions

**Callbacks vs notifications.** Parent/child links are closures (`on…`); anything that crosses panes, tabs or windows is a notification.

| Name | Defined in | Posted by | Observed by |
|---|---|---|---|
| `.tursoraDirectoriesChanged` (`"tursora.directoriesChanged"`, userInfo `directories`, optional `renamedFrom`/`renamedTo`) | `DirectoryWatcher.swift` | `DirectoryChanges.post` — from `BrowserViewController` (`newFolder`, `duplicate`, `trash`, `deletePermanently`, `rename`, `transfer`, undo) and `InfoWindowController` (`rename`, `toggleLocked`, `toggleHiddenExtension`, `setPrivilege`) | `BrowserViewController.directoriesChanged`, `InfoWindowController.directoriesChanged` |
| `.tursoraSelectionChanged` (`"tursora.selectionChanged"`, object = the pane) | `InfoWindowController.swift` | `BrowserViewController` (selection closure, and `load`) | `InfoWindowController` in `.inspector` mode |
| `.tursoraPreferencesChanged` (`"Tursora.preferencesChanged"`, object = the store) | `AppPreferences.swift` | `AppPreferences.Store` on a changed value | `AppDelegate` updates menus; windows refresh extension labels / shut down disabled terminals; Settings refreshes controls |
| `PlacesModel.didChange` | `PlacesModel.swift` | `PlacesModel.notify()` (mount/unmount/rename, `saveOrder`, `resetFavourites`) | `SidebarViewController.placesChanged` |

Plus AppKit's `NSWorkspace.didMount/didUnmount/didRenameVolume` (PlacesModel) and `NSWindow.didBecomeMainNotification` (Inspector).

**View-mode toolbar sync.** After a pane mounts its new file view, `BrowserHost.viewModeDidChange(in:)` asks the window to validate toolbar state. A new pane chooses its mounted file view from the persisted mode before `loadView`, so the stored mode and actual child cannot diverge. The window ignores background panes; tab/pane activation continues to refresh through `locationChanged`. `validateNavigation` also synchronizes the Split View toggle state and its Close Left/Right Pane action title; toolbar clicks, overflow commands and the existing shortcut all call `tabs.toggleSplit` through the window.

**Responder chain.** `MainMenu` uses `nil` targets. Window-scope actions live on `MainWindowController` — navigation (`goBack/goForward/goUp/goHome`, `reload`, `editLocation`), tabs (`newTab`, `closeTab`, `reopenClosedTab`, `nextTab`, `previousTab`), split (`toggleSplit`, `focusOtherPane`), sort (`sortBy`, `toggleSortOrder`), `focusFilter`, `toggleHiddenFiles`, `newFolder`, `getInfo`/`getSummaryInfo`/`showInspector` — because they must work whichever pane or chrome view has focus; most forward to `browser`. Selection- and view-scoped actions live on `BrowserViewController` — `copy/cut/paste`, `duplicate`, `moveToTrash`, `deletePermanently`, `renameSelection`, `quickLook`, `viewAsIcons/viewAsList`, `zoomIn/zoomOut/zoomActualSize`, `togglePreviews`, `toggleGroups`, `groupBy`, `copyToOtherPane`/`moveToOtherPane` — so they reach the **focused** pane. Both implement `NSMenuItemValidation`.

**Undo grouping.** `asUndoGroup(_:actionName:_:)` closes any stale automatic group, opens one explicit group, registers, names it, closes it, then closes the event group again — each operation is a self-contained undo group. Undo handlers re-register their inverse (move ⇄ move, copy → trash, rename → rename) and re-post `DirectoryChanges`. The Info window registers its rename on its own `window.undoManager` (D13).

**Error reporting.** `BrowserViewController.report(_:context:)` and `InfoWindowController.report(_:)` print to stdout when `SmokeTest.isRequested` (a modal would hang a headless run), otherwise `presentError`/`NSAlert`. `FileOperations.report` and sidebar Eject errors also suppress modal UI in smoke mode. Settings and server errors appear inline; archive navigation errors use the browser's inline error area.

**Finder-semantics helpers.** `FileListViewController.dropOperation(for:into:sourceMask:)` (⌥ = copy, same volume = move, cross-volume = copy, own folder = no-op) is the one drop rule, used by list, grid, sidebar and tab bar. `FileOperations.uniqueURL` ("Report 2.pdf") and `duplicateURL` ("Report copy.pdf"). `FileOperations.askConflict` is the conflict dialog. `clickedItems` (selection if the clicked row is in it, else the clicked row) is the context-menu target rule.

**Persistence.**

| Where | Keys |
|---|---|
| `ViewPreferences` (UserDefaults) | `viewMode`, `zoom.details`, `zoom.icons`, `groupKey`, `lastGroupKey`, `showPreviews` |
| `AppPreferences.Store` (UserDefaults) | `showFileExtensions` (default true), `experimentalTerminalEnabled` / `experimentalZIPBrowsingEnabled` (default false), `filterShortcutKey` / `filterShortcutModifiers` (default ⌘F) |
| `PlacesModel` (UserDefaults) | `favouritesOrder` (written by `saveOrder`, removed by `resetFavourites`); legacy `favouriteBookmarks` read for migration |
| `InfoSection` (UserDefaults) | `InfoSection.<key>` per section |
| Window | frame autosave name `TursoraMainWindow`; toolbar identifier `TursoraMainToolbar` |
| Filesystem | Finder comments in the `com.apple.metadata:kMDItemFinderComment` xattr; default apps via `NSWorkspace.setDefaultApplication` |
| Environment | `TURSORA_SMOKE_TEST`, `TURSORA_DND_DEBUG` |

The debug binary (no bundle) and `Tursora.app` (bundle id `com.tursora.Tursora`) use different UserDefaults domains.

## 5. Threading

Off the main thread: the **root directory listing** (`DirectoryModel.load` on `.global(qos: .userInitiated)`, result delivered to main and dropped if `loadToken` moved on); **copy/move** (`FileOperations.transfer`; the conflict handler hops back with `DispatchQueue.main.sync` so it can run a modal alert; `progress` and `completion` on main); **size calculation** (`FileInfo.computeSize`, throttled `update` on main every ~0.25 s plus a final call, cancellable); **thumbnails** (`QLThumbnailGenerator`, cache write and coalesced callbacks on main). On the main thread: subfolder listings (`loadChildren`), `trash`/`rename`/`delete`/`duplicate`, all `FileInfo` flag/comment/permission writes, and the FSEvents callback. Bursts are coalesced by `scheduleRefresh` (0.15 s) and `InfoWindowController.scheduleRebuild` (0.15 s).

Archive work runs off-main and delivers completion on main; ZIP preparation is coalesced by `ArchiveWorkspace`, with a browser navigation-generation guard against stale navigation; ordinary directory load tokens still discard stale listings. NetFS async completion is scheduled on main. SwiftTerm manages PTY I/O; explicit terminal shutdown signals only the owned session and reaps its child off-main. No existing shell receives automatic `cd` input.

## 6. The smoke test

`SplitToolbarSmokeTests.run(completion:)` exercises actual toggle/overflow actions, tab and active-pane state changes, and real sidebar-menu dispatch into new tabs or opposite panes without displaying a window. `SidebarContextSmokeTests` separately checks right-click target capture and selection preservation.

Enabled by `TURSORA_SMOKE_TEST`. Application preferences are saved, reset for deterministic integration checks, and restored through `atexit`. Isolated `SettingsSmokeTests` uses its own defaults domain and notification center; server tests use a mock, and terminal tests use a controlled `/bin/sh` PTY without user startup files instead of starting the interactive user shell. `SmokeTest.run(wc)` resets leaked preferences (`ViewPreferences.groupKey = .none`, `lastGroupKey = .kind`, `viewMode = .details`, plus `setGroupKey(.none)`/`setViewMode(.details)` on the browser) and waits for the initial model generation with a 15-second deadline, polling on the main queue. Before navigation, a delayed empty provider verifies waiting beyond one second without blocking the run loop, an isolated Info section verifies width, collapse, and resize behaviour, and new panes verify both persisted view modes. `check(_:_:_:)` prints `ok`/`FAIL` and exits 1 on the first failure; `after(_:_:)` is `asyncAfter` on main. Sections are `private static func`s that end by calling the next one, usually inside an `after`, so the chain is one long asynchronous sequence ending in `SMOKE TEST PASSED`. Temp dirs: `narrowAddressBar` uses `tursora-narrow-<pid>`; `contextMenus` creates `tursora-smoke-<pid>` under `FileManager.temporaryDirectory` and passes it as `tmp` to every later section; `favouritesAndHistory` removes it last.

Order starts with `run` → initial-listing wait → icon / server / settings / archive / ZIP-browser / terminal suites → `delayedListing` → `infoSectionLayout` → `savedViewModes` → preferences integration / window chrome → `navigation` → `insideFolder` → `backHome` → `tabs` → `addressBarEditing` → `narrowAddressBar` → `contextMenus` → `fileOperations` → `copyPaste` → `duplicateAndTrash` → `expansion` → `splitView` → `tabDragSplit` → `viewModes` → `liveRefresh` → `crossTabDrag` → `filterAndConflicts` → `scrollClamp` → `groups` → `conflicts` → `getInfo` → `infoWindow` → `infoWindowFollows` → `favouritesAndHistory` → exit.

## Native archive and server services

`ArchiveOperations.swift` extends `FileOperations` with asynchronous ZIP creation/extraction, private staging, exclusive publication, system metadata and quarantine handling. `BrowserViewController` captures inputs, tracks busy state, registers output undo, and posts directory changes. `ArchiveSmokeTests` covers isolated model operations and malicious fixtures; `SmokeTest.archiveUI` covers both views, menus, grouping/filtering, splits and undo/redo.

`ArchiveWorkspace` retains read-only snapshots until application shutdown, including after tabs or windows close. External applications can keep using opened copies, but no operation writes their edits back into the source ZIP. The logical path is an application location, not a new on-disk directory or registered URL protocol. Full extraction requires temporary disk space; changing the source ZIP does not automatically refresh its snapshot. See [archive browsing research](research/archive-browsing.md) for current verification boundaries.

`ServerConnection` implements `ServerMounting` through NetFS async mount/cancel. `ServerConnectionController` owns address validation and inline state; the system owns authentication. Success returns local file URLs. `PlacesModel` observes workspace mount notifications and classifies network volumes. `ServerConnectionSmokeTests` uses a mock mount service and never contacts a server.

## Product page

`site/` is a separate Chinese static page for editable paths, tabs, split panes and read-only ZIP browsing. It does not participate in the Swift executable or application packaging.

| File | Responsibility |
|---|---|
| `site/index.html` | Product copy, four workflow panels, semantic links and screenshot references. All four workflows remain accessible without JavaScript. |
| `site/styles.css` | Responsive layout, focus states and reduced-motion presentation. |
| `site/main.js` | Progressive enhancement for the workflow selector and screenshot dialog, including keyboard controls and focus restoration. |
| `site/build.py` | Python 3.9+ standard-library build, canonical asset copying and static validation; recreates only `site/dist/` and rejects a symlink at that output path. |

The icon comes from `app/Resources/AppIcon.png`; four screenshots come from `docs/images/features/`. The split screenshot serves both the hero and its feature panel. Build output contains HTML, CSS, JavaScript and one copy of each asset, with relative references for subpath hosting. No Node packages, remote fonts, tracking, embedded external libraries or build-time network requests are required. External links point to GitHub; the builder does not validate live access or artifact availability. Build and browser-review instructions are in [site/README.md](../site/README.md); current verification is recorded in [HANDOFF](HANDOFF.md).

## Search ownership and lifecycle

`SearchRequest` contains Codable scope and AND conditions; `SearchSession` accepts an injectable `SearchBackend` and rejects callbacks after its generation changes. `LocalSearchBackend` traverses ordinary folders off-main for filename/type/date requests and uses an owned NSMetadataQuery on the main run loop for text-content requests. Item hydration happens off-main. `SavedSearchStore` persists only named requests in UserDefaults.

`BrowserSearch.swift` wires each browser's `SearchPanelController` and session to `DirectoryModel.beginSearchResults/replaceSearchResults`. The result container has `DirectoryModel.url == nil` while each `FileItem.url` remains its real source URL, so they cannot become an implicit paste/drop destination; `isSearchResults` also disables unfiltered tree expansion. The browser retains the originating ordinary directory separately for navigation chrome. Session callbacks and search reload completions run on main; navigation clears the session before directory loading. Search-specific selection preservation always uses full URLs, including view-mode changes, rename/undo, duplicate and trash.

Selection mutations use `canModifySelectedItems`; directory destination operations use `canModifyCurrentLocation`. Existing FileOperations and window undo groups remain responsible for filesystem changes. Search rows display Location in the list and an extra parent label in the icon grid. The panel reads/writes saved conditions through its store and never mutates files. `SearchSmokeTests.swift` covers injectable backend lifecycle before real UI integration.

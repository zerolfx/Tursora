# Architecture

Tursora is one Swift executable target, `app/Sources/Tursora`, split into `Model/` (no AppKit views, headlessly testable) and `UI/` (AppKit). Everything is built in code — no nibs, no storyboards. This document is the code map; the intended behaviour is in [SPEC.md](SPEC.md), the reasons in [DECISIONS.md](DECISIONS.md).

## 1. Object graph at runtime

```
NSApplication
└─ AppDelegate                      one LocalFileProvider + one PlacesModel, shared by all windows
   └─ MainWindowController ×N       NSWindow, NSToolbar (delegate), BrowserHost, NSSearchFieldDelegate
      └─ NSSplitViewController
         ├─ SidebarViewController   NSOutlineView over PlacesModel
         └─ TabsController          SearchScopeBar · TabBarView · BreadcrumbBar · container of TabPages · SplitDropOverlay
            └─ TabPage ×tabs        NSSplitView with 1–2 panes, activeIndex, click monitor
               └─ BrowserViewController ×pane
                  ├─ DirectoryModel, NavigationHistory, DirectoryWatcher
                  ├─ fileView: FileViewing  = FileListViewController (always) | IconGridViewController (lazy)
                  ├─ StatusBarView, active-pane indicator, error label, context NSMenu (delegate)
                  └─ QLPreviewPanel data source / delegate
InfoWindowController ×open          static registry `openWindows` + `inspector`; not owned by any window
```

- **`main.swift`** creates `NSApplication`, an `AppDelegate`, sets `.regular` activation policy, runs.
- **`AppDelegate`** owns the one `LocalFileProvider` and the one `PlacesModel`, plus `windowControllers`. `newWindow(at:)` builds a controller, cascades it and installs `wc.onClose`. On launch it builds `MainMenu.build()` and, if `SmokeTest.isRequested`, calls `SmokeTest.run(wc)`. `applicationWillTerminate` closes Info windows so a comment still being typed is saved.
- **`MainWindowController`** (one per window) owns the `NSWindow`, an `NSSplitViewController` (sidebar item + `TabsController` item), the `NSToolbar` (it is the delegate), `SidebarViewController` and `TabsController`. It **is** the `BrowserHost` (`tabs.host = self`) and the delegate of the toolbar's `NSSearchToolbarItem`. It holds `backButton`/`forwardButton` (`LongPressMenuButton`), `viewModeControl`, `searchItem`, and two local `NSEvent` monitors (⌃Tab, ⌘1–9, ⌘=; mouse buttons 4/5).
- **`TabsController`** owns, top to bottom in one `NSStackView`: `SearchScopeBar`, `TabBarView`, `BreadcrumbBar` (`addressBar`), and a container holding every `TabPage` view plus a `SplitDropOverlay`. State: `pages`, `currentIndex`, `closedTabs` (max 10). Callbacks out: `onCurrentLocationChanged`, `onTabsChanged`.
- **`TabPage`** = one tab: 1–2 `BrowserViewController`s in a vertical-divider `NSSplitView` (it is the delegate), `activeIndex`, and a click monitor that activates whichever pane was clicked. Callbacks out: `onActivePaneChanged`, `onPaneLocationChanged`.
- **`BrowserViewController`** = one pane. Owns a `DirectoryModel`, a `NavigationHistory`, the two file views (current one as `fileView: FileViewing`), `StatusBarView`, the pane's context menu (it is the `NSMenuDelegate`) and a `DirectoryWatcher`. `weak var host: BrowserHost?` reaches the window.
- **`FileViewing`** is the protocol both file views implement; the browser is the sole consumer of their closures.
- **Chrome** (toolbar, breadcrumb, tab bar, scope bar, completion popup) is window-level and always reflects `tabs.currentPage.active`.

## 2. Per file

### Model/

| File | Responsibility |
|---|---|
| `FileProvider.swift` | `protocol FileProvider` (`listDirectory(_:)`, `homeURL`, `displayName(for:)`) — the single filesystem seam; `LocalFileProvider` implements it with `FileManager`. `listDirectory` blocks; callers run it off the main thread. |
| `FileItem.swift` | Immutable value for one listing entry: `url, name, isDirectory, isPackage, isHidden, isSymlink, size, modificationDate, creationDate, accessDate, addedDate, tags, contentType`, all read once via `resourceKeys`. Derived: `isNavigable`, `icon(size:)`, `kindDescription`, `displaySize`, `displayDate`. Never re-stats during sort or draw. |
| `DirectoryModel.swift` | `FileNode` (class, identity-stable across reloads, keyed by URL) and `DirectoryModel`: `url`, `allNodes`, `nodes`, `groups`, `generation`, and the arrangement inputs `showHidden`, `nameFilter`, `groupKey`, `foldersFirst`, `sortKey`, `ascending` (each `didSet` → `resort()`). `load(_:completion:)` lists off-main with a `loadToken` guard and merges into existing nodes; `reload`, `setSort`, `loadChildren(of:refresh:)` (synchronous), `node(for:)`, `indexOf(url:)`, `item(at:)`, `matches(_:filter:)` (wildcards when `*`/`?`). Private `arrange` = hidden filter + name filter + sort, recursing into loaded children. Never mutates the filesystem. |
| `DirectoryWatcher.swift` | FSEvents wrapper (file events, 0.25 s latency, dispatched on main). Also defines `Notification.Name.tursoraDirectoriesChanged` and `enum DirectoryChanges` with `post(_:renamed:)` and `affected(sources:destination:)`. |
| `Grouping.swift` | `GroupKey` (Finder's ten keys), `GroupNode` (title + nodes + sort order), and the pure `Grouping.split(_:by:now:)` with `nameBucket`, `kindBucket`, `applicationBucket`, `dateBucket`, `sizeBucket`, `tagBucket`. No UI, no I/O beyond `NSWorkspace.urlForApplication`. |
| `NavigationHistory.swift` | Linear `entries` + `index`; `push` (dedupes the current URL, truncates forward, trims to 100), `goBack`, `goForward`, `go(to:)`, `recordViewState(selectedName:scrollOffset:)`, `backEntries`/`forwardEntries` for the long-press menus. Knows nothing about views. |
| `FileOperations.swift` | All mutation: `uniqueURL`, `duplicateURL`, `rename` (via the name resource, so case-only renames work on APFS), `trash` (returns original/trashed pairs), `delete`, `sameVolume`, `duplicate`, and `transfer(_:to:kind:conflict:progress:completion:)` with `BatchPolicy` (apply-to-all) and recursive `merge`. UI-facing helpers: `askConflict(in:_:)` (Finder's conflict dialog rebuilt: Keep Both / Merge / Skip / Stop / Replace + "Apply to all") and `report(_:in:)`. |
| `FileInfo.swift` | Every fact behind Get Info, computed headlessly: `whereString`, `dateString`, `Size` + `computeSize(of:countingChildren:update:)` → cancellable `SizeCalculation`, `sizeString`/`headerSizeString`, `isLocked`/`setLocked`, `hasHiddenExtension`/`setHiddenExtension`, `comment`/`setComment` (xattr `com.apple.metadata:kMDItemFinderComment`), `moreInfo` (Spotlight), `bundleInfo`, `volumeInfo`, `original`, `applications(toOpen:)`, `Permissions`/`Privilege`/`Who`, `privilege`, `mode(_:setting:for:isFolder:)`, `setMode`, `accessSummary`, `fileID`/`sibling(of:withFileID:)`, `kind`, `summaryKind`. Reads flags through `FileManager.attributesOfItem`, not URL resource values (D15). |
| `PlacesModel.swift` | Sidebar data: `Section`/`Place`, rebuilt from `builtIns()` + user paths in one persisted order list, plus mounted volumes. `favouriteIndex(of:)`, `isFavourite`, `addFavourite(_:at:)`, `removeFavourite`, `moveFavourite(from:to:)`, `resetFavourites`, `isEjectable`. Posts `PlacesModel.didChange`; observes `NSWorkspace` mount/unmount/rename. |
| `PathCompleter.swift` | Pure: `resolveDirectory(_:cwd:home:)`, `completions(for:cwd:home:includeHidden:)` (directories only, trailing `/`, packages skipped), `splitLastComponent`. |
| `ThumbnailProvider.swift` | Singleton Quick Look thumbnail cache: `canPreview(_:)`, `thumbnail(for:size:scale:completion:)` returns a cached image synchronously or calls back on main; `NSCache` keyed by path·size·mtime·bytes, coalesced `pending`, remembered `unsupported`. |
| `ZoomLevel.swift` | `ViewMode`, the two zoom ladders, `defaultIndex`, `clamp`, `previewThreshold = 32`; `ViewPreferences` is the only reader/writer of the view-related `UserDefaults` keys. |

### UI/

| File | Responsibility |
|---|---|
| `MainWindowController.swift` | Window, toolbar, split view, sidebar wiring, the `BrowserHost` implementation (`isSplit`, `openInNewTab`, `openInNewWindow`, `openInOtherPane`, `transferToOtherPane`, `viewModeDidChange`), the toolbar filter field (`applyFilter`, `cancelFilter`, `focusFilter`, `syncFilterUI`), `locationChanged` (title, subtitle, `representedURL`, sidebar sync, validation), the window-scope menu actions and `validateMenuItem`/`validateToolbarItem`. |
| `TabsController.swift` | Tab lifecycle (`newTab`, `closeTab(at:)`, `closeCurrentTab`, `reopenClosedTab`, `selectTab/Next/Previous`, `moveTab`), split operations (`isSplit`, `toggleSplit`, `openInOtherPane`, `focusOtherPane`, `canSplit(withTab:)`, `splitCurrentPage(withTab:side:)`, `splitSide(at:)`), file drops on the strip (`filesDropped`), and `refreshChrome()` (tab titles, tab-bar visibility, address-bar URL, `onTabsChanged`). Also `SplitDropOverlay`. |
| `TabPage.swift` | `PaneSide`, pane list, `split(with:side:)`, `adopt`, `releaseActivePane`, `closePane`/`closeActivePane`, `activate`/`activateOther`, `updateIndicators`, split-view constraints (min 160 pt, never collapses) and the click monitor. Wires each pane's `onLocationChanged`/`onFocus`. |
| `BrowserViewController.swift` | The pane controller and the responder for selection-scoped commands: `navigate(to:)`, `goBack/goForward/goUp/goHome/goToHistory(slot:)`, `reload()`, `historyMenu(back:)`, `nameFilter`/`isFiltering`/`filterSummary`, `setViewMode`, `setZoomIndex`/`zoom(by:)`, `setShowsPreviews`, `setGroupKey`, `newFolder()`, `copy/cut/paste/duplicate/moveToTrash/deletePermanently/renameSelection/quickLook`, `rename(_:to:)`, `trash(_:)`, `dropFiles(_:to:op:)`, `buildContextMenu(for:)`, `getInfo/getSummaryInfo/showInspector`, `infoTargets`, `updateStatus`, `displayedDirectories`, `scheduleRefresh`, `refreshPreservingSelection`, `report(_:context:)`. Private: `load`, `transfer`, `asUndoGroup`, `registerUndoMove/Trash/Rename`, `saveViewState`/`restoreViewState`. **The only place panes talk to `FileOperations`.** |
| `FileViewing.swift` | The view-swap contract: closures in (`onOpen`, `onOpenInNewTab`, `onRenameCommitted`, `onSelectionChanged`, `onFocus`, `onQuickLook`, `onDropFiles`, `onZoomGesture`), commands out (`reloadData`, `select(name:)`/`select(names:)`, `openSelection`, `beginRename(item:)`, `itemAfterSelection`, `setIconSize(_:showPreviews:)`, `frameOnScreen(for:)`, `forwardKey`, `scrollOffset`, `selectedItems`, `clickedItems`, `cutURLs`, `contextMenu`). Views must not navigate, mutate files, or drive Quick Look themselves. |
| `FileListViewController.swift` | Details view over `NSOutlineView` (`FileOutlineView`): four columns, group rows for `GroupNode`, expand-in-place with `expandedURLs` tracking, `reloadData()` that refreshes expanded children before `tableView.reloadData()` when `model.generation` changed, inline rename with Finder's base-name preselection, sort via `sortDescriptors`, drag source, and the static Finder rule `dropOperation(for:into:sourceMask:)` reused by the grid, sidebar and tab bar. `FileOutlineView` adds Return/Space, middle click, ⌘-scroll/pinch zoom, and the delayed click-to-rename with drag guards (`renameCandidate`, `renameAllowedAfterMouseUp`, `scheduleRename`, `cancelPendingRename`). |
| `IconGridViewController.swift` | Icon view over `NSCollectionView`; one section per `GroupNode` with sticky `GroupHeaderView`; `FileCollectionItem` draws Finder-style selection and does label rename; `FileCollectionView` adds Return/Space, zoom gestures and `clickedIndexPath`. Same `FileViewing` surface; drop rules delegated to `FileListViewController.dropOperation`. |
| `SidebarViewController.swift` | Source-list outline over `PlacesModel`; `row(for:)`, `syncSelection(to:)`, `reorderTargetIndex(item:childIndex:pointerY:)`, context menu (Open / New Tab / Reveal / Remove / Reset / Eject), three drop kinds: reorder a favourite (private `com.tursora.place` type), add dropped folders as favourites, drop files onto a place (`onDropFiles`). Never performs the transfer itself. |
| `BreadcrumbBar.swift` | Dolphin's URL navigator: `url`, `onNavigate`, `onEndEditing`, `beginEditing()`/`endEditing()`/`commit(_:)`, static `segments(for:home:)`, manual layout with overflow folding and shrinking, `subfolderMenu(of:current:)`, and edit-mode completion (`textChanged`, `accept(candidate:)`, `acceptCompletion`, `typedText`, `inlineCompletion`) driving `CompletionPopup`. |
| `CompletionPopup.swift` | Non-activating borderless child panel with a click-only table: `show(_:below:in:)`, `hide()`, `moveSelection(by:)`, `selectedCandidate`, `candidates`. |
| `TabBarView.swift` | Draws tabs; `reload(titles:selected:)`, reorder by drag, drag-below-the-strip reporting (`onDragOutside`/`onDropOutside`), file drops (`dropOperationForTab`, `performDrop(urls:sourceMask:onTabAt:)`, `beginAutoActivation`, `autoActivationDelay = 0.8`). `TabItemView` handles hover, close button, middle-click close. |
| `SearchScopeBar.swift` | Passive: `folderName`, `folderIcon`, `summary`, fixed height 30. |
| `StatusBarView.swift` | `update(itemCount:totalCount:selectedCount:directory:)`, `setZoom(index:count:)`/`onZoomChanged`, `beginBusy`/`endBusy` (nested-safe spinner). |
| `InfoWindowController.swift` | Get Info / Summary / Inspector. Statics: `show(for:relativeTo:)` (>10 items → summary; an existing window is re-fronted), `showSummary`, `showInspector`, `closeAll`, `openWindows`, `inspectorWindow`. Instance: `rebuild()` (tears down and rebuilds all sections), `scheduleRebuild()` (150 ms debounce), `isEditing`/`rebuildDeferred`, section builders (`generalContent`, `nameContent`, `commentsContent`, `openWithContent`, `previewContent`, `sharingContent`), `commitRename`, `saveComment`, `setLocked`, `setHiddenExtension`, `setPrivilege`, `setDefaultApplication`, `follow(_:to:)`, `parentsChanged`, `fitWindow`, `sync(with:force:)`/`syncWithMainWindow`, plus test accessors. Also `InfoSection` (collapsible, persists its own expansion) and the `canBecomeMain == false` window/panel subclasses. Defines `.tursoraSelectionChanged`. |
| `LongPressMenuButton.swift` | Click fires the action; long-press (0.35 s) or right-click pops `menuProvider()`. |
| `ViewHelpers.swift` | `NSView.pinToEdges(_:insets:)`, `NSTableCellView.make(identifier:withIcon:alignment:iconSize:)`. |
| `MainMenu.swift` | Builds the whole menu bar in code with `nil` targets so the responder chain resolves them; `groupByMenuItem()` is shared with the toolbar Group item; `MenuIcons.image` resolves `"a|b"` SF Symbol fallbacks. |
| `SmokeTest.swift` | See §6 and [DEVELOPMENT.md](DEVELOPMENT.md). |

## 3. Data flow walkthroughs

**(a) Navigate to a folder.**
1. `BrowserViewController.navigate(to:)` → `saveViewState()` (`history.recordViewState`) → `history.push(url)` → `load(url)`.
2. `load` sets `currentURL`, clears the error, cancels `refreshDebounce`, clears `nameFilter` if the directory changed, creates a new `DirectoryWatcher`, calls `model.load(url) { restoreViewState() }`, then `onLocationChanged?(url)` and posts `.tursoraSelectionChanged`.
3. `DirectoryModel.load` lists off-main, merges, bumps `generation`, `resort()` → `Grouping.split` → `onChange`.
4. `onChange` → `fileView.reloadData()` + `updateStatus()`.
5. The completion runs `restoreViewState()` (pending selection, else the history entry's `selectedName`/`scrollOffset`).
6. `onLocationChanged` → `TabPage.onPaneLocationChanged` → `TabsController.refreshChrome()` (tab titles + `addressBar.url`) and, for the active pane of the current tab, `onCurrentLocationChanged` → `MainWindowController.locationChanged` → window title/subtitle/`representedURL`, `sidebar.syncSelection(to:)`, `validateNavigation()`, `syncFilterUI()`.

**(b) Move by drag, with undo.**
1. `FileListViewController.acceptDrop` (or the grid / sidebar / tab bar) computes `dropOperation(for:into:sourceMask:)` and calls `onDropFiles`.
2. → `BrowserViewController.dropFiles(_:to:op:)` → private `transfer(...)`: `statusBar.beginBusy()`, `FileOperations.transfer` with `conflict: { FileOperations.askConflict(in: window, $0) }`.
3. Completion on main: `endBusy()`, `registerUndoMove(result.moved, actionName: "Move")` (or `registerUndoTrash` for copies) inside `asUndoGroup`.
4. `reloadSelecting(names)` if the destination is this pane, else `reload()`.
5. `DirectoryChanges.post(DirectoryChanges.affected(sources:destination:))` → every other pane and Info window observing `.tursoraDirectoriesChanged` refreshes.
6. `FileOperations.report(result.failures, in: window)`.

**(c) Outside change.** FSEvents → `DirectoryWatcher` handler on main → `BrowserViewController.fileSystemChanged(paths)` → `isDisplaying(path)` (symlinks resolved on both sides; matches `displayedDirectories` = current URL + `fileList.expandedFolderURLs`) → `scheduleRefresh(after: 0.15)` (debounced) → `refreshPreservingSelection()`: capture selected names (mapped through `pendingRenames`) and `scrollOffset`, `model.reload`, re-`select(names:)`, restore the offset. The in-app path is identical from `scheduleRefresh` on, entered via `directoriesChanged(_:)`.

**(d) Selection → status bar / Quick Look / Inspector.** View selection change → `FileViewing.onSelectionChanged` → browser closure: `updateStatus()`, post `.tursoraSelectionChanged` with `object: self`, `panel.reloadData()` if a visible `QLPreviewPanel` exists. The Inspector observes the notification, checks the poster is the active pane of the main (or key, or only) `MainWindowController`, then `sync(with:)` → `urls = selection` (or the folder when empty) → `scheduleRebuild()`.

**(e) Filter and groups.** Typing in the toolbar field → `controlTextDidChange` → `MainWindowController.applyFilter` → `browser.nameFilter` → `DirectoryModel.nameFilter` `didSet` → `resort()` → `arrange` → `Grouping.split` → `onChange` → `reloadData` + `updateStatus`; then `syncFilterUI()` updates the scope bar. Groups: View ▸ Group By / toolbar Group menu → `groupBy` or `toggleGroups` → `setGroupKey` → `model.groupKey` `didSet` → same path; `ViewPreferences.groupKey`/`lastGroupKey` are written. The list renders `model.groups` as group rows; the grid as one section per group.

**(f) Get Info build / rebuild.** ⌘I → `MainWindowController.getInfo` → `browser.getInfo` → `InfoWindowController.show(for: infoTargets, relativeTo:)` → registry check → `init` → `buildChrome()` + `rebuild()`. `rebuild()` cancels the size calculation, saves any comment, empties the stack, adds header + `general`, `moreInfo`, `name`, `comments`, `openWith` (files only), `preview`, `sharing`, records `fileIDs`, starts the size calculation, watches the parent, fits the window. Rebuilds are deferred while `isEditing` and resumed from `controlTextDidEndEditing`/`textDidEndEditing`. Renames: in-app ones arrive as `.tursoraDirectoriesChanged` with `renamedFrom`/`renamedTo` → `follow(from:to:)` rewrites `urls` and every per-section URL; outside renames arrive via FSEvents → `parentsChanged()` → for missing items `FileInfo.sibling(of:withFileID:)` finds the same inode → `follow`. A truly deleted item closes the window (the Inspector re-syncs instead).

## 4. Cross-cutting conventions

**Callbacks vs notifications.** Parent/child links are closures (`on…`); anything that crosses panes, tabs or windows is a notification.

| Name | Defined in | Posted by | Observed by |
|---|---|---|---|
| `.tursoraDirectoriesChanged` (`"tursora.directoriesChanged"`, userInfo `directories`, optional `renamedFrom`/`renamedTo`) | `DirectoryWatcher.swift` | `DirectoryChanges.post` — from `BrowserViewController` (`newFolder`, `duplicate`, `trash`, `deletePermanently`, `rename`, `transfer`, undo) and `InfoWindowController` (`rename`, `toggleLocked`, `toggleHiddenExtension`, `setPrivilege`) | `BrowserViewController.directoriesChanged`, `InfoWindowController.directoriesChanged` |
| `.tursoraSelectionChanged` (`"tursora.selectionChanged"`, object = the pane) | `InfoWindowController.swift` | `BrowserViewController` (selection closure, and `load`) | `InfoWindowController` in `.inspector` mode |
| `PlacesModel.didChange` | `PlacesModel.swift` | `PlacesModel.notify()` (mount/unmount/rename, `saveOrder`, `resetFavourites`) | `SidebarViewController.placesChanged` |

Plus AppKit's `NSWorkspace.didMount/didUnmount/didRenameVolume` (PlacesModel) and `NSWindow.didBecomeMainNotification` (Inspector).

**View-mode toolbar sync.** After a pane mounts its new file view, `BrowserHost.viewModeDidChange(in:)` asks the window to validate toolbar state. A new pane chooses its mounted file view from the persisted mode before `loadView`, so the stored mode and actual child cannot diverge. The window ignores background panes; tab/pane activation continues to refresh through `locationChanged`.

**Responder chain.** `MainMenu` uses `nil` targets. Window-scope actions live on `MainWindowController` — navigation (`goBack/goForward/goUp/goHome`, `reload`, `editLocation`), tabs (`newTab`, `closeTab`, `reopenClosedTab`, `nextTab`, `previousTab`), split (`toggleSplit`, `focusOtherPane`), sort (`sortBy`, `toggleSortOrder`), `focusFilter`, `toggleHiddenFiles`, `newFolder`, `getInfo`/`getSummaryInfo`/`showInspector` — because they must work whichever pane or chrome view has focus; most forward to `browser`. Selection- and view-scoped actions live on `BrowserViewController` — `copy/cut/paste`, `duplicate`, `moveToTrash`, `deletePermanently`, `renameSelection`, `quickLook`, `viewAsIcons/viewAsList`, `zoomIn/zoomOut/zoomActualSize`, `togglePreviews`, `toggleGroups`, `groupBy`, `copyToOtherPane`/`moveToOtherPane` — so they reach the **focused** pane. Both implement `NSMenuItemValidation`.

**Undo grouping.** `asUndoGroup(_:actionName:_:)` closes any stale automatic group, opens one explicit group, registers, names it, closes it, then closes the event group again — each operation is a self-contained undo group. Undo handlers re-register their inverse (move ⇄ move, copy → trash, rename → rename) and re-post `DirectoryChanges`. The Info window registers its rename on its own `window.undoManager` (D13).

**Error reporting.** `BrowserViewController.report(_:context:)` and `InfoWindowController.report(_:)` print to stdout when `SmokeTest.isRequested` (a modal would hang a headless run), otherwise `presentError`/`NSAlert`. `FileOperations.report` always uses an `NSAlert`.

**Finder-semantics helpers.** `FileListViewController.dropOperation(for:into:sourceMask:)` (⌥ = copy, same volume = move, cross-volume = copy, own folder = no-op) is the one drop rule, used by list, grid, sidebar and tab bar. `FileOperations.uniqueURL` ("Report 2.pdf") and `duplicateURL` ("Report copy.pdf"). `FileOperations.askConflict` is the conflict dialog. `clickedItems` (selection if the clicked row is in it, else the clicked row) is the context-menu target rule.

**Persistence.**

| Where | Keys |
|---|---|
| `ViewPreferences` (UserDefaults) | `viewMode`, `zoom.details`, `zoom.icons`, `groupKey`, `lastGroupKey`, `showPreviews` |
| `PlacesModel` (UserDefaults) | `favouritesOrder` (written by `saveOrder`, removed by `resetFavourites`); legacy `favouriteBookmarks` read for migration |
| `InfoSection` (UserDefaults) | `InfoSection.<key>` per section |
| Window | frame autosave name `TursoraMainWindow`; toolbar identifier `TursoraMainToolbar` |
| Filesystem | Finder comments in the `com.apple.metadata:kMDItemFinderComment` xattr; default apps via `NSWorkspace.setDefaultApplication` |
| Environment | `TURSORA_SMOKE_TEST`, `TURSORA_DND_DEBUG` |

The debug binary (no bundle) and `Tursora.app` (bundle id `com.tursora.Tursora`) use different UserDefaults domains.

## 5. Threading

Off the main thread: the **root directory listing** (`DirectoryModel.load` on `.global(qos: .userInitiated)`, result delivered to main and dropped if `loadToken` moved on); **copy/move** (`FileOperations.transfer`; the conflict handler hops back with `DispatchQueue.main.sync` so it can run a modal alert; `progress` and `completion` on main); **size calculation** (`FileInfo.computeSize`, throttled `update` on main every ~0.25 s plus a final call, cancellable); **thumbnails** (`QLThumbnailGenerator`, cache write and coalesced callbacks on main). On the main thread: subfolder listings (`loadChildren`), `trash`/`rename`/`delete`/`duplicate`, all `FileInfo` flag/comment/permission writes, and the FSEvents callback. Bursts are coalesced by `scheduleRefresh` (0.15 s) and `InfoWindowController.scheduleRebuild` (0.15 s).

## 6. The smoke test

Enabled by `TURSORA_SMOKE_TEST`. `SmokeTest.run(wc)` resets leaked preferences (`ViewPreferences.groupKey = .none`, `lastGroupKey = .kind`, `viewMode = .details`, plus `setGroupKey(.none)`/`setViewMode(.details)` on the browser) and waits for the initial model generation with a 15-second deadline, polling on the main queue. Before navigation, a delayed empty provider verifies waiting beyond one second without blocking the run loop, an isolated Info section verifies width, collapse, and resize behaviour, and new panes verify both persisted view modes. `check(_:_:_:)` prints `ok`/`FAIL` and exits 1 on the first failure; `after(_:_:)` is `asyncAfter` on main. Sections are `private static func`s that end by calling the next one, usually inside an `after`, so the chain is one long asynchronous sequence ending in `SMOKE TEST PASSED`. Temp dirs: `narrowAddressBar` uses `tursora-narrow-<pid>`; `contextMenus` creates `tursora-smoke-<pid>` under `FileManager.temporaryDirectory` and passes it as `tmp` to every later section; `favouritesAndHistory` removes it last.

Order: `run` → initial-listing wait → `delayedListing` → `infoSectionLayout` → `savedViewModes` → `navigation` → `insideFolder` → `backHome` → `tabs` → `addressBarEditing` → `narrowAddressBar` → `contextMenus` → `fileOperations` → `copyPaste` → `duplicateAndTrash` → `expansion` → `splitView` → `tabDragSplit` → `viewModes` → `liveRefresh` → `crossTabDrag` → `filterAndConflicts` → `scrollClamp` → `groups` → `conflicts` → `getInfo` → `infoWindow` → `infoWindowFollows` → `favouritesAndHistory` → exit.

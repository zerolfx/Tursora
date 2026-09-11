## Dolphin core decoupling — the `libDolphinCore` boundary

### Verdict up front

Dolphin is **already split along almost exactly the line we need**, and the split is better than expected. Upstream ships four CMake targets (`src/CMakeLists.txt:24, 59, 263, 285, 511`), and the shared library `dolphinprivate` contains the entire item-view framework *plus* `DolphinView` — i.e. the model layer, the async metadata/thumbnail engine, view-properties persistence and the VCS observer are all in a reusable `.so` today.

The decisive finding for Phase 3 is that **`kitemviews/` is genuinely bisected**: the model half has *zero* references to the render half.

| direction | occurrences | evidence |
|---|---|---|
| render half → `KFileItemModel` | **0** in `kitemlistview.cpp`, **0** in `kitemlistcontroller.cpp` | `grep -c KFileItemModel src/kitemviews/kitemlistview.cpp` → 0 |
| model half → `KItemListView` | **0** (one prose mention in a doc comment) | `src/kitemviews/kfileitemmodel.h:483` |
| `KFileItemModelRolesUpdater` → view | **0** | `src/kitemviews/kfileitemmodelrolesupdater.h:86` takes only `KFileItemModel*`; drive point is `setVisibleIndexRange(int,int)` at `:99` |

`KFileItemModelRolesUpdater` is driven purely by *integer index ranges* (`src/kitemviews/kfileitemlistview.cpp:388-390, 420`). An `NSCollectionView` can supply those ranges from `-visibleRect` exactly as `KFileItemListView` does. **Phase 3 is architecturally viable.** The residual coupling is three small, named, upstreamable defects listed in §4.

---

### 1. What upstream already ships

| target | kind | contents | `src/CMakeLists.txt` |
|---|---|---|---|
| `dolphinvcs` | SHARED, installed, exported as `Dolphin::DolphinVcs` | exactly one file: `views/versioncontrol/kversioncontrolplugin.cpp` | `:24-56` |
| `dolphinprivate` | SHARED, installed (namelink skipped) | all of `kitemviews/` (incl. `private/`, `accessibility/`), `views/dolphinview.cpp`, `views/viewproperties.cpp`, `views/versioncontrol/{versioncontrolobserver,updateitemstatesthread}.cpp`, `views/dolphinviewactionhandler.cpp`, `views/draganddrophelper.cpp`, `views/zoomlevelinfo.cpp`, `settings/viewpropertiesdialog.cpp`, `selectionmode/actiontexthelper.cpp`, `dolphinnewfilemenu.cpp`, **plus all 8 generated `KConfigSkeleton` classes** | `:59-260` |
| `dolphinstatic` | STATIC (not installed) | the *shell*: `dolphinmainwindow`, `dolphintabwidget/tabpage/tabbar`, `dolphinviewcontainer`, `dolphincontextmenu`, `dolphinurlnavigator*`, all of `panels/`, `search/`, `selectionmode/`, `settings/`, `statusbar/`, `filterbar/`, `admin/`, `trash/`, **+ the D-Bus adaptor** | `:285-509` |
| `dolphin` | executable | `main.cpp` + `dbusinterface.cpp` only | `:511-547` |

So the shell is ~13.3 k LOC of top-level `.cpp/.h` plus the subdirectory widgets; the reusable library is the rest. `dolphinvcs` links `Qt6::Widgets` **publicly** (`:34`), so QtWidgets leaks into every consumer of `dolphinprivate` transitively; `dolphinprivate` itself only names `Qt6::Gui` (`:222`) but also pulls `KF6::KIOWidgets` (`:227`), `KIOFileWidgets` (`:228`), `TextWidgets` (`:230`), `NewStuffWidgets` (`:232`), `Parts` (`:233`), `KCMUtils` (`:237`) — all QtWidgets-based.

---

### 2. Component inventory

LOC = `wc -l` of the listed `.cpp` + `.h`. "QtW" = QtWidgets, "KXG" = KXmlGui/`KActionCollection`, "KIOW" = KIOWidgets/KIOFileWidgets.

#### 2a. Shell / window layer (all in `dolphinstatic`)

| component | files | LOC | responsibility | QtW | KXG | KIOW | verdict |
|---|---|---|---|:--:|:--:|:--:|---|
| `DolphinMainWindow` | `dolphinmainwindow.{cpp,h}` | 4081 | menus, toolbars, ~120 actions, session restore, D-Bus adaptor | ✔ `KXmlGuiWindow` (`dolphinmainwindow.h:72`) | ✔ | ✔ | **replace** (AppKit `NSWindowController`) |
| `DolphinTabWidget` | `dolphintabwidget.{cpp,h}` | 945 | tab set, `saveProperties`/`readProperties`, `isUrlOpen`, `isItemVisibleInAnyView` | ✔ `QTabWidget` (`:21`) | – | – | **replace**, but ~40 % is portable state logic |
| `DolphinTabPage` (+`Splitter`) | `dolphintabpage.{cpp,h}` | 901 | split-view state machine, `QByteArray saveState()/restoreState()` (`dolphintabpage.h:127,133`) | ✔ `QWidget`+`QSplitter` (`:24,253`) | – | – | **replace**; extract state machine |
| `DolphinTabBar` | `dolphintabbar.{cpp,h}` | 335 | DnD onto tabs, middle-click close | ✔ `QTabBar` | – | – | replace (`NSTabView`/toolbar) |
| `DolphinViewContainer` | `dolphinviewcontainer.{cpp,h}` | 1746 | glues navigator + view + filter bar + status bar + message widget + admin bar | ✔ `QWidget` (`:62`) | ✔ | ✔ | **replace**; it is pure assembly + policy |
| `DolphinNavigatorsWidgetAction` | `dolphinnavigatorswidgetaction.{cpp,h}` | 676 | puts one/two URL navigators *into the toolbar*, aligns them with the split | ✔ `QWidgetAction` (`:39`) | ✔ | – | **replace** (macOS toolbar item) |
| `DolphinUrlNavigator` | `dolphinurlnavigator.{cpp,h}` | 267 | Dolphin policy on top of `KUrlNavigator` | ✔ `KUrlNavigator : QWidget` (kio `src/filewidgets/kurlnavigator.h:76`) | – | ✔ | **replace** — but see §3, history is separable |
| `DolphinUrlNavigatorsController` | `…scontroller.{cpp,h}` | 146 | static registry applying settings to all navigators | – (`QObject`) | – | – | replace (trivial) |
| `DolphinContextMenu` | `dolphincontextmenu.{cpp,h}` | 693 | builds the right-click menu from `KFileItemActions`, `KFileCopyToMenu`, service menus | ✔ `QMenu` (`:34`) | ✔ | ✔ | **replace** with `NSMenu`; keep `KFileItemActions` as the *data source* |
| `DolphinNewFileMenu` | `dolphinnewfilemenu.{cpp,h}` | 76 | 1 overridden slot on `KNewFileMenu` for error routing | ✔ `KNewFileMenu` | – | ✔ | replace; `KNewFileMenu` templates come from KIO |
| `DolphinRecentTabsMenu`, `DolphinRemoveAction`, `DolphinBookmarkHandler` | 3 pairs | ~370 | `KActionMenu`/`QAction`/`KBookmarkOwner` | ✔ | ✔ | – | replace |
| `Trash` singleton | `trash/dolphintrash.{cpp,h}` | 149 | `KDirLister` on `trash:/`, `emptinessChanged` | only `empty(QWidget*)` | – | ✔ (`DeleteOrTrashJob`) | **reusable with patches** — see §5 |
| `global.{cpp,h}` | 2 | 292 | `homeUrl()`, `validateUris()`, `sortOrderForUrl()`, `animationDurationFactor()` **+ D-Bus single-instance** | `QWidget*` param on `openNewWindow` (`global.h:35`) | – | – | **split**: config half → core, `attachToExistingInstance`/`dolphinGuiInstances` (`global.cpp:141-166`, session bus) → macOS replacement |

#### 2b. `kitemviews/` — model half (the prize)

| component | files | LOC | responsibility | QtW | verdict |
|---|---|---|---|:--:|---|
| `KItemModelBase` | `kitemmodelbase.{cpp,h}` | 511 | abstract index-based model: `count()`, `data(int)→SmallHash`, sort/group roles, expand tree, `createMimeData`, `url(int)`, `isDir(int)` | **none** — `QObject`, includes only `QHash/QObject/QUrl/QVariant` (`kitemmodelbase.h:17-20`) | **reuse as-is** |
| `KFileItemModel` | `kfileitemmodel.{cpp,h}` | 3921 | `KDirLister`-backed directory model; sorting (`QCollator`), grouping, filtering, recursive expansion, drop support | **one line**: `qobject_cast<QWidget*>(parent)` for `KDirLister::setMainWindow` (`kfileitemmodel.cpp:292`) | **reuse with a 3-line patch** |
| `KFileItemModelFilter` | `private/kfileitemmodelfilter.{cpp,h}` | 277 | name-filter (wildcard/regex/case) + MIME filter | none | reuse as-is |
| `KFileItemModelSortAlgorithm` | `private/…sortalgorithm.h` | 122 | parallel merge sort with an injected comparator | none | reuse as-is |
| `KItemSet` / `KItemRange` | `kitemset.{cpp,h}`, `kitemrange.h` | 892 | range-compressed index sets | none | reuse as-is |
| `SmallHash` | `smallhash.h` | 121 | flat `vector<pair<QByteArray,QVariant>>` replacing per-item `QHash` (3 KB/span) | none | reuse as-is; **this is the bridge payload type** |
| `KFileItemModelRolesUpdater` | `kfileitemmodelrolesupdater.{cpp,h}` | 1979 | **the async engine**: `KIO::PreviewJob` thumbnails, MIME resolution, icon overlays (`KOverlayIconPlugin`), directory-content counting, Baloo metadata, hover thumbnail sequences | 2 lines: `qApp->activeWindow()` (`:980, :1092`) | **reuse with a 6-line patch** — see §4 |
| `KDirectoryContentsCounter(Worker)` | `private/kdirectorycontentscounter*.{cpp,h}` | 456 | threaded folder-size/child-count, `KDirWatch` invalidation | none | reuse as-is (`KDirWatch` on macOS is a separate audit item) |
| `KFileItemClipboard` | `private/kfileitemclipboard.{cpp,h}` | ~130 | tracks cut items for the "faded" look | `QApplication::clipboard()` → swap to `QGuiApplication` | reuse with 1-line patch |
| `KItemListSelectionManager` | `kitemlistselectionmanager.{cpp,h}` | 492 | current item, anchored ranges, index fix-up on insert/remove/move | none (`QObject`) | **reuse with patch** — private API + `friend KItemListView` (`:90-92`), see §4 |
| `kfileitemlisttostring` | `kfileitemlisttostring.{cpp,h}` | 173 | "3 folders, 2 files" summary strings | `QFontMetrics` (QtGui, fine) | reuse as-is |

Model half total ≈ **9.0 k LOC**, of which the QtWidgets contact surface is **4 lines**.

#### 2c. `kitemviews/` — render half + controller

| component | files | LOC | base class | verdict |
|---|---|---|---|---|
| `KItemListView` | `kitemlistview.{cpp,h}` | 3991 | `QGraphicsWidget` (`:55`) | Qt-only; keep for Phase 2, dead code in Phase 3 |
| `KItemListWidget(Informant)` | `kitemlistwidget.{cpp,h}` | 992 | `QGraphicsWidget` (`:52`) | Qt-only |
| `KStandardItemListView/Widget/GroupHeader` | 6 files | 2597 | `KItemListView`/`KItemListWidget` | Qt-only |
| `KFileItemListView` / `KFileItemListWidget` | 4 files | 985 | ↑ | Qt-only. **But**: `KFileItemListView` is the *only* thing that owns and drives the roles updater (`kfileitemlistview.cpp:243, 388-390`) — Phase 3 must re-implement ~150 lines of that drive loop |
| `KItemListController` | `kitemlistcontroller.{cpp,h}` | 2366 | `QObject`, but ctor calls `view->grabGesture(...)` ×5 unconditionally (`kitemlistcontroller.cpp:75-79`) | **cannot run headless**; Phase 3 replaces it |
| `KItemListContainer` | `kitemlistcontainer.{cpp,h}` | 549 | `QAbstractScrollArea` wrapping a `QGraphicsView`+`QGraphicsScene` (`kitemlistcontainer.cpp:31,68`) | Qt-only |
| `private/kitemlist{viewlayouter,viewanimation,sizehintresolver,smoothscroller,rubberband,headerwidget,roleeditor,selectiontoggle,keyboardsearchmanager}`, `kpixmapmodifier`, `kitemviewsutils` | 22 files | ~2.9 k | mixed `QObject`/`QGraphicsWidget` | Qt-only (`kitemlistkeyboardsearchmanager` is `QObject`-pure and reusable for type-ahead) |
| `accessibility/` | 6 files | 1145 | `QAccessible*` | Qt-only; AppKit gets a11y for free |
| `DolphinItemListView` | `views/dolphinitemlistview.{cpp,h}` | 345 | `KFileItemListView`; maps zoom level → grid/icon size (`dolphinitemlistview.h:22`) | Qt-only; the zoom→size *table* comes from `ZoomLevelInfo` which is reusable |
| `DolphinFileItemListWidget` | `views/dolphinfileitemlistwidget.{cpp,h}` | 165 | VCS overlay tinting | Qt-only |

Render half total ≈ **17.5 k LOC** — this is the part Phase 3 discards.

#### 2d. `views/` — the controller layer

| component | files | LOC | responsibility | QtW | KXG | verdict |
|---|---|---|---|:--:|:--:|---|
| **`DolphinView`** | `views/dolphinview.{cpp,h}` | 4003 | *the* view controller: URL, mode, sort/group/filter, selection, zoom, rename, trash/delete/cut/copy/paste/duplicate, drop handling, status-bar text, placeholder text | `: QWidget` (`dolphinview.h:56`) | **none** | **reusable with patches — the single most valuable class** |
| `ViewProperties` | `views/viewproperties.{cpp,h}` | 1057 | per-directory `.directory` persistence, global-mode fallback, hashed side-store for non-writable/remote dirs (`viewproperties.cpp:39,168-236`) | plain class, **no QObject** (`:38`) | – | **reuse as-is** (see §5 for the macOS `.directory` UX question) |
| `DolphinViewActionHandler` | `views/dolphinviewactionhandler.{cpp,h}` | 1302 | owns ~40 `QAction`s for the View menu, retargetable via `setCurrentView` | ✔ | ✔ `KActionCollection` ctor (`:47`) | **replace** — but it is the exact spec for the AppKit View menu |
| `VersionControlObserver` | `views/versioncontrol/versioncontrolobserver.{cpp,h}` | 604 | loads `dolphin/vcs` plugins (`versioncontrolobserver.cpp:298-302`), threaded status refresh, writes `version` role into the model | `QList<QAction*> actions()` (`:50`); `DolphinView*` only to connect `activated` (`:89-96`) | – | **reuse with patches** |
| `UpdateItemStatesThread` | same dir | 238 | `QThread` calling the plugin | none | – | reuse as-is |
| `KVersionControlPlugin` | `versioncontrol/kversioncontrolplugin.{cpp,h}` | 232 | ABI-stable plugin interface; `QObject`, but returns `QList<QAction*>` (`:177,185`) | via `QAction` | – | reuse as-is (it is `dolphinvcs`, already installed & exported) |
| `DragAndDropHelper` | `views/draganddrophelper.{cpp,h}` | 190 | `KIO::drop`, Ark DnD, `supportsDropping` | `QWidget*`, `QDropEvent*` | – | **split**: `supportsDropping`/`urlListMatchesUrl` → core; `dropUrls` (uses `QDBusConnection::sessionBus()` at `:44-49`) → platform |
| `ZoomLevelInfo` | `views/zoomlevelinfo.{cpp,h}` | 112 | zoom level ↔ icon size table | `KIconLoader`, `QSize` | reuse as-is |
| `ViewModeController` | `views/viewmodecontroller.{cpp,h}` | 180 | **already dead-ish**: not in any target's source list | – | drop |
| `DolphinNewFileMenuObserver` | `views/dolphinnewfilemenuobserver.{cpp,h}` | ~130 | singleton signalling item/dir creation so views can select the new item | none | reuse as-is |
| `views/tooltips/` | 4 files | 523 | Baloo-gated metadata tooltip | ✔ | – | replace (`NSPopover`) |

#### 2e. Peripheral subsystems

| subsystem | files/LOC | notes | verdict |
|---|---|---|---|
| `panels/places` | 2 / 362 | `PlacesPanel : KFilePlacesView` (`placespanel.h:28`), backed by `DolphinPlacesModel : KFilePlacesModel` | **replace UI**; `KFilePlacesModel` (KIOFileWidgets, needs Solid) is reusable as a data source — Solid on macOS is a separate audit item |
| `panels/folders` | 6 / 836 | `FoldersPanel` builds a *second* `KFileItemModel` + `KFileItemListView` + `KItemListController` (`folderspanel.cpp:133-162`) | **strong existing proof the model is reusable standalone**; replace with `NSOutlineView` |
| `panels/information` | 8 / 1987 | Baloo-gated (`HAVE_BALOO`), `Qt::Multimedia` | replace (`NSView` inspector) |
| `panels/terminal` | 2 / 487 | loads the **Konsole KPart** via `KPluginFactory` + `KXMLGUIFactory`, `kde_terminal_interface.h`, KIOFuse D-Bus | **drop on macOS** (no Konsole part); Terminal.app integration instead |
| `search/` | 22 / 2907 | `Search::DolphinQuery` is a plain class (`dolphinquery.h:80`) that builds `baloosearch:`/`filenamesearch:` URLs; the rest is chips/popup widgets | `DolphinQuery` → **core**; UI → replace with `NSSearchField`; both backends are Linux-flavoured |
| `settings/` | 46 / ~4.5 k | 8 `KConfigSkeleton` classes (generated, `src/CMakeLists.txt:203`) + `KPageDialog` UI + 3 `KCModule`s (gated `if(NOT WIN32)`, `:561`) | **skeletons → core as-is**; dialogs → replace with an AppKit Preferences window |
| `statusbar/` | 12 / 1608 | `MountPointObserver` uses `KIO::fileSystemFreeSpace` (`mountpointobserver.cpp:37`) — pure `QObject`; `DolphinStatusBar`/`StatusBarSpaceInfo` are widgets | observers → **core as-is**; widgets → replace |
| `filterbar/` | 2 / 332 | `FilterBar : AnimatedHeightWidget`; only real output is `KFileItemModelFilter::FilterMode` | replace (`NSSearchField`) |
| `selectionmode/` | 13 / 1753 | touch/phone selection bars; `ActionTextHelper` is in `dolphinprivate` | drop on macOS (desktop-only target) |
| `itemactions/` | 6 / 582 | 3 separate `KAbstractFileItemActionPlugin` MODULEs, not linked into the app | out of scope; `setfoldericonitemaction` is `if(NOT WIN32)` (`itemactions/CMakeLists.txt`) |
| `admin/` | 4 / 563 | `admin://` scheme via kio-admin + PolicyKit; `KProtocolInfo::isKnownProtocol("admin")` (`workerintegration.cpp:45`) | **drop on macOS** (no kio-admin, no polkit) |
| `userfeedback/` | 6 / 246 | `HAVE_KUSERFEEDBACK`-gated | drop |
| `dolphinpart*` | 6 / ~1.1 k | `KParts::ReadOnlyPart` for Konqueror | drop |

---

### 3. UI-free logic that is already separable

| logic | exact class | how welded? | evidence |
|---|---|---|---|
| **Navigation history** | `KCoreUrlNavigator` (KIO, **not** Dolphin) | **not welded at all.** `KUrlNavigator` is a pure breadcrumb UI delegating to an internal `KCoreUrlNavigator`: `goBack/goForward/goUp/historySize/locationUrl/locationState` are all one-line forwards | kio `src/gui/kcoreurlnavigator.h:37` (`: QObject`, KIOGui); kio `src/filewidgets/kurlnavigator.cpp:214, 1077-1104, 1361` |
| **Per-item view-state blob** | `KUrlNavigator::saveLocationState(QByteArray)` / `locationState()` | already a `QByteArray` per history entry; `DolphinViewContainer` stores scroll position + current item there | kio `src/filewidgets/kurlnavigator.h:122,130` |
| **View properties persistence** | `ViewProperties` | **fully free.** Not a `QObject`, not a `QWidget`, no `QAction`. Only Dolphin-internal include is `dolphinview.h`, and *only* for the `DolphinView::Mode` enum | `views/viewproperties.h:12,38`; ctor `explicit ViewProperties(const QUrl&)` `:40` |
| **Sorting / grouping / comparators** | `KFileItemModel` + `private/kfileitemmodelsortalgorithm.h` | free. `QCollator`-based, role-driven, parallel merge sort | `kfileitemmodel.cpp:284` (`m_collator.setNumericMode(true)`) |
| **Filtering** | `KFileItemModelFilter` | free. Plain class, `QRegularExpression` + MIME list | `private/kfileitemmodelfilter.h:114` |
| **Selection model** | `KItemListSelectionManager` | `QObject`, no widgets — **but** `setModel()` and the index fix-up methods `itemsInserted/Removed/Moved` are **private**, exposed only via `friend class KItemListView` | `kitemlistselectionmanager.h:70-91`; call sites `kitemlistview.cpp:1322, 1444, 1472` |
| **Thumbnail/metadata pipeline** | `KFileItemModelRolesUpdater` | free apart from 2 `qApp->activeWindow()` lines. Public API is `setIconSize`, `setDevicePixelRatio`, `setVisibleIndexRange(int,int)`, `setMaximumVisibleItems`, `setPreviewsShown`, `setRoles`, `setPaused`, `setHoverSequenceState` — **all index/size based, no view type anywhere** | `kfileitemmodelrolesupdater.h:88-165` |
| **File-operation orchestration** | `DolphinView` slots: `renameSelectedItems`, `trashSelectedItems`, `deleteSelectedItems`, `cut/copy/paste/pasteIntoFolder`, `duplicateSelectedItems`, `copySelectedItems`, `moveSelectedItems`, `dropUrls` | logic is KIO-only; **welded solely through `this` as a dialog parent**. 12 sites: `KIO::RenameFileDialog(items, this)` `:875`, `KMessageBox::error(this,…)` `:891`, `createDefaultJobUiDelegate(…, this)` `:910,:923`, `KJobWidgets::setWindow(job, this)` `:955,:977,:1041,:2365,:2640`, `KMessageBox::warningContinueCancel(…)` `:1223`, `KMessageBox::questionTwoActions(this,…)` `:2302`, `new KMessageDialog(…, this)` `:2347` | `views/dolphinview.cpp` |
| **View state machine** | `DolphinView` | is a `QWidget` (`dolphinview.h:56`) and takes `QWidget* parent` (`:89`), **but constructs zero `QAction`s and never touches `KActionCollection`** — it is absent from the KXmlGui grep set. Its own widget usage is confined to: a `QVBoxLayout`, one `QLabel` placeholder, and hosting `KItemListContainer` | `views/dolphinview.cpp:141-243`; ratio inside the file: 89 × `m_model->`, 46 × `m_view->`, 48 × `m_container->` |
| **Tab & split state** | `DolphinTabPage` / `DolphinTabWidget` | welded — `QWidget`/`QSplitter`/`QTabWidget`. **However** the persistence contract is already serialized: `QByteArray DolphinTabPage::saveState()/restoreState()` (`dolphintabpage.h:127,133`) and `DolphinTabWidget::saveProperties/readProperties(KConfigGroup&)` (`dolphintabwidget.h:66-67`) | — |
| **VCS plugin interface** | `KVersionControlPlugin` + `VersionControlObserver` | plugin ABI is `QObject`-based and already an installed, exported shared lib. Observer's only `DolphinView` use is `connect(m_view, &DolphinView::activated, …)` — one signal | `versioncontrolobserver.cpp:89-96`; plugin discovery `:298-302` |
| **Free-space monitoring** | `MountPointObserver` / `MountPointObserverCache` / `SpaceInfoObserver` | free. `QObject` + `KIO::fileSystemFreeSpace` | `statusbar/mountpointobserver.cpp:37` |
| **Search query construction** | `Search::DolphinQuery` | free. Plain class over `QUrl`; Baloo parts `#if HAVE_BALOO` | `search/dolphinquery.h:80` |

---

### 4. `kitemviews/` model/view separability — the three coupling points

Model↔view separation is **clean by construction** (the framework is a port of Trolltech's "Itemviews NG"; see the header credits at `kitemmodelbase.h:4`). Exactly three things stand between us and driving `KFileItemModel` from `NSCollectionView`:

**C1 — the selection manager is synced by the *view*, not the model.**
`KItemListSelectionManager::itemsInserted/itemsRemoved/itemsMoved` are private and called from `KItemListView::slotItemsInserted/Removed/Moved`:
```
kitemlistview.cpp:1322   m_controller->selectionManager()->itemsInserted(itemRanges);
kitemlistview.cpp:1444   m_controller->selectionManager()->itemsRemoved(itemRanges);
kitemlistview.cpp:1472   m_controller->selectionManager()->itemsMoved(itemRange, movedToIndexes);
kitemlistselectionmanager.h:90-91   friend class KItemListController;  friend class KItemListView;
```
Without a `KItemListView`, selections silently corrupt on any directory change. **Fix (upstreamable):** have `setModel()` connect to `KItemModelBase::itemsInserted/Removed/Moved` directly and make `setModel()` public. ~20 lines; strictly better than the friend hack and would also fix the fact that `FoldersPanel`-style consumers currently depend on view internals.

**C2 — `KItemListController` cannot exist without a view.**
`kitemlistcontroller.cpp:75-79` calls `view->grabGesture(...)` five times unconditionally in the constructor. So `KItemListController` (which owns the selection manager, `:50`) is unusable headless. **Fix:** none needed — Phase 3 does not use the controller; input handling is native. But this means the *selection manager must be constructible standalone*, which C1's fix delivers.

**C3 — the roles-updater drive loop lives in `KFileItemListView`.**
`KFileItemListView` is the sole owner (`kfileitemlistview.cpp:243`) and the sole caller of `setVisibleIndexRange` / `setMaximumVisibleItems` / `setIconSize` / `setDevicePixelRatio` / `setPaused` (`:244-245, 291-307, 371, 388-390, 409-422, 459`). This is ~150 lines of policy (pause during transactions, recompute on icon-size change) that Phase 3 must re-implement against `NSCollectionView.visibleRect`. **Not a blocker — a port task.** Consider proposing an upstream `KFileItemModelPreviewController` that holds this policy view-independently (class (a) refactor).

**What `KFileItemModelRolesUpdater` gives a native view.** Reading `kfileitemmodelrolesupdater.h:43-77` and the `data.insert(...)` sites, it asynchronously fills these roles back into the model:

| role | produced by | line |
|---|---|---|
| `iconPixmap` | `KIO::PreviewJob` → `transformPreviewImage(QImage)` → `QPixmap` | `:576, :990-1032` |
| `iconName` | `KFileItem::iconName()` (MIME resolution) | `:1247` |
| `iconOverlays` | `KOverlayIconPlugin` instances | `:1380, :1404` |
| `hoverSequencePixmaps` | sequence thumbnails for hover-scrub | `:633-687, :1065` |
| `count`/`size` for directories | `KDirectoryContentsCounter` (threaded) | `private/kdirectorycontentscounter.cpp` |
| Baloo roles (rating, tags, comment, …) | `KBalooRolesProvider`, `#if HAVE_BALOO` | `:27-30` |

It is throttled, paused during scrolling, and only resolves visible ± margin items — exactly the semantics `NSCollectionViewDataSource` wants. **A native view absolutely should keep it.** The only bridge friction is `QPixmap` → `NSImage`; `QPixmap` requires a `QGuiApplication` and the cocoa platform plugin (we will have both).

---

### 5. Proposed `libDolphinCore` boundary

**Principle:** `libDolphinCore` = everything that is `QObject`-or-plainer *plus* `DolphinView` kept as a `QWidget` that is never made visible in Phase 3. Fighting `DolphinView`'s `QWidget` base is not worth it: it buys nothing and costs a 4 k-line fork. Instead we inject a **UI delegate** so the 12 dialog sites route to AppKit.

#### 5a. Files that move in (≈ 13.1 k LOC measured)

```
kitemviews/kitemmodelbase.{cpp,h}          kitemviews/kitemset.{cpp,h}
kitemviews/kitemrange.h                    smallhash.h
kitemviews/kfileitemmodel.{cpp,h}          kitemviews/kfileitemlisttostring.{cpp,h}
kitemviews/kfileitemmodelrolesupdater.{cpp,h}
kitemviews/kitemlistselectionmanager.{cpp,h}
kitemviews/private/kfileitemmodelfilter.{cpp,h}
kitemviews/private/kfileitemmodelsortalgorithm.h
kitemviews/private/kfileitemclipboard.{cpp,h}
kitemviews/private/kdirectorycontentscounter{,worker}.{cpp,h}
kitemviews/private/kbaloorolesprovider.{cpp,h}      [HAVE_BALOO]
kitemviews/private/kitemlistkeyboardsearchmanager.{cpp,h}   (type-ahead; QObject-pure)
views/viewproperties.{cpp,h}               views/zoomlevelinfo.{cpp,h}
views/dolphinnewfilemenuobserver.{cpp,h}
views/versioncontrol/{versioncontrolobserver,updateitemstatesthread}.{cpp,h}
views/versioncontrol/kversioncontrolplugin.{cpp,h}   (= existing dolphinvcs)
search/dolphinquery.{cpp,h}
trash/dolphintrash.{cpp,h}
statusbar/{mountpointobserver,mountpointobservercache,spaceinfoobserver}.{cpp,h}
settings/dolphin_*.kcfgc            (all 8 generated KConfigSkeletons)
settings/dolphin_{folderspanel,placespanel,searchsettings}.kcfgc
global.{cpp,h}                      (minus the D-Bus half)
+ NEW: views/draganddrophelper_core.{cpp,h}   (supportsDropping, urlListMatchesUrl, updateDropAction)
+ NEW: core/uidelegate.h                      (abstract; see 5c)
```

`DolphinView` sits in a thin **`libDolphinViewCore`** on top (still QtWidgets-linked, still 4 k LOC, unmodified except for the delegate injection). Phase 3 keeps it, instantiated with `nullptr` parent and never shown — it remains the file-operation orchestrator and dialog anchor.

**Stays in the Qt UI layer** (`libDolphinQtUi`, Phase 2 only): the whole render half (§2c, ~17.5 k LOC), `DolphinViewContainer`, `DolphinMainWindow`, `DolphinTabWidget/Page/Bar`, `DolphinContextMenu`, `DolphinViewActionHandler`, all `panels/`, `search/` widgets, `settings/` dialogs, `statusbar/` widgets, `filterbar/`, `selectionmode/`, `admin/`, `views/tooltips/`.

**Dropped entirely:** `dolphinpart*`, `userfeedback/`, `panels/terminal/`, `admin/`, `settings/kcm/`, `settings/contextmenu/servicemenuinstaller`, `dbusinterface.cpp`, `settings/dolphin_*update*.cpp`.

#### 5b. Target graph

```
libDolphinCore        → Qt6::Core, Qt6::Gui, Qt6::Concurrent
                        KF6::{KIOCore, KIOGui, CoreAddons, ConfigCore, I18n,
                              FileMetaData, GuiAddons, IconThemes, Codecs}
                        (NO QtWidgets, NO QtDBus, NO KXmlGui)
libDolphinVcs         → Qt6::Gui  [today: Qt6::Widgets, src/CMakeLists.txt:34 — see U3]
libDolphinViewCore    → libDolphinCore + Qt6::Widgets + KF6::{KIOWidgets, KIOFileWidgets, WidgetsAddons}
libDolphinQtUi        → libDolphinViewCore + KF6::{Parts, XmlGui, Bookmarks, KCMUtils, …}   [Phase 2 only]
DolphinMac.app        → libDolphinViewCore (+ libDolphinQtUi in Phase 2)  + AppKit
```

The **only** hard obstacle to a QtWidgets-free `libDolphinCore` is four lines (`kfileitemmodel.cpp:292`, `kfileitemmodelrolesupdater.cpp:980,1092`, `kfileitemclipboard.cpp`'s `QApplication::clipboard()`). All four are trivially replaceable (`QGuiApplication`, or a `QWindow*`/`nullptr` hook). If we choose not to fix them, `libDolphinCore` just links QtWidgets too — a cosmetic loss, not a functional one. Recommend fixing: it is 4 lines and it is upstreamable.

#### 5c. Public API for the Objective-C++ bridge

The bridge should **not** see Qt types. Propose a `DolphinCore/` façade of ~6 headers. Sketch:

```cpp
// DolphinCore/UiDelegate.h — the key inversion. Injected into DolphinView.
namespace DolphinCore {
class UiDelegate {                     // implemented by AppKit in Phase 3,
public:                                // by a QWidget-backed shim in Phase 2
    virtual ~UiDelegate() = default;
    enum class Answer { Primary, Secondary, Cancel };
    virtual Answer confirm(const QString &title, const QString &text,
                           const QString &primary, const QString &secondary,
                           const QString &dontAskAgainKey = {}) = 0;
    virtual void   showError(const QString &text) = 0;
    virtual void   beginRename(const KFileItemList &items,
                               std::function<void(const QList<QUrl>&)> done) = 0;
    /// Anchor for KIO job UI (progress, overwrite prompts, auth).
    /// Phase 2 returns the real QWidget; Phase 3 returns a hidden one.
    virtual QWidget *jobParent() = 0;
};
}
// DolphinView gains: void setUiDelegate(DolphinCore::UiDelegate *);
// and the 12 sites in dolphinview.cpp become m_ui->confirm(...) / m_ui->jobParent().
```

```cpp
// DolphinCore/DirectoryModel.h — one object per pane; owns model + previews + selection.
namespace DolphinCore {
class DirectoryModel : public QObject {
    Q_OBJECT
public:
    explicit DirectoryModel(QObject *parent = nullptr);

    void    loadDirectory(const QUrl &url);
    void    reload();
    void    stopLoading();
    QUrl    directory() const;

    int         count() const;
    SmallHash   itemData(int index) const;     // roles → QVariant
    KFileItem   fileItem(int index) const;
    QUrl        itemUrl(int index) const;
    bool        isDir(int index) const;
    int         indexForUrl(const QUrl &) const;

    // sorting / grouping / filtering  (all forward to KFileItemModel)
    void setSortRole(const QByteArray &); QByteArray sortRole() const;
    void setSortOrder(Qt::SortOrder);     void setSortFoldersFirst(bool);
    void setGroupRole(const QByteArray &);
    QList<QPair<int, QVariant>> groups() const;
    void setNameFilter(const QString &);  void setMimeTypeFilters(const QStringList &);
    void setHiddenFilesShown(bool);

    // tree expansion (details mode / NSOutlineView)
    bool setExpanded(int index, bool);    bool isExpanded(int) const;
    int  expandedParentsCount(int) const;

    // previews & metadata  (drives KFileItemModelRolesUpdater)
    void setVisibleIndexRange(int first, int count);
    void setIconSize(const QSize &);      void setDevicePixelRatio(qreal);
    void setPreviewsShown(bool);          void setPreviewsPaused(bool);
    void setRoles(const QSet<QByteArray> &);
    void setHoverSequenceState(const QUrl &, int seqIdx);

    // selection  (wraps KItemListSelectionManager)
    SelectionModel *selection() const;

Q_SIGNALS:
    void itemsInserted(const KItemRangeList &);
    void itemsRemoved(const KItemRangeList &);
    void itemsMoved(const KItemRange &, const QList<int> &movedTo);
    void itemsChanged(const KItemRangeList &, const QSet<QByteArray> &roles);
    void groupsChanged();
    void directoryLoadingStarted();
    void directoryLoadingProgress(int percent);
    void directoryLoadingCompleted();
    void directoryRedirection(const QUrl &oldUrl, const QUrl &newUrl);
    void errorMessage(const QString &, int kioErrorCode);
};
}
```
`itemsInserted/Removed/Moved` map 1:1 onto `NSCollectionView -performBatchUpdates:` / `NSTableView -insertRowsAtIndexes:`. `itemsChanged(ranges, {"iconPixmap"})` maps onto `-reloadItemsAtIndexPaths:`.

```cpp
// DolphinCore/NavigationController.h — backed by KIO's KCoreUrlNavigator (kio/src/gui).
class NavigationController : public QObject {
    Q_OBJECT
public:
    QUrl  currentUrl() const;         void setCurrentUrl(const QUrl &);
    bool  goBack();  bool goForward();  bool goUp();  void goHome();
    int   historySize() const;        int  historyIndex() const;
    QUrl  urlAt(int historyIndex) const;
    void  saveViewState(const QByteArray &);   // scroll pos + current item
    QByteArray viewStateAt(int historyIndex) const;
Q_SIGNALS:
    void currentUrlAboutToChange(const QUrl &newUrl);
    void currentUrlChanged(const QUrl &);
    void historyChanged();
};
```

```cpp
// DolphinCore/ViewState.h — thin, ABI-friendly wrapper over ViewProperties.
struct ViewState {                       // POD-ish; safe to hand to Obj-C++
    enum Mode { Icons, Compact, Details };
    Mode mode; int zoomLevel; bool hiddenFilesShown; bool previewsShown;
    bool groupedSorting; QByteArray sortRole; Qt::SortOrder sortOrder;
    bool sortFoldersFirst; bool sortHiddenLast; QList<QByteArray> visibleRoles;
};
ViewState loadViewState(const QUrl &directory);   // = ViewProperties(url) getters
void      saveViewState(const QUrl &directory, const ViewState &);
```

```cpp
// DolphinCore/TabModel.h — pure state, no widgets. Extracted from DolphinTabPage/TabWidget.
struct PaneState  { QUrl url; QByteArray viewState; };
struct TabState   { PaneState primary; std::optional<PaneState> secondary;
                    bool primaryActive; int splitterPos; QString customLabel;
                    QByteArray serialize() const; static TabState deserialize(const QByteArray &); };
class  TabModel : public QObject {         // owns QList<TabState>, current index
    int  openTab(const QUrl &, int atIndex = -1);
    void closeTab(int);   void moveTab(int from, int to);
    void setSplitEnabled(int tab, bool, const QUrl &secondary = {});
    bool isUrlOpen(const QUrl &) const;
    void saveSession(KConfigGroup &) const;  void restoreSession(const KConfigGroup &);
Q_SIGNALS:
    void tabInserted(int); void tabRemoved(int); void currentTabChanged(int);
    void tabTitleChanged(int, const QString &);
};
```

```cpp
// DolphinCore/FileOperations.h — wraps the DolphinView slots so AppKit can call them
// without touching DolphinView directly. Every entry point takes a UiDelegate.
namespace FileOperations {
    void rename(const KFileItemList &, UiDelegate &);
    void moveToTrash(const KFileItemList &, UiDelegate &);
    void deletePermanently(const KFileItemList &, UiDelegate &);
    void cut(const KFileItemList &);  void copy(const KFileItemList &);
    void paste(const QUrl &destination, UiDelegate &);
    void duplicate(const KFileItemList &, UiDelegate &);
    void copyTo(const KFileItemList &, const QUrl &dest, UiDelegate &);
    void moveTo(const KFileItemList &, const QUrl &dest, UiDelegate &);
    std::pair<bool, QString> pasteInfo();          // enabled + menu text
    void dropUrls(const QMimeData *, Qt::DropAction, const QUrl &dest, UiDelegate &);
}
```

```cpp
// DolphinCore/VcsObserver.h — unchanged VersionControlObserver, minus the DolphinView*.
class VcsObserver : public QObject {
    void setModel(DirectoryModel *);
    void refresh();                                   // was: connect(view, &DolphinView::activated,…)
    struct VcsAction { QString text; QString iconName; int id; };  // NSMenuItem-friendly
    QList<VcsAction> actionsFor(const KFileItemList &) const;
    void triggerAction(int id);
Q_SIGNALS: void infoMessage(const QString&); void errorMessage(const QString&);
};
```

#### 5d. Why this survives the Phase 2 → Phase 3 swap

* Phase 2's Qt view is constructed from the *same* `DirectoryModel` — `KItemListController(model, view)` accepts the `KFileItemModel*` that `DirectoryModel` owns. No parallel state.
* `UiDelegate` is implemented twice (QWidget shim / AppKit); nothing else changes.
* `NavigationController`, `ViewState`, `TabModel`, `FileOperations`, `VcsObserver` are already widget-free, so Phase 3 touches **zero** core files.
* The only Phase-3 new code in core is C1's selection fix and C3's re-implemented preview drive loop (~200 lines total).

---

### 6. Upstreamability

| # | change | class | rationale |
|---|---|---|---|
| U1 | `KItemListSelectionManager`: make `setModel()` public and self-connect to `KItemModelBase::itemsInserted/Removed/Moved`; drop `friend class KItemListView` | **(a) upstreamable** | removes a friend hack, fixes a latent bug for any non-`KItemListView` consumer; ~20 lines |
| U2 | delete the stale `#include "dolphintabwidget.h"` at `views/dolphinview.h:12` | **(a)** | **`DolphinTabWidget` is referenced nowhere in `dolphinview.h` or `.cpp`** (verified by grep). Worse, it makes `dolphinprivate` compile against a header owned by `dolphinstatic` — a target it does not link. Pure win |
| U3 | `views/viewproperties.h`: replace `#include "views/dolphinview.h"` with a standalone `enum class ViewMode` (or forward-declared enum) | **(a)** | `ViewProperties` currently drags `QWidget` + `KParts` + `KIO::StatJob` into every TU that reads view properties, including the `kcm_dolphingeneral` KCM which already recompiles `viewproperties.cpp` (`src/CMakeLists.txt:591`) |
| U4 | `dolphinvcs`: `Qt6::Widgets` → `Qt6::Gui` in `target_link_libraries` (`src/CMakeLists.txt:34`) | **(a)** | `KVersionControlPlugin` only needs `QAction` (QtGui in Qt6) — `kversioncontrolplugin.h:13,177`. Shrinks the public dep of an installed, exported framework |
| U5 | `KFileItemModel`: replace the `qobject_cast<QWidget*>(parent)` → `setMainWindow()` (`kfileitemmodel.cpp:292`) with an explicit `setDialogParent(QWidget*)` setter | **(a)** | removes QtWidgets from an otherwise pure model; also fixes the silent behaviour change when the model is reparented |
| U6 | `KFileItemModelRolesUpdater`: replace `qApp->activeWindow()` (`:980, :1092`) with a settable window pointer | **(a)** | same rationale; also more correct in multi-window Dolphin |
| U7 | `KFileItemClipboard`: `QApplication::clipboard()` → `QGuiApplication::clipboard()` | **(a)** | one-word change |
| U8 | extract a `KFileItemModelPreviewController` holding `KFileItemListView`'s roles-updater drive policy (`kfileitemlistview.cpp:288-460`) | **(a)** | would let Plasma/Qt-Quick file views reuse Dolphin's preview engine — a long-standing KDE want |
| U9 | `DolphinView::setUiDelegate()` + route the 12 dialog sites through it | **(a)** | KDE benefits (testability — `dolphinviewtest.cpp` currently cannot exercise delete/rename paths headlessly). Fall back to **(b)** if upstream resists |
| U10 | CMake: gate `qt_generate_dbus_interface`/`qt_add_dbus_adaptor` (`src/CMakeLists.txt:477-480`), `dbusinterface.cpp`, and `Dolphin::attachToExistingInstance` behind `if(NOT APPLE)` / `#ifndef Q_OS_MACOS` | **(b) macOS `#ifdef`** | there is already precedent: `if (UNIX AND NOT APPLE AND NOT HAIKU)` at `CMakeLists.txt:69`, and `#if defined(Q_OS_WIN) \|\| defined(Q_OS_MACOS)` at `dolphinmainwindow.cpp:152` and `main.cpp:88` |
| U11 | gate `panels/terminal/`, `admin/`, `settings/kcm/`, `servicemenuinstaller` out on Apple | **(b)** | `admin/` needs kio-admin + polkit (`workerintegration.cpp:45`); terminal needs the Konsole KPart. `settings/kcm` and `servicemenuinstaller` are already `if(NOT WIN32)` (`:561, :578`) — extend to `NOT APPLE` |
| U12 | new `macos/` frontend directory (AppKit shell, Obj-C++ bridge, `UiDelegate` impl) | **(c) but additive** | new files only; **zero** upstream conflict surface, so it does not count as a fork of existing code |
| U13 | `.directory` vs a macOS-native store for `ViewProperties` | **(b) or (c)** | `ViewProperties` writes `.directory` files into user folders (`viewproperties.cpp:39, 164-168`). That is alien on macOS. It already has a hashed side-store under `destinationDir("local/")+directoryHashForUrl()` for non-writable dirs (`:211`) — so a `#ifdef Q_OS_MACOS` that *always* takes the side-store path is a ~5-line change, not a fork |

**Keeping the patch set small and rebasable.** Recommended layout:

```
DolphinForMac/
  upstream/dolphin/            git submodule, pinned tag, never edited
  patches/                     quilt series applied to upstream/dolphin
    series
    0001-viewproperties-drop-dolphinview-include.patch      (U3, ~30 lines)
    0002-dolphinview-drop-stale-tabwidget-include.patch     (U2, 1 line)
    0003-selectionmanager-self-sync-with-model.patch        (U1, ~25 lines)
    0004-model-explicit-dialog-parent.patch                 (U5+U6+U7, ~15 lines)
    0005-dolphinvcs-link-qtgui-not-qtwidgets.patch          (U4, 1 line)
    0006-cmake-gate-dbus-and-linux-only-subsystems.patch    (U10+U11, ~60 lines)
    0007-dolphinview-uidelegate.patch                       (U9, ~120 lines)
    0008-viewproperties-macos-store.patch                   (U13, ~10 lines)
  macos/                       our code — AppKit shell, Obj-C++ bridge, .xcconfig
  cmake/DolphinCore.cmake      defines libDolphinCore/libDolphinViewCore over upstream sources
```

Total patch surface ≈ **260 lines**, spread over 8 files, all of them (a)-class except two `#ifdef` patches. Submit 0001–0005 upstream immediately; they are independently justifiable and, once merged, the series shrinks further. `cmake/DolphinCore.cmake` should *reference* upstream source paths rather than move files, so upstream file renames cost one line each rather than a patch rebase.

---

### 7. Phased migration order

```
P0  Freeze upstream at a tag; stand up patches/ + a `quilt push` step in the build.
    Verify `patch -p1 --dry-run` cleanly on the pinned tree.          [no deps]

P1  Backend up on macOS.
 1.1  Build KF6 deps from source (separate audit section).
 1.2  Apply 0006: gate D-Bus adaptor + terminal/admin/kcm out on APPLE.
 1.3  Build `dolphinprivate` (unmodified) as-is on macOS.  ← first real milestone
 1.4  Run the headless-capable tests to prove the model works:
      kitemsettest, kitemrangetest, kitemlistselectionmanagertest,
      kfileitemmodeltest, viewpropertiestest, dolphinquerytest
      (src/tests/CMakeLists.txt:13,16,23,56,82,76 — all link only
       dolphinprivate/dolphinstatic + Qt6::Test).
 1.5  Replace Dolphin::attachToExistingInstance with an NSApplication
      single-instance path.                                     [needs 1.2]

P2  Qt UI embedded in an AppKit shell.
 2.1  Apply 0001–0005 (the mechanical decoupling patches).      [needs P1.3]
 2.2  Introduce cmake/DolphinCore.cmake: split dolphinprivate into
      libDolphinCore + libDolphinViewCore + libDolphinQtUi. No code moves;
      only target membership changes.                            [needs 2.1]
 2.3  Apply 0007 (UiDelegate) and ship the QWidget-backed shim so behaviour
      is byte-identical to upstream.                             [needs 2.2]
 2.4  AppKit NSWindow hosts DolphinViewContainer via NSView<->QWidget
      embedding; native menu bar drives DolphinViewActionHandler's QActions.
      TabModel is introduced here and DolphinTabWidget is driven *from* it,
      so Phase 3 does not re-plumb tabs.                          [needs 2.3]
 2.5  Native NSToolbar path control fed by NavigationController
      (KCoreUrlNavigator) — first component to go native, because
      KUrlNavigator is the least macOS-idiomatic widget and the
      substitution is already supported by KIO.                   [needs 2.2]

P3  Native views.
 3.1  Land C1's fix in anger (patch 0003 already applied; now exercise it
      with a selection manager that has no KItemListView).        [needs 2.2]
 3.2  Write the roles-updater drive loop against NSCollectionView.visibleRect,
      porting kfileitemlistview.cpp:288-460.                      [needs 3.1]
 3.3  DirectoryModel façade + Obj-C++ NSCollectionViewDataSource /
      NSTableViewDataSource; QPixmap→NSImage bridge.              [needs 3.2]
 3.4  Icons mode (NSCollectionView) first — fewest roles.
 3.5  Details mode (NSOutlineView) second — needs KItemModelBase's
      setExpanded/expandedParentsCount tree API (kitemmodelbase.h:116-136).
 3.6  Compact mode last (or drop it; it is the least macOS-idiomatic).
 3.7  AppKit UiDelegate impl (NSAlert/NSSavePanel); Qt dialog shim retired.
 3.8  Delete libDolphinQtUi and the render half from the link line
      (~17.5 k LOC drops out).                                    [needs 3.4-3.7]

P4  Panels & polish: NSOutlineView folders panel (mirrors FoldersPanel's
    existing standalone KFileItemModel usage, folderspanel.cpp:133-162),
    NSSourceList places panel over KFilePlacesModel, inspector,
    NSSearchField over Search::DolphinQuery.                      [needs P3]
```

The critical path is **P1.3 → 2.2 → 3.1 → 3.2 → 3.3**. Everything else parallelises.

## Dolphin core decoupling — what is reusable, and where `libDolphinCore` should cut

All paths below are relative to **`upstream/dolphin/`** unless prefixed with `kio:` (= `upstream/kio/`).

---

### 1. What upstream already splits (and why it is *not* a core/UI split)

`src/CMakeLists.txt` already builds six targets. Measured sizes (`.cpp` + `.h`, blank/comment lines included):

| Target | Decl | Files | LOC | What it actually is |
|---|---|---|---|---|
| `dolphinvcs` (SHARED, installed, versioned SO) | `src/CMakeLists.txt:24` | 2 | 842 (incl. observer) / **22 in the lib itself** | Only `views/versioncontrol/kversioncontrolplugin.cpp`. The public VCS plugin ABI. |
| `dolphinprivate` (SHARED, installed, `NAMELINK_SKIP`) | `src/CMakeLists.txt:59` | 113 | **35 891** | `kitemviews/` (model **and** QGraphicsWidget view), `views/`, view-properties persistence + its two `QDialog`s, `DolphinNewFileMenu`, `zoomwidgetaction`. |
| `dolphinpart` (MODULE) | `src/CMakeLists.txt:263` | 6 | ~1 700 | KParts embedding of `DolphinView`. |
| `dolphinstatic` (STATIC, **not installed, no exported headers**) | `src/CMakeLists.txt:285` | 135 | **24 277** | The whole shell: main window, tabs, view container, panels, search UI, settings dialogs, status bar, selection-mode bars, `admin/`. |
| `dolphin` (executable) | `src/CMakeLists.txt:511` | 3 | ~450 | `main.cpp` + `dbusinterface.cpp` only. |
| `kcm_dolphin{viewmodes,general}` (MODULE) | `src/CMakeLists.txt:562-563` | — | — | Gated `if(NOT WIN32)` — will need a macOS gate too. |

**The critical finding: `dolphinprivate` is not a headless core.** Its link line (`src/CMakeLists.txt:217-243`) pulls `KF6::KIOWidgets`, `KF6::KIOFileWidgets`, `KF6::TextWidgets`, `KF6::NewStuffWidgets`, `KF6::Parts`, `KF6::KCMUtils`, `KF6::WidgetsAddons`, and it inherits `Qt6::Widgets` publicly from `dolphinvcs` (`src/CMakeLists.txt:32-35`). It contains `DolphinView : QWidget` (`src/views/dolphinview.h:56`), `KItemListView : QGraphicsWidget` (`src/kitemviews/kitemlistview.h:55`), `KItemListContainer : QAbstractScrollArea`, `ViewPropertiesDialog : QDialog`, `ViewPropsProgressInfo : QDialog`, `KItemListRoleEditor : KTextEdit`. The existing split is **"reusable by `dolphinpart` and the KCMs"**, not **"UI-free"**. `libDolphinCore` is a *new* cut, roughly the lower half of `dolphinprivate`.

Two hygiene issues in the existing split worth noting up front:

* Four `.cpp` files are compiled into **both** `dolphinprivate` (a dylib) and `dolphinstatic`: `kitemviews/kfileitemlisttostring.cpp`, `selectionmode/actiontexthelper.cpp`, `settings/viewmodes/viewmodesettings.cpp`, `views/zoomlevelinfo.cpp` (compare `src/CMakeLists.txt:72-190` with `src/CMakeLists.txt:285-425`). On macOS's two-level namespace this yields duplicate definitions across the dylib boundary — harmless today, but it must not be replicated when we add a third target.
* `dolphinvcs` links `Qt6::Widgets` **PUBLIC** (`src/CMakeLists.txt:32-35`) although its only source file is 22 lines and touches nothing but `QObject`/`QAction` (`src/views/versioncontrol/kversioncontrolplugin.cpp:1-22`). In Qt 6 `QAction` lives in QtGui. This is over-linkage that transitively forces QtWidgets onto every consumer of `dolphinprivate`.

---

### 2. Component inventory

Legend for the reuse column: **A** = reusable as-is · **P** = reusable with patches · **R** = must be replaced for the AppKit frontend.

#### 2.1 `kitemviews/` — the custom item-view framework (19 950 LOC in `kitemviews/`, +5 203 in `kitemviews/private/`, +1 145 accessibility)

| Component | Files | LOC | Responsibility | QtWidgets | KXmlGui | KIOWidgets | Reuse |
|---|---|---|---|---|---|---|---|
| `KItemModelBase` (+ `KItemSet`, `KItemRange`, `SmallHash`) | `kitemviews/kitemmodelbase.*`, `kitemset.*`, `kitemrange.h`, `smallhash.h` | 1 524 | Abstract flat item model: `count()`/`data(int)`, sort role/order, group role, expansion, `createMimeData()` | **no** — includes only `QHash/QObject/QUrl/QVariant` (`kitemmodelbase.h:17-20`) | no | no | **A** |
| `KFileItemModel` (+ filter, sort algorithm) | `kitemviews/kfileitemmodel.*`, `private/kfileitemmodelfilter.*`, `private/kfileitemmodelsortalgorithm.h` | 4 320 | `KDirLister`-backed directory model, sorting/grouping/comparators, name+MIME filtering, tree expansion, drag MIME | **2 lines only** (see §3.1) | no | no | **P** (trivial) |
| `KFileItemModelRolesUpdater` | `kitemviews/kfileitemmodelrolesupdater.*` | 1 979 | Async previews (`KIO::PreviewJob`, KIOGui), MIME type, dir-size counting, Baloo roles, overlay icons, hover sequences | **2 call sites** (`qApp->activeWindow()`, lines 980, 1092) | no | no | **P** (trivial) |
| `KDirectoryContentsCounter` (+worker) | `kitemviews/private/kdirectorycontentscounter*.*` | 601 | Threaded recursive folder size/count via `fts(3)` | no | no | no | **A** (macOS has `fts.h`; the `#if defined(Q_OS_WIN) \|\| defined(Q_OS_HAIKU)` at `kdirectorycontentscounterworker.cpp:11,26,141` leaves macOS on the fts path) |
| `KItemListSelectionManager` | `kitemviews/kitemlistselectionmanager.*` | 492 | Current item + selected `KItemSet`, anchored (shift) selection, index fix-up on model mutation | no (zero includes beyond its own header, `kitemlistselectionmanager.cpp:10`) | no | no | **P** (friend/API change, §3.2) |
| `KFileItemClipboard` | `kitemviews/private/kfileitemclipboard.*` | 119 | Tracks "cut" items from `QClipboard` | QtGui only | no | no | **A** |
| `KItemListView` / `KStandardItemListView` / `KFileItemListView` | `kitemviews/kitemlistview.*`, `kstandarditemlistview.*`, `kfileitemlistview.*` | 4 859 | Render half: `QGraphicsWidget` scene, widget recycling, layouter, animations, header, rubber band | **yes, fundamentally** (`kitemlistview.h:21,55`) | no | no | **R** (Phase 3) |
| `KItemListWidget` / `KStandardItemListWidget` / `KFileItemListWidget` | `kitemviews/kitemlistwidget.*`, `kstandarditemlistwidget.*`, `kfileitemlistwidget.*` | 3 419 | Per-item painting: icon, text eliding, roles layout, expansion arrow, rating | yes (`QGraphicsWidget`) | no | no | **R** |
| `KItemListController` | `kitemviews/kitemlistcontroller.*` | 2 366 | Mouse/keyboard/gesture/DnD handling in scene coordinates; owns model+view+selection manager | yes (`QGraphicsScene*Event` throughout, `kitemlistcontroller.h:327-338`) | no | no | **R** (but its selection *semantics* must be re-implemented) |
| `KItemListContainer` | `kitemviews/kitemlistcontainer.*` | 543 | `QAbstractScrollArea` host for the graphics scene; smooth scrolling | yes | no | no | **R** |
| `private/` helpers (layouter, size-hint resolver, animation, rubber band, smooth scroller, header widget, role editor, selection toggle, pixmap modifier, keyboard search) | `kitemviews/private/*` | ~4 400 | Geometry, animation, inline rename | mostly yes | no | no | **R** except `kitemlistkeyboardsearchmanager` (**P**, pure `QObject`) and `kpixmapmodifier` (**A**) |
| Accessibility bridge | `kitemviews/accessibility/*` | 1 145 | `QAccessible*` for the graphics view | yes | no | no | **R** (NSAccessibility instead) |
| `KBalooRolesProvider` | `kitemviews/private/kbaloorolesprovider.*` | — | Baloo metadata roles | no | no | no | **R/drop** — `HAVE_BALOO` will be 0 on macOS (`CMakeLists.txt:126-149`) |

#### 2.2 `views/`

| Component | Files | LOC | Responsibility | QtWidgets | KXmlGui | KIOWidgets | Reuse |
|---|---|---|---|---|---|---|---|
| `DolphinView` | `views/dolphinview.*` | **4 003** | The monolith: URL/loading state machine, view-mode & zoom, sorting/filter plumbing, selection restore across reloads, **all file-operation orchestration** (trash/delete/cut/copy/paste/duplicate/rename), status-bar text, VCS wiring, tooltips, placeholder label | **`: public QWidget`** (`views/dolphinview.h:56`); ctor takes `QWidget *parent` (`:89`) | no (no `QAction` construction — that is `DolphinViewActionHandler`'s job) | yes (`KIO::RenameFileDialog`, `KIO::createDefaultJobUiDelegate(..., this)` at `views/dolphinview.cpp:909,922`, `KJobWidgets::setWindow(job, this)` ×5) | **P (split)** — see §4 |
| `DolphinViewActionHandler` | `views/dolphinviewactionhandler.*` | 1 302 | Builds ~40 `QAction`s in a `KActionCollection` and maps them onto the current `DolphinView` | via `KActionCollection` | yes — ctor is `(KActionCollection*, ActionTextHelper*, QObject*)` (`views/dolphinviewactionhandler.h:47`); 85 references to `actionCollection` | no | **R** (replaced by an NSMenu/`NSToolbar` command table; the *slot bodies* are the reusable part) |
| `DolphinItemListView`, `DolphinFileItemListWidget` | `views/dolphinitemlistview.*`, `dolphinfileitemlistwidget.*` | 510 | Dolphin-flavoured subclasses of `KFileItemListView`/`KFileItemListWidget` (zoom levels → icon sizes, VCS overlay painting) | yes | no | no | **R** |
| `ViewProperties` | `views/viewproperties.*` | 1 057 | Per-directory `.directory` / global view-properties persistence (mode, sort, hidden, previews, visible roles), incl. hashed remote-URL fallback | **no code**, but the header `#include "views/dolphinview.h"` (`views/viewproperties.h:12`) purely for `DolphinView::Mode` | no | no | **P** (extract the enum) |
| `VersionControlObserver` + `UpdateItemStatesThread` | `views/versioncontrol/versioncontrolobserver.*`, `updateitemstatesthread.*` | 842 (incl. plugin) | Loads VCS plugins, watches the model, writes `version` role back into `KFileItemModel` | no directly, but `setView(DolphinView*)` (`versioncontrolobserver.h:48`) only to hear `DolphinView::activated` | no | no | **P** (replace `setView(DolphinView*)` with a plain `refresh()` slot) |
| `KVersionControlPlugin` | `views/versioncontrol/kversioncontrolplugin.*` | 22 (.cpp) | Public plugin ABI; returns `QList<QAction*>` | Qt6 `QAction` is QtGui → **no real dependency** | no | no | **A** |
| `DragAndDropHelper` | `views/draganddrophelper.*` | 190 | `supportsDropping()` (pure), `dropUrls(dest, QDropEvent*, QWidget*)` (UI), Ark D-Bus drop | mixed | no | yes (`KIO::DropJob`) | **P (split)** |
| `ZoomLevelInfo` | `views/zoomlevelinfo.*` | 112 | zoom level ↔ icon size table | no | no | no | **A** |
| `ToolTipManager`, `DolphinFileMetaDataWidget` | `views/tooltips/*` | 523 | Rich hover tooltips | yes | no | no | **R** (and Baloo-gated: only built `if(HAVE_BALOO)`, `src/CMakeLists.txt:190+`) |
| `ViewModeController`, `DolphinRemoteEncoding`, `DolphinNewFileMenuObserver` | `views/*` | ~340 | Small helpers | mixed | no | no | **P** |

#### 2.3 Shell (`dolphinstatic`) — replaced wholesale by the AppKit frontend

| Component | Files | LOC | QtWidgets | KXmlGui | KIOWidgets | Reuse |
|---|---|---|---|---|---|---|
| `DolphinMainWindow` | `dolphinmainwindow.*` | **4 081** | yes | **`: public KXmlGuiWindow`** (`dolphinmainwindow.h:72`), plus an unconditional `new MainWindowAdaptor(this)` D-Bus adaptor (`dolphinmainwindow.cpp:142`) | yes | **R** |
| `DolphinTabWidget` + `DolphinTabBar` | `dolphintabwidget.*`, `dolphintabbar.*` | 1 280 | `: QTabWidget` / `: QTabBar` | via action collection | no | **R** (state machine worth porting, §3.5) |
| `DolphinTabPage` (+ splitter) | `dolphintabpage.*` | 901 | `: QWidget`, `: QSplitter` | no | no | **R** (`saveState()`/`restoreState()` at `dolphintabpage.h:127,133` are portable) |
| `DolphinViewContainer` | `dolphinviewcontainer.*` | 1 746 | `: QWidget` | takes `KActionCollection*` (`dolphinviewcontainer.h:170`) | yes | **R** |
| `DolphinContextMenu` | `dolphincontextmenu.*` | 693 | `: QMenu` (`dolphincontextmenu.h:34`); ctor needs `DolphinMainWindow*` | yes | yes (`KFileItemActions`) | **R** (the *composition rules* — trash menu, item menu, viewport menu, Open With — are the reusable spec) |
| `DolphinNewFileMenu` | `dolphinnewfilemenu.*` | 76 | `: KNewFileMenu` (KIOWidgets) | no | **yes** | **R** on AppKit; **A** for Phase 2 |
| `DolphinUrlNavigator` / `DolphinUrlNavigatorsController` | `dolphinurlnavigator.*`, `dolphinurlnavigatorscontroller.*` | 413 | `: KUrlNavigator` = `QWidget` (`kio: src/filewidgets/kurlnavigator.h:76`) | no | KIOFileWidgets | **R** — but see §3.2: history lives in `KCoreUrlNavigator` (KIOGui, `QObject`) |
| `DolphinNavigatorsWidgetAction` | `dolphinnavigatorswidgetaction.*` | 676 | `: QWidgetAction`, keeps two navigators aligned with split-view geometry | **yes** (`dolphinnavigatorswidgetaction.h:20` needs `KXmlGuiWindow`) | no | **R** (pure XMLGUI-toolbar workaround; irrelevant on macOS) |
| `selectionmode/` bars | `selectionmode/*` | 1 123 | yes | reads `KActionCollection` | no | **R** (touch-oriented; likely dropped on macOS) |
| `statusbar/` | `statusbar/*` | 1 608 | `DolphinStatusBar`, `StatusBarSpaceInfo` are widgets; **`MountPointObserver`, `MountPointObserverCache`, `SpaceInfoObserver` are pure `QObject`** (zero widget includes, `statusbar/mountpointobserver.cpp:7-9`) | no | no | **Mixed**: observers **A**, widgets **R** |
| `filterbar/` | `filterbar/filterbar.*` | 332 | yes | no | no | **R** |
| `search/` | `search/*` | 2 335 | `DolphinQuery` (751 LOC) is a **pure value type** — `search/dolphinquery.h:11-18` includes only `KFileMetaData/Types`, `QString`, `QUrl`; the rest (`bar`, `popup`, `chip`, selectors) are widgets | no | no | `DolphinQuery` **A**; UI **R** |
| `panels/places` | `panels/places/*` | 362 | `: KFilePlacesView` (KIOFileWidgets) | no | yes | **R** (`KFilePlacesModel` — `kio: src/filewidgets/kfileplacesmodel.h` — is a `QAbstractItemModel` and **is** reusable, but it ships in KIOFileWidgets, which links QtWidgets) |
| `panels/folders` | `panels/folders/*` | 836 | Second `KFileItemModel` + `KFileItemListView` instance (`panels/folders/folderspanel.cpp:13-18`) | no | no | **R** view / **A** model — proves the model is instantiable independently of `DolphinView` |
| `panels/information` | `panels/information/*` | 1 987 | yes; **entirely `if(HAVE_BALOO)`** (`src/CMakeLists.txt:425+`) | no | no | **Drop** on macOS |
| `panels/terminal` | `panels/terminal/*` | 487 | Loads the **Konsole KPart** (`panels/terminal/terminalpanel.cpp:16,20-22` — `KParts::ReadOnlyPart`, `KXMLGUIFactory`, `kde_terminal_interface.h`) and talks to KIOFuse over D-Bus | yes | **yes** | **R/drop** — see blocker `terminal-panel-macos` |
| `settings/` dialogs + KCMs | `settings/*` | ~3 800 | `KPageDialog`, `KCModule` | yes | yes | **R**; the generated `KConfigXT` classes (`settings/dolphin_*.kcfgc`, `src/CMakeLists.txt:203-213`) are **A** (KConfigCore only) |
| `admin/` | `admin/*` | 563 | `kio-admin` integration, runtime-gated by `KProtocolInfo::isKnownProtocol("admin")` (`admin/workerintegration.cpp:45`) | yes | yes | **Drop** on macOS |
| `trash/` | `trash/dolphintrash.*` | 149 | Trash emptiness watcher | only `empty(QWidget *window)` (`trash/dolphintrash.h:31`) | no | yes | **P** (trivial) |
| `itemactions/` | `itemactions/*` | 582 | Three out-of-process `KAbstractFileItemActionPlugin`s | yes | no | yes | **A** as plugins (`setfoldericonitemaction` is already `if(NOT WIN32)`-gated, `itemactions/CMakeLists.txt:29`) |

---

### 3. UI-free logic that is already separable

#### 3.1 Directory model — `KFileItemModel` (**cleanest win in the codebase**)

`KFileItemModel : KItemModelBase : QObject`. Its header pulls only `KFileItem`, `QCollator`, `QHash/QSet/QUrl/QVariant` (`kitemviews/kfileitemmodel.h:10-24`). It is already exercised headlessly by `src/tests/kfileitemmodeltest.cpp`, which constructs a bare `KFileItemModel` and drives it with `QSignalSpy` — no view, no container.

Exactly **two** widget touchpoints exist in 3 295 lines:

```
kitemviews/kfileitemmodel.cpp:32   #include <QWidget>
kitemviews/kfileitemmodel.cpp:292  const QWidget *parentWidget = qobject_cast<QWidget *>(parent);
kitemviews/kfileitemmodel.cpp:293-295   if (parentWidget) m_dirLister->setMainWindow(parentWidget->window());
kitemviews/kfileitemmodel.cpp:633  return !item.isNull() && DragAndDropHelper::supportsDropping(item);
```

`DragAndDropHelper::supportsDropping(const KFileItem&)` is a static, widget-free predicate (`views/draganddrophelper.h:56`) — only its sibling `dropUrls(..., QWidget *window, ...)` (`views/draganddrophelper.h:44`) is UI. Splitting that one file makes the model 100 % widget-free.

#### 3.2 Navigation / history — **already solved by KIO**

`DolphinUrlNavigator : KUrlNavigator : QWidget`, so it is not reusable. But `KUrlNavigator` is itself a thin skin over `KCoreUrlNavigator` (`kio: src/gui/kcoreurlnavigator.h:37`, a `QObject` in **KIOGui**), which owns the entire history state machine: `historySize()`, `historyIndex()`, `locationUrl(int)`, `locationState(int)`, `goBack()`, `goForward()`, `goUp()`, `saveLocationState()`. `KUrlNavigator` forwards to it verbatim (`kio: src/filewidgets/kurlnavigator.cpp:214, 1077-1104, 1361`).

**Consequence:** the AppKit frontend gets Dolphin's back/forward/up semantics for free by holding a `KCoreUrlNavigator` per view — no port, no fork.

The Dolphin-specific bits on top are (a) settings application (`DolphinUrlNavigatorsController::slotReadSettings()`, `dolphinurlnavigatorscontroller.h:38`) and (b) a `VisualState` struct for transferring editing state between split panes (`dolphinurlnavigator.h:47-55`) — both are UI concerns.

#### 3.3 Selection — `KItemListSelectionManager`

Pure `QObject`; `kitemlistselectionmanager.cpp` includes nothing but its own header. It carries all the selection semantics (anchored/shift ranges, index fix-up on insert/remove/move).

**But it is welded to the render half by C++ access control:**

```
kitemviews/kitemlistselectionmanager.h:70-74   private: void itemsInserted(...); itemsRemoved(...); itemsMoved(...);
kitemviews/kitemlistselectionmanager.h:90-91   friend class KItemListController; // Calls setModel()
                                               friend class KItemListView;       // Calls itemsInserted/Removed/Moved
```

and the only callers are inside the graphics view:

```
kitemviews/kitemlistview.cpp:1322  m_controller->selectionManager()->itemsInserted(itemRanges);
kitemviews/kitemlistview.cpp:1444  m_controller->selectionManager()->itemsRemoved(itemRanges);
kitemviews/kitemlistview.cpp:1472  m_controller->selectionManager()->itemsMoved(itemRange, movedToIndexes);
```

Drop `KItemListView` and selection silently desynchronises from the model on every file creation/deletion. **This is the single most important API change to land early.**

#### 3.4 View properties — `ViewProperties`

Not a `QObject` at all; `views/viewproperties.cpp:8-22` includes only `KFileItem`, `KFileMetaData/UserMetaData`, `QBuffer`, `QCryptographicHash` and the generated KConfigXT classes. Fully portable. Its *only* coupling is `#include "views/dolphinview.h"` (`views/viewproperties.h:12`) to name `DolphinView::Mode` in `setViewMode()`/`viewMode()` (`views/viewproperties.h:44-45`, used at `viewproperties.cpp:265-289, 351-362, 508, 557, 756-762`). Extracting a free `enum class DolphinViewMode { Icons, Details, Compact }` removes a `QWidget` header from the persistence layer.

#### 3.5 Tab & split-view state machine

`DolphinTabPage : QWidget` (`dolphintabpage.h:24`) and `DolphinTabWidget : QTabWidget` (`dolphintabwidget.h:21`) fuse state and widgetry, but the *state* is small and already serialised: `DolphinTabPage::saveState()/restoreState(QByteArray)` (`dolphintabpage.h:127,133`), `m_primaryViewActive`, `m_splitViewEnabled`, two `QPointer<DolphinViewContainer>` (`dolphintabpage.h:220-229`). This is ~200 LOC of genuine logic wrapped in 900 LOC of widget code — cheapest to **re-implement** in the core as a plain model rather than to extract.

#### 3.6 File-operation orchestration — the valuable, extractable half of `DolphinView`

`views/dolphinview.cpp` has 83 `KIO::`/`KJob` references. The operations (`renameSelectedItems():850`, `trashSelectedItems():903`, `deleteSelectedItems():916`, `cutSelectedItemsToClipboard():929`, `copySelectedItemsToClipboard():937`, `copySelectedItems():944`, `moveSelectedItems():966`, `paste():988`, `pasteIntoFolder():993`, `duplicateSelectedItems():1001`, `pasteToUrl():2637`, `copyPathToClipboard():2748`) are ~600 LOC of pure KIO logic whose *only* UI coupling is passing `this` (the `QWidget`) as a job parent:

```
views/dolphinview.cpp:909  trashJob->setUiDelegate(KIO::createDefaultJobUiDelegate(KJobUiDelegate::AutoWarningHandlingEnabled, this));
views/dolphinview.cpp:955  KJobWidgets::setWindow(job, this);      // also :977, :1041, :2365, :2640
views/dolphinview.cpp:891  KMessageBox::error(this, job->errorString());
views/dolphinview.cpp:1223 KMessageBox::warningContinueCancel(...)
views/dolphinview.cpp:874  KIO::RenameFileDialog *dialog = new KIO::RenameFileDialog(items, this);
```

Every one of these is replaceable by an injected delegate. Note that KIO already provides the widget-free seams: `KIO::AskUserActionInterface` lives in **KIOCore** (`kio: src/core/askuseractioninterface.h:45`) and `DolphinView` already uses its enums (`views/dolphinview.cpp:907, 920`); and `KJobWindows::setWindow(KJob*, QWindow*)` is the `QWindow` counterpart KIO uses internally (`kio: src/widgets/dropjob.cpp:28,630`).

#### 3.7 Other already-clean pieces

* `SpaceInfoObserver` / `MountPointObserver` / `MountPointObserverCache` — pure `QObject`, statfs polling.
* `DolphinQuery` — pure value type; parses/serialises `filenamesearch:` and `baloosearch:` URLs (`search/dolphinquery.cpp:130,149,233`). The `filenamesearch` half is macOS-viable; the Baloo half is not.
* `Dolphin::validateUris()`, `Dolphin::homeUrl()`, `Dolphin::sortOrderForUrl()` (`global.h:19-49`) — portable; the same header's `attachToExistingInstance()`/`dolphinGuiInstances()` are D-Bus and must be split out.
* Generated KConfigXT settings singletons (`GeneralSettings`, `ContentDisplaySettings`, …) — `KF6::ConfigCore` only. `KFileItemModel` already depends on them directly (`kfileitemmodel.cpp:286, 336, 1305-1308, 2425`), so they must move into the core.

---

### 4. `kitemviews/` model ⟷ view separability (decides Phase 3)

**Verdict: the model half is cleanly separable. The roles-updater half is not, but the fix is small and mechanical.**

#### 4.1 The model→view contract is exactly nine signals

`KItemListView::setModel()` (`kitemviews/kitemlistview.cpp`, the `setModel` body) connects and disconnects precisely:

`itemsChanged`, `itemsInserted`, `itemsRemoved`, `itemsMoved`, `groupsChanged`, `groupedSortingChanged`, `sortOrderChanged`, `sortRoleChanged`, `groupRoleChanged`

— all declared on `KItemModelBase` (`kitemviews/kitemmodelbase.h:200-249`). Nothing else flows model→view. `KItemModelBase` has **zero** knowledge of `KItemListView`: no include, no forward declaration, no pointer. An `NSCollectionView`/`NSTableView` data source needs to implement exactly this nine-signal protocol plus `count()`/`data(int)`.

#### 4.2 The three real coupling points

| # | Coupling | Evidence | Fix |
|---|---|---|---|
| 1 | **Selection manager is only mutated by `KItemListView`** | `kitemlistselectionmanager.h:70-74, 91`; `kitemlistview.cpp:1322, 1444, 1472` | Make `itemsInserted/Removed/Moved` public slots, or (better upstream) have `KItemListSelectionManager::setModel()` connect to the model's signals directly and drop the friendship. **Upstreamable** — it removes a friend declaration and a hidden ordering dependency. |
| 2 | **`KFileItemModelRolesUpdater` is created, owned and driven by `KFileItemListView`** | `kitemviews/kfileitemlistview.h:124` (member); `kfileitemlistview.cpp:239-248` (`onModelChanged` deletes and re-creates it, parented to the graphics widget); `kfileitemlistview.cpp:388-390, 413-422` (feeds it `setMaximumVisibleItems`/`setVisibleIndexRange`/`setIconSize`/`setPaused`) | The updater's own API is already view-agnostic: `KFileItemModelRolesUpdater(KFileItemModel*, QObject* parent)` (`kfileitemmodelrolesupdater.h:87`), `setVisibleIndexRange(int,int)` (`:100`), `setMaximumVisibleItems(int)` (`:102`), `setIconSize(QSize)` (`:90`), `setDevicePixelRatio(qreal)` (`:93`), `setPaused(bool)` (`:125`), `setRoles(QSet<QByteArray>)` (`:131`). **The core just instantiates it itself** and the AppKit view feeds it the visible range from `NSCollectionView`'s `visibleItems`. No fork needed. |
| 3 | **Two QtWidgets calls inside the updater** | `kfileitemmodelrolesupdater.cpp:980` and `:1092` — `KJobWidgets::setWindow(job, qApp->activeWindow())` (`QApplication::activeWindow()` is QtWidgets-only) | Replace with an injectable `QWindow*` (`KJobWindows::setWindow`) or `#ifdef` it out. ~6 lines. |

Note also `KItemViewsUtils::devicePixelRatio(const QGraphicsItem*)` (`kitemviews/private/kitemviewsutils.h:17`, `.cpp:14-19`) — the only reason the updater's DPR comes from the graphics view. On AppKit, feed `NSScreen.backingScaleFactor` into `setDevicePixelRatio()` directly.

#### 4.3 What `KFileItemModelRolesUpdater` does (and why a native view still wants it)

1 537 LOC of carefully-tuned incremental work (`kfileitemmodelrolesupdater.cpp`). It writes resolved role values back into the model via `KItemModelBase::setData()`:

* **Thumbnails/previews** — `KIO::PreviewJob` (**KIOGui**, `kio: src/gui/previewjob.h` — no widget dependency), result stored as the `iconPixmap` role (`:576`); on failure falls back to `iconName` (`:1247`). Also drives *hover sequence* previews (animated video/GIF scrubbing, `:1064, 646`).
* **Icon post-processing** — frames/borders for non-alpha previews via `KPixmapModifier` + `QPainter` (`:998-1015`).
* **Overlay icons** — `KOverlayIconPlugin` results into the `iconOverlays` role (`:1380, 1404`).
* **MIME type resolution** — `type` role from `KFileItem::mimeComment()` (`:1203, 1372`), deliberately deferred because `KDirLister` runs with `setDelayedMimeTypes(true)` (`kfileitemmodel.cpp:290`).
* **Recursive folder sizes / item counts** — via `KDirectoryContentsCounter`, into the `size` and `isExpandable` roles (`:877-880, 1519`).
* **Baloo metadata** — rating/tags/comment/document/image/audio/video roles, all under `#if HAVE_BALOO` (`kfileitemmodelrolesupdater.cpp:27, 93, 118, 296, 414, 820, 836, 1383`). **Zero on macOS**, which removes ~26 of the 48 roles in `KFileItemModel::rolesInfoMap()` (`kfileitemmodel.cpp:3143-3190`; every row with `requiresBaloo = true`).
* **Throttling** — only the visible range + margins + first/last page are resolved, and everything pauses during scrolling (`:371, 390, 422`).

Re-implementing this against `QLookupThumbnailer`/QuickLook would be a multi-week job and would abandon Dolphin's thumbnailer plugin ecosystem. **Keep it.**

---

### 5. Proposed `libDolphinCore` boundary

Three targets, strictly layered. Nothing in a lower layer may include a higher-layer header.

```
libDolphinCore   (no QtWidgets, no KXmlGui, no KIOWidgets, no KIOFileWidgets, no D-Bus)
      ↑                                 ↑
libDolphinQtUi (Phase 2)        macos/ frontend (Phase 3, Objective-C++)
   = today's DolphinView/           = AppKitViewSurface + NSWindow shell
     KItemListView stack
```

#### 5.1 Files that move into `libDolphinCore`

**Model & roles** (moved unchanged or with the 2-line patches of §4.2):
`kitemviews/kitemmodelbase.*`, `kitemset.*`, `kitemrange.h`, `smallhash.h`, `kfileitemmodel.*`, `kfileitemmodelrolesupdater.*`, `kfileitemlisttostring.*`, `kitemlistselectionmanager.*`, `private/kfileitemmodelfilter.*`, `private/kfileitemmodelsortalgorithm.h`, `private/kdirectorycontentscounter*.*`, `private/kfileitemclipboard.*`, `private/kitemlistkeyboardsearchmanager.*`, `private/kpixmapmodifier.*`.

**Persistence & config:** `views/viewproperties.*`, `views/zoomlevelinfo.*`, `settings/viewmodes/viewmodesettings.*`, all `settings/dolphin_*.kcfgc` generated classes, `settings/applyviewpropsjob.*`.

**Domain logic:** `views/versioncontrol/*` (+ keep `dolphinvcs` as-is, relinked to `Qt6::Gui`), `search/dolphinquery.*`, `statusbar/{mountpointobserver,mountpointobservercache,spaceinfoobserver}.*`, `trash/dolphintrash.*` (patched), `global.cpp` minus the D-Bus functions, the pure half of `views/draganddrophelper.*`.

**New, written by us** (the actual extraction work): `DolphinViewCore`, `DolphinFileOperations`, `DolphinNavigator`, `DolphinTabModel`/`DolphinSessionModel`, `IDolphinItemSurface`, `IDolphinUiHost`.

**Stays in the Qt UI layer:** everything `QGraphicsWidget`-based (`kitemlistview`, `kitemlistwidget`, `kstandarditem*`, `kfileitemlist{view,widget}`, `kitemlistcontroller`, `kitemlistcontainer`, all remaining `private/` geometry+animation helpers, `accessibility/`), `views/dolphinitemlistview.*`, `views/dolphinfileitemlistwidget.*`, `views/tooltips/*`, `views/dolphinviewactionhandler.*`, `settings/viewpropertiesdialog.*`, `settings/viewpropsprogressinfo.*`, `views/zoomwidgetaction.*`, `dolphinnewfilemenu.*`, and the whole of today's `dolphinstatic`.

#### 5.2 Public API surface (pseudo-C++)

```cpp
// ── dolphincore/dolphinviewmode.h ─────────────────────────────────────────
// Extracted from DolphinView::Mode so ViewProperties stops including a QWidget header.
enum class DolphinViewMode { Icons = 0, Details = 1, Compact = 2 };

// ── dolphincore/idolphinuihost.h ──────────────────────────────────────────
// Everything the core needs from "a window", with zero widget types.
// Phase 2: implemented by a QWidget adapter.  Phase 3: by an NSWindow adapter.
class DOLPHINCORE_EXPORT IDolphinUiHost {
public:
    virtual ~IDolphinUiHost();
    enum class MessageType { Information, Warning, Error, Positive };

    // Job parenting: today's `KJobWidgets::setWindow(job, this)` (dolphinview.cpp:955,977,1041,2365,2640)
    virtual QWindow *nativeWindow() const = 0;
    virtual void attachToJob(KJob *job) = 0;               // KJobWindows::setWindow + ui delegate
    virtual KIO::AskUserActionInterface *askUser() const = 0;  // KIOCore, not KIOWidgets

    // Replaces KMessageBox::error / warningContinueCancel (dolphinview.cpp:891,1223,2302)
    virtual void showMessage(const QString &text, MessageType) = 0;
    virtual void confirm(const QString &text, const QString &acceptLabel,
                         std::function<void(bool accepted)> done) = 0;   // async: no nested event loop

    // Replaces KIO::RenameFileDialog (dolphinview.cpp:874)
    virtual void requestBatchRename(const KFileItemList &, std::function<void(QList<QUrl>)> done) = 0;
};

// ── dolphincore/idolphinitemsurface.h ─────────────────────────────────────
// The render half, abstracted.  Derived DIRECTLY from the 46 `m_view->…`, 7 `m_container->…`
// and 34 `controller()->…` call sites in views/dolphinview.cpp — nothing invented.
class DOLPHINCORE_EXPORT IDolphinItemSurface {
public:
    virtual ~IDolphinItemSurface();

    // --- core → surface (imperative) ---
    virtual void setModel(KFileItemModel *) = 0;
    virtual void setViewMode(DolphinViewMode) = 0;            // was m_view->setItemLayout()
    virtual void setZoomLevel(int) = 0;                       // was m_view->setZoomLevel()
    virtual int  zoomLevel() const = 0;
    virtual void setVisibleRoles(const QList<QByteArray> &) = 0;
    virtual QList<QByteArray> visibleRoles() const = 0;
    virtual void setPreviewsShown(bool) = 0;                  // forwarded to the roles updater
    virtual void scrollToItem(int index) = 0;
    virtual void beginTransaction() = 0;                      // batch layout suppression
    virtual void endTransaction() = 0;
    virtual void beginInlineRename(int index, const QByteArray &role) = 0;  // was m_view->editRole()
    virtual int  itemAt(const QPointF &viewPos) const = 0;
    virtual QRectF itemRect(int index) const = 0;             // for context-menu / tooltip anchoring
    virtual QPoint contentsPosition() const = 0;              // saveState/restoreState
    virtual void  setContentsPosition(const QPoint &) = 0;
    virtual void  setFocus() = 0;
    virtual int   horizontalScrollBarHeight() const = 0;
    virtual void  setStatusBarOffset(int) = 0;

    // Column header (Details mode) — was m_view->header()
    virtual void setColumnWidths(const QList<qreal> &) = 0;
    virtual QList<qreal> columnWidths() const = 0;

    // --- surface → core (callbacks; the core installs these once) ---
    struct Callbacks {
        std::function<void(int index)>                            itemActivated;
        std::function<void(const KItemSet &)>                     itemsActivated;
        std::function<void(int index)>                            itemMiddleClicked;
        std::function<void(int index, const QPointF &globalPos)>  itemContextMenuRequested;
        std::function<void(const QPointF &globalPos)>             viewContextMenuRequested;
        std::function<void(int roleIndex, const QPointF &)>       headerContextMenuRequested;
        std::function<void(int index)>                            itemHovered;
        std::function<void()>                                     itemUnhovered;
        std::function<void(int index, const QMimeData *, Qt::DropAction)> itemDropped;
        std::function<void()>                                     escapePressed;
        std::function<void(int delta)>                            zoomRequested;
        std::function<void(int first, int count)>                 visibleRangeChanged;  // → roles updater
        std::function<void(QByteArray role, Qt::SortOrder)>       sortChangedByHeader;
        std::function<void(QList<QByteArray>)>                    visibleRolesChangedByHeader;
        std::function<void(int index, QByteArray role, QVariant)> inlineRenameFinished;
    };
    virtual void setCallbacks(Callbacks) = 0;

    // Selection is owned by the CORE, not the surface.  The surface only reflects it.
    virtual void onSelectionChanged(const KItemSet &current) = 0;
    virtual void onCurrentItemChanged(int current) = 0;
};

// ── dolphincore/dolphinviewcore.h ─────────────────────────────────────────
// The headless residue of today's 4003-LOC DolphinView.  QObject, never QWidget.
class DOLPHINCORE_EXPORT DolphinViewCore : public QObject {
    Q_OBJECT
public:
    DolphinViewCore(const QUrl &url, IDolphinUiHost *host, QObject *parent = nullptr);

    void attachSurface(IDolphinItemSurface *);   // Phase 2: Qt surface.  Phase 3: AppKit surface.
    void detachSurface();

    KFileItemModel               *model() const;
    KItemListSelectionManager    *selection() const;
    KFileItemModelRolesUpdater   *rolesUpdater() const;   // core owns it now — see §4.2 #2
    KCoreUrlNavigator            *navigator() const;      // KIOGui; history for free

    QUrl url() const;
    KFileItem rootItem() const;
    KFileItemList items() const;
    KFileItemList selectedItems() const;
    int  selectedItemsCount() const;
    bool isFolderWritable() const;

    void setViewMode(DolphinViewMode);   DolphinViewMode viewMode() const;
    void setZoomLevel(int);              int  zoomLevel() const;
    void setSortRole(const QByteArray&); void setSortOrder(Qt::SortOrder);
    void setGroupedSorting(bool);        void setHiddenFilesShown(bool);
    void setPreviewsShown(bool);         void setVisibleRoles(const QList<QByteArray>&);
    void setNameFilter(const QString&);  void setMimeTypeFilters(const QStringList&);

    void markUrlsAsSelected(const QList<QUrl>&);
    void markUrlAsCurrent(const QUrl&);
    void selectAll(); void invertSelection(); void clearSelection();
    void selectItems(const QRegularExpression&, bool enabled);

    void saveState(QDataStream&) const;  void restoreState(QDataStream&);

public Q_SLOTS:
    void setUrl(const QUrl&); void reload(); void stopLoading();

Q_SIGNALS:
    void urlChanged(const QUrl&);
    void directoryLoadingStarted();
    void directoryLoadingProgress(int percent);
    void directoryLoadingCompleted();
    void directoryLoadingCanceled();
    void itemCountChanged();
    void selectionChanged(const KFileItemList&);
    void itemActivated(const KFileItem&);
    void itemsActivated(const KFileItemList&);
    void requestContextMenu(const KFileItem &hit, const KFileItemList &sel,
                            const QUrl &baseUrl, const QPointF &globalPos);
    void requestInlineRename(int index);
    void statusBarTextChanged(const QString&);
    void infoMessage(const QString&);
    void errorMessage(const QString&);
    void writeStateChanged(bool isFolderWritable);
};

// ── dolphincore/dolphinfileoperations.h ───────────────────────────────────
// Lifted verbatim from views/dolphinview.cpp:850-1010, 2637-2760, with `this`
// replaced by IDolphinUiHost.  Free functions: no state to own.
namespace DolphinFileOperations {
DOLPHINCORE_EXPORT void trash    (const QList<QUrl>&, IDolphinUiHost*, std::function<void(KJob*)> done = {});
DOLPHINCORE_EXPORT void deleteNow(const QList<QUrl>&, IDolphinUiHost*, std::function<void(KJob*)> done = {});
DOLPHINCORE_EXPORT void copyTo   (const KFileItemList&, const QUrl &dest, IDolphinUiHost*);
DOLPHINCORE_EXPORT void moveTo   (const KFileItemList&, const QUrl &dest, IDolphinUiHost*);
DOLPHINCORE_EXPORT void duplicate(const KFileItemList&, IDolphinUiHost*);
DOLPHINCORE_EXPORT void pasteInto(const QUrl &dest, IDolphinUiHost*);
DOLPHINCORE_EXPORT void cutToClipboard (const KFileItemList&);
DOLPHINCORE_EXPORT void copyToClipboard(const KFileItemList&);
DOLPHINCORE_EXPORT std::pair<bool, QString> pasteInfo(const QUrl &dest);  // was DolphinView::pasteInfo()
DOLPHINCORE_EXPORT void drop(const QUrl &destUrl, const QMimeData*, Qt::DropAction, IDolphinUiHost*);
}

// ── dolphincore/dolphinsessionmodel.h ─────────────────────────────────────
// Re-implementation (not extraction) of DolphinTabPage/DolphinTabWidget state.
class DOLPHINCORE_EXPORT DolphinTabModel : public QObject {
    Q_OBJECT
public:
    DolphinViewCore *primary() const;
    DolphinViewCore *secondary() const;      // nullptr unless split
    DolphinViewCore *active() const;
    bool splitViewEnabled() const;
    void setSplitViewEnabled(bool, const QUrl &secondaryUrl = {});
    void setPrimaryActive(bool);
    QString displayName() const;             // tab title
    QByteArray saveState() const;  void restoreState(const QByteArray&);
};
class DOLPHINCORE_EXPORT DolphinSessionModel : public QObject { /* tab list, ordering, restore */ };
```

#### 5.3 How this satisfies "Phase 2 embeds Qt, Phase 3 swaps AppKit, no re-plumbing"

* **Phase 2** ships `class QtItemSurface : public IDolphinItemSurface` wrapping `DolphinItemListView` + `KItemListContainer` + `KItemListController`. It is a thin adapter (est. 400-600 LOC) because §3 showed the surface API is only ~20 methods and ~15 callbacks. `DolphinView` becomes `DolphinViewCore` + `QtItemSurface` + a `QWidget` shell that hosts the container and the placeholder label.
* **Phase 3** ships `class AppKitItemSurface : public IDolphinItemSurface` in `macos/`, backed by `NSCollectionView` (icons/compact) and `NSTableView` (details). It implements the same 20 methods. **`DolphinViewCore`, the model, the roles updater, view-properties persistence, the file operations and the navigation history are untouched.**
* Selection stays authoritative in the core (`KItemListSelectionManager`), so the AppKit view is a *reflector* of selection, not an owner — which also sidesteps `NSCollectionView`'s awkward selection-index-path bookkeeping across model mutations.
* Previews work identically in both phases because the core owns `KFileItemModelRolesUpdater` and the surface only reports `visibleRangeChanged`.

---

### 6. Upstreamability

| # | Change | Class | Rationale / benefit to KDE |
|---|---|---|---|
| 1 | Extract `DolphinView::Mode` into a standalone `dolphinviewmode.h`; drop `#include "views/dolphinview.h"` from `views/viewproperties.h:12` | **(a) upstreamable** | Removes a `QWidget` header from a pure-persistence class; speeds up KDE's build too |
| 2 | Delete the two dead includes in the most-included public header: `views/dolphinview.h:12` (`dolphintabwidget.h` — grep for `DolphinTabWidget` in `dolphinview.{h,cpp}` returns **nothing**) and `views/dolphinview.h:20` (`<kparts/part.h>` — grep for `KParts` returns **nothing**) | **(a)** | `dolphinview.h` currently drags a `dolphinstatic` header (`QTabWidget`) into a `dolphinprivate` public header — a layering violation |
| 3 | `dolphinvcs`: `Qt6::Widgets` → `Qt6::Gui` (`src/CMakeLists.txt:32-35`) | **(a)** | `QAction` is QtGui in Qt 6; removes QtWidgets from `dolphinprivate`'s PUBLIC transitive link |
| 4 | `KItemListSelectionManager`: make `itemsInserted/Removed/Moved` public (or self-connect in `setModel()`); drop `friend class KItemListView` (`kitemlistselectionmanager.h:70-74, 91`) | **(a)** | Removes a hidden ordering dependency; makes the class independently testable — KDE already has `kitemlistselectionmanagertest` |
| 5 | `KFileItemModel`: guard/remove the `qobject_cast<QWidget*>(parent)` → `KDirLister::setMainWindow()` path (`kfileitemmodel.cpp:32, 292-295`); replace with an explicit `setMainWindow(QWindow*)` setter | **(a)** | Makes the model widget-free; the current implicit-parent-sniffing is fragile |
| 6 | Split `views/draganddrophelper.*` into `DragAndDropHelperCore` (`supportsDropping`, `urlListMatchesUrl`) and `DragAndDropHelper` (UI) | **(a)** | Un-couples the model from a UI helper (`kfileitemmodel.cpp:633`) |
| 7 | `KFileItemModelRolesUpdater`: replace `KJobWidgets::setWindow(job, qApp->activeWindow())` (`:980, :1092`) with an injectable `QWindow*` | **(a)** | Removes the last QtWidgets symbol from the preview pipeline; helps KDE's Plasma-mobile/QML consumers too |
| 8 | `VersionControlObserver::setView(DolphinView*)` (`versioncontrolobserver.h:48`) → a plain `refresh()` slot the caller connects | **(a)** | Removes a `QWidget` from a plugin-loading class |
| 9 | `Trash::empty(QWidget*)` (`trash/dolphintrash.h:31`) → `empty(QWindow*)` | **(a)** | |
| 10 | Introduce `IDolphinItemSurface` and make `DolphinView` drive it instead of `DolphinItemListView` directly | **(a) if accepted, else (c)** | This is the one *architectural* proposal. It is defensible upstream (KDE has repeatedly wanted a QML/Kirigami Dolphin view) but is the riskiest to land. Design it so that, if rejected, it lives entirely in **new** files and the diff to existing files stays at the "extract method / change one member type" level. |
| 11 | Split the four duplicated `.cpp`s out of `dolphinstatic` (`src/CMakeLists.txt`) | **(a)** | |
| 12 | macOS gates: `HAVE_TERMINAL` currently `TRUE` on macOS (`CMakeLists.txt:152-157`, only `WIN32` excluded) → add `OR APPLE`; gate the KCM modules (`src/CMakeLists.txt:562`) and `settings/contextmenu/servicemenuinstaller` (`src/CMakeLists.txt:641`) | **(b) macOS-only `#ifdef`/CMake gate** | Upstream already carries `Q_OS_MACOS` branches (`kitemlistcontainer.cpp:190`, `kitemlistsmoothscroller.cpp:218`, `dolphinmainwindow.cpp:152`, `main.cpp:88`), so this pattern is precedented and small patches here are likely acceptable upstream |
| 13 | Guard the two unconditional `QDBusConnection::sessionBus()` uses in `dolphinprivate`: `views/draganddrophelper.cpp:49` (Ark drop-extract) and `kitemviews/private/kitemlistsmoothscroller.cpp:32` (KDE animation-speed change signal) | **(b)** | Prevents per-launch D-Bus autolaunch attempts/warnings on macOS |
| 14 | Everything under `macos/` — `AppKitItemSurface`, `NSWindow` shell, menu/toolbar tables, Finder-idiom behaviours | **(c) unavoidable fork, but additive-only** | New directory, zero edits to upstream files |

**Keeping the patch set small and rebasable**

```
Dolphin-for-macOS/
  upstream/dolphin/            # pristine git checkout, never edited
  patches/
    series                     # quilt-style, ordered
    0001-viewproperties-extract-viewmode-enum.patch      (a)
    0002-dolphinview-drop-dead-includes.patch            (a)
    0003-dolphinvcs-link-qtgui-not-qtwidgets.patch       (a)
    0004-selectionmanager-public-model-hooks.patch       (a)
    0005-kfileitemmodel-drop-qwidget-parent-sniffing.patch (a)
    0006-draganddrophelper-split-core.patch              (a)
    0007-rolesupdater-injectable-window.patch            (a)
    0008-vcsobserver-drop-dolphinview.patch              (a)
    0009-trash-qwindow.patch                             (a)
    0100-macos-gate-terminal-kcm-servicemenu.patch       (b)
    0101-macos-guard-dbus-calls.patch                    (b)
    0200-introduce-idolphinitemsurface.patch             (a?)
  core/                        # NEW files only: libDolphinCore glue (DolphinViewCore,
                               # DolphinFileOperations, DolphinSessionModel, IDolphinUiHost)
  macos/                       # NEW: Objective-C++ frontend
```

Rules that keep this rebasable: (i) numbering separates upstreamable (`0001-0099`) from macOS-only (`0100-0199`) from architectural (`0200+`), so the first block can be submitted to KDE and dropped from the series as it lands; (ii) all *new* code lives in `core/` and `macos/`, never inside `upstream/`; (iii) every patch touches ≤ 3 files. Total edited-line budget for the (a)+(b) blocks: **roughly 250 lines across 18 upstream files** — well inside "rebase weekly by hand" territory. The only large-diff item is #10, which is why it is isolated as `0200-`.

---

### 7. Phased migration order

| Step | Work | Depends on | Ends when |
|---|---|---|---|
| **0** | Build KF6 + KIO from source; build `dolphinprivate` unmodified with `HAVE_BALOO=0`, `HAVE_KUSERFEEDBACK=0`, `HAVE_PACKAGEKIT=0`. Do **not** try to build `dolphinstatic`/`dolphin` yet. | — | `libdolphinprivate.dylib` links on arm64 |
| **1** | Apply patches `0001-0009` + `0100-0101`. Stand up a `dolphincore_smoke` console binary: `QCoreApplication` + `KFileItemModel::loadDirectory()` + `KFileItemModelRolesUpdater` + `KItemListSelectionManager`, printing roles and thumbnail arrivals. Model after `src/tests/kfileitemmodeltest.cpp`. | 0 | Directory listing, sorting, previews and dir-size counting all work with **no QApplication and no QGraphicsWidget** |
| **2** | Create the `dolphincore` CMake target and physically move the §5.1 file list into it; make `dolphinprivate` link `dolphincore`. Nothing else changes; upstream tests must still pass. | 1 | Two libraries, no behaviour change, `dolphincore` link line contains no `*Widgets` |
| **3** | Extract `DolphinFileOperations` + `IDolphinUiHost` out of `DolphinView` (the §3.6 method list). `DolphinView` keeps its methods as one-line forwarders through a `QWidgetUiHost`. | 2 | `dolphinviewtest` still green |
| **4** | Introduce `IDolphinItemSurface` + `QtItemSurface`; split `DolphinView` into `DolphinViewCore` (`QObject`) + a thin `DolphinViewWidget` shell. Move ownership of `KFileItemModelRolesUpdater` from `KFileItemListView` up into `DolphinViewCore`. | 3, and §4.2 fixes #1 and #2 | `dolphinviewtest`, `kfileitemlistviewtest`, `dolphinitemlistviewtest` green; `DolphinViewCore` compiles against `dolphincore` only |
| **5** | `DolphinNavigator` over `KCoreUrlNavigator`; `DolphinTabModel`/`DolphinSessionModel` re-implemented headlessly (port `DolphinTabPage::saveState/restoreState` semantics). | 2 | Back/forward/up/split/tab-restore covered by headless unit tests |
| **6 (Phase 2 deliverable)** | AppKit `NSWindow` shell hosting `QtItemSurface` inside an `NSView` (Qt widget embedding), driven by `DolphinViewCore` + `DolphinSessionModel`. Native menus/toolbar call into `DolphinFileOperations`. `DolphinViewActionHandler` is **not** ported — the command table is rebuilt natively. | 4, 5 | A macOS app that browses, selects, previews and does file ops, with a Qt-rendered file list |
| **7 (Phase 3)** | `AppKitItemSurface` (NSCollectionView / NSTableView) implementing `IDolphinItemSurface`. Swap it in behind a runtime flag so both surfaces stay testable side by side. | 6 | Icons + Details + Compact rendered natively; **zero changes below `IDolphinItemSurface`** |
| **8** | Native context menus from `DolphinContextMenu`'s composition rules; native inline rename; NSAccessibility. Submit patch block `0001-0009` upstream. | 7 | Patch series shrinks to `0100+` |

**Critical path:** step 4 gates everything native. Its two prerequisites (`KItemListSelectionManager` public model hooks, and moving the roles updater's ownership) are both small, mechanical and independently upstreamable — **do them first, in step 1**, so they are settled before any large refactor rides on them.

**Explicitly out of scope for reuse:** `panels/terminal` (Konsole KPart), `panels/information` + `views/tooltips` + all Baloo roles (`HAVE_BALOO=0`), `admin/`, `selectionmode/` bars, `dolphinnavigatorswidgetaction` (an XMLGUI-toolbar workaround), `userfeedback/`, `settings/kcm/`, and `dolphinpart`.

## Baloo, KFileMetaData & Search

**TL;DR** — `KF6FileMetaData` is genuinely required but is the *easy* dependency: it builds on macOS (it has an explicit `Q_OS_MAC` xattr backend, and every extractor dep is optional), and Dolphin only uses three of its APIs, none of which touch an extractor. `KF6Baloo`/`KF6BalooWidgets` should simply be left off — the `#if HAVE_BALOO` handling in `src/` is unusually disciplined and compiles cleanly with real `#else` stubs, at the cost of the Information Panel, all hover tooltips, and ~30 metadata columns. **The real casualty is search: with Baloo off *and* `filenamesearch` excluded on APPLE, Dolphin's MVP has literally zero working search — pressing Enter in the search bar produces the error message `Invalid protocol 'filenamesearch'`.** Two fixes exist; the cheap one (port `filenamesearch`, it needs a 2-line D-Bus removal) unblocks Phase 1/2, and a `spotlight:/` KIO worker is the correct Phase-3 answer because `KFileItemModel` has exactly one data source — `KDirLister::openUrl()` — so a URL-scheme backend requires **zero** changes to the view/model stack.

---

### 1. KF6FileMetaData — REQUIRED, and that is fine

**The gate** (dolphin, `CMakeLists.txt:120-125`):

```cmake
find_package(KF6FileMetaData ${KF6_MIN_VERSION})       # KF6_MIN_VERSION = 6.23.0 (CMakeLists.txt:15)
set_package_properties(KF6FileMetaData PROPERTIES
                       URL "https://projects.kde.org/kfilemetadata"
                       TYPE REQUIRED                    # <-- CMakeLists.txt:123
                       PURPOSE "For accessing file metadata labels and filesystem metadata"
                      )
```

It is linked into `dolphinprivate` unconditionally (`src/CMakeLists.txt:238`, `KF6::FileMetaData`), i.e. outside any `if(HAVE_BALOO)` block.

#### What Dolphin actually uses from it

Exhaustive grep over `src/` (excluding `src/tests/`) yields **three** API surfaces, none of which need an extractor plugin:

| API | Used at | Purpose | Needs extractors? |
|---|---|---|---|
| `KFileMetaData::UserMetaData` | `src/views/viewproperties.cpp:22,54,641,680,714` | **Stores per-folder view properties in an extended attribute**, with `.directory`-file fallback | No — pure xattr |
| `KFileMetaData::UserMetaData` | `src/kitemviews/kfileitemmodel.cpp:18,2354` | reads `md.rating()` for the `rating` role | No |
| `KFileMetaData::Type` / `TypeInfo` | `src/search/dolphinquery.h:15,265`, `dolphinquery.cpp:16,194-195,303,408,441`, `src/search/selectors/filetypeselector.cpp:12,21-56` | the file-type enum + display names for the search UI's type filter | No — static enum/registry |
| `KFileMetaData::PropertyInfo` | `src/kitemviews/private/kbaloorolesprovider.cpp:11-12,111` | Baloo-only (file is `if(HAVE_BALOO)`-gated, `src/CMakeLists.txt:197`) | n/a |

The `viewproperties.cpp` usage is the important one and it is **guarded**: `if (!metadata.isSupported())` at `viewproperties.cpp:54` and `:642` falls back to a `.directory` `KConfig` file. So even a broken xattr layer degrades rather than breaks.

#### Does kfilemetadata build on macOS?

I could not verify from a local checkout (kfilemetadata is **not** in `upstream/`); the following is from the upstream master sources fetched read-only from invent.kde.org and is flagged as such.

- `kfilemetadata/CMakeLists.txt`: `find_package(Xattr)` is `TYPE REQUIRED` **only** under `if(CMAKE_SYSTEM_NAME MATCHES "Linux")`. On macOS it is not required.
- `kfilemetadata/src/xattr_p.h` has a dedicated branch `#elif defined(Q_OS_MAC)` → `#include <sys/xattr.h>`, calling `getxattr`/`setxattr` with the extra macOS `position`/`options` arguments and `removexattr(..., XATTR_NOFOLLOW)`, and prefixing attribute names with `"user."` (same as Linux). `k_isSupported()` probes via `k_getxattr()`. **So `UserMetaData` is a first-class supported platform, and Dolphin's view-properties-in-xattr path should work on APFS.**
- Hard deps: `ECM 6.29`, `Qt6 Xml` (REQUIRED), `KF6CoreAddons`, `KF6I18n`, `KF6Codecs` (REQUIRED). Optional: `Qt6Gui`, `KF6Archive`, `KF6Config`, `Poppler(Qt6)`, `Taglib`, `LibExiv2`, `FFmpeg(AVCODEC)`, `EPub`, `QMobipocket6`, `libappimage`, `CatDoc` (runtime only).

> ⚠️ Version-floor note: kfilemetadata master wants **ECM/KF 6.29**, while Dolphin's floor is 6.23. Homebrew's `extra-cmake-modules` is exactly `6.29.0`, so pin the whole KF6 source build to the 6.29 tag rather than mixing.

#### Homebrew availability on arm64 / macOS 26 (Tahoe)

All checked read-only with `brew info --json=v2`; bottle key checked is `arm64_tahoe`:

| Formula | Version | `arm64_tahoe` bottle | Gates |
|---|---|---|---|
| `exiv2` | 0.28.8 | ✅ | image extractor |
| `taglib` | 2.3.1 | ✅ | audio tags extractor |
| `poppler-qt6` | 26.08.0 | ✅ | PDF extractor |
| `ffmpeg` | 9.0.1 | ✅ | video extractor |
| `ebook-tools` | 0.2.2 | ✅ | EPub extractor |
| `karchive` | 6.29.0 | ✅ | ODF/OOXML extractors |
| `ki18n` | 6.29.0 | ✅ | REQUIRED |
| `qt` / `qtbase` | 6.11.1 | ✅ | — |

Everything is available. **`karchive` and `ki18n` are the only two KF6 formulae in homebrew/core** (`brew search` returns nothing else matching `k(archive|config|coreaddons|io|...)`), and note they declare a dependency on the **`qtbase`** formula, not `qt` — mixing brew's `karchive` with a `qt`-built stack risks two Qt copies. Build KF6 from source and ignore the brew KF6 formulae.

**Recommendation:** build kfilemetadata with every extractor disabled —
`-DCMAKE_DISABLE_FIND_PACKAGE_{Poppler,Taglib,LibExiv2,FFmpeg,EPub,QMobipocket6,libappimage,CatDoc}=ON`.
Dolphin loses **nothing**, because extractors are consumed by Baloo's indexer and by `Baloo::FileMetaDataWidget` — both of which are off. This turns a 6-package dependency chain into `Qt6 Xml + KCoreAddons + KI18n + KCodecs`. **Do not stub kfilemetadata**: `UserMetaData` is load-bearing for `ViewProperties` persistence and a stub would silently change where view settings live.

---

### 2. `HAVE_BALOO` — full trace

Flag defined at `src/config-dolphin.h.cmake:2` (`#cmakedefine01 HAVE_BALOO`), set at `CMakeLists.txt:140-150` only when **both** `KF6Baloo_FOUND AND KF6BalooWidgets_FOUND`.

> **Qt Multimedia coupling (flagged as requested).** `CMakeLists.txt:144-147`:
> ```cmake
> if (KF6Baloo_FOUND AND KF6BalooWidgets_FOUND)
>     set(HAVE_BALOO TRUE)
>     find_package(Qt6 ${QT_MIN_VERSION} CONFIG REQUIRED COMPONENTS
>         Multimedia
>         MultimediaWidgets)
> ```
> and `src/CMakeLists.txt:445-447` links `Qt::Multimedia`/`Qt::MultimediaWidgets` into `dolphinstatic` inside the same `if(HAVE_BALOO)`. The real consumer is `panels/information/mediawidget.cpp` (`QMediaPlayer`, `QAudioOutput`, `QVideoWidget` at `mediawidget.h:15`, `mediawidget.cpp:11-12`) — the audio/video preview player in the Information Panel. So the coupling is *transitive through the Information Panel*, not through Baloo itself. **Consequence for us: turning Baloo off also removes the QtMultimedia dependency entirely.** That is a bonus (QtMultimedia on macOS drags in AVFoundation backends), but it also means that if Phase 3 ever wants an inline media preview panel backed by Spotlight metadata, the `HAVE_BALOO` gate must be split into `HAVE_BALOO` and `HAVE_INFOPANEL`.

Also note `find_package(KF6BalooWidgets ${RELEASE_SERVICE_VERSION})` (`CMakeLists.txt:134`) requires baloo-widgets **26.11.70** — i.e. master. Another reason not to try.

#### 2a. Sources compiled *only* when `HAVE_BALOO` (CMake-level, no `#if` in the files)

| File(s) | CMake gate | Feature lost |
|---|---|---|
| `views/tooltips/dolphinfilemetadatawidget.{cpp,h}`<br>`views/tooltips/tooltipmanager.{cpp,h}` | `src/CMakeLists.txt:192-201` | **All rich hover tooltips in the file view** |
| `kitemviews/private/kbaloorolesprovider.{cpp,h}` | same | metadata role resolution |
| `panels/information/{informationpanel,informationpanelcontent,pixmapviewer,mediawidget}.{cpp,h}`<br>`settings/interface/panelsettingspage.{cpp,h}` | `src/CMakeLists.txt:427-441` | **Information Panel** (F11) + its settings tab + the media player |
| `panels/information/dolphin_informationpanelsettings.kcfgc` | `src/CMakeLists.txt:442-444` | — |

These files hard-include Baloo headers (`informationpanelcontent.cpp:24`, `informationpanel.cpp:19`, `dolphinfilemetadatawidget.cpp:11`, all `<Baloo/FileMetaDataWidget>`), so they genuinely cannot be compiled without BalooWidgets.

#### 2b. Every `#if HAVE_BALOO` in `src/` (tests excluded), verified

| File:line | What it gates | `#else` branch | Verdict |
|---|---|---|---|
| `dolphinmainwindow.h:22` | `#include "panels/information/informationpanel.h"` | none needed | ✅ |
| `dolphinmainwindow.cpp:323-329` | `isInformationPanelEnabled()` | `return false;` | ✅ real stub |
| `dolphinmainwindow.cpp:2368-2382` | InformationPanel creation, `createPanelAction`, `addDockWidget`, 5 signal connects | none | ⚠️ **see BLOCKER `orphan-infodock`** |
| `dolphinmainwindow.cpp:2389-2398` | whatsThis for `show_information_panel` | none | ✅ |
| `dolphinmainwindow.cpp:2592-2594` | adds `show_information_panel` to Panels menu | none | ✅ |
| `views/dolphinview.cpp:32-34` | `#include <Baloo/IndexerConfig>` | — | ✅ |
| `views/dolphinview.cpp:254-257` | `m_toolTipManager = new ToolTipManager(...)` | none; member is `nullptr`-init at `dolphinview.cpp:95` | ✅ |
| `views/dolphinview.cpp:1324-1328` | `Baloo::IndexerConfig::fileIndexingEnabled()` → `indexingEnabled` | `bool indexingEnabled = false;` precedes | ✅ |
| `views/dolphinview.cpp:1477-1483` | `m_toolTipManager->showToolTip(...)` | none | ✅ (guarded) |
| `views/dolphinview.cpp:2086-2090` | `m_toolTipManager->hideToolTip(...)` | `Q_UNUSED(behavior)` | ✅ clean stub |
| `views/dolphinviewactionhandler.cpp:17,456-460` | `IndexerConfig` for role-menu enablement | `indexingEnabled=false` default | ✅ |
| `settings/viewpropertiesdialog.cpp:22,110-114` | ditto | ditto | ✅ |
| `settings/interface/interfacesettingspage.cpp:14,50-55,66-68` | the whole **Panels** settings tab | none | ✅ tab simply absent |
| `settings/viewmodes/generalviewsettingspage.{h:46,cpp:72-76,80-84,200-202,220-222,255-257}` | "Show item information on hover" checkbox | `#else` **re-labels** the group so `m_showSelectionToggle` keeps the "Miscellaneous:" header (`cpp:80-84`) | ✅ genuinely thoughtful |
| `search/dolphinquery.h:20-25` | fwd-decl `Baloo::Query` | — | ✅ |
| `search/dolphinquery.h:47` | `SearchTool::Baloo` enumerator | enum has only `Filenamesearch` | ✅ |
| `search/dolphinquery.h:232` | `initializeFromBalooQuery()` decl | — | ✅ |
| `search/dolphinquery.h:257-261` | default `m_searchTool` from settings | `#else m_searchTool = SearchTool::Filenamesearch;` | ✅ |
| `search/dolphinquery.cpp:10-13,44-51,59-64,148-154,157-159,182-186,190-230,279-285,287-355` | Baloo query parse/emit, `isIndexingEnabledIn()`, `isContentIndexingEnabled()` | both helpers `return false` with `Q_UNUSED` | ✅ clean |
| `search/popup.cpp:109-243` | tool-selection radios + type/date/rating/tags selectors | none — UI just shrinks | ✅ |
| `search/popup.cpp:269-313,315-325` | `updateState()` for those widgets; `#else` keeps `m_searchInFileContentsRadioButton->setText(...)` | ✅ correctly interleaved | ✅ |
| `kitemviews/kfileitemmodelrolesupdater.{h:35,436; cpp:27-31,93-95,118-120,296-315,414-430,820-831,836-,1383-1388}` | `Baloo::File`, `Baloo::FileMonitor`, `KBalooRolesProvider` | `Q_UNUSED(file)` stubs at `cpp:829-830`; member `m_balooFileMonitor` itself `#if`-gated | ✅ clean |

**Corrections to the assignment's list:** `dolphinviewcontainer.cpp` and `kfileitemmodel.cpp` contain **no** `#if HAVE_BALOO`. `dolphinviewcontainer.cpp:641,861` reference `ToolTipManager::HideBehavior` — that resolves because `tooltips/tooltipmanager.h` is included unconditionally from `views/dolphinview.h:14` and the header itself pulls in no Baloo types (`tooltipmanager.h:10-18` only forward-declares `DolphinFileMetaDataWidget`). The header stays on disk; only the `.cpp` is dropped. `kfileitemmodel.cpp` instead carries the Baloo knowledge as *data* (`requiresBaloo`/`requiresIndexer` columns in the static table at `kfileitemmodel.cpp:3139-3190`).

#### 2c. Behaviour with `HAVE_BALOO=0` — two real defects

**(i) `orphan-infodock` (RUNTIME/UX, needs a runtime check).** At `dolphinmainwindow.cpp:2363-2366` the dock is created **outside** the `#if`:
```cpp
DolphinDockWidget *infoDock = new DolphinDockWidget(i18nc("@title:window", "Information"), this);
infoDock->setLocked(lock);
infoDock->setObjectName(QStringLiteral("infoDock"));
infoDock->setAllowedAreas(Qt::LeftDockWidgetArea | Qt::RightDockWidgetArea);
#if HAVE_BALOO
    ... infoDock->setWidget(infoPanel);  addDockWidget(Qt::RightDockWidgetArea, infoDock); ...
#endif
```
and `infoDock->setWhatsThis(...)` at `:2400` is also outside. With Baloo off the `QDockWidget` is parented to the `QMainWindow` but never handed to `addDockWidget()`, so `QMainWindowLayout` never lays it out. Since `setupDockWidgets()` runs before the window is first shown, `showChildren()` should show it at its default geometry (top-left, over the toolbar). I could not build to confirm — treat as **PLAUSIBLE, verify first**. One-line fix: move the four construction lines and the `setWhatsThis` inside the `#if`.

**(ii) `phantom-metadata-columns` (UX, confirmed by reading).** `KFileItemModel::rolesInformation()` (`kfileitemmodel.cpp:1224-1256`) returns **all** roles unconditionally; consumers filter with:
```cpp
// views/dolphinview.cpp:1359  and  settings/viewpropertiesdialog.cpp:124-125
const bool enable = (!info.requiresBaloo && !info.requiresIndexer) || (info.requiresBaloo) || (info.requiresIndexer && indexingEnabled);
```
The middle term `|| (info.requiresBaloo)` is unconditionally true for every Baloo role, and every `requiresIndexer` role also has `requiresBaloo == true` (`kfileitemmodel.cpp:3147-3178`). Result: with `HAVE_BALOO=0` the column header menu and the View Properties dialog still **enable** ~30 columns — Rating, Tags, Comment, Title, Author, Publisher, Page/Word/Line Count, Date Photographed, Dimensions, Width/Height, Orientation, Album, Artist, Audio/Video Codec, Bitrate, Duration, Genre, Release Year, Track, Aspect Ratio, Color Space, Frame Rate, Pixel Format, Downloaded From — every one of which will be permanently blank on macOS. (Only `rating` has a non-Baloo path, via `UserMetaData` at `kfileitemmodel.cpp:2353-2358`, and only for xattrs Dolphin itself wrote.) Fix: add `&& HAVE_BALOO` to the `requiresBaloo` term in both places.

**(iii) upstream oddity worth knowing:** `search/popup.cpp:303-304` reads
```cpp
m_balooRadioButton->setChecked(dolphinQuery->searchTool() == SearchTool::Baloo);
m_balooRadioButton->setChecked(false);
```
— the second line unconditionally unchecks it, which disables the whole selector block below. Looks like a debug leftover in master. Irrelevant for us (Baloo off) but it means the Baloo search path is currently half-broken upstream, so do not use it as a behavioural reference.

**Everything else compiles and behaves sanely.** Net user-visible loss with `HAVE_BALOO=0`: Information Panel (and its settings tab and media player), all hover tooltips + the "Show item information on hover" preference, the tool-selection and type/date/rating/tags UI in the search popup, and all indexed metadata columns.

---

### 3. Search architecture, and what survives on macOS

Everything under `src/search` is compiled **unconditionally** (`src/CMakeLists.txt:315-324, 384-393`) — the whole search UI exists on macOS regardless of Baloo.

#### Backends and how one is chosen

`DolphinQuery` (`search/dolphinquery.{h,cpp}`) is a pure value object: UI state in, **URL** out. There is no backend abstraction beyond a URL scheme.

- Recognised schemes — `dolphinquery.cpp:25-34`: `filenamesearch`, `baloosearch`, `tags`.
- Parsing — `DolphinQuery::DolphinQuery()` `dolphinquery.cpp:128-172`: `filenamesearch:` branch (`:130-146`), `baloosearch:` branch (`:148-154`, `#if HAVE_BALOO`), `tags:` branch (`:156-168`), otherwise treat the URL as the search *path* and call `switchToPreferredSearchTool()`.
- Emission — `DolphinQuery::toUrl()` `dolphinquery.cpp:174-251`: builds a `Baloo::Query` → `query.toSearchUrl()` when `m_searchTool == Baloo` (`:190-230`), else a `filenamesearch:?search=…&checkContent=yes&url=…&title=…` URL (`:232-250`).
- Backend selection — `switchToPreferredSearchTool()` `dolphinquery.cpp:271-285`: if the search location is not Baloo-indexed, **or** content search is wanted while content indexing is off → force `Filenamesearch`; otherwise honour the `SearchSettings::searchTool()` preference. With `HAVE_BALOO=0`, `isIndexingEnabledIn()` (`:38-51`) and `isContentIndexingEnabled()` (`:53-64`) both `return false`, so the first branch always fires: **`m_searchTool` is permanently `Filenamesearch`.**
- Execution — `Bar::slotReturnPressed()` emits `urlChangeRequested(m_searchConfiguration->toUrl())` (`search/bar.cpp:332`); `DolphinViewContainer` forwards it to the URL navigator, and `DolphinView::setUrl()` → `loadDirectory()` → `KFileItemModel` → **`m_dirLister->openUrl(url)`** (`kitemviews/kfileitemmodel.cpp:288, 350`). *Search is just "list a URL".* There is no other seam.
- `tags:/` is additionally used live by `search/selectors/tagsselector.cpp:37` (`m_tagsLister->openUrl(QUrl("tags:/"))`) to populate the tag list. `tags:` is a **Baloo** worker (it is not in kio-extras — `ls upstream/kio-extras` shows no `tags` directory), so it is absent on macOS too.

#### The APPLE exclusion (verified)

`upstream/kio-extras/CMakeLists.txt:213-215`:
```cmake
if (NOT WIN32 AND NOT APPLE AND USE_DBUS)
    add_subdirectory( filenamesearch )
endif()
```

#### So what search does the MVP have? **None — and it fails loudly.**

There is **no** `KProtocolInfo::isKnownProtocol()` guard anywhere in the search path (grep for `isKnownProtocol` in `src/` finds only `admin` at `dolphinviewcontainer.cpp:1016`, `confirmationssettingspage.cpp:97`, `admin/workerintegration.cpp:45`). The search bar therefore builds a `filenamesearch:` URL for a protocol that does not exist, and `DolphinViewContainer::slotUrlNavigatorLocationChanged()` (`dolphinviewcontainer.cpp:888-925`) does:

```
KProtocolManager::supportsListing(url) → findProtocol() == nullptr → false   (kio/src/core/kprotocolmanager.cpp)
KProtocolManager::isSourceProtocol(url) → nullptr → false
→ else branch: showMessage(i18nc("@info:status", "Invalid protocol '%1'", url.scheme()), KMessageWidget::Error);  // dolphinviewcontainer.cpp:922
```

**Phase-1 user experience: type a query, press Enter, get a red "Invalid protocol 'filenamesearch'" banner and bounce back to the previous folder.** Places-panel saved searches (`bar.cpp:341-343` writes search URLs into the Places model) would be equally dead.

#### `filenamesearch` is *nearly* portable — this is the cheap win

Why it is excluded is not a deep portability problem. Reading `kio-extras/filenamesearch/`:

- The only D-Bus in the worker is **two lines** in the constructor (`kio_filenamesearch.cpp:20`, `:85-86`): `QDBusInterface kded("org.kde.kded6", "/kded", "org.kde.kded6"); kded.call("loadModule", "filenamesearchmodule");` — it just asks kded to load the module that keeps saved searches fresh. Delete it (or `#ifndef Q_OS_MACOS` it) and the worker no longer needs a session bus.
- `CMakeLists.txt:9` links `KF6::DBusAddons` — droppable with the above.
- `filenamesearch/kded/` (the `filenamesearchmodule`) is genuinely D-Bus-only; just don't build that subdirectory.
- The content-search fast path shells out to `${DATADIR}/kio_filenamesearch/kio-filenamesearch-grep` via `QProcess` (`kio_filenamesearch.cpp:713-800`); the script is installed `if(NOT WIN32)` and only needs `rg`/`rga` on `PATH`, exiting 127 to trigger the built-in slower fallback. Works on macOS as-is.
- Directory walking is plain Qt + a `contentContainsPattern()` helper (`:240`, `:328`); results are emitted as `UDSEntry` with `UDS_URL` replaced by the real `file://` URL (`:659`) so Dolphin can act on them normally. Protocol metadata is a plain JSON file (`filenamesearch.json`), no D-Bus service file.

**Estimated port cost: ~1 engineer-day, mostly build plumbing.** This is the recommended Phase-1/2 search, independent of Spotlight.

---

### 4. The Spotlight path

#### Design A — `spotlight:/` KIO worker (**recommended**)

A `kio_spotlight` plugin modelled directly on `kio_filenamesearch`:

1. **Protocol metadata** — `spotlight.json`, cloned from `filenamesearch.json`: `"protocol": "spotlight"`, `"Class": ":local"`, `"listing": [Name, Type, Size, Date, AccessDate, Access, Owner, Group, Link]`, `"reading": true`, `"source": false`, `"output": "filesystem"`, `"maxInstances": 10`.
2. **`stat()`** — return a synthetic `inode/directory` UDSEntry carrying `UDS_DISPLAY_NAME` = the `title` query item, exactly as `kio_filenamesearch.cpp:91-124`.
3. **`listDir()`** — parse `QUrlQuery`, build the query, stream results with `listEntry()` as they arrive, setting `UDS_URL` to the real `file://` URL (mirrors `kio_filenamesearch.cpp:659`) so "Open Containing Folder", drag, rename, and the Places panel all keep working.
4. **Query execution — two options, both viable:**
   - **`mdfind` subprocess** (`mdfind -0 -onlyin <dir> '<query>'` via `QProcess`, streamed line-by-line). This copies a code path that already exists and is proven in-tree (`kio_filenamesearch.cpp:713-800`). No Objective-C, no runloop concerns, no entitlement questions. **Start here.**
   - **`NSMetadataQuery`** in a `.mm` translation unit. Richer (live updates via `NSMetadataQueryDidUpdateNotification`, sortable, `valueListAttributes` for free faceting) but requires a CFRunLoop-driven event loop inside the worker process and careful main-thread handling. Worth it only if live-updating results become a goal.
5. **Wiring in Dolphin** — see the seam list below.

**Why this wins:** `KFileItemModel`'s *only* data source is `KDirLister` (`kfileitemmodel.cpp:288-307, 350`), and the entire search flow is "produce a URL, let the view list it" (`bar.cpp:332` → `dolphinviewcontainer` → `dolphinview.cpp:806-829` → `kfileitemmodel.cpp:350`). A URL-scheme backend therefore requires **zero** changes to the model, the view, the sorting/grouping code, the status bar, selection, or the Places panel. Saved searches (`bar.cpp:341-343`) work for free. It is also the same shape as every existing backend, so the code stays upstreamable.

**Its one dependency:** KIO must be able to launch out-of-process workers on macOS (worker plugin discovery + the `kioworker` launcher). That is the KIO auditor's item; if out-of-process workers are broken on macOS, *both* Design A and the `filenamesearch` port die together, and Design B becomes mandatory. **Flagged as an open question, not an assumption.**

#### Design B — native search provider inside Dolphin

Introduce an abstract `SearchProvider` that returns `KFileItemList` and have `KFileItemModel` accept results from it instead of from `KDirLister`. **Rejected:** `KFileItemModel` is welded to `KDirLister` through 11 signal connections and its whole incremental-update contract (`kfileitemmodel.cpp:288-307`); every consumer (`dolphinview`, `dolphinpart`, `kfileitemmodelrolesupdater`) assumes that lifecycle. This is a large, permanent, unupstreamable fork of the model layer to gain nothing the worker does not already give. Keep it in reserve strictly as the fallback if KIO workers cannot run on macOS.

#### Where to plug in — concrete seams

| Seam | File:line | Change |
|---|---|---|
| Backend enum | `search/dolphinquery.h:44-49` | add `Spotlight` under `#if HAVE_SPOTLIGHT` |
| Scheme registry | `search/dolphinquery.cpp:25-34` | add `"spotlight"` to `supportedSchemes` |
| URL → query | `search/dolphinquery.cpp:128-172` | add a `spotlight:` parse branch |
| query → URL | `search/dolphinquery.cpp:174-251` | emit the `spotlight:` URL |
| Backend choice | `search/dolphinquery.cpp:271-285` | prefer `Spotlight` on macOS |
| "Is it indexed?" | `search/dolphinquery.cpp:38-51`, `:53-64` | reimplement over Spotlight index state (e.g. `mdutil -s` on the volume / path-exclusion check) instead of `return false` |
| Tool radios + selectors | `search/popup.cpp:109-243`, `:269-325` | widen the `#if HAVE_BALOO` gate to `HAVE_BALOO \|\| HAVE_SPOTLIGHT`; the type/date/tag selectors are already backend-agnostic |
| Chip visibility | `search/bar.cpp:265-276` and `isSearchConfigured()` `bar.cpp:38-44` | replace the hard-coded `searchTool() != SearchTool::Filenamesearch` test with a capability predicate, e.g. `supportsMetadataFilters(tool)` |
| Tag list source | `search/selectors/tagsselector.cpp:37` | replace `tags:/` `KCoreDirLister` with Finder Tags (`mdfind`'s `kMDItemUserTags` value list, or read `com.apple.metadata:_kMDItemUserTags`) |
| "For more advanced searches" | `search/popup.cpp:250-259` | `KFind` does not exist on macOS — hide, or point at Finder |

#### Mapping `dolphinquery.cpp`'s model onto Spotlight predicates

| DolphinQuery field | `mdfind` / `NSPredicate` | Fidelity |
|---|---|---|
| `searchTerm` + `SearchThrough::FileNames` (`:202-204`, Baloo's `filename:"x"`) | `kMDItemFSName LIKE[cd] "*x*"` | ✅ good |
| `searchTerm` + `SearchThrough::FileContents` (`:200-201`) | `kMDItemTextContent LIKE[cd] "*x*"` (Spotlight's bare-word query already covers name+content) | ✅ good — and *far* better than the Linux fallback |
| `searchPath` + `SearchLocations::FromHere` (`:206-208`) | `mdfind -onlyin <path>` / `NSMetadataQuery.searchScopes = @[fileURL]` | ✅ exact |
| `SearchLocations::Everywhere` (`:243-246`) | `NSMetadataQueryLocalComputerScope` (or `…UserHomeScope`) | ⚠️ semantics differ: Spotlight covers only *indexed* volumes and honours Privacy exclusions; Dolphin's `file:///` means literally everything |
| `fileType` (`:194-196`, `KFileMetaData::Type::{Archive,Audio,Video,Image,Document,Spreadsheet,Presentation,Text,Folder}`) | `kMDItemContentTypeTree == "public.audio"` / `"public.movie"` / `"public.image"` / `"public.composite-content"` / `"public.folder"` / `"public.archive"` … | ✅ clean UTI-tree mapping, one static table |
| `modifiedSinceDate` (`:210-212`) | `kMDItemContentModificationDate >= $date` | ✅ exact |
| `requiredTags` (`:218-224`) | `kMDItemUserTags CONTAINS[c] "tag"` — **native Finder Tags** | ✅ excellent; strictly better than Baloo tags on macOS |
| `minimumRating` (`:214-216`) | — | ❌ **no general macOS equivalent.** `kMDItemStarRating` exists only for media-library items. Options: (a) hide the rating chip when the tool is Spotlight (`bar.cpp:270-273` already has that mechanism), or (b) run the Spotlight query then post-filter with `KFileMetaData::UserMetaData::rating()` (which *does* work on macOS per §1) — accurate only for ratings Dolphin itself wrote |
| `m_unrecognizedBalooQueryStrings` (`dolphinquery.h:283-290`, used at `:198`) | — | ❌ Baloo-specific passthrough; drop for Spotlight (keep the field so Baloo URLs opened from a synced config round-trip unharmed) |
| `title` (`:357-445`) | passed as a `title=` query item, echoed by the worker's `stat()` | ✅ |

Other places it does not map: Spotlight's index is volume-scoped and skips non-indexed/network volumes and everything under Privacy exclusions (so "Everywhere" is a *different set*, and this should be surfaced in the popup's help text the way `popup.cpp:290-299` already warns about Baloo's indexed-folders limitation); Spotlight is inherently token/prefix-oriented rather than substring-oriented, so `LIKE[cd] "*x*"` is markedly slower than a bare term query and worth an explicit UI choice; and Spotlight offers no way to express Baloo's arbitrary boolean `AND` search strings (`dolphinquery.cpp:339-340`).

---

### 5. Recommendations

**Phase 1 — build and run the backend on macOS**

1. **Baloo off.** Configure with `-DCMAKE_DISABLE_FIND_PACKAGE_KF6Baloo=ON -DCMAKE_DISABLE_FIND_PACKAGE_KF6BalooWidgets=ON`. This removes Baloo, baloo-widgets, *and* Qt Multimedia/MultimediaWidgets from the dependency graph in one move. Do not attempt to port Baloo — it is a D-Bus daemon plus an inotify-based indexer plus an LMDB store, all of which duplicate Spotlight.
2. **Build kfilemetadata for real; do not stub it.** All extractors disabled (`-DCMAKE_DISABLE_FIND_PACKAGE_{Poppler,Taglib,LibExiv2,FFmpeg,EPub,QMobipocket6,libappimage,CatDoc}=ON`). Remaining deps — `Qt6 Xml`, `KCoreAddons`, `KI18n`, `KCodecs` — are already on the KF6-from-source list. It carries a real `Q_OS_MAC` xattr implementation and is load-bearing for `ViewProperties` persistence (`viewproperties.cpp:641-712`). Pin the KF6 source build to **6.29** to match Homebrew's `extra-cmake-modules 6.29.0`.
3. **Two small patches while Baloo is off:** move the `infoDock` construction inside the `#if HAVE_BALOO` (`dolphinmainwindow.cpp:2363-2366, 2400`), and add `&& HAVE_BALOO` to the `info.requiresBaloo` term in the two column-enable expressions (`dolphinview.cpp:1359`, `viewpropertiesdialog.cpp:124-125`).
4. **Expect no search.** Either accept the "Invalid protocol 'filenamesearch'" banner for Phase 1, or — recommended — spend ~1 day porting `kio_filenamesearch` (drop `kio_filenamesearch.cpp:20,85-86` and `KF6::DBusAddons`, skip `filenamesearch/kded/`). That immediately gives working name **and** content search on macOS with no Spotlight work, and it de-risks Phase 3 by proving KIO worker launching end to end.
5. **Watch the Places panel.** `KFilePlacesModel` decides Baloo is present by reading a config file that will not exist: `kio/src/filewidgets/kfileplacesmodel.cpp:72-78` — `basicSettings.readEntry("Indexing-Enabled", true)` **defaults to `true`**. Consequently `kfileplacesmodel.cpp:417-431` will create `timeline:/today` and `timeline:/yesterday` system bookmarks on first run, and `:926` will keep baloo-scheme entries visible. Ship a `baloofilerc` with `Indexing-Enabled=false` in the bundle's config dir (or patch the default) to avoid two dead Places entries.

**Phase 3 — Spotlight & Finder Tags seam**

Build `kio_spotlight` (Design A) around `mdfind` first, promoting to `NSMetadataQuery` only if live-updating results are wanted. Land the Dolphin-side changes as the ten seam edits tabulated in §4 — all of them are additive alongside the existing `HAVE_BALOO` gates, so the fork stays small and each piece is individually upstreamable. Do Finder Tags in the same pass: `kMDItemUserTags` maps 1:1 onto `DolphinQuery::requiredTags()`, and replacing the `tags:/` lister at `tagsselector.cpp:37` makes Dolphin's existing tag chip UI a native Finder-Tags browser with no new UI work. Ratings are the one field with no macOS home — hide the chip for the Spotlight backend rather than inventing a parallel rating store.

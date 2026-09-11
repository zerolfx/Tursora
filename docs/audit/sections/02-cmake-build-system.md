## CMake / Build-System Audit (Dolphin v26.11.70 → macOS 26, Apple Silicon)

All citations are relative to the local checkout root `upstream/dolphin` unless another repo is named.
Nothing was built or configured; findings come from reading every `CMakeLists.txt`, every `*.cmake`,
`src/config-dolphin.h.cmake`, and the consuming `#if` sites in `src/`, plus targeted probes of the
host toolchain and of ECM/CMake/Qt upstream sources.

**Headline result: there is no CMake *configure* or *link* blocker that stops Dolphin from building on
macOS.** The build system is far more macOS-tolerant than expected — including one fact that inverts the
usual assumption: **Dolphin already produces a `dolphin.app` bundle on macOS today**, because
`KDECMakeSettings` sets `CMAKE_MACOSX_BUNDLE ON` globally. The real problems are (a) that bundle is
*identity-less* and *non-relocatable*, (b) `HAVE_TERMINAL` is wrongly true on Apple, (c) a dozen
install rules deposit Linux desktop-integration junk, and (d) two helper executables become `.app`
directories in places that require plain binaries.

---

### 1. Existing platform gates and what each implies for `APPLE`

There are exactly **eight** platform conditionals in the entire CMake tree. I grepped for
`WIN32|UNIX|APPLE|HAIKU|MACOSX|Darwin|BUNDLE|Info.plist` across all `CMakeLists.txt`/`*.cmake` — this is
the complete list:

| # | File:line | Gate | Effect for `APPLE` | Verdict |
|---|---|---|---|---|
| 1 | `CMakeLists.txt:69` | `if (UNIX AND NOT APPLE AND NOT HAIKU)` → `set(HAVE_X11 TRUE)` | `HAVE_X11` undefined ⇒ `0` on macOS. **Correct.** | OK |
| 2 | `CMakeLists.txt:153` | `if(WIN32) set(HAVE_TERMINAL FALSE) else() set(HAVE_TERMINAL TRUE)` | **APPLE lands in the `else()` ⇒ `HAVE_TERMINAL=1`.** Linux behaviour applied to macOS. | **Wrong** |
| 3 | `CMakeLists.txt:161` | `if(HAVE_FTS_H AND NOT HAIKU)` | APPLE proceeds to `check_function_exists(fts_open)`. Verified correct (§2.6). | OK |
| 4 | `src/CMakeLists.txt:560` | `if(NOT WIN32)` → builds `kcm_dolphinviewmodes`, `kcm_dolphingeneral`, installs `org.kde.dolphin.appdata.xml` | **APPLE takes the Linux branch.** Builds two Plasma System-Settings KCM plugins that nothing on macOS can load, and installs AppStream metadata into `share/metainfo`. | Wrong-but-harmless (dead weight) |
| 5 | `src/CMakeLists.txt:617` | `if(NOT WIN32)` → `add_subdirectory(settings/contextmenu/servicemenuinstaller)` + installs `servicemenu.knsrc` | **APPLE takes the Linux branch.** Builds a helper that shells out to `kdialog` (`src/settings/contextmenu/servicemenuinstaller/servicemenuinstaller.cpp:21-25`) and installs a KNewStuff config for `store.kde.org`. | Wrong-but-harmless |
| 6 | `src/itemactions/CMakeLists.txt:29` | `if(NOT WIN32)` → `setfoldericonitemaction` | **APPLE takes the Linux branch.** Builds the plugin that writes freedesktop `.directory` files — meaningless next to Finder's own folder-icon mechanism. | UX-wrong |
| 7 | `src/tests/CMakeLists.txt:87,99,130` | `if(NOT WIN32)` ×3 | APPLE runs `dolphinmainwindowtest`, the `bash`-based `no_bare_qwait_in_tests` lint, and `dolphin_smoketest`. | OK (see §6) |
| 8 | `appiumtests/CMakeLists.txt:4` | `if(NOT BUILD_TESTING OR NOT CMAKE_SYSTEM_NAME MATCHES "Linux") return()` | **Clean early-out on Darwin.** | OK — no blocker |

There is **zero** `if(APPLE)` in Dolphin's own CMake. Every macOS-specific decision is therefore either
inherited from ECM or accidental.

Source-level gates tell the same story: `src/` contains 40+ `#ifdef Q_OS_WIN` but only **two**
`Q_OS_MACOS` sites outside `main.cpp` — `src/kitemviews/kitemlistcontainer.cpp:190` and
`src/kitemviews/private/kitemlistsmoothscroller.cpp:218` (scroll-direction tweaks) — plus
`src/dolphinmainwindow.cpp:152` (`KColorSchemeManager` for Win/macOS) and `src/main.cpp:88`
(`QApplication::setStyle("breeze")` for Win/macOS). Everything else treats macOS as Linux.

---

### 2. `HAVE_*` traced from definition to every consumer

`src/config-dolphin.h.cmake` is 17 lines and emits five `#cmakedefine01` symbols (lines 2–6) plus a
hard-coded `KDE_INSTALL_FULL_DATADIR` (line 8).

#### 2.1 `HAVE_X11` — defined `CMakeLists.txt:69-71`; value on macOS: **0** ✅

| Consumer | Compiled out |
|---|---|
| `src/main.cpp:42-44` | `#include <private/qtx11extras_p.h>` — good, avoids a private-header dependency |
| `src/main.cpp:198-200` | `QX11Info::nextStartupId()` |
| `src/dolphinmainwindow.cpp:100-102` | `#include <KStartupInfo>` |
| `src/dolphinmainwindow.cpp:347-349` | `KStartupInfo::setNewStartupId(...)` |
| `src/CMakeLists.txt:543-545` | `target_link_libraries(dolphin PRIVATE Qt::GuiPrivate)` |

Correct. Note the **inconsistency**: `CMakeLists.txt:65-67` still does
`find_package(Qt6GuiPrivate ${QT_MIN_VERSION} REQUIRED NO_MODULE)` unconditionally for Qt ≥ 6.10 — with
Qt 6.11 that hard-requires the private-headers CMake package even though `HAVE_X11=0` means it is never
linked. If Homebrew's `qtbase` bottle omits `lib/cmake/Qt6GuiPrivate/`, this is a **configure-time
FATAL_ERROR**. This is the single highest-probability configure failure in the file (see Open Questions).

#### 2.2 `HAVE_TERMINAL` — defined `CMakeLists.txt:152-157`; value on macOS: **1** ❌

This is the most consequential mis-gate. Consumers:

| Consumer | What is enabled on macOS |
|---|---|
| `src/dolphinmainwindow.cpp:2443-2506` | Creates the bottom `terminalDock` + `TerminalPanel`, the F4 `show_terminal_panel` action, `Ctrl+Shift+F4` `focus_terminal_panel`, and `switch_terminal_url_sync` |
| `src/settings/interface/confirmationssettingspage.{h:40, cpp:44,66,90,130,171,221}` | "Closing windows with a program running in the Terminal panel" checkbox |
| `src/tests/dolphinmainwindowtest.cpp:910,923,1766` | Terminal-panel test coverage runs |

`src/panels/terminal/terminalpanel.cpp` is compiled **unconditionally** (`src/CMakeLists.txt:314`), not
under the flag. It *will build*: its only exotic include, `kde_terminal_interface.h`
(`terminalpanel.cpp:22`), is installed by **KParts**, already a REQUIRED KF6 component
(`CMakeLists.txt:83`). So this is not a build blocker.

It is a **runtime blocker**: `terminalpanel.cpp:167` does
`KPluginFactory::loadFactory(KPluginMetaData(QStringLiteral("kf6/parts/konsolepart")))`. Konsole is not
being ported, so this always returns null and the F4 panel degrades to a permanent
"konsole part missing" message widget. Additionally `terminalpanel.cpp:43` constructs a `QDBusInterface`
on `QDBusConnection::sessionBus()` for `org.kde.KIOFuse` at *construction time* — with no session bus
that is a dead interface (harmless, but it is executed on every window).

Separately, the `open_terminal` / `open_terminal_here` actions (`src/dolphinmainwindow.cpp:2212-2229`)
are **not** guarded by `HAVE_TERMINAL` at all — only by `KAuthorized::authorize("shell_access")`. They
call `KTerminalLauncherJob` (`src/dolphinmainwindow.cpp:1433`), which in `upstream/kio` only has
`#ifndef Q_OS_WIN` branches (`upstream/kio/src/gui/kterminallauncherjob.cpp:88,113`) — i.e. it will try
to launch a freedesktop terminal `.desktop` service on macOS. Needs an `open -a Terminal` path.

#### 2.3 `HAVE_BALOO` — `CMakeLists.txt:128-150`; value on macOS: **0** (Baloo will not be ported)

This is the *most widely* consumed flag: 60+ `#if` sites. What disappears:

* **CMake**: `views/tooltips/*`, `kitemviews/private/kbaloorolesprovider.*` (`src/CMakeLists.txt:192-201`);
  `panels/information/*` + `settings/interface/panelsettingspage.*` (`src/CMakeLists.txt:427-449`);
  `KF6::Baloo`/`KF6::BalooWidgets` links (244-250); and, importantly, the whole
  `find_package(Qt6 … Multimedia MultimediaWidgets)` requirement (`CMakeLists.txt:144-148`) — one fewer
  Qt module to worry about.
* **Information panel is gone entirely** (`src/dolphinmainwindow.cpp:2368-2382`), including its
  `show_information_panel` action; the Panels menu entry is correctly bracketed at
  `src/dolphinmainwindow.cpp:2592-2594`. I checked `src/dolphinui.rc` — it contains **no** reference to
  `show_information_panel`, so KXmlGui will *not* warn about a dangling action.
* **Search degrades but survives**: `src/search/dolphinquery.h:47-51` drops `SearchTool::Baloo` from the
  enum; `Search::isIndexingEnabledIn()` and `isContentIndexingEnabled()` hard-return `false`
  (`src/search/dolphinquery.cpp:44-49, 59-63`). Search falls back entirely to the `filenamesearch:` KIO
  worker — which lives in **kio-extras**, not KIO, and whose grep helper is looked up via a hard-coded
  install path (see §2.7).
* Tooltips lose metadata; `src/settings/viewmodes/generalviewsettingspage.cpp:72-255` and
  `src/settings/viewpropertiesdialog.cpp:22,111` lose rating/tag columns.
* `src/tests/CMakeLists.txt:68-79,141-151` skip 4 tests.

Note `KF6FileMetaData` is **`TYPE REQUIRED`** (`CMakeLists.txt:120-126`) and combined with
`feature_summary(… FATAL_ON_MISSING_REQUIRED_PACKAGES)` (`CMakeLists.txt:237`) it is a hard configure
dependency independent of Baloo — `src/search/dolphinquery.h:15` includes `<KFileMetaData/Types>`
unconditionally. KFileMetaData must be in the KF6 build set.

#### 2.4 `HAVE_PACKAGEKIT` — `CMakeLists.txt:110-118`; value on macOS: **0** ✅ (graceful)

Consumers degrade *by design*: `src/dolphinpackageinstaller.cpp:12-16,39-63` falls back to
`QDesktopServices::openUrl(m_fallBackInstallationPageUrl)` plus a 3-second polling timer; and
`src/settings/contextmenu/servicemenuinstaller/servicemenuinstaller.cpp:34-39,111-128` falls back to
`QDesktopServices::openUrl`. No build impact. The *fallback* is still wrong for macOS (it opens a Linux
distro package page for `kio-admin`/`filelight`/`kfind`, names hard-coded at `src/CMakeLists.txt:7-9`),
which is a UX issue, not a build one.

#### 2.5 `HAVE_KUSERFEEDBACK` — `CMakeLists.txt:96-104`; value on macOS: **0** unless KUserFeedback is built

Consumers: `src/CMakeLists.txt:451-462` (4 source files), `503-509` (2 links),
`src/main.cpp:17-19,280-283`, `src/settings/dolphinsettingsdialog.cpp:16,85,102`. Purely additive —
just do not build KUserFeedback and this vanishes cleanly. Recommend leaving it off.

#### 2.6 `HAVE_FTS_H` / `HAVE_FTS_OPEN` / `HAVE_LIB_FTS` — `CMakeLists.txt:159-172` — **verified working**

I did not trust this one, so I probed it directly on this machine (SDK
`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`):

* `fts.h` exists and declares `fts_open` with an `__DARWIN_INODE64(fts_open)` asm alias
  (`.../usr/include/fts.h:178`).
* On arm64, `__DARWIN_ONLY_64_BIT_INO_T` is `1` (`.../usr/include/sys/cdefs.h:659`), so the alias
  collapses to the plain symbol, and `libSystem.tbd` exports plain `_fts_open`.
* Compiling `char fts_open(void); int main(){return (int)(long)fts_open;}` — exactly what
  `check_function_exists` does — **links successfully** with `clang -arch arm64`.
* A real call using `fts_open(p, FTS_COMFOLLOW|FTS_PHYSICAL|FTS_XDEV, 0)` + `fts_read` + `fts_close`
  (mirroring `src/kitemviews/private/kdirectorycontentscounterworker.cpp:35-47`) also compiles and links.

⇒ On macOS: `HAVE_FTS_H=1`, `HAVE_FTS_OPEN=1`, `HAVE_LIB_FTS` unset, `FTS_LIB=""`
(`CMakeLists.txt:168-172`), and `src/kitemviews/private/kdirectorycontentscounterworker.cpp` takes the
`#if !defined(Q_OS_WIN) && !defined(Q_OS_HAIKU)` BSD-fts path (line 26). **No change required.**
(Semantic caveat for the runtime auditor, not the build auditor: `FTS_XDEV` on APFS means directory-size
counting stops at firmlink/volume boundaries such as `/System/Volumes/Data`.)

#### 2.7 `KDE_INSTALL_FULL_DATADIR` — `src/config-dolphin.h.cmake:8`

Not a `HAVE_` flag but the same mechanism, and it is a **relocation blocker**: the absolute configure-time
data dir is baked into the binary and used at `src/search/popup.cpp:138` to locate
`kio_filenamesearch/kio-filenamesearch-grep`, and into plugin metadata at `src/dolphinpart.json.in:83`.
Inside a signed, distributable `.app` this must become a bundle-relative lookup.

---

### 3. Install layout on macOS

I fetched the ECM sources to check rather than guess. Ground truth from
`extra-cmake-modules/kde-modules/KDEInstallDirsCommon.cmake`:

* `BUNDLEDIR` is the **only** APPLE-guarded directory:
  `if(APPLE) _define_absolute(BUNDLEDIR "/Applications/KDE" …) endif()`.
* `SYSTEMDUSERUNITDIR`, `DBUSDIR`, `DBUSSERVICEDIR`, `ZSHAUTOCOMPLETEDIR`, `APPDIR`, `ICONDIR`,
  `LOGGINGCATEGORIESDIR` are all defined **unconditionally on every platform**.
* `KDEInstallDirs6.cmake` appends `BUNDLE DESTINATION "${KDE_INSTALL_BUNDLEDIR}"` to
  `KDE_INSTALL_TARGETS_DEFAULT_ARGS` when `APPLE`.

Consequence: nothing *fails*; everything installs into a Linux-shaped `${prefix}/{bin,lib,share}` tree
that macOS's own path resolution will never consult.

| Install rule | File:line | Behaviour on macOS | Severity |
|---|---|---|---|
| systemd user unit | `CMakeLists.txt:222` `ecm_install_configured_files(INPUT plasma-dolphin.service.in DESTINATION ${KDE_INSTALL_SYSTEMDUSERUNITDIR})` | Succeeds. Writes `${prefix}/lib/systemd/user/plasma-dolphin.service` (`plasma-dolphin.service.in:6` hard-codes `@KDE_INSTALL_FULL_BINDIR@/dolphin --daemon`). Pure dead file — the macOS equivalent is a `launchd` plist, and the real "keep running" mechanism is `LSUIElement`/login items. | Harmless-but-wrong |
| D-Bus service file | `CMakeLists.txt:204-220` `ecm_generate_dbus_service_file(NAME org.freedesktop.FileManager1 EXECUTABLE "${KDE_INSTALL_FULL_BINDIR}/dolphin --daemon" …)` | **Does not fail.** I read `ECMGenerateDBusServiceFile.cmake`: the only non-Windows precondition is `IS_ABSOLUTE`, which the path satisfies. Writes `share/dbus-1/services/org.kde.dolphin.FileManager1.service`. Meaningless without a session bus. | Harmless-but-wrong |
| D-Bus interface XML | `src/CMakeLists.txt:547-554` via `cmake/DbusInterfaceMacros.cmake:8-25` | Runs `qt_generate_dbus_interface` (needs `qdbuscpp2xml` from qtbase — present in the Homebrew bottle) and installs XML to `share/dbus-1/interfaces`. Builds fine. | Harmless-but-wrong |
| zsh completion | `CMakeLists.txt:235` → `${KDE_INSTALL_ZSHAUTOCOMPLETEDIR}` = `share/zsh/site-functions` | Installs `_dolphin`. Actually *works* on macOS (zsh is the default shell) if the prefix is on `$fpath`. | Harmless / mildly useful |
| logging categories | `CMakeLists.txt:224-228` → `share/qlogging-categories6/dolphin.categories` | Installs. Only read by `kdebugsettings`. | Harmless |
| `kdoctools_install(po)` | `CMakeLists.txt:231-233` | Guarded by `if(KF6DocTools_FOUND)`; `doc/CMakeLists.txt:9-11` likewise. DocTools is `OPTIONAL_COMPONENTS` (`CMakeLists.txt:106-108`). **Skip building KDocTools** and this whole path disappears — avoids dragging in docbook-xsl/libxslt/meinproc6. | Non-issue if DocTools is omitted |
| `ki18n_install(po)` | `CMakeLists.txt:230` | `po/` exists in the checkout; needs `msgfmt` — present at `/opt/homebrew/bin/msgfmt`. Installs `.mo` into `share/locale`, which `QStandardPaths` on macOS **will not find** (§5). | Works, but ineffective |
| `.desktop` + kglobalaccel symlink | `src/CMakeLists.txt:624`, `626`, `628-630` | Installs `org.kde.dolphin.desktop` into `share/applications` and then `execute_process(… create_symlink …)` into `share/kglobalaccel/`. Succeeds (symlinks work on APFS). Both are pure Plasma integration — the `.desktop` file is replaced on macOS by `Info.plist` `CFBundleDocumentTypes`, and kglobalaccel has no macOS counterpart. | Harmless-but-wrong |
| Servicemenus / KNSRC | `src/CMakeLists.txt:617-620` | Installs `servicemenu.knsrc` into `${KDE_INSTALL_KNSRCDIR}` and builds `servicemenuinstaller` — see §4 for why that target is actively broken on macOS. | Wrong |
| KCM plugins | `src/CMakeLists.txt:560-615` | Builds and installs `kcm_dolphinviewmodes`/`kcm_dolphingeneral` MODULEs into `lib/plugins/dolphin/kcms`. MODULE targets correctly get a `.so` suffix on APPLE (CMake default), so KPluginMetaData could load them — but there is no systemsettings host on macOS. Wasted build time + two extra dylibs to code-sign. | Harmless-but-wrong |
| `${KDE_INSTALL_INCLUDEDIR}` dev headers, `DolphinVcsConfig.cmake`, `install(EXPORT DolphinVcsTargets)` | `CMakeLists.txt:181-200`, `src/CMakeLists.txt:50-55, 258` | Fine. Exports an absolute-path CMake package for VCS plugins nobody will build on macOS. | Harmless |

**Nothing in this table actively fails a `make install`.** The problems are §4.

---

### 4. App bundle — the surprising part

**There IS bundle handling — inherited, not written.** I verified against
`extra-cmake-modules/kde-modules/KDECMakeSettings.cmake`, which Dolphin includes at
`CMakeLists.txt:32`. Inside its `if(NOT KDE_SKIP_BUILD_SETTINGS)` block:

```cmake
# By default, create 'GUI' executables. This can be reverted on a per-target basis
# using ECMMarkNonGuiExecutable
set(CMAKE_WIN32_EXECUTABLE ON)
set(CMAKE_MACOSX_BUNDLE ON)
```

So **every** `add_executable()` in the tree becomes a macOS bundle by default. Dolphin never calls
`ecm_mark_nongui_executable` (grep for `MACOSX|BUNDLE` across all CMake files returns only
`CMakeLists.txt:69`). Four consequences, two good and two bad:

**Good — `dolphin.app` already exists:**
1. `src/CMakeLists.txt:511` `add_executable(dolphin)` ⇒ `build/bin/dolphin.app/Contents/MacOS/dolphin`.
2. `src/CMakeLists.txt:556` `install(TARGETS dolphin ${KDE_INSTALL_TARGETS_DEFAULT_ARGS})` already carries
   `BUNDLE DESTINATION /Applications/KDE`, so `make install` deposits `/Applications/KDE/dolphin.app`.
3. `src/CMakeLists.txt:524-532` `ecm_add_app_icon(dolphin ICONS …)` already handles APPLE: it builds an
   `.iconset`, runs `iconutil` (present at `/usr/bin/iconutil` on this machine), sets
   `MACOSX_BUNDLE_ICON_FILE` in the parent (= `src/`) scope, `target_sources()`es the `.icns`, and sets
   `MACOSX_PACKAGE_LOCATION Resources`.

**Bad — the bundle has no identity.** CMake falls back to `Modules/MacOSXBundleInfo.plist.in`, whose keys
are exactly: `CFBundleDevelopmentRegion, CFBundleExecutable, CFBundleGetInfoString, CFBundleIconFile,
CFBundleIdentifier, CFBundleInfoDictionaryVersion, CFBundleLongVersionString, CFBundleName,
CFBundlePackageType, CFBundleShortVersionString, CFBundleSignature, CFBundleVersion,
CSResourcesFileMapped, NSHumanReadableCopyright`. Dolphin sets **none** of the backing
`MACOSX_BUNDLE_*` variables and the `dolphin` target has no `VERSION` property, so the emitted plist has:

| Key | Emitted value | Why it matters on macOS 26 |
|---|---|---|
| `CFBundleIdentifier` | **empty** | TCC (Full Disk Access / Files-and-Folders), Launch Services registration, `NSUserDefaults` domain, `UNUserNotificationCenter`, `codesign`, and notarization all key off it. An empty bundle id is a **hard blocker for a file manager**, which needs a Files-and-Folders TCC grant to read `~/Documents`, `~/Desktop`, `~/Downloads`. |
| `CFBundleName` | empty | The macOS application menu title falls back to the executable name — the menu bar would read "dolphin", lowercase. |
| `CFBundleShortVersionString` / `CFBundleVersion` | empty | Notarization rejects; "About" and Finder Get-Info show nothing. |
| `CFBundleDocumentTypes`, `LSItemContentTypes`, `LSApplicationCategoryType`, `NSHumanReadableCopyright`, `LSMinimumSystemVersion` | **absent** | Dolphin cannot be registered as a handler for `public.folder`, so "Open With" / default-file-manager is impossible. |

**Bad — non-GUI helpers become `.app` directories.** Because `CMAKE_MACOSX_BUNDLE` is global:

* `src/CMakeLists.txt:650` `dolphin_25.04_update_statusandlocationbarssettings` and
  `src/CMakeLists.txt:662` `dolphin_update_splitviewsettings` become bundles, then
  `install(TARGETS … DESTINATION ${KDE_INSTALL_LIBDIR}/kconf_update_bin)` (lines 656-660, 670-674).
  CMake's generic `DESTINATION` supplies the missing `BUNDLE DESTINATION`, so you get
  `lib/kconf_update_bin/dolphin_update_splitviewsettings.app/` — a **directory** where KConfig's
  `kconf_update` expects an executable file. Config migration silently never runs.
* `src/settings/contextmenu/servicemenuinstaller/CMakeLists.txt:8,19` — `servicemenuinstaller.app`
  installed into `/Applications/KDE` alongside the real app.
* `src/tests/CMakeLists.txt:61-62` `kfileitemmodelbenchmark` becomes a bundle. (The `ecm_add_test`
  targets do **not**: I read `ECMAddTests.cmake` — it calls `ecm_mark_nongui_executable()` whenever `GUI`
  is not passed, which clears `MACOSX_BUNDLE`.)

**Bad — the bundle is non-relocatable.** `KDECMakeSettings.cmake` sets, on APPLE only,
`set(CMAKE_INSTALL_NAME_DIR ${_abs_LIB_INSTALL_DIR})`. So the installed
`dolphin.app/Contents/MacOS/dolphin` links against absolute paths like
`/usr/local/lib/libdolphinprivate.6.dylib` (`src/CMakeLists.txt:257`) and
`libdolphinvcs.6.dylib` (`src/CMakeLists.txt:52`), plus the entire Homebrew Qt and the from-source KF6
tree. Nothing is inside `Contents/Frameworks`. The app cannot be signed, notarized, or moved.

**Icon quality gap.** I read the `elseif (APPLE …)` branch of `ECMAddAppIcon.cmake`. It maps
`foreach(size 16 32 128 256 512)` with `2×` variants and silently drops any other size. Dolphin ships
16/22/32/48/64/128 (`src/icons/`), so the generated `.icns` contains only
`icon_16x16`, `icon_16x16@2x`, `icon_32x32`, `icon_32x32@2x`, `icon_128x128` — the 22 px and 48 px files
are discarded, and there is **no 256/512/1024**. Result: a blurry upscaled Dock, Launchpad, and
Get-Info icon on every Retina display. `src/icons/org.kde.dolphin.svg` exists; render 256/512/1024 PNGs
from it and add them to the `ICONS` list.

**Minimum required to get a shippable `Dolphin.app`:**
1. `set_target_properties(dolphin PROPERTIES OUTPUT_NAME Dolphin MACOSX_BUNDLE_INFO_PLIST <custom>.plist.in VERSION ${RELEASE_SERVICE_VERSION})` and a hand-written `Info.plist.in` with the keys in the table above (`CFBundleIdentifier org.kde.dolphin`, `CFBundleDocumentTypes` for `public.folder`).
2. `ecm_mark_nongui_executable()` on the two `kconf_update_bin` targets, `servicemenuinstaller`, and `kfileitemmodelbenchmark`.
3. Override `KDE_INSTALL_BUNDLEDIR` to `/Applications` (or a staging dir).
4. Add a post-install `macdeployqt`-equivalent step: copy `libdolphinprivate`/`libdolphinvcs`, all KF6 dylibs, Qt frameworks and plugins, and **the KIO worker plugins** into `Contents/Frameworks` / `Contents/PlugIns`, rewrite install names to `@rpath`, and set `BUILD_RPATH`/`INSTALL_RPATH` to `@executable_path/../Frameworks`. `macdeployqt` alone will not find `KIO`'s dlopen-ed workers or KF6's `KPluginMetaData` plugins — those need explicit `install(… DESTINATION …/Contents/PlugIns)` rules.
5. Add 256/512/1024 px icons.

---

### 5. Data-file lookup at runtime inside a bundle

This is the sharpest structural finding and it is **good news for `dolphinui.rc`, bad news for everything else**.

**KXmlGui — already safe.** `src/dolphin.qrc` maps `dolphinui.rc` and `dolphinuiforphones.rc` under the
Qt-resource prefix `/kxmlgui5/dolphin`, and `src/dolphinpart.qrc` maps `dolphinpart.rc` under
`/kxmlgui5/dolphinpart`. `src/dolphinmainwindow.cpp:140` calls `Q_INIT_RESOURCE(dolphin)` (needed because
`dolphin.qrc` is compiled into the *static* `dolphinstatic` library, `src/CMakeLists.txt:356`),
`:147` calls `setComponentName("dolphin", …)`, and `:214` calls
`setupGUI(Save | Create | ToolBar, …)`. KXMLGUIClient's search order tries `:/kxmlgui5/<component>/<file>`
before the filesystem, so **the main UI definition needs no install-tree lookup at all.** Do not break
this.

**Everything else is broken.** I verified against Qt's `qstandardpaths_mac.mm`: the main bundle's
`Contents/Resources` is appended **only** for `AppDataLocation` / `AppLocalDataLocation`, **never** for
`GenericDataLocation`, and `XDG_DATA_DIRS` is **not consulted at all** on macOS. Meanwhile
`GenericDataLocation` returns only `~/Library/Application Support` and `/Library/Application Support`.

Everything KF6 resolves through `GenericDataLocation` therefore silently fails inside a bundle:

| Lookup | Site | Installed to | Found on macOS? |
|---|---|---|---|
| `kfile/bookmarks.xml` | `src/dolphinbookmarkhandler.cpp:21-23` | `share/kfile` | ✗ |
| `kio/servicemenus` | `src/settings/contextmenu/contextmenusettingspage.cpp:273`; `servicemenuinstaller.cpp:54-55` | `share/kio/servicemenus` | ✗ |
| `.desktop` / `KService` lookups (e.g. `TerminalService` at `src/dolphinmainwindow.cpp:2207-2209`) | KService via `share/applications` | `${KDE_INSTALL_APPDIR}` | ✗ |
| icon themes (`QIcon::fromTheme` used ~200× ; `KIconTheme::initTheme()` at `src/main.cpp:70`) | `share/icons` (`src/CMakeLists.txt:534`) | ✗ | |
| `.mo` catalogs (`ki18n_install(po)`, `CMakeLists.txt:230`) | `share/locale` | ✗ | |
| `ui_standards.rc` (KXmlGui's own) | `share/kxmlgui6` | ✗ | |
| `kio_filenamesearch` grep helper | `src/search/popup.cpp:138-139` — falls back to `KDE_INSTALL_FULL_DATADIR` (absolute, `src/config-dolphin.h.cmake:8`) *and* `GenericDataLocation` | ✗ (only the absolute path works, and only pre-relocation) |
| KF6 plugins / KIO workers | `${KDE_INSTALL_PLUGINDIR}` (`src/CMakeLists.txt:280,613-614`) | Needs `QT_PLUGIN_PATH` or `QCoreApplication::addLibraryPath` | ✗ by default |

**Required setup.** There is no env-var escape hatch on macOS (`XDG_DATA_DIRS` is ignored by Qt there), so
the fix must be code, not environment:

* Early in `main()` (before `QApplication`, definitely before `KIconTheme::initTheme()` at
  `src/main.cpp:70`), call `QStandardPaths::setTestModeEnabled(false)` + explicitly
  `QCoreApplication::addLibraryPath(bundle/Contents/PlugIns)` and prepend
  `bundle/Contents/Resources` to KF6's data search. KF6 has no public API to inject a
  `GenericDataLocation` root, so in practice you either (a) patch/ship a KCoreAddons that honours
  `XDG_DATA_DIRS` on macOS, or (b) `setenv("XDG_DATA_DIRS", …)` *and* build KF6 against a Qt that reads it
  — neither works with stock Homebrew Qt.
* The realistic Phase-2 approach, and the one KDE Craft uses, is to install the whole `share/` tree into
  `Contents/Resources/` and set `QT_PLUGIN_PATH` / `XDG_DATA_DIRS` from a launcher stub, accepting that
  some KF6 lookups need patching. **Budget this as real engineering, not packaging.**

---

### 6. Tests + `appiumtests`

* `appiumtests/CMakeLists.txt:4-6` — `if(NOT BUILD_TESTING OR NOT CMAKE_SYSTEM_NAME MATCHES "Linux") return()`.
  **Clean early-out on Darwin. Zero impact on a macOS configure run.** No change needed.
* `src/CMakeLists.txt:676-679` — `if(BUILD_TESTING)` … `add_subdirectory(tests)`. `KDECMakeSettings`
  defaults `BUILD_TESTING` to `ON`, so `src/tests/` **is** configured by default.
* `src/tests/CMakeLists.txt:7` `find_package(Qt6Test CONFIG REQUIRED)` — present in the Homebrew bottle.
* `src/tests/CMakeLists.txt:10,153-160` — `include(FindGem)` and `find_gem(test-unit)` for
  `servicemenutest`. `cmake/FindGem.cmake:14` `configure_file`s `FindGem.cmake.in`; `find_package` is
  `TYPE RECOMMENDED`, **not** required, so a missing gem is only a feature-summary note — **not** a
  configure failure. Note: this machine's Ruby is `/usr/bin/ruby 2.6.10p210` — Apple's deprecated system
  Ruby, slated for removal. If `test-unit` happens to be present, `src/settings/contextmenu/test/test_run.rb`
  would run against Linux-only servicemenu semantics and fail. Recommend `-DCMAKE_DISABLE_FIND_PACKAGE_Gem_test-unit=ON`
  or simply gating the block on `NOT APPLE`.
* `src/tests/CMakeLists.txt:99-127` — the `no_bare_qwait_in_tests` lint runs `bash -c "grep -rn 'qWait(' … | grep -v …"`.
  BSD `grep` supports `-r -n -v`, and `/bin/bash` (3.2) is present. Works.
* `src/tests/CMakeLists.txt:130-133` — `dolphin_smoketest` runs `$<TARGET_FILE:dolphin> --self-test`
  (option defined at `src/main.cpp:148`, honoured at `:286` under `#ifdef BUILD_TESTING`, which
  `src/CMakeLists.txt:677` sets). `$<TARGET_FILE:>` correctly resolves *into* the bundle, so this works —
  but it needs a real GUI session and will hang/fail over SSH or in a headless CI runner.
* `src/tests/CMakeLists.txt:5` overrides `EXECUTABLE_OUTPUT_PATH` — a legacy variable, harmless here.
* Failure risk at runtime (not configure): the `Q_OS_UNIX` branches in `src/tests/testdir.cpp:9,30` and
  `src/tests/viewpropertiestest.cpp:16,304,352,407,708` assume POSIX permissions semantics that APFS
  honours, so those should be fine.

**Verdict: tests do not break a macOS configure run.** For Phase 1 just pass `-DBUILD_TESTING=OFF` to cut
configure time, then re-enable selectively.

---

### 7. C++20 + Apple clang 21

`CMakeLists.txt:18-20` sets `CXX_STANDARD 20`, `EXTENSIONS OFF`, `STANDARD_REQUIRED TRUE`. I grepped
`src/` for every construct that historically trips libc++:

| Construct | Occurrences | Verdict |
|---|---|---|
| `<format>` / `std::format` | **0** | ✅ (this is the usual libc++ landmine — Dolphin avoids it entirely) |
| Coroutines (`co_await`/`co_return`/`co_yield`) | **0** | ✅ |
| `char8_t` / `u8"…"` literals | **0** | ✅ |
| C-style designated initializers (`.field = …`) | **0** | ✅ |
| `operator<=>`, `std::jthread`, `consteval`, `constinit`, `<bit>`, `<barrier>`, `<latch>`, `<semaphore>`, `<syncstream>` | **0** | ✅ |
| `<ranges>` | **1**: `src/selectionmode/bottombarcontentscontainer.cpp:24` + `std::ranges::reverse_view` at `:94` | ✅ available since libc++ 16; fine on Apple clang 21 |
| Concepts (`concept` / `requires` clauses) | **0** (the `requires` grep hits are prose in doc comments: `src/animatedheightwidget.h:46`, `src/admin/workerintegration.h:80`, `src/views/zoomwidgetaction.h:15`) | ✅ |
| Linux-only headers (`sys/vfs.h`, `mntent.h`, `linux/*`, `sys/inotify.h`, `malloc.h`, `sys/prctl.h`) | **0** | ✅ |

**No C++20 or Apple-clang blocker.** `cmake_minimum_required(VERSION 3.16)` (`CMakeLists.txt:5`) is also
safe under Homebrew's CMake 4.4.2: CMake 4 hard-errors only below 3.5 and warns below 3.10.

---

### 8. Required CMake changes

| # | File | Line | Current | Required change | Why |
|---|---|---|---|---|---|
| 1 | `CMakeLists.txt` | 152-157 | `if(WIN32) set(HAVE_TERMINAL FALSE) else() set(HAVE_TERMINAL TRUE)` | `if(WIN32 OR APPLE) … FALSE` | Konsole is not ported; `terminalpanel.cpp:167` can never load `kf6/parts/konsolepart`. Removes a permanently-broken F4 panel, a dead `org.kde.KIOFuse` D-Bus proxy (`terminalpanel.cpp:43`), and a useless settings checkbox. |
| 2 | `src/CMakeLists.txt` | 314, 383 | `panels/terminal/terminalpanel.cpp` / `.h` listed unconditionally | Wrap in `if(HAVE_TERMINAL)` | The file compiles regardless of the flag today; with change #1 it becomes dead code that still links KParts/KXMLGUIFactory. |
| 3 | `src/CMakeLists.txt` | 511 | `add_executable(dolphin)` | Add `set_target_properties(dolphin PROPERTIES OUTPUT_NAME Dolphin VERSION ${RELEASE_SERVICE_VERSION} MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in)` under `if(APPLE)` | CMake's default plist emits an **empty `CFBundleIdentifier`** and empty version strings → TCC, Launch Services, codesign and notarization all fail. Also fixes the lowercase "dolphin" menu-bar title. |
| 4 | *new* `src/Info.plist.in` | — | does not exist | Create with `CFBundleIdentifier org.kde.dolphin`, `CFBundleName Dolphin`, `CFBundleShortVersionString`, `CFBundleVersion`, `CFBundleIconFile`, `CFBundleDocumentTypes` (`public.folder`, `LSHandlerRank Alternate`), `LSApplicationCategoryType public.app-category.utilities`, `NSHumanReadableCopyright`, `LSMinimumSystemVersion` | Prerequisite for #3; without `CFBundleDocumentTypes` Dolphin can never be a folder handler. |
| 5 | `src/CMakeLists.txt` | 650-660 | `add_executable(dolphin_25.04_update_statusandlocationbarssettings …)` + `install(TARGETS … DESTINATION ${KDE_INSTALL_LIBDIR}/kconf_update_bin)` | Add `ecm_mark_nongui_executable(dolphin_25.04_update_statusandlocationbarssettings)` (needs `include(ECMMarkNonGuiExecutable)`) | `CMAKE_MACOSX_BUNDLE ON` (from `KDECMakeSettings`) turns this into a `.app` **directory** in `kconf_update_bin`; `kconf_update` expects a plain executable, so config migration silently never runs. |
| 6 | `src/CMakeLists.txt` | 662-674 | `add_executable(dolphin_update_splitviewsettings …)` + same install | `ecm_mark_nongui_executable(dolphin_update_splitviewsettings)` | Same as #5. |
| 7 | `src/settings/contextmenu/servicemenuinstaller/CMakeLists.txt` | 8, 19 | `add_executable(servicemenuinstaller …)` / `install(TARGETS … ${KDE_INSTALL_TARGETS_DEFAULT_ARGS})` | Either `ecm_mark_nongui_executable(servicemenuinstaller)` **or** (preferred) gate the whole `add_subdirectory` at `src/CMakeLists.txt:618` on `NOT APPLE` | Otherwise a CLI helper installs as `servicemenuinstaller.app` into `/Applications/KDE`. The tool shells out to `kdialog` (`servicemenuinstaller.cpp:21-25`) which does not exist on macOS. |
| 8 | `src/tests/CMakeLists.txt` | 61-62 | `add_executable(kfileitemmodelbenchmark …)` | `ecm_mark_nongui_executable(kfileitemmodelbenchmark)` | Bundle-ifies a console benchmark. |
| 9 | `src/CMakeLists.txt` | 524-532 | `ecm_add_app_icon(dolphin ICONS 128/16/22/32/48/64 …)` | Add 256, 512, 1024 px PNGs rendered from `src/icons/org.kde.dolphin.svg`; the 22 and 48 entries are silently discarded by ECM | `ECMAddAppIcon.cmake`'s APPLE branch only accepts 16/32/128/256/512 (+2×). Without 256/512 the Dock, Launchpad and Get-Info icons are upscaled from 128 px → visibly blurry on every Retina Mac. |
| 10 | `CMakeLists.txt` | 204-220 | `ecm_generate_dbus_service_file(...)` ×2 | Wrap in `if(NOT APPLE)` | Installs `share/dbus-1/services/org.kde.dolphin.FileManager1.service` referencing `dolphin --daemon`; there is no session bus and no bus-activation on macOS. Harmless but pollutes the install tree that must later be copied into `Contents/Resources`. |
| 11 | `CMakeLists.txt` | 222 | `ecm_install_configured_files(INPUT plasma-dolphin.service.in DESTINATION ${KDE_INSTALL_SYSTEMDUSERUNITDIR})` | Wrap in `if(NOT APPLE)` | systemd does not exist on macOS; `KDE_INSTALL_SYSTEMDUSERUNITDIR` is defined unconditionally by ECM so this *silently succeeds* and installs a dead file. |
| 12 | `src/CMakeLists.txt` | 626-630 | `install( DIRECTORY DESTINATION "…/kglobalaccel")` + `install(CODE … create_symlink …)` | Wrap in `if(NOT APPLE)` | kglobalaccel is Plasma-only; the symlink target `share/applications/org.kde.dolphin.desktop` is itself meaningless on macOS. |
| 13 | `src/CMakeLists.txt` | 624 | `install( PROGRAMS org.kde.dolphin.desktop DESTINATION ${KDE_INSTALL_APPDIR} )` | Wrap in `if(NOT APPLE)`; replace by `Info.plist` `CFBundleDocumentTypes` | `.desktop` files are not read by macOS; `QStandardPaths::GenericDataLocation` cannot see `share/applications` inside a bundle anyway (§5). |
| 14 | `src/CMakeLists.txt` | 560-615 | `if(NOT WIN32)` around the two KCM MODULEs + appdata | Change to `if(NOT WIN32 AND NOT APPLE)` | No systemsettings host on macOS. Removes 2 dylibs from the code-signing set and drops the only hard use of `KF6::KCMUtils` in a plugin context. |
| 15 | `src/CMakeLists.txt` | 617-620 | `if(NOT WIN32)` around servicemenuinstaller + `servicemenu.knsrc` | Change to `if(NOT WIN32 AND NOT APPLE)` | See #7; also removes the `${KDE_INSTALL_KNSRCDIR}` install. |
| 16 | `src/itemactions/CMakeLists.txt` | 29-40 | `if(NOT WIN32)` around `setfoldericonitemaction` | Change to `if(NOT WIN32 AND NOT APPLE)` | Writes freedesktop `.directory` files that Finder ignores; conflicts conceptually with macOS's own custom-icon mechanism. |
| 17 | `CMakeLists.txt` | 73-95 | `KCMUtils` and `NewStuff` in the REQUIRED `find_package(KF6 …)` component list | Move behind `if(NOT APPLE)` once #14/#15 land; `KCMUtils` is still needed for `src/settings/trash/trashsettingspage.cpp:9-18` (`KCModuleLoader::loadModule("kcm_trash")`), so that page must be replaced first | `KNewStuff` is used in **exactly one place** (`src/settings/contextmenu/contextmenusettingspage.cpp:24,67`) yet drags QtDeclarative/QtQuick, KPackage, Attica and Syndication into the from-source KF6 build. Dropping it is the single largest reduction in Phase-1 KF6 build surface. |
| 18 | `CMakeLists.txt` | 65-67 | `find_package(Qt6GuiPrivate ${QT_MIN_VERSION} REQUIRED NO_MODULE)` for Qt ≥ 6.10 | Guard with `if(HAVE_X11)` | It is only consumed by `target_link_libraries(dolphin PRIVATE Qt::GuiPrivate)` at `src/CMakeLists.txt:543-545`, which is itself `if (HAVE_X11)`. As written it is a *hard* configure requirement on Qt private-header CMake packages for zero benefit on macOS. Highest-probability configure failure in the tree. |
| 19 | `src/config-dolphin.h.cmake` | 8 | `#define KDE_INSTALL_FULL_DATADIR "${KDE_INSTALL_FULL_DATADIR}"` | On APPLE resolve at runtime from `QCoreApplication::applicationDirPath() + "/../Resources"` | Baking the configure-time absolute prefix into the binary (consumed at `src/search/popup.cpp:138`) makes the `.app` non-relocatable and breaks the moment it is dragged to `/Applications`. |
| 20 | `src/CMakeLists.txt` | 52, 257 | `install(TARGETS dolphinvcs/dolphinprivate ${KDE_INSTALL_TARGETS_DEFAULT_ARGS})` → `${prefix}/lib` with `CMAKE_INSTALL_NAME_DIR` = absolute libdir | Add an APPLE branch installing into `<bundle>/Contents/Frameworks` with `INSTALL_RPATH "@executable_path/../Frameworks"` and `INSTALL_NAME_DIR "@rpath"` | Otherwise the installed app hard-links absolute Homebrew/KF6 paths and cannot be signed, notarized or distributed. |
| 21 | *new*, after `src/CMakeLists.txt:556` | — | no dependency-bundling step exists | Add a `macdeployqt`-equivalent install step that also copies KF6 dylibs, **KIO worker plugins**, KF6 `KPluginMetaData` plugins and Qt plugins into `Contents/Frameworks` / `Contents/PlugIns` | `macdeployqt` only follows link-time dependencies; KIO workers and KF6 plugins are `dlopen`-ed via `KPluginMetaData` and will be missed. |
| 22 | `src/tests/CMakeLists.txt` | 153-160 | `find_gem(test-unit)` + `servicemenutest` | Wrap in `if(NOT APPLE)` | Depends on Apple's deprecated system Ruby (`/usr/bin/ruby 2.6.10`) and tests Linux-only servicemenu install semantics. |
| 23 | `CMakeLists.txt` | 230 | `ki18n_install(po)` | Keep, but ensure the resulting `share/locale` is copied into `Contents/Resources` and made visible to `KLocalizedString` | Installs fine (`msgfmt` present) but `QStandardPaths::GenericDataLocation` on macOS never sees `${prefix}/share` — translations would silently not load. |

Changes **1–8 and 18** are the Phase-1 set (get a correct, non-broken build). **3, 4, 9, 19–21** are the
Phase-2 bundle set. **10–17, 22–23** are cleanup that can be batched.

---

### 9. Things that are *fine* and should not be "fixed"

* `appiumtests/` — already returns early on non-Linux (`appiumtests/CMakeLists.txt:4`).
* The `fts` probe (`CMakeLists.txt:159-172`) — empirically verified to work on arm64 macOS 26.
* `ecm_generate_dbus_service_file` — does not fail its `IS_ABSOLUTE` precondition (verified against ECM source).
* `dolphinui.rc` loading — served from Qt resources (`src/dolphin.qrc`, `Q_INIT_RESOURCE` at `src/dolphinmainwindow.cpp:140`), immune to the bundle path problem.
* `HAVE_X11` (`CMakeLists.txt:69`) and all four of its consumer sites — already correct for APPLE.
* `HAVE_PACKAGEKIT=0` and `HAVE_KUSERFEEDBACK=0` degrade cleanly with real `#else` fallbacks.
* MODULE targets (`dolphinpart`, the KCMs, `kcoreaddons_add_plugin` item actions) get the correct `.so` suffix on APPLE by CMake default — no plugin-suffix work needed.

---

### 10. Host-toolchain reality check (this machine, 2026-08-19)

| Item | State |
|---|---|
| `extra-cmake-modules` | Homebrew formula 6.29.0 available, **not installed** |
| `qt` | Homebrew formula 6.11.1 available, **not installed** |
| `cmake` | Homebrew formula 4.4.2 available, **not installed** (`cmake` not on PATH) |
| `ninja`, `pkg-config` | **not installed** |
| KF6 | `brew search kf6` → no matches. Confirms: **every KF6 framework must be built from source.** |
| `iconutil` | `/usr/bin/iconutil` ✅ (required by `ecm_add_app_icon`) |
| `msgfmt` | `/opt/homebrew/bin/msgfmt` ✅ (required by `ki18n_install`) |
| `ruby` | `/usr/bin/ruby 2.6.10p210` — Apple's deprecated system Ruby |
| SDK | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` (Command Line Tools only — **no full Xcode**, which will matter for codesigning/notarization in Phase 3+) |

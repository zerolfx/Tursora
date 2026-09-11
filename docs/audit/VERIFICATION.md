# Appendix — Adversarial verification of blocker claims

All 61 blocker/major claims from the ten parallel audits were re-checked by an independent agent
instructed to **refute** them, then a subset was re-checked again by the author after cloning the
repositories the verifier could not reach. Verdicts below.

## Summary

| | count |
|---|---|
| claims examined | 61 |
| upheld | 45 |
| refuted or unprovable as stated | 16 |
| **corrected severity: blocker** | 4 |
| corrected severity: major | 25 |
| corrected severity: minor | 23 |
| corrected severity: info | 9 |

The original audits reported **14 blockers**. After verification, **4** survive at blocker
severity. That is the single most useful number in this appendix: the raw audit output was
roughly 3.5× too alarmist at the top of the severity scale.

## Verifier's own caveat, which the author endorses

> Twelve claims rest on repositories that were not checked out at verification time (solid,
> extra-cmake-modules, kcoreaddons, qtbase). They were marked refuted because no cited file could
> be opened — **that is "unproven", not "disproven"**.

The author subsequently cloned `solid`, `extra-cmake-modules` and `kcoreaddons` and re-checked the
most decision-relevant of those twelve; results are in the *Author re-verification* section below.
The qtbase-dependent claims (responder chain, `NSApp.mainMenu` ownership, `processEvents` pump,
popup positioning) **remain unverified** because Qt is not installed on this machine. They are the
highest-value target for the Phase-2 spikes in §9 R1/R4.

## Author re-verification (first-hand, after cloning the missing repos)

| Claim | Verdict | Evidence read |
|---|---|---|
| `iokit-teardown-noop` | ✔ **UPHELD** | `solid:src/solid/devices/backends/iokit/iokitstorageaccess.cpp` — `bool IOKitStorageAccess::setup() { // TODO?  return false; }` and an identical `teardown()`. Verbatim. |
| `iokit-no-hotplug` | ✔ **UPHELD** | `grep -c IOServiceAddMatchingNotification` over **all 14** `.cpp` files in `solid/src/solid/devices/backends/iokit/` returns **0**. No hot-plug notification is ever registered. |
| `nongui-helpers-become-app-bundles` | ✔ **UPHELD** | `extra-cmake-modules/kde-modules/KDECMakeSettings.cmake:245` — `set(CMAKE_MACOSX_BUNDLE ON)`. |
| `non-relocatable-install-names` | ✔ **UPHELD** | `extra-cmake-modules/kde-modules/KDECMakeSettings.cmake:152` — `set(CMAKE_INSTALL_NAME_DIR ${_abs_LIB_INSTALL_DIR})`. |
| `kdirwatch-no-macos-backend` | ✎ **CORRECTED — claim is wrong** | `kcoreaddons/src/lib/io/kdirwatch.cpp:96-112`: with no `HAVE_SYS_INOTIFY_H`, `methodFromString("default")` returns **`KDirWatch::QFSWatch`**, not `Stat`. Qt implements `QFileSystemWatcher` on macOS with FSEvents. KDirWatch does **not** stat-poll on macOS. The real (smaller) issue is the semantic gap the code itself documents at `:104` — *"inotify supports delete+recreate+modify, which QFSWatch doesn't support"* — plus one watch per counted subdirectory. Severity major → minor. |
| `q-os-osx-macro-fragility` | ✎ **CORRECTED** | Qt 6.11 `qsystemdetection.h:172` still **defines** `Q_OS_OSX` inside `#ifdef Q_OS_MACOS`, with `#pragma clang deprecated`. The trash path does not compile out. Severity major → minor (deprecation warnings + future-removal risk). |

## Notable outright refutations

| Claim | Why it failed |
|---|---|
| `kiofuse-blocking-call-gui-thread` | The entire KIOFuse block sits inside `#ifdef WITH_QTDBUS` spanning `kio:src/core/desktopexecparser.cpp:398-464`, so it is **not compiled on macOS at all**. The claimed mechanism was also wrong, and `waitForFinished` is at `:436`, not in the cited range. |
| `kio-auth-infinite-loop-no-dbus` | `kio-extras:sftp/kio_sftp.cpp:976` is indeed `for (;;)`, but it **exits at `:1013-1015` on `SSH_AUTH_ERROR`**, which a real sshd produces after `MaxAuthTries`. The underlying empty-credentials bug is real and survives as `no-dbus-password-dialog-returns-success`; the dramatic "unbounded CPU-burning hang" framing does not. |
| `kio-extras-smb-mtp-dead-on-macos` | **Fabricated citation.** `kio-extras/CMakeLists.txt:107-111` is the `BUILD_DOC` / `find_package(KF6DocTools)` block, not `USE_DBUS_DEFAULT` (which is at `:57-60`). The auditor appears to have transposed KIO's line numbers onto kio-extras. The *conclusion* is still correct via the real gates at `:230` and `:217`. |

## Full verdict table

| id | verdict | corrected severity | note |
|---|---|---|---|
| `no-search-in-mvp` | ✔ upheld | blocker | Survives. kio-extras/CMakeLists.txt:213-215 is exactly `if (NOT WIN32 AND NOT APPLE AND USE_DBUS) add_subdirectory( filenamesearch )` — APPLE is excluded regardless of USE_DBUS. dolphin/src/search/dolphinquery.cpp:233 unconditiona |
| `kf6-absent-from-homebrew` | ✔ upheld | blocker | Survives. dolphin/CMakeLists.txt:73-93 lists exactly 20 REQUIRED KF6 components (KCMUtils, NewStuff, CoreAddons, I18n, DBusAddons, Bookmarks, Config, KIO, Parts, Solid, IconThemes, Completion, TextWidgets, Notifications, Crash, Wi |
| `no-dbus-password-dialog-returns-success` | ✔ upheld | blocker | Survives verbatim. kio/src/core/slavebase.cpp:907 defines openPasswordDialogV2; the `#ifdef WITH_QTDBUS` at :925 has `#else return KJob::NoError; #endif` at :931-933 — `info` is never assigned (only the local `dlgInfo` is built).  |
| `kio-trash-not-macos-trash` | ✔ upheld | blocker | Survives, citations near-exact. kio/src/kioworkers/trash/trashimpl.cpp:173 `QString trashDir = QDir::homePath() + QLatin1String("/.Trash");` and :178 `trashDir += QLatin1String("/KDE.trash");` inside the `#else` of `#ifndef Q_OS_O |
| `kdbusaddons-hard-required-by-dolphin` | ✔ upheld | major | Facts survive, severity inflated. DBusAddons is at dolphin/CMakeLists.txt:78 (not :79) inside the REQUIRED block opened at :73; Qt6 DBus at :62 confirmed. main.cpp:24 `#include <KDBusService>`, KDBusService constructed at :184, :1 |
| `kio-auth-infinite-loop-no-dbus` | ✗ refuted | major | Same root cause as no-dbus-password-dialog-returns-success; the distinctive 'infinite CPU-burning loop' framing does not survive. kio-extras/sftp/kio_sftp.cpp:976 is indeed `for (;;)`, :988 `int errCode = openPasswordDialog(info,  |
| `iokit-teardown-noop` | ✗ refuted | major | UNVERIFIABLE HERE, not disproven. The solid repository is not among the local checkouts — `find` over the workspace returns only docs/audit/sections/04-solid-devices.md and upstream/craft-blueprints/kde/frameworks/tier1/solid/soli |
| `iokit-no-hotplug` | ✗ refuted | major | UNVERIFIABLE HERE, not disproven — solid is not checked out (see iokit-teardown-noop). iokitmanager.cpp:99-111 and the grep for IOServiceAddMatchingNotification could not be reproduced. The KIO consumer half is exact: kio/src/file |
| `empty-bundle-identity` | ✔ upheld | major | Substance survives but one cited fact is wrong. `grep -rn MACOSX` over the entire dolphin checkout returns ZERO hits — not 'only CMakeLists.txt:69' as claimed; line 69 is `if (UNIX AND NOT APPLE AND NOT HAIKU)`. There is also no I |
| `genericdatalocation-invisible-in-bundle` | ✔ upheld | major | Dolphin call sites exact; the Qt premise is asserted, not read. dolphinbookmarkhandler.cpp:21 is verbatim `QString bookmarksFile = QStandardPaths::locate(QStandardPaths::GenericDataLocation, QStringLiteral("kfile/bookmarks.xml")); |
| `non-relocatable-install-names` | ✗ refuted | major | Citations do not say what the claim says. extra-cmake-modules is not on this machine (`find / -name KDECMakeSettings.cmake` returns nothing), so `set(CMAKE_INSTALL_NAME_DIR ...)` is unverified. The three dolphin citations are real |
| `split-responder-chain-menu-validation` | ✗ refuted | major | UNVERIFIABLE HERE. Every citation is to qtbase (qcocoamenuitem.mm, qnsview_menus.mm) and qtbase is not on this machine: `brew list` contains no qt, and `find / -name qsystemdetection.h` and a workspace-wide search for *qcocoa* bot |
| `phantom-metadata-columns` | ✔ upheld | major | Survives, citations exact. kfileitemmodel.cpp:1224-1255 rolesInformation() walks the whole rolesInfoMap with no HAVE_BALOO filter. The static table at :3142+ marks rating/tags/comment requiresBaloo=true and every Document/Image/Au |
| `kio-extras-smb-mtp-dead-on-macos` | ✗ refuted | major | Duplicate with a fabricated citation. 'kio-extras/CMakeLists.txt:107-111 (USE_DBUS_DEFAULT OFF when APPLE)' is wrong — :105-111 is the BUILD_DOC / find_package(KF6DocTools) block; USE_DBUS_DEFAULT is at :56-61. That line range was |
| `no-macos-ci-anywhere` | ✔ upheld | major | Survives; minor line drift. dolphin/.kde-ci.yml:5 does list 'macOS/Qt6', and the third dependency block also requires network/kio-extras on macOS/Qt6, while Options `require-passing-tests-on: ['Linux/Qt6','FreeBSD/Qt6']`. dolphin/ |
| `baloo-tier3-features-lost` | ✔ upheld | major | Survives with exact citations, but duplicates baloo-absent-kills-panel-and-tooltips. dolphin/.kde-ci.yml:30-34 is exactly the ['Linux/Qt6','Linux/Qt6Next','FreeBSD/Qt6'] block requiring frameworks/baloo, libraries/baloo-widgets, t |
| `dbus-single-instance-and-adaptor` | ✔ upheld | major | Exact, overlaps dolphin-unconditional-dbus-dep. src/CMakeLists.txt:477-480, :221 (`Qt6::DBus` in dolphinprivate's PUBLIC list), :549 generate_and_install_dbus_interface — all verbatim. global.cpp:60 `bool Dolphin::attachToExisting |
| `ssl-exception-storage-noop` | ✔ upheld | major | Survives verbatim. ksslcertificatemanager.cpp:401-405 setRule, :408-412 clearRule, :414-419 clearRule overload, :422-429 rule() with `#else return KSslCertificateRule(); #endif` — all pure `#ifdef WITH_QTDBUS`. kssld is dropped at |
| `trash-not-native-macos` | ✔ upheld | major | Duplicate of kio-trash-not-macos-trash but the most precisely cited version of the two. trashimpl.cpp:159 `#ifndef Q_OS_OSX`, :173 `QDir::homePath() + "/.Trash"`, :178 `+= "/KDE.trash"`. The lazy-createTrashInfrastructure `#ifdef  |
| `kdirnotify-no-remote-dir-refresh` | ✔ upheld | major | Survives, citations exact. kcoredirlister.cpp:71-77 wraps every KDirNotify connect in `#ifdef WITH_QTDBUS`; core/CMakeLists.txt:94-103 is verbatim `if (HAVE_QTDBUS) target_sources(KF6KIOCore PRIVATE kpasswdserverloop.cpp kpasswdse |
| `no-job-progress-tracker` | ✔ upheld | major | Survives verbatim — one of the strongest claims in the set. kio/src/widgets/CMakeLists.txt:65-70 is exactly `if (HAVE_QTDBUS) target_sources(KF6KIOWidgets PRIVATE kdynamicjobtracker.cpp ${kiowidgets_dbus_SRCS}) endif()`. kio/src/c |
| `dolphin-unconditional-dbus-dep` | ✔ upheld | major | Survives, citations exact. dolphin/CMakeLists.txt:57-63 find_package(Qt6 … DBus), :72-78 find_package(KF6 … DBusAddons) — DBusAddons on :78. src/CMakeLists.txt:221 `Qt6::DBus` in dolphinprivate's PUBLIC list, :491 `KF6::DBusAddons |
| `session-restore-dead-without-bus` | ✔ upheld | major | Survives with unusually exact line numbers. main.cpp:234 `KDBusService dolphinDBusService(serviceOptions);` (with the NoExitOnFailure guard at :231-233 already handling a missing bus), :247 `if (app.isSessionRestored() \|\| Genera |
| `smb-mtp-dropped-without-dbus` | ✔ upheld | major | Survives with exact line numbers — this is the correctly-cited version of the smb/mtp finding. kio-extras/CMakeLists.txt:56-61 is verbatim `set(USE_DBUS_DEFAULT OFF)` / `if(UNIX AND NOT APPLE AND NOT ANDROID AND NOT HAIKU) set(USE |
| `baloo-absent-kills-panel-and-tooltips` | ✔ upheld | major | Survives. CMakeLists.txt:127-150 (KF6Baloo/KF6BalooWidgets OPTIONAL; HAVE_BALOO TRUE only at :142 when both found). dolphinmainwindow.cpp:2368-2382 and :2388-2399 guard InformationPanel and its whatsThis (claim said 2367/2400 — on |
| `qt-owns-nsapp-mainmenu` | ✗ refuted | major | UNVERIFIABLE HERE. The decisive citation — QCocoaMenuBar::updateMenuBarImmediately() reassigning NSApp.mainMenu — is in qtbase, which is not present on this machine (no qt in `brew list`, no qcocoamenubar.mm anywhere). The dolphin |
| `appdelegate-ordering` | ✗ refuted | major | UNVERIFIABLE HERE — qcocoaintegration.mm and qcocoaapplicationdelegate.mm are in qtbase, which is not on this machine. The reflectionDelegate mechanism and the AA_PluginApplication branch are quoted from memory with '≈' line numbe |
| `processevents-pump-model-broken` | ✗ refuted | major | UNVERIFIABLE HERE — qcocoaeventdispatcher.mm is in qtbase, absent from this machine. The `processEventsCalled && !(flags & EventLoopExec)` early-return is quoted with '≈602-606' and could not be opened. If true it kills integratio |
| `uf-hidden-not-honoured` | ✔ upheld | major | Survives with every citation exact — one of the cleanest claims here. kio/src/core/kfileitem.cpp:1386 `bool KFileItem::isHidden() const`, with the UDS override at :1393-1395 and the dotfile rule at :1407 `d->m_hiddenCache = fileNa |
| `delete-key-inversion` | ✔ upheld | minor | Dolphin half exact, severity inflated. dolphinmainwindow.cpp:2119-2121 is verbatim `// Prepend this shortcut, to avoid being hidden by the two-slot UI (#371130)` / `backShortcuts.prepend(QKeySequence(Qt::Key_Backspace));` / `actio |
| `space-quicklook-conflict` | ✔ upheld | minor | Citations exact, severity badly inflated. dolphinmainwindow.cpp:1993 is verbatim `actionCollection()->setDefaultShortcut(toggleSelectionModeAction, Qt::Key_Space);`. kitemlistcontroller.cpp:456 `case Qt::Key_Space:` with toggle/ex |
| `orphan-infodock` | ✔ upheld | minor | Citations exact, severity slightly inflated. dolphinmainwindow.cpp:2363 `DolphinDockWidget *infoDock = new DolphinDockWidget(i18nc("@title:window", "Information"), this);` sits above the guard; `#if HAVE_BALOO` opens at :2368, set |
| `kcmutils-knewstuff-pull-qtquick-stack` | ✗ refuted | minor | Duplicate, and the load-bearing half is admittedly unread. Consumers verified exactly: dolphin/CMakeLists.txt:74-75 (KCMUtils, NewStuff), src/CMakeLists.txt:232 `KF6::NewStuffWidgets    # KNSWidgets::Button` and :237 `KF6::KCMUtil |
| `qt6guiprivate-required` | ✔ upheld | minor | Citations exact; the risk is speculative. dolphin/CMakeLists.txt:65-67 is verbatim `if (Qt6Gui_VERSION VERSION_GREATER_EQUAL "6.10.0") find_package(Qt6GuiPrivate ${QT_MIN_VERSION} REQUIRED NO_MODULE) endif()`, and kio/CMakeLists.t |
| `kmountpoint-no-cache-on-darwin` | ✔ upheld | minor | Citations correct, impact unproven. kmountpoint.cpp:730-741 is exactly `currentMountPointForPath` with the statx fast path inside `#if HAVE_STATX_MNT_ID_UNIQUE` and `return currentMountPoints().findByPath(path);` as the only non-g |
| `dirlister-insert-quadratic` | ✔ upheld | minor | Citations exact but the finding is not macOS-specific and the magnitude is overstated. kcoredirlister_p.h:493-504 is verbatim insertSortedItems with `lstItems.reserve(...)`, `auto it = lstItems.begin();` and a per-item `it = std:: |
| `case-insensitive-fs-url-cache` | ✔ upheld | minor | Citations essentially correct, consequence narrow. kmountpoint.cpp:28-33 is verbatim `#ifdef Q_OS_WIN … cs = Qt::CaseInsensitive #else … cs = Qt::CaseSensitive #endif`, used at :591 in findByDevice; the prefix match `realPath.star |
| `return-opens-vs-renames` | ✔ upheld | minor | Facts correct, severity inflated. kitemlistcontroller.cpp:433-444 is verbatim `case Qt::Key_Enter: case Qt::Key_Return: { … Q_EMIT itemsActivated(selectedItems); … Q_EMIT itemActivated(...) }`. The rename action is `KStandardActio |
| `fkey-block-system-claimed` | ✔ upheld | minor | Every line number is exact — the best-cited UX claim in the set — but it is still a rebinding decision. Verified by grep: dolphinmainwindow.cpp:1925 Ctrl+F3, :1937 Ctrl+I (plus Qt::Key_Slash), :2044 F3, :2054 Shift+F3, :2058 Ctrl+ |
| `cmd-h-cmd-m-cmd-i-collisions` | ✔ upheld | minor | Citations check out; two of the four shortcuts are not actually set by Dolphin. dolphinviewactionhandler.cpp:390 is verbatim `m_actionCollection->setDefaultShortcuts(showHiddenFiles, KStandardShortcut::showHideHiddenFiles());` and |
| `remote-drag-needs-file-promises` | ✔ upheld | minor | Citations exact; it is a feature to implement, not a defect to fix. kfileitemmodel.cpp:559-562 collects `urls << item.url();` and `mostLocalUrls << item.mostLocalUrl(&isLocal);`, then :566 `KUrlMimeData::setUrls(urls, mostLocalUrl |
| `menubar-hidden-and-no-menu-roles` | ✔ upheld | minor | Both halves verified exactly, but it duplicates dolphin-hides-menubar-by-default and is a port-design item. dolphinmainwindow.cpp:214 `setupGUI(Save \| Create \| ToolBar, ...)`, :224 `menuBar()->setVisible(false);` inside `if (fir |
| `solid-macos-not-in-ci` | ✗ refuted | minor | UNVERIFIABLE HERE. solid is not checked out (workspace search finds only craft-blueprints/kde/frameworks/tier1/solid/solid.py), so solid/.kde-ci.yml, solid/.gitlab-ci.yml and the three cited commit hashes (8024b29, f22d566, fde3c2 |
| `storageaccessfrompath-cost` | ✗ refuted | minor | UNVERIFIABLE HERE — every citation (devicemanager.cpp:147-179, iokitmanager.cpp:176-187, dadictionary.cpp:11-22) is in solid, which is not checked out. No line of the claimed evidence could be opened, and no profiling data is offe |
| `have-terminal-true-on-apple` | ✔ upheld | minor | All citations exact — and the claim correctly says it is not a build blocker. dolphin/CMakeLists.txt:152-157 is verbatim `# TODO: drop HAVE_TERMINAL … if(WIN32) set(HAVE_TERMINAL FALSE) else() set(HAVE_TERMINAL TRUE) endif()`. dol |
| `nongui-helpers-become-app-bundles` | ✗ refuted | minor | The load-bearing premise is unread. `set(CMAKE_MACOSX_BUNDLE ON)` in ECM's KDECMakeSettings.cmake could not be verified: extra-cmake-modules is not installed or checked out anywhere (`find / -name KDECMakeSettings.cmake` returns n |
| `qt6guiprivate-required-without-x11` | ✔ upheld | minor | Duplicate of qt6guiprivate-required, and both citations are exact: dolphin/CMakeLists.txt:65-67 is the unconditional-for-6.10+ find_package(Qt6GuiPrivate … REQUIRED NO_MODULE), the only dolphin consumer is src/CMakeLists.txt:543-5 |
| `knewstuff-kcmutils-required-for-one-widget` | ✔ upheld | minor | Consumer citations exact — dolphin/CMakeLists.txt:74-75 in the REQUIRED list; the single KNewStuff consumer is contextmenusettingspage.cpp:24 `#include <KNSWidgets/Button>` and :67 `using NewStuffButton = KNSWidgets::Button;`; KCM |
| `dolphin-hides-menubar-by-default` | ✔ upheld | minor | Every dolphin citation is exact: :224 `menuBar()->setVisible(false);` inside `if (firstRun)`, :237 `showMenuBarAction->setChecked(!menuBar()->isHidden()); // workaround for bug #171080`, :238-240 the `QTimer::singleShot(0, ...)` r |
| `nfd-nfc-mismatch` | ✔ upheld | minor | I reproduced the host probe and it behaves exactly as described. On the APFS Data volume (/private/tmp, 'Macintosh HD', File System Personality: APFS) a file created with NFD bytes `nai\xcc\x88ve.txt` is returned by readdir in NFD |
| `ntfs-hidden-getxattr-per-entry` | ✔ upheld | minor | Citations perfect, magnitude overstated. file_unix.cpp:827 `#if HAVE_SYS_XATTR_H`, :828-855 isNtfsHidden with `constexpr auto attrName = "system.ntfs_attrib_be"` and the `#ifdef Q_OS_MACOS` getxattr(…, 0, XATTR_NOFOLLOW) at :837.  |
| `kdirwatch-no-macos-backend` | ✔ upheld | minor | Half verified, half asserted. I confirmed there is no sys/inotify.h in the SDK (`ls $(xcrun --show-sdk-path)/usr/include/sys/inotify.h` → No such file), so HAVE_SYS_INOTIFY_H is indeed false, and Dolphin's per-subdirectory watch i |
| `kio-worker-launch-dependency` | ✔ upheld | info | Citations exact but this is a design premise, not a defect. kfileitemmodel.cpp:288 `m_dirLister = new KDirLister(this);` with connects through :307, and :350 `m_dirLister->openUrl(url);` is the whole of loadDirectory — so yes, the |
| `selection-manager-synced-by-view` | ✔ upheld | info | Facts exact, but this is an architecture observation, not a runtime defect. kitemlistselectionmanager.h:71-74 declares setModel/itemsInserted/itemsRemoved/itemsMoved under `private:` at :70; friends are `friend class KItemListCont |
| `controller-requires-view` | ✔ upheld | info | Exact, but again an architecture cost, not a defect. kitemlistcontroller.cpp:50 `, m_selectionManager(new KItemListSelectionManager(this))`; :70-71 setModel(model)/setView(view); :75-79 are five consecutive unconditional `view->gr |
| `rolesupdater-drive-loop-in-view` | ✔ upheld | info | Exact. kfileitemlistview.cpp:243 is the sole construction (`m_modelRolesUpdater = new KFileItemModelRolesUpdater(static_cast<KFileItemModel *>(current), this);`) followed by setIconSize/setDevicePixelRatio at :244-245; the drive p |
| `dolphinview-is-qwidget-dialog-anchor` | ✔ upheld | info | Exact, and the 12 line numbers all check out individually. dolphinview.h:56 `class DOLPHIN_EXPORT DolphinView : public QWidget`; :89 `DolphinView(const QUrl &url, QWidget *parent);`. Each cited dolphinview.cpp line passes `this` a |
| `kiofuse-blocking-call-gui-thread` | ✗ refuted | info | REFUTED. The entire block is inside `#ifdef WITH_QTDBUS` opening at desktopexecparser.cpp:398 and closing at :464 — I verified the guard span with an awk scan of all preprocessor lines in 395-520. On the macOS default build (WITH_ |
| `kitemviews-no-itemview-seam` | ✔ upheld | info | Exact, and the single most plan-relevant architecture fact here — but it is a fact, not a UX defect. kitemlistcontainer.h:29 `class DOLPHIN_EXPORT KItemListContainer : public QAbstractScrollArea`; kitemlistcontainer.cpp:31 `class  |
| `embedded-popup-mispositioning` | ✗ refuted | info | Self-refuting as written, and I agree with the author's own hedge. The claim states 'I could not read the QTBUG-91639 issue body … Marked PLAUSIBLE rather than CONFIRMED'; the qtbase citations (qcocoawindow.mm ≈2597-2621, ≈1557-15 |
| `q-os-osx-macro-fragility` | ✗ refuted | info | The line list is perfect but the severity is wrong. My grep of Q_OS_OSX in trashimpl.cpp returns exactly 104, 159, 270, 376, 395, 477, 571, 878, 954, 968, 1034, 1076, 1095, 1107, 1121, 1280 — an exact match to the claim — plus tra |

## What this says about audit reliability

COVERAGE: all 61 claims examined. Nothing left unchecked, though ~12 could only be examined negatively (see below).

BIGGEST SYSTEMIC PROBLEM — claims about repos that are not in this workspace. Only dolphin, kio, kio-extras and craft-blueprints are checked out. solid, extra-cmake-modules, kcoreaddons, kconfig and qtbase are absent, and Qt is not even installed (`brew list` contains no qt; `find / -name qsystemdetection.h` returns nothing). Twelve claims rest wholly or mostly on those absent repos and could not be verified at all: iokit-teardown-noop, iokit-no-hotplug, solid-macos-not-in-ci, storageaccessfrompath-cost (solid); split-responder-chain-menu-validation, qt-owns-nsapp-mainmenu, appdelegate-ordering, processevents-pump-model-broken, embedded-popup-mispositioning (qtbase); non-relocatable-install-names, nongui-helpers-become-app-bundles (ECM); kdirwatch-no-macos-backend (kcoreaddons + qtbase). I marked these refuted=true because no cited file could be opened — that is "unproven", not "disproven". Several would materially change the plan if true (especially iokit-teardown-noop, iokit-no-hotplug, qt-owns-nsapp-mainmenu, processevents-pump-model-broken). RECOMMENDATION: clone solid, extra-cmake-modules, kcoreaddons and qtbase before Phase 1, then re-run verification on exactly those twelve. Do not let them enter the plan as established facts meanwhile.

OUTRIGHT REFUTATIONS (evidence read, claim wrong):
- kiofuse-blocking-call-gui-thread: the whole KIOFuse block is inside `#ifdef WITH_QTDBUS` spanning desktopexecparser.cpp:398-464 (verified by scanning every preprocessor directive in that range). It is not compiled on macOS. The claim's stated mechanism ("the connection is unconnected so the reply errors immediately") is simply not what happens. Also `waitForFinished` is at :436, not in the cited :407-420.
- kio-auth-infinite-loop-no-dbus: the `for (;;)` at kio_sftp.cpp:976 has an exit at :1013-1015 on SSH_AUTH_ERROR, which a real sshd produces after MaxAuthTries. Not unbounded.
- q-os-osx-macro-fragility: exact line list, but ground truth already establishes Qt 6.11 still defines Q_OS_OSX. No build issue today.
- kio-extras-smb-mtp-dead-on-macos: "kio-extras/CMakeLists.txt:107-111 (USE_DBUS_DEFAULT OFF when APPLE)" is fabricated — 105-111 is the BUILD_DOC/KF6DocTools block; the real location is :56-61. The line range was evidently copy-pasted from kio/CMakeLists.txt:104-110.
- empty-bundle-identity cites "grep for MACOSX … returns only CMakeLists.txt:69". My grep returns ZERO hits across the whole dolphin tree, and :69 is `if (UNIX AND NOT APPLE AND NOT HAIKU)`. Ironically the conclusion is better supported than its own evidence.

CITATION QUALITY WAS OTHERWISE VERY HIGH. Claims sourced from dolphin/, kio/ and kio-extras/ were near-flawless — several were line-perfect over a dozen references (fkey-block-system-claimed, uf-hidden-not-honoured, have-terminal-true-on-apple, dolphinview-is-qwidget-dialog-anchor, q-os-osx-macro-fragility's 16-l
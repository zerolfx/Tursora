## KIO Framework Readiness on macOS/arm64

*All paths below are relative to the repo named in the heading of each block. `kio/` = `upstream/kio`, `dolphin/` = `upstream/dolphin`. Checkout audited: KIO `3c6ae8bf` (KF 6.30.0 dev, `KF_DEP_VERSION` 6.29.0, requires Qt ≥ 6.9.0 — `kio/CMakeLists.txt:3-4,98`).*

### 0. Executive summary

KIO is in far better macOS shape than a "Linux desktop framework" reputation suggests. Upstream already has a first-class **`USE_DBUS=OFF`** build mode that is the *default on Apple* (`kio/CMakeLists.txt:107-111`), an Objective-C++ file for the daemon (`kio/src/kiod/kiod_agent.mm`), a DiskArbitration-based trash backend, Darwin-correct `xattr`/`statfs`/`st_*timespec` handling, and a threaded in-process `kio_file` that avoids IPC serialisation entirely. **KIOCore compiles and runs on macOS essentially unmodified.**

The damage is concentrated in exactly one place: **turning D-Bus off silently deletes the auth and SSL-exception subsystems and turns two API calls into lies.** `SlaveBase::openPasswordDialogV2()` returns `KJob::NoError` *without filling in credentials* (`kio/src/core/slavebase.cpp:933-935`), and `KSslCertificateManager::setRule()/rule()` become no-ops (`kio/src/core/ksslcertificatemanager.cpp:401-429`). Those are the two patches KIO itself actually needs.

**Verdict: viable for Phase 1 essentially unmodified. Minimum KIO patch set is ~4 files.**

---

### 1. Structure: the four libraries and what Dolphin pulls from each

| Library | Sources | Dolphin files that `#include` from it | KF6 deps (`target_link_libraries`) |
|---|---|---|---|
| **KIOCore** | `kio/src/core/` (~110 .cpp) | **53** | CoreAddons, ConfigCore, I18n, Service, Crash, Qt Network/Xml |
| **KIOGui** | `kio/src/gui/` | **14** | + Solid, Qt Gui/Concurrent, WindowSystem |
| **KIOWidgets** | `kio/src/widgets/` | **26** | + JobWidgets, Completion, WidgetsAddons, IconThemes, IconWidgets, GuiAddons, ColorScheme, ConfigGui, **Qt6::GuiPrivate** (`kio/src/widgets/CMakeLists.txt`) |
| **KIOFileWidgets** | `kio/src/filewidgets/` | **14** | + Bookmarks, BookmarksWidgets, ItemViews, **Solid** (71 `Solid::` call sites) |

Dolphin links three of them explicitly (`dolphin/src/CMakeLists.txt:226-228`: `KF6::KIOCore`, `KF6::KIOWidgets`, `KF6::KIOFileWidgets`); KIOGui arrives transitively.

**Header-level breakdown (derived by resolving every `#include <K…>` in `dolphin/src` to the KIO subdirectory that defines it):**

| Library | Headers Dolphin uses |
|---|---|
| KIOCore | `KFileItem` (20 sites), `KFileItemListProperties` (11), `KProtocolManager` (7), `KProtocolInfo` (6), `KIO/Job`, `KIO/CopyJob`, `KIO/StatJob`, `KIO/ListJob`, `KIO/SimpleJob`, `KIO/Global`, `KIO/UDSEntry`, `KIO/RestoreJob`, `KIO/MkpathJob`, `KIO/EmptyTrashJob`, `KIO/FileSystemFreeSpaceJob`, `KIO/JobUiDelegateFactory`, `KIO/DesktopExecParser`, `KCoreDirLister`, `KMountPoint`, `KOverlayIconPlugin`, `KDirNotify` |
| KIOGui | `KIO/PreviewJob` (6), `KIO/ApplicationLauncherJob`, `KIO/CommandLauncherJob` (5), `KIO/OpenUrlJob`, `KIO/OpenFileManagerWindowJob`, `KTerminalLauncherJob` |
| KIOWidgets | `KDirLister` (5), `KIO/DropJob` (5), `KIO/DeleteOrTrashJob` (4), `KFileItemActions` (4), `KIO/Paste`, `KIO/PasteJob`, `KIO/FileUndoManager`, `KIO/JobUiDelegate`, `KIO/RenameFileDialog`, `KDirModel`, `KPropertiesDialog`, `KUrlComboBox`, `KAbstractFileItemActionPlugin` |
| KIOFileWidgets | `KFilePlacesModel`, `KFilePlacesView`, `KUrlNavigator`, `KNewFileMenu`, `KFileCopyToMenu` |

**Which can we drop in a native AppKit shell?**

- **KIOCore — load-bearing forever.** It is the only place that defines the data model (`KFileItem`, `UDSEntry`, `KCoreDirLister`), the protocol registry (`KProtocolInfo`/`KProtocolManager`), the worker IPC, and every I/O job. There is no subset of it we can shed. 53 of ~320 Dolphin source files touch it directly; the model layer (`dolphin/src/kitemviews/kfileitemmodel.cpp`) is built on it.
- **KIOFileWidgets — droppable, cleanly.** Every header Dolphin uses from it is a `QWidget` or a widget-bound model. `KFilePlacesModel` is the one piece worth keeping/porting rather than reimplementing (it merges XBEL bookmarks + Solid devices), but it is not on the file-listing path.
- **KIOGui — mostly droppable, one exception.** The launcher jobs (`ApplicationLauncherJob`, `CommandLauncherJob`, `OpenUrlJob`, `KTerminalLauncherJob`) are `.desktop`-file machinery that we would replace with LaunchServices anyway; `openurljob.cpp:189-195` already short-circuits to `QDesktopServices::openUrl()` on `Q_OS_MACOS`. **`KIO::PreviewJob` is the exception** — it is the thumbnail pipeline (plugin loading, cache, devicePixelRatio handling) and re-implementing it is real work.
- **KIOWidgets — droppable but *not* free.** The Qt-widget parts (`KPropertiesDialog`, `KUrlComboBox`, `RenameFileDialog`, `KFileItemDelegate`) are obviously replaceable. But `KIO::DropJob`, `KIO::PasteJob`, `KIO::Paste` and `KIO::FileUndoManager` are **pure logic that merely happens to live in the widgets library** — undo/redo of copy/move/trash, MIME-aware clipboard paste, drag-and-drop action resolution. Re-homing those is the real cost of dropping KIOWidgets. Note also that `KDirLister` is a **60-line subclass** of `KCoreDirLister` (`kio/src/widgets/kdirlister.cpp`, 60 lines total) whose only added API is `setMainWindow()` for auth window-id plumbing — replacing it with plain `KCoreDirLister` is a one-line change per call site.

> **Recommendation:** target `KIOCore + KIOGui` as the permanent surface. Plan to lift `FileUndoManager`/`DropJob`/`PasteJob` logic out of KIOWidgets (or keep KIOWidgets linked headlessly) rather than assuming they come for free.

---

### 2. Platform gates already in KIO

#### 2a. macOS is a *first-class, already-wired* configuration

| Gate | Location | Effect |
|---|---|---|
| `USE_DBUS_DEFAULT OFF` unless `UNIX AND NOT APPLE AND NOT ANDROID AND NOT HAIKU` | `kio/CMakeLists.txt:107-110` | **D-Bus is off by default on macOS.** No session bus assumed. |
| X11/Wayland options only defined `if (NOT APPLE AND NOT WIN32 …)` | `kio/CMakeLists.txt:121-127` | `HAVE_X11`/`HAVE_WAYLAND` undefined on macOS; all `#if HAVE_X11` blocks compile out. |
| `LibMount` required only `if (CMAKE_SYSTEM_NAME MATCHES "Linux")` | `kio/CMakeLists.txt:138-143` | KMountPoint falls back to the BSD `getmntinfo()` branch. |
| `if (APPLE) target_sources(kiod6 kiod_agent.mm)` + `-framework AppKit -framework CoreFoundation` + `ecm_mark_nongui_executable` | `kio/src/kiod/CMakeLists.txt:9-13,33-38` | Full Obj-C++ agent-app support for the daemon. |
| `if(APPLE) target_link_libraries(kio_trash "-framework DiskArbitration -framework CoreFoundation")` | `kio/src/kioworkers/trash/CMakeLists.txt:60-62` | Native volume identification for per-volume trash. |
| `makeAgentApplication()` / `setAgentActivationPolicy()` | `kio/src/kiod/kiod_main.cpp:84-87,120-125`, `kio/src/kiod/kiod_agent.mm` | Sets `LSUIElement` programmatically + `NSApplicationActivationPolicyAccessory` so kiod has no Dock icon but *can* take keyboard focus in dialogs. |

#### 2b. Darwin-correct source-level code (evidence of real upstream care)

| Concern | Location |
|---|---|
| `flistxattr/fgetxattr/fsetxattr` 6-arg Darwin signatures | `kio/src/kioworkers/file/file_unix.cpp:368-372, 426-432, 460-466` |
| `getxattr(..., 0, XATTR_NOFOLLOW)` for NTFS hidden-attr probe | `kio/src/kioworkers/file/file_unix.cpp:836-840` |
| `st_atimespec`/`st_mtimespec` vs `st_atim`/`st_mtim` | `kio/src/kioworkers/file/stat_unix.h:232, 246` |
| `SOCK_NONBLOCK` fallback for macOS | `kio/src/kioworkers/file/sharefd_p.h:18-21` |
| POSIX-ACL probe via Darwin `getxattr` | `kio/src/widgets/kpropertiesdialogbuiltin_p.cpp:1398-1399` |
| Skip `kuiserver` on macOS/Windows, use widget tracker | `kio/src/widgets/kdynamicjobtracker.cpp:115-119` |
| Skip `KWindowSystem::setMainWindow` on macOS | `kio/src/kpasswdserver/kpasswdserver.cpp:833-836` |
| `QDesktopServices::openUrl()` on macOS instead of `.desktop` resolution | `kio/src/gui/openurljob.cpp:189-195` |
| HTTP `User-Agent` platform string = `Macintosh` | `kio/src/kioworkers/http/http.cpp:1768-1771` |
| Whole macOS trash implementation | `kio/src/kioworkers/trash/trashimpl.cpp` (18 `Q_OS_OSX` blocks) |

#### 2c. What is Linux-only and simply compiles out

`statx()` and `STATX_MNT_ID_UNIQUE` (guarded by `LIBC_IS_GLIBC` in `kio/src/core/ConfigureChecks.cmake:29-36`), `libmount`/`/proc/self/mountinfo` (`kio/src/core/kmountpoint.cpp:428-434`), `copy_file_range` (`check_function_exists` in `kio/src/kioworkers/file/ConfigureChecks.cmake:16`; call site `file_unix.cpp:648`), systemd `KProcessRunner` backends (`kio/src/gui/CMakeLists.txt:43` — `HAVE_QTDBUS AND CMAKE_SYSTEM_NAME STREQUAL "Linux"`), SwitcherooControl GPU detection (`kio/src/gui/gpudetection.cpp:45-58`), KX11Extras window tracking (`kio/src/kpasswdserver/kpasswdserver.cpp:32-34,75-77`).

**No Linux-only IPC anywhere in the worker path** — see §3.

---

### 3. Worker launching in KF6 — precise mechanism

`KIO::Worker::createWorker()` (`kio/src/core/worker.cpp:419-535`) has **three** paths:

**(a) Built-in, no process at all.** `protocol == "data"` returns `new DataProtocol()` (`worker.cpp:423-425`).

**(b) In-process worker thread — the default for `file:`.**
```cpp
// kio/src/core/worker.cpp:469-473
const auto useThreads = []() { return qgetenv("KIO_ENABLE_WORKER_THREADS") != "0"; };
static bool bUseThreads = useThreads();
// worker.cpp:477
if (protocol == QLatin1String("admin") || (bUseThreads && protocol == QLatin1String("file"))) {
```
The `.so`/`.dylib` is loaded with `QPluginLoader`, cast to `KIO::WorkerFactory`, and run in a `WorkerThread` inside the app process (`worker.cpp:479-491`). **This is the `KIO_FORK_SLAVES` successor**: the env knob is `KIO_ENABLE_WORKER_THREADS=0` to force out-of-process. It applies *only to `file` and `admin`*, by explicit upstream design ("Threads have performance benefits, but degrade robustness", `worker.cpp:475-476`).

**(c) Out-of-process, for everything else (`trash:`, `ftp:`, `http:`/`dav:`, `remote:`, and every kio-extras worker).**
1. The app creates a `QLocalServer` listening on a **filesystem-path Unix socket** under `QStandardPaths::RuntimeLocation`, named `<appName>XXXXXX.<n>.kioworker.socket` (`kio/src/core/socketconnectionbackend.cpp:108-138`). **No abstract namespace, no `socketpair`, no `SOCK_CLOEXEC`/`SOCK_NONBLOCK` flag-ORing, no `prctl`, no `/proc`.**
2. It locates the `kioworker` stub via `KLibexec::kdeFrameworksPaths("libexec/kf6")`, then the compiled-in `KDE_INSTALL_FULL_LIBEXECDIR_KF`, then plain `PATH` (`worker.cpp:507-522`).
3. It spawns it with **`QProcess::startDetached()`**, passing `{lib_path, protocol, "", "local:/path/to/socket"}` (`worker.cpp:524-532`). The only Unix-specific call is `setUnixProcessParameters(CloseFileDescriptors)` under `#ifdef Q_OS_UNIX` (`worker.cpp:528-530`) — supported on Darwin.
4. `kioworker` (`kio/src/kioworker/kioworker.cpp`) is a ~140-line stub: `QPluginLoader(libname).fileName()` → `QLibrary::load()` → `resolve("kdemain")` → call it. It deliberately keeps `argv[0]` intact "so that `applicationDirPath()` is correct on non-Linux (no `/proc`)" (`kioworker.cpp:129-131`).
5. The worker connects back with `QLocalSocket` (`socketconnectionbackend.cpp:82-97`).

**D-Bus in the launch path: none.** Every `QDBus*` use in KIOCore is behind `#ifdef WITH_QTDBUS` (43 sites), and `KPasswdServerClient` is only *compiled* when `HAVE_QTDBUS` (`kio/src/core/CMakeLists.txt:95-98`).

#### Worker discovery and the `.app` bundle

Discovery is `KPluginMetaData::findPlugins(QStringLiteral("kf6/kio"))` (`kio/src/core/kprotocolinfofactory.cpp:91`), which walks `QCoreApplication::libraryPaths()` looking for a `kf6/kio` subdirectory and reads each plugin's embedded `KDE-KIO-Protocols` JSON. Install namespace is `${KDE_INSTALL_PLUGINDIR}/kf6/kio` (`kio/src/core/config-kiocore.h.cmake:12`).

**Inside a bundle this works with zero code changes** provided workers land in `Dolphin.app/Contents/PlugIns/kf6/kio/` — Qt adds `Contents/PlugIns` to `libraryPaths()` automatically on macOS. Two caveats:

- The `kioworker` **executable** is found through `KLibexec::kdeFrameworksPaths()` (a KCoreAddons API that resolves relative to the loaded library via `dladdr`), not through `libraryPaths()`. Its behaviour for a dylib inside `Contents/Frameworks/` is **not verifiable from this checkout** (KCoreAddons is not checked out) — see open questions. The `QStandardPaths::findExecutable("kioworker")` PATH fallback (`worker.cpp:515`) and the compiled-in `KDE_INSTALL_FULL_LIBEXECDIR_KF` give us two escape hatches, and worst case we ship a `qt.conf`/`LibraryExecutables` entry.
- The `admin` protocol is refused unless its plugin path starts with the compiled-in `KDE_INSTALL_FULL_KIO_PLUGINDIR` (`worker.cpp:456-465`) — i.e. **bundled `kf6/kio` plugins can never provide `admin:`**. Irrelevant to us (kio_admin lives in a separate repo and is a polkit/root-helper thing we do not want on macOS).
- Socket path length: `sun_path` is **104 bytes on Darwin vs 108 on Linux**. macOS `RuntimeLocation` resolves under `/var/folders/xx/…/T/` (~43 chars); plus `dolphin` + `XXXXXX.1.kioworker.socket` (25 chars) ≈ 75. Fits, but there is less headroom than on Linux and a long `applicationName()` would break it.

**Dead code found:** `isWorkerSecurityCompromised()` (`kio/src/core/worker.cpp:372-415`) is defined but **never called** anywhere in the tree. Its `entryInfoList({"*KIOCore.so*"})` glob would never match `libKF6KIOCore.6.dylib` on macOS anyway. Harmless; worth knowing so we do not chase it. Likewise `FdReceiver`/`sharefd_p.h` (`kio/src/kioworkers/file/fdreceiver.cpp`) is compiled into `kio_file` (`kio/src/kioworkers/file/CMakeLists.txt:14`) but has **no remaining callers** — and its `::socket(AF_LOCAL, SOCK_STREAM | SOCK_NONBLOCK, 0)` (`fdreceiver.cpp:27`, where the macOS fallback `#define SOCK_NONBLOCK O_NONBLOCK` makes the type argument `1|4 == 5 == SOCK_SEQPACKET`) would fail at runtime on Darwin if it were ever used. Recommend deleting it from our build rather than fixing it.

---

### 4. Workers shipping in KIO core

Enumerated from `kio/src/kioworkers/CMakeLists.txt:3-8` and each worker's embedded JSON.

| Worker | Protocols (from JSON) | In-proc? | macOS gate-check |
|---|---|---|---|
| **`kio_file`** | `file` | **Yes** (threaded by default) | ✅ Builds. `file_unix.cpp` + `fdreceiver.cpp` on non-WIN32 (`file/CMakeLists.txt:5-17`). Darwin xattr/stat paths present. `copy_file_range` compiled out. Case-insensitive rename already special-cased (`file_unix.cpp:1000-1010`). |
| **`kio_trash`** | `trash` | No | ⚠️ Builds with DiskArbitration. **Uses `~/.Trash/KDE.trash/{files,info}`, not the native Finder trash** — see §4a. |
| **`kio_ftp`** | `ftp` | No | ✅ Pure `QTcpSocket`/Qt Network. Builds clean. Auth broken without D-Bus (§5). |
| **`kio_http`** | `dav`, `davs`, `http`, `https`, `webdav`, `webdavs` | No | ✅ Rewritten on `QNetworkAccessManager` (`http.cpp:24,298`). **WebDAV is here, not a separate worker.** Builds clean; TLS exception storage broken without D-Bus (§6). |
| **`kio_remote`** | `remote` | No | ⚠️ Builds, but its change-notification KDED module is `if (HAVE_QTDBUS)` (`remote/CMakeLists.txt:1-3`) → **`remote:/` never auto-refreshes on macOS**. |
| **`kio_help` / `kio_ghelp`** | `help`, `ghelp` | No | ⛔ Only built `if (KF6DocTools_FOUND)` and needs LibXslt + LibXml2 + KArchive (`help/CMakeLists.txt:1-24`). **Do not build these.** Dolphin does not need them. |
| `ktrash6` | (CLI helper) | — | Builds. |

Also in-tree but **not built without D-Bus**: `kiod6` + `kssld` (`kio/src/CMakeLists.txt:8-11`), `kiod_kpasswdserver` + `kioexec` (`kio/src/CMakeLists.txt:23-26`), the Qt Designer plugin. `schemehandlers/telnet` and `urifilters` still build.

#### 4a. Trash is macOS-aware but *not* macOS-native — a UX blocker

`TrashImpl::init()` (`kio/src/kioworkers/trash/trashimpl.cpp:146-180`):
```cpp
#else   // Q_OS_OSX
    // we DO NOT create ~/.Trash on OS X, that's the operating system's privilege
    QString trashDir = QDir::homePath() + QLatin1String("/.Trash");
    ...
    trashDir += QLatin1String("/KDE.trash");
```
Everything then follows the **freedesktop.org trash spec inside that subfolder**: `KDE.trash/files/` + `KDE.trash/info/*.trashinfo`, `createTrashInfrastructure()` called lazily on every operation under `#ifdef Q_OS_OSX` (`trashimpl.cpp:376-379, 395-397, 477-479, 571-573`), and per-volume trash IDs derived from `DADiskCopyDescription` major/minor numbers (`trashimpl.cpp:878-921`).

Consequences on macOS:
- Finder shows a stray `KDE.trash` **folder** in the user's Trash, not the individual files.
- Finder's **"Put Back"** does not work on our trashed items (it uses per-item Spotlight/`.DS_Store` metadata, not `.trashinfo`).
- Items the user trashes **in Finder do not appear in Dolphin's `trash:/`** at all.
- Emptying trash from Finder leaves our `info/` orphans.

This is a **UX blocker**, and the fix is in KIO: an alternate `TrashImpl` backend calling `NSFileManager trashItemAtURL:` / `-[NSWorkspace recycleURLs:]`, or a Dolphin-side interception. Not needed for Phase 1 to *run*, but shipping it as-is would read as broken.

---

### 5. Authentication: the KPasswdServer flow and the Keychain seam

**Normal (Linux) flow:**
`kio_ftp`/`kio_http` call `WorkerBase::checkCachedAuthentication()` / `openPasswordDialog()` (`kio/src/core/workerbase.cpp:333-386`) → `SlaveBase` → `KPasswdServerClient` → **D-Bus** to `org.kde.kpasswdserver6` at `/modules/kpasswdserver` (`kio/src/core/kpasswdserverclient.cpp:29-33`) → the `kiod6`-hosted `KPasswdServer` module shows a `KPasswordDialog` (`kio/src/kpasswdserver/kpasswdserver.cpp:840-843`) and persists to **KWallet** (`kpasswdserver.cpp:113-166, 425, 472-481`; `KF6Wallet` is `OPTIONAL`, gated by `HAVE_KF6WALLET` in `kio/src/kpasswdserver/CMakeLists.txt:1-12`).

**On macOS (`USE_DBUS=OFF`) this whole subsystem is not built** (`kio/src/CMakeLists.txt:23-26`), and the client stubs become:

```cpp
// kio/src/core/slavebase.cpp:926-935  — openPasswordDialogV2()
#ifdef WITH_QTDBUS
    ... queryAuthInfo(...) ...
    return errCode;
#else
    return KJob::NoError;        // <-- returns SUCCESS with an unmodified, empty AuthInfo
#endif
```
```cpp
// kio/src/core/slavebase.cpp:1275-1283 — checkCachedAuthentication()
#else
    return false;
#endif
```
```cpp
// kio/src/core/slavebase.cpp:1325-1331 — cacheAuthentication() → no-op, still returns true
```

**This is the single worst bug for us.** `kio_ftp` does `const int errorCode = q->openPasswordDialog(info, errorMsg);` (`kio/src/kioworkers/ftp/ftp.cpp:579`) and on `NoError` proceeds to log in with an **empty username/password**, then loops. `kio_http` does the same at `http.cpp:342-351`. Any authenticated protocol (ftp, WebDAV, and later kio-extras `sftp:`/`smb:`) will hard-fail or spin. `return KJob::NoError` should be `return KIO::ERR_USER_CANCELED` at minimum.

**The seam for a native macOS sheet + Keychain — three options, in increasing order of cleanliness:**

1. **`KIO::AskUserActionInterface`** (`kio/src/core/askuseractioninterface.h`) — the abstract, KIOCore-level, *widget-free* hook that KIO resolves via `KIO::delegateExtension<KIO::AskUserActionInterface*>(job)` off the job's `KJobUiDelegate` (`kio/src/core/jobuidelegatefactory.h:102-125`, used at `kio/src/core/usernotificationhandler.cpp:130-141`). We install our own subclass by implementing `KIO::JobUiDelegateFactory::createDelegate()` and calling `KIO::setDefaultJobUiDelegateFactory()`. **This is the right seam for SSL and all messageboxes.** It does **not** currently carry password prompts.
2. **`KPasswdServerClient`** (`kio/src/core/kpasswdserverclient.h`) — the D-Bus proxy. Replacing its three methods (`checkAuthInfo`, `queryAuthInfo`, `addAuthInfo`) with a Keychain-backed in-process implementation, and un-`#ifdef`ing the three `SlaveBase` call sites, is the **smallest correct patch**: `KIO::AuthInfo` (`kio/src/core/authinfo.h`) maps almost 1:1 onto a `kSecClassInternetPassword` item (`url`, `username`, `password`, `realmValue`, `keepPassword`). ~1 new file + 3 `#ifdef` edits in `slavebase.cpp`. **This is what I recommend.**
3. Add a `queryAuthInfo()` virtual to `AskUserActionInterface` and route through it — the "upstream-able" version, but a KF API addition.

**KIO does not use KWallet anywhere except `kpasswdserver`** (grep: `KWallet` appears only in `kio/src/kpasswdserver/kpasswdserver.{h,cpp}` and its CMake). So dropping kpasswdserver drops the *entire* KWallet dependency — there is nothing else to unpick.

Note: the credential prompt must also run **in-process** on macOS, because the worker is a separate process with no session bus to call back into. For out-of-process workers this means the existing `INF_MESSAGEBOX`-style socket round-trip (`SlaveBase::messageBox`, `slavebase.cpp:942-960` → `UserNotificationHandler`) is the transport we should reuse for password prompts too — i.e. add a `CMD_PASSWORDANSWER`-style command rather than trying to show UI from the worker process.

---

### 6. SSL/TLS

- **Trust store:** `KSslCertificateManagerPrivate::loadDefaultCaCertificates()` uses `QSslConfiguration::systemCaCertificates()` (`kio/src/core/ksslcertificatemanager.cpp:178`), i.e. **whatever Qt's TLS backend reports**. Homebrew `qtbase` 6.11.1 depends on `openssl@3` (verified via `brew info qtbase`), so the active backend will be OpenSSL, and `systemCaCertificates()` on macOS is populated from the **system keychain via Security.framework** by Qt's own platform code. No KDE-specific CA bundle is required. It additionally merges PEMs from `$GenericDataLocation/kssl/userCaCertificates/` (`ksslcertificatemanager.cpp:163-164, 185`) and honours a `ksslcablacklist` KConfig blacklist (`ksslcertificatemanager.cpp:181-190`) — both harmless, both KConfig-based (no D-Bus).
- **Error UI:** `kio_http` collects the peer chain and error list and calls `sslError(sslData)` (`kio/src/kioworkers/http/http.cpp:140-232`), which travels over the worker socket to `UserNotificationHandler::sslError()` → `AskUserActionInterface::askIgnoreSslErrors()` (`kio/src/core/usernotificationhandler.cpp:130-141`). The widget implementation is `KIO::WidgetsAskUserActionHandler::askIgnoreSslErrors()` (`kio/src/widgets/widgetsaskuseractionhandler.cpp:503-581`) which builds a `KSslInfoDialog`. **Replacing this with an `NSAlert`/sheet is a clean subclass of `AskUserActionInterface`** — no KIOWidgets needed.
- **What breaks on macOS:** the *storage* of user-accepted exceptions. `KSslCertificateManager::rule()`, `setRule()`, `clearRule()` are pure D-Bus proxies to the `kssld` module and become no-ops / return default-constructed `KSslCertificateRule` when `WITH_QTDBUS` is undefined (`kio/src/core/ksslcertificatemanager.cpp:401-429`). Since `kssld` is not built at all on macOS (`kio/src/CMakeLists.txt:8-11`), **the user is re-prompted on every single connection to a self-signed / expired-cert host**, and "accept forever" (`http.cpp:206-232`) silently does nothing.
- **Fix:** `kssld` is a thin KConfig-backed rule store (`kio/src/kssld/kssld.cpp`). Compile it as an in-process singleton and make `KSslCertificateManager` call it directly when `!WITH_QTDBUS`, or persist rules to the Keychain alongside credentials. Small patch (~100 lines), self-contained in KIOCore.
- `KSslCertificateManager::nonIgnorableErrors()` (`ksslcertificatemanager.cpp:441-449`) is pure logic and works everywhere.

---

### 7. Performance for the 10k/100k-file goal

#### 7a. The good news: `file:` listing is a *zero-copy in-process* pipeline

This is genuinely strong and we should not throw it away.

1. `FileProtocol::listDir()` (`kio/src/kioworkers/file/file_unix.cpp:854-970`) walks `readdir()`. With `details == KIO::StatBasic` it uses `d_type` only — **no `stat` at all** (`file_unix.cpp:924-940`). With full details it calls `createUDSEntry()` per entry.
2. `SlaveBase::listEntry()` batches: flush when **>200 entries** or **>300 ms** since the batch started (`kio/src/core/slavebase.cpp:85-86, 711-741`):
   ```cpp
   static constexpr int KIO_MAX_ENTRIES_PER_BATCH = 200;
   static constexpr int KIO_MAX_SEND_BATCH_TIME  = 300;
   ...
   if (d->m_timeSinceLastBatch.elapsed() > KIO_MAX_SEND_BATCH_TIME
       || d->pendingListEntries.size() > KIO_MAX_ENTRIES_PER_BATCH) { listEntries(...); }
   ```
3. Because `kio_file` runs **in-thread** (§3b), the batch crosses to the app as a `std::variant` payload holding the `UDSEntryList` itself — no `QDataStream` marshalling:
   ```cpp
   // kio/src/core/connectionbackend_p.h:33
   using TaskPayload = std::variant<std::monostate, QByteArray, quint32, quint64,
                                    QString, QUrl, UDSEntry, UDSEntryList, MetaData, TaskError>;
   // kio/src/core/workerinterface.cpp:130-135
   case MSG_LIST_ENTRIES:
       if (UDSEntryList *entries = std::get_if<UDSEntryList>(&m_incomingPayload)) {
           Q_EMIT listEntries(std::exchange(*entries, UDSEntryList{}));  // moved, not serialised
   ```
   with a bounded 32-task queue providing backpressure (`kio/src/core/threadconnectionbackend_p.h:74`).
4. `KCoreDirListerCache::slotEntries()` builds `KFileItem`s, sorts the batch, inserts, emits (`kio/src/core/kcoredirlister.cpp:1133-1245`).

**Nothing macOS-specific degrades steps 1–3.**

#### 7b. Three concrete costs, two of them macOS-specific

**(i) One extra `getxattr()` syscall per file, macOS-only.** In the detailed-listing path:
```cpp
// kio/src/kioworkers/file/file_unix.cpp:946-948
#if HAVE_SYS_XATTR_H && HAVE_DIRENT_D_TYPE
    if (isNtfsHidden(filename)) {
```
`sys/xattr.h` exists on macOS so `HAVE_SYS_XATTR_H=1` (`kio/src/kioworkers/file/ConfigureChecks.cmake:12`), and `isNtfsHidden()` issues `getxattr(name, "system.ntfs_attrib_be", …, XATTR_NOFOLLOW)` per entry (`file_unix.cpp:828-852`). On APFS this always returns `ENOATTR`, so it is pure waste: **100k extra syscalls per full listing.** Trivial fix — add `&& !defined(Q_OS_MACOS)` to the guard, since NTFS-3G's attribute namespace does not exist on Darwin.

**(ii) `KMountPoint` has no cache on the non-`statx` path — macOS-only.** `currentMountPointForPath()` short-circuits through a mount-id cache **only** `#if HAVE_STATX_MNT_ID_UNIQUE` (`kio/src/core/kmountpoint.cpp:730-740`). That macro is set only for glibc (`kio/src/core/ConfigureChecks.cmake:29,62-75`), so on macOS **every call re-runs `getmntinfo(MNT_NOWAIT)` and `lstat()`s every mount point** (`kmountpoint.cpp:367-395`). Callers on hot paths: `isOnCifsMount()` (`kio/src/kioworkers/file/file_unix.cpp:96`), `TrashImpl::findTrashDirectory()` per trashed file (`kio/src/kioworkers/trash/trashimpl.cpp:934`), `dropjob.cpp:457,508`. Not fatal for plain listing, but it makes "trash 5000 files" O(n × mounts). Fix: extend the existing `MountIdCache` (`kmountpoint.cpp:683-728`) to a path/`st_dev`-keyed cache on non-statx platforms.

**(iii) `insertSortedItems()` is O(n²) in list size — cross-platform, but it is what will bite the 100k target.**
```cpp
// kio/src/core/kcoredirlister_p.h:493-504
lstItems.reserve(lstItems.size() + items.size());
auto it = lstItems.begin();
for (const auto &item : items) {
    it = std::lower_bound(it, lstItems.end(), item.url());
    it = lstItems.insert(it, item);          // O(n) memmove, once per item
}
```
`KFileItem` is one `QSharedDataPointer` (8 bytes, `kio/src/core/kfileitem.h:716`), so each insert memmoves ~`n/2 × 8` bytes. Batches arrive in readdir order (≈ random w.r.t. sorted URL order), so total work ≈ `n²/2` element moves — ~5×10⁹ for n=100k. Upstream's own benchmark only goes to **1000 items** (`kio/autotests/kcoredirlister_benchmark.cpp:21-22`, `maxPowerOfTen = 3`), so this is untested territory. **I have not measured it — flagging as the single highest-value thing to benchmark first.** Mitigation is local: accumulate per batch and `std::inplace_merge`, giving `O(n log n)` total.

#### 7c. Case-insensitive filesystem behaviour

I found **no pathological case-folding** in `KCoreDirLister` — but I also found no case-*insensitive* handling, which is its own hazard:

- `KCoreDirListerCache::itemsInUse` / `itemsCached` are `QHash<QUrl, DirItem*>` (`kio/src/core/kcoredirlister.cpp:158, 687-689`) — **case-sensitive keys**.
- Item lookup is `std::binary_search(dir->lstItems, item)` on URL ordering (`kcoredirlister.cpp:1207`).
- `KMountPoint::List::findByDevice()` explicitly uses `Qt::CaseSensitive` on every non-Windows platform, macOS included:
  ```cpp
  // kio/src/core/kmountpoint.cpp:29-33
  #ifdef Q_OS_WIN
  static const Qt::CaseSensitivity cs = Qt::CaseInsensitive;
  #else
  static const Qt::CaseSensitivity cs = Qt::CaseSensitive;
  #endif
  ```
- `findByPath()` compares `realPath.startsWith(mountPtr->mountPoint())` case-sensitively (`kmountpoint.cpp:573`).

On a default (case-insensitive, case-preserving) APFS volume, navigating to `/Users/foo/Documents` and `/Users/foo/documents` yields **two independent `DirItem`s, two `KDirWatch` registrations, and two listings of the same directory**. Upstream is aware of case-insensitive filesystems in exactly one place — the rename path (`file_unix.cpp:1000-1010`, "detected special case of lower/uppercase renaming … on a case-insensitive filesystem"). Mitigation is cheap and belongs on our side: canonicalise every URL at the Dolphin/AppKit boundary before it reaches `KCoreDirLister`.

**Unicode normalisation is an open question.** There is **zero** use of `QString::normalized()` anywhere in `kio/src` (verified by grep). HFS+ stores NFD; APFS is normalisation-*insensitive* but preserving, so `readdir()` can return NFD while user input is NFC. Whether this produces cache misses depends on Qt/APFS behaviour I could not verify statically.

---

### 8. Verdict and minimum patch set

**Yes — unmodified upstream KIO is viable on macOS/arm64 for Phase 1** (local `file:` browsing, copy/move/delete, thumbnails). Nothing in the KIOCore listing/job path is Linux-specific; `kio_file` runs in-process; worker discovery works in a bundle; the whole D-Bus surface is already `#ifdef`-clean. The one thing you should *expect* to configure rather than patch is the build:

```
-DUSE_DBUS=OFF          # already the APPLE default (CMakeLists.txt:107-110)
-DBUILD_TESTING=OFF
-DKF6DocTools_DIR=…-NOTFOUND   # keeps kio_help/kio_ghelp out (help/CMakeLists.txt:1)
```
KF6 modules that must be built from source for **KIOCore alone**: `extra-cmake-modules` (Homebrew has 6.29.0 — exactly `KF_DEP_VERSION`), KConfig, KCoreAddons, KI18n, KService, KCrash, **Solid** (required unconditionally at `kio/CMakeLists.txt:70` "for kio_trash"). Full Dolphin needs the further ~12 listed in `kio/CMakeLists.txt:73-85`. Watch for `Qt6GuiPrivate`, required when Qt ≥ 6.10 (`kio/CMakeLists.txt:101-103`) and consumed by `kio/src/widgets/kurlrequester.cpp:30` (`#include <private/qguiapplication_p.h>`) — confirm Homebrew `qtbase` ships private headers before committing to KIOWidgets.

#### Minimum patch set **to KIO itself** (as opposed to Dolphin)

| # | Patch | File(s) | Size | Needed by |
|---|---|---|---|---|
| 1 | `openPasswordDialogV2()` must not return `NoError` with empty creds; route to an in-process credential provider | `kio/src/core/slavebase.cpp:926-935` (+`:1275-1283`, `:1325-1331`) | **S** (3 `#ifdef`s) | Phase 2 |
| 2 | Keychain-backed replacement for `KPasswdServerClient` (or a `queryAuthInfo` virtual on `AskUserActionInterface`) | new file in `kio/src/core/` + `CMakeLists.txt:95-98` | **M** | Phase 2 |
| 3 | In-process `KSslCertificateRule` store so "accept certificate forever" persists | `kio/src/core/ksslcertificatemanager.cpp:401-429`, reuse `kio/src/kssld/kssld.cpp` | **M** | Phase 2 |
| 4 | Guard `isNtfsHidden()` out on Darwin (one `getxattr` per file saved) | `kio/src/kioworkers/file/file_unix.cpp:946-948` | **S** | Phase 1 |
| 5 | Cache `KMountPoint::currentMountPointForPath()` on non-`statx` platforms | `kio/src/core/kmountpoint.cpp:730-740, 683-728` | **S/M** | Phase 1 |
| 6 | Replace `insertSortedItems()` linear inserts with `inplace_merge` **(measure first)** | `kio/src/core/kcoredirlister_p.h:493-504` | **S** | Phase 1 (100k goal) |
| 7 | Guard `Q_ASSERT(QFileInfo::exists(kioexec))` — `kioexec` is not built when D-Bus is off | `kio/src/core/desktopexecparser.cpp:276-283` | **S** | Phase 2/3 |
| 8 | Native-Trash backend (`NSFileManager trashItemAtURL:`) instead of `~/.Trash/KDE.trash` | `kio/src/kioworkers/trash/trashimpl.cpp` (18 `Q_OS_OSX` sites) | **L** | Phase 3 (UX) |
| 9 | Drop dead `fdreceiver.cpp`/`sharefd_p.h` from `kio_file` | `kio/src/kioworkers/file/CMakeLists.txt:14` | **S** | hygiene |

Patches 4–6 are the whole Phase-1 KIO delta and are all small. **Patches 1–3 are the real work, and they are all D-Bus-substitution, all in KIOCore, all upstream-able** (KDE would plausibly take 1 and 3 as bug fixes).

Deliberately **not** patched: `KDirNotify`. On macOS, local-file change notification flows through `KDirWatch` (registered only for `url.isLocalFile()`, `kio/src/core/kcoredirlister_p.h:447-449, 464-466`), which is a KCoreAddons concern, not a KIO one. The consequence is that **virtual protocols do not auto-refresh** — `trash:/` and `remote:/` views will need a manual/polling refresh, since their change notifications are `#ifdef WITH_QTDBUS`-only (`trashimpl.cpp:869-871`, `kio/src/kioworkers/remote/CMakeLists.txt:1-3`).
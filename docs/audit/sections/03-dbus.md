## D-Bus Dependency & De-Bus Strategy

**Bottom line:** D-Bus is *not* the structural blocker it looks like from the outside. Upstream KF6 has already
done most of the de-Bus work: **KIO's `USE_DBUS` option already defaults to `OFF` on Apple**
(`CMakeLists.txt:105-119`, kio), and KIO carries **87 `#ifdef WITH_QTDBUS` guards across 35 files** with real
non-D-Bus fallbacks. A `kioworker` is launched with `QProcess` + a Unix-domain socket and touches D-Bus **not at
all**. What remains is a small number of *behavioural* holes — credentials, cross-process directory
invalidation, job progress — plus ~11 unguarded call sites in Dolphin itself. There are **no 25-second blocking
D-Bus stalls** on the no-bus path; the dangerous blocking calls only become reachable if we *add* a bus.

---

### A) Dolphin: complete D-Bus touchpoint inventory

Exhaustive grep of `upstream/dolphin/src` for `QDBus|KDBusService|KDirNotify|*interface` (excluding `po/`,
`*.xml`, `tests/`) yields exactly the files below. Dolphin has **no `USE_DBUS` option** — `Qt6::DBus`
(`CMakeLists.txt:62`) and `KF6::DBusAddons` (`CMakeLists.txt:78`) are unconditional `REQUIRED` components,
linked at `src/CMakeLists.txt:221` (`dolphinprivate`) and `src/CMakeLists.txt:491` (`dolphinstatic`).

| File:line (repo `dolphin`) | Interface / purpose | Behaviour with **no session bus** |
|---|---|---|
| `src/dbusinterface.cpp:20-26` | Registers `/org/freedesktop/FileManager1`, claims `org.freedesktop.FileManager1` (XDG file-manager spec: `ShowFolders`/`ShowItems`/`ShowItemProperties`) | `registerObject()` returns false; `sessionBus().interface()` is `nullptr`, guarded at line 23 → **silent no-op**. Whole class is dead weight on macOS. |
| `src/main.cpp:184,186` (`--daemon`) | `KDBusService` (default options) + `DBusInterface` | Registration fails. `NoExitOnFailure` is only set under `FLATPAK` → **`dolphin --daemon` aborts** (see §B). |
| `src/main.cpp:230-235` | `KDBusService(Multiple)` for the normal GUI path | Already handled: line 231 checks `sessionBus().isConnected()` and adds `NoExitOnFailure`. Comment at line 229 reads "Allow starting Dolphin on a system that is not running DBus". **Safe.** |
| `src/main.cpp:249-251` → `src/global.cpp:141-170` | `Dolphin::dolphinGuiInstances()` — enumerates `org.kde.dolphin-<pid>` services | `sessionInterface == nullptr` (global.cpp:153) → empty list → `instancesCount == 0` → the `instancesCount == 1 \|\| (isSessionRestored() && > 0)` test at `main.cpp:251` **never passes**. ⇒ **"Remember open tabs"/session restore silently does nothing.** Real regression, not cosmetic. |
| `src/global.cpp:60-138` | `attachToExistingInstance()` — 3 × `waitForFinished()` on `isActiveWindow()` / `isUrlOpen()` / `openFiles()` | Returns `false` immediately because `dolphinGuiInstances()` is empty (line 72-75). **No blocking, no hang.** Single-instance semantics are simply gone. |
| `src/dolphinmainwindow.cpp:2063-2064` | `isServiceRegistered("org.kde.kio.StashNotifier")` to show/hide the "Stash" toolbar action | `sessionInterface` null → action hidden. Correct degradation; one round-trip on Linux only. |
| `src/dolphinmainwindow.cpp:148` + `src/global.cpp:146` | `setObjectName("Dolphin#")` ⇒ KXmlGui auto-registers the `org.kde.dolphin.MainWindow` adaptor (generated at `src/CMakeLists.txt:477-479`) at `/dolphin/Dolphin_1` | Object registration fails silently. |
| `src/panels/information/informationpanel.cpp:11-13,414-422` | Subscribes to `org.kde.KDirNotify` broadcasts to refresh the info panel | Guarded by `#define HAVE_KDIRNOTIFY __has_include(<KDirNotify>)` — **already portable**. Compiles out; panel just doesn't live-refresh. |
| `src/panels/terminal/terminalpanel.cpp:43,300-320,341-370` | `org.kde.KIOFuse.VFS` — `mountUrl()` / `remoteUrl()`, async (`QDBusPendingCallWatcher`) | Non-blocking; replies error out. Moot anyway: the whole terminal panel is behind `HAVE_TERMINAL`, forced `FALSE` off-Linux at `CMakeLists.txt:152-156`. |
| `src/views/dolphinremoteencoding.cpp:213-216` | Broadcasts `org.kde.KIO.Scheduler.reparseSlaveConfiguration` (signal, `send()`) | Fire-and-forget → **silent no-op**. Same-process side is guarded in KIO (`src/core/scheduler.cpp:571-583`); note `Scheduler::emitReparseSlaveConfiguration()` at `scheduler.cpp:624-628` calls the slot **directly** when D-Bus is off, so in-process reparse still works if we call that instead. |
| `src/views/draganddrophelper.cpp:41-50` | **Blocking** `sessionBus().call()` to Ark's `org.kde.ark.DndExtract` | Only on the Ark-DnD MIME path. Invalid connection → returns immediately with error. Ark does not exist on macOS ⇒ dead code. |
| `src/settings/kcm/kcmdolphinviewmodes.cpp:78-80` | `org.kde.Konqueror.Main.reparseConfiguration` signal | Fire-and-forget → no-op. Pure legacy. |
| `src/kitemviews/private/kitemlistsmoothscroller.cpp:32-38` | Subscribes to `/SmoothScroll org.kde.SmoothScroll notifyChange` | `connect()` fails silently; the setting is still read from `kdeglobals` at line 28-31. Cosmetic. |
| `src/itemactions/hidefileitemaction.cpp:10-12,126-128,145-147`<br>`src/itemactions/setfoldericonitemaction.cpp:15-17,67-69` | `KDirNotify::emitFilesChanged()` after toggling `.hidden` / folder icon | Guarded by `#ifdef QT_DBUS_LIB`. These plugin targets link only `KF6::KIOCore/KIOWidgets` (`src/itemactions/CMakeLists.txt:23-27,35-39`); `QT_DBUS_LIB` arrives *transitively* because `KF6KIOCore` `PUBLIC`-links `Qt6::DBus` (`kio/src/core/CMakeLists.txt:206-208`) — **only when KIO is built with D-Bus**. With KIO `USE_DBUS=OFF` the guard is correctly false. **No build break either way** (I checked this specifically; it is the one place a mixed configuration could have bitten). |

**Verdict for (A): there is no D-Bus *build* blocker in Dolphin** provided `KF6DBusAddons` itself builds on macOS
(Dolphin's own CI requires it on `macOS/Qt6` — `.kde-ci.yml:5,11`). The damage is entirely behavioural, and only
two items matter: **session restore** and **single-instance/`FileManager1`**.

---

### B) `KDBusService` in `main.cpp` and its macOS-native replacement

`KDBusService` provides four things, all of which macOS provides natively and better:

| KDBusService feature | Where used | macOS-native equivalent |
|---|---|---|
| Unique-name registration `org.kde.dolphin-<pid>` | `main.cpp:234` | LaunchServices: one `.app` = one process. Nothing to do. |
| Cross-instance "attach to running window" | `main.cpp:203` → `global.cpp:60` | `QEvent::FileOpen` (Qt's wrapper for `application:openURLs:` / `applicationShouldOpenFile:`), delivered to the already-running process by LaunchServices. Install a `QCoreApplication` event filter in `main.cpp` and route to `DolphinMainWindow::openDirectories()/openFiles()`. |
| `org.freedesktop.FileManager1` (external apps ask the FM to reveal a file) | `dbusinterface.cpp` | Two halves: (a) *being* the handler → `Info.plist` `CFBundleDocumentTypes` with `public.folder` + `LSHandlerRank`, plus an `NSAppleEventManager` handler or a private URL scheme for the "reveal & select" case (there is no Apple standard for *receiving* reveal-select); (b) *calling* a file manager → `NSWorkspace -activateFileViewerSelectingURLs:`. |
| `--daemon` background instance + `.service` bus-activation file (`CMakeLists.txt:206-220`, `plasma-dolphin.service.in`) | `main.cpp:171-191` | Delete. macOS has no analogue and does not need one; `LSUIElement=1` would only be relevant if we wanted a Dock-less agent, which we do not. |

**How much of `main.cpp` must change:** modest. The `--daemon` block (`main.cpp:171-191`, 21 lines) and the
`--daemon` option registration (`main.cpp:144-145`) are deleted outright, along with `dbusinterface.{cpp,h}`
(~120 lines, dropped from `src/CMakeLists.txt:513-517`). Lines `24, 37-38, 194-207, 229-235` get gated behind a
new `DOLPHIN_WITH_DBUS` (default `OFF` on Apple, mirroring KIO). The genuinely *new* code is small:
an event filter for `QEvent::FileOpen` and a replacement for the `instancesCount` heuristic at `main.cpp:249-251`
(with a single process this is trivially "am I the first window?"). Note also `add_executable(dolphin)` at
`src/CMakeLists.txt:516` has **no `MACOSX_BUNDLE`** and the tree contains zero `Info.plist` — bundle plumbing is
net-new regardless of D-Bus.

One trap: `Dolphin::openNewWindow()` (`global.cpp:42-58`) shells out via `KIO::ApplicationLauncherJob` with the
literal command `"dolphin --new-window"`. Inside a `.app` that resolves to nothing. This is not a D-Bus issue but
it lives in the same code path and must be replaced with an in-process `new DolphinMainWindow`.

---

### C) KIO 6.x: how much actually hard-requires D-Bus at runtime

#### C.1 The `USE_DBUS` gate — exactly what it disables

`upstream/kio/CMakeLists.txt:105-119`:

```cmake
# shall we use DBus?
# enabled per default on Linux & BSD systems
set(USE_DBUS_DEFAULT OFF)
if(UNIX AND NOT APPLE AND NOT ANDROID AND NOT HAIKU)
    set(USE_DBUS_DEFAULT ON)
endif()
option(USE_DBUS "Build components using DBus" ${USE_DBUS_DEFAULT})
if(USE_DBUS)
    find_package(KF6DBusAddons ...); find_package(Qt6 ... DBus)
    set(HAVE_QTDBUS ${Qt6DBus_FOUND})
    add_definitions(-DWITH_QTDBUS)
endif()
```

**On Apple the default is `OFF`.** KIO's own CI confirms this is the tested configuration: `kio/.kde-ci.yml:27-31`
requires `kdbusaddons` **only on `Linux` and `FreeBSD`**, not macOS. Upstream's oss-fuzz script builds the whole
stack this way — `kio-extras/thumbnail/autotests/ossfuzz/build_fuzzers.sh:133,143,208` pass `-DUSE_DBUS=OFF` to
`kconfig`, `kcoreaddons` and `kio`.

What `USE_DBUS=OFF` removes:

| Removed | Gate | Consequence |
|---|---|---|
| `kiod` daemon, `kssld` | `src/CMakeLists.txt:8-11` | No SSL cert-exception store (`ksslcertificatemanager.cpp:402-428` → `setRule/clearRule` become no-ops, `rule()` returns an empty rule at line 424-431). |
| `kpasswdserver`, `kioexec` | `src/CMakeLists.txt:23-26` | **No credential prompts** (see C.3); no "edit remote file in external app". |
| `kdirnotify.cpp`, `kpasswdserver{loop,client}.cpp`, **`forwardingworkerbase.cpp`**; `KDirNotify` header not installed | `src/core/CMakeLists.txt:94-103` | See C.4. `forwardingworkerbase.cpp` is **over-gated** — it contains zero D-Bus code (only a doc comment at `forwardingworkerbase.h:70`) yet its header *is* still installed unconditionally at `src/core/CMakeLists.txt:265` ⇒ latent link error for any consumer. |
| `kdynamicjobtracker.cpp`, `FileUndoManager` adaptor, `kuiserver` interface | `src/widgets/CMakeLists.txt:17-21,65-70` | **No job progress UI at all** (see C.5). |
| `dbusactivationrunner.cpp`, systemd scope runners | `src/gui/CMakeLists.txt:34-60` | systemd block is additionally `AND CMAKE_SYSTEM_NAME STREQUAL "Linux"` — already macOS-safe. |
| `remote:/` kded notifier (worker itself still builds) | `src/kioworkers/remote/CMakeLists.txt:1-3` | `remote:/` Places entry (`src/filewidgets/kfileplacesmodel.cpp:286-289`) lists but never auto-refreshes. |

In **kio-extras** (`CMakeLists.txt:55-65`) the same option exists with the same Apple default, and gates away:
`filenamesearch` (`:213`, also excluded on `APPLE` outright), `mtp` (`:217`), **`smb` (`:230`)**, `activities` +
`recentlyused` (`:91-98`). `sftp`, `thumbnail`, `archive`, `fish`, `man`, `nfs`, `info`, `filter` are entirely
D-Bus-clean (grepped: no hits). Note kio-extras is **not CI-built on macOS at all** (`kio-extras/.kde-ci.yml:5`
lists `Linux, FreeBSD, Windows`), even though Dolphin's CI pulls it in on `macOS/Qt6` — so its macOS build is
much less proven than KIO's.

#### C.2 Worker launch — **zero D-Bus**

`grep -i dbus src/core/worker.cpp` → **no matches**. `KIO::Worker::createWorker()`
(`kio/src/core/worker.cpp:419-534`) does:

1. `KProtocolInfo::exec(protocol)` → `QPluginLoader` to resolve the `kf6/kio/kio_<proto>.so` path (`:445-453`);
2. for `file` (and `admin`) with `KIO_ENABLE_WORKER_THREADS != 0`, loads the plugin and runs it in a
   **`WorkerThread` in-process** (`:467-492`);
3. otherwise `Worker::createConnectionServer()` (`:143-154`) → `QLocalServer` on a Unix socket under
   `QStandardPaths::RuntimeLocation` (`src/core/socketconnectionbackend.cpp:108-140`), then
   `QProcess::startDetached()` of the `kioworker` helper (`:504-531`).

klauncher is indeed gone; nothing here needs a bus. Two macOS notes from reading this code:
`KLibexec::kdeFrameworksPaths("libexec/kf6")` + `KDE_INSTALL_FULL_LIBEXECDIR_KF` must resolve *inside* the bundle
(`worker.cpp:508-516`), and the socket path is tight against the 104-byte `sun_path` limit — measured on this
machine: `/var/folders/m1/…/T/runtime-fxlin/dolphinXXXXXX.1.kioworker.socket` = **95 bytes**. It fits, but a
longer username would not.

#### C.3 Credentials — **the one true runtime blocker**

`KIO::SlaveBase::openPasswordDialogV2()`, `kio/src/core/slavebase.cpp:906-935`:

```cpp
#ifdef WITH_QTDBUS
    KPasswdServerClient *passwdServerClient = d->passwdServerClient();
    const int errCode = passwdServerClient->queryAuthInfo(&dlgInfo, errorMessage, windowId, userTimestamp);
    if (errCode == KJob::NoError) { info = dlgInfo; }
    return errCode;
#else
    return KJob::NoError;      // <-- lies: returns success, never touches `info`
#endif
```

`checkCachedAuthentication()` (`slavebase.cpp:1275-1283`) returns `false`; `cacheAuthentication()`
(`slavebase.cpp:1325-1332`) is a no-op. The `#else` branch returning `NoError` **with `info` untouched** is
actively harmful. Concrete failure, traced end to end into kio-extras:

`kio-extras/sftp/kio_sftp.cpp:975-1019` is an unbounded `for (;;)` loop:

```
987:  int errCode = openPasswordDialog(info, errMsg);
988:  if (errCode != 0) { return Result::fail(errCode, QString()); }   // never taken
1008: rc = ssh_userauth_password(mSession, info.username…, info.password…);
1009: if (rc == SSH_AUTH_SUCCESS) break;
1012: if (rc == SSH_AUTH_ERROR)  return fail(ERR_CANNOT_LOGIN);        // only hard errors exit
1017: isFirstLoginAttempt = false; info.password.clear();              // SSH_AUTH_DENIED -> loop forever
```

⇒ Connecting to a password-protected `sftp://` host with `USE_DBUS=OFF` gives an **infinite CPU-burning retry
loop in the worker process**, with Dolphin showing a job that never completes. `smb` has the same shape
(`kio-extras/smb/kio_smb_auth.cpp:62-76`). This must be fixed before any remote protocol is usable.

There is a good template for the fix already in the wire protocol: `SlaveBase::messageBox()`
(`slavebase.cpp:942-958`) does `send(INF_MESSAGEBOX, data)` + `waitForAnswer(CMD_MESSAGEBOXANSWER, …)`. An
`INF_AUTHREQUEST` / `CMD_AUTHANSWER` pair added to `src/core/commands_p.h:20-55` (which today has only
`CMD_MESSAGEBOXANSWER`, `CMD_RESUMEANSWER`, `CMD_SSLERRORANSWER`) plus a `KJobUiDelegateExtension` hook would put
the `KPasswordDialog` in the Dolphin process and, ideally, back it with the macOS Keychain instead of KWallet
(which is already optional — `src/kpasswdserver/CMakeLists.txt:1-12`).

#### C.4 `KDirNotify` — cross-process *and* intra-process invalidation

`org.kde.KDirNotify` is subscribed with **empty service and empty path** (`kio/src/core/kdirnotify.h:52-55`,
used at `kio/src/core/kcoredirlister.cpp:71-78`) — i.e. "listen to this signal from *any* process, including
myself". That last part matters: the signal loops back through the bus to the *emitting* process, so on Linux
KDirNotify is how a `KCoreDirLister` learns about changes even when the job that caused them ran in the same
process. Emit sites (19 total):

| Emitter | Process |
|---|---|
| `core/copyjob.cpp:2243,2249,1672`, `core/deletejob.cpp:501`, `core/simplejob.cpp:200-216`, `core/restorejob.cpp:79`, `filewidgets/knewfilemenu.cpp:1704`, `widgets/paste.cpp:95`, `widgets/fileundomanager.cpp:664`, `widgets/kpropertiesdialogbuiltin_p.cpp:1068` | **In the app process** |
| `kioworkers/file/file.cpp` | In-process by default (`worker.cpp:476` runs `file` in a `WorkerThread`) |
| `kioworkers/trash/kio_trash.cpp:177`, `trashimpl.cpp:441,869` | Out-of-process worker |
| `kioworkers/remote/kdedmodule/remotedirnotify.cpp` | Not built without D-Bus |

**≈90 % of emissions are same-process.** That is the key strategic fact: an in-process signal hub reproduces
almost all of KDirNotify's value with no IPC whatsoever.

Upstream has already written *partial* fallbacks for the remainder:
- `core/copyjob.cpp:2254-2263` and `core/deletejob.cpp:497-510`: `#ifndef WITH_QTDBUS` → `KCoreDirLister().updateDirectory(QUrl("trash:/"))` when a trash URL was involved;
- `core/copyjob.cpp:2267-2272` and `core/deletejob.cpp:485-493`: `#ifndef WITH_QTDBUS` → `KDirWatch::self()->setDirty(dir)` in addition to `restartDirScan()`.

What is **still broken** without D-Bus: any *non-local, non-trash* directory (`sftp:`, `smb:`, `fish:`,
`archive:`) will **not refresh** after mkdir / rename / copy / move / delete. `KDirWatch` cannot cover those
(no local inode) and there is no fallback. Dolphin has no compensating manual refresh — `DolphinView` only calls
`m_model->refreshDirectory()` from `loadDirectory(url, reload=true)` (`src/views/dolphinview.cpp:2399-2401`),
i.e. only on an explicit F5.

#### C.5 Job progress / `kuiserver` — no bus needed, but currently no tracker at all

`KIO::getJobTracker()` (`kio/src/core/jobtracker.cpp:14-20`) returns a **dummy** `KJobTrackerInterface` unless
someone calls `setJobTracker()`. The only caller is `KDynamicJobTracker`, installed by a
`Q_CONSTRUCTOR_FUNCTION` at `kio/src/widgets/kdynamicjobtracker.cpp:239-247` — and that entire file is inside
`if (HAVE_QTDBUS)` at `kio/src/widgets/CMakeLists.txt:65-70`.

The irony: `kdynamicjobtracker.cpp:114-118` **already** does the right thing for macOS —

```cpp
// do not try to use kuiserver on Windows/macOS
#if defined(Q_OS_WIN) || defined(Q_OS_MAC)
    useWidgetsFallback();      // plain KWidgetJobTracker, zero D-Bus
    return;
#endif
```

— but the file is never compiled there. **Net effect on macOS today: copy/move/delete jobs run with no progress
dialog, no percentage, and no cancel button.** Fix is trivial and cheap: either move `kdynamicjobtracker.cpp`
out of the `HAVE_QTDBUS` block (its D-Bus parts are already `#if`-guarded internally), or have Dolphin call
`KIO::setJobTracker(new KWidgetJobTracker)` once in `main.cpp`. **No bus is required for job progress.**

#### C.6 Trash and `KDirWatch`

`kio_trash` is **not** gated on D-Bus (`kio/src/kioworkers/trash/CMakeLists.txt:29-59`, linking an empty
`${DBUS_LIB}`), and it already has real macOS support — `trashimpl.cpp:878-885` compiles a
`DiskArbitration`/`CoreFoundation` `idForMountPoint()` under `#ifdef Q_OS_OSX`, matched by
`target_link_libraries(kio_trash "-framework DiskArbitration -framework CoreFoundation")` at
`CMakeLists.txt:60-62`. Its three D-Bus uses are all `#ifdef WITH_QTDBUS`-guarded KDirNotify emissions
(`kio_trash.cpp:177`, `trashimpl.cpp:441,869`), and since `kio_trash` runs **out of process**, these are exactly
the ones an in-process shim cannot cover — hence the explicit `trash:/` fallbacks noted in C.4. `KDirWatch`
itself lives in KCoreAddons (not checked out) and is used unconditionally by
`kio/src/core/kcoredirlister.cpp:67-69`; whether it survives `kcoreaddons -DUSE_DBUS=OFF` and what backend it
picks on macOS is an **open question** below.

#### C.7 Blocking-call audit (the "25-second UI stall" question)

I looked for every synchronous D-Bus call reachable from Dolphin. **On the no-bus path there are none that can
stall**: `QDBusConnection::sessionBus()` is not connected, so `call()` / `waitForFinished()` fail
immediately rather than waiting out `DBUS_TIMEOUT_USE_DEFAULT` (25 s). The blocking calls only become a hazard
under Option 1 (bundled bus), where a registered-but-unresponsive service *can* burn the full timeout:

| Site | Blocking? | Reachable when |
|---|---|---|
| `kio/src/core/desktopexecparser.cpp:407-420` — `kiofuse_iface.mountUrl()` then `request.reply.waitForFinished()` **on the GUI thread** | **Yes, 25 s** | A bus exists and `org.kde.KIOFuse` is name-activatable but hangs. Highest-risk site found. |
| `dolphin/src/views/draganddrophelper.cpp:44-49` — `sessionBus().call()` to Ark | Yes, 25 s | Ark drag-and-drop only; Ark does not exist on macOS. |
| `kio/src/widgets/kdynamicjobtracker.cpp:149-152` — `Introspect` on `/JobViewServer` | Yes, 25 s | **Unreachable on macOS** — short-circuited at line 114-118. |
| `kio/src/core/kpasswdserverclient.cpp:54,92` — `QDBusReply` from `queryAuthInfoAsync` | Yes, 25 s | In the **worker** process, not the UI. Then `KPasswdServerLoop::waitForResult()` (`kpasswdserverloop.cpp:25-30`) `exec()`s with **no timeout at all**, exiting only on `serviceUnregistered` (line 16-18) — an unbounded wait if kpasswdserver hangs rather than dies. |
| `kio-extras/filenamesearch/kio_filenamesearch.cpp:85-86` — `kded.call("loadModule", …)` in the worker ctor | Yes, 25 s | Worker excluded on `APPLE` anyway (`kio-extras/CMakeLists.txt:213`). |
| `dolphin/src/global.cpp:82-83,99-100,123-124` — 3 × `waitForFinished()` | Yes | Only when other Dolphin instances are registered; unreachable with no bus. |

Also noted: `kio/src/core/desktopexecparser.cpp:276-283` `kioexecPath()` ends in
`Q_ASSERT(QFileInfo::exists(kioexec))`, and `kioexec` is **not built** with `USE_DBUS=OFF`
(`kio/src/CMakeLists.txt:23-26`). The `tempFiles` branch at `:386-397` is **outside** the `WITH_QTDBUS` guard, so
opening a temp-file document in an external app aborts in a debug build / silently launches a nonexistent binary
in release.

---

### D) Verdict & strategy

| | **(1) Bundle a private `dbus-daemon`** | **(2) `USE_DBUS=OFF` + `#ifdef` Dolphin** | **(3) In-process stub / QtDBus peer-to-peer** |
|---|---|---|---|
| **How** | Ship Homebrew `dbus` (stable 1.16.2, a `qtbase` dependency already — `brew deps qtbase` lists `dbus`, so QtDBus is present and usable on macOS) inside `Dolphin.app`; spawn `dbus-daemon --session --nofork --print-address` at launch, export `DBUS_SESSION_BUS_ADDRESS` before the first `sessionBus()` call; install `kiod6`/`kpasswdserver6` `.service` files (`kdbusaddons_generate_dbus_service_file` at `kio/src/kpasswdserver/CMakeLists.txt:52`) into a bundle `servicedir`. Build KIO with `-DUSE_DBUS=ON`. | Take the upstream Apple default. Add a `DOLPHIN_WITH_DBUS` option to Dolphin mirroring `kio/CMakeLists.txt:105-119`; guard the ~11 files in the §A table; delete `--daemon` + `dbusinterface.*`. | Keep `USE_DBUS=OFF`. Replace `org::kde::KDirNotify` with a process-local singleton exposing the same six signals; register `KWidgetJobTracker` explicitly; add an in-band auth command to the worker protocol. |
| **Effort** | ~4–6 d to get running; ongoing cost in signing/notarization/relocation of `dbus-daemon` + `libdbus-1` and every kiod plugin. | ~2–3 d of mechanical patching. | ~5–8 d on top of (2): KDirNotify shim ~1 d, job tracker ~0.5 d, auth channel ~3–4 d. |
| **Pros** | Everything upstream expects just works: kpasswdserver, kssld, kioexec, KDirNotify, `FileManager1`, `smb`/`mtp` workers stay buildable. Zero patches to KIO or Dolphin. Excellent for de-risking Phase 1 — isolates the port to UI work. | Zero new runtime infrastructure. **This is the configuration KIO's own CI builds on macOS** (`kio/.kde-ci.yml:27-31`) and that upstream fuzzes (`build_fuzzers.sh:208`). Nothing to sign, sandbox, or supervise. Patches are small and upstreamable. | Same deployment story as (2), and closes (2)'s three real holes. Fixes are *architecturally* right (in-process notification for in-process emitters). |
| **Cons** | A daemon inside a notarized `.app` is a serious liability: hardened-runtime signing of every bundled binary, an extra supervised process to start/reap/crash-handle, `$TMPDIR` socket path length, and it re-opens every 25 s blocking path in §C.7 (notably `desktopexecparser.cpp:418`). Feels wrong on macOS and will be the first thing a reviewer objects to. Also makes `smb`/`mtp` *buildable* but they are still untested on macOS. | Ships today with three known holes: **infinite auth loop** (C.3), **no remote-dir refresh** (C.4), **no progress UI** (C.5). Loses `smb`, `mtp`, `filenamesearch`, SSL exception storage. | Doesn't restore `smb`/`mtp` (those are CMake-gated, not runtime-gated) or `kioexec`. The auth channel is a genuine KIO wire-protocol change → needs upstream buy-in or a carried patch. **QtDBus peer-to-peer is a dead end** for the hard cases: a `QDBusServer` connection has no bus daemon, so `QDBusConnection::interface()` is null, service names don't exist, and the "empty service, empty path" broadcast subscription that `kcoredirlister.cpp:72` relies on is unimplementable. Only the point-to-point kpasswdserver case maps onto it, and a plain in-process call is simpler. |

**Recommendation — Phase 1: Option (2), unmodified.** Configure `kio`, `kio-extras`, `kcoreaddons`, `kconfig`
with the Apple defaults (i.e. pass nothing), add `DOLPHIN_WITH_DBUS=OFF` to Dolphin, patch the ~11 call sites,
delete `--daemon`. This is the *only* configuration with upstream CI coverage on macOS, it needs no new runtime
process, and it gets local-filesystem browsing — the actual Phase 1 goal — working fastest. Explicitly **do not**
bundle `dbus-daemon`: it would let a whole class of Linux-isms survive into the codebase unexamined, and every
one of them would have to be removed again before shipping.

**Recommendation — shipping product: Option (3), i.e. (2) plus the three targeted fixes**, in this order:

1. **Job tracker** (~0.5 d, no risk): `KIO::setJobTracker(new KWidgetJobTracker)` in `main.cpp`, or move
   `kdynamicjobtracker.cpp` out of the `HAVE_QTDBUS` gate in `kio/src/widgets/CMakeLists.txt:65-70` — its macOS
   short-circuit at line 114-118 already does the right thing. Upstreamable as-is.
2. **In-process KDirNotify shim** (~1 d): a singleton with the six `KDirNotify` signals, wired to
   `KCoreDirListerCache` at `kcoredirlister.cpp:71-78` and to the 10 in-process emit sites. Covers ~90 % of
   emissions; keep upstream's existing `trash:/` and `KDirWatch::setDirty()` fallbacks for the out-of-process
   `kio_trash` case.
3. **In-band credential channel** (~3–4 d): `INF_AUTHREQUEST`/`CMD_AUTHANSWER` in `commands_p.h`, modelled on
   `SlaveBase::messageBox()` (`slavebase.cpp:942-958`), backed by macOS Keychain. Until this lands, **`sftp:` and
   any password-protected protocol must be disabled in the UI**, not merely left broken — the current `#else
   return KJob::NoError` produces a hang, not an error dialog.

Additionally: fix the `forwardingworkerbase.cpp` over-gating (`kio/src/core/CMakeLists.txt:94-103` vs `:265`) and
guard the `kioexec` `tempFiles` branch (`desktopexecparser.cpp:386-397`) — both are one-line upstream patches.

The `USE_DBUS` gating in `kio-extras/CMakeLists.txt:55-65` is exactly the hint it appears to be: upstream is
actively maintaining a bus-free build of the KIO stack, the Apple default is already `OFF` everywhere, and the
`#ifndef WITH_QTDBUS` fallbacks in `copyjob.cpp`/`deletejob.cpp` show they are filling the gaps as they find them.
**We should ride that work rather than fight it.**

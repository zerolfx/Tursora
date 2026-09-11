## Solid, devices & volumes on macOS

**Scope.** Every `Solid::` call site in Dolphin, the Solid call sites inside KIO that Dolphin's Places panel is literally built on, the macOS `iokit` backend of KF6 Solid, `KMountPoint`, and the free-space path. Repos are referred to as **dolphin** (`upstream/dolphin`, v26.11.70), **kio** (`upstream/kio`, KF 6.30.0), **solid** (KF6 Solid `master`, commit `9890568` — a shallow clone I made read-only in scratch, *not* in the project tree).

---

### 0. Headline: "no Solid" is not an option, and a macOS backend already exists

Two facts reframe this whole area:

1. **Solid is a hard, unconditional dependency of KIO itself**, not just of Dolphin: `kio/CMakeLists.txt:63` — `find_package(KF6Solid ${KF_DEP_VERSION} REQUIRED) # for kio_trash`, and it is linked into both `KF6::KIOGui` (`kio/src/gui/CMakeLists.txt:100`) and `KF6::KIOFileWidgets` (`kio/src/filewidgets/CMakeLists.txt:108`). Dolphin also requires it directly (`dolphin/CMakeLists.txt:83`, unconditional — no `if(APPLE)` gate anywhere). So **we must build Solid from source on macOS regardless**. The question is only what its backend returns.
2. **KF6 Solid has a real macOS backend.** `solid/CMakeLists.txt:128-130`:
   ```cmake
   elseif (APPLE)
       find_package(IOKit REQUIRED)
       add_device_backend(iokit)
   ```
   28 source files in `solid/src/solid/devices/backends/iokit/`, linking `${IOKIT_LIBRARY}` and `-framework DiskArbitration` (`solid/src/solid/devices/backends/iokit/CMakeLists.txt:17`). It is registered like any other backend at `solid/src/solid/devices/managerbase.cpp:71-73`.

Also good news: **Solid does not need D-Bus on macOS.** `solid/CMakeLists.txt:30-34` sets `USE_DBUS_DEFAULT OFF` unless `UNIX AND NOT APPLE`, with the comment that "Windows & Mac have backends that don't use DBus". The `udisks2`/`upower`/`kdeconnect` backends are Linux-only (`solid/CMakeLists.txt:106-127`).

The bad news is what the iokit backend *doesn't* do — see §2.

---

### 1. Every Solid use, and what breaks without it

#### 1a. Dolphin (`upstream/dolphin`)

| Site | Solid API | UI it drives | Degradation if Solid returns nothing |
|---|---|---|---|
| `src/panels/places/placespanel.cpp:189` | `KFilePlacesModel::deviceForIndex()` → `Solid::Device` | Context menu: `device.isValid()` decides whether custom actions are appended (`:194-205`) | Falls into the `!url.isValid() && !device.isValid()` branch → custom actions added. Harmless. |
| `src/panels/places/placespanel.cpp:211-222` | `Solid::StorageAccess::filePath()`, `disconnect(teardownRequested)` | "Safely Remove"/"Unmount" flow: emits `storageTearDownRequested(filePath)` | `storageAccess == nullptr` → early `return` at `:212-214`. Menu item is never offered (see KIO row below), so unreachable. |
| `src/panels/places/placespanel.cpp:228-231` | `Solid::StorageAccess::teardownRequested` | Reacts when *something else* (e.g. Plasma) initiates unmount | Never fires on macOS. Dead code, no harm. |
| `src/panels/places/placespanel.cpp:233-243` | `Solid::ErrorType` in `slotTearDownDone` | Emits `storageTearDownSuccessful` → main window closes views on the ejected volume (`dolphinmainwindow.cpp:1741-1760`) | Never fires. See blocker `iokit-teardown-noop`. |
| `src/panels/places/placespanel.cpp:260-266`, `:273-278` | `connect/disconnect teardownRequested` per row | bookkeeping | No-op. |
| `src/panels/places/placespanel.h:17,20,65` | `#include <Solid/SolidNamespace>` for `Solid::ErrorType` | — | **Build-level coupling only**; trivially replaceable with our own enum. |
| `src/statusbar/mountpointobservercache.cpp:47-55` | `Solid::Device::storageAccessFromPath()` → `StorageAccess::filePath()` | Chooses the **cache key** for the free-space observer, so all dirs on one mount share one observer | Falls to `cachedObserverUrl = url` (`:54`). **Numbers stay correct** — see §3b. Cost: one `MountPointObserver` (and one 60 s poll, `:70`) per visited directory instead of per mount. |
| `src/trash/dolphintrash.cpp:40-55` | `Solid::DeviceNotifier::deviceAdded/deviceRemoved`, `StorageAccess::accessibilityChanged` | Re-lists `trash:/` when a removable volume with a per-volume trash appears/disappears | Signals never fire → `trash:/` and the trash icon's empty/full state go stale until the user refreshes. Minor. |
| `src/userfeedback/placesdatasource.cpp:42-70` | `Solid::Device::listFromType(NetworkShare)`, `Solid::NetworkShare::type()` | Telemetry counters `hasSSHFSMount` / `hasSambaShare` / `hasNfsShare` | **Always all-false on macOS** — the iokit backend has no `NetworkShare` support at all (`grep -rn NetworkShare solid/src/solid/devices/backends/iokit/` → zero hits) and the `fstab` backend, which *is* the NetworkShare provider, is **not** enabled on APPLE (`solid/CMakeLists.txt:128-130` — only `iokit`, no `fstab`). |

> **Free win:** `placesdatasource.cpp` is only compiled when `KF6UserFeedback` is found (`dolphin/CMakeLists.txt:96-105` → `HAVE_KUSERFEEDBACK`). Don't build UserFeedback for the macOS port and 1 of Dolphin's 4 Solid sites disappears with zero code changes.

#### 1b. KIO — this is where the Places device list actually lives

Dolphin's `PlacesPanel` *is* a `KFilePlacesView` over `KFilePlacesModel`. All device enumeration is KIO's:

| Site (repo: kio) | What it does |
|---|---|
| `src/filewidgets/kfileplacesmodel.cpp:438-459` | The Solid predicate that defines the Devices section: `StorageVolume.ignored == false AND [StorageVolume.usage == 'FileSystem' OR ... 'Encrypted']` OR floppy OR audio CD OR `StorageAccess.ignored == false`, plus `PortableMediaPlayer.supportedProtocols == 'mtp'/'afc'/'kdeconnect'` when those protocols exist. |
| `src/filewidgets/kfileplacesmodel.cpp:758-793` | `initDeviceList()`: `Solid::Device::listFromQuery(predicate)` + `DeviceNotifier::deviceAdded/deviceRemoved` → hotplug. |
| `src/filewidgets/kfileplacesmodel.cpp:1395-1465` | `teardownActionForIndex()` / `ejectActionForIndex()` — the "&Safely Remove" / "&Unmount" / "&Release" / "&Eject" menu items. Both return `nullptr` when there is no `Solid::StorageAccess` / `Solid::OpticalDisc`. |
| `src/filewidgets/kfileplacesmodel.cpp:1467-1527` | `requestTeardown()` / `requestEject()` / `requestSetup()` — call `access->teardown()`, `drive->eject()`, `access->setup()`. |
| `src/filewidgets/kfileplacesitem.cpp:526-596` | Per-row: `StorageAccess`, `StorageVolume`, `Block`, `OpticalDisc`, `PortableMediaPlayer`, `NetworkShare`, `StorageDrive`, `OpticalDrive` + all the `setupRequested/Done`, `teardownRequested/Done`, `accessibilityChanged`, `ejectRequested/Done` connections that drive the "Unmounting…" spinner. |
| `src/filewidgets/kfileplacesitem.cpp:469-484` | `createDeviceBookmark()` persists `UDI` + `uuid` metadata into `user-places.xbel`. |
| `src/gui/filepreviewjob.cpp:547-557` | `Solid::Device::storageAccessFromPath()` + `StorageAccess::isEncrypted()` → thumbnail **cache** policy. |

`kio/src/gui/gpudetection.cpp:114-133` mentions "Solid" but is **not** the Solid library — it is a D-Bus call to `org.kde.Solid.PowerManagement`, wrapped in `#ifdef WITH_QTDBUS` and falling through to `GpuCheck::Absent`. Non-issue on macOS.

`kio_trash` does **not** use Solid despite the comment at `kio/CMakeLists.txt:63` (`grep -rln "Solid/" kio/src/` → only `src/gui/filepreviewjob.cpp` and `src/gui/gpudetection.cpp`). It uses `KMountPoint` instead (`src/kioworkers/trash/trashimpl.cpp:56, 934, 1021`).

**Net degradation if the device list is empty:** the Places panel keeps everything bookmark-driven — Home, Desktop, Documents, Downloads, Music, Pictures, Videos, Trash, Network, Remote (`kio/src/filewidgets/kfileplacesmodel.cpp:340-414`; none of that touches Solid). The **Devices** and **Removable Devices** groups are simply empty, and there is no eject/unmount UI. Nothing crashes, nothing is disabled elsewhere.

---

### 2. The macOS Solid backend: what it actually implements

Backend inventory (from the Solid repo tree, `src/solid/devices/backends/`): `fakehw`, `fstab`, `imobile`, `iokit`, `kdeconnect`, `shared`, `udev`, `udisks2`, `upower`, `win`. On APPLE, exactly **`fakehw` + `iokit`** are compiled (`solid/CMakeLists.txt:104-152`).

`IOKitManager` (`solid/src/solid/devices/backends/iokit/iokitmanager.cpp`) advertises 11 interfaces (`:113-124`) but only maps 5 enum values to IOKit classes (`:69-93`): `Processor→AppleACPICPU`, `Battery→AppleSmartBattery`, `StorageAccess/StorageDrive/StorageVolume→IOMedia`, `OpticalDrive/OpticalDisc→IOCDMedia`; everything else returns `0` → empty result.

| Capability | Status | Evidence |
|---|---|---|
| Enumerate block devices / volumes | **Implemented** — `IORegistryCreateIterator` / `IOServiceGetMatchingServices("IOMedia")` | `iokitmanager.cpp:149-204` |
| Volume label / fs type / UUID / size / vendor / product | **Implemented** via DiskArbitration `DADiskCopyDescription` | `iokitvolume.cpp:53-91`, `dadictionary.cpp:37-46` |
| Mount point (`StorageAccess::filePath`) | **Implemented** via `kDADiskDescriptionVolumePathKey` | `iokitstorageaccess.cpp:40-58` |
| `isRemovable` / `isHotpluggable` / bus / drive type | **Implemented** (heuristic — string-matches the IORegistry path for `/SATA@`, `/SDXC@`, `/IOUSBInterface@`) | `iokitstorage.cpp:31-84` |
| **Unmount / "Safely Remove"** | ❌ **`teardown()` is `return false;` with a `// TODO?` comment** | `iokitstorage`**`access`**`.cpp:84-88` |
| **Mount (`setup()`)** | ❌ **`return false;` `// TODO?`** | `iokitstorageaccess.cpp:78-82` |
| `isEncrypted()` | ❌ hardcoded `return false; // TODO: Implementation left for IOKit developer` | `iokitstorageaccess.cpp:72-76` |
| **Hotplug (`deviceAdded`/`deviceRemoved`)** | ❌ **never emitted.** The ctor creates an `IONotificationPortRef` and adds a run-loop source but **never calls `IOServiceAddMatchingNotification`** — `grep -rn "deviceAdded\|deviceRemoved\|IOServiceAddMatchingNotification" backends/iokit/` returns **zero hits**. | `iokitmanager.cpp:99-111` |
| **`accessibilityChanged`** | ❌ effectively dead. `IOKitDevice::propertyChanged` is *declared* (`iokitdevice.h:52`) but **never emitted anywhere**. The one code path that would fire it constructs a **temporary** and signals from it: `IOKitStorageAccess(m_device).onPropertyChanged(...)` — nobody is connected to that temporary. | `iokitstorageaccess.cpp:53`; `iokitstorageaccess.cpp:90-97` |
| Optical eject | Implemented, but the DiskArbitration path is **`#ifdef EJECT_USING_DISKARBITRATION` and that macro is defined nowhere in the repo**. The live path is a **blocking `QProcess::execute("hdiutil detach …")` on the calling (GUI) thread**. | `iokitopticaldrive.cpp:320-341`; `grep -rn EJECT_USING_DISKARBITRATION solid/` → only the 5 `#ifdef`/`#endif` lines |
| `udiPrefix()` | Returns `QString()` with `// FIXME: We should probably use a prefix there... has to be tested on Mac` | `iokitmanager.cpp:139-142` |
| NetworkShare (SMB/NFS mounts in `/Volumes`) | ❌ not implemented; `fstab` backend not enabled on APPLE | `solid/CMakeLists.txt:128-130` |
| PortableMediaPlayer / Camera (MTP, iOS) | ❌ `typeToName()` returns `0` | `iokitmanager.cpp:69-93` |

**Is it maintained?** Partially. `git log -- src/solid/devices/backends/iokit` shows real macOS work: `8024b29 (2023-02-10) Fix IORegistryEntryGetPath failed on Apple Silicon`, `f22d566 (2023-10-06) backends/iokit: port to Qt 6`, `fde3c21 (2026-01-15) Fix macOS build: Replace make_unique with explicit new…`. **But it is not built in KDE CI**: `solid/.gitlab-ci.yml` includes only `linux-qt6`, `linux-qt6-next`, `android-qt6`, `freebsd-qt6`, `windows-qt6`, `alpine-qt6` templates, and `solid/.kde-ci.yml` has `require-passing-tests-on: ['Linux', 'FreeBSD', 'Windows']`. Assume it compiles *mostly* and budget for local fixes.

**Predicted end-user behaviour on Apple Silicon / macOS 26 (unverified — see open questions):** Places shows *some* device rows for mounted volumes (the predicate's `StorageVolume.ignored == false AND usage == 'FileSystem'` is satisfiable — `IOKitVolume::isIgnored()` returns `Open == false` at `iokitvolume.cpp:31-38`, `usage()` returns `FileSystem` for anything that isn't `CD_DA` or a `partition_scheme` at `:40-51`), **but the list never updates on plug/unplug, and clicking "Safely Remove" is a silent no-op**.

That last one is worth spelling out, because the failure is *silent, not visible*: `KFilePlacesModel::requestTeardown()` puts the row into `d->teardownInProgress` and calls `access->teardown()` (`kio/src/filewidgets/kfileplacesmodel.cpp:1472-1481`), which returns `false` and emits nothing. `KFilePlacesItem` only flips its spinner on `teardownRequested`/`teardownDone` (`kio/src/filewidgets/kfileplacesitem.cpp:563-570`), neither of which arrives — so the menu item stays enabled and reads "&Safely Remove", the volume stays mounted, no error is shown, and Dolphin's `PlacesPanel::slotTearDownDone` (`dolphin/src/panels/places/placespanel.cpp:233-243`) never runs.

---

### 3. KIO's own volume paths

#### 3a. `KMountPoint` — works on macOS, via `getmntinfo`

`kio/src/core/kmountpoint.cpp` has three branches. Which one macOS takes is decided by `kio/src/core/ConfigureChecks.cmake`:

| Config var | macOS value | Why |
|---|---|---|
| `HAVE_GETMNTINFO` | **1** | `check_function_exists(getmntinfo …)` (`ConfigureChecks.cmake:11`). I verified by compiling CMake's exact probe (`char getmntinfo(void);` + link) with the CLT toolchain — it links. Declared at `MacOSX.sdk/usr/include/sys/mount.h:451`. |
| `GETMNTINFO_USES_STATVFS` | **0** | The probe at `ConfigureChecks.cmake:18-26` needs `getmntinfo(struct statvfs**, int)`; macOS has no such overload (`sys/statvfs.h` doesn't declare `getmntinfo`). → the code uses `struct statfs` (`kmountpoint.cpp:376`). |
| `HAVE_SYS_MOUNT_H`, `HAVE_SYS_PARAM_H`, `HAVE_FSTAB_H` | **1, 1, 1** | headers present in the SDK; `fstab.h:55` defines `FSTAB "/etc/fstab"` and `:78` declares `getfsfile()`. |
| `HAVE_LIB_MOUNT` | **0** | `LibMount` is only searched `if (CMAKE_SYSTEM_NAME MATCHES Linux)` (`kio/CMakeLists.txt` / `solid/CMakeLists.txt:79-84`). |
| `HAVE_STATX*` | **0** | gated on `LIBC_IS_GLIBC` (`ConfigureChecks.cmake:28-82`). |
| `MNTOPT_NAMES` | **not defined** (FreeBSD-only) | `grep -c MNTOPT_NAMES sys/mount.h` → 0. |

So on macOS:

* **`KMountPoint::currentMountPoints()` → the `HAVE_GETMNTINFO` branch, `kmountpoint.cpp:371-408`.** Calls `getmntinfo(&mounted, MNT_NOWAIT)` and fills `mountedFrom = f_mntfromname`, `mountPoint = f_mntonname`, `mountType = f_fstypename`, plus `QT_LSTAT` for `deviceId`. **This works and is correct.** Mount options come from `getfsfile()` (`:396-399`) or, failing that, the hex fallback `translateMountOptions` at `:209-212` — i.e. `mountOptions()` on macOS returns things like `"0x1000"`, not names. Only `placesdatasource.cpp` and `terminalpanel.cpp` in Dolphin touch mount options-adjacent APIs, so this is cosmetic.
* **`KMountPoint::possibleMountPoints()` → the `#elif HAVE_FSTAB_H` branch, `kmountpoint.cpp:294-339`** — parses `/etc/fstab`, which normally does not exist on macOS → `f.open()` fails → **empty list**. Correct-by-accident (macOS has no "known but unmounted" concept in fstab). Nothing in Dolphin calls it.
* **`KMountPoint::currentMountPointForUniqueId()` always returns null on macOS** (`kmountpoint.cpp:598-611`: the body is inside `#if HAVE_STATX_MNT_ID_UNIQUE`, `#else Q_UNUSED(mountId)`). Consequence at `kio/src/gui/filepreviewjob.cpp:239-242`: falls back to the blocking `KFileItem::isSlow()`. Correct but slower.
* **`KMountPoint::currentMountPointForPath()` re-reads the whole mount table on every call** on macOS (`kmountpoint.cpp:730-741` — the `statx`+`QCache` fast path is `#if HAVE_STATX_MNT_ID_UNIQUE`). It's called per-directory-entry in `kio/src/kioworkers/file/file_unix.cpp:96` (`isOnCifsMount`) — though only 10 mounts on a stock Mac, so `getmntinfo` is cheap. Flagging as a watch item, not a blocker.

**macOS-specific noise:** `getmntinfo` on this machine returns 10 mounts, 7 of which are `nobrowse` APFS system volumes (`/System/Volumes/{VM,Preboot,Update,xarts,iSCPreboot,Hardware,Data}`). None of `fstype == "apfs"` is in `isPseudoFs()`'s list (`kmountpoint.cpp:83-150`), so all 7 are returned as ordinary mounts. `kio_trash`'s `scanTrashDirectories()` (`kio/src/kioworkers/trash/trashimpl.cpp:1019-1054`) iterates exactly that list and will probe each for a trash dir. Also note `isNetfs()` (`kmountpoint.cpp:61-81`) knows `smbfs`/`nfs` (good — that's what macOS reports) but **not** `afpfs` or `webdav`.

#### 3b. `KDiskFreeSpaceInfo` no longer exists — and free space does not depend on Solid

`grep -rn KDiskFreeSpaceInfo` over the whole KIO checkout: **zero hits**. It is gone in KF6; there is nothing to port. The live path is:

```
DolphinStatusBar → StatusBarSpaceInfo → SpaceInfoObserver (dolphin/src/statusbar/spaceinfoobserver.cpp:43)
  → MountPointObserver::update()  (dolphin/src/statusbar/mountpointobserver.cpp:40)
    → KIO::fileSystemFreeSpace(url)
      → FileProtocol::fileSystemFreeSpace (kio/src/kioworkers/file/file.cpp:953-969)
        → QStorageInfo::bytesTotal() / bytesAvailable()
```

`QStorageInfo` is pure Qt and works fine on macOS. **The status-bar numbers are Solid-independent.** Solid appears in this stack in exactly one place — picking the observer's cache key (`dolphin/src/statusbar/mountpointobservercache.cpp:47`) — and the fallback at `:51-55` is already correct. This is the cheapest Solid removal in the codebase.

---

### 4. Proposed macOS replacement design

#### 4.1 The adapter

New Objective-C++ component in the macOS shell layer, e.g. `src/platform/mac/dolphinvolumemanager.{h,mm}`. Pure Qt types at the boundary so shared Dolphin code never sees Cocoa.

```cpp
// Plain value type — no Solid, no CF, no Obj-C in the header.
struct DolphinVolume {
    QString id;          // stable identity: NSURLVolumeUUIDStringKey, else BSD name
    QString name;        // NSURLVolumeLocalizedNameKey
    QString mountPath;   // "/Volumes/Backup"
    QString bsdName;     // "disk4s2"
    QString fsType;      // "apfs" | "exfat" | "smbfs" | "nfs" | ...
    QString iconName;    // mapped to a Breeze/KDE icon name for KFilePlacesItem
    bool isInternal = false, isRemovable = false, isEjectable = false;
    bool isBrowsable = true, isNetwork = false, isReadOnly = false, isEncrypted = false;
    quint64 totalBytes = 0, availableBytes = 0;
};

class DolphinVolumeManager : public QObject {
    Q_OBJECT
public:
    static DolphinVolumeManager *instance();

    QList<DolphinVolume> volumes() const;                              // cached; refreshed by notifications
    std::optional<DolphinVolume> volumeForPath(const QString &) const; // longest-prefix over cache — O(n), no syscall
    bool canUnmount(const QString &volumeId) const;                    // !isInternal || isEjectable
    bool canEject(const QString &volumeId) const;                      // isEjectable

public Q_SLOTS:
    void requestUnmount(const QString &volumeId);   // async, never blocks the GUI thread
    void requestEject(const QString &volumeId);     // async
    void requestMount(const QString &volumeId);     // async (present-but-unmounted volumes)
    void refresh();

Q_SIGNALS:
    void volumeAdded(const DolphinVolume &);
    void volumeRemoved(const QString &volumeId);
    void volumeChanged(const DolphinVolume &);      // rename, remount, capacity change
    void unmountFinished(const QString &volumeId, bool ok, const QString &errorText);
    void ejectFinished(const QString &volumeId, bool ok, const QString &errorText);
};
```

**Implementation, with the exact APIs (all verified present in `MacOSX.sdk`):**

| Concern | API | Note |
|---|---|---|
| Enumeration | `-[NSFileManager mountedVolumeURLsIncludingResourceValuesForKeys:options:]` (`Foundation/NSFileManager.h:104`) with `NSVolumeEnumerationSkipHiddenVolumes` (`NSFileManager.h:33`) | ⚠️ **Do not use `-[NSWorkspace mountedLocalVolumePaths]` as the brief suggests — it is `API_DEPRECATED(…, macos(10.0,10.11))`** (`AppKit/NSWorkspace.h:433`), as is `mountedRemovableMedia` (`:436`). `SkipHiddenVolumes` is precisely what filters out the `/System/Volumes/Preboot`-class noise that `getmntinfo` returns (§3a). |
| Per-volume properties | `NSURLVolumeLocalizedNameKey`, `NSURLVolumeUUIDStringKey` (`NSURL.h:342`), `NSURLVolumeIsRemovableKey` (`:335`), `NSURLVolumeIsEjectableKey` (`:334`), `NSURLVolumeIsInternalKey` (`:336`), `NSURLVolumeIsBrowsableKey` (`:332`), `NSURLVolumeIsLocalKey`, `NSURLVolumeIsReadOnlyKey`, `NSURLVolumeTotalCapacityKey`, `NSURLVolumeAvailableCapacityKey`, `NSURLVolumeLocalizedFormatDescriptionKey` | One `getResourceValues:` batch per volume. |
| Change notifications | `[[NSWorkspace sharedWorkspace] notificationCenter]` + `NSWorkspaceDidMountNotification` / `NSWorkspaceWillUnmountNotification` / `NSWorkspaceDidUnmountNotification` (`NSWorkspace.h:310-312`) / `NSWorkspaceDidRenameVolumeNotification` (`:316`); `userInfo[@"NSDevicePath"]` | **This is the piece Solid's iokit backend is missing entirely.** |
| Unmount + eject | `-[NSWorkspace unmountAndEjectDeviceAtURL:error:]` (`NSWorkspace.h:105`, 10.6+, **not** deprecated) | Gives the system's polite "the disk is in use by …" flow for free. Use the path-taking `unmountAndEjectDeviceAtPath:` (`:102`) never — deprecated. |
| Fallback / fine-grained | `DiskArbitration`: `DASessionCreate`, `DADiskCreateFromVolumePath` (`DADisk.h:143`), `DADiskCopyDescription`, `DADiskUnmount(kDADiskUnmountOptionWhole)`, `DADiskEject`, `DARegisterDiskAppearedCallback`/`DisappearedCallback`/`DescriptionChangedCallback` (`DiskArbitration.h:186/233/210`) | Needed for BSD name, `kDADiskDescriptionVolumeNetworkKey`, whole-drive eject of a multi-partition stick. **Bind the session with `DASessionSetDispatchQueue(session, dispatch_get_main_queue())`** — never the synchronous `CFRunLoopRunInMode` spin that Solid's `iokitopticaldrive.cpp:134-138` does. |

#### 4.2 Where it plugs into existing code

Four seams, in ascending order of cost:

1. **Status bar — do it in Phase 1, ~10 lines.** `dolphin/src/statusbar/mountpointobservercache.cpp:47-55`: drop `Solid::Device::storageAccessFromPath()` for `KMountPoint::currentMountPointForPath(path)->mountPoint()`. That is **portable** (works on Linux too, and is arguably better there — `kmountpoint.cpp:730-741` has a statx-backed cache on Linux that Solid's linear scan does not), removes the last Solid reference from the status-bar path, and avoids the `storageAccessFromPath` cost described below. Optionally later swap in `DolphinVolumeManager::volumeForPath()`.
2. **Trash refresh — ~15 lines.** `dolphin/src/trash/dolphintrash.cpp:40-55`: replace `Solid::DeviceNotifier::deviceAdded/deviceRemoved` + `accessibilityChanged` with `DolphinVolumeManager::volumeAdded/volumeRemoved/volumeChanged` → same `m_trashDirLister->updateDirectory(QUrl("trash:/"))`.
3. **`PlacesPanel` — ~40 lines.** `dolphin/src/panels/places/placespanel.{h,cpp}` only ever needs `filePath()` and a `teardownRequested`-equivalent. Replace `Solid::StorageAccess*` with `QString volumeId`, and `Solid::ErrorType` (`placespanel.h:17,65`) with a local enum. Nothing else in Dolphin's Solid surface survives.
4. **The Places device list — the real work, Phase 3.** Solid is welded into `KFilePlacesItem`/`KFilePlacesModel`, not injected. The clean, upstreamable shape is a `KFilePlacesDeviceSource` seam inside `kio/src/filewidgets/` with a Solid implementation and a macOS implementation selected by `#ifdef Q_OS_MACOS`, exposing roughly eight things — `devices()`, `deviceAdded/deviceRemoved/deviceChanged`, and per-device `displayName/iconName/url/tooltip/accessibility/isRemovable`, `teardown()/eject()/setup()` with `…Requested/…Done` signals. The precise call sites to hoist are the ones tabulated in §1b (`kfileplacesmodel.cpp:438-459, 758-793, 1395-1527`; `kfileplacesitem.cpp:469-484, 526-596`) — the fact that they are this few and this localised is what makes the seam tractable. Carry it as a patch in `patches/` against a pinned KIO tag.

**Which path for Phase 2?** Two options, and they are not exclusive:
* **(A) Fix Solid's iokit backend** — add `IOServiceAddMatchingNotification` for appear/disappear, implement `IOKitStorageAccess::setup()/teardown()` on `DADiskMountWithArguments`/`DADiskUnmount` with async callbacks emitting `setupDone`/`teardownDone`, and actually emit `IOKitDevice::propertyChanged`. Estimate **~250-400 LOC**, all inside `solid/src/solid/devices/backends/iokit/`, genuinely upstreamable, and it makes *unmodified* KIO+Dolphin work. **This is the higher-leverage move.**
* **(B) Build `DolphinVolumeManager` and the `KFilePlacesDeviceSource` seam** — more code, more patch surface against KIO, but gives native `unmountAndEjectDeviceAtURL:` semantics, native volume names/icons, and correctly skips hidden system volumes.

Recommendation: **(A) for Phase 2 to get a working device list + eject; (B) in Phase 3** for Finder-quality behaviour, with (A) left upstream as a good-citizen contribution.

---

### 5. What MVP loses if Solid is effectively absent, and is that OK for Phase 1

To be precise, "Solid absent" cannot mean "not built" (§0) — it means "iokit backend built but returning an empty/inert device list". In that state:

| Lost | Severity |
|---|---|
| Places **Devices** / **Removable Devices** sections are empty — no USB sticks, no external SSDs, no SD cards | **The single most visible regression vs Finder.** |
| No **Eject / Safely Remove / Unmount** anywhere (`kio/src/filewidgets/kfileplacesmodel.cpp:1395-1465` return `nullptr`) | High, but users can eject from Finder/menu bar. |
| No hotplug: plugging a drive does not update Places without a restart | High (and this is the state even *with* today's iokit backend). |
| `trash:/` doesn't auto-refresh on volume plug/unplug (`dolphin/src/trash/dolphintrash.cpp:40-55`) | Low — F5 works. |
| Telemetry `hasSambaShare`/`hasNfsShare`/`hasSSHFSMount` always false (`dolphin/src/userfeedback/placesdatasource.cpp:42-70`) | None — don't build UserFeedback. |
| Thumbnail **cache** policy for files outside the home volume becomes `Prevent` (`kio/src/gui/filepreviewjob.cpp:545-562`), because `storageAccessFromPath()` returns an invalid device | Low: thumbnails are still *generated*, just not persisted → regenerated on each visit. |
| Free space in the status bar | **Not lost.** Numbers come from `QStorageInfo` (§3b). Only observer sharing degrades. |
| Places bookmarks (Home/Desktop/Documents/Downloads/Trash/Network) | **Not lost** — bookmark-driven, no Solid (`kio/src/filewidgets/kfileplacesmodel.cpp:340-414`). |

**Verdict for Phase 1 (backend running on macOS): acceptable.** Nothing here blocks compiling, launching, listing directories, or the status bar. Phase 1 work in this area is small and mechanical: build Solid from source with the iokit backend, expect to patch a compile error or two (no macOS CI), then run `solid-hardware6 list details` once and record what the IORegistry actually yields on Apple Silicon — that one measurement decides whether Phase 2 needs option (A) or (B).

**Not acceptable beyond Phase 2.** A file manager whose sidebar cannot see a plugged-in USB drive is not a Finder replacement, and the silent no-op on "Safely Remove" is worse than having no menu item at all — if we ship Phase 2 without fixing teardown, we should **hide** the action on macOS rather than leave a button that does nothing.

**Do this in Phase 1 regardless (cheap, high value):**
- Swap `mountpointobservercache.cpp:47` to `KMountPoint::currentMountPointForPath()`. Removes Solid from the status bar and avoids `storageAccessFromPath()` entirely.
- Do not build `KF6UserFeedback` → `placesdatasource.cpp` is not compiled.
- Add `-DBUILD_DEVICE_BACKEND_iokit=ON` explicitly to the Solid build (it's the default via `option()` at `solid/cmake/SolidBackendsMacros.cmake:29`, but pin it so a silent regression is visible).

## Unix/Linux-specific code & filesystem semantics

**Scope of evidence.** All citations below were read in the local checkouts. `dolphin/` = Dolphin master `5e457ee9` (v26.11.70); `kio/` = KIO master `3c6ae8bf`. Host used for the runtime probes: `arm64`, macOS 26.5.2, root volume APFS (`/dev/disk3s5s1 … apfs, sealed`), Data volume `/dev/disk3s1 on /System/Volumes/Data`. KCoreAddons (`KDirWatch`), KFileMetaData (`UserMetaData`), Solid and KFileSystemType are **not** in the local checkouts; claims about them are marked as inference and listed as open questions.

### 0. Headline verdict

There is very little that *fails to compile*. Dolphin's POSIX surface is tiny (four `#include <sys/…>`/`<unistd.h>` sites in the whole tree). The damage is concentrated in **semantics**: trash location, Unicode normalization, hidden-file definition, and file-watching throughput. Two of these (trash, hidden files) already have a working seam in KIO that we can extend rather than fork.

| # | Area | Class | Severity | Earliest phase |
|---|------|-------|----------|----------------|
| 1 | fts.h directory counter | build ✔ / runtime (TCC) | minor | 1 |
| 2 | `Q_OS_OSX` gating KIO's whole macOS trash impl | build/runtime | major | 1 |
| 3 | KIO fd.o trash → `~/.Trash/KDE.trash` (Finder-invisible, no Put Back) | runtime/ux | **blocker** | 2 |
| 4 | NFD/NFC mismatch in `QHash<QUrl,int>` + filter + tie-break comparators | runtime | major | 2 |
| 5 | KDirWatch has no inotify on macOS → QFSWatch/Stat | runtime/perf | major | 3 |
| 6 | `isNtfsHidden()` = one `getxattr` **per directory entry** on macOS | runtime/perf | major | 2 |
| 7 | Hidden = dotfile only; no `UF_HIDDEN` (e.g. `Icon\r`) | ux | major | 3 |
| 8 | POSIX ACL support compiled out; macOS NFSv4 ACLs invisible | build/ux | minor | 3 |
| 9 | Case-only rename | **verified working** | info | — |

---

### 1. `fts.h` — where it is and what it does

The root CMake probe is `dolphin/CMakeLists.txt:159-172`:

```cmake
# Compatibility with platforms without native fts (e.g. musl)
check_include_files("sys/types.h;sys/stat.h;fts.h" HAVE_FTS_H)
if(HAVE_FTS_H AND NOT HAIKU)
    check_function_exists(fts_open HAVE_FTS_OPEN)
    if(NOT HAVE_FTS_OPEN)
        check_library_exists(fts fts_open "" HAVE_LIB_FTS)
```
`FTS_LIB` is then linked into `dolphinprivate` at `dolphin/src/CMakeLists.txt:241`.

**The single consumer** is `dolphin/src/kitemviews/private/kdirectorycontentscounterworker.cpp` — the background worker that produces the "N items / total size" column and folder tooltips. It is gated `#if !defined(Q_OS_WIN) && !defined(Q_OS_HAIKU)` (`:11-18`, `:26`), i.e. **macOS takes the fts path**, not the `QDir::entryList` path. Key lines:

- `:35` `::fts_open(path, FTS_COMFOLLOW | FTS_PHYSICAL | FTS_XDEV, nullptr)`
- `:47` `while ((node = fts_read(tree)) && !m_stopping)`
- `:68` hidden-skip is **`node->fts_name[0] == '.'`** and nothing else
- `:76-82` `if (node->fts_statp->st_blocks > 0) totalSize += node->fts_statp->st_size;`
- `:112` `if (errno != 0) return;` — swallows the final `result()` signal if *any* stray errno is left set

**Build status on Apple Silicon: clean.** `fts.h` exists (`MacOSX.sdk/usr/include/fts.h`, `FTS_XDEV` at `:98`, `fts_statp` at `:167`). `fts_open` is declared `__DARWIN_INODE64(fts_open)` (`fts.h:177-178`), but on arm64 `sys/cdefs.h:659` sets `__DARWIN_ONLY_64_BIT_INO_T 1` → `__DARWIN_SUF_64_BIT_INO_T` is empty (`cdefs.h:753-757`), so the symbol is plain `_fts_open` and `check_function_exists(fts_open)` **succeeds**. `HAVE_LIB_FTS` stays false, `FTS_LIB` empty. (On x86_64 the `$INODE64` suffix would make the probe fail, but that is harmless — the header's asm label still resolves at link time. Apple Silicon only, so moot.)

**Runtime caveats specific to macOS:**

1. **TCC.** `fts_read` returns `FTS_DNR`/`FTS_ERR` for `~/Desktop`, `~/Documents`, `~/Downloads`, iCloud Drive etc. until the bundle has Full Disk Access or per-folder consent. The worker silently `continue`s (`:54-62`), so those folders will display an item count of `-1`/blank with no explanation. This is a Phase-1/2 packaging + UX task, not a code blocker.
2. **`FTS_XDEV` vs APFS firmlinks.** The root volume group is split (`/` is `disk3s5s1` read-only sealed; `/System/Volumes/Data` is `disk3s1`). Counting from `/` stops at every firmlink boundary — `/Users`, `/Applications`, `/private` all live on the Data volume. Counting `/` will report a nonsense number. Low impact (who counts `/`), but worth a guard.
3. **`st_blocks > 0`** is used to skip `/proc/kcore`-style pseudo-files (`:77` comment). On macOS this now silently excludes **APFS-compressed files** (decmpfs, data in the `com.apple.decmpfs` xattr, `st_blocks == 0`) from the size total — many system/app binaries are compressed. Folder sizes for `/Applications`-like trees will read low.

### 2. Every other POSIX / XDG hit in Dolphin

An exhaustive grep over `dolphin/src` for `statfs|statvfs|getmntent|mntent|/proc/|/sys/|inotify|sendfile|ioctl|mmap(` returns **exactly one** hit, and it is a comment (`kdirectorycontentscounterworker.cpp:77`). Literals `"/media`, `"/mnt`, `/run/user`, `/etc/fstab`, `/etc/mtab`, `/proc/self` return **zero** hits in `dolphin/src`. POSIX headers in Dolphin proper: `main.cpp:47 <unistd.h>` and `kdirectorycontentscounterworker.cpp:16-17 <sys/stat.h>,<sys/types.h>`. That is the entire list.

| Site | Code | macOS behaviour |
|---|---|---|
| `src/main.cpp:57` | `getuid() == 0 && (SUDO_USER \|\| KDESU_USER)` | Harmless; the "don't run as root" path just never triggers. |
| `src/dolphinviewcontainer.cpp:101-107` | `#if !defined(Q_OS_WIN)… if (getuid()==0)` root warning | Works, but `Q_OS_WIN`-only gate means macOS keeps a Linux-flavoured warning. Cosmetic. |
| `src/main.cpp:196` | `qEnvironmentVariable("XDG_ACTIVATION_TOKEN")` | Guarded by `KWindowSystem::isPlatformWayland()`, so dead on macOS. No action. |
| `src/dolphinpart.cpp:186` | `GenericConfigLocation + "/autostart"` | Resolves to `~/Library/Preferences/autostart` — meaningless on macOS. Cosmetic; the "Autostart" place should be dropped. |
| `src/dolphinbookmarkhandler.cpp:21-23` | `GenericDataLocation` + `kfile/bookmarks.xml` | `~/Library/Application Support/…` — fine, just non-native location. |
| `src/settings/contextmenu/contextmenusettingspage.cpp:273`, `servicemenuinstaller.cpp:54,299-380` | `GenericDataLocation/kio/servicemenus`, install/remove of `.desktop` files | The service-menu subsystem is an XDG `.desktop` concept end-to-end. On macOS it will build and run but find nothing, and `servicemenuinstaller.cpp:222` probes for `konsole`. Recommend compiling the whole service-menu page out for Phase 1-3 and replacing it later with Services/Quick Actions. |
| `src/search/popup.cpp:139` | `GenericDataLocation/kio_filenamesearch/kio-filenamesearch-grep` | A helper script shipped by `kio-extras`; will be absent. Search fallback path degrades. |
| `src/views/viewproperties.cpp:232` | compares `localPath == QStandardPaths::writableLocation(DownloadLocation)` | Exact-string compare against `~/Downloads`; see §4 — a case- or normalization-variant path silently misses. |
| `src/statusbar/mountpointobserver.cpp:40` | `KIO::fileSystemFreeSpace` | Lands in `kio/src/kioworkers/file/file.cpp:953-960`, which uses `QStorageInfo` — portable, works. |

**No `getmntent`/`/etc/mtab` risk:** `kio/src/core/kmountpoint.cpp:371-400` uses `getmntinfo(&mounted, MNT_NOWAIT)` under `#if HAVE_GETMNTINFO`; the SDK declares it (`sys/mount.h:451`). The `/etc/fstab` parse at `kmountpoint.cpp:254,276` is only reached for `possibleMountPoints()` and via `getfsfile()` for mount options — benign on macOS (it returns nothing).

`HAVE_X11` is correctly forced off for Apple: `dolphin/CMakeLists.txt` gates it on `if (UNIX AND NOT APPLE AND NOT HAIKU)`. KIO does the same at `kio/CMakeLists.txt:121`, and disables D-Bus by default for Apple at `kio/CMakeLists.txt:108-110`.

### 3. Trash — the biggest single semantic gap

#### 3a. KIO already has a macOS trash path, and it is gated on a deprecated macro

`kio/src/kioworkers/trash/trashimpl.cpp` carries **13 `#ifdef Q_OS_OSX` blocks** (`:104, :159, :270, :376, :395, :477, :571, :878, :954, :968, :1034, :1076, :1095, :1107, :1121, :1280`) plus `trashimpl.h:148`, and `trash/CMakeLists.txt:60-62` links `-framework DiskArbitration -framework CoreFoundation` under `if(APPLE)`.

What that code actually does:

```cpp
// trashimpl.cpp:172-179  (bool TrashImpl::init())
#else
    // we DO NOT create ~/.Trash on OS X, that's the operating system's privilege
    QString trashDir = QDir::homePath() + QLatin1String("/.Trash");
    if (!QFileInfo(trashDir).isDir()) { error(KIO::ERR_DOES_NOT_EXIST, trashDir); return false; }
    trashDir += QLatin1String("/KDE.trash");
#endif
```
and for non-home volumes (`trashimpl.cpp:1076-1112`) it uses `$topdir/.Trashes` instead of `$topdir/.Trash`, appending `/<uid>/KDE.trash`. Volume IDs come from DiskArbitration (`trashimpl.cpp:878-905`, `DASessionCreate` → `statfs` → `DADiskCreateFromBSDName` → `kDADiskDescriptionMediaBSDMajor/MinorKey`) instead of `KMountPoint::mountId()`.

**Risk:** the gate is `Q_OS_OSX`, a *legacy compatibility synonym*. In Qt 6.8's `qsystemdetection.h` it is still defined (confirmed: `Q_OS_MACOS`, then `#define Q_OS_MAC // FIXME: Deprecate`, `Q_OS_MACX`, `Q_OS_OSX` in the `#ifdef Q_OS_DARWIN` block). It carries an explicit deprecation note upstream. If Qt 6.11 has dropped it — or if some future Qt does — **every one of those blocks silently flips to the freedesktop.org branch**: no compile error, no link error, and trash quietly starts writing to `~/Library/Application Support/Trash/{files,info}`. This must be verified against the actual Qt 6.11 headers at Phase-1 configure time, and the pragmatic fix is a one-line patch replacing `Q_OS_OSX` with `Q_OS_MACOS` throughout `trashimpl.cpp`/`trashimpl.h` (we already need a KF6 build-from-source, so patching is cheap).

#### 3b. Even when the macOS branch *is* active, it is not macOS trash

Compare the two models:

| Concern | KIO (`Q_OS_OSX` branch) | macOS / `NSFileManager trashItemAtURL:` |
|---|---|---|
| Home trash | `~/.Trash/KDE.trash/{files,info}` (`trashimpl.cpp:172-179`) | `~/.Trash/<name>` directly |
| Other volumes | `/Volumes/X/.Trashes/<uid>/KDE.trash/{files,info}` (`:1076-1112`) | `/Volumes/X/.Trashes/<uid>/<name>` |
| Original-path record | `Path=` line in `<id>.trashinfo`, percent-encoded (`trashimpl.cpp:305-316`) | `com.apple.metadata:_kMDItemUserTags`-adjacent private store; Finder "Put Back" reads `kMDItemHomeDirectory`-style metadata written by the OS |
| Restore | `TrashProtocol::restore()` (`kio_trash.cpp:110-137`) reading `info.origPath` | Finder **Put Back** — will not work for anything we trash |
| Size accounting | `TrashSizeCache` + `trashrc` `[Status] Empty` (`dolphin/src/trash/dolphintrash.cpp:104-106`) | Finder computes live |
| Notification | `org::kde::KDirNotify::emitFilesChanged` under `#ifdef WITH_QTDBUS` (`trashimpl.cpp:951`) | — |

**What breaks concretely if we ship this as-is:**

1. Finder's Trash shows a folder literally named `KDE.trash` containing `files/` and `info/`. Users' trashed items are two levels down. Nothing else on the system knows about it.
2. Finder's **Put Back** is unavailable for every item Dolphin trashes.
3. "Empty Trash" from Finder deletes the `KDE.trash` folder wholesale; Dolphin's `trashrc` `[Status] Empty` (read at `dolphin/src/trash/dolphintrash.cpp:102-106`) and `TrashSizeCache` go stale, so the Places-panel trash icon lies.
4. Conversely, `Trash::empty()` (`dolphintrash.cpp:89-100`) will not touch items Finder put in `~/.Trash`, so "Empty Trash" in Dolphin appears to do nothing for those.
5. `trashForMountPoint` (`trashimpl.cpp:1082-1105`) requires the sticky bit **and** `access(W_OK)` on `/Volumes/X/.Trashes`. macOS creates `.Trashes` mode `drwxrwxrwt` on some volume types and not at all on others; where the check fails, the `#ifndef Q_OS_OSX` guard at `trashimpl.cpp:954-958` deliberately lets an *empty* `trashDir` through, and `idForTrashDirectory("")` will then be asked for an id. Behaviour on external/network volumes is untested — see open questions.
6. Without a session bus (`kio/CMakeLists.txt:108-110` disables D-Bus on Apple by default), `emitFilesChanged({trash:/})` at `trashimpl.cpp:951` is compiled out, so `dolphintrash.cpp`'s `m_trashDirLister` refresh depends entirely on KDirWatch noticing `~/.Trash/KDE.trash` change — see §6.

**Recommended fix (Phase 2/3):** write a replacement `kio_trash` worker for macOS backed by `-[NSFileManager trashItemAtURL:resultingItemURL:error:]` for the trash operation, and enumerate `~/.Trash` + `/Volumes/*/.Trashes/<uid>` for the `trash:/` listing. Implement `restore` by shelling out to a small AppKit helper that reproduces Put Back (or, minimally, keep our own sidecar index and accept that Finder's Put Back covers Finder-trashed items and ours covers ours). Do **not** try to synthesise Apple's Put Back metadata by hand. Effort: L. Interim (Phase 1-2) posture: keep KIO's `KDE.trash`, but patch `Q_OS_OSX`→`Q_OS_MACOS` first so we at least know which code is running, and put a known-issue note in the UI.

Dolphin's own trash code is thin and does not need changing: `dolphin/src/trash/dolphintrash.cpp` only drives a `KDirLister` on `trash:/` (`:57`), listens to `Solid::DeviceNotifier` to re-list when removable volumes appear (`:38-55`) — note this needs a working Solid IOKit backend on macOS — and calls `KIO::DeleteOrTrashJob` (`:92`). `dolphin/src/settings/trash/trashsettingspage.cpp:18` loads the external `kcm_trash` KCM, which will not exist unless we build it.

### 4. APFS: case-insensitive-but-case-preserving

**Measured on this machine** (`/private/tmp`, Data volume): creating `lowercase.txt` and then `ls LOWERCASE.TXT` succeeds → the default APFS volume here **is case-insensitive**.

#### The good news: case-only rename already works

- `dolphin/src/views/dolphinview.cpp:2290` — `newName != oldItem.text()` is a case-sensitive `QString` compare, so `foo.txt` → `FOO.txt` is *not* short-circuited and proceeds to `KIO::moveAs(oldUrl, newUrl)` at `:2364`.
- `KIO::moveAs` → `CopyJobPrivate::startRenameJob` (`kio/src/core/copyjob.cpp:1128-1166`) issues `CMD_RENAME` with `overwrite = false`.
- `kio/src/kioworkers/file/file_unix.cpp:996-1007` explicitly handles it:
  ```cpp
  bool dest_exists = (QT_LSTAT(_dest.data(), &buff_dest) != -1);
  if (dest_exists) {
      // Try QFile::rename(), this can help when renaming 'a' to 'A' on a case-insensitive
      // filesystem, e.g. FAT32/VFAT.
      if (src != dest && QString::compare(src, dest, Qt::CaseInsensitive) == 0) {
          if (QFile::rename(src, dest)) return WorkerResult::pass();
      }
  ```
- Qt's `QFile::rename` detects this by comparing `QFileSystemEngine::id()` of source and target *and* `compare(..., Qt::CaseInsensitive) == 0`, then renames via an intermediate name. So the path is sound.

Without this branch it would fail with `ERR_FILE_ALREADY_EXIST` — worth a regression test, because the code is only reachable when `dest_exists`, and any refactor of `FileProtocol::rename` would silently regress macOS.

#### The bad news: Dolphin's model index is byte-exact

`dolphin/src/kitemviews/kfileitemmodel.h:575`:
```cpp
mutable QHash<QUrl, int> m_items;   // cache for index(const QUrl&)
```
`KFileItemModel::index(const QUrl&)` (`kfileitemmodel.cpp:740-810`) does a pure `QHash` lookup on the `QUrl`, i.e. exact byte equality of the encoded path. Anything that reaches the model with a differently-cased (or differently-normalized — §5) URL returns `-1` and Dolphin prints *"The model is in an inconsistent state"* (`:779`). Practical triggers: a URL typed into the location bar with different case; a URL coming back from a KIO job that round-tripped through a case-insensitive lookup; a drag-and-drop source URL. The blast radius is "selection/scroll-to silently doesn't happen", not a crash. Note `dolphinview.cpp:2367` `if (m_model->index(newUrl) < 0)` relies on this being exact and would misbehave in the opposite direction if we naively case-folded the hash.

Other exact-match sites that would need auditing if we normalize: `dolphinpart.cpp:282`, `dolphinmainwindow.cpp:1647`, `dolphintabwidget.cpp:593-637`, `dolphincontextmenu.cpp:492`, `kfileitemmodel.cpp:1014,1564`, `dolphinview.cpp:1904`, `tooltipmanager.cpp:151`, `viewproperties.cpp:232`.

Duplicate detection in the dir lister — `kio/src/core/kcoredirlister.cpp:1208` `if (newItemNames.contains(name) || std::binary_search(...))` — is also exact-string, so it will not conflate `README` and `readme` (correct, since they cannot coexist anyway) but also cannot notice that they *are* the same file if a caller ever supplies both spellings.

**Recommendation:** do not case-fold. Instead introduce a single canonicalisation helper applied at the model boundary (§5), and keep `m_items` exact — the case-only rename path already works, and case-folding `m_items` would break `dolphinview.cpp:2367`.

### 5. Unicode normalization (NFD vs NFC) — the highest-value quiet bug

**Measured on this machine**, `/private/tmp` (APFS, Data volume):

```
create "café.txt" written as NFC (c3 a9)  → readdir returns 63 61 66 c3 a9 2e 74 78 74   (NFC preserved)
create "naïve.txt" written as NFD (cc 88) → readdir returns 6e 61 69 cc 88 76 65 2e ...   (NFD preserved)
lookup  "naïve.txt" as NFC (c3 af)        → resolves to the NFD-stored file                (lookup is normalization-insensitive)
```

So modern APFS is **normalization-preserving and normalization-insensitive**. The kernel will find the file either way — but `readdir` hands us whatever byte form was used at creation, and macOS/HFS+-heritage producers (Time Machine restores, some archive extractors, SMB/AFP shares, older apps) still write NFD. Qt/KIO/Dolphin then hold NFD `QString`s and compare them against NFC strings that came from the UI, from `QUrl` parsing, or from config.

Where this bites, with citations:

1. **`QHash<QUrl,int> m_items`** (`kfileitemmodel.h:575`, lookup at `kfileitemmodel.cpp:747`). `qHash(QUrl)` hashes the encoded string; NFD and NFC hash differently. Same failure mode as §4 — `index()` returns `-1`, selection/scroll silently lost after rename, copy, or "select newly created item".
2. **Sort tie-breakers are raw code-unit comparisons.** `KFileItemModel::stringCompare` ends with `return QString::compare(a, b, Qt::CaseSensitive);` (`kfileitemmodel.cpp:2666`), and `decimalAwareNaturalCompare` does the same at `:255-260`. The final fallback in `sortRoleCompare` is `QString::compare(itemA.url().url(), itemB.url().url(), Qt::CaseSensitive)` (`:2637`). These are the "guarantee a total order" fallbacks, so an NFD/NFC pair that the collator considers equivalent gets ordered by UTF-16 code units — `U+0308` (0x0308) vs `U+00EF` (0x00EF) sort *backwards* relative to the precomposed form. Result: unstable-looking, non-obvious ordering of accented names, and (worse) a comparator that is inconsistent with the collator, which is exactly the kind of thing that trips `std::sort`'s strict-weak-ordering debug assertions.
3. **The natural-sort comparator itself.** `decimalAwareNaturalCompare` (`kfileitemmodel.cpp:203-260`) splits strings at ASCII digits (`isAsciiDigit`, `countNumericChainSegments`) and calls `collator.compare()` on the non-numeric runs. Splitting a *decomposed* string on ASCII digit boundaries can put a combining mark at the head of a segment (e.g. `a1̈2` splits as `a` / `1` / `̈` / `2`), which the collator then compares as a bare combining mark. Rare, but it is a genuine correctness hazard the Linux side never sees.
4. **The filter bar does no normalization.** `kio`… no — `dolphin/src/kitemviews/private/kfileitemmodelfilter.cpp:136-142`:
   ```cpp
   if (m_filterMode == Glob || m_filterMode == Regex) return m_regExp->isValid() && m_regExp->match(item.text()).hasMatch();
   else if (m_caseSensitive) return item.text().contains(m_pattern);
   else return item.text().toLower().contains(m_lowerCasePattern);
   ```
   Typing `café` (the IME produces NFC) will **not** match an NFD-stored `café.txt`. Same for `QRegularExpression` — PCRE2 does not do canonical equivalence here.
5. **`.hidden` name matching** in KIO — `kcoredirlister.cpp:1224` `cachedHidden->listedFiles.find(name)` on a `std::set<QString>` read line-by-line from the file (`:2857-2866`). Exact-string; NFD/NFC mismatch means a listed name isn't hidden.
6. **`QCollator`** — Qt on macOS without ICU uses `qcollator_macx.cpp`, which drives Unicode Collation Services (`UCCreateCollator`/`UCCompareText`). Confirmed it *does* honour `numericMode` (`kUCCollateDigitsAsNumberMask | kUCCollateDigitsOverrideMask`) and `ignorePunctuation`, which matters because `kfileitemmodel.cpp:284` sets `m_collator.setNumericMode(true)`. UCS handles canonical equivalence, so the *collator* is fine — it is the non-collator fallbacks (item 2) and the raw `contains()`/regex (item 4) that break. Whether Homebrew's Qt 6.11 is built with ICU (and therefore uses `qcollator_icu.cpp` instead) should be checked at Phase 1; behaviour differs subtly between the two.
7. **Existing precedent for the fix already lives in the file.** `kfileitemmodel.cpp:577-585`:
   ```cpp
   QString removeMarks(const QString &original) {
       const auto normalized = original.normalized(QString::NormalizationForm_D);
       ... skip ch.isMark() ...
   }
   ```
   used by `indexForKeyboardSearch` (`:586-590`). Type-to-find is therefore *already* normalization-robust; nothing else is.

**Recommended fix:** normalize to **NFC at the KIO/model boundary** — one place: when a `KFileItem` enters `KFileItemModel` (and correspondingly in `KCoreDirLister`), store `QString::normalized(NormalizationForm_C)` for the display text and the hash key, while keeping the *original* bytes for all filesystem I/O (`QFile::encodeName` must never see the re-normalized form, or we would try to open a path that doesn't exist on a normalization-*sensitive* volume such as a case-sensitive APFS format or an NFS mount). Also normalize the filter pattern in `KFileItemModelFilter::setPattern`. Size: M. This is the single highest-leverage change in this section.

### 6. File watching: which backend, and what it costs

**KDirWatch has no macOS backend.** (Inference — KCoreAddons is not in the local checkouts; verified against upstream `kcoreaddons/src/lib/io/kdirwatch.cpp`. Confidence: high.) It supports exactly three methods — INotify, QFSWatch (`QFileSystemWatcher`), and Stat (polling); the fallback order is INotify → QFSWatch → Stat; the poll interval defaults to 500 ms (5000 ms on NFS); there is **no FSEvents backend**. On macOS `HAVE_SYS_INOTIFY_H` is false (no `sys/inotify.h` in the SDK — verified), so every watch lands on **QFSWatch**, i.e. Qt's `QFileSystemWatcher`, whose macOS engine is `QFseventsFileSystemWatcherEngine` (confirmed in `qfilesystemwatcher.cpp`: `#elif defined(Q_OS_MACOS) return QFseventsFileSystemWatcherEngine::create(parent);` — macOS is explicitly *not* the kqueue path, so we do not hit the `RLIMIT_NOFILE` wall that FreeBSD does).

Consequences:

- **Coarser events.** KDirWatch's own source notes that "inotify supports delete+recreate+modify, which QFSWatch doesn't". Dolphin already codes around inotify-specific behaviour: `dolphin/src/kitemviews/private/kdirectorycontentscounter.cpp:142-155` comments *"If INotify is used, KDirWatch issues the dirty() signal also for changed files inside the directory"* and returns early for non-dirs. On QFSWatch that early-return is dead code, and the compensating re-listing does not happen — expect **missed refreshes** rather than excessive ones.
- **Watch fan-out.** `kdirectorycontentscounter.cpp:130-133` adds a `KDirWatch` directory watch for **every directory whose contents it counted**:
  ```cpp
  if (fileInfo.isReadable() && !m_watchedDirs.contains(resolvedPath)) m_dirWatcher->addDir(resolvedPath);
  ```
  With "show folder item count" on (Dolphin's default in Details view) and a folder containing 10 000 subdirectories, that is 10 000 `QFileSystemWatcher::addPath` calls. Qt's FSEvents engine maintains a *single* `FSEventStream` and **restarts it whenever the watched-path set changes**, so bulk-adding N paths is O(N²) stream restarts. This is a concrete, measurable risk against the 10k/100k performance goal and needs a benchmark early (Phase 3).
- **Latency + coalescing.** FSEvents delivers directory-granularity events with a configurable latency; KCoreDirLister then re-`listDir`s the whole directory (`kcoredirlister.cpp:1025` "Called by KDirWatch — usually when a dir we're watching has been modified"). Re-listing a 100 k-entry directory on every coalesced event is the dominant cost, and §7 makes each re-list worse.
- **TCC again.** FSEvents on TCC-protected paths returns nothing without consent; watches will silently never fire for `~/Documents` etc.
- **If QFSWatch ever fails to attach**, KDirWatch falls back to `Stat` — a 500 ms `QFileInfo::lastModified()` poll per watched entry. With the fan-out above that is catastrophic. Set `KDIRWATCH_METHOD` explicitly and log the chosen method at startup.

**Recommendation (Phase 3):** (a) benchmark `addDir` fan-out first; (b) consider capping/deferring the counter's watch registration; (c) longer term, contribute a native FSEvents backend to KDirWatch (a single recursive stream rooted at the visible directory beats N per-directory watches and is what Finder effectively does). Effort for a real FSEvents backend: L.

### 7. A macOS-only per-file syscall in every directory listing

`kio/src/kioworkers/file/file_unix.cpp:948` calls `isNtfsHidden(filename)` for **every entry** in every local directory listing, guarded only by `#if HAVE_SYS_XATTR_H && HAVE_DIRENT_D_TYPE`. Both are true on macOS (`sys/xattr.h` present in the SDK; `dirent.d_type` present) — the probes are at `kio/src/kioworkers/file/ConfigureChecks.cmake:12,20`. The function (`file_unix.cpp:828-855`) does:

```cpp
#ifdef Q_OS_MACOS
    auto length = getxattr(filenameEncoded.data(), attrName, strAttr, xattr_size, 0, XATTR_NOFOLLOW);
```
looking for `system.ntfs_attrib_be` — a **Linux ntfs-3g** attribute that can never exist on macOS. That is one wasted `getxattr(2)` per file, plus a `QFile::encodeName` allocation, plus (when it "hits", which it won't) a `QDir::canonicalPath()` + `KMountPoint::currentMountPointForPath()`. For a 100 000-entry directory that is 100 000 pointless syscalls on the listing hot path, on top of the `createUDSEntry` stat.

**Fix (S, high value):** gate `isNtfsHidden` on `!defined(Q_OS_MACOS)` — or better, replace the whole call with the macOS-correct equivalent described in §9. This is a one-line patch to KIO that we control (we build KF6 from source anyway).

### 8. Permissions, ACLs, BSD flags, xattr

**Where Dolphin shows/edits permissions:**
- Read-only display: the `permissions` role. `KFileItemModel::permissionRoleGroups()` (`kfileitemmodel.cpp:707+`) builds group headers from `QFileInfo::permission(QFile::ReadUser|WriteUser|ExeUser|…)` — pure mode-bit logic.
- Editing: `KPropertiesDialog` from KIO Widgets, launched at `dolphin/src/views/dolphinviewactionhandler.cpp:908-914`, `panels/folders/treeviewcontextmenu.cpp:204`, and `dbusinterface.cpp:58`. Dolphin itself contains **no** permissions-editing code.

**ACLs are compiled out on macOS.** `kio/CMakeLists.txt:129-131` does `find_package(ACL); set(HAVE_POSIX_ACL ${ACL_FOUND})`, and `kio/cmake/FindACL.cmake:18-21` requires `attr/libattr.h AND sys/xattr.h AND sys/acl.h AND acl/libacl.h`, **or** `sys/extattr.h`. On macOS: `sys/acl.h` ✔, `sys/xattr.h` ✔, `attr/libattr.h` ✘, `acl/libacl.h` ✘, `sys/extattr.h` ✘ (all verified against `MacOSX.sdk/usr/include`). It also needs `find_library(acl)` **and** `find_library(attr)`. So `ACL_FOUND=FALSE` → `HAVE_POSIX_ACL=0` → the ACL tab in `KFilePermissionsPropsPlugin` is gone. Not a build blocker — a silent feature loss. Note the dead macOS branch inside the disabled block, `kio/src/widgets/kpropertiesdialogbuiltin_p.cpp:1398`:
```cpp
#elif defined Q_OS_MACOS
    fileSystemSupportsACLs = getxattr(path.data(), "system.posix_acl_access", nullptr, 0, 0, XATTR_NOFOLLOW) >= 0 || errno == ENODATA;
```
`system.posix_acl_access` is a Linux xattr name; macOS ACLs are NFSv4-style, exposed via `acl_get_file(…, ACL_TYPE_EXTENDED)` and the `com.apple.system.Security` xattr. This branch would return false even if it were reachable.

**The real risk is destructive, not cosmetic:** macOS ACLs are *not* reflected in the mode bits. Every real directory in a macOS home has one — `ls -ldO ~/.Trash` on this machine shows `drwx------+` (the `+` is an extended ACL). If the user opens Properties and clicks OK, `KFilePermissionsPropsPlugin` issues a `chmod`, which on macOS **does not clear the ACL** (good) but does silently make the displayed permissions diverge from the effective ones (bad). Recommend: hide or disable the permissions tab for Phase 1-3, or replace it with an `acl_get_file`-based read-only view.

**BSD flags (`chflags`) are entirely absent** from both trees — zero hits for `chflags`, `st_flags`, `UF_IMMUTABLE`, `UF_HIDDEN`. Consequences: a `uchg` (user-immutable) file looks writable in Dolphin and delete/rename fails with a bare `EPERM` → `ERR_WRITE_ACCESS_DENIED` (`file_unix.cpp:1024`) with no explanation of why.

**xattr handling is macOS-aware and works.** `FileProtocol::copyXattrs` (`file_unix.cpp:360-475`) has correct 6-arg macOS variants of `flistxattr`/`fgetxattr`/`fsetxattr` at `:368-370`, `:426-428`, `:460-462`. Two notes: (a) on macOS this copies **all** namespaces, so `com.apple.quarantine` propagates to copies (same as Finder — desirable) while `com.apple.macl`/`com.apple.provenance` will fail with `EPERM` and are silently skipped (`:471-479` only bails on `ENOTSUP`/`ENOSPC`/`EDQUOT`) — acceptable; (b) `com.apple.ResourceFork` and `com.apple.FinderInfo` *are* preserved this way, which is more than I expected.

**The Finder Tags seam.** Dolphin already routes all user metadata through **`KFileMetaData::UserMetaData`**:
- `dolphin/src/kitemviews/private/kbaloorolesprovider.cpp:144-145,164-165` — `attributes |= KFileMetaData::UserMetaData::Tags; values.insert("tags", tagsFromValues(md.tags()));`
- `dolphin/src/views/viewproperties.cpp:22,54,641,712` — view properties are themselves stored in an xattr via `metaData.setAttribute(MetaDataKey, …)`, falling back to a `.directory` file when `!metaData.isSupported()` (`:47-58`, `:642-647`) or when the xattr is out of space (`:714-726`).

So **`KFileMetaData::UserMetaData` is the exact seam** for Finder Tags: teach its macOS build to map `Tags` onto `com.apple.metadata:_kMDItemUserTags` (a binary plist of `"Name\n<colorIndex>"` strings) instead of `user.xdg.tags`, and Dolphin's tag column, tag filter (`src/search/selectors/tagsselector.cpp`) and Information Panel light up with no Dolphin changes at all. KFileMetaData is not in the local checkouts, so the current macOS mapping is an open question. Similarly, view properties will land in a `com.apple.*`-adjacent custom xattr — harmless, but it means every folder Dolphin visits with non-default view settings gets an xattr, which `rsync` without `-X` and most archivers will drop.

### 9. Hidden files

**Dolphin's logic is entirely delegated.** `dolphin/src/kitemviews/kfileitemmodel.cpp:507-519` just forwards to `KCoreDirLister::setShowHiddenFiles`, and `:2230` computes the display role as
```cpp
data.insert(sharedValue("isHidden"), item.isHidden() || item.currentMimeType().name() == QStringLiteral("application/x-trash"));
```
(the second clause is the "hide backup files" option, `GeneralSettings::hideXTrashFile()`, wired at `:338` and `:488-510`). Filtering happens in KIO at `kio/src/core/kcoredirlister.cpp:2463` `if (!settings.isShowingDotFiles && item.isHidden()) return false;`.

**The actual definition** is `kio/src/core/kfileitem.cpp:1386-1407`:
```cpp
    // The KIO worker can specify explicitly that a file is hidden or shown
    if (d->m_hidden != KFileItemPrivate::Auto) return d->m_hidden == KFileItemPrivate::Hidden;
    ...
    d->m_hiddenCache = fileName.length() > 1 && fileName[0] == QLatin1Char('.') ? … Hidden : … Shown;
```
i.e. **leading dot, nothing else** — plus whatever a worker declares via `UDS_HIDDEN` (parsed at `kfileitem.cpp:344`). There is exactly one producer of `UDS_HIDDEN` today: `file_unix.cpp:961`, for NTFS.

Dolphin's `fts` counter has its own, *separate* dotfile check that KIO's rules never reach (`kdirectorycontentscounterworker.cpp:68`, which also hard-codes an exception for `.git`), so folder item counts and the visible listing can already disagree.

**What macOS adds that Dolphin misses:**

| macOS mechanism | Current behaviour | Notes |
|---|---|---|
| `UF_HIDDEN` flag (`sys/stat.h:330`, `0x00008000`) | **Not honoured.** | Real files with `UF_HIDDEN` and no leading dot: `Icon\r` (custom folder icons — appears in Dolphin as a garbage-named file in every folder that has one), `/Applications` items hidden by installers, `/usr`, `/bin`, `/sbin`, `/Library` at the volume root, `$RECYCLE.BIN`, and `/Volumes/<name>/.fseventsd`. |
| `/.hidden` (root-only legacy list) | **Accidentally honoured**, and per-directory rather than root-only. | `kcoredirlister.cpp:2842-2880` reads `<dir>/.hidden` and hides every listed name (`:1214-1227`, `:1792-1805`). macOS ships no `/.hidden` by default (verified: absent on this machine), but if present it will do the right thing at `/`. Note the exact-string match — see §5 item 5. |
| Bundle/package directories (`.app`, `.rtfd`, `.photoslibrary`, `.fcpbundle`) | Shown as ordinary folders. | Not "hidden" but the same class of problem: Finder treats them as opaque documents. Dolphin has **zero** bundle awareness (grep for `isBundle`/`package` in `dolphin/src` returns nothing but `inode/directory` checks at `dolphinmainwindow.cpp:382,1494`). Double-clicking a `.app` in Dolphin will descend into `Contents/` instead of launching it. |
| `.DS_Store`, `.localized` | Hidden (dotfiles). ✔ | But `.DS_Store` becomes *visible* the moment the user toggles "show hidden files", in every single directory. |

**Recommended fix (Phase 3, size M):** extend `FileProtocol::listDir` to set `UDS_HIDDEN` from `st_flags & UF_HIDDEN`. The seam already exists — replace the `isNtfsHidden` call at `file_unix.cpp:948` with a macOS branch, which simultaneously fixes §7. Note that `readdir` does not give `st_flags`, so this needs the `stat` that `createUDSEntry` performs anyway (`stat_unix.h` already has `Q_OS_DARWIN` branches at `:232,246` for `st_mtimespec`/`st_atimespec`, so adding an `stat_flags()` accessor there is idiomatic). Separately, teach `kdirectorycontentscounterworker.cpp:68` about `fts_statp->st_flags` so counts agree with the view. Bundle-as-document is a larger Phase-4 UX item requiring `LSItemContentTypes`/UTI `com.apple.package` conformance checks.

---

### Recommendations, ordered

1. **Phase 1 (cheap, do first):** verify `Q_OS_OSX` is still defined by Homebrew Qt 6.11 and, either way, patch `kio/src/kioworkers/trash/trashimpl.{cpp,h}` to `Q_OS_MACOS`. Log the KDirWatch method at startup. Gate `isNtfsHidden` off on macOS. Confirm `check_function_exists(fts_open)` passes in the real configure log.
2. **Phase 2:** NFC normalization at the KIO→model boundary + `KFileItemModelFilter::setPattern`. Add regression tests for case-only rename and for an NFD-named file.
3. **Phase 3:** native trash worker over `NSFileManager trashItemAtURL:`; `UF_HIDDEN` → `UDS_HIDDEN`; benchmark KDirWatch fan-out and decide on an FSEvents backend; disable or replace the permissions tab.
4. **Phase 4:** bundle-as-document semantics; Finder Tags via a macOS `KFileMetaData::UserMetaData` mapping; BSD-flag surfacing (`uchg` lock badge).
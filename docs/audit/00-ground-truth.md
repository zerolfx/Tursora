# Phase 0 — Ground truth (first-hand verified)

Facts in this file were verified directly against the pinned checkouts and the local
toolchain. Everything here is evidence, not inference. Cited as `repo:path:line`.

## Pinned upstream revisions

| Repo | Commit | Date | Path |
|---|---|---|---|
| dolphin | `5e457ee9e88aa6277fbf056cd5c32462c5318866` | 2026-08-18 | `upstream/dolphin` |
| kio | `3c6ae8bf757262386a8f6a10bfbc1f9f6d221d2a` | 2026-08-19 | `upstream/kio` |
| kio-extras | `6ddac4968aad8ca39862b0420bcc529cc480fe60` | 2026-08-19 | `upstream/kio-extras` |
| craft-blueprints-kde | `11b07503ab24e84affc5ed9c94093f8b03b05fd4` | 2026-08-17 | `upstream/craft-blueprints` |

Dolphin version: **26.11.70** (master). Requires **Qt ≥ 6.4.0**, **KF6 ≥ 6.23.0**, **C++20**.
(`dolphin:CMakeLists.txt:8-19`)

## Host toolchain

| Item | Value |
|---|---|
| macOS | 26.5.2 (build 25F84) |
| Arch | arm64 (Apple Silicon) |
| Compiler | Apple clang 21.0.0, target `arm64-apple-darwin25.5.0` |
| Xcode | Command Line Tools only (`/Library/Developer/CommandLineTools`) |
| Homebrew | 6.0.15 |
| cmake / ninja | **not installed** |
| Qt | **not installed** (Homebrew `qt` = 6.11.1 available) |

## Finding GT-1 — KDE already builds & packages Dolphin for macOS via Craft

`craft-blueprints:kde/applications/dolphin/dolphin.py` contains an explicit macOS branch:

```python
if CraftCore.compiler.isMacOS:
    self.blacklist_file.append(self.blueprintDir() / "blacklist_mac.txt")
...
# skip dbus for macOS and Windows, we don't use it there and it only leads to issues
if not CraftCore.compiler.isLinux:
    self.ignoredPackages.append("libs/dbus")
```

Consequences:
- A macOS build path for Dolphin is **maintained upstream**, not hypothetical.
- Upstream's own position is that **macOS Dolphin runs without D-Bus**.
- The blueprint's `setDependencies()` is an authoritative, minimal dependency list
  (see `docs/audit/02-dependency-graph.md`).

## Finding GT-2 — KIO defaults to D-Bus **off** on macOS, and the no-D-Bus path is real

`kio:CMakeLists.txt:107-111`:

```cmake
set(USE_DBUS_DEFAULT OFF)
if(UNIX AND NOT APPLE AND NOT ANDROID AND NOT HAIKU)
    set(USE_DBUS_DEFAULT ON)
endif()
option(USE_DBUS "Build components using DBus" ${USE_DBUS_DEFAULT})
```

`-DWITH_QTDBUS` is only defined when `USE_DBUS` is on (`kio:CMakeLists.txt:117`). The guard is
used in **28 source files** across `core` (13), `gui` (7), `widgets` (7), `filewidgets` (1) —
this is a maintained build configuration, not an accident.

## Finding GT-3 — D-Bus off silently removes four KIO components

`kio:src/CMakeLists.txt:8-11,23-26,33`:

```cmake
if (HAVE_QTDBUS)
    add_subdirectory(kiod)        # KIO daemon
    add_subdirectory(kssld)       # SSL certificate manager
endif()
...
if (HAVE_QTDBUS)
    add_subdirectory(kpasswdserver)   # credential prompting + caching
    add_subdirectory(kioexec)         # "open remote file in local app"
endif()
```

So on a default macOS KIO build there is **no kpasswdserver and no kioexec**.

## Finding GT-4 — credential caching is a hard no-op without D-Bus

`kio:src/core/slavebase.cpp:1274-1283`:

```cpp
bool SlaveBase::checkCachedAuthentication(AuthInfo &info)
{
#ifdef WITH_QTDBUS
    ...KPasswdServerClient...
#else
    return false;
#endif
}
```

and `kio:src/core/slavebase.cpp:1325-1332` — `cacheAuthentication()` does nothing and returns
`true`. **Every** sftp/smb/webdav operation will therefore re-prompt for credentials on macOS.

This is a concrete Phase-1 work item: a Keychain-backed replacement for `KPasswdServerClient`.

## Finding GT-5 — KIO already contains Objective-C++ and macOS framework linkage

- `kio:src/kiod/CMakeLists.txt:9-13` compiles `kiod_agent.mm` on APPLE.
- `kio:src/kiod/CMakeLists.txt:33-38` links `-framework AppKit -framework CoreFoundation`.
- `kio:src/kiod/kiod_agent.mm` sets `LSUIElement` and
  `NSApplicationActivationPolicyAccessory` so a helper process gets no Dock icon.
- `kio:src/kioworkers/trash/CMakeLists.txt:60-62` links
  `-framework DiskArbitration -framework CoreFoundation` for `kio_trash`.

Precedent exists inside KIO for exactly the Qt↔AppKit bridging style this project needs.

## Finding GT-6 — no KF6 stack in Homebrew

Checked with `brew info --json=v2`:

| Formula | Status |
|---|---|
| `qt` | ✅ 6.11.1 |
| `extra-cmake-modules` | ✅ 6.29.0 |
| `karchive` | ✅ 6.29.0 (isolated leaf framework) |
| `kcoreaddons`, `kio`, `ki18n`, `kconfig`, `solid`, `kxmlgui`, `kfilemetadata`, `baloo`, … | ❌ absent (≈45 checked, none present) |

`kdenlive` and `kde-connect` exist only as **casks** (prebuilt .app bundles produced by KDE
Craft), not formulae — confirming Homebrew has no KF6 source stack.

Third-party deps that *are* available on arm64: `libssh` 0.12.2 (sftp), `samba` 4.24.6
(smb/libsmbclient), `exiv2` 0.28.8, `taglib` 2.3.1, `poppler-qt6` 26.08.0, `ffmpeg` 9.0.1,
`openexr` 3.4.14, `shared-mime-info` 2.5.1, `dbus` 1.16.2.

⚠️ Naming collision: the Homebrew cask `dolphin` is the **GameCube emulator**. Our product
name/bundle identifier must not collide.

## Finding GT-7 — Dolphin's source is already split, and the split is close to the seam we want

`dolphin:src/CMakeLists.txt` builds:

| Target | Line | Nature |
|---|---|---|
| `dolphinvcs` (SHARED) | 24 | version-control plugin interface |
| `dolphinprivate` (SHARED) | 59 | **view + model framework**: all of `kitemviews/`, `DolphinView`, view properties, DnD helper, new-file menu |
| `dolphinpart` (MODULE) | 263 | KParts embedding |
| `dolphinstatic` (STATIC) | 285 | application shell: main window, tabs, panels, settings, search |
| `dolphin` (EXECUTABLE) | 511 | thin `main.cpp` |
| `kcm_dolphin*` (MODULE) | 562-563 | settings modules |

`dolphinprivate` already links `Qt6::DBus` unconditionally (`dolphin:src/CMakeLists.txt:222`) —
that is a Dolphin-side patch target, since KIO itself will be built without D-Bus.

## Finding GT-8 — source size and where the weight sits

Dolphin `src/`: **169 .cpp + 151 .h ≈ 77.5k LOC** (incl. 10.9k LOC of tests).

| Area | Files | LOC | Note |
|---|---|---|---|
| `kitemviews/` + `private/` | 70 | **25,153** | custom QGraphicsWidget item-view framework — the Phase 3 replacement target |
| top-level (`.`) | 50 | 13,319 | main window, tabs, bars, menus |
| `tests/` | 24 | 10,942 | |
| `views/` (+tooltips, vcs) | 32 | 9,308 | `DolphinView` and friends |
| `search/` (+selectors) | 22 | 2,907 | |
| `settings/` (all) | 50 | 5,240 | |
| `panels/` (all) | 20 | 3,816 | places, folders, information, terminal |
| `selectionmode/` | 13 | 1,753 | |
| `statusbar/` | 12 | 1,608 | |
| others | — | ~3,400 | trash, filterbar, itemactions, admin, userfeedback |

`kitemviews/` alone is ~32% of non-test code. Keeping its **model half**
(`KFileItemModel`, `KFileItemModelRolesUpdater`) while replacing its **view half** is the single
highest-leverage architectural decision in this project.

## Finding GT-9 — Dolphin has very little macOS-specific code today

Platform conditionals in `dolphin/src`: `Q_OS_WIN` ×56, `Q_OS_UNIX` ×7, `Q_OS_MACOS` ×4,
`Q_OS_HAIKU` ×4. The four macOS sites are:

- `dolphinmainwindow.cpp:152` (shared with WIN)
- `main.cpp:88` (shared with WIN)
- `kitemviews/kitemlistcontainer.cpp:190`
- `kitemviews/private/kitemlistsmoothscroller.cpp:218`

The large `Q_OS_WIN` count is good news: the Windows port already forced upstream to abstract
many Linux-only assumptions, and macOS can often reuse the non-Linux branch.

## Finding GT-10 — kio-extras gates workers per platform

`kio-extras:CMakeLists.txt` — relevant gates: line 58 (`UNIX AND NOT APPLE AND NOT ANDROID AND
NOT HAIKU`), 91 (`NOT WIN32 AND USE_DBUS`), 110, 154, and per-worker
`add_subdirectory` calls at 191-248, including `sftp` (210), **`filenamesearch` excluded on
APPLE** (213: `if (NOT WIN32 AND NOT APPLE AND USE_DBUS)`), and `smb` (232).

The exclusion of `filenamesearch` on APPLE matters: combined with Baloo being optional, it means
**a default macOS build has no working file-search backend at all**. See the search section.

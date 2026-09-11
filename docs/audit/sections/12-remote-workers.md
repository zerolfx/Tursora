## Remote filesystem workers (sftp / smb / webdav / ftp) — specialist pass

All line references are first-hand reads of the three read-only checkouts. Repo prefixes: `kio-extras:`, `kio:`, `dolphin:`.

---

### 1. kio-extras `add_subdirectory` inventory — every gate

`kio-extras/CMakeLists.txt` is 256 lines. There are 16 `add_subdirectory` calls in it plus 3 in `kcms/CMakeLists.txt`. macOS-relevant preconditions established up front:

| var | value on APPLE | evidence |
|---|---|---|
| `USE_DBUS_DEFAULT` | `OFF` (only `UNIX AND NOT APPLE AND NOT ANDROID AND NOT HAIKU` flips it ON) | `kio-extras:CMakeLists.txt:57-60` |
| `USE_DBUS` | `OFF` unless user forces it | `kio-extras:CMakeLists.txt:61` |
| `WITH_LIBPROXY` | **undefined** — the `option()` is only declared inside `if(LINUX)` | `kio-extras:CMakeLists.txt:67-69` |
| `BUILD_ACTIVITIES` | **undefined** — `option()` only declared inside `if (NOT WIN32 AND USE_DBUS)` | `kio-extras:CMakeLists.txt:91-98` |
| `WIN32` / `UNIX` | false / true | — |

| worker / subdir | builds on macOS? | gate (file:line) | external deps | notes |
|---|---|---|---|---|
| `kcms` (→ trash, webshortcuts, proxy) | **yes** if `BUILD_KCMS` (default ON) | `CMakeLists.txt:190-192` | KF6KCMUtils, KF6KIOWidgets, KF6Solid | Not in Homebrew; all three KCMs are Plasma System Settings modules and are **useless in a macOS shell**. `kcms/trash` links `-framework DiskArbitration -framework CoreFoundation` (`kcms/trash/CMakeLists.txt:17-19`) and `kcms/trash/kcmtrash.cpp:206` uses `#ifdef Q_OS_OSX` — still compiles (deprecation pragma only). `kcms/proxy/CMakeLists.txt:1-3` correctly skips `wpad-detector` when `WITH_LIBPROXY` is unset. **Recommend `-DBUILD_KCMS=OFF`.** |
| `activities` | **no** | `CMakeLists.txt:194` (`BUILD_ACTIVITIES` undefined) | Qt6Sql, PlasmaActivities | Footgun: forcing `-DBUILD_ACTIVITIES=ON` reaches line 195 but `find_package(PlasmaActivities REQUIRED)` at :95 never ran → hard configure error. |
| `recentlyused` | **no** | `CMakeLists.txt:194` | PlasmaActivitiesStats | same |
| `filter` (gzip/bzip/bzip2/lzma/xz/zstd) | **yes**, unconditional | `CMakeLists.txt:198` | KF6Archive (brew ✓ 6.29.0) | `filter/filter.json` declares 6 protocols. Cheap win. |
| `info` | **yes**, unconditional | `CMakeLists.txt:199` | KF6I18n | `info:/` — GNU texinfo browser. Useless on macOS; harmless. |
| `archive` (ar/sevenz/tar/zip) | **yes**, unconditional | `CMakeLists.txt:200` | KF6Archive | Also builds/installs the public `kioarchive6` shared lib + CMake package (`archive/CMakeLists.txt:56,85`). Needed for "browse into archives" (`dolphin:views/dolphinview.cpp:1835`). |
| `fish` | **yes** | `CMakeLists.txt:201-205` (`NOT WIN32`) | needs an `md5sum`/`md5` binary at configure time | `fish/CMakeLists.txt` `find_program(NAMES md5sum md5)`. Verified on this machine: `/sbin/md5sum` exists on macOS 26.5.2 and emits GNU format (`d8e8fca2…  -`), so `CUT_ARG "-f 1"` is chosen correctly. `fish:/` = SSH-over-shell; superseded by sftp. |
| `thumbnail` | **yes**, unconditional | `CMakeLists.txt:206` | see §5 | Also builds ~15 thumbcreator plugins, most optional. |
| `sftp` | **yes** — **no platform gate at all** | `CMakeLists.txt:207-211` (`if (libssh_FOUND)`) | libssh ≥ 0.9.8 (`CMakeLists.txt:122`), **QCoro6 Core REQUIRED** (`:208`), KF6 WidgetsAddons/ConfigCore/I18n | brew has libssh 0.12.2 ✓ and qcoro6 0.13.0 ✓. See §2. |
| `filenamesearch` | **no — explicitly excluded on APPLE** | `CMakeLists.txt:213-215` (`NOT WIN32 AND NOT APPLE AND USE_DBUS`) | KF6DBusAddons | The only subdir with an explicit `NOT APPLE`. Also has a `kded` submodule. |
| `mtp` | **no** | `CMakeLists.txt:217-219` (`Libmtp_FOUND AND USE_DBUS`) | libmtp ≥ 1.1.2, KF6DBusAddons | Double-blocked (D-Bus + kiod module). |
| `man` | **yes** if gperf found | `CMakeLists.txt:221-224` (`NOT WIN32 AND Gperf_FOUND`) | gperf, KF6Codecs | `/usr/bin/gperf` **exists** on this machine (Xcode CLT) → **this will build**, pulling in KF6Codecs. Turn it off or accept the extra KF6 dep. |
| `nfs` | **no** (in practice) | `CMakeLists.txt:225-227` (`NOT WIN32 AND TIRPC_FOUND`) | libtirpc | `cmake/FindTIRPC.cmake:14-26` looks for `netconfig.h` + `libtirpc`; not present on macOS unless brew-installed. Also does a `FATAL_ERROR` if no 64-bit XDR (`nfs/CMakeLists.txt:14-16`). |
| `smb` | **no** | `CMakeLists.txt:230-233` (`SAMBA_FOUND AND USE_DBUS`) | libsmbclient, **KF6DNSSD (REQUIRED at :231)**, **KDSoapWSDiscoveryClient (REQUIRED)**, Threads | See §3. |
| `afc` | **no** | `CMakeLists.txt:235-237` (`IMobileDevice_FOUND AND PList_FOUND`) | libimobiledevice, libplist | Would actually be interesting on macOS but neither dep is in the required set. |
| `doc` | **yes** if `BUILD_DOC` (default ON) | `CMakeLists.txt:247-250` | KF6DocTools **TYPE REQUIRED** (`:101-105`) | brew has kdoctools 6.29.0 ✓. Recommend `-DBUILD_DOC=OFF` anyway. |

`smoketest/` exists on disk but is never `add_subdirectory`'d.

**Net for macOS with stock flags:** you get `filter`, `info`, `archive`, `fish`, `thumbnail`, `sftp`, `man`, plus 3 useless KCMs. `smb`, `mtp`, `activities`, `recentlyused`, `filenamesearch`, `nfs`, `afc` are all gated off.

---

### 2. sftp — the one that actually works

**Build.** `kio-extras:CMakeLists.txt:122` — `find_package(libssh 0.9.8 CONFIG)`; floor is **0.9.8**, brew ships 0.12.2. `sftp/CMakeLists.txt:5-11` probes `sftp_aio_begin_read` and sets `-DHAVE_SFTP_AIO`; that symbol landed in libssh 0.11, so on 0.12.2 the **AIO path** (`kio_sftp.cpp:2239-2416`) is compiled, not the legacy `sftp_async_read` path (`:2417-2612`). Links `KF6::KIOCore KF6::WidgetsAddons KF6::ConfigCore KF6::I18n Qt::Network QCoro::Core ssh` (`sftp/CMakeLists.txt:43-52`) plus `kde_target_enable_exceptions`.

**QCoro6 is a hard requirement and cannot be dropped cheaply.** `kio-extras:CMakeLists.txt:207-211` does `find_package(QCoro6 REQUIRED COMPONENTS Core)` + `qcoro_enable_coroutines()` *before* `add_subdirectory(sftp)`. What it provides is exactly one thing: `QCoro::Generator<T>`, used as the transfer pipeline type. It appears in **both** `#if HAVE_SFTP_AIO` branches — `kio_sftp.cpp:2242` and `kio_sftp.cpp:2550` both declare `QCoro::Generator<SFTPWorker::ReadResponse> SFTPWorker::asyncRead(...)`, and `:2330`/`:2579` the `asyncWrite` counterparts, consumed at `:1239` and `:1565`. So there is no `#ifdef` escape hatch. Homebrew's `qcoro6 0.13.0` satisfies it; `qcoro_enable_coroutines()` just adds `-fcoroutines`-equivalent flags, a no-op for clang with `-std=c++20` (`CMAKE_CXX_STANDARD 20` at `:16`).

**Authentication flow, precisely (`kio_sftp.cpp:793-1059`).**

1. `openConnectionWithoutCloseOnError()` builds an `AuthInfo`, and if no password was in the URL calls `checkCachedAuthentication(info)` (`:818`). **On macOS this is hard-wired to `return false`** — `kio:src/core/slavebase.cpp:1275-1282`. There is never a cache hit.
2. `sftpOpenConnection()` (`:640-736`): sets timeout/nodelay/compression/host/port/user, then **`ssh_options_parse_config(mSession, nullptr)` at `:708-712` — so `~/.ssh/config` *is* read** (libssh's parser, not OpenSSH's), then `ssh_connect`.
3. Host key: `ssh_session_is_known_server()` at `:842`, with a `messageBox(WarningContinueCancel, …)` for `CHANGED`/`NOT_FOUND`/`UNKNOWN` (`:854-887`) and `ssh_session_update_known_hosts()` at `:892`. **This path is D-Bus-free** — `SlaveBase::messageBox` goes over the worker socket via `send(INF_MESSAGEBOX)` / `waitForAnswer(CMD_MESSAGEBOXANSWER)` (`kio:src/core/slavebase.cpp:942-958`). Host-key prompting will work on macOS as-is, provided the app side implements the `INF_MESSAGEBOX` handler.
4. `ssh_userauth_none` → `ssh_auth_list` (`:907-918`).
5. **Public-key loop** `:923-940`. Calls `ssh_userauth_publickey_auto(mSession, nullptr, nullptr)`. Terminates when `rc != SSH_AUTH_DENIED` **or** `!mPublicKeyAuthInfo` **or** `!mPublicKeyAuthInfo->isModified()`.
6. GSSAPI `:944-951`; keyboard-interactive `:954-964` → `authenticateKeyboardInteractive()` `:392-475`.
7. **Password loop** `:976-1019`.
8. On success, `cacheAuthentication(info)` at `:1043` — **a no-op on macOS** (`kio:src/core/slavebase.cpp:1323-1330` returns `true` without storing anything). "Keep password" silently does nothing, every session re-prompts.

**Is the retry loop unbounded? Analysis with the empty-credentials bug.**

`openPasswordDialog` → `SlaveBase::openPasswordDialogV2` → `kio:src/core/slavebase.cpp:926-935`: without `WITH_QTDBUS` it returns `KJob::NoError` (== 0) **and never assigns `info = dlgInfo`**. So the worker sees "dialog succeeded, user did not cancel," with `info.password` unchanged.

- *Public-key loop (`:923-940`) — bounded, fails silently.* `auth_callback` (`:306-348`) allocates `mPublicKeyAuthInfo`, calls `setModified(false)` at `:333`, calls `openPasswordDialog` at `:338` which returns 0 → treated as success → `strncpy(buf, mPublicKeyAuthInfo->password.toUtf8().constData(), len-1)` at `:342` copies an **empty string** as the key passphrase. Back in the loop, `!mPublicKeyAuthInfo->isModified()` is true → `break` at `:936-939`. So: **terminates**, but *any passphrase-protected key silently fails to unlock* with no user-visible reason. Unencrypted keys and ssh-agent are unaffected because the callback is never invoked for them.
- *Password loop (`:976-1019`) — effectively unbounded; only the remote server stops it.* First iteration with an empty password enters the `if` at `:977`, calls `openPasswordDialog` at `:988` → 0 → not treated as cancel → falls through with `info.password` still empty. `wasUsernameChanged()` (`:310-322`) compares against `KUser().loginName()`; unchanged → no reconnect. `ssh_userauth_password(…, "")` at `:1008` → `SSH_AUTH_DENIED`. `isFirstLoginAttempt = false`, `info.password.clear()` (`:1017-1018`), loop repeats. From then on the `!isFirstLoginAttempt` branch is always taken, so it prompts (no-op) and retries with empty credentials forever. **The only terminator is the server**: after `MaxAuthTries` (OpenSSH default 6) sshd drops the connection, libssh returns `SSH_AUTH_ERROR`, and `:1012-1015` returns `ERR_CANNOT_LOGIN`. Against a server with unlimited/looped auth, or one that returns DENIED without disconnecting, this is a **hot spin with a network round-trip per iteration and no backoff** — the worker process pegs a core and never emits `finished()`. There is no iteration counter, no timer, no `wasKilled()` check inside the loop.
- *Keyboard-interactive (`:392-475`)*: bounded by the server's `SSH_AUTH_INFO` sequence, but note the pre-existing upstream bug at `:441-443`: it prompts with `infoKbdInt` and then reads `info.username` (the *other* object) as the answer.

**ssh-agent / ~/.ssh/config / known_hosts on macOS.**

| mechanism | consulted? | evidence | macOS behavior |
|---|---|---|---|
| ssh-agent | **only implicitly** — there is no `ssh_userauth_agent()` call anywhere in `kio_sftp.cpp` (grep confirmed); reliance is entirely on `ssh_userauth_publickey_auto` at `:924` | `kio_sftp.cpp:924` | Depends on `SSH_AUTH_SOCK` being in the KIO worker's environment. The worker is forked from the app, so it inherits the app's env. A GUI app launched by LaunchServices gets launchd's agent socket; an app launched from a terminal gets the terminal's. **Needs empirical verification** — see open questions. If it works, this is the primary usable auth path on macOS given the password bug. |
| `~/.ssh/config` | **yes** | `kio_sftp.cpp:708-712`, `ssh_options_parse_config(mSession, nullptr)` | libssh's own parser, not OpenSSH's. Apple-specific keywords (`UseKeychain`) and anything libssh doesn't implement are skipped. `IdentityFile`, `Port`, `User`, `HostName`, `ProxyCommand` are honored by libssh 0.12. A `Host *` block with `UseKeychain yes` (extremely common on macOS) will not load keys from the login Keychain — libssh has no Keychain integration. |
| `known_hosts` | **yes**, read and written | `kio_sftp.cpp:842` (`ssh_session_is_known_server`), `:892` (`ssh_session_update_known_hosts`) | Default `~/.ssh/known_hosts`. Works. Behind an App Sandbox this would be blocked — do **not** enable App Sandbox for the Phase 1 app. |

---

### 3. smb — firm recommendation: **do not un-gate `kio_smb`. Use native `mount_smbfs`/NetFS.**

**Gate confirmed.** `kio-extras:CMakeLists.txt:230-233`:
```
if(SAMBA_FOUND AND USE_DBUS)
    find_package(KF6 ${KF_MIN_VERSION} REQUIRED COMPONENTS DNSSD)
    add_subdirectory(smb)
endif()
```
`USE_DBUS` is OFF on APPLE (`:57-60`), so this is dead. `find_package(Samba)` itself *is* run on macOS (`:110-120`, gated only on `NOT WIN32`); `cmake/FindSamba.cmake:22-26` uses pkg-config `smbclient` plus `find_path(libsmbclient.h)`/`find_library(smbclient)` and additionally requires `smbc_set_context` **and** `smbc_option_set` (`CMakeLists.txt:112-113` + `FindSamba.cmake:31-45`).

**`KDSoapWSDiscoveryClient` is genuinely `REQUIRED` — verified.** `kio-extras/smb/CMakeLists.txt:6`:
```
find_package(KDSoapWSDiscoveryClient REQUIRED)
```
No `if()`, no `OPTIONAL`, no fallback. It is unconditionally linked (`smb/CMakeLists.txt:70`, `KDSoap::WSDiscoveryClient`) into `kio_smb_static`, whose source list unconditionally includes `wsdiscoverer.cpp` (`:37`). `wsdiscoverer.cpp:16-22` hard-includes `<WSDiscoveryClient>`, `<WSDiscoveryTargetService>`, and four `KDSoapClient/*` headers. **`brew search kdsoap` → "No available formula"; `brew search wsdiscovery` → error, no formula.** Neither KDSoap nor KDSoapWSDiscoveryClient is in Homebrew — both would have to be built from source.

**Full dependency bill to un-gate smb on macOS:** libsmbclient (brew samba 4.24.6 — *whether the bottle even ships `libsmbclient.h`/`libsmbclient.dylib`/`smbclient.pc` is unverified*), **KF6DNSSD** (source build), **KDSoap** (source build), **KDSoapWSDiscoveryClient** (source build), plus patching `USE_DBUS` out of the gate.

**Credentials (`smb/kio_smb_auth.cpp` + `smb/smbauthenticator.cpp`).** Two entry points, both dead-ended on macOS:
- `SMBWorker::checkPassword()` (`kio_smb_auth.cpp:15-77`) builds an `AuthInfo` for `smb://host/share`, calls `openPasswordDialog(info)` at `:63`, and on `KJob::NoError` does `url.setUser(info.username)` (`:66`) and optionally `cacheAuthentication(info)` (`:70`). With the D-Bus stub this returns `NoError` with an **empty username**, so it sets an empty user and reports success.
- `SMBAuthenticator::auth()` (`smbauthenticator.cpp:33-103`) is the libsmbclient callback. It calls `m_frontend.checkCachedAuthentication(info)` at `:74` (always false on macOS), falls back to `m_defaultUser`/`m_defaultPassword` from the KCM (`:88-91`), then `strncpy`s whatever it has — **empty strings** — and calls `smbc_set_credentials_with_fallback`. Note `:59-63`: for `SMBURLTYPE_ENTIRE_NETWORK` it returns early without authenticating at all. There is no interactive prompt in this path; there is no retry loop, so it fails cleanly rather than spinning, but it fails for every authenticated share.

Additionally the browse/discovery machinery is deeply tied to Linux: `smb/kded/` builds `smbnotifier` and a **kded module** linking `KF6::DBusAddons` and `QDBusConnection::sessionBus()` (`smb/kded/CMakeLists.txt:12`, `smb/kded/watcher.cpp:9,183`), plus `smb/CMakeLists.txt:87-95` requires `SharedMimeInfo` and runs `update_xdg_mimetypes`. `kio_smb_mount.cpp:36-49` reads Samba-specific `system.nt_sec_desc.*` xattrs.

**Recommendation (firm): ship SMB via macOS-native `mount_smbfs`/NetFS, not `kio_smb`.**

Reasoning:
1. Cost asymmetry is enormous. Un-gating buys three source-built dependency trees (KDSoap, KDSoapWSDiscoveryClient, KF6DNSSD) whose only purpose is *discovery* — WS-Discovery and DNS-SD browsing — which macOS already does natively and better (`NetFS.framework` + Bonjour, verified present at `/System/Library/Frameworks/NetFS.framework`).
2. The credential story is unsalvageable without also building the credential bridge (§7), and even then `SMBAuthenticator::auth()` is a synchronous libsmbclient callback with no prompt path — you'd have to rewrite it.
3. `/sbin/mount_smbfs` is present on this machine and gives you kernel-level SMB3 with multichannel, signing, encryption, Kerberos/SSO against AD, and Keychain-backed credentials — all things `kio_smb` on macOS would either lack or reimplement badly.
4. Once mounted at `/Volumes/share`, **every** other subsystem works for free: `isLocalFile()` is true, so Quick Look, drag-to-Finder, Open With, the terminal panel, thumbnails, and `KDirWatch` all just work with zero bridging (§6). Going through `kio_smb` means every one of those needs the download-to-temp bridge.
5. Feature parity with Finder is not the goal here — the project's advantage is *sftp*, which Finder genuinely lacks. SMB is where Finder is already strong; matching it natively is the cheap and correct play.

Concretely: a small `NSObject` wrapper around `NetFSMountURLSync()` (or shelling to `mount_smbfs`), surfaced in the Places panel as "Connect to Server…", with unmount via `DADiskUnmount`. Credentials go to the login Keychain via NetFS's own UI, which sidesteps the whole kpasswdserver problem for SMB entirely.

---

### 4. webdav / ftp — where they actually live

Both are in **`kio` core, not kio-extras**. I searched both checkouts: `kio-extras` contains **no** webdav or ftp worker at all (`find` for `*webdav*` / `*ftp*` under kio-extras returns only `sftp/`).

| protocol(s) | provided by | source | CMake gate | macOS status |
|---|---|---|---|---|
| `dav`, `davs`, `webdav`, `webdavs`, `http`, `https` | **`kio_http`** — one worker, six protocols | `kio:src/kioworkers/http/http.cpp` (1829 lines), manifest `kio:src/kioworkers/http/http.json` | `kio:src/kioworkers/CMakeLists.txt:6` — **unconditional**; parent gate `kio:src/CMakeLists.txt:4-6` is only `NOT ANDROID` | **Builds on macOS.** Deps are `KF6::KIOCore KF6::I18n KF6::ConfigCore Qt6::Network Qt6::Xml` (`http/CMakeLists.txt:17`) — no D-Bus, no external libs. `isWebDav()` at `http.cpp:105`; `listDir` → `DAV_PROPFIND` at `:783,827`. Already has a `Q_OS_MAC` branch at `:1770` for the UA string. |
| `ftp` | **`kio_ftp`** | `kio:src/kioworkers/ftp/ftp.cpp` (2617 lines), manifest `ftp.json` | `kio:src/kioworkers/CMakeLists.txt:4` — **unconditional** | **Builds on macOS.** Deps `Qt6::Network KF6::KIOCore KF6::I18n KF6::ConfigCore` (`ftp/CMakeLists.txt:19`). Only `#ifdef Q_OS_WIN` at `ftp.cpp:23`. |

There is **no FTPS/SFTP overlap** and no separate `kio_webdav` in KF6 — that was KDE4-era.

**webdav auth degrades gracefully; ftp does not.**

- *http/webdav*: `http.cpp:320-360` hooks `QNetworkAccessManager::authenticationRequired`. `checkCachedAuthentication` (`:342`) returns false, `openPasswordDialog` (`:351`) returns 0 without filling anything, so `authenticator->setUser("")/setPassword("")` is applied. **Qt's QNAM emits `authenticationRequired` at most twice per request** and then surfaces the 401 — so this **fails cleanly with an auth error, no hang.** Same shape for `proxyAuthenticationRequired` at `:363-412`. This makes webdav the *safest* protocol to ship first.
- *ftp*: `FtpInternal::ftpLogin()` at `ftp.cpp:505-661` is `do { … } while (++failedAuth);` — **a genuinely infinite loop on macOS.** Trace: with no credentials it falls back to anonymous (`:531-534`, `s_ftpLogin`/`s_ftpPasswd` from `:63-64`). If anonymous is refused, `failedAuth` becomes 1 and the prompt block at `:549` is entered; `openPasswordDialog` at `:579` returns 0 → the `else` branch at `:582` runs → `info.getExtraField("anonymous")` is false (set at `:544`) → `user = info.username; pass = info.password;` — and **`info.username` was never assigned** (it's only set at `:563-565` when `user != "anonymous"`, which is false here) → both become **empty strings**. Login fails again, and `:652-661` calls `ftpOpenControlConnection()` to **re-establish a fresh TCP connection** each iteration. So unlike sftp there is no server-side `MaxAuthTries` backstop: it reconnects forever, hammering the server. Proxy auth has the same stub at `:2496-2523`.
- *TLS rules on webdav*: `handleSslErrors` at `http.cpp:138-235` works — `sslError()` goes over the worker socket (`kio:src/core/slavebase.cpp:962-974`, `INF_SSLERROR`/`CMD_SSLERRORANSWER`), and so does the "accept forever?" `messageBox` at `:207-215`. **But the answer is never persisted**: `KSslCertificateManager::setRule()` is `#ifdef WITH_QTDBUS`-empty (`kio:src/core/ksslcertificatemanager.cpp:402-407`) and `rule()` returns a blank `KSslCertificateRule` (`:423-430`) because the store lives in the `kssld` kiod module, which isn't built. Self-signed `davs://` hosts will re-prompt on every single connection.

---

### 5. thumbnail

**Architecture (three tiers, verified).**

1. **In-process job.** `KIO::PreviewJob` (`kio:src/gui/previewjob.cpp`, 383 lines) is now a thin scheduler; the real work is `KIO::FilePreviewJob` (`kio:src/gui/filepreviewjob.cpp`, 858 lines). It stats the item, picks a plugin by MIME type, and enforces size caps.
2. **Out-of-process worker.** For normal thumbcreator plugins, `FilePreviewJob::createThumbnail()` at `filepreviewjob.cpp:565-640` builds a `thumbnail:/<absolute-local-path>` URL and does `KIO::get(thumbURL)` (`:606-609`), passing `mimeType`, `width`, `height`, `plugin`, `enabledPlugins`, `devicePixelRatio`, `cache`, `shmid` as metadata. That is `kio_thumbnail` (`kio-extras/thumbnail/thumbnail.cpp`), a separate process.
3. **Plugins inside the worker.** `ThumbnailProtocol::pluginForMimeType()` at `thumbnail.cpp:419-430` does `KPluginMetaData::findPlugins("kf6/thumbcreator")`; `getThumbCreator()` at `:739` dlopens and caches them. They implement `KIO::ThumbnailCreator::create(KIO::ThumbnailRequest)` — and the request is built as **`QUrl::fromLocalFile(filePath)`** (`thumbnail.cpp`, in `createThumbnail`). **Plugins only ever see local paths.**
   *Fourth path:* XDG "standard thumbnailers" (`*.thumbnailer` files, `filepreviewjob.cpp:744-786`) are external executables run by `KIO::StandardThumbnailJob` **in the app process** (`:598-603`), bypassing the worker. Almost nothing on macOS installs those.

**Plugin deps** (`kio-extras/thumbnail/CMakeLists.txt`): always-built — `imagethumbnail` (:99), `jpegthumbnail` (:111, optional KExiv2Qt6 at :45-51), `svgthumbnail` (:135, Qt::Svg), `textthumbnail` (:149, **KF6::SyntaxHighlighting**), `comicbookthumbnail` (:189, KF6::Archive), `kraorathumbnail` (:212, KF6::Archive), `windowsexethumbnail`/`windowsimagethumbnail` (:75-82 of that block), `directorythumbnail`, `opendocumentthumbnail`, `ebookthumbnail`, `appimagethumbnail`. Non-Windows-only: `djvuthumbnail` (:162-180). Optional: `exrthumbnail` (OpenEXR ≥3, :184), `cursorthumbnail` (**X11 Xcursor** — `:219`, guarded by `WITHOUT_X11`; set `-DWITHOUT_X11=ON`), `audiothumbnail` (Taglib ≥1.11, :288). KF6::SyntaxHighlighting is a required top-level dep (`kio-extras:CMakeLists.txt:48`) and is not in Homebrew.

**Does it work for remote files? Only via a full download, and it's disabled by default.**

`FilePreviewJob::getOrCreateThumbnail()` (`filepreviewjob.cpp:418-440`): if `m_fileItem.localPath()` is empty and the item isn't a dir, it tries KIOFuse (`createThumbnailViaFuse`, `:442-470`) — **compiled out on macOS**, since `:444` is `#if defined(WITH_QTDBUS) && !defined(Q_OS_ANDROID)` and the `#else` at `:468` goes straight to `createThumbnailViaLocalCopy()`. That (`:489-514`) does `KIO::file_copy(remoteUrl → ~/Library/Caches/<app>/kpreviewjob/<pid>/<uuid>.<ext>)` and thumbnails the copy. So **remote thumbnails = download the whole file**.

Two guards make this near-useless out of the box:
- `filepreviewjob.cpp:295-310`: for anything not `isLocalAndFast`, `MaximumRemoteSize` defaults to **`0`** and `EnableRemoteFolderThumbnail` defaults to **`false`**. With `size > 0` the item is skipped outright. Dolphin only overrides this for the info panel and tooltips, and only for local items: `dolphin:panels/information/informationpanelcontent.cpp:191` and `dolphin:views/tooltips/tooltipmanager.cpp:140` both pass `m_item.isLocalFile() && !m_item.isSlow()` to `setIgnoreMaximumSize()`.
- `:435-437` skips remote dirs entirely.

**SHM transport — a real macOS constraint I measured.** `filepreviewjob.cpp:812-830` uses **System V** `shmget(IPC_PRIVATE, size, IPC_CREAT|0600)`, enabled by `WITH_SHM` at `:18-22` (`Q_OS_UNIX && !Q_OS_ANDROID && !Q_OS_HAIKU` → **on** for macOS). Measured on this machine (macOS 26.5.2, arm64):
```
kern.sysv.shmmax: 4194304   # 4 MiB per segment
kern.sysv.shmall: 1024      # 1024 pages = 4 MiB TOTAL, system-wide
kern.sysv.shmseg: 8         # 8 segments per process
```
A 512×512 @2× ARGB32 thumbnail is exactly 4 MiB — the entire system-wide SysV budget. With `maxWorkers` concurrent previews you will exhaust `shmall`/`shmseg` immediately. **Good news:** it degrades, it doesn't break. `SHM::create()` returns `nullptr` on `shmget` failure (`:815-818`), no `shmid` metadata is sent, and `thumbnail.cpp:391-396` falls back to `stream << img` over the socket. So the effect is a silent throughput loss, not a crash. Recommend just forcing the stream path on macOS rather than fighting `sysctl`.

**How it should interact with macOS QuickLook.** Recommendation: **replace tiers 2+3 for local files with `QLThumbnailGenerator`, keep the KIO thumbnail worker only as a fallback.** `/System/Library/Frameworks/QuickLookThumbnailing.framework` is present. `QLThumbnailGenerator.generateBestRepresentation(for:)` gives you every format the user's installed apps can thumbnail (Sketch, Figma, Xcode, Office, RAW, HEIC, video posters) with OS-level caching and correct DPR — strictly a superset of what these plugins do, minus DjVu/comics/Krita. The clean seam is `FilePreviewJob::createThumbnail(const QString &pixPath)` at `filepreviewjob.cpp:565`: at that point the path is *always* local and absolute (`Q_ASSERT_X(info.isAbsolute())` at `:567`), whether it came from a real local file or from the download-to-temp copy. Route that through an ObjC++ `QLThumbnailGenerator` bridge and you get QuickLook thumbnails for local *and* (post-download) remote files with one hook. Keep `kio_thumbnail` for the handful of formats QuickLook doesn't know. Do **not** try to make thumbcreator plugins remote-aware — the `ThumbnailRequest` API is `QUrl::fromLocalFile`-only by construction.

---

### 6. Network-transparency audit — `dolphin/src`

35 `isLocalFile()` call sites and 78 `toLocalFile()` sites (tests excluded: 33 and ~30). Sorted by whether they need a download-to-temp bridge on macOS.

**A. Hard blockers — assume a local path, silently degrade or break on `sftp://`**

| site | what it assumes | consequence on remote | fix |
|---|---|---|---|
| `dolphin:panels/terminal/terminalpanel.cpp:245-260`, `:316-326` | `url.isLocalFile()` → `sendCdToTerminal(toLocalFile())`; else `KIO::mostLocalUrl` for `:local` protocols; else `sendCdToTerminalKIOFuse(url)` | sftp is `Class = :internet` (verified in `kio-extras/sftp/sftp.json`), so `mostLocalUrl` is skipped and it falls to the **KIOFuse** path, which is D-Bus-only → terminal panel silently does nothing | either disable the panel for remote URLs, or `cd` into an sshfs/`mount_smbfs` mount if one exists; a real fix is spawning `ssh user@host` in the panel |
| `dolphin:dolphinmainwindow.cpp:1431-1460` (`openTerminalJob`) | same three-tier fallback, ending at `QDir::homePath()` at `:1458` | "Open Terminal" on an sftp view opens `$HOME` — wrong location, no warning | same |
| **Open With / double-click** → `KIO::OpenUrlJob` → `KIO::DesktopExecParser` | `kio:src/core/desktopexecparser.cpp:398-462` — the **entire** kioexec + KIOFuse block is inside `#ifdef WITH_QTDBUS` | On macOS the block vanishes, so a remote URL is substituted **verbatim** into the app's argv. The target app receives the literal string `sftp://host/path/file.pdf` and fails. **This is the single most user-visible break.** | app-side bridge: intercept non-local URLs, `KIO::file_copy` to a temp dir, launch via `NSWorkspace` with the local path, watch for modification and upload back (that is exactly what `kioexec` does) |
| `kio:src/core/desktopexecparser.cpp:275-283` (`kioexecPath()`) | `Q_ASSERT(QFileInfo::exists(kioexec))` | `kioexec` is **not built** without D-Bus (`kio:src/CMakeLists.txt:23-26`). Reached unconditionally from `:386-396` when `tempFiles` is set — **asserts in debug, execs a nonexistent binary in release** | must be patched or the `tempFiles` path disabled |
| `dolphin:kitemviews/kfileitemmodel.cpp:540-566` (**drag MIME data**) | builds `mostLocalUrls` via `item.mostLocalUrl(&isLocal)` and calls `KUrlMimeData::setUrls(urls, mostLocalUrls, data)` | For sftp, `mostLocalUrl()` returns the sftp URL itself → the pasteboard carries a non-`file://` URL. **Dragging to Finder or any native app produces nothing.** Same code in `dolphin:panels/folders/treeviewcontextmenu.cpp:155-160` | write `NSPasteboard` `NSFilePromiseProvider` and materialize via `KIO::file_copy` on drop; or eagerly download to temp and put a `file://` URL on the pasteboard |
| `dolphin:views/dolphinview.cpp:1835-1846` | `browseThroughArchives && item.isFile() && url.isLocalFile()` | Cannot browse into a `.zip`/`.tar` that lives on the remote — even though `kio_archive` would handle it | route through a temp download, or accept the limitation |
| `dolphin:views/dolphinview.cpp:1849-1852` | `KDesktopFile desktopFile(url.toLocalFile())` for `application/x-desktop` | empty path → `KDesktopFile("")`. Moot on macOS (no .desktop files) but a latent crash-adjacent path |
| `dolphin:kitemviews/kfileitemmodelrolesupdater.cpp:1348-1352` | `const QString path = item.localPath(); … m_directoryContentsCounter->scanDirectory(path, …)` | empty path handed to the directory scanner thread for remote dirs | there *is* a remote branch at `:1269-1272` that resets size to -1, but `:1276` (`ContentCount` mode or `isSlow()`) can still reach `:1348` |
| `dolphin:kitemviews/kfileitemmodelrolesupdater.cpp:837`, `:1385` | `Baloo::File file(item.localPath())`, `m_balooFileMonitor->addFile(item.localPath())` | Baloo isn't shipping on macOS anyway; must be compiled out |
| `dolphin:kitemviews/kfileitemmodel.cpp:2353-2355` | `KFileMetaData::UserMetaData md(item.localPath())` for the Rating role | empty path; ratings/tags/comments silently unavailable remotely (correct, but no UI feedback) |

**B. Correct-but-degrading — behave sanely, just lose features**

| site | behavior |
|---|---|
| `dolphin:panels/information/informationpanelcontent.cpp:191` and `dolphin:views/tooltips/tooltipmanager.cpp:140` | `setIgnoreMaximumSize(isLocalFile() && !isSlow())` — for remote, the `MaximumRemoteSize=0` default (§5) kills the preview entirely |
| `dolphin:panels/information/informationpanelcontent.cpp:282` | `m_preview->setAnimatedImageFileName(itemUrl.toLocalFile())` — **empty string** for remote animated GIFs; no guard |
| `dolphin:statusbar/diskspaceusagemenu.cpp:95-113`, `dolphin:statusbar/mountpointobservercache.cpp:44-47` | `QStorageInfo(toLocalFile())` / `Solid::Device::storageAccessFromPath()` — free-space widget is local-only. sftp *does* support `fileSystemFreeSpace` (`kio_sftp.cpp:2219-2237`, `statvfs@openssh.com`), so this is leaving capability on the table |
| `dolphin:views/versioncontrol/versioncontrolobserver.cpp:172` | VCS overlays local-only — correct |
| `dolphin:views/viewproperties.cpp:181-182` | `.directory` view props stored only for local dirs; remote falls back to the global store — correct |
| `dolphin:views/draganddrophelper.cpp:66,76` | `supportsDropping()` / `updateDropAction()` — `!item.isLocalFile()` **accepts** the drop, so KIO handles remote→remote copies. Fine |
| `dolphin:dolphinviewcontainer.cpp:571,604` | title/caption formatting only |
| `dolphin:dolphinviewcontainer.cpp:996-1010` | `Q_ASSERT(url.isLocalFile())` in `isTopMostExistingParentFolderWritable` — **assert fires** if ever reached with a remote URL; check callers |
| `dolphin:dolphinviewcontainer.cpp:1114-1125` | on "current dir removed", only local gets ancestor-walk recovery |
| `dolphin:views/dolphinview.cpp:2755-2760` (`copyPathToClipboard`) | falls back to `url().toDisplayString()` when `localPath()` is empty — correct, but on macOS should probably still copy a POSIX path when one exists |
| `dolphin:dolphinviewcontainer.cpp:796`, `dolphin:kitemviews/kfileitemmodel.cpp:644` | executable-script detection local-only — correct and desirable |
| `dolphin:itemactions/setfoldericonitemaction.cpp:54,194`, `dolphin:itemactions/hidefileitemaction.cpp:56,100-104` | both use `mostLocalUrl`/`localPath` — no-ops remotely |
| `dolphin:search/dolphinquery.cpp:46,207,369` | Baloo search, local-only by definition |
| `dolphin:panels/folders/folderspanel.cpp:320`, `dolphin:panels/folders/treeviewcontextmenu.cpp:80,110` | "limit to home directory" local-only |
| `dolphin:dolphinpart.cpp:265-270,393` | KPart; likely dropped for the macOS shell |

**Bottom line for §6:** you need exactly **one** shared piece of machinery — a *materialize-to-temp-and-write-back* service (what `kioexec` is) — and it unblocks Open With, Quick Look, drag-to-Finder, and archive browsing all at once. Terminal and free-space are separate, smaller items.

---

### 7. Phase 1 MVP — what ships, how, and what it costs

**Prerequisite, blocking everything below — build the credential bridge first (P0).**

Every remote protocol is broken by the same three-line stub (`kio:src/core/slavebase.cpp:926-935`, `:1275-1282`, `:1323-1330`). Do **not** try to revive `kpasswdserver` or D-Bus. The correct fix is already modeled twice inside KIO: `messageBox()` (`slavebase.cpp:942-958`) and `sslError()` (`:962-974`) both prompt the user over the **worker↔app socket** using an `INF_*` / `CMD_*ANSWER` pair — no D-Bus. Add a third pair:
- `INF_AUTHINFO` after `INF_SSLERROR` in `kio:src/core/workerinterface_p.h:32-48`, and `CMD_AUTHINFOANSWER` after `CMD_SSLERRORANSWER` in `kio:src/core/commands_p.h:20-56` (both enums explicitly reserve trailing space for exactly this).
- Reimplement `openPasswordDialogV2` on top of it; handle it in `kio:src/core/workerinterface.cpp` next to the `INF_MESSAGEBOX` case at `:222`.
- App side: a native Cocoa credential sheet backed by **macOS Keychain** (`kSecClassInternetPassword`, keyed on scheme+host+port+realm) — this simultaneously fixes `checkCachedAuthentication`/`cacheAuthentication` and gives users Keychain sync for free.
- **Separately and immediately**, bound the two retry loops even with the bridge in place: `kio-extras/sftp/kio_sftp.cpp:976` and `kio:src/kioworkers/ftp/ftp.cpp:546-661` both need an attempt cap (3) and a `wasKilled()` check.

**Ship in Phase 1:**

| # | protocol | how | why | effort (eng-days) |
|---|---|---|---|---|
| 0 | **credential bridge** (prerequisite) | `INF_AUTHINFO`/`CMD_AUTHINFOANSWER` + Keychain-backed native sheet; bound the sftp/ftp loops | unblocks 1–3; without it sftp and ftp are actively harmful (infinite loops) | **5** |
| 1 | **sftp** | build `kio-extras/sftp` as-is: `brew install libssh qcoro6`; `-DBUILD_KCMS=OFF -DBUILD_DOC=OFF -DWITHOUT_X11=ON`. Wire `INF_MESSAGEBOX` for host-key prompts. Verify ssh-agent + `~/.ssh/config` end-to-end | **the product thesis.** No platform gate (`CMakeLists.txt:207`), both deps in Homebrew, `Class=:internet`, full read/write/rename/symlink/statvfs | **3** |
| 2 | **webdav / davs** | already built by `kio:src/kioworkers/http`; nothing to enable. Add a per-session in-memory `KSslCertificateManager` shim so self-signed hosts don't re-prompt every connection | **zero marginal build cost**, zero external deps, and the *only* protocol whose auth already fails safely (QNAM caps `authenticationRequired` at 2) | **2** |
| 3 | **ftp** | already built by `kio:src/kioworkers/ftp`. **Must** land the `ftpLogin()` loop cap before shipping — the reconnect-forever bug is a server-abuse hazard, not just a hang | free once #0 lands; still genuinely used for NAS/router/legacy hosts | **1.5** |
| 4 | **smb** | **native `mount_smbfs`/NetFS**, surfaced as "Connect to Server…" in Places; unmount via `DADiskUnmount` (Dolphin already links DiskArbitration for trash). **Do not build `kio_smb`.** | §3 — three source-built deps for discovery macOS already does, plus everything downstream works for free once mounted at `/Volumes/…` | **2** (vs. ~15 to un-gate `kio_smb`) |
| 5 | **archive + filter** | free (`CMakeLists.txt:198,200`, unconditional) — `tar`/`zip`/`ar`/`sevenz` + 6 compression filters | almost no cost, visible feature | **0.5** |
| 6 | **materialize-to-temp bridge** | reimplement `kioexec` in-process: `KIO::file_copy` → temp → `NSWorkspace` open / Quick Look / pasteboard `NSFilePromiseProvider` → `KDirWatch` → upload back. Hook Open-With, drag-to-Finder, Quick Look, archive-browse | §6 — one component unblocks four separate broken features; also fixes the `Q_ASSERT` at `desktopexecparser.cpp:282` | **6** |
| 7 | **thumbnails** | route `FilePreviewJob::createThumbnail(pixPath)` (`filepreviewjob.cpp:565`) through `QLThumbnailGenerator`; keep `kio_thumbnail` as fallback; force the non-SHM stream path; raise `MaximumRemoteSize` to a sane default (e.g. 8 MiB) | §5 — QuickLook is a strict superset for local files and the seam is already local-path-only | **3** |

**Explicitly deferred:** `smb` via `kio_smb`, `nfs`, `mtp`, `afc`, `fish`, `man`, `info`, `filenamesearch`, `activities`, `recentlyused`, all three KCMs.

**Total Phase 1 remote-filesystem effort: ~23 engineer-days.** Serialized critical path is #0 → #1 → #6; #2/#3/#4/#5 parallelize.

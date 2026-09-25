# 0.5.0 release preparation and verification

2026-09-25. What has actually been done for 0.5.0 and what is still outstanding.

**Status: published and verified.** [Tursora 0.5.0](https://github.com/zerolfx/Tursora/releases/tag/v0.5.0) is the latest stable release, published 2026-09-25.

## Why this release exists

Three changes merged since 0.4.3, one of them large enough to move the minor version:

| Change | Record |
|---|---|
| Opening a ZIP lists it from the table of contents instead of extracting it; bytes arrive only when something reads them | [lazy-zip-browsing.md](lazy-zip-browsing.md) |
| **New Folder** opens the name for editing; an optional **Open Selection (Alternative)** command can take Return; ZIP extraction runs as a cancellable File Operations task | [finder-new-folder-rename.md](finder-new-folder-rename.md), [custom-shortcuts.md](custom-shortcuts.md), [archive-extraction-progress.md](archive-extraction-progress.md) |
| With the Terminal panel turned off, its toolbar button is withdrawn rather than dimmed | [terminal-entry-point-visibility.md](terminal-entry-point-visibility.md) |

The version is 0.5.0 rather than 0.4.4 because the ZIP change adds behaviour — drag and share of unextracted items, thumbnails, prefetching, a new command — rather than only fixing it.

## Local verification performed

| Check | Result |
|---|---|
| Debug build | clean |
| Full smoke suite | three consecutive runs, **4,949 checks each**, exit 0, each printing `SMOKE TEST PASSED`; the last check reports the archive tool ran on the main thread in 0 of 108 runs |
| Release tool tests | 90 tests, OK; `release-notes.py 0.5.0` extracts the dated section |
| **Packaged application** | release bundle built by `make-app.sh` (short version 0.5.0), launched on a fixture folder holding a 309-entry ZIP with a 200 MB member, and used — see below |

### What the packaged application was seen to do

Scope: one fixture, list view only, the default settings of this machine's installed domain.

- **Opening the ZIP extracted nothing.** After entering `Project/` the session's temporary directory held only its private clone of the archive (356 KB) and the lock file; `big.bin` had not been written. The status bar reads "ZIP · Read-only".
- **Quick Look on an unextracted member** opened the panel and showed the text of `readme.txt`.
- **New Folder** (File ▸ New Folder) in an ordinary folder put the row into editing immediately with "untitled folder" selected. The typed name was committed when focus left the field; the folder on disk carried the new name. Return itself could not be delivered: background accessibility input sets the text rather than pressing the key, so the Return path was not exercised.
- **Extract** on the ZIP produced a File Operations row, "Extract "Sample.zip"", which finished as Completed, 209.9 MB of 209.9 MB, 1 completed · 0 skipped. The extracted `big.bin` is byte-identical to its source.
- **Quitting removed the session's temporary directory.**

## Verification of the published artifacts

| Check | Result |
|---|---|
| Release run | [36131960552](https://github.com/zerolfx/Tursora/actions/runs/36131960552), success, dispatched on `main` after [Build 36131447052](https://github.com/zerolfx/Tursora/actions/runs/36131447052) passed on the same commit |
| Tag | `v0.5.0` resolves to `7fd6453d9598214952f7b1f8341f4ce4244858e1`, whose tree is identical to the reviewed head of the preparation pull request |
| Release | not a draft, not a prerelease, the repository's latest, three assets |
| Checksum | recomputed independently, matches the published `SHA256SUMS.txt`: `3dfc973f16d58e1c3dcf130d6ceb1e40d6399cefb863f44cf0c6cab77383ea19` |
| Disk image | mounted read-only: `Tursora.app`, the `Applications` link to `/Applications`, the background and its license |
| Application inside | `CFBundleShortVersionString` 0.5.0, `CFBundleVersion` 1790336930, `lipo -archs` arm64, `codesign --verify --deep --strict` clean, `LSMinimumSystemVersion` 14.0, `update-metadata.py verify-bundle` clean |
| Stable feed | `verify-appcast` passes against the DMG and app; `releases/latest/download/appcast.xml` serves byte-identical content to the release asset |
| Homebrew cask | regenerated from the published bytes |
| **The published binary, run and looked at** | the app copied out of the downloaded DMG was opened on the same fixture: the ZIP listed read-only with only the 356 KB clone on disk, Quick Look showed the unextracted `readme.txt`, and quitting removed the session's temporary directory |

The DMG's `.DS_Store` layout was checked by the Release workflow; `verify-dmg-layout.py` was not rerun locally, because its `ds_store` dependency lives only in the workflow's virtual environment.

## Not done

- **The progress bar and Cancel were not seen mid-flight.** The fixture's large member is zeros and extracted in well under a second; only the finished row was observed.
- **The terminal button's withdrawal was not looked at.** Doing so means turning the Terminal panel off in the installed app's own settings.
- **Open Selection (Alternative)** was not bound to Return and tried.
- **No production-feed update** from an installed 0.4.3 to 0.5.0 was exercised.
- Still outstanding from the ZIP record: drag to Finder from each view, Share through Mail and AirDrop, the Quick Look placeholder while loading, a folder of 20,000 files, and a ZIP nested in another.

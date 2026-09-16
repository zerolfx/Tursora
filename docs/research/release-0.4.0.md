# 0.4.0 release preparation and verification

2026-09-16. What has actually been done for 0.4.0 and what is still outstanding.

**Status: published and verified.** [Tursora 0.4.0](https://github.com/zerolfx/Tursora/releases/tag/v0.4.0) is the latest stable release, published 2026-09-16. The packaged-app interaction check is still outstanding; see "Not done".

## Scope of the release

0.4.0 is the round that followed a feature comparison against [Iruka](https://iruka.sh), a Dolphin-inspired macOS file manager in the same niche. The owner chose four items from that comparison and excluded the rest:

| Merged | What it is |
|---|---|
| [#16](https://github.com/zerolfx/Tursora/pull/16) | Batch rename's `#` placeholder — KIO's Enumerate semantics, replacing Finder's Name and Index / Name and Counter, which it subsumes (D80) |
| [#17](https://github.com/zerolfx/Tursora/pull/17) | A docked preview pane that renders Markdown (D81–D83) |
| [#18](https://github.com/zerolfx/Tursora/pull/18) | Finder's column view as a third file view (D84) |
| [#19](https://github.com/zerolfx/Tursora/pull/19) | Content search that does not need the system index (D85) |

Excluded by the owner during the same round, recorded in [ROADMAP](../ROADMAP.md): git in any form, developer-only remote access (SFTP, SSHFS, SCP, S3), Intel support, in-place text editing, syntax highlighting, file and folder comparison, and gallery view.

## Source under test

The tip of `main` after #19, `0ba022c`, plus the version change in this preparation commit. `main` is linear: every pull request was rebase-merged.

## Local verification performed

| Check | Result |
|---|---|
| Debug build | clean |
| Full smoke suite | three consecutive runs on the final tree, 4,335 checks each, exit 0 |
| Release tool tests | `python3 -m unittest discover -s app/tools -p 'test_*.py'` — 90 tests, OK |
| Site build | `python3 site/build.py` — 2 languages, 90 references checked, 29 screenshots passed alpha checks, version resolved to 0.4.0 |
| Release bundle | `tools/make-app.sh release`: `CFBundleShortVersionString` 0.4.0, `CFBundleIdentifier` com.tursora.Tursora, `lipo -archs` arm64, `codesign --verify --deep --strict` clean, `plutil -lint` OK, `AppIcon.icns` present |
| Drag-install DMG | `TURSORA_PYTHON=/opt/homebrew/bin/python3.13 tools/make-dmg.sh`: layout verified (application left, Applications right, arrow background), 6,669,336 bytes, SHA-256 `0d6211b7725247c24db4899da09be81159b7b0f106c65619580480a5cbcb9b32` |

The local DMG is not a published asset. Its bytes come from a local build of the same source; the workflow builds its own, and the cask must be generated from the published file, never from this one.

The three smoke runs were executed with the shared verification lock held and the test process kept frontmost through System Events, because one check — `shortcuts: native menu resolves the owned active pane` — resolves a menu command through `NSApp`'s responder chain and cannot pass while the app is in the background.

## Review performed on the round

Each of the four features went through adversarial review before merging: roughly 240 findings raised across the round, of which about 100 were confirmed and fixed and the rest refuted under two independent skeptics each. Several confirmed findings were defects the feature's own checks had passed over, and two were regressions introduced by earlier fixes in the same work. The ones worth remembering:

- Every split tab title rendered with an ellipsis, because a truncating `NSTextField` cell clips before its text reaches the frame edge and the labels were sized to the glyph width.
- Nested Markdown lists took their marker from the wrong nesting level, so bullets under a numbered step rendered as numbers.
- A drop over the column view's preview column resolved to the previewed item's own path; a package is a directory on disk, so a file dropped over a selected `.app` would have been moved inside the bundle, breaking its signature.
- Content scanning would have materialised cloud placeholders, downloading an evicted iCloud folder during a search.
- Adding one field to `SearchRequest` would have silently emptied every saved search, because synthesized `Codable` throws for an absent key instead of using a property default and the store decodes the whole array with `try?`.

## Verification of the published artifacts

Performed against the bytes downloaded from the release, not against the local build.

| Check | Result |
|---|---|
| Release | tag `v0.4.0`, not a draft, not a prerelease, three assets |
| Checksum | `shasum -a 256` recomputed independently matches the published `SHA256SUMS.txt`: `4953d185967c83f7c54782eac3fbec8d9a6f10f3d1c454a84d4e026395f76858` |
| Published DMG | 6,582,647 bytes. The local build was 6,669,336 — a different machine produces different compression and timestamps, which is why the cask and this check use the published bytes only |
| Application inside | `CFBundleShortVersionString` 0.4.0, `CFBundleIdentifier` com.tursora.Tursora, `lipo -archs` arm64, `codesign --verify --deep --strict` clean, `LSMinimumSystemVersion` 14.0 |
| Update feed | `appcast.xml` points at `releases/download/v0.4.0/Tursora-0.4.0-macOS-arm64.dmg` |

## Not done

- **No packaged-app interaction check.** None of the four features has been clicked through in the packaged application. The column widths, the preview column's appearance, Markdown layout and the search panel's new row are unverified by eye. Each feature record says so individually.
- **No isolated Homebrew install.** The cask will be generated from the published bytes and its syntax checked; `brew install` / `brew uninstall` into a throwaway prefix is not part of this round.
- **No launch of the downloaded application.** The published bundle will be mounted and inspected, not opened.
- **No genuine cloud-placeholder check.** The `SF_DATALESS` guard is covered by a unit-level check of the tally, not by a real evicted iCloud file, which cannot be created headlessly.

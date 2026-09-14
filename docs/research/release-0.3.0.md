# 0.3.0 release preparation and verification

2026-09-14. This record covers what has actually been done for 0.3.0 and what is still outstanding. It is written in English because the owner moved the product-facing documents to English; the earlier records keep their original language until they are rewritten.

**Status: published and verified.** [Tursora 0.3.0](https://github.com/zerolfx/Tursora/releases/tag/v0.3.0) is the latest stable release. The packaged-app interaction check is still outstanding; see "Not done".

## Scope of the release

0.3.0 is the first release after the feature round merged as [#10](https://github.com/zerolfx/Tursora/pull/10): batch rename, Trash browsing with Put Back and Empty Trash, two-way terminal folder sync covering zsh, bash and fish, the three new date sort keys with optional list columns and folder sizes, Finder's spring-loaded folders / breadcrumb drops / command-drag move, and the command palette. The user-visible list is the `0.3.0` section of [the changelog](../../CHANGELOG.md); the per-feature scope, evidence and remaining limits are in the feature records linked from [the documentation index](../README.md).

## Source under test

The prepared commit is the tip of `main` after that merge, `37fa071`, plus the single-source version change described below (`feat: add Trash browsing, more sort keys and columns, folder sizes, and Finder drag behaviours`), plus this round's release metadata: the changelog section, the new `VERSION` file and this record.

## The version now has one source

Preparing this release started by editing the number in about twenty places: the README, both product pages, the installation guide and the packaging script. That duplication had already produced a stale claim — the spec still described 0.2.0 as the published release two releases later, which the English documentation rewrite caught. So before publishing, the number moved to a single `VERSION` file at the repository root:

- `app/tools/make-app.sh` reads it, and the Release workflow still overrides it through `TURSORA_VERSION`, so a dispatch always wins over the checkout.
- `site/index.html`, `site/zh.html` and `site/install.md` carry a `{{VERSION}}` placeholder that `site/build.py` substitutes, failing the build on any placeholder it cannot resolve.
- `README.md` names no version at all, because GitHub renders it from source with nothing to substitute: it links to `releases/latest` and names the asset by pattern.
- `app/tools/test_version_source.py` fails if the current version reappears in that prose, if the packaging script stops reading the file, or if `VERSION` has no dated changelog section. Dependency versions and references to past releases are deliberately left alone.

Publishing now edits `VERSION` and the changelog section. The decision is recorded as D75. `main` is linear — the pull request was re-applied as a rebase, so `37fa071` sits directly on `a301044` with no merge commit.

## Local verification performed

| Check | Result |
|---|---|
| Debug build | clean, no errors |
| Full smoke suite | three consecutive runs on the final tree, 4,103 checks each, exit 0, 211 / 216 / 213 s |
| Release tool tests | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s app/tools -p 'test_*.py'` — 89 tests, OK (83 existing plus the six new version-source guards) |
| Release bundle | `tools/make-app.sh release`: `CFBundleShortVersionString` 0.3.0, `CFBundleVersion` 1789313539, `CFBundleIdentifier` com.tursora.Tursora, `lipo -archs` arm64, `codesign --verify --deep --strict` passed |
| Drag-install DMG | `TURSORA_PYTHON=/opt/homebrew/bin/python3.13 tools/make-dmg.sh`: layout verified (application left, Applications right, arrow background), 6,486,135 bytes, SHA-256 `41c4f1ed1b6e233b611273710ca02d7bf4dd4bc57359c7d945d7d52554844b8c` |

The local DMG is not a published asset. Its bytes come from a local build of the same source; the workflow builds its own, and the cask must be generated from the published file, never from this one.

The three smoke runs were executed with the shared verification lock held, and with the test process kept frontmost through System Events: one check, `shortcuts: native menu resolves the owned active pane`, requires the process to be the active application, which a process launched from a background tool cannot arrange for itself.

## Not done

- **No packaged-app interaction check.** The 0.3.0 bundle was built and inspected, but nobody has clicked through the new sheets, panels and menus in the packaged application. Every feature record for this round records the same gap.
- **No isolated Homebrew install.** The cask was generated from the published bytes and its syntax checked, but `brew install` / `brew uninstall` into a throwaway prefix was not run in this round; the Homebrew workflow covers it on its own runner.
- **No launch of the downloaded application.** The published bundle was mounted and inspected, not opened.

## Publication

[Release run 34796223610](https://github.com/zerolfx/Tursora/actions/runs/34796223610) succeeded on `main`. The `v0.3.0` tag resolves to `54c867d4138340be5b9af314e84bd5ccd8f07d3b`, which is exactly the reviewed tip of `main`; the release is neither a draft nor a prerelease, and the GitHub API reports it as `latest`.

`CFBundleVersion` is `1789348408`, the Unix committer timestamp of that commit — checked against `git show -s --format=%ct 54c867d4`, not assumed.

### Published assets, downloaded again

The workflow builds its own DMG, so these bytes differ from the local image built during preparation (6,486,135 bytes). The local file is not a published asset and was not used for anything below.

| Asset | Bytes | SHA-256 |
|---|---:|---|
| `Tursora-0.3.0-macOS-arm64.dmg` | 6,403,387 | `9706add96eab66828b86700125c657537cedff5c92680108d79e96283ef99557` |
| `appcast.xml` | 6,523 | `887fb499b1a3ca1800c0e2fb5b01c24c553d72dd8b9bafe1137c5224f1c0c035` |
| `SHA256SUMS.txt` | 174 | — |

`shasum -a 256 -c SHA256SUMS.txt` passes for both files after downloading them with `gh release download`.

### The application inside the published image

Mounting the downloaded DMG read-only shows `Tursora.app` beside the `Applications` symlink. `CFBundleShortVersionString` 0.3.0, `CFBundleVersion` 1789348408, `CFBundleIdentifier` com.tursora.Tursora, `lipo -archs` arm64, and `codesign --verify --deep --strict` reports "valid on disk" and "satisfies its Designated Requirement". `Sparkle.framework` is present under `Contents/Frameworks`, and the bundle carries `SUFeedURL` `https://github.com/zerolfx/Tursora/releases/latest/download/appcast.xml` with `SUPublicEDKey` `G8if0uug+SchbfBEzbvDsWHp7tfB8tEI1xnyygGWh00=`.

### Production update feed

Fetching `https://github.com/zerolfx/Tursora/releases/latest/download/appcast.xml` — the URL an installed application actually uses — returns bytes whose SHA-256 equals the published `appcast.xml` above. The feed has one item and no deltas: short version 0.3.0, version 1789348408, enclosure `https://github.com/zerolfx/Tursora/releases/download/v0.3.0/Tursora-0.3.0-macOS-arm64.dmg` with length 6403387 and minimum system version 14.0, matching the downloaded DMG byte for byte.

`app/tools/update-metadata.py verify-appcast feed.xml --archive <downloaded DMG> --app <mounted app>` exits 0 and prints the Ed25519 signature `D1dhpVELsp4Y5qGlog44+PEDiG3A+s/qmUP67/+4rstsCne98fFRioNAySmm3yFisEXRQFcJySl5qz1BeRuKCg==`, so the feed's fields, the archive bytes and the bundle agree.

### Follow-up in this same round

`Casks/tursora.rb` was regenerated by `app/tools/update-homebrew.py` from the downloaded release JSON, `SHA256SUMS.txt` and the actual DMG: version 0.3.0, the SHA-256 above, `auto_updates true`. Both product pages gained a "New in 0.3.0" block, marked so the version guard treats it as a record of when the features arrived rather than as the current download. The cask's isolated install and uninstall have not been run in this round; the Homebrew workflow checks the cask on its own runner once this lands.

# 0.3.0 release preparation and verification

2026-09-14. This record covers what has actually been done for 0.3.0 and what is still outstanding. It is written in English because the owner moved the product-facing documents to English; the earlier records keep their original language until they are rewritten.

**Status: prepared, not published.** Nothing below claims that a release exists. The publication section stays empty until the Release workflow has run and its assets have been checked.

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
- **No publication.** The Release workflow has not been dispatched, so there is no tag, no release, no appcast and no published DMG. The production update feed still offers 0.2.1.
- **No Homebrew or site follow-up.** `Casks/tursora.rb` still tracks 0.2.1, and both product pages still name 0.2.1 as the current download. Both must be updated from the published bytes after publication, as was done for 0.2.0 and 0.2.1.

## Publication

Pending. When the Release workflow has run, record here: the exact tag and commit, the workflow run, the published asset names, byte counts and SHA-256 values as downloaded again from the release, the updater signature check, and the production feed check. Do not copy the local figures above into that section.

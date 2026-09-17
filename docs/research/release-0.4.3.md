# 0.4.3 release preparation and verification

2026-09-17. What has actually been done for 0.4.3 and what is still outstanding.

**Status: published and verified.** [Tursora 0.4.3](https://github.com/zerolfx/Tursora/releases/tag/v0.4.3) is the latest stable release, published 2026-09-17.

## Why this release exists

Three defects the owner reported against 0.4.2, all introduced during the 0.4.1 column-view work.

| Reported | What it was |
|---|---|
| A narrow column loses the filename entirely | The name vanished, leaving only the icon |
| **Set Tursora as Default** fails | "The file couldn't be opened." — the system's error, passed straight through |
| The settings button is far too long | Push buttons stretched the whole width of the pane |

## The narrow column

A filename is one unbreakable word and the cell's default is to wrap, so at a column narrower than the name the line breaks after the icon attachment and the cell draws only that first line. Four things were measured at a 70 pt column before one worked:

| what was set | name drawn |
|---|---|
| `.byTruncatingMiddle` paragraph style inside the attributed string | no |
| `cell.lineBreakMode = .byTruncatingMiddle` | no |
| `cell.wraps = false` | no |
| **`cell.usesSingleLineMode = true`** | **yes** |

`lineBreakMode` is kept beside it to put the ellipsis in the middle, matching the list view and Finder, but a pixel count cannot tell that from tail truncation, so nothing asserts it and the code comment says so rather than implying the check proves it.

**The first version of the check did not catch the bug.** It used the fixture's existing `top.txt`, which fits at 70 pt, so it passed with the fix reverted. Mutation-testing the check caught that; the fixture now carries a name no narrow column can fit.

## The default-handler failure

Reproduced against deliberately bad targets — nothing that could succeed, so no default was ever changed — and the message matches exactly: `NSCocoaErrorDomain` **256**, "The file couldn't be opened." LaunchServices refuses a bundle in a temporary or read-only location, and App Translocation puts a quarantined copy of a downloaded, ad-hoc-signed application in exactly such a place. Since Tursora is ad-hoc signed and not notarized, a user who opens it straight from the disk image hits this every time.

The location is now diagnosed before the request: the settings line explains it and the button is disabled until the application is moved, instead of handing over an error nobody can act on. `SecTranslocateIsTranslocatedURL` is not exposed to Swift, so the test is the `/AppTranslocation/` path marker plus the private temporary tree and a read-only volume check.

## Local verification performed

| Check | Result |
|---|---|
| Debug build | clean |
| Full smoke suite | three consecutive runs, 4,377 checks each, exit 0, each printing `SMOKE TEST PASSED` |
| Mutation testing | the narrow-column check verified to fail when `usesSingleLineMode` is reverted |
| Release tool tests | 90 tests, OK |
| **Packaged application** | built, launched on a fixture with long filenames, and **looked at**: with the column dragged to its 100 pt minimum, rows keep both icons and names; the settings button measures 161 pt rather than the full 592 pt pane |

## Verification of the published artifacts

| Check | Result |
|---|---|
| Release run | [35217600481](https://github.com/zerolfx/Tursora/actions/runs/35217600481), success, dispatched on `main` |
| Tag | `v0.4.3` resolves to `fc4766fc97614fa76686492cce99f2b04092d345` |
| Release | not a draft, not a prerelease, the repository's latest, three assets |
| Checksum | recomputed independently, matches the published `SHA256SUMS.txt`: `8aaddc941524a18c86fa548fed5dbe577b61ed90c715cd25fbeedabae99b588d` |
| Application inside | `CFBundleShortVersionString` 0.4.3, `CFBundleVersion` 1789645346, `lipo -archs` arm64, `codesign --verify --deep --strict` clean, `LSMinimumSystemVersion` 14.0 |
| Stable feed | `releases/latest/download/appcast.xml` serves byte-identical content to the release asset |
| Homebrew cask | regenerated from the published bytes |
| **The published binary, run and looked at** | the app was copied out of the downloaded DMG and opened on a fixture of long filenames. With the column dragged to 101 pt — its minimum — every row still draws both its icon and its name, the long ones clipped but present |

That last row is the one 0.4.1 and 0.4.2 could not claim. 0.4.1 shipped a fix that did not work and nobody looked; 0.4.2's check ran against a local build of identical sources because the screen locked. This time the artifact users download is the artifact that was watched.

## Not done

- **The location message was not seen on screen.** The packaged build under test lives in a normal directory, so the diagnosis correctly reports no problem and the button stays enabled. The refusal path is covered by checks driven with stub bundles in a temporary directory, and the error-code mapping was measured directly — but no screenshot shows the sentence a translocated user would read.
- **The button was never pressed.** Doing so would change which application this machine opens folders with.
- **No local isolated Homebrew install**; the cask's install/uninstall is exercised by the Homebrew workflow on a clean runner.
- **The remaining 0.4.x features have still not been used in a packaged build** — the preview pane's Markdown rendering, batch rename and content search.

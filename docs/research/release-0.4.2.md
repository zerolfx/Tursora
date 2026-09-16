# 0.4.2 release preparation and verification

2026-09-17. What has actually been done for 0.4.2 and what is still outstanding.

**Status: published and verified.** [Tursora 0.4.2](https://github.com/zerolfx/Tursora/releases/tag/v0.4.2) is the latest stable release, published 2026-09-17.

## Why this release exists

0.4.1 shipped one of its three advertised fixes broken. Column view rows still drew no icons — the exact defect the owner reported and the release claimed to have fixed. 0.4.2 contains that one fix and nothing else.

## How it was found, and why nothing automated caught it

By downloading the published 0.4.1 DMG, copying the application out of it, running it against a fixture and looking at the screen. About a minute of work. What it had survived:

- three consecutive green smoke rounds, 4,369 checks each;
- an adversarial review of the branch, 73 agents across seven lenses and three skeptics per finding;
- mutation testing of all eleven checks added that round, each verified to fail when its fix was reverted.

The cause was the accessibility repair made during the same round. `setAccessibilityValue` on a cell owned by an `NSBrowser` writes through to the cell's own value and replaces the attributed string; the icon is an `NSTextAttachment` inside that string. Isolated on a real item-mode browser, one variable at a time:

| what the delegate sets | attachment survives | AX label |
|---|---|---|
| neither | yes | nil |
| `setAccessibilityLabel` only | yes | correct |
| `setAccessibilityValue` | **no** | nil |
| both | **no** | correct |

The measurement that led to setting both was not wrong — label alone does leave U+FFFC in the AX value. It measured only what setting the value gained and never what it cost.

The blind spot in the check was narrower than "no visual test". The check built its own `NSTextFieldCell`, called the delegate on it and read it back; on a detached cell every write sticks, while on the cell the browser actually draws the accessibility write clobbers the string. The check now also reads `browser.loadedCell(atRow:inColumn:)` and was confirmed to fail against the shipped code while the probe-based one still passed. That distinction is recorded in [DEVELOPMENT.md](../DEVELOPMENT.md) § AppKit pitfalls.

## What the same packaged check confirmed working

Both other reported bugs were genuinely fixed in 0.4.1, verified on the released build:

| Reported bug | Result in released 0.4.1 |
|---|---|
| Column view shows no icons | **still broken** — fixed here |
| PDF cannot be previewed | works; the preview column needs a window wider than about 560 pt to have room |
| Back loses the scroll position | works; the list returns to the same rows with the opened folder still selected |

The new Settings ▸ General ▸ Opening folders row also reads correctly ("Folders open in Finder." with an enabled button). The button itself was deliberately never pressed: it would change which application the machine opens folders with.

## Source under test

`72e26e1`, the tip of `main`, plus the version change in this preparation commit.

## Local verification performed

| Check | Result |
|---|---|
| Debug build | clean |
| Full smoke suite | three consecutive runs, 4,371 checks each, exit 0, each printing `SMOKE TEST PASSED` |
| The new check | verified to fail against the shipped 0.4.1 code while the old probe-based check still passed |
| Release tool tests | 90 tests, OK |
| **Packaged application** | built, launched against a fixture, and **looked at**: folder rows and file rows both draw their icons in column view |

## Verification of the published artifacts

| Check | Result |
|---|---|
| Release run | [35127645725](https://github.com/zerolfx/Tursora/actions/runs/35127645725), success, dispatched on `main` |
| Tag | `v0.4.2` resolves to `31e81b2ea0b3785ba63073cded6db7294ee28ba8` |
| Release | not a draft, not a prerelease, the repository's latest, three assets |
| Checksum | recomputed independently, matches the published `SHA256SUMS.txt`: `d788cc029b275ad78f6f802152a0a418ed2204d1b121a2ec5b2b268d2c34a6d6` |
| Published DMG | 6,611,232 bytes |
| Application inside | `CFBundleShortVersionString` 0.4.2, `CFBundleVersion` 1789578889, `lipo -archs` arm64, `codesign --verify --deep --strict` clean, `LSMinimumSystemVersion` 14.0 |
| Update feed | immutable versioned URL, `length` matching the actual bytes, Ed25519 signature present |
| Stable feed | `releases/latest/download/appcast.xml` serves byte-identical content to the release asset |
| Homebrew cask | regenerated from the published bytes |

## The visual check, and exactly which binary it covered

The icons were confirmed on screen **before** this release was cut, in a locally packaged build of `72e26e1`. `git diff 72e26e1 31e81b2` touches only `VERSION`, `CHANGELOG.md` and this file — **no Swift source at all** — so the application code that was looked at is the code that shipped.

What was *not* done: the downloaded 0.4.2 application was launched, but the screen locked before it could be captured, so the published binary itself was inspected rather than watched. Given the identical sources that is a weak gap, but it is a gap, and after 0.4.1 it is worth naming rather than rounding off.

## Not done

- **No isolated local Homebrew install.** The cask is generated from the published bytes and its install/uninstall is exercised by the Homebrew workflow on a clean runner, not on a machine with an existing Tursora or a non-admin account.
- **No launch of the downloaded 0.4.2 application.** The published bundle will be mounted and inspected; the pre-release visual check used a locally packaged build of the same commit.
- **The remaining 0.4.x features have still not been clicked through.** This round looked at column-view icons, the column preview and Back; the preview pane's Markdown rendering, batch rename and content search have never been used in a packaged build.

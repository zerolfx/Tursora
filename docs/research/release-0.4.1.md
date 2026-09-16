# 0.4.1 release preparation and verification

2026-09-16. What has actually been done for 0.4.1 and what is still outstanding.

**Status: published and verified.** [Tursora 0.4.1](https://github.com/zerolfx/Tursora/releases/tag/v0.4.1) is the latest stable release, published 2026-09-16. The packaged-app interaction check is still outstanding; see "Not done".

## Scope of the release

0.4.1 is a bug-fix round answering three defects the owner reported against 0.4.0, plus one setting and the defects that fixing the first three exposed.

| Merged | What it is |
|---|---|
| [#21](https://github.com/zerolfx/Tursora/pull/21) | The 0.4.0 "published and verified" record. It should have been merged before 0.4.0 shipped and was not; merged first this round |
| [#22](https://github.com/zerolfx/Tursora/pull/22) | The three reported bugs, the defects the first fix exposed, and Settings ▸ General ▸ Opening folders (D86) |

The three reported bugs: column view drew no icons, the column preview was blank for anything Quick Look renders, and Back returned to a folder without returning to the place in it.

## What fixing the first bug exposed

`willDisplayCell:` had been casting to `NSBrowserCell`, which an item-mode `NSBrowser` never supplies, so the whole delegate body had been dead code. Repairing the cast brought it to life and with it three regressions, none of which the feature's own checks could see — all found by an adversarial review of the branch before merge (seven lenses, three skeptics per finding, 73 agents; 22 findings raised, 15 surviving a majority):

- type-select stopped matching, because it falls back to the cell's string and that now began with the attachment's U+FFFC;
- VoiceOver read the object-replacement character, because an `NSCell` derives both its accessibility label and its value from the attributed string;
- rename preselected the whole filename, so typing over `photo.jpg` produced a file with no extension — `SPEC.md` had always required the base name.

The review also found that several of the new checks could not fail, and two defects outside the icon change (the scroll offset overriding a selection after a filtered navigation, and a preview pane that came back blank when reopened on an unchanged selection).

## Source under test

`ef64dcc`, the tip of `main` after #22, plus the version change in this preparation commit. `main` is linear: every pull request was squash-merged.

## Local verification performed

| Check | Result |
|---|---|
| Debug build | clean |
| Full smoke suite | three consecutive runs on the final tree, 4,369 checks each, exit 0, each printing `SMOKE TEST PASSED` |
| Mutation testing | every one of the eleven new checks was verified to **fail** when the fix it covers is reverted, one at a time. Eleven of eleven. Two checks failed that test on the first attempt and were rewritten: one asserted state the test had seeded itself, one took a code path that cleared the pane before the reopen it was meant to exercise |
| Release tool tests | `python3 -m unittest discover -s app/tools -p 'test_*.py'` — 90 tests, OK |
| Packaged bundle | `tools/make-app.sh` produced `Tursora.app` with `CFBundleShortVersionString` 0.4.1, `CFBundleIdentifier` com.tursora.Tursora, `LSMinimumSystemVersion` 14.0, ad-hoc signature replaced |

## Verification of the published artifacts

| Check | Result |
|---|---|
| Release run | [35111183239](https://github.com/zerolfx/Tursora/actions/runs/35111183239), success, dispatched on `main` |
| Tag | `v0.4.1` resolves to `4fad0becdd4a7d72ddebe29ae652bff4e023bed6`, the reviewed commit |
| Release | not a draft, not a prerelease, the repository's latest, three assets |
| Checksum | `shasum -a 256` recomputed independently matches the published `SHA256SUMS.txt`: `6578f6f3eae180ced7107d6506e2fece2451fa084f6ed3ee76923f7b41e268fa` |
| Published DMG | 6,610,635 bytes |
| Application inside | `CFBundleShortVersionString` 0.4.1, `CFBundleVersion` 1789569676, `CFBundleIdentifier` com.tursora.Tursora, `lipo -archs` arm64, `codesign --verify --deep --strict` clean, `LSMinimumSystemVersion` 14.0 |
| DMG layout | mounted read-only: `Tursora.app`, an `Applications` symlink to `/Applications`, the background image and the bundled `.dmgbuild-LICENSE.txt` |
| Update feed | `appcast.xml` points at the immutable `releases/download/v0.4.1/Tursora-0.4.1-macOS-arm64.dmg`, `length` 6610635 matching the actual bytes, with an Ed25519 signature |
| Stable feed | `releases/latest/download/appcast.xml` serves byte-identical content to the release asset |
| Homebrew cask | regenerated from the published bytes, and its install/uninstall validated by the Homebrew workflow on a clean runner. It had still been on **0.3.0** — the 0.4.0 round never updated it — so this also repairs that |

## A check that looked flaky and was not

`terminal: Control-C restores the shell foreground group` failed in roughly half the rounds, on a code path this release does not touch, and blocked the round each time because the suite exits on the first failure. It was nearly recorded as a flaky test to look at later. It is not flaky.

Measured on a failing run: the `sleep` job's `p_sigignore` carried the SIGINT bit while the shell's did not. A suite started in the background — `nohup … &`, or any parent that ignores SIGINT — passes `SIG_IGN` down, and a shell gives every job it starts `SIG_IGN` for the signals that were ignored when the shell itself started. An inherited ignore survives `exec` and cannot be reset from shell script (POSIX: a signal ignored on entry to a non-interactive shell cannot be trapped or reset), so no keystroke could ever interrupt the job. Controlled comparison, same binary, same fixture: **SIGINT inherited as ignored → fails; SIGINT reset to `SIG_DFL` in the child → passes.** It fails 100% of the time in the first condition and passes 100% in the second.

The check and its fixture are unchanged, because neither was wrong. What changed: the failure detail now names the cause, the pitfall is in `docs/DEVELOPMENT.md`, and the smoke runner resets SIGINT and SIGQUIT in the child so a background-launched round matches a foreground one.

## Corrections to claims made earlier in this round

Three statements written during the fix were wrong and were corrected before merge:

- The default-handler setting does **not** capture another application's "Reveal in Finder". That is `NSWorkspace.activateFileViewerSelecting`, which addresses Finder by name and no handler setting redirects. The changelog, spec, gap row, README and D86 all said otherwise at one point.
- Folders never hide extensions (`FileItem.displayName` returns early for anything navigable), so "a folder showed the raw filename" was not a symptom of the icon bug.
- `NSWorkspace.icon(forFile:)` returns a **fresh** image on every call, not a shared cached one — measured, `a === b` is false and resizing one does not affect the next. Two code comments had claimed the opposite.

## Not done

- ~~**No packaged-app interaction check, again.**~~ **Done on 2026-09-17, after publication — and it found that 0.4.1 shipped one of its three fixes broken.** The released DMG was downloaded, the app copied out of it and run against a fixture. Results: the PDF preview works (it needs a window wider than about 560 pt for the preview column to have room), Back restores the scroll position exactly, and the new Opening folders row reads correctly — but **column rows still drew no icons**, the very defect 0.4.1 claimed to fix. Cause and correction are in [the column-view record](column-view.md); in short, the accessibility repair made in the same round replaced the styled text the icon lived in. Three green rounds of 4,369 checks, an adversarial review and mutation testing all passed over it; looking at the packaged app took about a minute. This is the third consecutive round in which the only defects that reached users were the ones a person could see and the suite could not.
- **No *local* isolated Homebrew install.** The cask is generated from the published bytes and its install/uninstall was exercised by the Homebrew workflow into a temporary runner app directory ([checks on #24](https://github.com/zerolfx/Tursora/pull/24)), which is a real install of the published asset — but on a clean CI runner, not on a machine with an existing Tursora, an existing tap, or a non-admin account.
- **No launch of the downloaded application.** The published bundle was mounted and inspected, not opened.
- **The folder-handler role is never claimed by a check.** Doing so would need a human to dismiss a system confirmation and would change the machine running the tests. What is checked is the wording, the enabled state, and the bundle-identifier identity rule, the last driven with two stub bundles that differ only in path.

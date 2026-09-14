# 0.2.1 release verification

> Historical record. The current stable release is [0.3.0](release-0.3.0.md); the evidence below is what was actually verified for 0.2.1 at the time.

2026-09-13. [Tursora 0.2.1](https://github.com/zerolfx/Tursora/releases/tag/v0.2.1) has been published as the latest stable version, not a draft or prerelease. The user authorised pushing and publishing once the terminal and documentation changes were finished; the tags and assets of older versions were not modified.

## Source and release

`v0.2.1` points exactly at `c95f4d5aaaf483dd8176873685ac614b47c8100a`, and build `1789288838` is that commit's Unix committer timestamp; author and committer are both the zerol identity the project requires, and the ordinary fast-forward push rewrote no history.

- The final 102 Swift source files passed three consecutive rounds of the full smoke, 3,435 checks per round, with identical hashes before and after and empty stderr. The 83 release-tooling tests, the release bundle and the local DMG verification all passed; for the on-machine scope — keeping hidden tasks, directory syncing, cancelling on quit, a narrow interface — see [the terminal verification](terminal-navigation-0.2.1.md).
- [Release 34748456904](https://github.com/zerolfx/Tursora/actions/runs/34748456904) was started only after [Build](https://github.com/zerolfx/Tursora/actions/runs/34748295219) and [Pages](https://github.com/zerolfx/Tursora/actions/runs/34748295179) for that commit had both succeeded. The release's build, update-signing, checksum and publish steps all passed, with a publication time of `2026-09-13T08:50:03Z`.
- The latest release from the GitHub API is `v0.2.1`, and its tag ref is the same commit as above; the evidence is at `/private/tmp/tursora-0.2.1-qa-u1_phjba/release/{release,latest,tag}.json`.

## The actual public assets

The official files were downloaded with `gh release download` and checked one by one against the GitHub asset digest / size and SHA256SUMS; no local trial build stood in for the public artefacts.

| Asset | Bytes | SHA-256 |
|---|---:|---|
| `Tursora-0.2.1-macOS-arm64.dmg` | 5,852,598 | `3458aa15670b75e8469398e4d0928ed73e6f038567c9ae7dba049e509333460b` |
| `appcast.xml` | 2,575 | `9d8b654d711731c44072f976d23694e49a13981ad559720f7769a4abc6b4cce1` |
| `SHA256SUMS.txt` | 174 | `cc356b563d51f201cbe3d05d5ef0bb4299367346987304d302401a0f0133bdcc` |

A read-only mount was used to check the version / build / bundle id, arm64, `codesign --verify --deep --strict`, the MIT / SwiftTerm / Sparkle licences, and the icon and runtime resources; the licences match the release commit byte for byte. The Applications symlink, the licence for the installer background and the two-icon / arrow layout all passed. `verify-bundle` / `verify-appcast` validated the metadata; separately, cryptography's Ed25519 verifier and the public key inside the bundle verified the signature over the complete DMG, and that public key also matches the released source — no private key was read at any point. A pristine copy of the app was kept and its signature verified again before the image was unmounted.

The report `/private/tmp/tursora-0.2.1-qa-u1_phjba/release/verification.json` reads passed; the actual original bundle is at `verified-0.2.1-3tklxqe7/Tursora.app` in that directory. A normal TLS request to `releases/latest/download/appcast.xml` returned HTTP 200, byte-for-byte identical to the versioned download and containing only the single 0.2.1 / build 1789288838 entry; `live-feed.json` holds that comparison and the re-confirmed latest / tag. This app is still ad-hoc signed and not notarised by Apple; an update signature is no substitute for Gatekeeper notarisation.

## Launching the official bundle and the update feed

An isolated test bundle was copied again from the pristine app, adjusting only the copy's name, bundle id and test file environment before re-signing it: `com.tursora.releaseqa021.s0913`, its own workspace / directory attributes file and its own ZDOTDIR, leaving the user's original app, preferences and dotfiles untouched. The official bundle launched normally; after Settings → Updates → Check for Updates reached the production feed it showed **You’re up to date! Tursora Release QA 0.2.1 is currently the newest version available.** The evidence is `screenshots/live-update-check.jpg` in the QA directory; the test app then quit normally, which an exact process query confirmed.

This check proves that the official version launches and can query the production feed. It does not claim that replacing an older production installation and restarting automatically was done this time, nor is it equivalent to a first-install test on another standard-user or managed Mac. The installation instructions support writable directories and the handling of the quarantine attribute on an app copy that has been verified; no 0.1.0 migration procedure is provided.

## Installation entry points, the website and screenshots

The README, the default English home page, the Chinese page and the shared agent installation guide were updated to 0.2.1, keeping the three steps of tap / trusting the single cask / install and the description of the actual installation paths. The cask was generated by `update-homebrew.py --auto-updates` from the real DMG only after the official assets had passed the checks above, pinning the SHA-256 values in this table. Local generation consistency, Ruby syntax, the 83 tooling tests and the bilingual site build all passed. For the online installation result of the final follow-up commit, the [Homebrew workflow](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml) is authoritative; a local generation check is not the same as an actual brew install.

Both languages were checked in a browser at 1200 / 390 px during the source release stage, and 11 normal TLS downloads covering the 10 deployed files and the default root URL all matched `c95f4d5` and the local build. The later installation version wording and the cask go into a separate follow-up commit; the release tag is not moved. The screenshots record moving the mouse away, the check for hover traces and the transparent rounded-corner treatment — see [the screenshot audit](screenshot-audit-2026-09-13.md); the evidence scope of historical research images stays at the stage at which they were actually taken.

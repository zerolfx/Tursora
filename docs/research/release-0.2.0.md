# 0.2.0 Official Release Verification

> A historical release record. The current stable version is [0.2.1](release-0.2.1.md); what follows keeps the actual evidence from the 0.2.0 release at the time.

2026-09-13. [Tursora 0.2.0](https://github.com/zerolfx/Tursora/releases/tag/v0.2.0) has been published as the latest stable version, not a draft / prerelease. The user authorized the push, the merge and the release once these features were finished, and the original 0.1.0 tag and its assets were not modified.

## Source and Pipeline

[PR #8](https://github.com/zerolfx/Tursora/pull/8) has been merged, and main, `v0.2.0` and the Release checkout correspond exactly to `3ca4ab9ffd43555e4c4118e5504eb6d39e6dc034`. The Git author and committer are both `zerol <20219056+zerolfx@users.noreply.github.com>`; this was an ordinary fast-forward push with no history rewriting.

- The final 3,329 smoke checks over 101 Swift source files passed three times in a row, with the per-round and current hashes matching and stderr empty each time; 83 tool tests, the final release / DMG build and functional verification on a real machine passed. For the exact scope see [terminal session lifecycle](terminal-session-lifecycle.md); the cask / documentation revisions made after the release do not change those Swift sources.
- Release was only started after [Build](https://github.com/zerolfx/Tursora/actions/runs/34739716326), [Homebrew](https://github.com/zerolfx/Tursora/actions/runs/34739716318) and [Pages deployment](https://github.com/zerolfx/Tursora/actions/runs/34739716315) on main had all passed. At that stage Homebrew was still verifying the 0.1.0 the cask was pinned to at the time.
- [Release](https://github.com/zerolfx/Tursora/actions/runs/34739914582) succeeded; `v0.2.0` is a tag pointing directly at the commit above, published at `2026-09-13T05:21:13Z`. The short version is `0.2.0`, and build `1789275959` is the commit's Unix committer timestamp.

## Public Assets and Signing

The three official assets were actually downloaded with `gh release download` into `/private/tmp/tursora-release-0.2.0-verified`, rather than a locally built package being used. The results match SHA256SUMS and the GitHub asset size / digest, and the checksum file itself also matches the API digest.

| Asset | Bytes | SHA-256 |
|---|---:|---|
| `Tursora-0.2.0-macOS-arm64.dmg` | 5,794,277 | `2593f312772b6d7ee6a885c8017ce43b31d094fc2744f764e76e027178d1aef7` |
| `appcast.xml` | 5,787 | `2c96395442c61bb985d361189472dbef34f56bfdf683db328218222d41f037d4` |
| `SHA256SUMS.txt` | 174 | `03185719aaa44ed9d310ae834303f9bb8499a28aa7bb9a4bddb42af4da708c88` |

After mounting the image read-only, the following were confirmed: the app version / build / bundle id, arm64, `codesign --verify --deep --strict`, the MIT / SwiftTerm / Sparkle licences and the icons inside the bundle, the Applications symlink, the installation background licence and the saved two-icon / arrow / 640 × 280 layout all passed. The MIT text at the root is byte for byte identical to the one in the source. The image has been unmounted.

`verify-bundle` and `verify-appcast` check the metadata; separately, the signature over the complete downloaded DMG was checked with CryptoKit's Ed25519 public key, so that "the metadata fields are correct" is not mistaken for cryptographic verification. Local verification only reads the project's public key and did not export or read the private key. The actual `releases/latest/download/appcast.xml` is byte-identical to the versioned appcast download.

This is still an ad-hoc signed app distributed directly and not notarized by Apple. The Sparkle update signature and the SHA-256 do not amount to Developer ID / Gatekeeper notarization; for the first launch, follow the instructions in the README.

## Launching the Official Package and the Live Update Check

The app was copied from the verified image; the original bundle was verified first, then only the test copy's name, bundle id, automatic-check default and test-only environment were modified and it was re-signed ad hoc. It used `com.tursora.releaseqa020.s0913` with its own workspace / view-properties files, so the user's own app and preferences were left alone; the production feed URL / public key / version / build were kept.

It launched successfully on a real machine, About showed `0.2.0 (1789275959)`, and the initial Terminal in the bottom right had clearly not started a shell. Settings → Updates → Check for Updates actually reached the production source and reported **You’re up to date!**, confirming that 0.2.0 is the current latest version. The evidence is `live-update-check.jpg`; the app then quit normally, and an exact process path query confirmed that the test copy had exited.

This time no app with the old official bundle id under the same user was handed to the production installer for replacement / automatic restart: the user's app is still running on this machine, and after a Sparkle replacement the standard restart path would not inherit the temporary isolation configuration of the old copy. A controlled Foundation probe also confirmed that `CFFIXED_USER_HOME` only changes the home path APIs and cannot isolate UserDefaults, so a new process still reaches the real preferences directory; the dedicated QA domain and its files have been cleaned up and the official preferences were untouched. Actually downloading / installing an older version and restarting automatically still rests on the earlier separate successful record using a **one-off QA key + loopback**, and that is not claimed as end-to-end installation verification against the production source this time.

## Installation Entry Point and Follow-up Checks

The installation section of the README has been moved to the front, and the site navigation and the "Install guide" in the hero jump to `#installation`. The new layout passed on desktop / at 390 px, in the installation image lightbox and in the Escape focus restore; all 8 files of main's first deployment returned HTTP 200 and were byte for byte identical to the local build. All 29 canonical images passed the transparent rounded corner check, and General / Terminal have been updated; see the [screenshot audit](screenshot-audit-2026-09-13.md).

The cask was generated only after the public 0.2.0 assets had passed verification, with `auto_updates true` enabled; the isolated actual Homebrew install / uninstall, the final wording and the Pages deployment are covered separately in the [Homebrew record](homebrew.md) and the [Pages record](github-pages.md). Those steps were verified separately from the Release, and later commits will not move a published tag.

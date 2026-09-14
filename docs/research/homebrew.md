# Homebrew distribution (2026-09-13)

## Current version: 0.3.0

`Casks/tursora.rb` is generated from the actually published 0.3.0 DMG, release JSON and `SHA256SUMS.txt`, and keeps `auto_updates true`. That DMG is 6,403,387 bytes, SHA-256 `9706add96eab66828b86700125c657537cedff5c92680108d79e96283ef99557`; the published assets, the code signature, the Ed25519 update signature and the production feed are verified in [the 0.3.0 release record](release-0.3.0.md). The generator refuses anything but a verified, published stable release, so the cask can never be built from a local image. This round did not run an isolated `brew install` / `brew uninstall`; the Homebrew workflow checks the cask on its own runner. The 0.2.1 figures below are kept as the history of the previous cask.

## Conclusions and primary sources

We can support our own Homebrew tap first, without buying into the Apple Developer Program. The 99 US dollars a year the user mentioned is for Apple membership; Developer ID signing and notarisation improve the first-launch experience, which is a separate matter from whether we can write a cask of our own. [Apple membership](https://developer.apple.com/programs/), [Developer ID](https://developer.apple.com/developer-id/).

Homebrew's current requirement for the official `homebrew/cask` is that a macOS executable product must pass its Gatekeeper check, and must not rely on turning Gatekeeper off or working around it. The current ad-hoc, un-notarised Tursora therefore makes no claim of meeting the conditions for inclusion in the official repository, and is not submitted to it. That restriction comes from the [acceptance rules for the official repository](https://docs.brew.sh/Acceptable-Casks#platform-compatibility-and-macos-security-protections).

Homebrew supports placing `Casks/` in an ordinary Git repository, and the two-argument `brew tap <name> <URL>` does not require the repository to be named with a `homebrew-` prefix. The public Tursora repository is therefore reused, and no extra external repository is added. [Maintaining a tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap), [two-argument tap and full names](https://docs.brew.sh/Taps).

## What this round implements

- [Casks/tursora.rb](../../Casks/tursora.rb) pins the real published version `0.2.0`, with Apple Silicon architecture and macOS 14 as the minimum. It downloads the official DMG, whose SHA-256 is `2593f312772b6d7ee6a885c8017ce43b31d094fc2744f764e76e027178d1aef7`, generated from the same version's release JSON, checksum file and actual asset.
- Installation uses the standard `app "Tursora.app"`; it runs no extra shell, removes no quarantine attribute and changes no system security settings. Homebrew's default download quarantine is kept, and first launch still follows the trusted-source steps in the README. There is no `zap`, so uninstalling does not delete preferences, sessions or user files.
- 0.2.0 already includes Sparkle and publishes an appcast, so the current cask is marked `auto_updates true`; the historical `0.1.0` had no updater and the old cask carried no such marker. `brew upgrade --cask --greedy zerolfx/tursora/tursora` makes Homebrew check versions that update themselves.
- [update-homebrew.py](../../app/tools/update-homebrew.py) generates the cask from a saved GitHub release JSON, the checksum file for the same version and the already downloaded asset. It rejects drafts, prereleases, non-stable tags, unofficial or mutable addresses, duplicate asset names, conflicting checksums, and any mismatch of bytes, size or digest; it handles no credentials, makes no network calls, and neither commits nor publishes automatically. `--auto-updates` additionally requires a published `appcast.xml` of the same version, and rejects the historical `0.1.0`.
- The [Homebrew workflow](../../.github/workflows/homebrew.yml) verifies cask install and uninstall on a dedicated macOS runner, without launching the app and without changing system security policy. The main workflow for the original cask has already succeeded; the remote result for the 0.2.0 cask is governed by the [Homebrew runs](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml) for the corresponding commit, and a remote run's result cannot be substituted by local tests.

The 0.2.0 cask was merged into main with [PR #9](https://github.com/zerolfx/Tursora/pull/9), and its [real install check](https://github.com/zerolfx/Tursora/actions/runs/34741008373) passed. At the user's explicit request, the main installation flow runs the following three commands in order, continuing to the next only after each one succeeds: add the tap with the full URL, explicitly trust only the Tursora cask, install. The second step is a required step of the flow in this document, see D58:

```sh
brew tap zerolfx/tursora https://github.com/zerolfx/Tursora
brew trust --cask zerolfx/tursora/tursora
brew install --cask zerolfx/tursora/tursora
```

The three-step flow has now been verified in sequence by the main task in a new, isolated trust directory: the tap, `trust --cask` and the install dry run all exited 0; the trust JSON contains only this cask, with no tap / formula / command authorisation, and the user's Homebrew was left unchanged. The evidence is `/private/tmp/tursora-three-step-install-3liuppa5/verification.json`. This is a check of the flow and of the trust scope; the app was not reinstalled. The earlier real DMG install / uninstall and the CI result for the newly added explicit trust are recorded separately.

## Current install location and a note on ordinary accounts

The user stated explicitly that the install location does not have to be uniform. A new [English plain-Markdown installation guide](../../site/install.md) has been added, with the site address `https://zerolfx.github.io/Tursora/install.md`, for a user or for an agent that receives an installation request to follow according to the actual conditions. Check the existing installation and the user's intent first, then choose `/Applications`, `~/Applications` or another directory that is actually writable; do not force an existing application to be moved. The three commands above use Homebrew's default destination; if another directory is chosen, assign the actual absolute directory to `app_dir` and add `--appdir="$app_dir"` to the third command. An installation already managed by Homebrew goes through the normal version check / upgrade; a direct DMG copy that meets an application of the same name has to have the conflict confirmed first, and must not silently overwrite it.

`--appdir` only changes where the application lands; it does not change the permissions of the prefix, including the tap and the Caskroom. By default only the owner who installed Homebrew can modify the prefix; whether an ordinary account can use it is decided by the actual permissions. Where Homebrew is not available, download the official DMG and the checksum file for the same version directly, verify the full SHA-256, and copy the app out of the read-only image; do not install Homebrew, elevate privileges or change ownership on your own initiative just to install the app. [Homebrew options](https://docs.brew.sh/Manpage#global-cask-options), [default permissions](https://docs.brew.sh/FAQ#what-are-the-default-ownership-and-permissions-used-by-homebrew).

The targeted command for the first launch is `xattr -dr com.apple.quarantine "$app_path"`, where `app_path` must be an actually installed, trusted copy of the app that passed the download verification. It removes only that attribute; it does not use `sudo`, does not clear all attributes and does not turn off system policy; the cask itself still keeps quarantine. An ordinary account and organisational management restrictions are two different problems: if device policy still blocks the app from running, IT has to handle it, and no promise can be made that this command works around management rules. [Apple management restrictions](https://support.apple.com/en-euro/guide/deployment/dep61dc030/web). This section records the guide and the check against primary sources; it adds no verification conclusion about installing under a non-administrator account or about the first Gatekeeper launch. Deployment results are recorded separately by the main task.

## Installation troubleshooting: repository address and single-item trust

On 2026-09-13 the user first reported that `homebrew-tursora` could not be found, and after retrying reported an `untrusted tap`. The complete original command / output was not received, so it cannot be asserted which step the user actually left out; what follows is independent reproduction and verified Homebrew behaviour.

The single-argument `brew tap zerolfx/tursora`, or installing a fully-qualified cask before tapping, goes by convention to `https://github.com/zerolfx/homebrew-tursora`. The real repository we reuse is `https://github.com/zerolfx/Tursora`, so the two-argument tap has to come first. Even when the remote is correct, the local directory is still called `Library/Taps/zerolfx/homebrew-tursora`; seeing only that directory name in `Cloning into` does not mean it failed. [Official tap rules](https://docs.brew.sh/Taps).

`untrusted tap` is Homebrew's trust check on third-party installation definitions, and has nothing to do with Apple notarisation. An installation definition is executable Ruby; the current main flow explicitly authorises the Tursora cask first and then installs, without widening this to the whole tap and without turning off the global trust check.

[The official documentation](https://docs.brew.sh/Tap-Trust) states that a fully-qualified install itself also trusts the specified item. The earlier default flow of two commands, tap / install, with an explicit trust only after an error, was a **historical troubleshooting stage**; the user then asked for the single-cask trust to be part of the main install commands, and the three-step flow in D58 now supersedes it. This choice of documentation does not mean that every Homebrew install must rely on a separate trust to succeed; the record below of a successful automatic trust is kept as it is. The user's own Homebrew trust settings on this machine were not modified on their behalf.

Historical troubleshooting verification: in our own isolated Homebrew 6.0.22, after the old test tap had been cleared, the tap with the URL omitted did in fact fail and reported that the default repository does not exist; the two-argument form cloned the public repository successfully, the remote matched exactly, and the cask resolved to 0.2.0 with the official SHA. Then, with two new temporary trust directories and the trust check explicitly enabled: the dry run of an install by short name reproduced `untrusted tap`; after a single-item trust, the install dry run succeeded. In another empty trust directory a fully-qualified install dry run also succeeded directly; both JSON files contained only one cask, with no whole-tap / formula / command trust. The app was neither installed nor launched this time, and the user's prefix and trust files were not modified. The evidence is in `/private/tmp/tursora-tap-diagnosis-3mrphmee/{result.json,trust-result.json}`; a dry run does not replace the real DMG install / uninstall record above.

## Maintaining a new stable version

Publish and verify a real release according to [RELEASING.md](../RELEASING.md) first, then update the cask. The maintenance process is demonstrated below with the **already published** `0.2.0`; for later releases, substitute the new tag and file names. The temporary directory must be created fresh, so that files from different versions cannot be mixed in.

```sh
release_dir="$(mktemp -d -t tursora-homebrew-release)"
gh api repos/zerolfx/Tursora/releases/tags/v0.2.0 > "$release_dir/release.json"
gh release download v0.2.0 --repo zerolfx/Tursora \
  --pattern SHA256SUMS.txt --pattern appcast.xml --pattern Tursora-0.2.0-macOS-arm64.dmg \
  --dir "$release_dir"
python3 app/tools/update-homebrew.py \
  --release-json "$release_dir/release.json" \
  --checksums "$release_dir/SHA256SUMS.txt" \
  --archive "$release_dir/Tursora-0.2.0-macOS-arm64.dmg" \
  --auto-updates --output Casks/tursora.rb
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s app/tools -p 'test_homebrew.py'
ruby -c Casks/tursora.rb
```

`--auto-updates` applies only to a version that includes Sparkle and has already published an appcast. Review the cask diff and confirm that the version, the SHA, the immutable URL, the minimum system and the architecture match the real package, then commit and merge according to the project rules. The cask must not be pointed at unpublished assets ahead of time, and `sha256` must not be replaced with `:no_check`. If a Developer ID is obtained later and notarisation is completed, verify the package's Gatekeeper result first, then remove the cask's un-notarised note and assess the conditions for acceptance into the official repository.

## Local verification of the initial 0.1.0 cask (historical)

The verification directory was `/private/tmp/tursora-distribution-qa`; the user's Homebrew prefix, taps, trust, logs and installed Tursora were not modified, and `/Applications` was not touched.

1. The live GitHub API confirmed that `v0.1.0` is the public, stable, latest version, with a ZIP of 4,101,534 bytes; the ZIP / SHA256SUMS were downloaded, and the actual SHA, the API digest and the checksum file all three agreed. The generator tool's output was byte-for-byte identical to the committed cask.
2. Homebrew 6.0.22 read the cask in a separate temporary prefix and resolved the version, the architecture and macOS 14 correctly. The current `depends_on macos: :sonoma` syntax is used, with no deprecation warning about the old string comparison.
3. `brew install --cask --appdir=<owned temporary directory> zerolfx/tursora/tursora` was actually executed and succeeded. The package version was `0.1.0`, arm64, and strict codesign passed; `com.apple.quarantine` was present. `--no-quarantine` was not used, the quarantine was not removed, and the app was not launched.
4. `brew uninstall --cask zerolfx/tursora/tursora` succeeded, and the temporary app path no longer existed.
5. The 6 release-boundary test methods passed and the Ruby syntax check passed; these standalone tool checks do not replace the final combined application smoke.

## Isolated install verification of the official 0.2.0 DMG

[The official 0.2.0](https://github.com/zerolfx/Tursora/releases/tag/v0.2.0) was published by [Release 34739914582](https://github.com/zerolfx/Tursora/actions/runs/34739914582). The main task saved and verified the real release JSON, SHA256SUMS, DMG and appcast in `/private/tmp/tursora-release-0.2.0-verified/`; the application bundle, the signature and the layout details are maintained centrally in the [release record](release-0.2.0.md).

This round's `update-homebrew.py --auto-updates` generated the cask from those three actual inputs; the DMG is 5,794,277 bytes with the SHA given above. The 6 release-boundary tests and the Ruby syntax check passed. The **self-owned isolated** Homebrew 6.0.22 runtime at `/private/tmp/tursora-distribution-qa/homebrew` used earlier was reused: the old Caskroom was confirmed to be empty, and only the test tap inside it was updated; cache / logs / config / temp / apps used the newly created directory `/private/tmp/tursora-homebrew-0.2.0-i_9y61y8/`. HOME was not overridden, and neither the user's prefix nor `/Applications` was touched.

`brew install --cask --appdir=<that directory>/apps zerolfx/tursora/tursora` actually downloaded from the official URL and installed successfully. The lack of DNS permission in the first sandbox only caused the download to fail; a retry in the same scope with network access allowed succeeded; no fake asset was pre-installed and the quarantine was not removed. The following were then checked:

- The package version `0.2.0` and build `1789275959` are the same as in the cask / the official release, and `auto_updates` is true.
- `lipo <file> -verify_arch arm64` and `codesign --verify --deep --strict` passed.
- `com.apple.quarantine` is kept; the MIT file is byte-identical to the root LICENSE, and the Sparkle / SwiftTerm notices are present.
- The app was not launched; the normal `brew uninstall --cask zerolfx/tursora/tursora` succeeded, and neither the temporary app nor the Caskroom record exists any more.

`cask-info.json`, `installed-verification.json`, `install-network.{out,err}`, `uninstall.{out,err}` and `scope.json` are kept in the new directory. This check is not the same as a first Gatekeeper launch, nor the same as an older version being downloaded, installed and relaunched through the production feed. This section records the local verification before the follow-up was merged; its merge and the remote results are governed by the corresponding PR, the [Homebrew runs](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml) and the [Pages runs](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml). The main task records the exact runs in the PR and in the final evidence JSON, and does not use the old 0.1.0 job in place of the new version's results.

## The first remote CI run and the toolchain fix

The first Homebrew job of PR #8 did install the real 0.1.0 from our own tap and passed strict codesign, after which lipo in Xcode 26.6 mistook the file in `-verify_arch arm64 <file>` for a further architecture argument. Following the tool's hint, the input file was put before the command: `lipo <file> -verify_arch arm64`; the final local verification of the 0.2.0 package passed; the subsequent [PR re-run](https://github.com/zerolfx/Tursora/actions/runs/34739465732) and [main run](https://github.com/zerolfx/Tursora/actions/runs/34739716318) both succeeded, completing the install / version / quarantine / uninstall steps. They verify the 0.1.0 cask as it was then, and cannot be taken as a remote result for the new 0.2.0 cask. The failure does not mean that installation or signing failed, and the later version / quarantine checks were not reached. [The original job](https://github.com/zerolfx/Tursora/actions/runs/34739359685/job/103676301695). This fix affects only the argument order in CI; the 101 Swift source files and the three rounds of 3,329 checks that already passed are entirely unaffected.

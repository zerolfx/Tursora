# Releases and changelog

`CHANGELOG.md` is the user-facing release history. Put new user-visible changes in `## [Unreleased]` as they are implemented. Keep implementation evidence, detailed test counts and historical investigation in the relevant version or feature research record under [research/](research/).

## Update signing and first-release readiness

Sparkle 2.9.6 is pinned by SPM. The app embeds the public Ed25519 key from `app/Resources/SparklePublicKey.txt`; its private counterpart was created in the maintainer's macOS Keychain under account `com.tursora.Tursora`. Reuse that key for subsequent releases. Never commit private key material, include it in an artifact, print it in logs, or generate a new unrelated key for each release.

Stable publication needs the repository Actions secret **`SPARKLE_PRIVATE_KEY`**. It was configured in `zerolfx/Tursora` with explicit maintainer authorization on 2026-09-13 at 00:48:20 Asia/Shanghai (`2026-09-12T16:48:20Z`). The existing Keychain key's derived public key matched the bundled resource before upload through stdin; the temporary mode-0600 export was removed, and GitHub's secret listing confirmed the name and update time. This supersedes the earlier automatic approval-review rejection. Current state is recorded in [the update research](research/app-updates.md). The workflow receives it only in the prerequisite and appcast-signing steps. Ordinary Build and Pages workflows do not need it; configuring the secret does not publish an update.

Current releases provide a DMG directly: open it, then copy Tursora to the user's intended writable application folder. The image's Applications shortcut points to `/Applications`; `~/Applications` or another writable destination is also valid. The published 0.2.1 release provides its DMG, `appcast.xml` and `SHA256SUMS.txt` through the stable feed. Adding code, configuring Pages, or setting the secret alone does not publish a release. Keep the [plain installation guide](../site/install.md), README and website consistent when updating release instructions.

The stable feed is `https://github.com/zerolfx/Tursora/releases/latest/download/appcast.xml`, independent of GitHub Pages. It contains one stable item with embedded release notes, an immutable versioned DMG URL, macOS/architecture requirements, exact byte length and the DMG's Ed25519 signature. The image is authenticated before Sparkle extracts the app. The XML itself is not signed and `SURequireSignedFeed` is not enabled. The app remains ad-hoc signed and not notarized.

## Build the drag-install DMG

Run `tools/make-app.sh`, then `tools/make-dmg.sh [release-version]` from `app/`. The local bundle version defaults to the `VERSION` pinned in `make-app.sh`; `TURSORA_VERSION` can override it, and the Release workflow supplies its explicitly selected version. The optional version defaults to the bundle's short version; a supplied prerelease name must have the same numeric version as the app. Output is `app/dist/Tursora-<version>-macOS-arm64.dmg`. GitHub Releases attaches this DMG directly. GitHub Actions' download service still wraps build artifacts in its own ZIP; that outer wrapper is not the application's installer format.

DMG creation requires Python 3.10+ (`TURSORA_PYTHON` selects the interpreter); both workflows set up Python 3.13. `make-dmg.sh` uses the dedicated `app/.build/dmg-tools` virtual environment and installs `dmgbuild==1.6.7`, `ds-store==1.3.3` and `mac-alias==2.2.3` with all three wheel hashes pinned in `dmg-requirements.txt`. It writes layout metadata directly and does not depend on a running Finder UI.

The compressed read-only image opens a 640 × 280 icon window with 128 px icons: Tursora at `(140, 120)`, Applications at `(500, 120)`, and an arrow background. Applications is a symlink to `/Applications`; no postinstall script or privileged package installer is used. The background's MIT license is included as `.dmgbuild-LICENSE.txt` at the volume root. Keeping that file outside `Tursora.app` preserves the application signature. The script mounts the image read-only, checks the app's architecture/signature/update metadata, symlink, license and `.DS_Store` layout, then detaches before publishing the output. If detaching fails, it preserves its staging directory and reports the path.

The [actual installer capture](images/features/installation.png) records the final local Finder check. It is evidence of the layout; published release and signing readiness remain separate below and in [the update record](research/app-updates.md).

## Apple signing and notarization

The maintainer has confirmed that no Developer ID certificate is available; the local identity check found no valid code-signing identities. This change does not introduce an untested Apple-signing or notarization script. When a suitable Apple Developer Program membership, Developer ID Application certificate/private key and notarization credentials are available, integrate and verify hardened-runtime signing, notarization and ticket stapling as a separate release change. Apple documents the [Developer ID requirements and notarization workflow](https://developer.apple.com/developer-id/). Sparkle's Ed25519 signature authenticates an update to the installed app; it is not Apple notarization and does not grant Gatekeeper trust.

Mac App Store distribution is a separate project, including the [App Sandbox requirement](https://developer.apple.com/documentation/security/app-sandbox) and the corresponding file-access/distribution design. The current DMG release workflow is for direct distribution.

## Prepare a release

1. Finish the implementation and documentation together. Review the diff, run the full application smoke suite three consecutive times, and verify the packaged app. Do not run computer-use checks while smoke is running.
2. Choose an unused semantic version without `v` and write it into the `VERSION` file at the repository root — the only place the number is spelled out. `make-app.sh` reads it for local builds, `site/build.py` substitutes it into the pages and the installation guide wherever they show `{{VERSION}}`, and `app/tools/test_version_source.py` fails if prose starts repeating it again. Then move the Unreleased entries into a dated heading such as `## [0.3.0] - 2026-09-14`; retain an empty Unreleased heading for future work, and update the compare and release links at the bottom of the changelog.
3. Run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s app/tools -p 'test_*.py'` to cover release notes and update metadata. The Release workflow rejects a missing, duplicate or empty version section before creating a tag. It also supplies the repository and exact commit to make repository-relative links usable from GitHub Release pages.
4. Update README download guidance and the version-specific release research record. Commit with the required author identity and the final smoke-test count. Push only with the maintainer's authorization.
5. Confirm remote `main` is exactly the reviewed commit and its Build, Pages and applicable Homebrew checks pass. Dispatch the **Release** workflow on `main`, supplying the version and prerelease flag. A version suffix requires the prerelease flag. Release builds and validates the package but does not run the application smoke suite; the three exact-source local runs remain a prerequisite.

The workflow checks out the dispatch commit and builds the Apple Silicon application. `CFBundleVersion` is the commit's Unix committer timestamp, identical between Build and Release workflows for the same commit. The numeric part of the requested version becomes `CFBundleShortVersionString`; the filename/tag retain a prerelease suffix if present. Do not substitute a workflow run number for the build number: Build and Release have independent sequences.

For a stable release, the workflow requires the signing secret and fetches the current latest release. `update-metadata.py stable-release` rejects a semantic version that does not increase; if the existing release includes an appcast, every prior feed build must also be lower. Timestamp order is checked rather than assumed, so backdated or rewritten commits cannot silently publish a downgrade. The first update-enabled release has no previous appcast to compare and still must exceed `0.1.0`.

The workflow verifies the outer app signature, updater framework/helpers, runtime paths and package metadata, creates and checks the DMG, then runs `make-appcast.sh`. That script stages only the current stable image, embeds release notes, disables deltas and older items, signs the DMG through Sparkle's tool, checks feed fields against the bundle and bytes, and verifies the signature before exposing `appcast.xml` as an asset. A wrong signing key or malformed feed stops publication. `SHA256SUMS.txt` covers both the DMG and appcast.

Finally it atomically creates a new `v<version>` tag at that exact commit and publishes the matching changelog section as release notes. Stable releases explicitly become latest. Prereleases omit the appcast, do not need the signing secret and use `--latest=false`, keeping the stable feed unchanged. Existing tags/releases are never overwritten.

Tag creation and release creation are separate GitHub operations. If publishing fails after the tag is created, a normal rerun will reject the existing tag. Inspect the exact tag SHA and the successful run's verified assets before completing that same release; do not move/delete a published tag or rebuild different bytes under an existing version to bypass the check.

## 0.2.1 preparation (2026-09-13)

The maintainer authorized publication after terminal directory following and the documentation refresh. The final 102 Swift files passed three consecutive 3,435-check smoke runs with unchanged source hashes and empty stderr. The release app and local 0.2.1 DMG passed packaging checks. An isolated packaged app verified hidden task retention, deferred directory following, cancellation of quit while a hidden task ran, the compact terminal header, ZIP parent-directory following and narrow footer layout. Four real application screenshots were refreshed with the pointer outside the captured window. Exact verification is in [the 0.2.1 record](research/terminal-navigation-0.2.1.md).

The source preparation retained 0.2.0 download/cask references and labelled the terminal behavior as upcoming until the real release existed. [0.2.1 is now published](https://github.com/zerolfx/Tursora/releases/tag/v0.2.1) from `c95f4d5aaaf483dd8176873685ac614b47c8100a`, build `1789288838`, by [Release 34748456904](https://github.com/zerolfx/Tursora/actions/runs/34748456904). Its actual immutable assets passed independent digest, signature, metadata and DMG-layout verification, and an isolated copy launched and checked the production feed. The cask was then generated from those verified bytes and installation copy updated to 0.2.1. See [the exact release record and boundaries](research/release-0.2.1.md); 0.2.0 was not retagged or altered.

## 0.2.0 preparation (2026-09-13)

The maintainer has authorized pushing, merging and publishing after terminal hide/retain behavior and quit/close/restart job confirmation are finished. The changelog now contains the dated 0.2.0 section, aggregating changes since 0.1.0 and retaining Unreleased. 0.2.0 has now been published by [Release 34739914582](https://github.com/zerolfx/Tursora/actions/runs/34739914582) from `3ca4ab9ffd43555e4c4118e5504eb6d39e6dc034`, build `1789275959`; actual bytes, signatures and verification boundaries are in [the release record](research/release-0.2.0.md).

The historical read-only preflight found remote main at `b58c1ce5acb0f5318f67feb129073864be4950f1`, successful Build/Pages for that commit, no open PRs, and only the `v0.1.0` tag/release. The 0.1.0 assets are its historical ZIP and SHA256SUMS; `v0.2.0` was then unused and planned as the first updater/DMG release. Do not reuse the earlier customization stage's 3,194-check runs for the new lifecycle code. Final source smoke, packaged-app/DMG validation and changed General/Terminal screenshots are tracked in [the lifecycle record](research/terminal-session-lifecycle.md).

After the checks and the exact reviewed main merge, the following dispatch published 0.2.0. It is a historical invocation; do not rerun it for the existing tag. Future releases must choose a new version:

```sh
gh workflow run release.yml --repo zerolfx/Tursora --ref main \
  -f version=0.2.0 -f prerelease=false
```

Identify the resulting Release run by its main SHA, wait for success, and verify the `v0.2.0` tag resolves to that SHA. The required stable assets are `Tursora-0.2.0-macOS-arm64.dmg`, `appcast.xml` and `SHA256SUMS.txt`. Download into a new owned directory:

```sh
release_dir="$(mktemp -d -t tursora-release-0.2.0)"
gh api repos/zerolfx/Tursora/releases/tags/v0.2.0 > "$release_dir/release.json"
gh release download v0.2.0 --repo zerolfx/Tursora \
  --pattern Tursora-0.2.0-macOS-arm64.dmg \
  --pattern appcast.xml --pattern SHA256SUMS.txt --dir "$release_dir"
(cd "$release_dir" && shasum -a 256 -c SHA256SUMS.txt)
```

Perform the mounted-app and feed checks below, including bundled MIT/third-party notices, and confirm `releases/latest/download/appcast.xml` serves the same feed bytes. The publication run verifies the archive signature separately from metadata. A controlled production-feed update is separate from the previous loopback test.

Only after the real release passes verification, generate its cask:

```sh
python3 app/tools/update-homebrew.py \
  --release-json "$release_dir/release.json" \
  --checksums "$release_dir/SHA256SUMS.txt" \
  --archive "$release_dir/Tursora-0.2.0-macOS-arm64.dmg" \
  --auto-updates --output Casks/tursora.rb
```

Review the generated version, exact SHA and immutable asset URL, run the cask tool checks, then commit/merge the cask follow-up and verify its Homebrew workflow. Remove the prepared/unpublished wording from README and the product page only after publication succeeds, and record Release / Homebrew / Pages URLs and scope in the relevant release, Homebrew and Pages research records. Cask updates, Pages deployment and production update verification are independent steps; Release does not perform them automatically.

## Verify the published result

Check that the workflow succeeded, the release tag resolves to the reviewed commit, and the expected application DMG and checksum file are attached. A stable release must also contain `appcast.xml` and be the repository's latest release. Download the assets, check SHA-256, mount the DMG read-only and verify the application signature, version, architecture, embedded resources, Applications link and layout. Copy its app to an owned test directory before checking app launch/update behavior. Metadata commands:

```sh
python3 app/tools/update-metadata.py verify-bundle /path/to/Tursora.app \
  --public-key app/Resources/SparklePublicKey.txt
python3 app/tools/update-metadata.py verify-appcast /path/to/appcast.xml \
  --archive /path/to/Tursora-0.2.0-macOS-arm64.dmg --app /path/to/Tursora.app
```

Replace the example `0.2.0` archive name with the released version. The appcast metadata command validates fields and returns the archive signature; it is not itself a cryptographic signature verifier. The release script performs the separate Sparkle signature check. For release verification, also exercise a controlled older update-enabled app against the feed, checking download, installation and relaunch without replacing the user's active app. A successful metadata/signing test alone is not evidence that the live installer flow was exercised.

Record the release URL, workflow result, exact commit and verification scope in the version-specific release research record. Publishing a release does not deploy the separate product website or change repository visibility. Pages uses its own workflow; see [site/README.md](../site/README.md).

Before 0.1.0, the changelog was a development log rather than a version history. Those entries are retained in [DEVELOPMENT_HISTORY.md](DEVELOPMENT_HISTORY.md); they are not separate published releases.

## Homebrew tap

The repository itself is a tap. The documented installation flow requires all three steps in order, waiting for each to succeed. The explicit trust step authorizes only the Tursora cask:

```sh
brew tap zerolfx/tursora https://github.com/zerolfx/Tursora
brew trust --cask zerolfx/tursora/tursora
brew install --cask zerolfx/tursora/tursora
```

Without an installed custom tap, the fully qualified install automatically tries the default `https://github.com/zerolfx/homebrew-tursora`; a repository-not-found error for that URL is resolved by adding the explicit remote first. `Casks/tursora.rb` tracks a real published stable application asset with a pinned SHA-256; the current follow-up tracks the published 0.2.1 DMG and sets `auto_updates true`. After publishing and verifying a new stable release, use `app/tools/update-homebrew.py` with its saved release JSON, SHA256SUMS and actual downloaded DMG, review the generated diff and merge it to main. Add `--auto-updates` only for a Sparkle-enabled release that has published its versioned appcast. See [the exact maintenance commands and local verification](research/homebrew.md).

The cask leaves Homebrew's quarantine in place and uses no post-install bypass. Its custom-tap installation does not require Developer ID membership, while official homebrew/cask acceptance has separate Gatekeeper rules. The Homebrew workflow validates this checkout's cask by installing/uninstalling into a temporary runner app directory. Publishing a release does not automatically update or publish the cask. The project MIT license must remain in the packaged app beside the third-party notices.

The block above uses Homebrew's default app directory. For a selected writable destination, set `app_dir` to that actual absolute directory and add `--appdir="$app_dir"` to the install command. This does not make an inaccessible Homebrew prefix writable. The [installation guide](../site/install.md) covers an existing usable Homebrew installation, direct DMG checksum verification, copy conflicts and a targeted `xattr -dr com.apple.quarantine "$app_path"` for the trusted installed copy. It requires no `sudo` or system-wide policy changes; organization restrictions still require appropriate approval. Do not install into the read-only DMG or silently replace an existing application. This documentation is not evidence of an installation or launch test on a non-admin account.

Installation-instruction corrections do not require a new application release. Keep the published 0.2.0 bundle version, build metadata, tag and assets unchanged. The maintainer explicitly requested the single-cask trust command in the main installation block. It is mandatory in our documented flow, even though supported Homebrew versions can also grant that item-level trust automatically during a fully qualified install. This is not a claim that every installation without a separate trust command fails. Trust handling follows [Homebrew Tap Trust](https://docs.brew.sh/Tap-Trust).

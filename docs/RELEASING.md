# Releases and changelog

`CHANGELOG.md` is the user-facing release history. Put new user-visible changes in `## [Unreleased]` as they are implemented. Keep implementation evidence, detailed test counts and historical investigation in the relevant research record and `HANDOFF.md`.

## Update signing and first-release readiness

Sparkle 2.9.6 is pinned by SPM. The app embeds the public Ed25519 key from `app/Resources/SparklePublicKey.txt`; its private counterpart was created in the maintainer's macOS Keychain under account `com.tursora.Tursora`. Reuse that key for subsequent releases. Never commit private key material, include it in an artifact, print it in logs, or generate a new unrelated key for each release.

Stable publication needs the repository Actions secret **`SPARKLE_PRIVATE_KEY`**. It was configured in `zerolfx/Tursora` with explicit maintainer authorization on 2026-09-13 at 00:48:20 Asia/Shanghai (`2026-09-12T16:48:20Z`). The existing Keychain key's derived public key matched the bundled resource before upload through stdin; the temporary mode-0600 export was removed, and GitHub's secret listing confirmed the name and update time. This supersedes the earlier automatic approval-review rejection. Current state is recorded in [the update research](research/app-updates.md). The workflow receives it only in the prerequisite and appcast-signing steps. Ordinary Build and Pages workflows do not need it; configuring the secret does not publish an update.

The original `0.1.0` release has no updater or appcast and retains its historical ZIP download. Its users must manually install the first update-enabled release once. New releases provide a DMG directly: open it, then drag Tursora to Applications. A new stable release with its DMG, `appcast.xml` and `SHA256SUMS.txt` is required before the live update feed becomes available. Adding code, configuring Pages, or setting the secret alone does not publish that release.

The stable feed is `https://github.com/zerolfx/Tursora/releases/latest/download/appcast.xml`, independent of GitHub Pages. It contains one stable item with embedded release notes, an immutable versioned DMG URL, macOS/architecture requirements, exact byte length and the DMG's Ed25519 signature. The image is authenticated before Sparkle extracts the app. The XML itself is not signed and `SURequireSignedFeed` is not enabled. The app remains ad-hoc signed and not notarized.

## Build the drag-install DMG

Run `tools/make-app.sh`, then `tools/make-dmg.sh [release-version]` from `app/`. The optional version defaults to the bundle's short version; a supplied prerelease name must have the same numeric version as the app. Output is `app/dist/Tursora-<version>-macOS-arm64.dmg`. GitHub Releases attaches this DMG directly. GitHub Actions' download service still wraps build artifacts in its own ZIP; that outer wrapper is not the application's installer format.

DMG creation requires Python 3.10+ (`TURSORA_PYTHON` selects the interpreter); both workflows set up Python 3.13. `make-dmg.sh` uses the dedicated `app/.build/dmg-tools` virtual environment and installs `dmgbuild==1.6.7`, `ds-store==1.3.3` and `mac-alias==2.2.3` with all three wheel hashes pinned in `dmg-requirements.txt`. It writes layout metadata directly and does not depend on a running Finder UI.

The compressed read-only image opens a 640 × 280 icon window with 128 px icons: Tursora at `(140, 120)`, Applications at `(500, 120)`, and an arrow background. Applications is a symlink to `/Applications`; no postinstall script or privileged package installer is used. The background's MIT license is included as `.dmgbuild-LICENSE.txt` at the volume root. Keeping that file outside `Tursora.app` preserves the application signature. The script mounts the image read-only, checks the app's architecture/signature/update metadata, symlink, license and `.DS_Store` layout, then detaches before publishing the output. If detaching fails, it preserves its staging directory and reports the path.

The [actual installer capture](images/features/installation.png) records the final local Finder check. It is evidence of the layout; published release and signing readiness remain separate below and in [the update record](research/app-updates.md).

## Apple signing and notarization

The maintainer has confirmed that no Developer ID certificate is available; the local identity check found no valid code-signing identities. This change does not introduce an untested Apple-signing or notarization script. When a suitable Apple Developer Program membership, Developer ID Application certificate/private key and notarization credentials are available, integrate and verify hardened-runtime signing, notarization and ticket stapling as a separate release change. Apple documents the [Developer ID requirements and notarization workflow](https://developer.apple.com/developer-id/). Sparkle's Ed25519 signature authenticates an update to the installed app; it is not Apple notarization and does not grant Gatekeeper trust.

Mac App Store distribution is a separate project, including the [App Sandbox requirement](https://developer.apple.com/documentation/security/app-sandbox) and the corresponding file-access/distribution design. The current DMG release workflow is for direct distribution.

## Prepare a release

1. Finish the implementation and documentation together. Review the diff, run the full application smoke suite three consecutive times, and verify the packaged app. Do not run computer-use checks while smoke is running.
2. Choose an unused semantic version without `v`. Move the Unreleased entries into a dated heading such as `## [0.2.0] - 2026-10-01`; retain an empty Unreleased heading for future work. Update the compare and release links at the bottom of the changelog.
3. Run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s app/tools -p 'test_*.py'` to cover release notes and update metadata. The Release workflow rejects a missing, duplicate or empty version section before creating a tag. It also supplies the repository and exact commit to make repository-relative links usable from GitHub Release pages.
4. Update README download guidance and current handoff information. Commit with the required author identity and the final smoke-test count. Push only with the maintainer's authorization.
5. Confirm remote `main` is exactly the reviewed commit. Dispatch the **Release** workflow on `main`, supplying the version and prerelease flag. A version suffix requires the prerelease flag.

The workflow checks out the dispatch commit and builds the Apple Silicon application. `CFBundleVersion` is the commit's Unix committer timestamp, identical between Build and Release workflows for the same commit. The numeric part of the requested version becomes `CFBundleShortVersionString`; the filename/tag retain a prerelease suffix if present. Do not substitute a workflow run number for the build number: Build and Release have independent sequences.

For a stable release, the workflow requires the signing secret and fetches the current latest release. `update-metadata.py stable-release` rejects a semantic version that does not increase; if the existing release includes an appcast, every prior feed build must also be lower. Timestamp order is checked rather than assumed, so backdated or rewritten commits cannot silently publish a downgrade. The first update-enabled release has no previous appcast to compare and still must exceed `0.1.0`.

The workflow verifies the outer app signature, updater framework/helpers, runtime paths and package metadata, creates and checks the DMG, then runs `make-appcast.sh`. That script stages only the current stable image, embeds release notes, disables deltas and older items, signs the DMG through Sparkle's tool, checks feed fields against the bundle and bytes, and verifies the signature before exposing `appcast.xml` as an asset. A wrong signing key or malformed feed stops publication. `SHA256SUMS.txt` covers both the DMG and appcast.

Finally it atomically creates a new `v<version>` tag at that exact commit and publishes the matching changelog section as release notes. Stable releases explicitly become latest. Prereleases omit the appcast, do not need the signing secret and use `--latest=false`, keeping the stable feed unchanged. Existing tags/releases are never overwritten.

## Verify the published result

Check that the workflow succeeded, the release tag resolves to the reviewed commit, and the expected application DMG and checksum file are attached. A stable release must also contain `appcast.xml` and be the repository's latest release. Download the assets, check SHA-256, mount the DMG read-only and verify the application signature, version, architecture, embedded resources, Applications link and layout. Copy its app to an owned test directory before checking app launch/update behavior. Metadata commands:

```sh
python3 app/tools/update-metadata.py verify-bundle /path/to/Tursora.app \
  --public-key app/Resources/SparklePublicKey.txt
python3 app/tools/update-metadata.py verify-appcast /path/to/appcast.xml \
  --archive /path/to/Tursora-0.1.1-macOS-arm64.dmg --app /path/to/Tursora.app
```

Replace the example `0.1.1` archive name with the released version. The appcast metadata command validates fields and returns the archive signature; it is not itself a cryptographic signature verifier. The release script performs the separate Sparkle signature check. For release verification, also exercise a controlled older update-enabled app against the feed, checking download, installation and relaunch without replacing the user's active app. A successful metadata/signing test alone is not evidence that the live installer flow was exercised.

Record the release URL, workflow result, exact commit and verification scope in the handoff. Publishing a release does not deploy the separate product website or change repository visibility. Pages uses its own workflow; see [site/README.md](../site/README.md).

Before 0.1.0, the changelog was a development log rather than a version history. Those entries are retained in [DEVELOPMENT_HISTORY.md](DEVELOPMENT_HISTORY.md); they are not separate published releases.

## Homebrew tap

The repository itself is a tap via `brew tap zerolfx/tursora https://github.com/zerolfx/Tursora`. `Casks/tursora.rb` tracks a real published stable application asset with a pinned SHA-256; currently it is the historical 0.1.0 ZIP. After publishing and verifying a new stable release, use `app/tools/update-homebrew.py` with its saved release JSON, SHA256SUMS and actual downloaded DMG, review the generated diff and merge it to main. Add `--auto-updates` only for a Sparkle-enabled release that has published its versioned appcast. The original 0.1.0 must not receive that flag. See [the exact maintenance commands and local verification](research/homebrew.md).

The cask leaves Homebrew's quarantine in place and uses no post-install bypass. Its custom-tap installation does not require Developer ID membership, while official homebrew/cask acceptance has separate Gatekeeper rules. The Homebrew workflow validates this checkout's cask by installing/uninstalling into a temporary runner app directory. Publishing a release does not automatically update or publish the cask. The project MIT license must remain in the packaged app beside the third-party notices.

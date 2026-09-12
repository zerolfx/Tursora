# Releases and changelog

`CHANGELOG.md` is the user-facing release history. Put new user-visible changes in `## [Unreleased]` as they are implemented. Keep implementation evidence, detailed test counts and historical investigation in the relevant research record and `HANDOFF.md`.

## Prepare a release

1. Finish the implementation and documentation together. Review the diff, run the full application smoke suite three consecutive times, and verify the packaged app. Do not run computer-use checks while smoke is running.
2. Choose an unused semantic version without `v`. Move the Unreleased entries into a dated heading such as `## [0.2.0] - 2026-10-01`; retain an empty Unreleased heading for future work. Update the compare and release links at the bottom of the changelog.
3. Check the release-note extractor and its tests with `python3 -m unittest discover -s app/tools -p 'test_release_notes.py'`. The Release workflow rejects a missing, duplicate or empty version section before creating a tag.
4. Update README download guidance and current handoff information. Commit with the required author identity and the final smoke-test count. Push only with the maintainer's authorization.
5. Confirm remote `main` is exactly the reviewed commit. Dispatch the **Release** workflow on `main`, supplying the version and prerelease flag. A version suffix requires the prerelease flag.

The workflow checks out the dispatch commit, builds the Apple Silicon application, verifies its signature and package metadata, packages and re-extracts the ZIP, and emits `SHA256SUMS.txt`. It atomically creates a new `v<version>` tag at that exact commit and publishes the matching changelog section as release notes. Existing tags/releases are never overwritten.

## Verify the published result

Check that the workflow succeeded, the release tag resolves to the reviewed commit, and both the application ZIP and checksum file are attached. Download those two assets, check the SHA-256, extract the ZIP and verify the application signature, version, architecture and embedded resources. Record the release URL and workflow result in the handoff. Publishing a release does not deploy the separate product website or change repository visibility.

Before 0.1.0, the changelog was a development log rather than a version history. Those entries are retained in [DEVELOPMENT_HISTORY.md](DEVELOPMENT_HISTORY.md); they are not separate published releases.

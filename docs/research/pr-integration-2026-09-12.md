# PR integration of three Dolphin features (2026-09-12)

## Baseline and method

Starting from main `ae5e47a`, PR #1 per-directory views (`820cf4e`), PR #2 file operation tasks (`88714d4`) and PR #3 search (`31203d6`) were checked against it; the GitHub Build of all three original PRs passed. The smoke and on-machine evidence of each original task stays in its feature research record.

The integration was done in `/private/tmp/tursora-merge-integration`, keeping the main working copy and the three development worktrees. Directory views were brought into the operation tasks first, then into search; the later PRs resolved their conflicts through a merge commit containing the preceding branch, and the final merge order was #1, #2, #3. Builds can run in parallel, while the smoke test and the packaged-app checks share one `fcntl.flock`, saving and restoring the two application preference domains around them.

## Review findings and regressions

- An atomic move within one volume should not recursively read descendants that do not need copying; a directory containing a FIFO, or whose descendants cannot be enumerated, should still move atomically.
- When an identity check fails, the undo log must not delete the only recovery copy just because UndoManager consumed the action; the recovery location is kept and reported to the user.
- Once directory views are restored, the icon round of the transfer smoke test has to set icon mode after the final directory has loaded, and check the real mode.
- A search page must isolate the persisted properties, observers and default/reset actions of the source directory and of the unified default, and a refresh must not slip back to an ordinary directory.
- File transfers from search results use the real URLs with parent/child deduplication, completion and undo keep refreshing the search, and a search page with no default target must not be treated as a directory that can be pasted into. If there is a symlink between a selected ancestor and a child, the explicitly selected child is still kept on its own; the automation covers the directory, the link text and the external file contents after the copy has actually been made.

## Current verification status

The combination of directory views and file operation tasks (including the review fixes) completed `swift build`, and the 1,063-check smoke test passed three consecutive rounds with empty stderr; the site build passes. The old ZIP test now tracks the identity of the window this operation adds, so that other test windows closing asynchronously cannot make the total count unreliable, and it covers the counter-example of a swapped window with an unchanged count.

Verification of the final three-feature combination (including the symlink fix made along the way):

- The debug build succeeded, and the **1,253-check smoke test passed three consecutive rounds**, each exiting 0 with empty stderr, taking 74.8 / 74.2 / 74.0 seconds. The logs are in `/private/tmp/tursora-integration-verification/final-verified/`. The earlier three rounds of 1,249 checks belong to the state before the symlink fix and do not count towards the final result.
- The `tools/make-app.sh` release build succeeded, and `codesign --verify --deep --strict --verbose=2` passed. The pre-existing compiler warnings are still present, so this is not called a warning-free build.
- The site build passes, with 36 references and 5 canonical assets checked.
- The [GitHub Build](https://github.com/zerolfx/Tursora/actions/runs/34685214129) of PR #2 integration commit `1464169` passed. CI for the exact commits of the final PR #3 and of main is checked separately at release time; local results are no substitute for the remote checks.

## Measurements on the final packaged app

Using the release bundle above and the one-off fixture `/private/tmp/tursora-integration-verification/cua-demo`; the process sets `TURSORA_TRANSFER_TEST_DELAY_MS=100` so that the chunked transfer of a genuinely large file can be observed — the rates are not a performance benchmark.

- First and Second under Sources each hold a `needle.txt` of the same name, and there is also a 128 MiB `needle-large.bin`. A recursive name query returns 3 results, and both the list and the icon view show each result's original location.
- Sources has List saved; switching to Icons during a search and then closing the search restores List. Destination has Icons saved; Back to Sources is List, and Forward into Destination again is Icons.
- Duplicating the large file from the list search results shows bytes, rate and remaining time in the task window. Pause was confirmed at 59.8 / 134.2 MB, and the byte count was watched afterwards and did not move; after Resume it continued to 60.8 MB, and Cancel ended it at 73.9 MB, showing 0 completed. The original file's SHA-256 stays `a626d17da2e502f5b4b8e3ebd23f0bf9daef6255688d8e0bb482b3ae3794a682`, with no half-finished output and no staging leftovers.
- After duplicating the small file the search returns 4 items and selects exactly the copy inside First; after undo it is back to 3 items, and the contents of the two same-named original files are unchanged.
- The named condition `Integration Needle` was saved, and after Clear, Open reran it and returned 3 items. For the dedicated measurement of saving across processes see the [separate search record](search-verification.md); rerunning inside the same process this round is not called a restart verification.
- The actual layout of search and of a paused task was looked at; the existing feature screenshots still match the current interface. Afterwards this round's application was quit, the original files were confirmed intact and the cleanup complete, the two preference domains and the directory view library were restored, and the shared lock was released.

This round adds no on-machine evidence for a real Spotlight content hit, for a second physical volume or a server, or for native drag-and-drop gestures. The limits of the automation for the content-injection fixture and the native query lifecycle, for cross-volume fault injection, and for the drop controller path remain as the original records distinguish them.

## Commit message convention

At the user's request, AGENTS and DEVELOPMENT were changed to require a concrete module scope (for example `search`, `transfers`, `view-settings`); global or cross-module commits omit the scope. Once the three PRs were done, the commit messages on main were rewritten, keeping the original author, time, parent relationships and every tree; the old history is kept as a backup ref, and publishing uses an exact force-with-lease. The tree comparison before and after the rewrite, and the remote CI, are confirmed by the delivery record once it is finished.

# Search verification (2026-09-12)

This record belongs to the separate worktree `d660/Tursora`, whose original baseline is `fbb6762` and which was synced with `main` at `ae5e47a` before committing (keeping the product page and the maintenance tidy-up), on the branch `codex/recursive-saved-search`. Uncommitted content from other feature worktrees was not brought in.

## Scope of the automation

`SearchSmokeTests.swift` tests the pure criteria and an injected backend first, then a real pane. Content criteria are verified against a deterministic index fixture, so nothing depends on when the system index becomes visible.

- The name / content distinction, case and diacritics, literal quotes not injected into the predicate, type AND date, start inclusive / end exclusive.
- Nested files with the same name, recursion into unindexed directories, empty results / invalid directories, symlink / package boundaries.
- Late results after cancel, replace and clear; synchronous delivery, duplicate batches, callbacks after the final state; permission failures and date errors without a modal.
- Saved requests round-tripping through the Store and through JSON, with the real Save / Open / Delete / Clear controls; deleting a criterion keeps the files.
- List and icon views, grouping and name filtering, Location, Open / Quick Look / Share / Info / Reveal on real URLs, rename / undo; a late rename notification does not change the wrong same-named item.
- Isolation between split panes and between tabs, cancelling navigation, the original directory history not being overwritten by the search selection, and the ZIP search entry point and saved criteria not crossing the read-only boundary.

A separate adversarial review found and fixed: the search basename leaking into the navigation history; inline editing binding to the wrong target after a result row was reused; icon grouping resolving new results with a stale indexPath; the context menu target drifting after a result batch reordered the rows; Trashing a parent directory and a descendant at the same time not registering undo; and `skipDescendants()` on a symlink leaf causing later directories to go unsearched. The last of these was reproduced against the failing fixture with a separate Foundation probe; after the fix, symlink leaves are no longer skipped by hand.

Development also corrected the tests' `/var` / `/private/var` representation difference, and a setting that kept a file type criterion across tests; those failures do not count as final passing rounds. The version before the CUA work had 854 checks pass three rounds in a row with empty stderr, and release / strict codesign passing; a content query on a real machine then revealed that an AND/OR with a single child is not supported by NSMetadataQuery and exits abnormally. A single criterion was changed to a direct predicate, and an empty criterion now uses a supported match-all on the file name; 74 native start / finish checks against the actual production predicate, plus pure structural checks, were added, and the final integrated version has completed **891 checks passing three rounds in a row**, all with exit 0 and empty stderr; the debug / release builds and strict codesign passed. The logs are `verified-1/2/3.stdout` and the matching `.stderr`. The old shortcut integration test was changed to ⌥⇧⌘F, which Search does not occupy.

## The actual Spotlight path

After the fix the actual `SearchRequest.swift` was compiled into a native probe: all 74 criteria returned `start() == true` and received DidFinishGathering, with empty stderr; they include every type, name / date combination, and literal quotes, wildcards and backslashes. Every result was 0, which verifies that the API accepts the criteria actually generated but does not amount to a positive content hit. The logs are at `/private/tmp/tursora-search-exact-predicate-probe/`.

An earlier standalone `NSMetadataQuery` probe queried the metadata service for this worktree for real: all four predicates — file name, content `CONTAINS[c]` / `CONTAINS[cd]`, and text type — returned `start() == true` and received DidFinishGathering. All four results were 0; `mdfind` over the same scope also counted 0 for content; `mdutil -s /` shows Indexing enabled. A read-only probe of the original source directory `/Users/zerol/Workspace/Tursora` was also 0.

The execution tool's restricted sandbox cannot reach the metadata service, where `start()` returns false; the authorised local run succeeded. What this verifies is the start, the final state and the empty-index path of the real API / service; **a positive content hit is not treated as verified**, and no indexing setting was changed and no index rebuild forced. Content results are determined by the formats Spotlight supports, by permissions, privacy exclusions and the current index, and the application keeps showing that limitation.

The probe and the local build / smoke / codesign logs are kept in this machine's dedicated directory `/private/tmp/tursora-search-verification-d660/`. Every smoke and CUA run held an exclusive flock on `/private/tmp/tursora-shared-verification.lock` across the whole of the actual run; preferences were saved before the run and restored afterwards, and only absolute paths inside this worktree or its own PID were touched.

## computer-use on the packaged app

The release bundle of this worktree was driven against its dedicated demo directory `/private/tmp/Tursora-Search-d660` (no personal files):

- A single-criterion content query finished normally with 0 results, the Spotlight index / format limitation is visible in the interface, and the run log's stderr was empty.
- The name `Project Notes` recursively returned the three same-named files in Delivery, Design and Research/Notes; the list's Location and the icon view's parent path each show the real location.
- After splitting, the left side keeps the three results while the right side searches independently for `Meeting`, and the icon view shows only the one item in Research.
- Save names the criterion, and after ending its own PID the app was really restarted; Saved Searches → Open from Home restored the original demo directory and the three results. After Delete the criteria list is empty and the demo files are still intact; Clear removes the current results and the criterion without starting a whole-directory query.
- An earlier packaged check actually selected the same-named item in Design and previewed it with Space, whose content is Design's demo text; Reveal in Enclosing Folder navigated to Design and selected exactly that file.

After the three smoke rounds, the final release bundle, which includes the menu target and parent/child selection fixes, was checked again: the search context menu has no Compress, and clicking Reveal on the Design result arrived at the real Design directory with exactly the right file selected; the independent split-pane query, the saved criterion and the completion of a single-criterion content query were all exercised once more.

From the confirmed worktree PID `80602` and main window ID `7467`, `screencapture -x -o -t jpg -l7467` was used to save and inspect [search.png](../images/features/search.png) (3840 × 1920). The screenshot shows the three same-named results and the saved criterion on the left, and the independent icon query on the right. The final run's stderr was empty; only its own PID was stopped, and the shared lock was released after the pre-run preferences had been restored.

While syncing the upstream product page, the statement that content / cross-directory search was still not implemented was corrected, and `python3 site/build.py` passed (5 canonical assets, 36 references). This round only changed the feature-boundary wording on that page; the page was not deployed.

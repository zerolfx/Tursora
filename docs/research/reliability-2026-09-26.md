# Reliability and maintenance — 2026-09-26

## Scope

The owner requested the six findings from the repository review, asynchronous address completion, browser responsibility separation and roadmap correction. This change covers collision-safe single rename/undo, partial Trash recovery, complete external ZIP export, failed-directory row invalidation, Unicode listing boundaries, isolated smoke preferences and fixture cleanup. It does not add product features or change application identity.

## Evidence before implementation

- An isolated Foundation script reproduced `URLResourceValues.name` overwriting an existing sibling and an undo-style rename overwriting a newly created original name. The older batch-rename record described the overwrite but incorrectly claimed inline rename had a collision guard.
- The unchanged directory model with an injected failing provider left one grouped row after clearing its root nodes. Real icon and grouped-list delegates consume those groups.
- The unchanged ZIP listing parser changed `中文.txt` to replacement characters when a UTF-8 character straddled the 1 MiB read boundary.
- Source tracing showed Trash discarded successful pairs when a later item threw; promise and Share callbacks ignored descendant failures when a parent URL existed; smoke favourites reset was not restored.

## Implementation

- Exclusive single rename is enforced in FileOperations, shared by browser edits, Info and undo/redo. Trash returns moved pairs and per-item failures, so origins, undo and directory notifications survive partial success.
- ArchiveExport validates complete results for file promises and sharing, including already-settled failed descendants. Promise copies stage on the destination volume before publication. The listing parser retains raw incomplete-line bytes.
- Directory failures clear rows, groups and folder-size work together.
- AppDefaults selects a unique smoke preference suite before application stores are initialized. Normal launches still use their existing domain. Packaged QA can opt into `TURSORA_UI_TEST_DEFAULTS_DOMAIN=com.tursora.ui-test.<identifier>`; frame autosave is disabled for isolated runs because AppKit writes standard defaults directly.
- Fixture teardown cancels measurements and detaches persistence callbacks, then closes windows and flushes stores before removing their directories. The folder-tree inactivity assertion waits for the followed ancestor chain to finish, rather than only the root listing. Folder-size callback checks await the coalesced notification separately from cache readiness.
- PathCompletionService debounces by 120 ms, uses at most two workers per navigator and caches at most eight directory snapshots for one second. A snapshot over 4,096 entries or 1 MiB of names is not retained. The bar rejects stale editor/text/caret/location results.
- BrowserFileOperations owns commands, transfers and undo registration. BrowserArchiveAccess owns pane archive reads, batching, cancellation, progress and hand-off. BrowserViewController retains pane/navigation state. ArchiveExport owns external completeness policy.
- The roadmap and gap ordering now distinguish delivered batch rename, content scanning, preview, column view, folder sizes, spring loading and user Trash from remaining work.

## Automated verification

Before the later smoke consolidation, the integrated `swift build` and `tools/make-app.sh` release build passed. That unchanged Swift source passed three consecutive complete smoke runs under the shared verification lock:

| Log | Successful assertions | Duration | Exit | New temporary fixtures remaining |
| --- | ---: | ---: | ---: | --- |
| `verified-1.log` | 5,138 | 229.0 s | 0 | None |
| `verified-2.log` | 5,138 | 232.3 s | 0 | None |
| `verified-3.log` | 5,138 | 234.4 s | 0 | None |

All three runs completed the final production-preference comparison unchanged. Logs, build output and a source fingerprint are retained under `/private/tmp/tursora-reliability-20260926-722c`. `git diff --check` and local documentation-link validation passed.

During integration, a full passing run still recreated `sizes-views.json` after fixture removal; teardown now stops the late metrics-to-persistence callback. A repeated run also exposed the independent cache/notification readiness race; its bounded callback assertion now waits for actual notification delivery. The three runs above followed both test fixes. These findings and the previously corrected address-focus/fixture-listing waits are not reported as product failures in the accepted final run.

Added suites: FileMutationSafetySmokeTests, ArchiveExportSmokeTests, DirectoryLoadingSmokeTests, PathCompletionSmokeTests and PreferencesIsolationSmokeTests. Existing real address-editor checks await completion. Standalone native probes are preliminary evidence only, not a substitute for full smoke verification.

## Packaged-app observation

Inspected the release bundle at `/Users/zerol/.codex/worktrees/722c/Tursora/app/build/Tursora.app`, retaining its normal `com.tursora.Tursora` identity. The owned QA process used `com.tursora.ui-test.reliability-20260926-722c` preferences and separate session, view-properties and Trash-origin files under `/private/tmp/tursora-reliability-20260926-722c/ui`. Verification held the shared app-test lock.

Observed through the actual packaged AppKit UI and screenshots:

- Inline rename of `source.txt` to the occupied `occupied.txt` displayed a file-exists alert. After dismissal both rows remained; a filesystem read after quit confirmed both original byte strings were intact.
- Typing the fixture path ending in `Al` displayed the `Alpha` candidate and selected only the completed suffix. Tab followed by Return navigated into `Alpha` and returned focus to the empty file list.
- Returning to the fixture and switching among List, Icons and Columns retained the six entries. Columns displayed the original source text in its preview.
- Opening `sample.zip` and then `中文目录` displayed `说明.txt` correctly in List and Icons; the icon thumbnail showed the fixture text and the status remained ZIP read-only.

The QA app quit normally (exit 0), and a semantic comparison of the production preference domain before/after was unchanged. The dedicated QA preference suite was removed. Logs and task-owned fixture files remain under the QA directory for inspection. The visual pass preceded the final test-only teardown and notification-wait refinements; the release bundle was rebuilt with those refinements, with no further production behavior changes. This visual pass covers the interactions above at an expanded window size; corrupted-export promises, Share callbacks, partial Trash, failed-directory loading, Unicode read boundaries and slow/stale completion requests are covered by automated checks rather than claimed as manual observations. Existing README screenshots still describe the same visible workflows and were not replaced by test-fixture screenshots.

After smoke consolidation, the final debug and release builds passed and the unchanged source passed three consecutive full runs: 5,056 assertions, 4,600 result lines and 53 named scopes per run, in 221.4, 219.6 and 220.1 seconds. All runs preserved production preferences and left no new temporary fixtures. The separate [smoke-suite size review](smoke-suite-review-2026-09-26.md) records the consolidation, counter validation and final measurements separately from the earlier baseline above.

The final rebuilt package received a second visual pass using `com.tursora.ui-test.reliability-20260926-722c-simplified` and separate stores under `/private/tmp/tursora-reliability-20260926-722c/simplified/ui`. Observed again: the file-exists alert, `Al` completion to `Alpha/` with Tab/Return navigation and file-list focus, six fixture entries in all three views, and the ZIP's `中文目录/说明.txt` name and text thumbnail in Icons. The owned process quit with exit 0, both rename fixture byte strings remained intact, production preferences were unchanged, and the QA preference suite was removed. This final visual pass covers those interactions; the automated-only cases listed above remain covered by smoke tests.

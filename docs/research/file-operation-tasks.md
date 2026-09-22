# File operation tasks and verification

## Dolphin source evidence

Read-only reference to `/Users/zerol/Workspace/Tursora/upstream/dolphin/src`, checked against pin `5e457ee9e88aa6277fbf056cd5c32462c5318866` (2026-08-18).

- `views/dolphinview.cpp:945–986`: Copy / Move are separate `KIO::CopyJob`s, bound to the originating window, subscribing to the result and to created-item notifications, and handed to `FileUndoManager` to record.
- `views/dolphinview.cpp:1001–1050`: Duplicate uses an asynchronous `KIO::copyAs`, renames automatically and records undo.
- `views/dolphinview.cpp:1517–1545`: drag and drop routes the actual copy task through a DropJob.
- `views/dolphinview.cpp:2637–2657`: Paste uses a separate PasteJob and listens both to the copy task and to the final result.

That code supports turning everything into a uniform task, fixing the window context, and driving undo from successful results; progress presentation and the suspend capability itself come from the external KIO / KJob layer, whose implementation is not here, so it cannot be claimed on this basis that every detail is reproduced. Tursora uses a local transfer engine and a native AppKit task window, and adds no network protocol backend.

## Implementation and limits in this round

Data in regular files is read and written block by block and can be paused / resumed / cancelled midway; scanning with an unknown total, metadata / fsync and the atomic publish show their real stage. Existing permissions, timestamps, ACLs, extended attributes, resource forks, quarantine flags, symlinks and bundles are preserved through system metadata copying and controlled staging. A Locked copy has its flag adjusted only temporarily, during a rename the app itself owns, and it is restored immediately; the user's original source and an existing replacement target are never unlocked.

Temporary storage comes from the system `.itemReplacementDirectory`, verified to be on the same volume as the file in question; internal recovery directories are never left behind in ordinary browsing directories. After success the undo log keeps the content needed to restore; on cancellation / failure the cleanup happens first and the terminal state is posted afterwards. A cross-volume move only moves the source into the same-volume recovery area once the target is complete, and reclaims it when the undo history is released. The cost is extra space, and there is no support for recovering a session after a crash.

Same-volume moves, metadata system calls and the short publish transaction cannot be guaranteed to stop immediately within a single system call; Cancel takes effect at the next boundary. Items already published remain successful changes, the batch shows as partially complete, and it can be undone. Closing a browser window cancels its tasks and waits; closing the task window only hides it; quitting first cancels the transfers and then closes the archive workspace. The ZIP compression stage, Trash and delete are outside the range of pausable transfers. ZIP extraction became a task of its own in D90: determinate progress and Cancel, deliberately without Pause, and driven by the archive tool's verbose stream rather than by the transfer engine — see [extraction progress](archive-extraction-progress.md).

## Independent adversarial review

A collaborator who did not write the engine reviewed the file operations and the asynchronous lifecycle, confirming and fixing the following:

- The source / target directory being replaced while a conflict waits or between Merge child items, which would make the task act on a new directory: directory identity is pinned, and child items and empty directories are verified again before being moved away.
- Content inside the same inode being updated after a Replace wait, and a cross-volume source being updated while waiting for the commit lock: the full file state is checked once the lock is held.
- The terminal state arriving before the staging cleanup: cleanup first, terminal state delivered afterwards, and quitting cannot happen before the worker thread's cleanup.
- Waits that never end because the quit-cancel completion callback fired synchronously, or because Clear Finished removed part of the terminal state: the completion callback is asynchronous and the end is decided from the set of still-active tasks.
- System metadata copying preserving the Locked flag, which caused EPERM when publishing from staging: reproduced by measurement in an isolated fixture, and flag handling was fixed for copy publish / undo / redo and for discarding staging.
- A file being edited after a cross-volume move, and new child items being added before a merge redo: restoring a stale copy or moving away new content is refused.
- A fast failure not opening the task window, and a new conflict hidden behind old history: a failure prompts once automatically, and a new task is put on top with the view positioned on the task that needs action.
- The `/var` and `/private/var` aliases of the macOS temporary directory mis-judging the retained set of recovery content: the physical path of the system recovery root is normalised, while the leaf symlink itself is preserved.
- `copyfile` rewriting the origin field of the quarantine attribute: after checking the byte differences in a fixture, the quarantine attribute is preserved exactly.

## Verification record

2026-09-12, feature branch with `fbb6762` as its baseline; after the final debug build, **928 smoke checks passed three times in a row**, every run exit 0 with empty stderr. The three rounds of 739 checks in the older documents belong to the baseline; the failed runs during development, the 922-check pass and the three rounds of 926 checks before the explicit ACL assertions were added do not count towards the final three rounds.

Dedicated coverage: pausing / resuming / cancelling a single file midway, independent concurrent tasks, cancellation and failure at the scan / write / publish / source-moved-away boundaries, Replace / Merge / Keep Both / Skip / Apply to all, undo and redo of successful items, directory identity changes, content changing while a replacement waits, a cross-volume recovery copy being edited, and content added after a directory merge. Metadata fixtures check permissions, timestamps, ACLs, extended attributes, resource forks, the quarantine attribute, Locked, bundles and dangling symlinks. Controller checks cover list / icon views, filtering and grouping, the context staying fixed across split panes / navigation / new tabs / closing tabs, clipboard and drag-and-drop callbacks, Duplicate, background pane refreshes, the task button and cleanup when the window closes; the fast-failure prompt and positioning on a conflict among older tasks also have dedicated assertions. The existing ZIP copy-out tests keep running through the same engine.

The final release bundle was produced by `tools/make-app.sh`, and `codesign --verify --deep --strict --verbose=2 app/build/Tursora.app` passed. The logs are kept in this worktree at `app/build/transfer-verification/smoke-{1,2,3}.log`, with the matching `.stderr` files and `codesign.log` (build products are not committed). All smoke runs happened inside the exclusive lock at `/private/tmp/tursora-shared-verification.lock`, with both preference domains `Tursora` and `com.tursora.Tursora` saved and restored before and after.

The cross-volume branch was verified by injection through `forceCrossVolumeMove`; this machine has no second writable independent volume, so this result is not called a real cross-volume verification on a real machine. Real server reads and writes are not verified either.

## Packaged-app checks

The final release bundle was exercised through CUA; the process was checked to be this worktree's `app/build/Tursora.app/Contents/MacOS/Tursora` (PID 79930), and no other worktree's app was operated. The final three smoke rounds and the CUA session below ran back to back inside the same exclusive lock; after the app quit normally, both preference domains were restored and the lock released. Subsequent documentation, commits and CI do not hold the verification lock.

The demo fixture is in this worktree at `app/build/transfer-verification/demo`. Two 128 MiB files use the process environment `TURSORA_TRANSFER_TEST_DELAY_MS=100` to slow block transfer down so that mid-transfer operations can be observed steadily; these are real file reads and writes, and the speeds in the screenshots are not a performance benchmark.

- Copied `Research footage.bin` with Copy / Paste in the list view and clicked Pause at 101.2 MB / 134.2 MB; the value was then observed to stay unchanged repeatedly, and the target directory held no unfinished file.
- Closed the task window, switched directory and to the icon view, and started `Delivery assets.bin` with Copy / Paste. Reopening from Window → File Operations, the first item was still paused and the second transferred independently showing speed / ETA. Cancelling only the second one, the first completed fully after Resume.
- Ran Move to Other Pane in the icon split; the `Readme.txt` conflict positioned itself automatically at the top of the tasks; the native same-volume move showed No file data to transfer. Clearing old task records did not affect the conflict; after Keep Both both panes refreshed, the existing target was kept and the source moved to `Readme 2.txt`.
- In the originating window, undid the Move, then undid the earlier Copy, then redid the Copy; the operations still acted on the original targets, and Clear Finished did not empty the window's undo history.
- Duplicate in the icon view produced a task as well; after pausing at 44.3 MB / 134.2 MB, pressed ⌘Q; the app quit normally (exit 0), the paused thread was cancelled and no copy was left behind.
- After quitting, compared the SHA-256 values from before the demo one by one: the three source files and the existing target `Readme.txt` were all unchanged; the Copy completed after Resume matched the original file; the cancelled Copy, the Duplicate cancelled by quitting and the undone Keep Both output were all absent. The results are kept in `app/build/transfer-verification/demo-after-checks.json`.

Real JPEG screenshots: [`file-operation-tasks.png`](../images/features/file-operation-tasks.png) shows one item paused and one transferring; [`file-operations.png`](../images/features/file-operations.png) shows an inline conflict placed ahead of the history records. The actual image format and legibility were checked; the interface was neither stitched together nor simulated. An immediate screenshot taken after clearing the history showed no cards and was not used as evidence of completion; the original screenshot visually confirmed before clearing is kept, and the Keep Both button was then really operated successfully.

Packaged-app limits: the drag-and-drop gesture attempted in this round only changed the selection and did not start a transfer, so it is not recorded as successful evidence of a native drag and drop; what was verified afterwards was the Move to Other Pane command. The real controller callbacks after both views accept a drop have automated coverage; native drag-and-drop gestures, real cross-volume / server cases, light mode and extremely long path layouts still need dedicated testing on a real machine.

## Fixes from the PR integration review

Same-volume atomic moves now verify only the root item and do not recursively enumerate descendants that only need a wholesale rename; Move, Merge, Undo and Redo with FIFOs / non-enumerable subdirectories have new regression tests. When Undo / Redo fails, the recovery directory is kept separately and its path is reported, and real controller tests cover the original target being preserved after the undo record is consumed and released. For the combined smoke run and the final commit evidence, see the [PR integration record](pr-integration-2026-09-12.md).

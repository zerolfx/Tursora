# Compression tasks and shared archive cancellation — 2026-09-26

## Scope and behavior

Compress now creates a File Operations task owned by the initiating window. It keeps Cancel available during input preparation, staging and ZIP creation. Pause is not offered. Closing the window or quitting uses the existing task cancellation and completion barrier.

Input staging uses the existing transfer engine: it scans the selected trees, copies file data in cancellable blocks, preserves metadata and symlinks, and validates sources before accepting the copies. The task reports those staged input bytes while the phase says **Preparing files…**. The following **Creating ZIP…** phase resets the byte counter and total, and uses an indeterminate indicator. No output percentage, compressed-byte rate or whole-operation ETA is inferred from staged input bytes: `ditto -c -k` has no verified progress stream here.

The worker writes only into its private, destination-volume `.tursora-archive-*` tree. Cancellation stops staging or terminates its owned tool; a tool still alive after a 0.5-second grace period receives SIGKILL, and the worker reaps it before cleanup. Cleanup relaxes flags and permissions only inside disposable staging, without following links. A final cancellation check precedes exclusive publication. A completed publication is success even if cancellation arrives after that boundary. Only a published ZIP receives a Compress undo registration, using the original window's undo manager even if navigation changed during the task.

The older callback-only compression API uses the same implementation and continues to serve archive fixtures and callers that do not show a task row.

## Shared archive reads

An archive member already being extracted by another request is still written only once. A waiting subscriber checks its own cancellation at bounded 50 ms intervals and again after the wait, without terminating the request that owns the bytes. Workspace materialization also checks before returning results and again before main-queue delivery, so cancelling after worker completion but before delivery does not hand out bytes.

## Automated checks added

`CompressionTaskSmokeTests` covers phase counter reset and task wording; cancellation after staged bytes, before ZIP creation and before publication; an actual child process that ignores TERM; and two subscribers sharing one member, where cancelling the waiting subscriber completes before the owner is released and the owner still receives the complete file from a single extraction.

The browser path runs through List, Icons and Columns with a split pane, another tab, grouping and filtering active. It checks the actual Compress task row, completed publication, the original window's undo/redo, cleanup, and cancellation through the browser task. Headless checks assert the task window stays hidden.

## Verification status

The final frozen source passed the integrated debug build and three consecutive full smoke runs. Each run completed 5,400 assertions, 4,926 result lines and 58 named suites; elapsed times were 250.5, 256.5 and 255.0 seconds. All three exited 0, preserved the recorded source fingerprints and left no new fixture directories. The final release build completed in 140.58 seconds, and `codesign --verify --deep --strict` passed.

Logs and per-run summaries are under `/private/tmp/tursora-seven-20260926-c947/final-acceptance-{1,2,3}.{log,json}`; the source manifest is `final-acceptance-sources.json` in the same directory. Production preferences and the WorkspaceSession, DirectoryViewProperties and TrashOrigins stores retained their pre-verification hashes. These are current local acceptance results, not a published release or a claim that every automated path received a separate mouse-and-keyboard check.

## Packaged-app observations

An owned packaged debug instance used isolated preferences and fixture stores under `/private/tmp/tursora-seven-20260926-c947/ui`. A 33.6 MB fixture, slowed to 80 ms per copy block for observation, completed through Compress. The File Operations screenshot showed one completed item and zero skipped items; the final unknown total remained truthful without an invented completion percentage. The final optimized release (PID 60912) then compressed the 33.6 MB `Recording.dat` fixture with a process-local 500 ms test delay. Window > File Operations showed **Preparing files…**, 10 MB of 33.6 MB (29.6875%), 536 KB/s and about 45 seconds remaining. Cancel was visible and Pause was absent. Clicking Cancel produced **Cancelled**, 12.3 MB of 33.6 MB, zero completed items and zero skipped items; the progress indicator and action buttons were removed. These figures describe measured input preparation, not compressed-output progress.

This directly observes cancellation during input preparation and the terminal task presentation. The successful debug run above observes completed publication. Tool-stage cancellation, forced child termination, publication-boundary races and subscriber independence retain their automated coverage; no separate manual claim is made for each. Screenshots were viewed during the interaction but were not exported as canonical repository screenshots. After cancellation and normal quit, the read-only filesystem check found the source `Recording.dat` still at 33,554,432 bytes, only the pre-existing `Recording.dat.zip` at 33,161 bytes, no second ZIP, and no `.tursora-archive-*` staging residue. The final result file below records these checks separately from the UI observation.


The final release instance quit through Command-Q with exit status 0. The read-only post-run checks in `/private/tmp/tursora-seven-20260926-c947/ui/final-release-results.json` confirmed unchanged production defaults and unchanged hashes/existence for all six checked case-variant workspace, view-property and Trash-origin store paths. The isolated preferences domain had no persisted entry to remove. No further native interaction or screenshot export is included in this pass.

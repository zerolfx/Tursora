# Workspace continuity and refresh — 2026-09-26

## Scope

The owner authorized the seven follow-ups identified in the repository review. This record covers saved selection and scroll position, choosing a recently closed tab, and refreshing directory errors and previews. Companion records cover [everyday commands](everyday-commands-2026-09-26.md), [view options](view-options-2026-09-26.md) and [compression tasks](compression-tasks-2026-09-26.md).

## Implementation

- A pane's optional view snapshot stores its selected logical file URLs and view mode. List stores vertical and optional horizontal offsets, Icons stores its vertical offset, and Columns stores its native horizontal offset plus per-directory vertical offsets. Version 1 sessions without view state continue to decode; an older view snapshot without the List horizontal field restores List to the left edge. Selection is bounded to 1,000 unique local URLs and column offsets to 64 entries. Supplied offsets are finite and clamped to 0–10,000,000 before native content bounds are applied; invalid/nonfinite data is sanitized. ZIP paths refer to the original archive, never private staging files.
- Restoration waits for directory loading or completed search results. Missing rows are ignored; selecting a descendant reopens its list ancestors or column chain. Scroll offsets are clamped by the native controls and applied only in the captured view mode. A newer navigation or search supersedes the pending view snapshot. Filters, navigation history, running terminals, transfer tasks and undo remain outside the saved session.
- File > Recently Closed Tabs shows the existing per-window ten-tab pool, newest first. Each row retains the particular page it names, so a stale menu cannot restore a different page after the pool changes. The existing Reopen Closed Tab shortcut retains its newest-first behavior. This recovery pool remains in memory and is not resurrected on launch.
- Successful filesystem listings clear the old error label and access banner. A sort of an old failed listing cannot masquerade as recovery.
- The docked preview is invalidated after a successful listing or a completed search. It also watches the currently previewed local file's parent for an external save, including while a search result stays selected, without rerunning the entire search. Hiding or closing the pane releases its watcher.

## Product choices and evidence

These restoration and menu behaviors are Tursora choices, not claims to replicate Finder's complete state restoration. Column scrolling uses AppKit's public column geometry and native scroll views, without private view class names. This round does not add a navigation-history store or persist closed tabs across launches.

### Native column-scroll evidence

A small standalone AppKit probe, run under the shared verification lock on 2026-09-26, loaded nine user-resizable columns in a 780-point-wide `NSBrowser`. After scrolling, its outer native `NSScrollView.contentView.bounds.minX` was 190 while `firstVisibleColumn` still reported 0. The public column-index getter therefore did not represent the actual viewport in this configuration. Apple's [NSBrowser documentation](https://developer.apple.com/documentation/appkit/nsbrowser) also defines `scrollColumnToVisible` as ensuring visibility, not restoring an exact origin; asking for an already visible column left the origin unchanged.

The pane snapshot now records the outer horizontal clip's pixel offset and restores it with `constrainBoundsRect`. The outer scroll view is located by the public `NSScrollView` type and `hasHorizontalScroller`, with no private class-name dependency. Finding each column's vertical scroll view descends through that outer scroll view instead of stopping at the first scroll-view ancestor. The native probe establishes the AppKit behavior; the integrated restart regression remains subject to the verification status below.

### List horizontal restoration

The initial continuity implementation saved only List's vertical offset. Inspection found that this could not preserve deliberate horizontal scrolling in a narrow pane. Selection and ancestor expansion run before restoring scroll position, so restoring only vertical position also left any resulting native horizontal movement untouched. This is a definite missing saved axis, not evidence that every restart causes a Name-column jump or that an accessibility click is the only possible trigger.

The additive `listHorizontalScrollOffset` field captures List's native clip origin. After restoring selection and layout, the pane restores vertical position followed by horizontal position using native bounds constraints, only when the saved and current modes agree. Missing horizontal data defaults to zero; other modes do not capture or apply this field.

## Automated verification

`WorkspaceContinuitySmokeTests` adds bounded model round trips, native selection and scrolling through a JSON restart boundary in all three views, identity-safe recent-tab action dispatch, and external Markdown changes through real FSEvents. Existing directory-loading checks now assert error removal after successful Reload. Additional search-race checks cover replacement of a pending restored search.

The column regression also opens an eight-directory chain with two selected leaf files, captures a native 333-point horizontal origin, checks small movements in both directions, and restores the selection and partial-column offset through JSON into fresh views. Oversized offsets and a missing saved descendant retain separate checks; the original per-column vertical-scroll assertion remains in place.

The List regression uses a real 1100 × 700 split window with grouped overflowing columns. It restores two exact selected file paths, a 480-point vertical offset, and horizontal offsets of 70 and zero through JSON into fresh windows and view-property stores. The zero case also checks that Name remains visible. A separate missing-field case exercises an older view snapshot; pure checks cover absent, negative, excessive and nonfinite horizontal data. These assertions passed in all three final full smoke runs. The final packaged restart observation is recorded below.

The final frozen source passed the integrated debug build and three consecutive full smoke runs. Each run completed 5,400 assertions, 4,926 result lines and 58 named suites; elapsed times were 250.5, 256.5 and 255.0 seconds. All three exited 0, preserved the recorded source fingerprints and left no new fixture directories. The final release build completed in 140.58 seconds, and `codesign --verify --deep --strict` passed.

Logs and per-run summaries are under `/private/tmp/tursora-seven-20260926-c947/final-acceptance-{1,2,3}.{log,json}`; the source manifest is `final-acceptance-sources.json` in the same directory. Production preferences and the WorkspaceSession, DirectoryViewProperties and TrashOrigins stores retained their pre-verification hashes. These are current local acceptance results, not a published release or a claim that every automated path received a separate mouse-and-keyboard check.

## Packaged-app observation

The packaged debug instance used isolated preferences and stores under `/private/tmp/tursora-seven-20260926-c947/ui`, under the shared verification lock. The File > Recently Closed Tabs submenu listed `Field Notes`; clicking its real menu item reopened the retained right-hand page, which was then closed again.

The owned debug process (PID 55578) quit normally with exit status 0 while `Note 45.txt` was selected and List had a nonzero vertical scroll position. The captured snapshot is `ui/pre-quit-session.json`.

The final optimized release (PID 60912, built in 140.58 seconds) then launched against that same isolated store. A viewed screenshot and native accessibility state showed `Note 45.txt` still selected, the vertical scrollbar value restored to exactly `0.8137044967880086` (saved vertical offset 1140 points), and horizontal position zero with Name visible. Command-J opened View Options; changing Show icon preview from off to on and closing the panel preserved that exact selection, horizontal zero and the same vertical scrollbar value.

This directly observes a normal quit/relaunch and a subsequent presentation change in a narrow split List. Nonzero List horizontal restoration, Icons and Columns retain their separate automated coverage above; the packaged observation does not claim that every mode and axis was manually replayed. The companion [View Options](view-options-2026-09-26.md) and [compression](compression-tasks-2026-09-26.md) records describe the remaining release interaction scope. Native width dragging was not tested, and canonical screenshots were not exported in this pass.


The final release instance quit through Command-Q with exit status 0. The read-only post-run checks in `/private/tmp/tursora-seven-20260926-c947/ui/final-release-results.json` confirmed unchanged production defaults and unchanged hashes/existence for all six checked case-variant workspace, view-property and Trash-origin store paths. The isolated preferences domain had no persisted entry to remove. No further native interaction or screenshot export is included in this pass.

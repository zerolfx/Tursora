# View Options and remembered column widths — 2026-09-26

## Implemented scope

View > Show View Options (Command-J) opens a modeless panel owned by the browser window. The panel follows the active tab and split pane and closes with its owner. It gathers the existing mode, sort key and direction, grouping, icon size, hidden-file, icon-preview, recursive folder-size and optional list-column controls. List-column checkboxes are enabled only in List mode. Calculate all sizes retains the existing ordinary-folder restriction. Search and archive view edits remain transient; Use Current Settings as Default and Restore Folder Defaults are unavailable there.

The panel also exposes the existing per-folder/shared policy, saving the current settings as the default, restoring the current folder's defaults, and resetting column widths for the current mode. The policy selector changes the application-wide policy explicitly; it does not promote a virtual page into the defaults. No recursive apply, free icon positioning, Finder-style text-size controls, or tags are added.

`DirectoryViewProperties` adds list widths keyed by column identifier and column-view widths indexed by depth from the current root. Both follow the existing per-directory/default/shared-policy rules. Hidden list columns retain their widths. The depth convention matches NSBrowser's native column-configuration convention, rather than claiming that each opened descendant has independent sizing settings. Widths are additive keys in the current version-1 record: old records default to the existing sizes. Known list columns clamp to 60–1600 points (Name: 180–1600); column-view widths clamp to 100–1200 and 64 depth entries. Nonfinite values never reach AppKit or JSON encoding; unknown list identifiers are dropped.

List persistence records only differences across the native header's mouse tracking, avoiding the automatic table resize notifications produced by ordinary window layout. Once Name has an explicit user width, its size remains fixed and horizontal scrolling serves a narrow pane; a folder without an explicit Name width keeps the existing fill-width behavior. Restoring widths and ordinary layout never writes a folder override. NSBrowser's user-sizing delegate marks a user resize, and its final configuration notification captures widths. Programmatic restores clear that mark, including the delayed notifications AppKit posts after `setWidth`.

## Local evidence and design choices

The following commands read Finder's own installed resources on this machine:

```sh
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib | rg -x 'Show View Options|Hide View Options|View Options'
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/ViewOptionsWindow.nib | rg -x '(Sort By:|Group By:|Show Columns:|Calculate all sizes|Show icon preview|Use as Defaults|View Options|Text size:|Icon size:)'
```

Observed labels include `Show View Options`, `Group By:`, `Sort By:`, `Icon size:`, `Show Columns:`, `Calculate all sizes`, `Show icon preview`, and `Use as Defaults`. The panel reuses the applicable labels; its layout, ownership, policy wording and width-reset control are Tursora choices, not claims of Finder parity. The optional column labels and their order retain the evidence in [sort-columns-folder-sizes.md](sort-columns-folder-sizes.md).

The local SDK at `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSBrowser.h` documents that configuration is stored by depth (lines 221–223), `setWidth` posts a delayed change notification (lines 202–204), `shouldSizeColumn` distinguishes user resizing from initial sizing (lines 357–360), and `browserColumnConfigurationDidChange` fires once after a user resize ends (lines 367–370). The implementation uses these explicit hooks rather than saving every width observed during layout.

## Verification status

`ViewOptionsSmokeTests` adds model checks for old records, finite/range/depth validation, hidden-column sizes and storage reconstruction. UI checks use an isolated store and actual panes: native header callback routing, NSBrowser delegate routing, navigation and width restoration, panel actions, filters and grouping, mode-specific enablement, split/tab targeting, shared-policy synchronization, transient search guards, reset/default actions, panel layout and owner closure. A callback-level test does not by itself verify a real mouse drag; packaged-app evidence must state whether it included one.

The final frozen source passed the integrated debug build and three consecutive full smoke runs. Each run completed 5,400 assertions, 4,926 result lines and 58 named suites; elapsed times were 250.5, 256.5 and 255.0 seconds. All three exited 0, preserved the recorded source fingerprints and left no new fixture directories. The final release build completed in 140.58 seconds, and `codesign --verify --deep --strict` passed.

Logs and per-run summaries are under `/private/tmp/tursora-seven-20260926-c947/final-acceptance-{1,2,3}.{log,json}`; the source manifest is `final-acceptance-sources.json` in the same directory. Production preferences and the WorkspaceSession, DirectoryViewProperties and TrashOrigins stores retained their pre-verification hashes. These are current local acceptance results, not a published release or a claim that every automated path received a separate mouse-and-keyboard check.

The packaged debug and final release observations, and their limits, are recorded below.

## Selection regression found during integration

The first integrated trials found that changing zoom in a grouped list cleared the selected file: the common zoom setter called the file view's reload path without restoring selection. The shared zoom and icon-preview setters now capture exact URLs and scroll positions around that update; the direct Calculate all sizes reload preserves the same state. The panel test now checks selection after each action, including icon-view zoom and preview changes. The per-action regression assertions passed in all three final full smoke runs.

The harness fixes were separate from that product defect. Folder readiness originally checked fields assigned before asynchronous listing completion; it now requires the expected fixture item's full URL. The test also shows and lays out its browser window and waits for NSBrowser's actual loaded cell before selecting. Per-action assertions compare standardized full URLs, matching the application's existing identity rule, rather than Foundation URL construction representations. The final assertions still require the exact file and preserved filter; no name-only or optional-selection fallback was introduced.

The View Options suite passed in the integrated diagnostic trial `trial-f-1.log` under `/private/tmp/tursora-seven-20260926-c947/`. That is a local suite result after the fixes, not a completed full-suite acceptance run or the required three consecutive rounds. Packaged-app verification remains separate.

## Narrow-list horizontal position during presentation changes

Packaged-app inspection reported that changing list zoom could leave the Name column offscreen in a narrow split while keeping the selected file. Source inspection found the native row-reselection path can scroll horizontally, while the selection-preservation setters restored only the vertical offset. The list now exposes a constrained horizontal-offset accessor; zoom, icon-preview and recursive-size changes restore both axes after reselection. Regression checks drive actual panel actions in a narrow grouped and filtered split, at x=0 and an intentional x=70, and require both exact selection and the previous horizontal position; x=0 additionally requires at least 160 points of the Name column to remain visible. These additions passed all three final full smoke runs. The corrected final package was also observed preserving selection and both axes during an icon-preview change at horizontal zero, as recorded below. Intentional nonzero horizontal position and the other presentation controls have the separate automated coverage above; the earlier trial-f result alone did not verify them.

## Packaged debug observation checkpoint

The owned packaged debug instance used fixtures and separate preferences/view/session stores under `/private/tmp/tursora-seven-20260926-c947/ui`, with the shared verification lock held. This was a packaged debug observation, not an optimized release-build result.

- Command-J opened the full View Options panel. The captured panel showed all controls and footer actions without clipping. Changing List icon size from 16 to 22 points took effect while the exact selected `Note 01.txt` remained selected.
- The horizontal-position correction above was compiled after this initial observation. Its final-release recheck is recorded below. Neither this initial observation nor callback-level smoke coverage establishes that real list-header or column-divider dragging has been exercised.
- In the companion file-command check, New Folder followed by Escape created a folder; Command-Z removed it and changed the listing count from 66 to 65, and Command-Shift-Z restored it and the count of 66. The Recently Closed Tabs submenu listed `Field Notes`; clicking its real menu item reopened that retained page, which was then closed again.
- A 33.6 MB compression fixture, slowed to 80 ms per copy block for observation, completed. The File Operations screenshot showed one completed item and zero skipped items, with the unknown final total represented without an invented completion percentage. Manual Cancel was subsequently observed in the final release, as recorded below.
- The owned process (PID 55578) quit with exit status 0 while `Note 45.txt` was selected and the list had a nonzero scroll position. The saved snapshot is `pre-quit-session.json` in the fixture directory. The later final-release restart observation is recorded below.

This checkpoint records the debug-package interaction scope only. The final frozen source and optimized package have the subsequent evidence below.

## Final release observations

The final optimized release (PID 60912, built in 140.58 seconds) launched against the same isolated store after the earlier normal quit. The viewed window restored exact selection of `Note 45.txt`, vertical scrollbar value `0.8137044967880086` (saved vertical offset 1140 points), and horizontal zero with Name visible. Command-J reopened View Options. Toggling Show icon preview from off to on and closing the panel preserved the same file, horizontal zero and that exact vertical scrollbar value.

Window > File Operations also showed a 33.6 MB `Recording.dat` compression in **Preparing files…**, with measured progress and Cancel but no Pause. Clicking Cancel produced the terminal cancelled row and removed its progress indicator and buttons; the [compression record](compression-tasks-2026-09-26.md) records the displayed values and limits.

The final release observation verifies the corrected preview-setting path at horizontal zero and launch restoration of the selected scrolled List. Automated checks separately cover intentional nonzero horizontal positions, zoom and Calculate all sizes, width callbacks and storage reconstruction. Real list-header or column-divider mouse dragging was not tested. Screenshots were viewed for layout and state, but no canonical repository screenshots were exported in this pass.


The final release instance quit through Command-Q with exit status 0. The read-only post-run checks in `/private/tmp/tursora-seven-20260926-c947/ui/final-release-results.json` confirmed unchanged production defaults and unchanged hashes/existence for all six checked case-variant workspace, view-property and Trash-origin store paths. The isolated preferences domain had no persisted entry to remove. No further native interaction or screenshot export is included in this pass.

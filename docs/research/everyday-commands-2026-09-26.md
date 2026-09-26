# Everyday commands and batch-rename guards, 2026-09-26

## Scope

This change adds New Folder undo/redo, New Folder with Selection, Move Items Here,
Deselect All, Invert Selection and Show Package Contents. It also prevents batch
rename previews from overflowing and rejects a batch containing an ancestor and
its descendant before any filesystem staging.

## Finder and Dolphin evidence

The following was read from this machine's Finder resources on 2026-09-26:

```sh
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
```

`MenuBar.nib` contains `Move Items Here`, `Deselect All`, `Show Package Contents`
and `New Folder with Selection`, including the selectors `cmdDeselectAll:` and
`cmdShowPackageContents:`. The merged strings contain:

| Key | Value |
| --- | --- |
| `N158` | `Show Package Contents` |
| `FR1`, `GF3` | `New Folder with Selection` |
| `NF1` | `Redo New Folder` |
| `NF2` | `Undo New Folder` |

The existing [new-folder record](finder-new-folder-rename.md) records the related
inline-rename evidence. These resource labels establish wording and the presence
of the commands, not the complete implementation of Finder's undo behavior.
Tursora's compound undo safety policy below is its own design.

The existing Dolphin checkout at
`/Users/zerol/Workspace/Tursora/upstream/dolphin`, commit
`5e457ee9e88aa6277fbf056cd5c32462c5318866`, registers `invert_selection` in
`src/dolphinmainwindow.cpp:2013`: `Invert Selection` selects the items that were
not selected. Tursora applies that complement to displayed file rows, excluding
group headings and filtered-out entries. The command is initially unbound rather
than adopting Dolphin's Linux shortcut.

## Behavior and boundaries

- New Folder registers its own undo operation, moving the created directory to
  Trash and restoring it for redo. Inline rename remains a separate subsequent
  operation, so undoing a name change first restores the original folder path.
- New Folder with Selection (`Control-Command-N`) creates a folder in the active
  ordinary directory, then moves the captured selection through the transfer
  task engine. The new folder and successful moves form one undo transaction.
  Undo restores the source items and moves the now-empty folder into private
  undo storage; redo restores the folder before moving the items back. Identity
  checks and exclusive renames still apply. If another item has appeared in the
  folder, undo refuses and rolls back earlier steps instead of removing it.
  Partial transfers retain undo for successful moves and the created folder.
  The originating pane and window own completion and undo if tabs or panes change.
  The active name filter is cleared so the new folder can be selected and renamed.
- Move Items Here (`Option-Command-V`) is Paste's alternate and moves copied file
  URLs without a preceding Cut. It uses ordinary transfer conflict handling,
  progress and undo. It refuses archive-owned sources and cannot write to a ZIP,
  search destination or Trash. Clipboard clearing is conditional on its generation
  still matching the command's captured clipboard.
- Deselect All (`Option-Command-A`) and Invert Selection operate only when a file
  view has focus. The list uses all displayed file rows (including expanded
  descendants); Icons uses its displayed entries; Columns uses the selected
  column. Explicit deselection in Columns clears folder selections too, closing
  their dependent columns. Navigation's existing selection-restoration behavior
  is unchanged.
- Show Package Contents is available for one ordinary local package directory,
  from File and its context menu. It navigates within the originating pane rather
  than launching the package. Archive entries and Trash do not offer this action.
- The new menu commands enter the existing searchable shortcut catalog. Paste /
  Move Items Here and Select All / Deselect All remain alternate pairs only while
  their user-configured bindings are compatible.
- Batch numbering checks the full sequence with overflow-reporting arithmetic
  before constructing its preview. An invalid sequence shows unchanged names,
  explains the error and disables Rename. Text outside the representable integer
  range also disables Rename rather than silently using one. A parent and child
  selected together are rejected by both the sheet and `FileOperations.renameBatch`;
  the implementation does not attempt to remap descendant paths during staging.
  The two new validation messages are Tursora wording, not extracted Finder text.

## Automated and computer-use verification

`EverydayCommandsSmokeTests` checks the menu bindings, real compound journal
undo/redo and rollback when a foreign file prevents folder removal, then drives
all three native views with filtering, grouping, a split pane and another tab.
It covers focus validation, selection complement, New Folder undo/redo,
New Folder with Selection undo/redo, moving copied URLs and package navigation.
Trash operations use an injected fixture Trash, not the user's Trash.

`BatchRenameSmokeTests` adds numbering-boundary checks, overlap rejection and
unchanged source bytes after rejection, a disabled overlap sheet, and live
overflow validation in Details, Icons and Columns.

The final frozen source passed the integrated debug build and three consecutive full smoke runs. Each run completed 5,400 assertions, 4,926 result lines and 58 named suites; elapsed times were 250.5, 256.5 and 255.0 seconds. All three exited 0, preserved the recorded source fingerprints and left no new fixture directories. The final release build completed in 140.58 seconds, and `codesign --verify --deep --strict` passed.

Logs and per-run summaries are under `/private/tmp/tursora-seven-20260926-c947/final-acceptance-{1,2,3}.{log,json}`; the source manifest is `final-acceptance-sources.json` in the same directory. Production preferences and the WorkspaceSession, DirectoryViewProperties and TrashOrigins stores retained their pre-verification hashes. These are current local acceptance results, not a published release or a claim that every automated path received a separate mouse-and-keyboard check.

### Packaged-app observations

An owned packaged debug instance used isolated preferences and fixture stores under `/private/tmp/tursora-seven-20260926-c947/ui`. New Folder followed by Escape created a folder; Command-Z removed the row and changed the listing count from 66 to 65, and Command-Shift-Z restored it and the count of 66. This is direct observation of New Folder undo/redo. The remaining new command paths have the automated coverage above; this observation does not claim separate manual coverage of each one.


The final optimized release also completed the scoped restart/View Options and compression Cancel interactions recorded in [workspace continuity](workspace-continuity-2026-09-26.md), [View Options](view-options-2026-09-26.md) and [compression](compression-tasks-2026-09-26.md). Those observations do not expand the manual file-command coverage beyond New Folder undo/redo above. Native width dragging was not tested, and viewed screenshots were not exported as canonical repository assets.


The final release instance quit through Command-Q with exit status 0. The read-only post-run checks in `/private/tmp/tursora-seven-20260926-c947/ui/final-release-results.json` confirmed unchanged production defaults and unchanged hashes/existence for all six checked case-variant workspace, view-property and Trash-origin store paths. The isolated preferences domain had no persisted entry to remove. No further native interaction or screenshot export is included in this pass.

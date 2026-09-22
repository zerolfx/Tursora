# Finder opens the new folder's name for editing (extracted from Finder's own binary)

Why this record exists: Tursora's New Folder created the folder and selected it, and the claim that
Finder goes one step further and opens the name for editing had never been sourced from Finder itself.
AGENTS.md rule 4 needs Finder's own resources, so the behaviour is derived here from Finder's symbol
table and its localized strings, not from memory of using Finder.

Read on macOS 26 (`Darwin 25.3.0`), 2026-09-22.

## The selector that carries the flag

```bash
strings -a /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder \
  | grep -o 'setPendingNodesToSelect[A-Za-z:]*' | sort -u
```

```
setPendingNodesToSelect:startEditing:runNewFolderAnimation:renameOp:
```

One selector, and it is the decisive one. Finder's "select this once the listing arrives" machinery —
the same idea as Tursora's `pendingSelection` — takes a `startEditing:` flag, and that flag travels
bolted to `runNewFolderAnimation:`. The two parameters belong to the same call because the new-folder
path is the caller that sets them.

## Where the edit is actually started, per view family

```bash
strings -a /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder \
  | grep -oE '^[a-zA-Z]*startEditing[A-Za-z:]*' | sort -u
```

```
startEditing
startEditing:
startEditingInPreviewPaneWithNode:renameOp:
startEditingNodeInSidebar:
startEditingNodeInTagsColumn:
startEditingNodeNowOrLater:runNewFolderAnimation:renameOp:
startEditingRow:
startEditingSelectedRow
startEditingViaDelayTimer
startEditingWithNode:
startEditingWithNode:afterDelay:
startEditingWithNode:renameOp:
startEditingWithNode:runNewFolderAnimation:renameOp:
startEditingWithNode:runNewFolderAnimation:renameOp:afterDelay:
startEditingWithRenameOp:
```

Class-qualified forms appear in the C++ lambda names that the same binary carries:

```bash
strings -a /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder \
  | grep -E 'startEditing|runNewFolderAnimation' | sort -u
```

```
-[TBaseBrowserViewController selectNodesForTask:startEditing:]
-[TColumnViewController startEditingWithNode:renameOp:]
-[TDesktopView startEditingWithNode:runNewFolderAnimation:renameOp:afterDelay:]
-[TIconOrGalleryCollectionView startEditingWithNode:runNewFolderAnimation:renameOp:afterDelay:]
-[TDesktopMultiViewController desktopViewController:snapNodeToGridNowOrLater:startEditing:runNewFolderAnimation:renameOp:]
```

Three things follow, and all three shaped the implementation:

1. **The edit is per view, not central.** There is a distinct entry point for the icon/gallery
   collection view, the column view controller and the desktop view. Tursora matches this: the
   pending edit is scheduled by `BrowserViewController`, but `beginRename(item:)` is each view's own.
2. **The edit is deferred on purpose.** `selectNodesNowOrLaterDetails:…`,
   `startEditingNodeNowOrLater:…` and an explicit `afterDelay:` parameter all say that Finder does not
   try to edit the row at the moment the folder is created. Neither can Tursora: creating a folder
   provokes three listings inside about half a second (the explicit reload, the `DirectoryChanges`
   broadcast returning to the same pane, and the pane's own FSEvents watcher).
3. **The new-folder path is a named operation.** `TNewFolderOperation`, `TNewFolderOperationDelegate`
   and `TBBVCNewFolderDelegate` exist as their own classes alongside the flag above.

## Names

```bash
plutil -convert json -o - \
  /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
```

| Key | Value |
|---|---|
| `N2`, `FI13` | `untitled folder` |
| `TL19`, `N156` | `New Folder` |
| `NF2` | `Undo New Folder` |
| `NF1` | `Redo New Folder` |

`untitled folder` confirms the default name Tursora already used. `NF1` / `NF2` show Finder registers
the creation with its undo manager; Tursora's `newFolder()` registers none. That is a real gap, it is
independent of this change, and per AGENTS.md rule 9 it is recorded in `docs/ROADMAP.md` rather than
built here.

## What is certain, and what is inferred

**Certain**, because the symbol table says so: a `startEditing:` BOOL travels with
`runNewFolderAnimation:` through the pending-selection call; each view family has its own
`startEditing…` entry point; the selection/edit is deferred rather than immediate; the default name is
`untitled folder`; Finder registers Undo / Redo New Folder.

**Inferred**, and marked as such:

- That the new-folder path passes `YES` for `startEditing:`. The symbol table shows the parameter
  exists and shows which call carries it; it cannot show the argument's value.
- The length of `afterDelay:`. Tursora uses 0.3 s, pushed back by each arriving listing and capped at
  five attempts; that number is ours, not Finder's.
- That Finder's list view also starts the edit. Only methods containing C++ lambdas produce mangled,
  class-qualified names in this binary, so the absence of a list-view symbol is an artefact of how the
  names were emitted rather than evidence that the list view behaves differently.

No computer-use observation of Finder was made for this record. Watching Finder create a folder in all
three views would upgrade the two inferences above to observed behaviour; until that is done and
recorded here, they stay marked inferred.

## Where Tursora deliberately differs

Dolphin is not a model here. It asks for the name in a dialog before the folder exists, so there is no
"created, now type over it" state at all. A line-exact citation is not given because `upstream/dolphin`
is not checked out in this worktree; re-clone it before any claim about Dolphin's `KNewFileMenu` goes
into `docs/DECISIONS.md`.

Tursora also differs from Finder in one place Finder has no answer for: a pane can have a name filter
active, and Finder has no filter bar. A new folder that the filter excludes would be created and then
be invisible, with nothing to type into. Tursora clears the filter instead, which is the only outcome
where the name the user is about to type is on screen. See the decision row in `docs/DECISIONS.md`.

## Automated verification

`app/Sources/Tursora/SmokeTest.swift` § "new folder rename" covers, for the list, icon and column
views: the pending edit is armed, the editor opens, it holds `untitled folder` with all 15 characters
preselected, the editing field belongs to the file view, abandoning the edit keeps the default name,
and a typed name is committed to disk. Beyond the three views it covers grouping active (list and
icons), two panes on one folder, an active name filter, and the regression the feature depends on — a
listing arriving under an open editor commits no half-typed name and re-opens the edit afterwards with
what was typed still in it. The refusal sites
(`SearchSmokeTests`, `ArchiveBrowserSmokeTests`, `TrashSmokeTests`) additionally assert that a refused
New Folder arms no edit.

Aborting the edit on every reload was implemented first and then replaced. It does prevent a half-typed
commit, but it also discards what the user has typed whenever an unrelated listing lands, and it made
the existing click-to-rename check (`SmokeTest` § "expand in place") fail one run in three. Capturing
and re-opening the edit passes three consecutive runs and loses nothing the user typed. The restore has
to be deferred to the next run-loop pass: doing it inline puts the editor back before the pane's own
`select(urls:)` runs, and moving the selection out from under an open editor ends and commits it.

No computer-use pass on the packaged app has been made for this change.

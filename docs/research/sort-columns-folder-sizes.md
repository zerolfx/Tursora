# Sort keys, optional columns and folder sizes — Finder evidence, implementation limits and verification

Covers three things: the three new date keys in `DirectoryModel.SortKey`, the optional columns of the detail view (header
context menu + per-directory persistence), and the new `Model/FolderSizes.swift` (folder item count / recursive byte total).

Related documents: [SPEC.md §5](../SPEC.md), [DECISIONS.md](../DECISIONS.md) D67–D69,
[research/finder-group-labels.md](finder-group-labels.md) (evidence for the group labels from the same source),
[research/directory-view-properties.md](directory-view-properties.md) (per-directory view memory).

## 1. Finder evidence

All of it comes from the Finder's own resources on this machine's macOS 26.5; the commands and raw output follow.

### 1.1 Sort key labels — `ArrangeByMenu.nib`

```
$ strings -a /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/ArrangeByMenu.nib \
  | grep -iE "^Date|^Name$|^Kind$|^Size$|^None$" | sort -u
Date Added
Date Created
Date Last Opened
Date Modified
Kind
Name
None
Size
```

Selectors in the same nib prove that these labels serve both Sort By and Arrange By:

```
$ strings -a .../ArrangeByMenu.nib | grep -iE "cmdSortBy" | sort -u
cmdSortByDateAdded:      cmdSortByDateCreated:   cmdSortByDateLastOpened:
cmdSortByDateModified:   cmdSortByKind:          cmdSortByLabel:
cmdSortByLastModifiedBy: cmdSortByName:          cmdSortByNone:
cmdSortBySharedBy:       cmdSortBySize:          cmdSortBySnapToGrid:
```

Tursora adopts seven of them — **Name / Date Modified / Date Created / Date Last Opened / Date Added / Size / Kind** — in
the column order of `ViewOptionsWindow.nib` (see 1.2). The ones left out, `Label`, `Shared By`, `Last Modified By` and
`Snap to Grid`, belong to capabilities we have not implemented yet (tags, sharing) and are out of scope here.

### 1.2 Column titles and order, "Calculate all sizes" — `ViewOptionsWindow.nib`

In order of appearance inside the file (unsorted), which is the real arrangement of Finder's "Show Columns:" checkboxes:

```
$ strings -a .../Base.lproj/ViewOptionsWindow.nib | grep -nE "^(Show Columns:|Date Modified|Date Created|Date Last Opened|Date Added|Size|Kind|Version|Comments|Tags|Calculate all sizes)$"
499:Show Columns:
515:Date Modified
519:Date Created
523:Date Last Opened
527:Date Added
531:Size
535:Kind
539:Version
543:Comments
547:Tags
556:Calculate all sizes
```

The binding key names in the same nib confirm that these are list view settings and that "Calculate all sizes" is a
separate switch:

```
value: viewOptionsSettingsController.targetedViewOptionsSettings.listViewCalculateAllSizes
value: viewOptionsSettingsController.targetedViewOptionsSettings.listViewShowKind
value: viewOptionsSettingsController.targetedViewOptionsSettings.listViewShowSize
value: viewOptionsSettingsController.targetedViewOptionsSettings.listViewShowComments
value: viewOptionsSettingsController.targetedViewOptionsSettings.listViewShowVersion
```

Tursora implements the six of Finder's nine columns for which we already have the data (Date Modified / Date Created /
Date Last Opened / Date Added / Size / Kind). **Version, Comments and Tags are not implemented** (no version number, no
writing of Finder comments, no tag system); they are recorded in the gap lists.

### 1.3 The "N items" wording — `en.lproj/LocalizableMerged.strings`

```
$ plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
'I_ITEMS_V1' = '^0 items'
'I_ITEMS_V2' = '^0 item'
'I_ITEMS_V3' = '^0 items'
```

That is, "1 item" in the singular and "N items" otherwise. `FolderSizes.itemCountText` follows this and matches the
existing status bar wording (`StatusBarView`: "1 item" / "N items").

### 1.4 "Keep folders on top" — `PreferencesWindow.nib`

Added 2026-09-14, when a user reported that Date Modified stranded folders in a block at the top. Finder's General
preferences pane carries one label and two checkboxes:

```
$ strings -a /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/PreferencesWindow.nib \
  | grep -iE "folders on top|in windows when sorting|^On Desktop$" | sort -u
In windows when sorting by name
On Desktop
Keep folders on top:
```

The outlets in the same nib confirm which control is which: `_sortFoldersFirstBtn` / `sortFoldersFirst:` and
`_sortFoldersFirstOnDesktopBtn` / `sortFoldersFirstOnDesktop:`. The window option is therefore scoped to name sorting
by its own wording — Finder offers no way to keep folders on top under Date Modified, Size or Kind. The preference is
also absent from this machine's domain, so the shipped default is off:

```
$ defaults read com.apple.finder _FXSortFoldersFirst
The domain/default pair of (com.apple.finder, _FXSortFoldersFirst) does not exist
```

This supersedes the "folders always first" reading recorded when the sort keys were built; see D76. Tursora keeps
folders leading under Name (the case Finder's option describes) and lets them sort with files under every other key.
Making the Name case switchable, as Finder's checkbox does, is still open.

## 2. Parts that are still inferred / deliberately different from Finder

| Item | What Finder does | Tursora | Rationale |
|---|---|---|---|
| The Size column for folders when "Calculate all sizes" is off | shows `--` | shows "N items" | Explicitly required by this task; `--` carries no information at all, while the item count is real data that one directory read already gives us. The wording still comes from Finder's `I_ITEMS_*`. **This is a deliberate difference from Finder.** |
| Whether "N items" counts hidden items | no evidence | **it does not** (`.skipsHiddenFiles`)| Consistent with the "visible items" intuition of Finder's Get Info window; inferred. |
| Whether the recursive byte total counts hidden files | no evidence | **it does** | The size has to be real; using a different basis from the item count is deliberate: the count describes "how much you can see", the size describes "how much disk it takes". Inferred. |
| Whether the recursive byte total counts symlinks themselves | no evidence | **it does not** | A link's bytes belong to the folder the target lives in; this avoids double counting. Darwin's own URL enumerator does not follow symlinks either (see the search section of DEVELOPMENT.md). Inferred. |
| What value folders use when sorting by Size | no evidence | calculation on and known → the byte total; otherwise → the item count; neither known → treated as the smallest | Lets sorting act on "whatever has already been computed" and re-sorts once results arrive. Inferred. |
| Where items with "no date" land under the three new date keys | no evidence | last in both ascending and descending order | A direction-independent rule: flipping the order should not push "no date" to the top. **`dateModified` keeps its existing `.distantPast` semantics unchanged**, so that existing behaviour is not disturbed. |
| Whether column widths persist | Finder remembers them | **we do not** | Out of scope here; the default width is used every time. |
| The exact contents of the header context menu | no evidence (Finder does have that menu) | six optional columns + a separator + "Calculate all sizes" | That the menu exists and has these two kinds of entry is inferred; the text of each entry itself has evidence (1.2). |

## 3. Implementation

### 3.1 Sort keys

`DirectoryModel.SortKey` gains `dateCreated / dateAdded / dateLastOpened`, with rawValues identical to the same-named
`GroupKey` keys. The comparator gains the pure function `DirectoryModel.compareDates(_:_:nameAscending:ascending:)`:
equal dates fall back to the name (name order flips with the direction, as with the existing keys), and `nil` sinks to
the bottom in both directions. Folders still come first unconditionally.

Three menus stay in sync: View ▸ Sort By in `MainMenu.swift`, the context-menu Sort By from
`BrowserViewController.sortMenuItem()`, and header clicks through `FileListViewController.Column.sortKey`
(`sortDescriptorPrototype` ↔ `SortKey`). The `sortKey` of `DirectoryViewProperties` still decodes leniently by rawValue,
the four keys written by older files load as before, and an unknown key falls back to `.name`.

The icon view has no columns and simply follows the model's sort key.

### 3.2 Optional columns

`FileListViewController.Column` grows to `name, dateModified, dateCreated, dateLastOpened, dateAdded, size, kind,
location` (the order is Finder's from 1.2; `location` is still search-only and stays last).
The three new columns are hidden by default, can be ticked in the header context menu, and can be clicked to sort.

`UI/FileListColumns.swift` holds: `ListColumnHeaderMenu` (an `NSMenuDelegate`, rebuilt on each open to refresh the
checkmarks), the show/hide and persistence extensions of `FileListViewController`, and
`BrowserViewController.canCalculateFolderSizes` together with the window commands.
When the `menu` that `NSTableHeaderView` provides is empty, a right-click falls through to the file context menu, so it
is assigned explicitly.

`DirectoryViewProperties` gains `listColumns: [String]` (default `["dateModified", "kind", "size"]`) and
`calculateAllSizes: Bool` (default `false`); both take part in `normalized` (deduplicate + sort, so the same set of
columns is equal regardless of order), in `Use Current Settings as Default` and in `Restore This Folder to Default`.
Decoding is lenient: a missing key → the default value; unknown column identifiers are kept in the model layer and
filtered by the view, so columns we already have are never hidden because a newer version wrote a column. Column widths
do not persist.

### 3.3 Folder sizes

`Model/FolderSizes.swift`, one instance per `DirectoryModel`:

- **All state lives on the main thread**; only the two filesystem traversals run on a serial background queue, and
  results come back to the main thread carrying a generation and a cancellation token.
- **Item count**: a single `contentsOfDirectory(options: .skipsHiddenFiles)`.
- **Recursive byte total**: only while "Calculate all sizes" is on; `FileManager.enumerator`, an `errorHandler` that
  always continues, symlinks skipped, cancellation checked every 256 items, and above `entryLimit` (500,000 items) it
  gives up and keeps only the item count.
- **Cache key = (standardised path, modification time)**: when the folder's own listing changes the key changes
  automatically and it is recomputed; a change deep in the subtree does not alter an ancestor's mtime, so
  `DirectoryChanges` is also observed, and the changed directory plus all of its already-measured ancestors are dropped
  from the cache and requested again.
- **Cancellation**: `cancel()` cancels the current token and increments the generation; `DirectoryModel.load` (switching
  directory) and `beginSearchResults` call it. Late results whose generation does not match are discarded outright and
  never land in the new directory.
- **ZIP / search results only count items**: `allowsRecursiveSizes` (set by `restoreViewProperties` according to
  `isBrowsingArchive`), `request(allowsRecursiveSizes:)` (passed in by `DirectoryModel` according to `isSearchResults`),
  and the per-item `isArchiveEntry` — all three block the recursive traversal, while the item count works as usual.

The Size column text goes through `FolderSizes.displaySize(for:)`; Size sorting goes through `sortValue(for:)`, and when
a new value arrives `DirectoryModel.folderMetricsDidChange` re-sorts if the sort key is `.size` and otherwise only
redraws.

## 4. Verification

- `cd app && swift build`: clean, no new warnings.
- `SortColumnSizesSmokeTests` (`checkPrefix` = `sort/columns/sizes: `) is registered in the `steps` of `SmokeTest.run`,
  with its fixture in `$TMPDIR/tursora-sort-columns-sizes-<UUID>`, touching no user files or preferences. Coverage:
  - The pure comparator: equality, `nil`, direction, name fallback and strictness for all three date keys.
  - Wording: `0 items` / `1 item` / `7 items`, and byte formatting identical to that of files.
  - Menus: the seven entries of View ▸ Sort By and their rawValues, "Calculate all sizes" in Folder View Settings, and
    the Finder order of the optional columns.
  - Persistence: the column set and `calculateAllSizes` round-tripping through `DirectoryViewPropertiesStore`; older
    documents (without the new keys) falling back to the defaults; an unknown sort key falling back to Name; duplicate
    columns deduplicated.
  - The calculator: item counts (dotfiles skipped, symlinks included), recursive bytes (symlinks skipped, hidden bytes
    included, subdirectories descended into), ZIP / search counting items only, no delivery and no re-sort after
    cancellation, and `reset()`.
  - A real list: the header menu entries and their checkmarks, ticking/unticking columns, per-directory memory and
    "restore defaults", the "N items" text in the Size column, the byte total appearing asynchronously after turning
    calculation on and the re-sort of Size sorting, no rows of the old directory left behind after navigating away, and
    independent column sets in split panes.
  - Both views: detail and icon both sort by the three new keys (ascending/descending). Folders led every key at the
    time; since D76 they lead under Name only, and a folder dated between two files is asserted to land between them.
- Computer-use check: **not done**. The appearance of the header context menu in the packaged app, the menu checkmarks
  and the actual column widths have not been looked at by a human yet.

## 5. Known limits

- Recursive sizes add up logical bytes (`.fileSizeKey`), not disk usage; this matches the basis used for file rows, but
  it will differ from the "on disk" number in Finder's Get Info.
- One `FolderSizes` has a single serial queue: if one directory contains a huge subtree, the folders behind it queue up.
- Above 4096 entries the cache is cleared wholesale rather than evicted by LRU.
- The Version / Comments / Tags columns are not implemented; column widths do not persist.
- The `nil` semantics of `dateModified` keep the old behaviour (bottom when ascending, top when descending); only the
  three new keys sink to the bottom in both directions.

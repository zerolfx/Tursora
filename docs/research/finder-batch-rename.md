# Batch rename (matching Finder's "Rename Finder Items")

Scope: batch rename after a multiple selection (≥ 2 items). Inline rename of a single selection (`Return`, or a delayed click on the name) is unchanged.

This record gives the evidence extracted from Finder's resources, the model and interface design, the explicit boundaries, and the verification stage of this implementation. Any wording or value that could not be taken from Finder's own resources is marked **inferred** below.

## 1. Finder evidence

Extraction environment: macOS 26.3 (Darwin 25.3.0), `/System/Library/CoreServices/Finder.app`.

### 1.1 Window nib

```bash
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/BulkRenameWindow.nib | sort -u
```

Visible strings (interface labels):

| String | Purpose |
|---|---|
| `Rename Finder Items:` | Window title / first-row label |
| `Replace Text` | Mode (also part of a controller class name) |
| `Find:` / `Replace with:` | The two fields of the replace mode |
| `Name Format:` | Popup label of the format mode |
| `Name and Index` / `Name and Counter` / `Name and Date` | The three numbering styles of the format mode |
| `Custom Format:` | Custom text field of the format mode |
| `Start numbers at:` | Starting number field |
| `Where:` | Position popup label |
| `after name` / `before name` | The two options of the position popup |
| `Example: ^0` | Example row (`^0` is a placeholder) |
| `Rename` / `Cancel` | The two buttons |

The accessibility titles and outlet names in the same nib show how the controls are put together:
`Find Text`, `Replace Text`, `Text To Add`, `Custom Format Text`, `Start Numbers At Text`, `Format Popup`, `Name Format Popup`, `Where Popup`;
`_findFld`, `_replaceFld`, `_textToAddFld`, `_customNameFld`, `_startIndexFld`, `_whereBtn`, `_nameFormatBtn`, `_exampleFld`, `_renameBtn`;
controller classes `TBulkRenameController`, `TBulkRenameReplaceTextController`, `TBulkRenameAddTextController`, `TBulkRenameMakeSequentialController`, `TBulkRenameFormatterController`.

### 1.2 String table

```bash
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
```

| Key | Value | Purpose |
|---|---|---|
| `BR5` | `Replace Text` | Mode popup item |
| `BR3` | `Add Text` | Mode popup item (the nib has only an outlet, no visible label) |
| `BR1` | `Format` | Mode popup item |
| `ME22_V1` | `Rename…` | File menu (the form used with no selection) |
| `ME22_V2` | `Rename “^1”` | File menu (single item) |
| `ME22_V3` | `Rename ^0 Items…` | **File menu, plural** |
| `RN17` | `The name “^0” is already taken. Please choose a different name.` | Name already taken |
| `RN31` / `RN32` | `The name “^0” can’t be used.` / `Try using a name with fewer characters, or with no punctuation marks.` | Illegal name |
| `RN1` / `RN2` | `Redo Rename` / `Undo Rename` | Undo action names |
| `RN24` / `RN25` | `Rename` / `Cancel` | Buttons |

The Finder main binary also contains the preference key names `BulkRenameStartIndex`, `BulkRenamePadAmount`, `BulkRenamePlaceNumberAt`, `BulkRenameAddTextTo`, `BulkRenameFindReplacePart`, `BulkRenameDateFormatStyle`, `BulkRenameDateSeparator`, `BulkRenameDatePosition` (`strings -a MacOS/Finder`), which show the parameters of each mode; their default values cannot be read out of the string table.

### 1.3 Parts explicitly marked as inferred

- **Order and default item of the mode popup**: `strings` does not preserve the control order of the nib. This implementation uses `Replace Text / Add Text / Format`, defaulting to `Replace Text` (the nib's initial first responder is the text field `_firstTextField`, which matches the `Find:` field of the replace mode). **Inferred**.
- **Separator between the custom text and the number**: this implementation uses a single space (`Custom 1`, `Custom 00001`, `Custom 2026-09-13 at 14.02.03`). **Inferred**.
- **Counter width of 5** (`Custom 00001`): `BulkRenamePadAmount` shows that the width is configurable, but its default value was not extracted. **Inferred**.
- **Date stamp format** `yyyy-MM-dd at HH.mm.ss` (`en_US_POSIX`, local time zone): a colon is illegal in a file name, so the time is separated by dots. **Inferred**.
- **Deduplication when date stamps inside one batch are identical** (appending ` 2`, ` 3`): Finder's handling is not documented anywhere we found. **Inferred**.
- The `Add Text:` field label: the nib gives only the accessibility title `Text To Add`. **Inferred**.
- `The name can’t be empty.`: Finder has no matching string, so this is Tursora's own wording.
- The preview table (`Current Name` → `New Name`): Finder's window has no preview list; this is a Tursora addition, with its semantics taken from the live list of Dolphin's batch rename.

## 2. Design

### 2.1 Model (`Model/BatchRename.swift`, pure functions)

- `Mode`: `.replace(find:replacement:)`, `.add(text:position:)`, `.format(kind:custom:start:position:)`; `Position` = `.afterName` / `.beforeName`; `FormatKind` = `.nameAndIndex` / `.nameAndCounter` / `.nameAndDate`.
- `Entry`: directory + name + date. The date is injected by the caller (so tests can be deterministic); the interface uses each item's modification time. The directory keeps the duplicate-name check confined to the item's own folder — several items in a search result may come from different directories.
- `split(_:)`: the extension is the part after the last dot; a dot file (`.profile`) counts entirely as the base name, and a trailing dot is not an extension.
- `plan(_:mode:)` returns the new name of every item in input order:
  - Replace Text replaces every occurrence across the **whole name** (extension included), so it can change the extension; an empty `Find` leaves the name unchanged;
  - Add Text changes only the base name and keeps the extension;
  - Format rewrites the base name as `custom text + space + number/date` and keeps the extension; Index is not zero-padded, Counter is padded to 5 digits and never truncates wider numbers, and Date uses the item's own date.
- `validate(_:for:siblings:caseSensitive:)` returns the first problem: an empty name (`The name can’t be empty.`), an illegal name (containing `/` or `:`, or being `.` or `..` → RN31 wording), a duplicate inside the batch, or a clash with an existing item in the **same directory** that is not part of this batch (RN17 wording). A name the batch itself gives up does not count as taken, so chains (a→b while b→c), swaps, and case-only changes all pass; the comparison folds case by default, and `caseSensitive: true` is there for case-sensitive volumes.
- `menuTitle(count:)` produces `Rename` / `Rename N Items…` (ME22_V3).

### 2.2 Writing to disk (`Model/BatchRenameOperations.swift`, a `FileOperations` extension)

`FileOperations.renameBatch(_:)` takes a list of `(url, newName)`:

1. validate all the names first and throw on anything illegal, **touching no file**;
2. skip the items whose name has not changed;
3. a first pass renames every item to a temporary name that is unique inside its directory (`.tursora-rename-<UUID>`), and a second pass renames it to the target name. Intermediate states therefore cannot occupy each other, so chains and swaps both work; the temporary name releases the original name, so a case-only rename also goes through a plain `moveItem` on APFS;
4. if any step fails, every rename already completed is undone in reverse order and the error is then thrown to the caller;
5. it returns `(from, to)` in request order, for undo to replay.

`reverseRenameBatch(_:)` replays the same two-pass mechanism in reverse. `siblingNames(in:)` / `siblingNames(forEntries:)` read the names a directory already contains (hidden files included) for validation to use; the interface itself never touches the filesystem.

**Why not the `URLResourceValues.name` used by single-item rename**: measured (with a one-off local script), renaming `a.txt` to an already existing `b.txt` with it **does not report an error, it overwrites `b.txt`**. Batch rename has to refuse to overwrite an item of the same name outside the batch, so it uses `FileManager.moveItem` instead (which returns `NSCocoaErrorDomain 516` when the name is taken); inline rename of a single selection keeps its existing implementation (`FileOperations.rename`), because it needs the ability to change only case on APFS and has its own up-front conflict check.

### 2.3 Interface (`UI/BatchRenameSheet.swift`, `UI/BatchRenameBrowser.swift`)

- `BatchRenameSheetController` uses `beginSheet` to attach to the window that holds the pane, **not `runModal`**, so a headless run does not hang either.
- The layout follows Finder from top to bottom: `Rename Finder Items:` + mode popup → the fields of the current mode (replace: `Find:` / `Replace with:`; add: text + `Where:`; format: `Name Format:` / `Where:` / `Custom Format:` / `Start numbers at:`) → `Example: <new name of the first item>` → preview table → error text + `Cancel` / `Rename`. `Start numbers at:` is hidden for `Name and Date`.
- Everything is recomputed on every keystroke: the preview table gives "old name → new name" row by row, and when validation fails `Rename` is greyed out and the reason is shown in place (Finder's wording). `Cancel` simply closes the sheet.
- Entry points: File ▸ Rename (the title becomes `Rename N Items…` for a multiple selection), the same item in the More (Actions) menu, and the same item in the context menu of a multiple selection. `Return` and inline rename of a single item go through `renameSelectionInline` and behave as before.
- Once applied, `BrowserViewController` takes over: `FileOperations.renameBatch` → `registerUndoBatchRename` (one undo group for the whole batch; undo renames back in reverse order) → keep the selection (renamed items by their new URL, unchanged ones by their old URL) → `DirectoryChanges.post(…, renamed:)` for every pair, so other panes and Info windows follow their own items.
- The list view and the icon view share the same path (both go through `FileViewing`'s selection and `select(urls:)`), and it applies with split panes, several tabs, filtering, grouping and search results; search results are renamed by URL, not by row number.

## 3. Boundaries

- No recursive rename, which Finder does not have either, and no remembering the settings for the next time the sheet opens (Finder's `BulkRename*` preference keys are not implemented).
- None of Finder's extension-change warning (RN8/RN12), leading-dot name confirmation (RN3), or "another operation is in progress" (RN11) prompts: these belong to the dialog family of single-item rename, and this round introduces no modals.
- Read-only ZIP pages and archive entries do not take part in batch rename; the menu item does not appear when `canModifySelectedItems` is false.
- Case-sensitive volumes: validation supports `caseSensitive`, but the interface does not yet detect whether a volume is case-sensitive and always validates with case folded (stricter, so it cannot overwrite anything by mistake).
- Finder's `Rename “^1”` (ME22_V2) wording for a single item is not implemented; a single item is still `Rename`.

## 4. Verification stage

This change (in a separate worktree, based on `e202c2e`):

- `swift build` with no errors and no new warnings.
- The full smoke test run **once** under the shared verification lock: `exit=0`, `ok=3572`, `fail=0` (baseline 3432, with 137 printed checks added by this feature). Log: `scratchpad/smoke-run-batch-rename-b-1.log`.
- New `BatchRenameSmokeTests`: the pure functions cover the three modes, `split`, date stamps and same-stamp deduplication, and every validation rule (empty name, illegal characters, duplicate inside the batch, same name across directories, conflict in the same directory, chain / swap / case-only change); `FileOperations.renameBatch` covers the chain a→b→c→d, a swap, a case-only change, skipping unchanged items, refusing a taken target and rolling the whole batch back, rejecting an illegal name up front, and counting hidden files among the sibling names; the interface path runs once in **each of the details and icons views**: plural menu wording and enablement, the More menu, the context menu, `Return` not opening the sheet, File ▸ Rename presenting the sheet, the preview updating on every keystroke, the three kinds of validation reported in place, the previews of the three modes, disk names / selection / filtering and grouping preserved after applying, another pane following along, `⌘Z` undoing the whole batch, redo, undo again, the context-menu entry point and `Cancel`; a search-results section verifies the cross-directory conflict scope and undo.
- **Not done**: the on-machine appearance check of the packaged `Tursora.app` (no screen access this round), so the sheet's actual layout, control spacing and light/dark appearance have no computer-use evidence yet; under the AGENTS.md rules this is a pending visual verification and must not be treated as completed.

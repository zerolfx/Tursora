# Trash: browsing, Put Back, Empty Trash

Records the Finder evidence, implementation boundaries, inferred parts and
verification status of the Trash feature. Corresponding code:
`app/Sources/Tursora/Model/TrashLocation.swift`, `Model/TrashOrigins.swift`,
`UI/TrashBrowser.swift`, `UI/LocationNotice.swift`, `TrashSmokeTests.swift`.

Source commit: `c97013e` (feat: add batch rename, two-way terminal folder sync, and a
command palette).

## 1. Finder evidence

All of it taken from this machine's `/System/Library/CoreServices/Finder.app/Contents/Resources/`.
The `.strings` files were read with `plutil -convert json -o -`, the `.nib` files scanned with `strings`.

| Key | English string | Use | Source file |
|---|---|---|---|
| `A3` | `Empty Trash…` | File menu and context-menu row (with the ellipsis when the warning is enabled) | `en.lproj/LocalizableMerged.strings` |
| `A15` | `Are you sure you want to permanently erase the items in the Trash?` | Main text of the empty-trash confirmation dialog | Same file |
| `A16` | `You can’t undo this action.` | Explanatory text of the confirmation dialog | Same file |
| `N157` | `Empty Trash` | Default button of the confirmation dialog | Same file |
| `N153.1` | `Put Back` | The "Put Back" context-menu row | Same file |
| `N153` | `Move to Trash` | Reference item, not added in this change | Same file |
| `N39` / `PW30` | `Trash` | Location name (sidebar, status-bar context) | Same file |
| `TL_HELP_TCAN` | `Go to the Trash` | Toolbar tooltip, evidence that "entering the Trash" is a navigation of its own | Same file |
| — | `Empty Trash` (`cmdEmptyTrash:` / `cmdEmptyTrashSilently:`) | The menu item exists in Finder's main menu | `Base.lproj/MenuBar.nib` |

Commands to reproduce:

```bash
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings \
  | python3 -c "import json,sys; d=json.load(sys.stdin); [print(k,'=',v) for k,v in d.items() if 'Trash' in str(v) or 'Put Back' in str(v)]"
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib | grep -i "trash"
```

`Put Back` appears only in `LocalizableMerged.strings`; no `.nib` contains it. Finder builds
its context menu at runtime, so **the row's position and which separator group it belongs to
are inferred**, while the wording itself has evidence.

## 2. Inferred parts (no Finder evidence, marked explicitly)

The following wording and behaviour are Tursora's own decisions: Finder has no counterpart,
or no evidence was obtained.

1. **The access-denied banner**, all of its wording: `Tursora doesn’t have permission to open “<name>”.`,
   `Give Tursora Full Disk Access in Privacy & Security settings, then try again.`,
   and the buttons `Open Privacy Settings` / `Try Again`. Finder is the system file manager and
   always has this permission, so it never shows such a banner.
2. **The tooltip shown when Put Back is disabled**, in all three variants (unknown origin / original directory gone / original name taken).
   Finder simply hides or greys out the menu row without explaining why.
3. **The Go ▸ Trash menu item**: Finder's Go menu has no Trash (it is offered only in the sidebar). Tursora adds
   it so that the keyboard and the command palette can reach the location too.
4. **No shortcut for File ▸ Empty Trash…**: Finder uses ⇧⌘⌫, but no evidence for it was found in the strings
   of `MenuBar.nib`, and the integration stage then showed that AppKit cannot tell that combination apart from
   ⌘⌫ at all. The command therefore ships unbound; see the last section of this record and D74.
5. **The `Trash` status-bar context**: its form matches the existing `ZIP · Read-only`; Finder's status bar has no such wording.
6. **Which commands are disabled inside the Trash**: Finder's actual behaviour (no new folder, paste, rename,
   duplicate or compress; copy, Quick Look, Get Info, Delete Immediately, Put Back and Empty Trash are possible) comes from
   interactive observation, not from resource evidence.

## 3. Why Put Back keeps its own log

macOS writes the path behind Finder's Put Back into private records inside the `.DS_Store` file in
the Trash directory; the format is undocumented and there is no stable API. Therefore:

- Tursora **does not parse `.DS_Store`**.
- `FileOperations.trash` already returns an `(original, trashed)` pair, and `TrashOrigins` records it
  in its own JSON log: `Application Support/Tursora/TrashOrigins.json`
  (a smoke run uses `$TMPDIR/tursora-trash-origins-smoke-<pid>-<uuid>/` instead;
  `TURSORA_UI_TEST_TRASH_ORIGINS_FILE` can point at a path).
- Writes go through a serial queue plus `Data.write(options: .atomic)`; when a read fails, the format does not match, or the version is not 1,
  **the existing file is left untouched**, the same policy as `DirectoryViewPropertiesStore`.
- Entries are removed at these moments: a successful Put Back, emptying the Trash, and listing the Trash finding that the corresponding file
  no longer exists (`pruneMissing`). The limit is `entryLimit = 5000`; beyond it the oldest entries are dropped.
- Items moved to the Trash by Finder, a shell or another application have **no** log entry; their Put Back
  is disabled with a reason given, and the origin is never guessed.

`TrashOrigins.putBack(origin:parentExists:destinationOccupied:)` is a pure function, and its rules are:
no entry → `unknownOrigin`; the original parent directory does not exist → `missingParent`; the original path is already occupied →
`nameTaken`; otherwise `available(original path)`. A missing parent takes precedence over a name clash.

## 4. Path canonicalization

`TrashLocation.canonicalPath` uses `realpath(3)` rather than `URL.resolvingSymlinksInPath()`:

- Foundation deliberately does **not** resolve `/tmp`, `/var` or `/etc` (it normalizes in the opposite direction, stripping `/private`);
  measured, `URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path == "/tmp"`.
- `resolvingSymlinksInPath()` only rewrites path components that **exist**, so an entry's key changes the moment
  the item is moved away and the log no longer matches.

Canonicalization therefore calls `realpath` on the deepest ancestor that exists and appends the remaining components back.
`/tmp/a/b` → `/private/tmp/a/b`, `/tmp` → `/private/tmp`, and an item that was just moved away still carries the name it
was recorded under.

## 5. Implementation boundaries

- **Only the user's Trash is handled**. `FileManager.url(for: .trashDirectory, in: .userDomainMask,
  appropriateFor: nil, create: false)`. `TrashLocation.volumeTrash(containing:)` uses
  `appropriateFor: <URL on the volume>` to resolve a volume-level trash (`/Volumes/X/.Trashes/501`), but **browsing,
  Put Back and Empty Trash never involve a volume-level trash**, and the sidebar has only one Trash item.
- **Injection point**: `TrashLocation.userTrashOverride`. Once set, `userTrash()`, `knownRoots()` and
  `volumeTrash(containing:)` all point at that directory, and `FileOperations.trash` moves items
  into it instead of calling `FileManager.trashItem` — which guarantees that no check ever writes into the real
  `~/.Trash`. When it is unset, behaviour is exactly as before.
- **Emptying the Trash cannot be undone** (as in Finder); items are removed one by one with `FileManager.removeItem` on a
  background queue, and failures are reported through `FileOperations.report`.
- **Undoing a Put Back** moves the item back to **the path it had inside the Trash** and restores the log entry, rather than
  calling `FileOperations.trash` again — with a fixture Trash injected, that call would send the item into the real
  `~/.Trash`. Redo restores it once more.
- **Dragging out of the Trash** follows the existing same-volume move rules. Rather than marking the Trash `isReadOnly` (which would
  force drags to degrade into copies), `FileViewing` gained a separate `allowsRenaming`.
- **A denied directory listing** (on this machine `ls ~/.Trash` is denied without Full Disk Access, see
  `docs/gaps/GAP-vs-FINDER.md`) shows a `LocationNotice` banner inside the pane, offering
  "Open Privacy Settings" (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`)
  and "Try Again". **A modal is never shown**; in smoke mode it only prints. The condition is `EPERM` / `EACCES`
  or `NSFileReadNoPermissionError` (including an `NSUnderlyingErrorKey` wrapper); `ENOENT` does not count.
- **The empty-trash confirmation** is injected through the `BrowserViewController.emptyTrashConfirmation` hook; in smoke mode
  the A15 / A16 strings are printed first and the hook then decides whether to continue or cancel (it continues when no hook is set).

## 6. Commands inside the Trash

| Command | Inside the Trash | Basis |
|---|---|---|
| New Folder / Paste / Compress / Extract | Disabled | `canModifyCurrentLocation` gains `!isBrowsingTrash` |
| Rename / Duplicate / Cut / Move to Trash | Disabled | `!isBrowsingTrash` guards in `validateMenuItem` and at each command entry point |
| Click-to-rename inside a view | Disabled | `FileViewing.allowsRenaming` (both views implement it) |
| Copy / Copy Path / Quick Look / Get Info | Available | They do not modify content |
| Delete Immediately… | Available | Still goes through the existing confirmation path |
| Put Back | Available when a log entry exists, the original parent directory is there and the original name is free | See §3 |
| Empty Trash… | Available when the Trash is not empty | `canEmptyTrash` |

Inside the Trash the context menu takes a separate branch, `trashContextMenu(for:into:)`; the background menu is
Get Info / Empty Trash… / Reload / Show Hidden Files / Sort By.

## 7. Verification

`swift build` with no errors and no new warnings.

Smoke test: **130** new `trash: ` checks, all passing (
`smoke-run-trash-h-1.log`: `ok=2126 fail=1`). Coverage:

- Pure functions: path canonicalization (trailing slash, symlink prefix, dot components), root and descendant checks, sibling
  directories with a shared prefix not being mistaken for one another, the injection override, the permission-error check,
  the Finder string constants, and the four Put Back verdicts.
- The log file: recording / lookup / forgetting / clearing by root / pruning stale entries, atomic writes and re-reading, and the entry limit.
- Both views (details and icons), one full UI pass each: moving items to the Trash through the browser → the log records
  two origins; a second tab writes into the same log; entering the Trash → the entries are listed plus the status-bar context
  `Trash — …`; the second pane of a split recognizes it too; filtering `*.txt` plus grouping by kind still work; disabled and available commands
  checked one by one; the contents of the context menu (on an item and on the background) checked; Put Back → back to the original path, the log entry gone;
  ⌘Z → back to the original path inside the Trash with the log entry restored; redo restores it once more; the three disabled reasons (unknown origin, original name
  taken, original parent directory gone); a refused Put Back moves no files; cancelling the empty leaves every entry untouched;
  after confirming the empty the directory is cleared, the log is cleared and the menu item greys out; leaving the Trash restores the ordinary rules.
- Access denied: after `chmod 000`, entering the Trash → the banner is shown, no modal, mounted inside the pane;
  `chmod 700` plus Try Again → the listing comes back.

**The one check that does not pass yet (unrelated to this feature)**: `shortcuts: native menu resolves the owned
active pane`. That check requires the test process to become the active macOS application; in this session
`osascript … set frontmost` returned 0, but the Claude desktop application immediately took the foreground back
(`get name of first process whose frontmost is true` → `Claude`), so
`NSApp.isActive == false` and there was no key/main window. This matches the known limitation recorded in
`memory/smoke-test-needs-frontmost.md`; until that environmental condition goes away, a whole run with exit=0 cannot be
obtained. The 130 checks for this feature all passed in the same run.

**No computer-use evidence yet**: the packaged `Tursora.app` has not been observed by hand, so the actual appearance of
the banner, the menus and the sidebar is still to be verified.

## The Empty Trash shortcut: why nothing is bound by default

Finder's `Empty Trash…` is ⇧⌘⌫. Measured on this machine with a standalone AppKit program (`NSMenu` plus a synthesized `NSEvent`, keyCode 51 = kVK_Delete):

| Menu item key equivalent | Event | `performKeyEquivalent` |
|---|---|---|
| ⇧⌘ + `\u{8}` | ⌘ + `\u{8}` | **true** (wrong match) |
| ⌘ + `\u{8}` | ⇧⌘ + `\u{8}` | **true** (wrong match) |
| ⌥⌘ + `\u{8}` | ⌘ + `\u{8}` | false (correctly distinguished) |
| ⌘ + `a` | ⌘ + `\u{8}` | false |

That is, for a non-letter key equivalent such as `⌫` AppKit ignores Shift but does not ignore Option. There are two consequences:

1. In the default menu order `Move to Trash` (⌘⌫) comes before `Empty Trash…`, and `performKeyEquivalent` takes the first match, so pressing ⇧⌘⌫ actually hits Move to Trash — parity with Finder's key assignment was never available in the first place.
2. As soon as a user clears the Move to Trash binding in Settings ▸ Shortcuts, a plain ⌘⌫ hits `Empty Trash…`, and emptying the Trash **cannot be undone**.

The command therefore carries no key equivalent by default ([D74](../DECISIONS.md)) and stays in the shortcut catalogue for users to assign themselves. `TrashSmokeTests.menuBinding()` asserts both that the menu item has no key equivalent and that AppKit still ignores Shift; should the latter change on a future macOS, the check fails and signals that this decision can be re-evaluated. `ShortcutMenu`'s global matching logic was not rewritten: changing the dispatch path of every menu for the sake of one command is more risk than benefit.

This one came out of the integration stage: after merging, the smoke test failed at `shortcuts: physical Backspace cannot dispatch the Forward Delete binding`, which was traced back to the newly added ⇧⌘⌫ binding.

## Reliability follow-up, 2026-09-26

Partial Move to Trash now returns successful moves and per-item failures together. Successful items retain their origin journal, Undo/Redo and cross-pane refresh even when another source fails. Undo/Redo keeps using the originating window manager after the source tab closes. Implementation and current automated/packaged verification are recorded in [the reliability record](reliability-2026-09-26.md).

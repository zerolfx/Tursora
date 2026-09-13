# Command Palette

A floating search panel that fuzzy-matches over all application commands, the sidebar favourites and
the current pane's back/forward history directories; Return runs the selection. Commands go through
the application's own menu items and responder chain, and folder entries navigate the active pane.

- Code: `app/Sources/Tursora/Model/CommandPalette.swift` (pure functions),
  `app/Sources/Tursora/UI/CommandPaletteController.swift` (the panel and dispatch)
- Tests: `app/Sources/Tursora/CommandPaletteSmokeTests.swift`
- Menu: View → `Command Palette…`, ⇧⌘O by default

## 1. Evidence

### 1.1 Finder resources (this machine, macOS 26.3 / 25D125)

```
$ strings -a /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib \
    | grep -n "Recent Folders\|Go to Folder\|Recents\|Set Focus To Search Field"
179:Go to Folder
181:Go to Folder
184:Recent Folders
186:Recent Folders
188:Recent Folders
250:Recents
252:Recents
315:Set Focus To Search Field
317:Set Focus To Search Field
```

The same file also contains the two selectors `cmdRecentFolders:` and `cmdClearRecentFolders:`
(lines 193–194), which shows that **Recent Folders** is Finder's own wording for the list of
recently visited folders. The panel's history group therefore takes `Recent Folders` as its category
name, with entry titles of the form `Recent: <path>`.

```
$ plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/Localizable.strings \
    | python3 -c "..."   # hits only
'Recents' = 'Recents'
```

`Recents` is the smart location in Finder's sidebar for recently used items, a different concept from
directory history, so it was not adopted.

```
$ strings -a .../Base.lproj/MenuBar.nib | grep -i palette
134:runToolbarCustomizationPalette:
558:toggleTouchBarCustomizationPalette:
```

Finder has **no** command palette feature and no title that could be cited. The following are
**inferred** and are not Finder evidence:

- Menu title `Command Palette…`: the common name used by editors and IDEs; the ellipsis follows the
  macOS convention for an item that opens an input interface.
- Search field placeholder `Run a command or go to a folder`.
- Empty-result text `No matching commands`.
- Favourites group name `Favourites`: consistent with the existing sidebar group title in
  `PlacesModel` (internal consistency within this project, not Finder evidence).
- Entry title `Go to <name>`: the wording shares its origin with `Go to Folder…` in the Go menu, but
  the combined form is inferred.

### 1.2 Shortcut choice

- ⇧⌘P already belongs to View → `Show Previews` (`MainMenu.viewMenu`) and cannot be reused.
- ⇧⌘O is free among the existing default bindings (the ⇧⌘ combinations already taken inside `MainMenu` are N/T/W/D/P/F/H/G/[/]/`.`).
- ⇧⌘O is the same key as Xcode's "Open Quickly", which is an **inferred** familiarity argument:
  Xcode is not installed on this machine, so there is no evidence for it.
- Like every other command it is registered in `ShortcutCatalog` (id `menu.showCommandPalette`),
  so it can be customised or cleared under Settings → Shortcuts.

### 1.3 Relationship to the menu search built into macOS

The Help menu already provides AppKit's system-level menu item search (typing highlights the matching
menu item). The two do not duplicate each other: the system search can only find items **in the
menus**, only does prefix/substring matching, and can only "point" at them for the user; the command
palette also covers catalog commands that have no menu item (File View context keys, window aliases),
favourites and history directories, and it ranks fuzzily and executes directly. The system menu
search is left untouched.

## 2. Design

### 2.1 Model layer (pure functions, testable without a UI)

`FuzzyMatcher.match(_ query: String, in candidate: String) -> Match?`

- Subsequence matching; whitespace in the query is ignored (`new f` is equivalent to `newf`), and an
  empty query matches everything with a score of 0.
- Scoring: +1 per matched character; +16 at the start of the string; +8 at the start of a word (the
  previous character is a separator, or a lowercase→uppercase or non-digit→digit boundary); +6 when
  adjacent to the previous match; −3 for each break; and the later the first match falls, an extra
  −min(offset, 6).
- The only hard constraint on the weights: **a prefix hit must always beat the same word appearing
  later** (16 − 8 = 8 still leaves headroom over the maximum first-character penalty of 6). Measured
  for `new`: `New Folder` = 31 > `Show New Item` = 18.
- The implementation is an O(query × candidate) dynamic program (the break penalty is a constant, so
  the previous row only needs a running maximum) that backtracks the indices of the matched
  characters for the UI to bold.

`PaletteEntry` has three kinds of row:

| kind | id | title | category | shortcut |
|---|---|---|---|---|
| `.command` | the `ShortcutCatalog` id | command title | catalog hierarchy (`File`, `View → Sort By`, …) | the **current** binding display string from `AppPreferences.shared.shortcuts` |
| `.favourite` | `favourite:<path>` | `Go to <name>` | `Favourites` | — |
| `.recent` | `recent:<path>` | `Recent: <path>` (home abbreviated to `~`) | `Recent Folders` | — |

`CommandPalette.filter` sorts by **score first, then category, then title, then id**, which makes the
result independent of the order in which entries were built. The panel's own command
(`menu.showCommandPalette`) is excluded from the list.

### 2.2 UI layer

- One `CommandPaletteController` per window, living as long as the window controller (a static table
  holds the host weakly, so it is cleaned up as soon as the host is released).
- The panel is an `NSPanel` subclass with `canBecomeKey = true` (the opposite of `CompletionPopup`'s
  non-activating panel), so keyboard input lands straight in the panel's own search field. Borderless
  plus `AdaptiveLayerView` rounded corners, following the parent window's appearance.
- The size flexes with the number of result rows between 420 and 640 pt wide, centred horizontally
  and sitting slightly above centre over the window.
- Keys: ↑/↓ move with wraparound, Return runs, Esc closes. Clicking a row is the same as Return.
- Unavailable commands are **still listed but greyed out** (category and shortcut included); Return
  refuses to run them and the panel stays open.

### 2.3 Execution path

1. **When the panel opens** (while the browser window is still key), the whole `NSApp.mainMenu` tree
   is first run through `update()` once, then each `NSMenuItem` is found by id and its target
   resolved explicitly **along the browser window's responder chain**
   (`item.target` → the `window.firstResponder` chain → the active pane → the window controller → the window → the app delegate → NSApp),
   taking an availability snapshot through `validateMenuItem` / `validateUserInterfaceItem`.
   The reason for resolving explicitly instead of relying on the key window: once the panel is open
   it is the key window itself, and `NSApp.targetForAction(_:to:from:)` would walk the wrong chain.
2. **When running**, the panel closes first (handing focus back to the file view), the command is
   validated once more, and then `NSApp.sendAction(item.action, to: target, from: item)` — the same
   as clicking it in the menu bar.
3. Catalog commands (the ones in `ShortcutCatalog` without a menu item: Rename/Quick Look/Cancel
   Opening Archive/the Next-Previous Tab aliases/the Zoom In alias/Select Tab 1–9) go through
   `CommandPaletteRunner.performContextual`, which matches the branches of `ShortcutDispatcher.handle`
   one for one.
4. Folder rows call `browser.navigate(to:)` on the **currently active pane** (`tabs.current` = the
   active pane of the current tab).

So the panel itself never touches the filesystem; writes such as `New Folder` still go through
`MainWindowController` → `BrowserViewController` → `FileOperations`, and undo and
`DirectoryChanges.post` follow the same path as before.

## 3. Boundaries and known limits

- Fuzzy matching applies to **titles** only, not to category names. Typing `sort` will not find
  `Name` under `View → Sort By`.
- History directories take at most 12 entries back and 12 forward from the current pane's
  `NavigationHistory`, de-duplicated and with the current directory excluded; this is **per-pane**
  history, not an application-level "recently opened" list, and it disappears once the tab is closed.
- Favourites come from the Favourites group of `PlacesModel`; Locations (volumes) do not enter the
  panel.
- Rows are snapshotted **at the moment the panel opens**: if the selection or the tab changes while
  the panel is open, the greyed-out state is not refreshed live (the command is validated again
  before it runs, so a command that has become invalid is never run by mistake).
- The panel has no icons or group headers beyond the matched characters; matched characters are only
  bolded, not coloured.
- Accessibility only sets a label on the search field; the rows themselves rely on what
  `NSTableView` exposes by default.
- There is no ranking memory of recently used commands.

## 4. Verification

### 4.1 Completed (automated)

This branch ran one full smoke on top of e202c2e (under the shared verification lock, with System
Events bringing the test process to the front): `exit=0 ok=3511 fail=0`, of which 76 checks belong to
the command palette itself. The e202c2e baseline is 3432 checks; the 79 new ones are the panel's 76
plus the 3 clear/rebind/reset checks for the new command in `ShortcutSmokeTests`.
**Per AGENTS.md three consecutive passes are still required before committing**; this record claims
only the single run that has passed.


`CommandPaletteSmokeTests` (`checkPrefix = "command palette: "`) runs in `SmokeTest.run`'s `steps`
directly after `ShortcutSmokeTests`:

- Pure matcher: no match returns nil; a query longer than the candidate returns nil; an empty query
  scores 0; whitespace is ignored; a prefix beats an infix; case-insensitive in both directions; a
  word start beats mid-word; starting at a word start beats being buried inside a word; subsequence
  indices with gaps; indices that prefer adjacency; indices where an abbreviation hits word starts.
- Pure entry list: the panel's own command is excluded; command rows carry their category and the
  current shortcut display string; an unbound command has no shortcut; favourites become
  `Go to …`; history becomes `Recent: …` with home abbreviated to `~`; duplicate history is
  de-duplicated; typing a command name ranks it first; no match gives an empty list; an empty query
  keeps everything; equal scores sort by category/title.
- Catalog registration: `menu.showCommandPalette` is a customisable catalog command; ⇧⌘O by default;
  `Show Previews` is still ⇧⌘P; the matching menu item exists in the View menu; no other command
  claims ⇧⌘O.
- The real panel (**run once in the list view and once in the icon view**): the panel opens as a
  child window; the initial query is empty and every row is listed; favourite rows agree with the
  sidebar Favourites; the current pane's history shows up as Recent rows; typing filters down to the
  target command and shows its shortcut; ↑/↓ move the selection and bring it back; Return runs the
  command and closes the panel; focus returns to the file view; `New Folder` really creates a folder
  in the active pane's directory; a directory row picked by path navigates the active pane; Esc
  closes and nothing is run; an unavailable command is listed but greyed out and Return refuses to
  run it (the panel stays open, no extra tab is opened); click-to-run reaches the active pane (Show
  Hidden Files toggles); a favourite row navigates the active pane through the same runner.
- Split panes: with the right pane active, `New Folder` is created in the right pane and the left
  pane is untouched; switching the active pane moves the target with it.

The fixture directory is `$TMPDIR/tursora-command-palette-<UUID>`, deleted when done; no real user
files are read or written, and no real preferences such as `favouritesOrder` are written (favourite
navigation uses a synthetic `PlacesModel.Place` pointing at the fixture directory).

### 4.2 Still pending

- **The visual check of the packaged app has not been done**: the panel's actual appearance (rounded
  corners, blur, Light/Dark, bold highlighting, its width in a narrow window) and real keyboard input
  (input methods, the ⇧⌘O trigger) have only gone through their logic path in the headless smoke
  test, with no screenshot evidence. This record does not count them as completed.
- The panel's placement has not been verified on multiple displays or in a full-screen window.

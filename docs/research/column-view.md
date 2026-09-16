# Column view: Finder evidence and what is inferred

Extracted read-only from macOS 26.3 (25D125) Finder resources on 2026-09-15, plus the defaults domain on this machine. Nothing here was taken from memory; anything not traceable to a resource is listed under *inferred*.

## Evidence from Finder's resources

| Claim | Source | Value |
|---|---|---|
| Menu label | `Base.lproj/MenuBar.nib` | `as Columns`, action `cmdViewAsColumns:` |
| Menu key | `MenuBar.nib` | key `3` with the Command-only mask, so **⌘3** |
| Menu symbol | `MenuBar.nib` | `rectangle.split.3x1` (already recorded in [finder-menu-icons](finder-menu-icons.md)) |
| Toolbar | `Toolbar.nib` | On this OS the view switcher is a menu (`_viewSwitcherMenu`), not a segmented control; its `as Columns` item carries the same symbol |
| View class | `ColumnView.nib` | `TColumnView : NSBrowser`, accessibility description `column view` |
| Geometry | `ColumnView.nib` | minimum column width 100, six visible columns, row height 24 |
| Preview column | `ColumnPreview.nib` | a Quick Look preview above an icon, name and "Size and Kind" header, then information rows |
| View Options labels | `ViewOptionsWindow.nib` | `Text size:`, `Show icons`, `Show icon preview`, `Show preview column`, `Resize columns to fit filenames` |
| Defaults | `defaults read com.apple.finder` → `StandardViewOptions.ColumnViewOptions` | `ColumnWidth = 245`, `ShowPreview = 1`, `ShowIconThumbnails = 1`, `ColumnShowIcons = 1`, `ColumnShowFolderArrow = 1`, `FontSize = 13`, `ArrangeBy = dnam` |

## How Tursora uses it

- The view is `NSBrowser` in item mode (`ColumnViewController`), matching Finder's class. Minimum width 100, default width 245 and six visible columns are taken from the resources above; the default zoom step gives a 24 pt row.
- The binding is **⌥⌘3**, not Finder's ⌘3: ⌘3 selects tab 3 in Tursora, and ⌥⌘1 / ⌥⌘2 already select the other two views. Finder's ⌥⌘3 is `Clean Up By ▸ Last Opened`, which Tursora does not have, so nothing collides.
- The preview column reuses the docked preview pane's renderer, so Markdown is rendered there too; Finder's preview column shows Quick Look plus an information block, which is not reproduced.

## Measured on this machine, 2026-09-15

The preview column releases its Quick Look item in `viewDidDisappear` and re-shows the selected file in `viewDidAppear`. `TabsController` switches tabs by toggling `isHidden` on the page views rather than adding and removing them, so whether those callbacks fire at all was checked with a standalone AppKit program: a view controller's view under a container whose ancestor is hidden receives `viewDidDisappear` (1 → 1 call), and unhiding it receives `viewWillAppear` and `viewDidAppear` again (1 → 2), exactly as removing and re-adding the view does (2 → 3). So the tab-switch path is real, not assumed.

### Two AppKit contracts found after the first release, 2026-09-16

Both bugs were reported against 0.4.0 and both were invisible to the existing checks, which asserted the model behind the columns rather than what a column draws.

- **Rows drew no icon.** An `NSBrowser` in *item* mode draws its rows with `NSTextFieldCell`, not `NSBrowserCell`; `setCellClass:` and `cellPrototype` are ignored in that mode. `willDisplayCell:` was casting to `NSBrowserCell`, so the `guard` failed on every row and the whole body — the icon, the display name and the dimming of a cut item — never ran, with no error. The cast is now to `NSCell` and the icon is an `NSTextAttachment` at the head of the attributed title, because a text cell has no `image`. A check reads a drawn row back and asserts the attachment character is there. Repairing the cast had a knock-on effect worth recording: `beginRename` used to seed the cell with the real filename and rely on nothing overwriting it, which held only because `willDisplayCell:` had never run. With the delegate working, `editItem` redraws the row and the drawn title — attachment character and hidden extension — became what the rename editor showed. The field editor is now seeded again after `editItem`. The suite already had a check for this (`rename retains the full extension`, run for all three view modes); it sits late in the asynchronous chain, which is why the bug survived several rounds that stopped earlier.
- **The preview column was blank for anything Quick Look renders — a PDF, an image, a video.** `NSBrowser` sizes a preview column's view through the **autoresizing mask**, not through constraints, so a view laid out purely with Auto Layout is handed a frame 0 pt high: correct content, nothing visible. `PreviewPanelController` now takes a non-zero frame and `[.width, .height]` when it is used inside a column, and not when it is the docked pane, which its split view item lays out. A check creates a real PDF with `CGContext` and asserts the preview column holds it, and a second check pins the sizing path.

### What the icon fix cost, found by review before merge, 2026-09-16

Making `willDisplayCell:` run for the first time changed three things that had been dead code, and each had a consequence the feature's own checks did not see. All were found by an adversarial review of the branch (7 lenses, 3 skeptics per finding) and fixed before merge; each now has a check that was verified to fail when the fix is reverted.

- **Type-select stopped working.** `NSBrowser.allowsTypeSelect` defaults to true and, with no delegate method, matches against the cell's own string — which now begins with the attachment's U+FFFC, so no typed letter could match any row. Measured on a standalone item-mode browser: "z" over Apple/Notes/Zebra selected nothing with the attachment title and `[[2]]` once `browser(_:typeSelectStringForRow:inColumn:)` supplied the plain name. `docs/SHORTCUTS.md` had claimed column-view type-select all along, and D84 gives it as a reason for choosing `NSBrowser`; the claim is true again.
- **VoiceOver read the attachment character.** An `NSCell` derives both its accessibility label and its value from the attributed string. Measured: setting only `setAccessibilityLabel` leaves U+FFFC in the value, and setting only `setAccessibilityValue` leaves the label nil, so the row sets both.
- **Rename showed the drawn title, and preselected the whole filename.** The first half is described above. The second half only became reachable once the editor was seeded at all: `SPEC.md` requires the base name to be preselected, as Finder does, and selecting the whole string turned `photo.jpg` plus a typed word into a file with no extension. The column view now applies the list view's rule.

One claim in the first round of comments was itself wrong and has been corrected: `NSWorkspace.icon(forFile:)` returns a **fresh image on every call**, not a shared cached one — measured, `a === b` is false and resizing one does not change the next. The code no longer claims otherwise.

## Inferred, not evidence

- **Selection does not navigate.** Finder makes the deepest selected folder the window's location. Tursora keeps the location on the first column's folder and moves it only when a folder is opened. This is a design choice (D84), driven by per-folder view properties being re-applied on navigation; it is not a claim about Finder.
- Grouping is not drawn in columns. Finder's column view supports Arrange By; Tursora applies the pane's filter and sort to every column and leaves grouping to the list and icon views.
- The column zoom ladder reuses the list's sizes. Finder exposes a `Text size:` option instead; the mapping from a zoom step to a row height is Tursora's.

## Verification status

- Automated: `ColumnViewSmokeTests` — mode plumbing, per-folder persistence including a file written before the mode existed, the column chain through a three-level fixture, selection through the pane's generic API, the location staying put, change-broadcast reporting for open columns, read-only rename refusal, zoom, mode round trips. Three consecutive green runs are required before commit.
- Automated, added 2026-09-16 with the fixes above: a drawn row carries an icon attachment; hides the extension when the preference says so; answers type-select with the real name; reads its own name to assistive clients rather than U+FFFC; is dimmed in both text and icon when cut (icon fade measured by alpha coverage, 0.576 → 0.260); a selected PDF is held by the preview column; the preview column takes the autoresizing path **and** starts from a non-zero frame; rename preselects the base name in all three views; and the preview pane, hidden and reopened on the same file, shows it again.
- Each of those checks was mutation-tested: the fix it covers was reverted one at a time and the check was confirmed to fail. Eight of eight. Two checks failed that test on the first attempt and were rewritten — one asserted state the test had seeded itself, one went through a path that cleared the pane before the reopen.
- **Not yet done:** the column view has not been looked at in a packaged build. Column widths, the preview column's appearance and keyboard movement between columns are unverified by eye. The two bugs above are what that gap costs: both were plainly visible on screen and neither was visible to the suite.

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

## Inferred, not evidence

- **Selection does not navigate.** Finder makes the deepest selected folder the window's location. Tursora keeps the location on the first column's folder and moves it only when a folder is opened. This is a design choice (D84), driven by per-folder view properties being re-applied on navigation; it is not a claim about Finder.
- Grouping is not drawn in columns. Finder's column view supports Arrange By; Tursora applies the pane's filter and sort to every column and leaves grouping to the list and icon views.
- The column zoom ladder reuses the list's sizes. Finder exposes a `Text size:` option instead; the mapping from a zoom step to a row height is Tursora's.

## Verification status

- Automated: `ColumnViewSmokeTests` — mode plumbing, per-folder persistence including a file written before the mode existed, the column chain through a three-level fixture, selection through the pane's generic API, the location staying put, change-broadcast reporting for open columns, read-only rename refusal, zoom, mode round trips. Three consecutive green runs are required before commit.
- **Not yet done:** the column view has not been looked at in a packaged build. Column widths, the preview column's appearance and keyboard movement between columns are unverified by eye.

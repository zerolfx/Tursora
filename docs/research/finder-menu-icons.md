# Finder's menu icons and Info window labels (extracted from Finder's own nibs)

Method: on macOS 26 Finder's menu items carry SF Symbols, and the symbol names live alongside the menu titles in `MenuBar.nib` (NIBArchive format, not a plist).
Once `strings` has pulled the strings out, each symbol name follows its own title:

```bash
strings "/System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib"
```

The nib deduplicates reused image objects, so items that share one icon (Get Info / Get Summary Info, Paste / Paste Exactly) appear only once,
and for some items no definite symbol name can be obtained. In the table below, "Source = nib" is certain; "Source = inferred" is a generic symbol we picked.

## Menu bar (the parts Tursora already uses)

| Menu item | SF Symbol | Source |
|---|---|---|
| New Finder Window → our New Window | `plus.rectangle` | nib |
| New Tab | `macwindow.badge.plus` | inferred |
| New Folder | `folder.badge.plus` | nib |
| Quick Look | `eye` | inferred |
| Get Info / Get Summary Info / Show Inspector | `info.circle` | nib (immediately follows Get Summary Info) |
| Rename | `pencil` | inferred |
| Duplicate | `plus.square.on.square` | nib |
| Move to Trash / Empty Trash | `trash` | nib (immediately follows Empty Trash) |
| Undo / Redo | `arrow.uturn.backward` / `arrow.uturn.forward` | inferred |
| Cut | `scissors` | inferred |
| Copy / Copy as Pathname | `document.on.document` (falls back to `doc.on.doc` on macOS 14) | nib (immediately follows Copy as Pathname) |
| Paste / Paste Exactly | `document.on.clipboard` (falls back to `doc.on.clipboard`) | nib (immediately follows Paste Exactly) |
| Select All | `character.textbox` | nib |
| as Icons / as List / as Columns / as Gallery | `square.grid.2x2` / `list.bullet` / `rectangle.split.3x1` / `squares.below.rectangle` | nib |
| Clean Up Selection | `square.grid.3x3` | nib |
| Use Groups | `square.grid.3x1.below.line.grid.1x2` | nib |
| Group By | `arrow.up.arrow.down` | nib (immediately follows "Group By"; may belong to Sort By instead) |
| Hide / Show Sidebar | `sidebar.leading` | nib |
| Hide / Show Preview | `sidebar.trailing` | nib |
| Customize Toolbar | `wrench.adjustable` | nib |
| Show View Options | `gearshape` | nib |
| Back / Forward | `chevron.backward` / `chevron.forward` | nib |
| Enclosing Folder | `arrow.up.folder` (falls back to `folder`) | nib |
| Home | `house` | nib |
| Desktop | `menubar.dock.rectangle` | nib |
| Documents / Downloads / Library / Utilities | `document` / `arrow.down.circle` / `building.columns` / `wrench.and.screwdriver` | nib |
| Go to Folder | `arrow.forward.folder` (falls back to `folder`) | nib |
| Recent Folders | `clock` | nib |
| Connect to Server | `rectangle.connected.to.line.below` | nib |
| Network / AirDrop | `network` / `airdrop` | nib |
| Filter (Finder's Find by Name) | `magnifyingglass` | nib |
| Reload | `arrow.clockwise` | inferred |
| Split View | `rectangle.split.2x1` | inferred |
| Add to Sidebar → our Add to Favourites | `star` (`star.slash` for removing) | nib / inferred |

In the nib but unused: Compress `zipper.page`, Make Alias `square.dashed.and.alias`, Show Original `arrowshape.turn.up.left.square.dashed`,
Add to Dock `dock.arrow.down.rectangle`, Slideshow `play.rectangle`, Print `printer`, Share `square.and.arrow.up`,
Eject All `eject`, Open in New Window and Close `arrow.up.forward.app`, Show Clipboard `clipboard`, Burn Disc `burn`,
Select Startup Disk `internaldrive`, Mac User Guide `book.pages`, Preferences `gear`, Shared `folder.badge.person.crop`,
Manage Shared File `person.crop.circle.badge.checkmark`.

## Info window sections and labels

From `InfoWindow*.nib` in the same directory, one section per nib:

| nib | Labels |
|---|---|
| InfoWindowSimpleHeaderView | icon, name, size, `Modified:` |
| InfoWindowGeneralView | `General:`, `Kind:`, `Size:`, `Where:`, `Created:`, `Modified:`, `Original:`, `Version:`, `Copyright:`, `Capacity:`, `Available:`, `Used:`, `Format:`, `Server:`, `Shared by:`, `Locked`, `Stationery pad`, and the application-only `Open using Rosetta` / `Prevent App Nap` / `Prefer External GPU` |
| InfoWindowMoreInfoView | `More Info:`, `Spotlight:`, `Fetching` |
| InfoWindowNameView | `Name & Extension:`, `Hide extension` |
| InfoWindowCommentsView | `Comments:` |
| InfoWindowOpenWithView | `Open with:`, `Change All`, `Use this application to open all documents like this one.` |
| InfoWindowPreviewView | `Preview:` |
| InfoWindowPermissionsView | columns `Name` / `Privilege`; `Read & Write`, `Read only`, `Write only (Drop Box)`, `No Access`, `Custom`, `No Privileges Info`; `You can only read`; `Apply to enclosed items`, `Ignore ownership on this volume`, `Make … the owner`, `Choose new owner` / `Choose new group`, `Revert changes`, `Remove` |
| InfoWindowApplyToWindow | `Apply to Enclosed Items`, `Applying privileges to …` |

The "Sharing & Permissions:" section title, "You can read and write", the "N bytes (X on disk)" / "X on disk (N bytes) for M items" wording of the Size line
and the "Multiple Item Info" title are not in the nib (they live in code or in another string table); they follow what Finder actually displays and are inferred.

# Finder 的菜单图标与 Info 窗口标签（从 Finder 自己的 nib 抽取）

方法：macOS 26 的 Finder 菜单项带 SF Symbol，符号名和菜单标题一起存在 `MenuBar.nib`（NIBArchive 格式，不是 plist）。
`strings` 抽出字符串后，符号名紧跟在对应标题之后：

```bash
strings "/System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib"
```

nib 会把重复使用的图片对象去重，所以共用同一图标的项（Get Info / Get Summary Info，Paste / Paste Exactly）只出现一次，
有些项拿不到确定的符号名。下表"来源 = nib"的是确定的，"来源 = 推断"的是我们选的通用符号。

## 菜单栏（Tursora 已用的部分）

| 菜单项 | SF Symbol | 来源 |
|---|---|---|
| New Finder Window → 我们的 New Window | `plus.rectangle` | nib |
| New Tab | `macwindow.badge.plus` | 推断 |
| New Folder | `folder.badge.plus` | nib |
| Quick Look | `eye` | 推断 |
| Get Info / Get Summary Info / Show Inspector | `info.circle` | nib（Get Summary Info 后紧跟） |
| Rename | `pencil` | 推断 |
| Duplicate | `plus.square.on.square` | nib |
| Move to Trash / Empty Trash | `trash` | nib（Empty Trash 后紧跟） |
| Undo / Redo | `arrow.uturn.backward` / `arrow.uturn.forward` | 推断 |
| Cut | `scissors` | 推断 |
| Copy / Copy as Pathname | `document.on.document`（macOS 14 回退 `doc.on.doc`） | nib（Copy as Pathname 后紧跟） |
| Paste / Paste Exactly | `document.on.clipboard`（回退 `doc.on.clipboard`） | nib（Paste Exactly 后紧跟） |
| Select All | `character.textbox` | nib |
| as Icons / as List / as Columns / as Gallery | `square.grid.2x2` / `list.bullet` / `rectangle.split.3x1` / `squares.below.rectangle` | nib |
| Clean Up Selection | `square.grid.3x3` | nib |
| Use Groups | `square.grid.3x1.below.line.grid.1x2` | nib |
| Group By | `arrow.up.arrow.down` | nib（紧跟 "Group By"，也可能属于 Sort By） |
| Hide / Show Sidebar | `sidebar.leading` | nib |
| Hide / Show Preview | `sidebar.trailing` | nib |
| Customize Toolbar | `wrench.adjustable` | nib |
| Show View Options | `gearshape` | nib |
| Back / Forward | `chevron.backward` / `chevron.forward` | nib |
| Enclosing Folder | `arrow.up.folder`（回退 `folder`） | nib |
| Home | `house` | nib |
| Desktop | `menubar.dock.rectangle` | nib |
| Documents / Downloads / Library / Utilities | `document` / `arrow.down.circle` / `building.columns` / `wrench.and.screwdriver` | nib |
| Go to Folder | `arrow.forward.folder`（回退 `folder`） | nib |
| Recent Folders | `clock` | nib |
| Connect to Server | `rectangle.connected.to.line.below` | nib |
| Network / AirDrop | `network` / `airdrop` | nib |
| Filter（Finder 的 Find by Name） | `magnifyingglass` | nib |
| Reload | `arrow.clockwise` | 推断 |
| Split View | `rectangle.split.2x1` | 推断 |
| Add to Sidebar → 我们的 Add to Favourites | `star`（移出用 `star.slash`） | nib / 推断 |

未用但 nib 里有：Compress `zipper.page`，Make Alias `square.dashed.and.alias`，Show Original `arrowshape.turn.up.left.square.dashed`，
Add to Dock `dock.arrow.down.rectangle`，Slideshow `play.rectangle`，Print `printer`，Share `square.and.arrow.up`，
Eject All `eject`，Open in New Window and Close `arrow.up.forward.app`，Show Clipboard `clipboard`，Burn Disc `burn`，
Select Startup Disk `internaldrive`，Mac User Guide `book.pages`，Preferences `gear`，Shared `folder.badge.person.crop`，
Manage Shared File `person.crop.circle.badge.checkmark`。

## Info 窗口的分区与标签

来自 `InfoWindow*.nib`（同目录），每个 nib 一个分区：

| nib | 标签 |
|---|---|
| InfoWindowSimpleHeaderView | 图标、名字、大小、`Modified:` |
| InfoWindowGeneralView | `General:`、`Kind:`、`Size:`、`Where:`、`Created:`、`Modified:`、`Original:`、`Version:`、`Copyright:`、`Capacity:`、`Available:`、`Used:`、`Format:`、`Server:`、`Shared by:`、`Locked`、`Stationery pad`、应用专有的 `Open using Rosetta` / `Prevent App Nap` / `Prefer External GPU` |
| InfoWindowMoreInfoView | `More Info:`、`Spotlight:`、`Fetching` |
| InfoWindowNameView | `Name & Extension:`、`Hide extension` |
| InfoWindowCommentsView | `Comments:` |
| InfoWindowOpenWithView | `Open with:`、`Change All`、`Use this application to open all documents like this one.` |
| InfoWindowPreviewView | `Preview:` |
| InfoWindowPermissionsView | 列 `Name` / `Privilege`；`Read & Write`、`Read only`、`Write only (Drop Box)`、`No Access`、`Custom`、`No Privileges Info`；`You can only read`；`Apply to enclosed items`、`Ignore ownership on this volume`、`Make … the owner`、`Choose new owner` / `Choose new group`、`Revert changes`、`Remove` |
| InfoWindowApplyToWindow | `Apply to Enclosed Items`、`Applying privileges to …` |

"Sharing & Permissions:" 的分区标题、"You can read and write"、Size 行的 "N bytes (X on disk)" / "X on disk (N bytes) for M items" 写法、
"Multiple Item Info" 标题不在 nib 里（在代码或别的字符串表），按 Finder 的实际显示写的，属于推断。

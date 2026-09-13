# 排序键、可选列与文件夹大小 —— Finder 取证、实现边界与验证

覆盖三件事：`DirectoryModel.SortKey` 新增的三个日期键、详情视图的可选列（表头右键菜单 + 每目录持久化），以及新的
`Model/FolderSizes.swift`（文件夹条目数 / 递归字节数）。

相关文档：[SPEC.md §5](../SPEC.md)、[DECISIONS.md](../DECISIONS.md) D67–D69、
[research/finder-group-labels.md](finder-group-labels.md)（分组标签的同源取证）、
[research/directory-view-properties.md](directory-view-properties.md)（每目录视图记忆）。

## 1. Finder 取证

全部来自本机 macOS 26.5 的 Finder 自身资源，命令与原始输出如下。

### 1.1 排序键标签 —— `ArrangeByMenu.nib`

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

同一 nib 中的 selector 证明这些标签同时用于 Sort By 与 Arrange By：

```
$ strings -a .../ArrangeByMenu.nib | grep -iE "cmdSortBy" | sort -u
cmdSortByDateAdded:      cmdSortByDateCreated:   cmdSortByDateLastOpened:
cmdSortByDateModified:   cmdSortByKind:          cmdSortByLabel:
cmdSortByLastModifiedBy: cmdSortByName:          cmdSortByNone:
cmdSortBySharedBy:       cmdSortBySize:          cmdSortBySnapToGrid:
```

Tursora 采用其中的 **Name / Date Modified / Date Created / Date Last Opened / Date Added / Size / Kind** 七项，顺序即
`ViewOptionsWindow.nib` 中的列顺序（见 1.2）。未采用的 `Label`、`Shared By`、`Last Modified By`、`Snap to Grid`
属于我们尚未实现的能力（标签、共享），不在本次范围。

### 1.2 列标题与顺序、"Calculate all sizes" —— `ViewOptionsWindow.nib`

按文件内出现顺序（未排序），即 Finder "Show Columns:" 复选框的实际排列：

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

同一 nib 的 binding 键名证实这些是列表视图（list view）的设置，且 "Calculate all sizes" 是一个独立开关：

```
value: viewOptionsSettingsController.targetedViewOptionsSettings.listViewCalculateAllSizes
value: viewOptionsSettingsController.targetedViewOptionsSettings.listViewShowKind
value: viewOptionsSettingsController.targetedViewOptionsSettings.listViewShowSize
value: viewOptionsSettingsController.targetedViewOptionsSettings.listViewShowComments
value: viewOptionsSettingsController.targetedViewOptionsSettings.listViewShowVersion
```

Tursora 实现 Finder 九列中我们已有数据的六列（Date Modified / Date Created / Date Last Opened / Date Added /
Size / Kind）。**Version、Comments、Tags 未实现**（无版本号、无 Finder 注释写入、无标签系统），记在缺口清单里。

### 1.3 "N items" 措辞 —— `en.lproj/LocalizableMerged.strings`

```
$ plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
'I_ITEMS_V1' = '^0 items'
'I_ITEMS_V2' = '^0 item'
'I_ITEMS_V3' = '^0 items'
```

即单数 "1 item"、其余 "N items"。`FolderSizes.itemCountText` 照此实现，与状态栏既有措辞
（`StatusBarView`："1 item" / "N items"）一致。

## 2. 仍属推断 / 与 Finder 有意不同的部分

| 项 | Finder 实际 | Tursora | 理由 |
|---|---|---|---|
| 关闭 "Calculate all sizes" 时文件夹的 Size 列 | 显示 `--` | 显示 "N items" | 本次任务明确要求；`--` 是纯粹的空信息，条目数是一次目录读取就能拿到的真实数据。措辞仍取自 Finder 的 `I_ITEMS_*`。**这是与 Finder 的有意差异。** |
| "N items" 是否计入隐藏项 | 未取证 | **不计**（`.skipsHiddenFiles`）| 与 Finder 简介窗口的"可见项"直觉一致；推断。 |
| 递归字节数是否计入隐藏文件 | 未取证 | **计入** | 大小要真实；与条目数的口径不同，是有意的：数量描述"你能看见多少"，大小描述"占了多少盘"。推断。 |
| 递归字节数是否计入符号链接自身 | 未取证 | **不计** | 链接的字节属于目标所在的文件夹；避免重复计数。Darwin 的 URL 枚举器本身也不跟随符号链接（见 DEVELOPMENT.md 搜索小节）。推断。 |
| 排序 Size 时文件夹用什么值 | 未取证 | 计算开启且已知 → 字节数；否则 → 条目数；都未知 → 视为最小 | 让排序对"已经算出来的东西"生效，并在结果到达后重排。推断。 |
| 三个新日期键中"无日期"项的位置 | 未取证 | 升序降序都排在最后 | 与"文件夹永远在前"同类的方向无关规则：翻转顺序不应把"没有日期"顶到最前。**`dateModified` 保持原有的 `.distantPast` 语义不变**，以免改动既有行为。 |
| 列宽是否持久化 | Finder 会记 | **不记** | 本次范围外；每次打开用默认宽度。 |
| 表头右键菜单的具体内容 | 未取证（Finder 确有该菜单） | 六个可选列 + 分隔线 + "Calculate all sizes" | 菜单存在与两类条目是推断；每条文字本身有取证（1.2）。 |

## 3. 实现

### 3.1 排序键

`DirectoryModel.SortKey` 增加 `dateCreated / dateAdded / dateLastOpened`，rawValue 与 `GroupKey` 同名键一致。
比较器新增纯函数 `DirectoryModel.compareDates(_:_:nameAscending:ascending:)`：日期相同回落到名称（名称顺序随方向
翻转，与既有键一致），`nil` 两个方向都垫底。文件夹依旧无条件在前。

菜单三处同步：`MainMenu.swift` 的 View ▸ Sort By、`BrowserViewController.sortMenuItem()` 的右键 Sort By、
`FileListViewController.Column.sortKey` 的表头点击（`sortDescriptorPrototype` ↔ `SortKey`）。
`DirectoryViewProperties` 的 `sortKey` 仍按 rawValue 宽容解码，旧文件写入的四个键照常加载，未知键回落 `.name`。

图标视图没有列，只跟随模型的排序键。

### 3.2 可选列

`FileListViewController.Column` 扩为 `name, dateModified, dateCreated, dateLastOpened, dateAdded, size, kind,
location`（顺序 = 1.2 的 Finder 顺序，`location` 仍是搜索专用、排在最后）。
新增三列默认隐藏，可在表头右键菜单勾选，也可点击表头排序。

`UI/FileListColumns.swift` 持有：`ListColumnHeaderMenu`（`NSMenuDelegate`，每次打开重建以刷新对勾）、
`FileListViewController` 的显隐/持久化扩展、`BrowserViewController.canCalculateFolderSizes` 与窗口命令。
`NSTableHeaderView` 自带的 `menu` 为空时右键会落到文件上下文菜单，所以显式赋值。

`DirectoryViewProperties` 新增 `listColumns: [String]`（默认 `["dateModified", "kind", "size"]`）与
`calculateAllSizes: Bool`（默认 `false`），两者都参与 `normalized`（去重 + 排序，保证同一列集合无论顺序都相等）、
`Use Current Settings as Default` 与 `Restore This Folder to Default`。解码宽容：缺键 → 默认值；
未知列标识符保留在模型层、由视图过滤，不会因为新版本写入的列而隐藏我们已有的列。列宽不持久化。

### 3.3 文件夹大小

`Model/FolderSizes.swift`，每个 `DirectoryModel` 一个实例：

- **状态全在主线程**，只有两次文件系统遍历在串行后台队列上跑；结果带着 generation 与取消 token 回主线程。
- **条目数**：一次 `contentsOfDirectory(options: .skipsHiddenFiles)`。
- **递归字节数**：仅在 "Calculate all sizes" 打开时；`FileManager.enumerator`，`errorHandler` 一律继续，
  跳过符号链接，每 256 项检查一次取消，超过 `entryLimit`（500,000 项）放弃并只保留条目数。
- **缓存键 = (标准化路径, 修改时间)**：文件夹自身列表变了就自动换键重算；子树深处的变化不改祖先的 mtime，
  所以额外监听 `DirectoryChanges`，把变更目录及其所有已测量祖先从缓存里删掉后重新请求。
- **取消**：`cancel()` 取消当前 token 并递增 generation；`DirectoryModel.load`（切换目录）与
  `beginSearchResults` 调用它。晚到的结果 generation 不匹配，直接丢弃，不会落到新目录里。
- **ZIP / 搜索结果只算条目数**：`allowsRecursiveSizes`（由 `restoreViewProperties` 按 `isBrowsingArchive` 设置）、
  `request(allowsRecursiveSizes:)`（`DirectoryModel` 按 `isSearchResults` 传入）、以及逐项的 `isArchiveEntry`，
  三道都拦递归遍历，条目数照常。

Size 列文本走 `FolderSizes.displaySize(for:)`；Size 排序走 `sortValue(for:)`，新值到达时
`DirectoryModel.folderMetricsDidChange` 在排序键为 `.size` 时重排，否则只重绘。

## 4. 验证

- `cd app && swift build`：干净，无新增警告。
- `SortColumnSizesSmokeTests`（`checkPrefix` = `sort/columns/sizes: `）在 `SmokeTest.run` 的 `steps` 中注册，
  fixture 位于 `$TMPDIR/tursora-sort-columns-sizes-<UUID>`，不触碰用户文件或偏好设置。覆盖：
  - 纯比较器：三个日期键的相等、`nil`、方向、名称回落与严格性。
  - 措辞：`0 items` / `1 item` / `7 items`、字节格式与文件一致。
  - 菜单：View ▸ Sort By 的七项与 rawValue、Folder View Settings 的 "Calculate all sizes"、可选列的 Finder 顺序。
  - 持久化：列集合与 `calculateAllSizes` 经 `DirectoryViewPropertiesStore` 往返；旧版本文档（无新键）回落默认；
    未知排序键回落 Name；重复列去重。
  - 计算器：条目数（跳点文件、含符号链接）、递归字节（跳符号链接、含隐藏字节、下钻子目录）、
    ZIP / 搜索只算条目数、取消后不投递且不重排、`reset()`。
  - 真实列表：表头菜单条目与对勾、勾选/取消列、每目录记忆与"恢复默认"、Size 列的 "N items" 文本、
    打开计算后异步出现的字节数与 Size 排序的重排、导航离开后不把旧目录的行留下、拆分窗格各自独立的列集合。
  - 两种视图：详情与图标都按三个新键（升/降）排序，文件夹恒在前。
- 计算机视觉（computer-use）检查：**未进行**。打包应用中的表头右键菜单外观、菜单对勾与实际列宽尚未人工看过。

## 5. 已知边界

- 递归大小按逻辑字节（`.fileSizeKey`）累加，不是磁盘占用；与文件行的大小口径一致，但和 Finder 简介里的
  "on disk" 数字会有差异。
- 一个 `FolderSizes` 只有一条串行队列：同一目录里若有超大子树，它后面的文件夹要排队。
- 缓存超过 4096 条整体清空，而不是按 LRU 淘汰。
- Version / Comments / Tags 三列未实现；列宽不持久化。
- `dateModified` 的 `nil` 语义保持旧行为（升序垫底、降序置顶），只有三个新键采用"两向垫底"。

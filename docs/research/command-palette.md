# 命令面板（Command Palette）

一个浮动搜索面板，对「全部应用命令 + 侧栏收藏 + 当前窗格的前进/后退历史目录」做模糊搜索，
回车执行。命令走应用自己的菜单项与响应链，文件夹条目导航当前活动窗格。

- 代码：`app/Sources/Tursora/Model/CommandPalette.swift`（纯函数）、
  `app/Sources/Tursora/UI/CommandPaletteController.swift`（面板与派发）
- 测试：`app/Sources/Tursora/CommandPaletteSmokeTests.swift`
- 菜单：View → `Command Palette…`，默认 ⇧⌘O

## 1. 证据

### 1.1 Finder 资源（本机 macOS 26.3 / 25D125）

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

同一文件里还有 `cmdRecentFolders:` / `cmdClearRecentFolders:` 两个选择器（第 193–194 行），
说明 **Recent Folders** 是 Finder 自己对「最近访问过的文件夹」这一列表的用词。
面板里历史目录分组因此取 `Recent Folders` 作为类别名，条目标题为 `Recent: <路径>`。

```
$ plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/Localizable.strings \
    | python3 -c "..."   # 仅命中
'Recents' = 'Recents'
```

`Recents` 是 Finder 侧栏里那个「最近使用」智能位置，与目录历史不是同一概念，未采用。

```
$ strings -a .../Base.lproj/MenuBar.nib | grep -i palette
134:runToolbarCustomizationPalette:
558:toggleTouchBarCustomizationPalette:
```

Finder **没有**命令面板这一功能，也没有可引用的标题。以下是**推断（inferred）**、非 Finder 证据：

- 菜单标题 `Command Palette…`：沿用编辑器/IDE 的通用叫法；省略号符合「会打开输入界面」的 macOS 惯例。
- 搜索框占位符 `Run a command or go to a folder`。
- 空结果文案 `No matching commands`。
- 收藏分组名 `Favourites`：与 `PlacesModel` 现有侧栏分组标题一致（本项目内部一致性，非 Finder 证据）。
- 条目标题 `Go to <名称>`：与 Go 菜单的 `Go to Folder…` 用词同源，但组合形式是推断的。

### 1.2 快捷键选择

- ⇧⌘P 已属于 View → `Show Previews`（`MainMenu.viewMenu`），不能复用。
- 现有默认绑定中 ⇧⌘O 空闲（`MainMenu` 内 ⇧⌘ 组合已占用 N/T/W/D/P/F/H/G/[/]/`.`）。
- ⇧⌘O 与 Xcode 的 "Open Quickly" 同键，属于**推断的**熟悉度理由，本机未安装 Xcode，无法取证。
- 该命令与其它命令一样注册进 `ShortcutCatalog`（id `menu.showCommandPalette`），
  因此可在「设置 → 快捷键」里自定义或清除。

### 1.3 与 macOS 自带菜单搜索的关系

Help 菜单本身已由 AppKit 提供系统级的菜单项搜索（输入后高亮对应菜单项）。
两者并不重复：系统搜索只能找到**菜单里**的项、只做前缀/子串匹配、且只能「指」给用户看；
命令面板还覆盖没有菜单项的目录类命令（File View 上下文键、窗口别名）、收藏与历史目录，
并做模糊排序、直接执行。系统菜单搜索保留不动。

## 2. 设计

### 2.1 模型层（纯函数，可无界面测试）

`FuzzyMatcher.match(_ query: String, in candidate: String) -> Match?`

- 子序列匹配；查询里的空白被忽略（`new f` 与 `newf` 等价），空查询以 0 分匹配全部。
- 打分：每个命中字符 +1；位于字符串开头 +16；位于词首（前一个字符是分隔符，或
  小写→大写、非数字→数字的边界）+8；与上一个命中相邻 +6；出现断裂每次 −3；
  首个命中越靠后，额外 −min(偏移, 6)。
- 权重的唯一硬约束：**前缀命中必定压过同样的词在后面出现**
  （16 − 8 = 8 > 最大首字符惩罚 6 之后仍有余量）。实测 `new`：
  `New Folder` = 31 > `Show New Item` = 18。
- 实现是 O(查询 × 候选) 的动态规划（断裂惩罚是常数，所以前一行只需维护跑动最大值），
  并回溯出命中字符的下标，供界面加粗高亮。

`PaletteEntry` 三类行：

| kind | id | title | category | shortcut |
|---|---|---|---|---|
| `.command` | `ShortcutCatalog` 的 id | 命令标题 | 目录层级（`File`、`View → Sort By` …） | `AppPreferences.shared.shortcuts` 里的**当前**绑定显示串 |
| `.favourite` | `favourite:<路径>` | `Go to <名称>` | `Favourites` | — |
| `.recent` | `recent:<路径>` | `Recent: <路径>`（home 缩写成 `~`） | `Recent Folders` | — |

`CommandPalette.filter` 排序：**先分数，再类别，再标题，最后 id**，保证结果与构建顺序无关。
面板自身的命令（`menu.showCommandPalette`）被排除在列表外。

### 2.2 界面层

- `CommandPaletteController` 每个窗口一个，随窗口控制器存活（静态表持弱 host，宿主释放即清理）。
- 面板是 `NSPanel` 子类，`canBecomeKey = true`（与 `CompletionPopup` 的非激活面板相反），
  这样键盘输入直接落进面板自己的搜索框。无边框 + `AdaptiveLayerView` 圆角，跟随父窗口外观。
- 尺寸按结果行数在 420–640 pt 宽之间伸缩，水平居中、竖直略偏上地盖在窗口上。
- 键：↑/↓ 循环移动，Return 执行，Esc 关闭。点击某行等同 Return。
- 不可用命令**照常列出但置灰**（含类别与快捷键），回车拒绝执行且面板不关闭。

### 2.3 执行路径

1. **打开面板时**（浏览窗口仍是 key）先整棵 `NSApp.mainMenu` 跑一次 `update()`，
   再逐条按 id 找到 `NSMenuItem`，在**浏览窗口的响应链上**显式解析 target
   （`item.target` → `window.firstResponder` 链 → 活动窗格 → 窗口控制器 → 窗口 → app delegate → NSApp），
   用 `validateMenuItem` / `validateUserInterfaceItem` 得到可用性快照。
   之所以显式解析而不依赖 key window：面板打开后自己就是 key window，
   `NSApp.targetForAction(_:to:from:)` 会走错响应链。
2. **执行时**先关闭面板（焦点交还文件视图），再重新校验一次，
   然后 `NSApp.sendAction(item.action, to: target, from: item)` —— 与从菜单栏点相同。
3. 目录类命令（`ShortcutCatalog` 里没有菜单项的：Rename/Quick Look/Cancel Opening Archive/
   Next-Previous Tab 别名/Zoom In 别名/Select Tab 1–9）走
   `CommandPaletteRunner.performContextual`，与 `ShortcutDispatcher.handle` 的分支一一对应。
4. 文件夹行调用 `browser.navigate(to:)`，作用于**当前活动窗格**（`tabs.current` = 当前标签页的活动窗格）。

因此：面板本身不碰文件系统；`New Folder` 之类的写操作仍旧经 `MainWindowController` →
`BrowserViewController` → `FileOperations`，撤销与 `DirectoryChanges.post` 也沿用原路径。

## 3. 边界与已知限制

- 模糊匹配只针对**标题**，不匹配类别名。输入 `sort` 找不到 `View → Sort By` 下的 `Name`。
- 历史目录取当前窗格 `NavigationHistory` 的前后各最多 12 条，去重并排除当前目录；
  这是**每个窗格**的历史，不是应用级的「最近打开」，关闭标签页后即消失。
- 收藏来自 `PlacesModel` 的 Favourites 分组；Locations（卷）没有进入面板。
- 行是在**打开面板的瞬间**快照的：面板开着时选择或标签页发生变化，
  置灰状态不会实时刷新（执行前会再校验一次，所以不会误执行已失效的命令）。
- 面板没有做匹配字符以外的图标与分组标题；命中字符只加粗，未着色。
- 无障碍只设置了搜索框的 label，行本身依赖 `NSTableView` 默认暴露。
- 未做「最近使用过的命令」排序记忆。

## 4. 验证

### 4.1 已完成（自动化）

本分支在 e202c2e 基础上跑了一次完整 smoke（共享验证锁下、System Events 前置测试进程）：
`exit=0 ok=3511 fail=0`，其中命令面板自身 76 条。基线 e202c2e 为 3432 条，
新增 79 = 面板 76 + `ShortcutSmokeTests` 针对新命令的 clear/rebind/reset 3 条。
**按 AGENTS.md 还需连续三次通过后才可提交**，本记录只声明已跑通的这一次。


`CommandPaletteSmokeTests`（`checkPrefix = "command palette: "`），在 `SmokeTest.run` 的
`steps` 中紧接 `ShortcutSmokeTests` 之后运行：

- 纯匹配器：无匹配返回 nil、查询长于候选返回 nil、空查询 0 分、空白忽略、
  前缀压过中缀、大小写不敏感（双向）、词首压过词中、词首起跑压过埋在词里、
  带间隔的子序列下标、相邻优先的下标、缩写命中词首的下标。
- 纯条目表：排除面板自身命令、命令行携带类别与当前快捷键显示串、未绑定命令无快捷键、
  收藏变成 `Go to …`、历史变成 `Recent: …` 且 home 缩写成 `~`、重复历史去重、
  输入命令名排到第一、无匹配为空、空查询保留全部、同分按类别/标题排序。
- 目录注册：`menu.showCommandPalette` 是可自定义的 catalog 命令、默认 ⇧⌘O、
  `Show Previews` 仍是 ⇧⌘P、View 菜单里存在对应菜单项、没有别的命令占用 ⇧⌘O。
- 真实面板（**列表视图与图标视图各跑一遍**）：面板作为子窗口打开、初始查询为空且列出全部行、
  收藏行与侧栏 Favourites 一致、当前窗格历史出现在 Recent 行、
  输入过滤后选中目标命令并显示其快捷键、↑/↓ 移动与回位、
  Return 执行并关闭面板、焦点回到文件视图、`New Folder` 在活动窗格目录里真的建出文件夹、
  目录行按路径选中并导航活动窗格、Esc 关闭且什么都没执行、
  不可用命令被列出但置灰且回车拒绝执行（面板保持打开、没有多开标签页）、
  点击式执行到达活动窗格（Show Hidden Files 切换）、收藏行经同一 runner 导航活动窗格。
- 分屏：右窗格为活动窗格时 `New Folder` 建在右窗格、左窗格不受影响；
  切换活动窗格后目标随之改变。

夹具目录为 `$TMPDIR/tursora-command-palette-<UUID>`，用完删除；
不读写用户真实文件，也不写入 `favouritesOrder` 等真实偏好
（收藏导航用合成的 `PlacesModel.Place` 指向夹具目录）。

### 4.2 待完成

- **打包应用的可视检查尚未进行**：面板的实际外观（圆角、模糊、Light/Dark、加粗高亮、
  窄窗口下的宽度）以及真实键盘输入（输入法、⇧⌘O 触发）只在无头 smoke 中走过逻辑路径，
  没有截图证据。本记录不把它记作已完成。
- 未在多显示器 / 全屏窗口下验证面板位置。

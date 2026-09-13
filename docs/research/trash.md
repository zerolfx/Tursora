# 废纸篓：浏览、放回原处、清倒

记录 Trash 功能的 Finder 取证、实现边界、推断部分与验证状态。对应代码：
`app/Sources/Tursora/Model/TrashLocation.swift`、`Model/TrashOrigins.swift`、
`UI/TrashBrowser.swift`、`UI/LocationNotice.swift`、`TrashSmokeTests.swift`。

源提交：`c97013e`（feat: add batch rename, two-way terminal folder sync, and a
command palette）。

## 1. Finder 取证

全部取自本机 `/System/Library/CoreServices/Finder.app/Contents/Resources/`。
`.strings` 用 `plutil -convert json -o -` 读出，`.nib` 用 `strings` 扫描。

| 键 | 英文原文 | 用途 | 来源文件 |
|---|---|---|---|
| `A3` | `Empty Trash…` | File 菜单与右键菜单行（开启警告时带省略号） | `en.lproj/LocalizableMerged.strings` |
| `A15` | `Are you sure you want to permanently erase the items in the Trash?` | 清倒确认弹窗主文案 | 同上 |
| `A16` | `You can’t undo this action.` | 清倒确认弹窗说明文案 | 同上 |
| `N157` | `Empty Trash` | 确认弹窗的默认按钮 | 同上 |
| `N153.1` | `Put Back` | 右键菜单「放回原处」 | 同上 |
| `N153` | `Move to Trash` | 对照项，本次未新增 | 同上 |
| `N39` / `PW30` | `Trash` | 位置名称（边栏、状态栏语境） | 同上 |
| `TL_HELP_TCAN` | `Go to the Trash` | 工具栏提示，佐证「进入废纸篓」是一条独立导航 | 同上 |
| — | `Empty Trash`（`cmdEmptyTrash:` / `cmdEmptyTrashSilently:`） | 菜单项存在于 Finder 主菜单 | `Base.lproj/MenuBar.nib` |

复现命令：

```bash
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings \
  | python3 -c "import json,sys; d=json.load(sys.stdin); [print(k,'=',v) for k,v in d.items() if 'Trash' in str(v) or 'Put Back' in str(v)]"
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib | grep -i "trash"
```

`Put Back` 只出现在 `LocalizableMerged.strings`，没有任何 `.nib` 包含它：Finder 的
右键菜单是运行时构建的，因此这一行的**位置与分隔符归属属于推断**，文案本身有取证。

## 2. 推断部分（无 Finder 取证，明确标注）

以下文案与行为是 Tursora 自己的决定，Finder 中不存在对应物或未取到证据：

1. **访问被拒横幅**的全部文案：`Tursora doesn’t have permission to open “<名称>”.`、
   `Give Tursora Full Disk Access in Privacy & Security settings, then try again.`、
   按钮 `Open Privacy Settings` / `Try Again`。Finder 是系统文件管理器，永远有这个
   权限，不会显示此类横幅。
2. **Put Back 被禁用时的 tooltip** 三种理由文案（未知来源 / 原目录已消失 / 原名被占用）。
   Finder 只是把菜单行隐藏或置灰，不解释原因。
3. **Go ▸ Trash 菜单项**：Finder 的 Go 菜单没有 Trash（只在边栏提供）。Tursora 增加
   它是为了让键盘与命令面板也能到达该位置。
4. **File ▸ Empty Trash… 的快捷键 ⇧⌘⌫**：Finder 使用同一组合，但未在 `MenuBar.nib`
   的字符串中取到证据，按常识沿用。
5. **状态栏语境 `Trash`**：形式对齐既有的 `ZIP · Read-only`，Finder 状态栏无此写法。
6. **废纸篓内禁用哪些命令**：Finder 的实际表现（不能新建文件夹、粘贴、重命名、
   复制副本、压缩；可以拷贝、快速查看、显示简介、立即删除、放回原处、清倒）来自
   交互观察，不是资源取证。

## 3. 为什么自建 Put Back 日志

macOS 把 Finder 的「放回原处」路径写在废纸篓目录下 `.DS_Store` 的私有记录里，格式
未公开、无稳定 API。因此：

- Tursora **不解析 `.DS_Store`**。
- `FileOperations.trash` 本来就返回 `(original, trashed)` 配对，`TrashOrigins` 把它
  记进自己的 JSON 日志：`Application Support/Tursora/TrashOrigins.json`
  （冒烟运行改用 `$TMPDIR/tursora-trash-origins-smoke-<pid>-<uuid>/`；
  `TURSORA_UI_TEST_TRASH_ORIGINS_FILE` 可指定路径）。
- 写入走串行队列 + `Data.write(options: .atomic)`；读取失败、格式不符或版本不为 1 时
  **保留原文件不动**，与 `DirectoryViewPropertiesStore` 的策略一致。
- 条目在以下时机被移除：放回原处成功、清倒废纸篓、以及列出废纸篓时发现对应文件
  已不存在（`pruneMissing`）。上限 `entryLimit = 5000`，超出时丢弃最旧的条目。
- 由 Finder、shell 或其它应用移入废纸篓的项目**没有**日志条目，它们的「放回原处」
  被禁用并给出理由，绝不猜测来源。

`TrashOrigins.putBack(origin:parentExists:destinationOccupied:)` 是纯函数，规则是：
无条目 → `unknownOrigin`；原父目录不存在 → `missingParent`；原路径已被占用 →
`nameTaken`；否则 `available(原路径)`。父目录缺失优先于重名。

## 4. 路径规范化

`TrashLocation.canonicalPath` 用 `realpath(3)` 而不是 `URL.resolvingSymlinksInPath()`：

- Foundation 刻意**不**解析 `/tmp`、`/var`、`/etc`（它反方向归一，去掉 `/private`），
  实测 `URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path == "/tmp"`。
- `resolvingSymlinksInPath()` 只重写**已存在**的路径分量，条目刚被移走后其键就会
  改变，日志会对不上。

因此规范化的做法是：对最深的、存在的祖先调用 `realpath`，再把剩下的分量接回去。
`/tmp/a/b` → `/private/tmp/a/b`，`/tmp` → `/private/tmp`，而刚被移走的条目仍与录入
时同名。

## 5. 实现边界

- **只处理用户废纸篓**。`FileManager.url(for: .trashDirectory, in: .userDomainMask,
  appropriateFor: nil, create: false)`。`TrashLocation.volumeTrash(containing:)` 用
  `appropriateFor: <卷内 URL>` 解析卷级废纸篓（`/Volumes/X/.Trashes/501`），但**浏览、
  放回原处与清倒都不涉及卷级废纸篓**，边栏也只有一项 Trash。
- **注入点**：`TrashLocation.userTrashOverride`。设置后，`userTrash()`、`knownRoots()`、
  `volumeTrash(containing:)` 全部指向该目录，并且 `FileOperations.trash` 改为把项目
  移入该目录而不是调用 `FileManager.trashItem`——这保证任何检查都不会写进真实的
  `~/.Trash`。未设置时行为与原来完全一致。
- **清倒不可撤销**（与 Finder 一致），在后台队列上逐个 `FileManager.removeItem`，
  失败项通过 `FileOperations.report` 汇报。
- **放回原处的撤销**是把项目移回它在废纸篓中的**原路径**并恢复日志条目，而不是再次
  调用 `FileOperations.trash`——后者在注入了 fixture 废纸篓时会把项目送进真实的
  `~/.Trash`。重做再次还原。
- **拖出废纸篓**沿用既有的同卷移动规则。为此没有把废纸篓设成 `isReadOnly`（那会把
  拖拽强制降级为拷贝），而是给 `FileViewing` 增加了独立的 `allowsRenaming`。
- **列目录被拒**（本机 `ls ~/.Trash` 在没有完全磁盘访问权限时被拒，见
  `docs/gaps/GAP-vs-FINDER.md`）会在窗格内显示 `LocationNotice` 横幅，提供
  「Open Privacy Settings」（`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`）
  与「Try Again」。**永远不弹模态**；冒烟模式下只打印。判定条件是 `EPERM` / `EACCES`
  或 `NSFileReadNoPermissionError`（含 `NSUnderlyingErrorKey` 包装），`ENOENT` 不算。
- **清倒确认**通过 `BrowserViewController.emptyTrashConfirmation` 钩子注入；冒烟模式
  下先打印 A15 / A16 文案，再由钩子决定继续或取消（无钩子时继续）。

## 6. 废纸篓内的命令

| 命令 | 废纸篓内 | 依据 |
|---|---|---|
| New Folder / Paste / Compress / Extract | 禁用 | `canModifyCurrentLocation` 增加 `!isBrowsingTrash` |
| Rename / Duplicate / Cut / Move to Trash | 禁用 | `validateMenuItem` 与各命令入口的 `!isBrowsingTrash` 守卫 |
| 视图内的点按重命名 | 禁用 | `FileViewing.allowsRenaming`（两个视图都实现） |
| Copy / Copy Path / Quick Look / Get Info | 可用 | 不修改内容 |
| Delete Immediately… | 可用 | 仍走原有确认路径 |
| Put Back | 有日志且原父目录存在、原名未被占用时可用 | 见 §3 |
| Empty Trash… | 废纸篓非空时可用 | `canEmptyTrash` |

右键菜单在废纸篓内走独立分支 `trashContextMenu(for:into:)`，背景菜单为
Get Info / Empty Trash… / Reload / Show Hidden Files / Sort By。

## 7. 验证

`swift build` 无错误、无新增告警。

冒烟：新增 **130** 条 `trash: ` 检查，全部通过（
`smoke-run-trash-h-1.log`：`ok=2126 fail=1`）。覆盖：

- 纯函数：路径规范化（尾斜杠、符号链接前缀、点段）、根与后代判定、同前缀兄弟目录
  不误判、注入覆盖、权限错误判定、Finder 文案常量、Put Back 四种判定。
- 日志文件：录入/查询/遗忘/按根清空/清理失效条目、原子落盘与重新读取、条目上限。
- 两个视图（details 与 icons）各一轮完整 UI 流程：通过浏览器移入废纸篓 → 日志记录
  两个来源；第二个标签页也写入同一日志；进入废纸篓 → 列出条目 + 状态栏语境
  `Trash — …`；分屏第二窗格同样识别；过滤 `*.txt` + 按种类分组仍可用；禁用/可用命令
  逐条校验；右键菜单（条目与背景）内容校验；Put Back → 回到原路径、日志条目消失；
  ⌘Z → 回到废纸篓原路径且日志恢复；重做再次还原；三种禁用理由（未知来源、原名被
  占用、原父目录消失）；被拒的 Put Back 不移动任何文件；清倒取消不动任何条目；
  清倒确认后目录清空、日志清空、菜单项置灰；离开废纸篓后恢复常规规则。
- 访问被拒：`chmod 000` 后进入废纸篓 → 显示横幅、无模态、窗格内挂载；
  `chmod 700` + Try Again → 列表恢复。

**尚未通过的一项（与本功能无关）**：`shortcuts: native menu resolves the owned
active pane`。该检查要求测试进程成为 macOS 的活动应用；本次会话中
`osascript … set frontmost` 返回 0，但随即被 Claude 桌面应用抢回前台
（`get name of first process whose frontmost is true` → `Claude`），于是
`NSApp.isActive == false`、无 key/main 窗口。这与
`memory/smoke-test-needs-frontmost.md` 记录的已知限制一致，在该环境条件消失前无法
取得整轮 exit=0。本功能的 130 条检查在同一轮中全部通过。

**尚无计算机使用（computer-use）证据**：未对打包后的 `Tursora.app` 做人工观察，
横幅、菜单与边栏的实际外观仍待验证。

## Empty Trash 的快捷键：为什么默认不绑定

Finder 的 `Empty Trash…` 是 ⇧⌘⌫。本机用独立 AppKit 程序（`NSMenu` + 合成 `NSEvent`，keyCode 51 = kVK_Delete）实测得到：

| 菜单项键等价 | 事件 | `performKeyEquivalent` |
|---|---|---|
| ⇧⌘ + `\u{8}` | ⌘ + `\u{8}` | **true**（误配） |
| ⌘ + `\u{8}` | ⇧⌘ + `\u{8}` | **true**（误配） |
| ⌥⌘ + `\u{8}` | ⌘ + `\u{8}` | false（正确区分） |
| ⌘ + `a` | ⌘ + `\u{8}` | false |

即 AppKit 对 `⌫` 这类非字母键等价忽略 Shift，但不忽略 Option。后果有两层：

1. 默认菜单顺序里 `Move to Trash`（⌘⌫）在 `Empty Trash…` 之前，`performKeyEquivalent` 取第一个匹配项，所以按 ⇧⌘⌫ 实际命中的是 Move to Trash——Finder 键位一致性本来就拿不到。
2. 用户一旦在 Settings ▸ Shortcuts 清掉 Move to Trash 的绑定，普通 ⌘⌫ 就会命中 `Empty Trash…`，而清倒**不可撤销**。

因此该命令默认不带键等价（[D74](../DECISIONS.md)），仍留在快捷键目录中供用户自行指定。`TrashSmokeTests.menuBinding()` 同时断言「菜单项无键等价」和「AppKit 仍然忽略 Shift」，后者一旦在未来的 macOS 上变化，检查会失败并提示可以重新评估这条决策。没有改写 `ShortcutMenu` 的全局匹配逻辑：为一个命令改变所有菜单的分发路径，风险大于收益。

这一项由整合阶段发现：合并后的 smoke 在 `shortcuts: physical Backspace cannot dispatch the Forward Delete binding` 失败，追查到新增的 ⇧⌘⌫ 绑定。

# 批量重命名（Finder「Rename Finder Items」对标）

适用范围：多选（≥ 2 项）后的批量重命名。单选的行内重命名（`Return`、点击名称延时进入）不变。

本记录给出 Finder 资源提取证据、模型与界面设计、明确的边界，以及本次实现的验证阶段。凡未能从 Finder 自身资源中取到的措辞或数值，均在下文标注**推断**。

## 1. Finder 证据

提取环境：macOS 26.3（Darwin 25.3.0），`/System/Library/CoreServices/Finder.app`。

### 1.1 窗口 nib

```bash
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/BulkRenameWindow.nib | sort -u
```

可见字符串（界面标签）：

| 字符串 | 用途 |
|---|---|
| `Rename Finder Items:` | 窗口标题 / 首行标签 |
| `Replace Text` | 模式（同时是控制器类名的一部分） |
| `Find:` / `Replace with:` | 替换模式的两个字段 |
| `Name Format:` | 格式模式的下拉标签 |
| `Name and Index` / `Name and Counter` / `Name and Date` | 格式模式三种编号方式 |
| `Custom Format:` | 格式模式的自定义文本字段 |
| `Start numbers at:` | 起始编号字段 |
| `Where:` | 位置下拉标签 |
| `after name` / `before name` | 位置下拉的两个选项 |
| `Example: ^0` | 示例行（`^0` 是占位符） |
| `Rename` / `Cancel` | 两个按钮 |

同一 nib 中的辅助功能标题与 outlet 名称，说明控件构成：
`Find Text`、`Replace Text`、`Text To Add`、`Custom Format Text`、`Start Numbers At Text`、`Format Popup`、`Name Format Popup`、`Where Popup`；
`_findFld`、`_replaceFld`、`_textToAddFld`、`_customNameFld`、`_startIndexFld`、`_whereBtn`、`_nameFormatBtn`、`_exampleFld`、`_renameBtn`；
控制器类 `TBulkRenameController`、`TBulkRenameReplaceTextController`、`TBulkRenameAddTextController`、`TBulkRenameMakeSequentialController`、`TBulkRenameFormatterController`。

### 1.2 字符串表

```bash
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
```

| 键 | 值 | 用途 |
|---|---|---|
| `BR5` | `Replace Text` | 模式下拉项 |
| `BR3` | `Add Text` | 模式下拉项（nib 中只有 outlet，没有可见标签） |
| `BR1` | `Format` | 模式下拉项 |
| `ME22_V1` | `Rename…` | File 菜单（无选中项时的形态） |
| `ME22_V2` | `Rename “^1”` | File 菜单（单项） |
| `ME22_V3` | `Rename ^0 Items…` | **File 菜单复数项** |
| `RN17` | `The name “^0” is already taken. Please choose a different name.` | 重名 |
| `RN31` / `RN32` | `The name “^0” can’t be used.` / `Try using a name with fewer characters, or with no punctuation marks.` | 非法名称 |
| `RN1` / `RN2` | `Redo Rename` / `Undo Rename` | 撤销动作名 |
| `RN24` / `RN25` | `Rename` / `Cancel` | 按钮 |

Finder 主二进制中还存在 `BulkRenameStartIndex`、`BulkRenamePadAmount`、`BulkRenamePlaceNumberAt`、`BulkRenameAddTextTo`、`BulkRenameFindReplacePart`、`BulkRenameDateFormatStyle`、`BulkRenameDateSeparator`、`BulkRenameDatePosition` 等偏好键名（`strings -a MacOS/Finder`），说明各模式的参数项，但其默认值无法从字符串表读出。

### 1.3 明确标注为推断的部分

- **模式下拉的顺序与默认项**：`strings` 不保留 nib 的控件顺序。本实现采用 `Replace Text / Add Text / Format`，默认 `Replace Text`（nib 的初始第一响应者是文本字段 `_firstTextField`，与替换模式的 `Find:` 一致）。**推断**。
- **自定义文本与编号之间的分隔**：本实现用一个空格（`Custom 1`、`Custom 00001`、`Custom 2026-09-13 at 14.02.03`）。**推断**。
- **Counter 的位数 5**（`Custom 00001`）：`BulkRenamePadAmount` 说明位宽可配置，默认值未提取。**推断**。
- **日期戳格式** `yyyy-MM-dd at HH.mm.ss`（`en_US_POSIX`，本地时区）：冒号在文件名中非法，故时间用点分隔。**推断**。
- **同一批内日期戳相同**时的去重（追加 ` 2`、` 3`）：Finder 的处理未见文档。**推断**。
- `Add Text:` 字段标签：nib 只给出辅助功能标题 `Text To Add`。**推断**。
- `The name can’t be empty.`：Finder 无对应字符串，属 Tursora 自拟措辞。
- 预览表（`Current Name` → `New Name`）：Finder 的窗口没有预览列表；这是 Tursora 的增补，语义参考 Dolphin 批量重命名的即时列表。

## 2. 设计

### 2.1 模型（`Model/BatchRename.swift`，纯函数）

- `Mode`：`.replace(find:replacement:)`、`.add(text:position:)`、`.format(kind:custom:start:position:)`；`Position` = `.afterName` / `.beforeName`；`FormatKind` = `.nameAndIndex` / `.nameAndCounter` / `.nameAndDate`。
- `Entry`：目录 + 名称 + 日期。日期由调用方注入（测试可确定化），界面用条目的修改时间。目录用于把重名判断限定在条目自己的文件夹内 —— 搜索结果里的多项可能来自不同目录。
- `split(_:)`：扩展名 = 最后一个点之后的部分；点文件（`.profile`）整体算主名，末尾的点不算扩展名。
- `plan(_:mode:)` 按输入顺序返回每一项的新名称：
  - Replace Text 对**整个名称**（含扩展名）做全部替换，因此可以改扩展名；`Find` 为空时不变；
  - Add Text 只改主名，扩展名保留；
  - Format 用 `自定义文本 + 空格 + 编号/日期` 重写主名，扩展名保留；Index 不补零，Counter 补到 5 位且不截断宽数字，Date 用条目自身的日期。
- `validate(_:for:siblings:caseSensitive:)` 返回第一个问题：空名（`The name can’t be empty.`）、非法名（含 `/` 或 `:`、`.`、`..` → RN31 措辞）、批内重复或与**同目录**中不参与本批的既有项重名（RN17 措辞）。批次自身让出的名字不算占用，所以连锁（a→b 同时 b→c）、互换、以及只改大小写都通过；默认折叠大小写比较，`caseSensitive: true` 供大小写敏感卷使用。
- `menuTitle(count:)` 给出 `Rename` / `Rename N Items…`（ME22_V3）。

### 2.2 落盘（`Model/BatchRenameOperations.swift`，`FileOperations` 扩展）

`FileOperations.renameBatch(_:)` 接受 `(url, newName)` 列表：

1. 先整体校验名称，非法即抛出，**不动任何文件**；
2. 跳过名称未变的项；
3. 第一遍把每一项改名为同目录下唯一的临时名（`.tursora-rename-<UUID>`），第二遍再改成目标名。中间状态因此不可能互相占用，连锁与互换都成立；临时名让出了原名，只改大小写的重命名在 APFS 上也走普通 `moveItem`；
4. 任一步失败时，按相反顺序把已完成的改名全部退回，再把错误抛给调用方；
5. 返回按请求顺序排列的 `(from, to)`，供撤销重放。

`reverseRenameBatch(_:)` 用同一套两遍机制反向重放。`siblingNames(in:)` / `siblingNames(forEntries:)` 读取目录现有名称（含隐藏文件）供校验使用，界面本身不碰文件系统。

**为什么不用单项重命名的 `URLResourceValues.name`**：实测（本地一次性脚本）用它把 `a.txt` 改成已存在的 `b.txt` **不会报错，会直接覆盖 `b.txt`**。批量重命名必须拒绝覆盖批外的同名项，所以这里改用 `FileManager.moveItem`（占用时返回 `NSCocoaErrorDomain 516`）；单选行内重命名保留原有实现（`FileOperations.rename`），因为它需要 APFS 上只改大小写的能力，且有独立的冲突前置检查。

### 2.3 界面（`UI/BatchRenameSheet.swift`、`UI/BatchRenameBrowser.swift`）

- `BatchRenameSheetController` 用 `beginSheet` 挂在 pane 所在窗口上，**不使用 `runModal`**，headless 运行也不会卡住。
- 布局按 Finder 自上而下：`Rename Finder Items:` + 模式下拉 → 当前模式的字段（替换：`Find:` / `Replace with:`；添加：文本 + `Where:`；格式：`Name Format:` / `Where:` / `Custom Format:` / `Start numbers at:`）→ `Example: <第一项的新名>` → 预览表 → 错误说明 + `Cancel` / `Rename`。`Name and Date` 时隐藏 `Start numbers at:`。
- 每次击键都重算：预览表逐行给出「旧名 → 新名」，校验失败时 `Rename` 变灰并就地显示原因（Finder 措辞）。`Cancel` 直接关闭。
- 入口：File ▸ Rename（多选时标题变为 `Rename N Items…`）、More（Actions）菜单的同一项、多选右键菜单的同一项。`Return` 与单项行内重命名走 `renameSelectionInline`，行为不变。
- 应用后由 `BrowserViewController` 负责：`FileOperations.renameBatch` → `registerUndoBatchRename`（整批一个撤销组，撤销按相反顺序改回）→ 保持选中（重命名过的按新 URL，未变的按原 URL）→ 每一对都 `DirectoryChanges.post(…, renamed:)`，其他 pane 与 Info 窗口据此跟随各自的条目。
- 列表视图与图标视图共用同一条路径（都通过 `FileViewing` 的选中项与 `select(urls:)`），分栏、多标签、过滤、分组与搜索结果都适用；搜索结果按 URL 重命名，不按行号。

## 3. 边界

- 不做 Finder 没有的递归重命名，也不提供把设置记住到下一次打开（Finder 的 `BulkRename*` 偏好键未实现）。
- 不提供 Finder 的扩展名变更警告（RN8/RN12）、点开头名称确认（RN3）、以及「另一操作进行中」（RN11）这类提示：这些属于单项重命名的对话框族，本次不引入模态。
- 只读 ZIP 页与归档条目不参与批量重命名；`canModifySelectedItems` 为假时菜单项不出现。
- 大小写敏感卷：校验支持 `caseSensitive`，但界面目前不探测卷的大小写敏感性，一律按折叠大小写校验（更严格，不会误覆盖）。
- 未做 Finder 的 `Rename “^1”`（ME22_V2）单项菜单措辞，单项仍是 `Rename`。

## 4. 验证阶段

本次改动（在独立 worktree 中，基于 `e202c2e`）：

- `swift build` 无错误、无新增警告。
- 完整 smoke test 用共享验证锁运行 **1 次**：`exit=0`，`ok=3572`，`fail=0`（基线 3432，本特性新增 137 条打印的检查）。日志：`scratchpad/smoke-run-batch-rename-b-1.log`。
- 新增 `BatchRenameSmokeTests`：纯函数覆盖三种模式、`split`、日期戳与同戳去重、全部校验规则（空名、非法字符、批内重复、跨目录同名、同目录冲突、连锁 / 互换 / 只改大小写）；`FileOperations.renameBatch` 覆盖连锁 a→b→c→d、互换、只改大小写、未变项跳过、被占用目标拒绝并整批回滚、非法名先行拒绝、隐藏文件计入同级名称；界面路径在 **details 与 icons 两种视图**各跑一遍：菜单复数措辞与启用、More 菜单、右键菜单、`Return` 不开表单、File ▸ Rename 挂出 sheet、预览随击键更新、三类校验就地提示、三种模式的预览、应用后磁盘名称 / 选中项 / 过滤与分组保持、另一个 pane 跟随、`⌘Z` 整批撤销、重做、再撤销、右键入口与 `Cancel`；搜索结果一节验证跨目录的冲突范围与撤销。
- **未做**：打包后 `Tursora.app` 的实机外观检查（本次无屏幕访问），因此 sheet 的实际排版、控件间距与深浅色表现尚无 computer-use 证据；按 AGENTS.md 规则，这属于待补的可视验证，不得当作已完成。

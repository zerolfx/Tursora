# Tursora — 功能规格（v1）

> Tursora 是用 Swift + AppKit 原生写的 macOS 文件管理器。它把 KDE Dolphin 里 Finder 没有或很弱的交互
> （地址栏横向跳转、每标签独立历史、分栏、缩放档位、过滤栏）搬到 macOS，界面形态则尽量照 Finder。
> 每一节都标了对标对象：**对标 Dolphin** 指语义照 Dolphin，**对标 Finder** 指形态、标签、措辞照 Finder，
> 而且 Finder 的部分只用 Finder 自己的资源（nib、字符串表）做依据，不靠记忆——见 [research/](research/)。
>
> 为什么不移植 Dolphin/KIO：[audit/PHASE-0-REPORT.md](audit/PHASE-0-REPORT.md)。决策记录：[DECISIONS.md](DECISIONS.md)。
> 还没做的：[gaps/](gaps/)、[ROADMAP.md](ROADMAP.md)。

## 0. 范围

**纯本地。** 不含 SFTP / SMB / WebDAV，不含 KIO、不含任何 KDE 依赖。文件后端走 `protocol FileProvider`，v1 只有 `LocalFileProvider`。

| 重点 | 为什么值得做 |
|---|---|
| **地址栏** | Finder 默认根本没有地址栏。Dolphin 的面包屑能**横向跳转兄弟目录**，这是效率差距最大的一处 |
| **标签页** | Finder 有，但没有"恢复关闭的标签""每标签独立历史"这些 |
| **快捷导航** | 侧边栏 + 后退/前进/上级 + 历史下拉 + 前往文件夹 |

明确不在 v1：紧凑视图、批量重命名、Spotlight 搜索、Finder 标签读写、版本控制集成、服务菜单、终端面板、远程协议。

## 1. 窗口、侧边栏与快捷导航（对标 Dolphin 的 Places + Finder 的侧栏）

**侧边栏**（`NSOutlineView`，source list 风格）：

```
Favourites
  🏠 fxlin
  🖥 Desktop
  📄 Documents
  ⬇︎ Downloads
  … 用户自定义（可拖入、可删、可重排；内置项同样可删可排，Reset 恢复）
Locations
  💽 Macintosh HD
  💾 外接卷（可推出）
```

| 操作 | 快捷键 |
|---|---|
| 后退 / 前进 | `⌘[` / `⌘]`，鼠标侧键 4/5，触控板双指/三指滑动 |
| 上一级 | `⌘↑` |
| 打开选中项 | `⌘↓`（`Return` 是重命名，见 [DECISIONS.md](DECISIONS.md) D3） |
| 前往文件夹… | `⌘⇧G`（进地址栏编辑） |
| 主目录 | `⌘⇧H` |
| 后退 / 前进按钮**长按**或右键 | 弹出历史列表，可跳多级 |

窗口标题跟活动 pane 的目录，副标题是 `~` 缩写路径，标题栏代理图标可拖、`⌘`-点击出路径菜单。状态栏显示"N items / N of M selected"，右侧是缩放滑块（Dolphin 的位置）。

## 2. 地址栏（对标 Dolphin，核心差异化）

```
  ◀  ▶  ▲   [ 🏠 fxlin ▸ Workspace ▸ Tursora ▸ app ]        🔍
                 └ 每段可点击          └ 点 ▸ 弹出该层兄弟目录
```

- 面包屑模式：路径每一段是独立按钮，点击直接跳转；**段间 `▸` 点开 = 该层级的兄弟目录列表**，可横向跳转。
- 点空白区 / `⌘L` / `⌘⇧G` → 切换为可编辑文本框；`Esc` 退回面包屑。
- 编辑模式：**行内补全**（补上的部分选中，继续打字即替换；Tab / → 接受）+ 候选列表面板（↑↓ 选、Return 接受并跳转、Esc 关、点击选）。补全跳过包（.app）。
- 路径过长时从**左侧**折叠，首段保留；过长的段压缩。
- 当前目录段高亮，非当前段 hover 才显示背景。

## 3. 标签页（对标 Dolphin）

| 交互 | 快捷键 |
|---|---|
| 新建 / 关闭 / 恢复关闭 | `⌘T` / `⌘W`（最后一个标签时关窗口）/ `⌘⇧T` |
| 下 / 上一个 | `⌃Tab` / `⌃⇧Tab`，`⌘⇧]` / `⌘⇧[` |
| 直达第 n 个 | `⌘1` … `⌘9`（`⌘9` = 最后一个） |
| 中键点击标签 | 关闭 |
| 中键 / `⌘` 双击文件夹 | 在后台新标签打开 |

- 每个标签独立持有：当前目录、导航历史、选中项、滚动位置、排序、过滤、分组、视图模式；分栏时两个 pane 各一套。
- 标签可拖拽重排；只有一个标签时标签栏自动隐藏。
- **文件拖到标签上**（同 Dolphin）：悬停 800 ms 自动切到该标签；放到标签上 = 放进该标签的当前目录（同卷移动 / 跨卷或 `⌥` 复制）；放到标签栏空白处 = 每个文件夹开一个后台新标签。
- 关闭再恢复标签：分栏状态与两个 pane 的历史一并恢复。

## 4. 分栏（对标 Dolphin）

结构与 Dolphin 一致（`DolphinTabWidget` → `DolphinTabPage` → primary/secondary `DolphinViewContainer`）：**标签在上层，每个标签下 1–2 个并排 pane**。

| 交互 | 行为 |
|---|---|
| `⌘⇧D` | 未分栏：在右侧打开第二个 pane（同一目录）并激活；已分栏：关闭**活动** pane（菜单项写明"关闭左/右 pane"） |
| 点任意 pane | 激活它；顶部 3 pt 强调色线标识活动 pane；地址栏、窗口标题、标签标题、侧边栏高亮、搜索框都跟活动 pane |
| `⌥⇥` | 焦点切到另一 pane |
| 右键文件夹 → 在新 pane 中打开 | 未分栏则拆分并显示该文件夹；已分栏则另一 pane 导航过去并激活 |
| `⌘⇧C` / `⌘⇧M`、右键 | 复制 / 移动到另一 pane |
| **拖动标签到内容区** | 拖到左 / 右三分之一（半透明高亮提示）松手 → 该标签变成当前标签的左 / 右 pane；中间区域松手 = 取消 |

## 5. 视图模式、缩放与预览（对标 Dolphin）

| | 列表（详细信息） | 图标 |
|---|---|---|
| 实现 | `NSOutlineView`，文件夹可就地展开（▸） | `NSCollectionView` 网格，仅顶层 |
| 缩放档位 | 16 / 22 / 32 / 48 / 64（行高随之 24→72） | 32 → 512 共 12 档 |
| 预览 | 图标 ≥ 32 时用 Quick Look 缩略图替代类型图标 | 同左（默认 64 起就有预览） |

- 切换：工具栏右侧 segmented、`⌘⌥1` 图标 / `⌘⌥2` 列表（`⌘1…9` 已归标签页）。
- 缩放：`⌘`+滚轮、触控板捏合、`⌘+` / `⌘-` / `⌘0`、状态栏右侧滑块。
- 预览开关 `⌘⇧P`；缩略图按 路径+尺寸+修改时间 缓存，只对可见项请求，无缩略图的类型记住不再重试。
- 模式与每种模式的缩放档位按 pane 记，最近一次作为新 pane 的默认值并持久化；新标签、新分栏和重启后的首个 pane 必须挂载对应模式的实际视图。
- 工具栏的视图按钮始终反映活动 pane；菜单或快捷键切换后立即同步，后台 pane 改变模式不影响当前工具栏。
- 图标视图：多选 / 框选、方向键、`Return` 重命名（预选主名）、`空格` Quick Look、拖放（拖到文件夹图标上 = 放进去）、右键菜单与列表一致。
- 排序：名称 / 修改日期 / 大小 / 种类，升降序；文件夹始终在前。

## 6. 文件操作（语义对标 Finder）

| 操作 | 行为 |
|---|---|
| `⌘C` / `⌘X` / `⌘V` | 剪切项半透明；剪切状态全局（一个标签剪、另一个标签贴）；粘贴到同目录 = 生成 " copy" 副本 |
| `⌘D` | 复制（Duplicate）："name copy.ext"、"name copy 2.ext" |
| 重命名 | `Return`；或点击已选中且唯一选中行的文字，等一个系统双击间隔后进入（双击、选择变化、指针位移超过拖动阈值、拖放会话开始或结束都会取消）。预选不含扩展名的部分；大小写-only 重命名在 APFS 上可用 |
| `⌘⌫` / `⌘⌥⌫` | 移到废纸篓（Finder 可见、可放回）/ 立即删除（确认） |
| 新建文件夹 `⌘⇧N` | "untitled folder"、"untitled folder 2"，创建后选中 |
| 拖放 | 同卷 = 移动，跨卷 = 复制，`⌥` = 复制；拖到自己所在目录或自身 = 无操作；可拖到 Finder、侧边栏收藏、标签、另一 pane；跨标签拖放 |
| Quick Look | `空格` / `⌘Y`，面板内方向键换项 |
| 撤销 / 重做 | 覆盖重命名、移动、复制、复制副本、废纸篓；每个操作自成一个撤销组，按窗口记 |
| Open With | 右键子菜单：默认程序在前，其余按名 |
| 其他右键项 | 在新标签 / 新窗口 / 另一 pane 中打开、复制 / 移动到另一 pane、在 Finder 中显示、复制路径、加入 / 移出收藏 |

状态栏在操作进行时转圈；错误用 sheet 报告（smoke test 模式下打印到标准输出）。

## 7. 冲突对话框（对标 Finder）

macOS 没有公开的 Finder 冲突对话框 API，自建但行为照 Finder：每个冲突问一次——**Keep Both**（默认，无损）/ **Skip**（多项时）/ **Stop** / **Replace**（破坏性样式），文件夹对文件夹多一个 **Merge**（递归合并，子冲突走同一策略）；多项冲突时有 **"Apply to all (N items)"** 复选框，勾选后其余冲突静默套用同一选择。正文给出两边的修改时间与大小并说明哪个更新。

## 8. 过滤（Finder 的形态，Dolphin 的语义）

UI 照 Finder：**工具栏右侧的搜索框**（`NSSearchToolbarItem`，窗口窄时收成放大镜图标），`⌘F` 聚焦；输入后工具栏下方出现**范围栏** `Filter:  [📁 当前文件夹]   N of M items`。Esc / ⓧ 清空并退出，焦点回列表；单纯点到别处**不会**取消过滤（同 Finder）。收窄成图标后 `⌘F` 展开，若未输入而焦点离开则自动缩回。
过滤语义照 Dolphin：不区分大小写子串，`*` / `?` 通配符，作用于当前 pane（含已展开的子目录）；按 pane 记，搜索框显示活动 pane 的过滤词；切换目录清空。

## 9. 分组（1:1 对标 Finder 的 Use Groups / Group By）

- 开关 **Use Groups** `⌃⌘0`；**Group By** 子菜单（View 菜单与工具栏 Group 按钮共用）：None `⌃⌘0` / Name `⌃⌘1` / Kind `⌃⌘2` / Application / Date Last Opened `⌃⌘3` / Date Added `⌃⌘4` / Date Modified `⌃⌘5` / Date Created `⌃⌘6` / Size `⌃⌘7` / Tags `⌃⌘8`。关掉再打开回到上次的键（首次为 Kind）。按 pane 记，最近值作为默认持久化。
- 列表视图：组头是整行、吸顶的 group row，不可选中（含框选）、无展开三角、始终展开；组内按当前排序；组里的文件夹仍可就地展开。图标视图：每组一节，吸顶组头。
- 分组规则（`Grouping.swift`，纯函数），标签取自 Finder 自己的字符串表（[research/finder-group-labels.md](research/finder-group-labels.md)）：Name 首字母，数字 / 符号归 `#` 排最后；Kind = Finder 的类别名（Applications / Documents / Folders / Images / Movies / Music / PDF Documents / Presentations / Spreadsheets / Text / Source code / HTML / AppleScript / Fonts / Contacts / Mail Messages / Webpages / Other Documents / Other——没有 Archives，压缩包归 Other），组按名称排序；Application = 默认打开程序名，文件夹归 Finder；日期 = Today / Yesterday / Previous 7 Days / Previous 30 Days / 今年内按月 / 更早按年，新的在前，**未来时间戳归 No Date**；Size = Folders 在前，其余按十进制数量级 "Under 1 KB" / "From 1 KB to 10 KB" / …，大的在前；Tags = 首个标签，无标签归 No Tags 排最后。
- 仍是推断：Size 的桶边界；Kind 组的排序；Date Last Opened 用访问时间近似 Spotlight 的 last-used；"Earlier" 这个键的用途。

## 10. 简介窗口（Get Info，对标 Finder）

- **Get Info** `⌘I`：每个选中项一个窗口（超过 10 项时只给一个汇总窗口）；没有选中时是当前文件夹本身。同一项再按 `⌘I` 只把已有窗口带到前面。**Show Inspector** `⌥⌘I`：单个浮动面板，跟随主窗口活动 pane 的选择（多选时显示汇总）。**Get Summary Info** `⌃⌘I`："Multiple Item Info"，Kind 写成 "2 documents, 1 folder"，Size 是总和。三个是同一菜单行的 ⌥ / ⌃ 备选项。
- 分区和标签取自 Finder 的 `InfoWindow*.nib`（[research/finder-menu-icons.md](research/finder-menu-icons.md)）：页眉（64 pt 图标、名字、大小、Modified）、**General:**（Kind / Size / Where / Created / Modified / Original（符号链接与别名）/ Version + Copyright（应用）/ Capacity + Available + Used + Format（卷）、Locked）、**More Info:**（Spotlight：Dimensions / Duration / Codecs / Authors / Page count / Where from / Last opened…）、**Name & Extension:**（可编辑，Return 或失焦提交，可撤销；Hide extension）、**Comments:**（Finder 的 `com.apple.metadata:kMDItemFinderComment` xattr，失焦、关窗或退出时保存）、**Open with:**（默认程序在前，其余按名，Other…；Change All… 先确认再改整个类型）、**Preview:**（`QLPreviewView`）、**Sharing & Permissions:**（owner / group / everyone 三行，Read & Write / Read only / Write only (Drop Box) / No Access，改的是 POSIX 位；文件夹的 x 位跟随读写，文件的 x 位不动；非本人所有的项只读）。每个分区可折叠，折叠状态按分区记住。
- Size 的写法照 Finder：文件 "6,148 bytes (8 KB on disk)"，文件夹 "8 KB on disk (6,148 bytes) for 2 items"，0 是 "Zero bytes"；文件夹在后台递归统计，中途刷新。Where 是 "Macintosh HD ▸ Users ▸ me"。日期是 long date + short time。
- 项目被删除时窗口自动关闭（Inspector 则换到当前选择）；项目被改名（本应用内：改名广播带 from/to；外部：按 inode 在父目录里找）时窗口跟着改标题，浏览 pane 的选择也跟着新名字。父目录有变化时整窗重建，但**正在输入名字或注释时不重建**，等编辑结束再补。每个分区记住自己对应的 URL，Inspector 换目标后迟到的 sheet / 点击不会作用到新目标上。Info 窗口能成为 key 但**永不成为 main**，所以 Inspector 和 Go 菜单继续跟着浏览窗口。
- v1 不做：Tags、Stationery pad、ACL、改 owner/group（需要提权）、Apply to enclosed items。
- 简介的各分区占满窗口宽度，分区标题和内容左右各留 16 pt；Preview 随窗口宽度拉伸，折叠后再展开仍保持宽度。

## 11. 目录监视（对标 KDirWatch）

每个 pane 用 FSEvents 监视当前目录（含就地展开的子目录），外部改动（Finder、终端、别的 pane / 窗口）在 ~0.5 s 内自动刷新，刷新**保留选中与滚动位置**（改名的项跟到新名字）。应用内文件操作完成后额外广播"目录已变化"（可带改名的 from/to），同 app 内其他 pane 与 Info 窗口立即刷新，不等 FSEvents。FSEvents 回报真实路径（`/private/var/…`），比对前两边都要解析符号链接。

## 12. 菜单与图标（对标 Finder）

菜单栏和右键菜单的条目带 SF Symbol，符号名取自 Finder 自己的 `MenuBar.nib`（New Folder = `folder.badge.plus`，Get Info = `info.circle`……，见 [research/finder-menu-icons.md](research/finder-menu-icons.md)）；nib 里没写明的少数几项用通用符号。菜单在代码里构建，无 nib。全部快捷键见 [SHORTCUTS.md](SHORTCUTS.md)。

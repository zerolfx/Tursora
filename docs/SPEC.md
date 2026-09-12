# Tursora — 功能规格（v1）

> Tursora 是用 Swift + AppKit 原生写的 macOS 文件管理器。它把 KDE Dolphin 里 Finder 没有或很弱的交互
> （地址栏横向跳转、每标签独立历史、分栏、缩放档位、过滤栏）搬到 macOS，界面形态则尽量照 Finder。
> 每一节都标了对标对象：**对标 Dolphin** 指语义照 Dolphin，**对标 Finder** 指形态、标签、措辞照 Finder，
> 而且 Finder 的部分只用 Finder 自己的资源（nib、字符串表）做依据，不靠记忆——见 [research/](research/)。
>
> 为什么不移植 Dolphin/KIO：[audit/PHASE-0-REPORT.md](audit/PHASE-0-REPORT.md)。决策记录：[DECISIONS.md](DECISIONS.md)。
> 还没做的：[gaps/](gaps/)、[ROADMAP.md](ROADMAP.md)。

## 0. 范围

应用图标：两块蓝色玻璃窗格组成抽象尾鳍，单层浅色背景铺满画布，不嵌套圆角底板。应用包提供 16–1024 px 的 macOS 图标尺寸。

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

窗口名称跟活动 pane 的目录（供 Window 菜单与辅助功能识别），标题栏隐藏名称且不再重复路径；目录位置由可编辑地址栏显示。侧栏按钮固定在工具栏最左端，折叠不移动窗口；侧栏和内容区共用平直接缝，仅外窗保留圆角。Favorites 图标统一使用 18 pt 图像区域。状态栏显示"N items / N of M selected"，右侧是缩放滑块（Dolphin 的位置）。

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

- 每个标签独立持有当前目录、导航历史、选中项、滚动位置和过滤；分栏时两个 pane 各一套。模式、排序、缩放、分组、隐藏和预览按 §5 的目录策略保存并在进入目录时恢复。
- 标签可拖拽重排；只有一个标签时标签栏自动隐藏。
- **文件拖到标签上**（同 Dolphin）：悬停 800 ms 自动切到该标签；放到标签上 = 放进该标签的当前目录（同卷移动 / 跨卷或 `⌥` 复制）；放到标签栏空白处 = 每个文件夹开一个后台新标签。
- 关闭再恢复标签：分栏状态与两个 pane 的历史一并恢复。
- 新 pane 等父控制器接好回调后才执行初始导航；若这期间已经明确选择另一位置，迟到的初始导航不能将其覆盖。

## 4. 分栏（对标 Dolphin）

结构与 Dolphin 一致（`DolphinTabWidget` → `DolphinTabPage` → primary/secondary `DolphinViewContainer`）：**标签在上层，每个标签下 1–2 个并排 pane**。

| 交互 | 行为 |
|---|---|
| 工具栏 Split View / `⌘⇧D` | 未分栏：在右侧打开第二个 pane（同一目录）并激活；已分栏：关闭**活动** pane（菜单项与按钮 tooltip 写明 Close Left / Right Pane） |
| 点任意 pane | 激活它；顶部 3 pt 强调色线标识活动 pane；地址栏、窗口标题、标签标题、侧边栏高亮、搜索框都跟活动 pane |
| `⌥⇥` | 焦点切到另一 pane |
| 右键文件夹 → 在新 pane 中打开 | 未分栏则拆分并显示该文件夹；已分栏则另一 pane 导航过去并激活 |
| `⌘⇧C` / `⌘⇧M`、右键 | 复制 / 移动到另一 pane |
| **拖动标签到内容区** | 拖到左 / 右三分之一（半透明高亮提示）松手 → 该标签变成当前标签的左 / 右 pane；中间区域松手 = 取消 |

工具栏的分栏按钮显示当前标签的分栏状态，切换标签或激活另一 pane 后立即同步选中态与关闭目标；按钮收进溢出菜单后仍执行同一动作。侧栏地点的 Open in Other Pane 将该地点交给另一 pane；未分栏时创建第二个 pane，已分栏时导航另一 pane 并激活，不改变原 pane 的目录。侧栏菜单的 Open in New Tab 与 Open in Other Pane 捕获实际右键地点，不依赖点击结束后的行号，也不先导航原 pane；右键分区标题或空白处无菜单。

## 5. 视图模式、缩放与预览（对标 Dolphin）

| | 列表（详细信息） | 图标 |
|---|---|---|
| 实现 | `NSOutlineView`，文件夹可就地展开（▸） | `NSCollectionView` 网格，仅顶层 |
| 缩放档位 | 16 / 22 / 32 / 48 / 64（行高随之 24→72） | 32 → 512 共 12 档 |
| 预览 | 图标 ≥ 32 时用 Quick Look 缩略图替代类型图标 | 同左（默认 64 起就有预览） |

- 切换：工具栏右侧 segmented、`⌘⌥1` 图标 / `⌘⌥2` 列表（`⌘1…9` 已归标签页）。
- 缩放：`⌘`+滚轮、触控板捏合、`⌘+` / `⌘-` / `⌘0`、状态栏右侧滑块。
- 预览开关 `⌘⇧P`；缩略图按 路径+尺寸+修改时间 缓存，只对可见项请求，无缩略图的类型记住不再重试。
- 模式、排序字段与升降序、列表和图标各自的缩放档位、分组字段及上次启用字段、隐藏文件和预览开关按目录策略持久化。离开返回、新标签、新分栏以及重启后再次打开同目录均恢复；无记录目录使用独立保存的默认值。新 pane 必须挂载对应模式的实际视图。
- 工具栏的视图按钮始终反映活动 pane；菜单或快捷键切换后立即同步，后台 pane 改变模式不影响当前工具栏。
- 图标视图：多选 / 框选、方向键、`Return` 重命名（预选主名）、`空格` Quick Look、拖放（拖到文件夹图标上 = 放进去）、右键菜单与列表一致。
- 排序：名称 / 修改日期 / 大小 / 种类，升降序；文件夹始终在前。
- 列表名称列最小宽度为 180 pt，窄分栏仍为文件名保留空间，不让日期、大小和种类列将其挤到无法辨认。
- Settings 的 Show all filename extensions 默认开启；关闭后，列表 / 图标中的文件和包名称隐藏最后一段扩展名，普通文件夹名不变。只改变标签显示；过滤、排序、路径与重命名仍使用完整真名。新旧窗口、各标签和分栏同步更新。

### 每目录记忆与统一默认

- 默认 **Remember Each Folder**（每目录记忆）；Settings 的 **Folder View Settings** 与 **View → Folder View Settings** 都能切到 **Use One View for All Folders**（统一默认）。切换统一策略使用已有默认值，不自动把当前 pane 提升为默认。切回每目录策略保留此前目录记录。
- **Use Current Settings as Default** 主动保存当前目录的整套设置为默认；已有定制目录保留定制，无记录目录跟随新默认。**Restore This Folder to Default** 删除当前目录定制，立即使用默认，以后继续跟随默认；仅每目录策略下的普通目录可用。
- 每目录策略的普通修改不实时改变另一已打开的同目录 pane；另一 pane 再次进入目录才读取最新记录。两个 pane 都主动修改时，最后一次修改的整套属性成为保存值。策略切换、默认修改和恢复默认会同步受影响的已打开普通目录 pane；统一策略下普通修改更新共同默认。
- 过滤文字、选中项、滚动位置和历史不写入目录记录，也不传给新标签或另一 pane。恢复属性不反向保存、不重复导航；属性从内存库在列表加载前读取，异步列表和归档加载继续用导航代次阻止 A 的迟到结果覆盖 B。菜单、工具栏模式与分组状态、排序箭头和缩放滑块跟随恢复后的活动 pane。
- 保存库位于 `~/Library/Application Support/Tursora/DirectoryViewProperties.json`，不向浏览目录写 `.directory`、`.DS_Store` 或 xattr，不要求该目录可写。v1 JSON 分开保存策略、默认值和目录记录；连续修改合并写入并原子替换，应用退出时等待待写数据完成。未支持版本或损坏文件回退到可用默认，读入和无修改的退出不覆盖原文件；之后实际修改才替换为当前格式。单个已知字段错误回退为工厂值，缩放越界夹到有效档位，坏目录记录单独跳过。保存失败不阻止当次操作；Settings 内联显示失败原因和 Retry Saving View Settings，重试成功后清除错误，无模态提示。
- 普通本地 file URL 使用规范化并解析 symlink 的绝对路径键；忽略尾斜杠、query 和 fragment，不主动把大小写全部折叠。非本地主机的 file URL 与非 file URL 无目录键。导航时固定本次键，之后修改使用此键；symlink 改指新目标后，刷新 / Reload 识别键变化，清除旧目标的过滤、选择、滚动及待处理改名，再恢复新目标设置。枚举目录时解析 symlink，条目和历史仍保留请求路径的拼写。当前浏览器不会自动解析 Finder alias；只有调用者已给出目标目录时才共享目标记录。重命名或移动后按新路径查找，不追踪 inode；旧路径复用、卷复用同一挂载点可能继承旧记录，同卷换挂载点则不跟随。
- ZIP 与搜索等逻辑页不持久化。ZIP 每次导航进入根或内部目录都采用当时默认，当次修改只影响该 pane；已打开逻辑页不响应普通目录策略 / 默认通知。不能将 ZIP 的逻辑地址或临时解压路径写入目录库，也不能从逻辑页将当前设置保存为默认。归档原有只读操作边界不变，搜索页仍未实现。
- 本功能不恢复上次窗口、标签或历史，不递归向子目录应用设置，不提供 Finder 的完整 Show View Options 对话框。Dolphin 固定源码依据与存储取舍见[每目录视图研究](research/directory-view-properties.md)；最终自动与实机验证状态见 [HANDOFF](HANDOFF.md)。

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

UI 使用**工具栏右侧的名称过滤框**（`NSSearchToolbarItem`，标为 `Filter by Name`，窗口窄时收成放大镜图标），默认 `⌘F` 聚焦（可在 Settings 自定义）；输入不会额外展开范围栏，匹配数量在底部状态栏显示。当前只过滤本目录，不递归搜索子目录或文件内容；与 Dolphin 的独立搜索功能区分，见 [对照记录](research/dolphin-filter-search.md)。Esc / ⓧ 清空并退出，焦点回列表；单纯点到别处**不会**取消过滤（同 Finder）。收窄成图标后同一过滤快捷键展开，若未输入而焦点离开则自动缩回。
过滤语义照 Dolphin：不区分大小写子串，`*` / `?` 通配符，作用于当前 pane（含已展开的子目录）；按 pane 记，搜索框显示活动 pane 的过滤词；切换目录清空。

从 Favorites 导航后，即使焦点仍在侧栏，工具栏和 View 菜单的 Group By / Use Groups 仍作用于活动 pane。

## 9. 分组（1:1 对标 Finder 的 Use Groups / Group By）

- 开关 **Use Groups** `⌃⌘0`；**Group By** 子菜单（View 菜单与工具栏 Group 按钮共用）：None `⌃⌘0` / Name `⌃⌘1` / Kind `⌃⌘2` / Application / Date Last Opened `⌃⌘3` / Date Added `⌃⌘4` / Date Modified `⌃⌘5` / Date Created `⌃⌘6` / Size `⌃⌘7`。关掉再打开回到上次的键（首次为 Kind）；分组与上次字段一起按 §5 的目录策略保存。
- 列表视图：组头是整行、吸顶的 group row，不可选中（含框选）、无展开三角、始终展开；组内按当前排序；组里的文件夹仍可就地展开。图标视图：每组一节，吸顶组头。
- 分组规则（`Grouping.swift`，纯函数），标签取自 Finder 自己的字符串表（[research/finder-group-labels.md](research/finder-group-labels.md)）：Name 首字母，数字 / 符号归 `#` 排最后；Kind = Finder 的类别名（Applications / Documents / Folders / Images / Movies / Music / PDF Documents / Presentations / Spreadsheets / Text / Source code / HTML / AppleScript / Fonts / Contacts / Mail Messages / Webpages / Other Documents / Other——没有 Archives，压缩包归 Other），组按名称排序；Application = 默认打开程序名，文件夹归 Finder；日期 = Today / Yesterday / Previous 7 Days / Previous 30 Days / 今年内按月 / 更早按年，新的在前，**未来时间戳归 No Date**；Size = Folders 在前，其余按十进制数量级 "Under 1 KB" / "From 1 KB to 10 KB" / …，大的在前。
- 仍是推断：Size 的桶边界；Kind 组的排序；Date Last Opened 用访问时间近似 Spotlight 的 last-used；"Earlier" 这个键的用途。

## 10. 简介窗口（Get Info，对标 Finder）

- **Get Info** `⌘I`：每个选中项一个窗口（超过 10 项时只给一个汇总窗口）；没有选中时是当前文件夹本身。同一项再按 `⌘I` 只把已有窗口带到前面；Get Info 与汇总窗口以标准化后的 URL 比较已有目标，避免路径表示差异产生重复窗口。**Show Inspector** `⌥⌘I`：单个浮动面板，跟随主窗口活动 pane 的选择（多选时显示汇总）。**Get Summary Info** `⌃⌘I`："Multiple Item Info"，Kind 写成 "2 documents, 1 folder"，Size 是总和。三个是同一菜单行的 ⌥ / ⌃ 备选项。
- 分区和标签取自 Finder 的 `InfoWindow*.nib`（[research/finder-menu-icons.md](research/finder-menu-icons.md)）：页眉（64 pt 图标、名字、大小、Modified）、**General:**（Kind / Size / Where / Created / Modified / Original（符号链接与别名）/ Version + Copyright（应用）/ Capacity + Available + Used + Format（卷）、Locked）、**More Info:**（Spotlight：Dimensions / Duration / Codecs / Authors / Page count / Where from / Last opened…）、**Name & Extension:**（可编辑，Return 或失焦提交，可撤销；Hide extension）、**Comments:**（Finder 的 `com.apple.metadata:kMDItemFinderComment` xattr，失焦、关窗或退出时保存）、**Open with:**（默认程序在前，其余按名，Other…；Change All… 先确认再改整个类型）、**Preview:**（`QLPreviewView`）、**Sharing & Permissions:**（owner / group / everyone 三行，Read & Write / Read only / Write only (Drop Box) / No Access，改的是 POSIX 位；文件夹的 x 位跟随读写，文件的 x 位不动；非本人所有的项只读）。每个分区可折叠，折叠状态按分区记住。
- Size 的写法照 Finder：文件 "6,148 bytes (8 KB on disk)"，文件夹 "8 KB on disk (6,148 bytes) for 2 items"，0 是 "Zero bytes"；文件夹在后台递归统计，中途刷新。Where 是 "Macintosh HD ▸ Users ▸ me"。日期是 long date + short time。
- 项目被删除时窗口自动关闭（Inspector 则换到当前选择）；项目被改名（本应用内：改名广播带 from/to；外部：按 inode 在父目录里找）时窗口跟着改标题，浏览 pane 的选择也跟着新名字。父目录有变化时整窗重建，但**正在输入名字或注释时不重建**，等编辑结束再补。每个分区记住自己对应的 URL，Inspector 换目标后迟到的 sheet / 点击不会作用到新目标上。Info 窗口能成为 key 但**永不成为 main**，所以 Inspector 和 Go 菜单继续跟着浏览窗口。
- v1 不做：Stationery pad、ACL、改 owner/group（需要提权）、Apply to enclosed items。
- 简介的各分区占满窗口宽度，分区标题和内容左右各留 16 pt；Preview 随窗口宽度拉伸，折叠后再展开仍保持宽度。

## 11. 目录监视（对标 KDirWatch）

每个 pane 用 FSEvents 监视当前目录（含就地展开的子目录），外部改动（Finder、终端、别的 pane / 窗口）在 ~0.5 s 内自动刷新，刷新**保留选中与滚动位置**（改名的项跟到新名字）。应用内文件操作完成后额外广播"目录已变化"（可带改名的 from/to），同 app 内其他 pane 与 Info 窗口立即刷新，不等 FSEvents。FSEvents 回报真实路径（`/private/var/…`），比对前两边都要解析符号链接。

列表的滚动位置按内容的可见顶部保存，考虑系统列标题占用的空间；在顶部刷新、压缩 / 解压或撤销重做后，首行仍完整可见且可点击。列表缩短时将旧滚动位置限制在有效范围内。

## 12. 菜单与图标（对标 Finder）

菜单栏和右键菜单的条目带 SF Symbol，符号名取自 Finder 自己的 `MenuBar.nib`（New Folder = `folder.badge.plus`，Get Info = `info.circle`……，见 [research/finder-menu-icons.md](research/finder-menu-icons.md)）；nib 里没写明的少数几项用通用符号。菜单在代码里构建，无 nib。全部快捷键见 [SHORTCUTS.md](SHORTCUTS.md)。

## 13. 更多操作与分享

工具栏 More（三点）按活动 pane 的选择提供 New Folder、Open、Get Info、Quick Look、Rename、Duplicate、Compress、Extract、Copy、Paste、Move to Trash；空选择时仅目录级命令和可用的 Paste 保持启用，Rename 仅允许单选。菜单目标固定到窗口，由窗口分派给当前 pane，不受 Favorites 或地址栏焦点干扰。Share 为系统 `NSSharingServicePickerToolbarItem`，提供当前选择的文件 URL；支持列表 / 图标、多选、分栏与过滤，无选择时禁用。服务和接收方由用户在系统界面选择。

**设计边界**：不引入文件 Tags 的显示、读取、编辑或分组；不引入 Import from iPhone。现有磁盘标签不会被移除。证据与取舍见 [更多菜单对照](research/finder-actions-menu.md)。

## 14. ZIP 压缩与解压（对照 Finder）

- File、More 和文件右键菜单提供 Compress；单项生成 `原名.zip`（保留原扩展名），多项生成 `Archive.zip`，保存到当前浏览目录。
- ZIP 文件提供 Extract；实验性 ZIP 浏览关闭时（默认），打开 / 双击 ZIP 也在应用内解压。启用后的打开行为见 §18；在普通目录中选中 ZIP 时，显式 Extract 始终保留。多选 ZIP 按顺序处理。解压在原 ZIP 旁边输出：单根项目直接保留其名，多根项目放入以归档名命名的文件夹。
- 重名时依次加 ` 2`、` 3`，不会覆盖或合并已有内容；源文件和 ZIP 都保留。完成后刷新相关 pane，Compress / Extract 支持撤销与重做。
- 耗时工作放在后台，状态栏显示忙碌；失败报告错误，不发布半成品。系统归档工具在私有临时目录中处理内容，并保持路径 / 符号链接越界保护，保留资源叉与下载隔离属性。
- 当前仅支持普通 ZIP；密码归档与其他格式不属于本次实现。没有设置系统文件关联。

## 15. 服务器与挂载卷（对照 Finder）

- Go → Connect to Server…（`⌘K`）接受 SMB / CIFS、NFS、WebDAV HTTP(S) 和系统仍支持的旧式 AFP 地址。内联显示格式错误；不接受内嵌密码，由 macOS 的认证界面处理登录和共享选择。
- 只有 Connect 或在地址框按 Return 明确提交才启动连接；地址框失焦、点击 Cancel 不得开始新的挂载请求。失焦提交回归的修复验证状态见[本轮实机记录](research/computer-use-2026-09-12-inline-zip.md)。
- 通过系统 NetFS 异步挂载，连接成功后进入返回的本地挂载路径；不自行实现网络文件系统。网络卷自动出现在 Locations，显示网络图标，支持 Eject / 断开；可移动本地卷保留原有弹出行为。
- 关闭连接窗口会取消请求，不让过时回调导航窗口。SMB / WebDAV 等协议实际可用性取决于系统和服务器。
- 不提供 SSH / SFTP 后端、服务器发现、收藏服务器或断线重连。本次只验证地址、状态流转与卷策略；没有真实服务器地址，因此未进行远端读写测试。


## 16. 设置与过滤快捷键

- Tursora → Settings…（`⌘,`）打开应用级设置窗口，含 General / Folder View Settings / Keyboard / Experimental；修改立即生效并持久化。Folder View Settings 选择每目录记忆或统一默认，保存当前默认和恢复当前目录的入口在 View 菜单，语义见 §5。
- 名称过滤快捷键默认 `⌘F`。点击录制按钮后输入组合；要求 Command 或 Control，可加 Option / Shift，支持字母、数字和允许的标点。拒绝已有应用命令及常见系统组合；冲突内联提示，原绑定不变。Escape 取消录制，Reset 恢复 `⌘F`。
- 过滤仍是当前目录名称过滤，没有递归搜索或全文索引。扩展名显示只影响界面标签，不改文件名或 Finder 的逐文件 Hide extension 标记。
- Terminal panel 与 Browse ZIP archives 两个实验开关默认均关闭；启用终端开关只让入口可用，不自行启动 shell。
- 证据、允许的组合与持久化规则见 [设置对照](research/settings-and-shortcuts.md)。

## 17. 实验性终端面板

- 启用设置后，View → Show / Hide Terminal（`F4`）在浏览窗口底部展开 / 关闭终端。每个窗口最多一个终端，与该窗口的全部标签 / 分栏共用；面板高度可拖动。
- 使用 SwiftTerm 1.15.0 的原生终端视图与真实 PTY，启动当前用户的交互登录 shell；初始目录为打开面板时的活动目录；活动 pane 在 ZIP 内时，使用原 ZIP 所在目录，不在临时副本内启动或重启 shell。只有开关启用且面板实际显示时才启动进程。
- 浏览器导航、切换标签或 pane 只更新 Restart in Current Folder 的目标，不向现有 shell 注入 `cd`，也不根据终端输出驱动文件浏览器导航。
- Restart 明确结束当前 shell 及前台命令后，在目标目录启动新会话；检测到前台命令时确认。关闭面板（含 F4 收起）、禁用实验、关闭所属窗口或退出应用都会结束该会话，不保留后台终端。
- 本轮不提供多个终端标签、会话恢复或自动双向目录同步。

## 18. 实验性 ZIP 浏览

- 开关默认关闭；启用后，在普通目录 Open / 双击 ZIP 会进入当前 pane 的 ZIP 根目录，不再打开独立归档窗口。保留归档原始根结构，不自动省去单个顶层文件夹或添加包装层。
- 复用列表 / 图标视图、就地展开、分组、排序、缩放和当前目录名称过滤；过滤仍非递归搜索。地址栏与面包屑显示原 ZIP 路径及内部目录，例如 `/Downloads/Sample.zip/Notes`，不会显示临时路径。输入 ZIP 根或子目录可进入；输入归档内普通文件不会触发外部打开。
- Back / Forward、历史菜单、标签页和分栏按普通目录方式工作。Up 从内部目录回到上层；在 ZIP 根执行 Up 返回原 ZIP 所在目录并选中 ZIP。关闭标签页或离开归档不清理其副本，历史仍可返回。
- 所有归档目录只读：不能新建、重命名、剪切、粘贴、拖入、删除、创建 Duplicate 副本、压缩 / 解压内部项目或移动到另一 pane，也不提供可编辑的 Get Info / Inspector。Copy 与拖出只复制；可复制到普通目录或另一可写 pane。Quick Look、Share 和显式 Open 使用经过路径校验的临时副本。
- 状态栏显示简短的 `ZIP · Read-only`；tooltip 解释临时副本、外部编辑不回写与 Save As。没有额外范围栏或 Extract All 按钮；需要解压时返回普通目录选中原 ZIP，按 §14 使用 Extract。
- 首次打开在后台准备完整的私有解压副本，同一归档的 pane 共用会话。副本保留到 Tursora 退出，避免外部应用丢失正在使用的文件；修改不写回 ZIP，需要保留编辑结果时使用 Save As。
- 关闭实验开关后，已有归档页与历史仍可安全只读浏览，普通目录中新打开 ZIP 恢复默认解压。归档内嵌套 ZIP 的普通 Open 使用系统默认应用，不自动进入另一归档会话。仅支持普通 ZIP；密码、其他格式、归档写回与原 ZIP 外部改变后的自动重载不属于本次实现。实现与验证边界见 [归档浏览研究](research/archive-browsing.md)。

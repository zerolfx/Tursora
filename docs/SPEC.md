# Tursora — 功能规格（v1）

> Tursora 是用 Swift + AppKit 原生写的 macOS 文件管理器。它把 KDE Dolphin 里 Finder 没有或很弱的交互
> （地址栏横向跳转、每标签独立历史、分栏、缩放档位、过滤栏）搬到 macOS，界面形态则尽量照 Finder。
> 每一节都标了对标对象：**对标 Dolphin** 指语义照 Dolphin，**对标 Finder** 指形态、标签、措辞照 Finder，
> 而且 Finder 的部分只用 Finder 自己的资源（nib、字符串表）做依据，不靠记忆——见 [research/](research/)。
>
> 为什么不移植 Dolphin/KIO：[audit/PHASE-0-REPORT.md](audit/PHASE-0-REPORT.md)。决策记录：[DECISIONS.md](DECISIONS.md)。
> 还没做的：[gaps/](gaps/)、[ROADMAP.md](ROADMAP.md)。

## 0. 范围

Tursora 免费使用，项目源码按 MIT 许可证开放；README 和产品页显著展示免费、开源与许可证入口。第三方依赖保留各自许可，打包资源附项目许可。公开源码、可安装版本、自动化与实机验证分别记录，不把未发布的开发功能当作正式版本能力。

应用图标：两块蓝色玻璃窗格组成抽象尾鳍，浅色背景裁成单个圆角底板，四周与外角透明，不增加描边、外阴影或第二层底板。前景保持原比例与位置；1024 px 导出在四周各留 80 px，圆角半径 192 px，这是本应用的几何选择。应用包提供 16–1024 px 的 macOS 图标尺寸，`.icns` 自带透明轮廓，不依赖系统补做圆角。依据与验证状态见[图标边缘记录](research/app-icon-edges.md)。

**本地文件系统接口。** 文件后端走 `protocol FileProvider`，当前只有 `LocalFileProvider`，也能浏览 macOS 已挂载的卷。Connect to Server 通过系统 NetFS 挂载 SMB / NFS / WebDAV 等服务，详见 §15；没有自建 SFTP 后端、KIO 或 KDE 依赖。

| 重点 | 为什么值得做 |
|---|---|
| **地址栏** | Finder 默认根本没有地址栏。Dolphin 的面包屑能**横向跳转兄弟目录**，这是效率差距最大的一处 |
| **标签页** | Finder 有，但没有"恢复关闭的标签""每标签独立历史"这些 |
| **快捷导航** | 侧边栏 + 后退/前进/上级 + 历史下拉 + 前往文件夹 |

当前未实现：紧凑视图、批量重命名、Finder 标签读写、版本控制集成与服务菜单。终端面板和只读 ZIP 浏览默认启用，可在设置中关闭；远程连接仅使用系统挂载。

## 1. 窗口、侧边栏与快捷导航（对标 Dolphin 的 Places + Finder 的侧栏）

**Dock 右键菜单**：提供 New Window、Downloads 和 Applications。三者都新开窗口并激活应用，分别进入 Home、当前用户下载目录和系统应用目录，不改现有标签、分栏、过滤或搜索。标准窗口列表、Options、Hide / Quit 等由 macOS 提供；菜单选择及文案证据见 [Dock 记录](research/dock-menu.md)。

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

**Folders 目录树**：View → Show / Hide Folders 默认 `F7`（可自定义），在左侧 Places 下方展开独立目录树，两块面板之间可拖动高度。首次默认隐藏；打开时保留 Favorites / Locations，侧栏收起时先展开侧栏。树跟随活动标签与活动 pane，列表 / 图标、过滤、分组或搜索不会过滤树本身；ZIP 内跟随原 ZIP 所在目录，不展示临时副本。

- 单击文件夹导航当前活动 pane；右键捕获所点目录，提供 Open、Open in New Tab、Open in Other Pane。后者按既有规则创建或使用另一侧。拖入树节点走相同复制 / 移动任务和撤销链，视图不直接读写文件系统。
- 只显示可浏览文件夹，不列普通文件或包。后台按需读取一层子目录，跟随时只展开到目标的祖先链；不递归预扫整盘。加载错误在树底部内联显示，可 Refresh Folders 重试；关闭树或折叠侧栏停用监听与结果应用。
- 辅助功能读取树或查询可否展开不改变节点状态、不触发目录读取；只有实际展开操作和活动路径跟随才加载所需节点。展开 / 刷新完成后选中目录保持完整可见，手动查看其他分支时不被无关刷新强行拉回。
- 菜单提供 Show Hidden Folders（默认关）、Limit to Home Directory（默认开）与 Refresh Folders。限制 Home 时，活动位置位于 Home 内就以 Home 为根；位置在 Home 外仍切到 `/` 以便跟随。树的隐藏项目选项独立于文件 pane。为跟随 macOS 的 `/tmp` / `/var` 等系统别名，模型在后台解析真实路径并展示 `/private/...` 祖先；只为当前路径补入隐藏的 `/private` 根节点，不打开其他隐藏目录或改写该选项。
- 会话保存每窗口的树可见性、上下比例和这两个选项；节点展开集合不跨进程保存，重开时根据活动位置重新展开。Dolphin 的 Places / Folders 是独立面板；本实现选定左侧上下排列，没有任意停靠、浮动或面板锁定，见[目录树对照](research/folder-tree.md)。

## 2. 地址栏（对标 Dolphin，核心差异化）

```
  ◀  ▶  ▲   [ 🏠 fxlin ▸ Workspace ▸ Tursora ▸ app ]        🔍
                 └ 每段可点击          └ 点 ▸ 弹出该层兄弟目录
```

- 面包屑模式：路径每一段是独立按钮，点击直接跳转；**段间 `▸` 点开 = 该层级的兄弟目录列表**，可横向跳转。
- 点空白区 / `⌘L` / `⌘⇧G` → 切换为可编辑文本框；`Esc` 退回面包屑。
- 编辑模式：**行内补全**（补上的部分选中，继续打字即替换；Tab / → 接受）+ 候选列表面板（↑↓ 选、Return 接受并跳转、Esc 关、点击选）。补全跳过包（.app）。
- 路径过长时从**左侧**折叠，首段保留；过长的段压缩。
- 窄窗与分栏持续保留根目录、折叠路径入口及尾部目录菜单，必要时缩短文字；反复改变窗口尺寸不引发持续布局循环或阻塞导航。
- 当前目录段高亮，非当前段 hover 才显示背景。
- 每个 pane 的文件区上方都有自己的地址栏；分栏时两边路径同时显示并随各自宽度布局。点击路径、面包屑或补全先激活该 pane，跳转只改变它的目录。`⌘L` / `⌘⇧G` 编辑活动 pane 的路径。
- 切换 pane / 标签时收起离开侧的路径编辑和补全面板，不提交尚未确认的输入；已捕获的路径操作不能改为作用于新活动 pane。另一侧的路径、导航历史、过滤和搜索保持独立。

## 3. 标签页（对标 Dolphin）

| 交互 | 快捷键 |
|---|---|
| 新建 / 关闭 / 恢复关闭 | `⌘T` / `⌘W`（最后一个标签时关窗口）/ `⌘⇧T` |
| 下 / 上一个 | `⌃Tab` / `⌃⇧Tab`，`⌘⇧]` / `⌘⇧[` |
| 直达第 n 个 | `⌘1` … `⌘9`（`⌘9` = 最后一个） |
| 中键点击标签 | 关闭 |
| 中键 / `⌘` 双击文件夹 | 在后台新标签打开 |

- 每个标签独立持有当前目录、导航历史、选中项、滚动位置和过滤；分栏时两个 pane 各一套。模式、排序、缩放、分组、隐藏和预览按 §5 的目录策略保存并在进入目录时恢复。
- 标签栏使用中性底条、柔和选中面和居中标题，悬停显示关闭按钮且文字不位移；右侧固定新增入口。多标签保留可读宽度，溢出后横向滚动并提供全部标签文字菜单，选择后自动显示目标页。应用跟随系统亮 / 暗外观，运行中切换也刷新标签、补全面板、活动 pane 线和任务卡片边框；[设计依据与验证](research/tabs-and-appearance.md)。
- 标签可拖拽重排；标签栏始终显示，单页也可见分栏标题并使用右键菜单。这是 Tursora 的默认选择；Dolphin 提供是否自动隐藏的设置。
- 单 pane 标签显示目录名；搜索显示 `Search: <名称条件>`，没有名称条件则显示 `Search Results`。分栏按物理左右顺序同时显示两边，统一使用竖线分隔：`Left | Right`，切换活动侧不改标题标点；活动 pane 由内容区提示线标识。自定义标签名覆盖自动标题，清空后恢复；完整路径在 tooltip 中保留，ZIP 显示逻辑路径。
- **文件拖到标签上**（同 Dolphin）：悬停 800 ms 自动切到该标签；放到标签上 = 放进该标签的当前目录（同卷移动 / 跨卷或 `⌥` 复制）；放到标签栏空白处 = 每个文件夹开一个后台新标签。
- 关闭再恢复标签：分栏状态、两个 pane 的历史和自定义名称一并恢复。关闭后台标签或批量关闭时保留仍存在的活动页；活动页被关闭才选择相邻页。
- 新 pane 等父控制器接好回调后才执行初始导航；若这期间已经明确选择另一位置，迟到的初始导航不能将其覆盖。
- 启动时默认恢复上次工作区中的窗口、标签和分栏；完整范围、持久化与关闭开关的语义见 §22。运行中 `⌘⇧T` 恢复关闭页的完整对象，与退出后的新会话重建是两种独立行为。

标签右键菜单按 Dolphin 提供 **New Tab、Detach Tab、Rename Tab、Close Other Tabs、Close Tabs to the Left、Close Tabs to the Right、Close Tab**。命令目标固定为实际右键标签，不依赖菜单结束后的索引或当前页；右键本身不切页。无其他页时禁用 Close Other Tabs，左右边界分别禁用对应批量关闭项，最后一页 Close Tab 关窗口。

- **New Tab**：用目标标签活动 pane 的位置新建并激活单 pane 页；搜索重新执行其请求，不复制旧结果。`+` / `⌘T` 对当前标签执行同一行为；文件夹的 Open in New Tab 仍打开明确指定的目录。活动侧正在准备 ZIP 时禁用。
- **Detach Tab**：用目标标签一到两个逻辑位置在新窗口重新打开，然后关闭原页；保留左右顺序、活动侧、自定义名和搜索请求，不迁移导航历史、选区、过滤、滚动、文件任务或撤销栈。任一侧正在准备 ZIP 时禁用。文件任务继续属于原窗口；关闭原窗口仍取消其任务并等待清理。
- **Rename Tab**：只改标签名，不改磁盘目录名；空名称恢复自动标题。

固定源码、菜单顺序与设计边界见[分栏地址栏与标签操作](research/pane-paths-and-tab-actions.md)。

## 4. 分栏（对标 Dolphin）

结构与 Dolphin 一致（`DolphinTabWidget` → `DolphinTabPage` → primary/secondary `DolphinViewContainer`）：**标签在上层，每个标签下 1–2 个并排 pane**。

| 交互 | 行为 |
|---|---|
| 工具栏 Split View / `⌘⇧D` | 未分栏：在右侧打开第二个 pane（同一目录）并激活；已分栏：关闭**活动** pane（菜单项与按钮 tooltip 写明 Close Left / Right Pane） |
| 点任意 pane（含其地址栏） | 激活它；顶部 3 pt 强调色线标识活动 pane；两侧地址栏各自保留路径，窗口标题、侧边栏高亮和工具栏过滤框跟随活动 pane |
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
| 预览 | 图标 ≥ 32 时用内容缩略图替代类型图标 | 同左（默认 64 起就有预览） |

- 切换：工具栏右侧 segmented、`⌘⌥1` 图标 / `⌘⌥2` 列表（`⌘1…9` 已归标签页）。
- 缩放：`⌘`+滚轮、触控板捏合、`⌘+` / `⌘-` / `⌘0`、状态栏右侧滑块。
- 预览开关 `⌘⇧P`；缩略图按路径、点尺寸、屏幕倍率、修改时间和文件大小缓存，只对可见项请求，无缩略图的类型记住不再重试。缩放、重载、复用单元或关闭预览后，迟到的旧请求不能覆盖当前图标。
- 纯文本、源码、Markdown、JSON / XML 等显示文件开头的真实文字片段，采用 3:4 浅色纸面与 7–10 pt 等宽字；放大时增加可见内容，避免把整页文字缩到不可辨认。后台最多读取 64 KiB、排版 8,192 字符，支持 UTF-8 与带 BOM 的 UTF-16；不支持的格式 / 编码沿用 Quick Look，没有可用预览时回退类型图标。列表与图标视图使用同一路径；纸张作为文档内容在亮 / 暗主题均保持浅色，不做语法高亮。32 pt 仍以辨识文本类型为主，阅读更多内容可放大或使用 Quick Look；[对照与实现](research/text-thumbnails.md)。
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
- ZIP 与搜索结果视图不持久化。ZIP 每次导航进入根或内部目录都采用当时默认，当次修改只影响该 pane；搜索继承启动时 pane 的视图，搜索中改变模式、排序、缩放、分组、隐藏与预览只保留到退出搜索。两者均不响应普通目录策略 / 默认 / 重置通知，也不能将当次视图设为默认或重置来源目录。不能将 ZIP 逻辑地址或临时解压路径写入目录库；搜索保留来源目录上下文作返回用途，但不写其记录或统一默认。返回普通目录重新读取该目录当前保存值，归档只读操作边界不变。
- 目录视图库不负责恢复窗口、标签或历史；窗口和标签由 §22 的独立会话库恢复，导航历史仍不持久化。不递归向子目录应用设置，不提供 Finder 的完整 Show View Options 对话框。Dolphin 固定源码依据与存储取舍见[每目录视图研究](research/directory-view-properties.md)；最终自动与实机验证状态见 [HANDOFF](HANDOFF.md)。

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

复制、移动、Duplicate、剪贴板与拖放统一为独立文件操作任务；ZIP 只读页复制 / 拖出仍只读源归档，复制到可写目录时使用同一任务引擎。列表与图标模式共用入口，任务开始即固定源、目标与原窗口撤销栈，切换标签、pane、过滤和分组不会改变传输目标。

较长任务自动显示 **File Operations** 窗口，也可从 **Window → File Operations** 打开；快速失败也会自动显示，新的任务排在前面，冲突会滚动到对应任务。每项分别显示当前项目、已传输 / 总字节、传输速度、预计剩余时间和状态，并提供 Pause / Resume / Cancel。暂停须等工作线程确认后显示 Paused；单个大文件传输中也可以暂停和取消。字节数统计普通文件数据，资源叉、扩展属性等在元数据阶段完成；准备扫描时总量未知；同卷移动的原子改名、元数据收尾与发布阶段显示真实阶段，不提供虚构的字节进度和 ETA。

复制先写入目标卷的私有暂存，完整成功后才发布。Replace 在成功发布前保留原目标；取消 / 故障清理未完成的暂存，不把它列为成功项。跨卷移动仅在相应目标完成后移走相应源；目录合并按实际成功子项记录，不把既有目标目录整体算成新建或移动。完成、取消、部分完成、失败分别显示；撤销仅记录真实成功变更，保留 Replace 原目标以及跨卷移动的恢复内容，重做无需重新读取源文件。此恢复内容在撤销历史存续期间占用磁盘空间。若撤销 / 重做因路径身份变化等原因失败，恢复目录会保留到手动恢复或清理，错误提示给出路径；撤销动作被消费或窗口关闭也不会删除这些副本。跨卷移动的恢复副本或目标在任务后被修改时，撤销拒绝恢复旧内容；合并重做也不会移走后来新增的源目录子项。

关闭任务窗口仅隐藏界面，任务仍由应用持有；关闭发起的浏览窗口会取消其任务并等待清理，关闭标签不转移任务上下文；退出应用会取消全部传输并等工作线程停止写盘。原子重命名、废纸篓 / 立即删除及 ZIP Compress / Extract 的工具执行继续使用既有路径，不宣称可在中途暂停。状态栏保留忙碌指示；传输错误显示在任务中，其他操作仍使用既有错误提示（smoke test 模式下打印，不弹模态框）。

## 7. 冲突对话框（对标 Finder）

macOS 没有公开的 Finder 冲突对话框 API，自建但行为照 Finder：每个冲突问一次——**Keep Both**（默认，无损）/ **Skip**（多项时）/ **Stop** / **Replace**（破坏性样式），文件夹对文件夹多一个 **Merge**（递归合并，子冲突走同一策略）；多项冲突时有 **"Apply to all (N items)"** 复选框，勾选后其余冲突静默套用同一选择。正文给出两边的修改时间与大小并说明哪个更新。

传输任务的冲突以内联选择呈现在对应任务中，保留上述选择与批量策略；内联版本单项也可 Skip，不设置跨任务通用的 Return 默认按钮。等待决定时其他任务仍可控制，Cancel 会结束等待并清理，Stop 停止本批后续工作。任务界面的布局与状态文案是 Tursora 的设计，不宣称逐像素复刻 Finder 或 KIO；Dolphin 任务路由证据见[文件操作任务记录](research/file-operation-tasks.md)。

## 8. 过滤（Finder 的形态，Dolphin 的语义）

UI 使用**工具栏右侧的名称过滤框**（`NSSearchToolbarItem`，标为 `Filter by Name`，窗口窄时收成放大镜图标），默认 `⌘F` 聚焦（可在 Settings 自定义）。输入先过滤当前目录，匹配数量在底部状态栏显示；普通目录有输入后，在 pane 顶部显示 `Current Folder` 与 **Search Options…** 入口。打开选项才进入含子目录的搜索并展开详细条件，同一个工具栏输入框改为编辑名称搜索词；不再有独立工具栏 Search 按钮或第二个名称框。ZIP 保留本地过滤，不显示递归选项。Esc / ⓧ 清空并退出，焦点回列表；单纯点到别处**不会**取消非空输入。收窄成图标后同一过滤快捷键展开，若未输入而焦点离开则自动缩回。交互对照与设计边界见[搜索输入记录](research/search-input-reference.md)。
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
- 初始只展开 **General** 与 **Preview**，其余分区折叠，对齐本机 Finder 已观察状态。之后按分区记住主动展开 / 折叠，Info、Inspector、Summary 共用同名偏好；打开窗口不把默认值写成用户选择。旧版自动保存的 `true` 采用新基线，旧 `false` 保留，新的明确选择始终优先；[证据及兼容取舍](research/info-disclosures.md)。
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
- ZIP 文件提供 Extract；ZIP 浏览在设置中关闭时，打开 / 双击 ZIP 也在应用内解压。启用后的打开行为见 §18；在普通目录中选中 ZIP 时，显式 Extract 始终保留。多选 ZIP 按顺序处理。解压在原 ZIP 旁边输出：单根项目直接保留其名，多根项目放入以归档名命名的文件夹。
- 重名时依次加 ` 2`、` 3`，不会覆盖或合并已有内容；源文件和 ZIP 都保留。完成后刷新相关 pane，Compress / Extract 支持撤销与重做。
- 耗时工作放在后台，状态栏显示忙碌；失败报告错误，不发布半成品。系统归档工具在私有临时目录中处理内容，并保持路径 / 符号链接越界保护，保留资源叉与下载隔离属性。
- 当前仅支持普通 ZIP；密码归档与其他格式不属于本次实现。没有设置系统文件关联。

## 15. 服务器与挂载卷（对照 Finder）

- Go → Connect to Server…（`⌘K`）接受 SMB / CIFS、NFS、WebDAV HTTP(S) 和系统仍支持的旧式 AFP 地址。内联显示格式错误；不接受内嵌密码，由 macOS 的认证界面处理登录和共享选择。
- 只有 Connect 或在地址框按 Return 明确提交才启动连接；地址框失焦、点击 Cancel 不得开始新的挂载请求。失焦提交回归的修复验证状态见[本轮实机记录](research/computer-use-2026-09-12-inline-zip.md)。
- 通过系统 NetFS 异步挂载，连接成功后进入返回的本地挂载路径；不自行实现网络文件系统。网络卷自动出现在 Locations，显示网络图标，支持 Eject / 断开；可移动本地卷保留原有弹出行为。
- 关闭连接窗口会取消请求，不让过时回调导航窗口。SMB / WebDAV 等协议实际可用性取决于系统和服务器。
- 不提供 SSH / SFTP 后端、服务器发现、收藏服务器或断线重连。本次只验证地址、状态流转与卷策略；没有真实服务器地址，因此未进行远端读写测试。


## 16. 设置与自定义快捷键

- Tursora → Settings…（默认 `⌘,`）打开应用级设置窗口，分 General / Shortcuts / Terminal / Updates 四页，首次选择 General。General 页含通用、Startup、Folder View Settings 和 Terminal & ZIP；修改立即生效并持久化。Startup 的 Reopen windows and tabs on launch 默认开启，语义见 §22。Folder View Settings 选择每目录记忆或统一默认，语义见 §5；Updates 页见 §20。
- Shortcuts 提供可搜索的应用命令目录，覆盖主菜单中已有绑定及未绑定命令，以及 Return / Enter 重命名、Space Quick Look、标签循环 / 数字定位、备用缩放、取消归档打开等额外键盘动作。支持录制、Clear、逐项 Reset、Reset All Shortcuts；清除的命令保持无绑定，与“没有覆盖值则用默认”区分。
- 绑定全局持久化，菜单与打开窗口立即更新；旧 Filter 自定义绑定保留，默认仍为 `⌘F`。冲突指出已占用的命令并保留原值；恢复单项也检查冲突，全部重置恢复一致的默认集合。Use Groups 默认 `⌃⌘0`，Group By → None 不再重复占用该键。
- 一般命令接受 Command / Control 组合或功能键；File View 额外动作可接受 Return、Tab、Space、Escape 组合。普通 Escape 取消录制，恢复 Escape 默认通过 Reset。保留已知 macOS 组合；按当前键盘布局录制并保留字符原值，只在比较时解析 Shift 等价关系；美式 Plus 与 Shift–Equals 等价，不把其他布局的独立 Plus 强制改成 Equals。
- 应用命令仍走 AppKit 菜单验证与响应链，文本框的复制、粘贴、撤销等保留原生目标。Control-only 与功能键在文本或 SwiftTerm 输入期间交回原视图，配置的终端开关除外。文件动作只在列表 / 图标具有焦点时处理；原生文本编辑、路径补全、方向选择、对话框确认、shell/readline 和鼠标手势不是该目录里的可重定义命令。分别列出的主菜单和备用动作独立配置。
- Backspace 与 Forward Delete 分别保存、显示和匹配；Fn-Delete 按前向删除解释。菜单匹配时只转换事件副本到 AppKit 对应的菜单字符，原生文本与终端的输入事件不被改写。禁用命令继续遵守菜单验证，不因改绑而执行。
- 过滤仍是当前目录名称过滤；独立递归搜索见 §19。扩展名显示只影响界面标签，不改文件名或 Finder 的逐文件 Hide extension 标记。
- Terminal panel 与 Browse ZIP archives 默认均开启，保留已有显式关闭选择；没有偏好记录时使用新默认值。终端开关只让入口可用，不自行启动 shell。关闭终端入口会隐藏已有面板并保留会话，设置说明可重新启用后继续。
- 完整默认绑定、可录制范围与响应链规则见 [SHORTCUTS.md](SHORTCUTS.md)；[设置对照](research/settings-and-shortcuts.md)保留原 Filter-only 阶段依据，不代表当前仍只支持一个快捷键。

## 17. 终端面板

- 工具栏终端按钮和 View → Show / Hide Terminal（默认 `F4`，可自定义）在浏览窗口底部展开 / 收起终端。按钮状态、标题、提示与溢出菜单反映当前窗口是否展开；设置关闭终端入口时按钮禁用。每个窗口最多一个终端，与该窗口的全部标签 / 分栏共用；面板高度可拖动。
- 当前标签最右侧 pane 的底部状态栏显示唯一的 Terminal 入口，代表整个窗口，与活动侧无关；点击也展开 / 收起同一面板。未启动显示 Terminal，已有会话显示 Running / Hidden / Ended / Error，检测到任务显示进程数量，无法检查显示 Check；不是完整 shell 作业数量。隐藏后仍可看到状态，窄栏压缩为图标并保留 tooltip / 辅助功能说明。入口禁用但有会话时仍显示状态和重新启用说明，按钮禁用；没有会话且入口禁用时不显示。
- 已存在终端的活动状态约每 2 秒在后台检查，同一时刻仅一个查询，按当前会话身份丢弃过时结果；自然结束且没有待处理任务时停止轮询。初始状态展示、浏览导航和应用启动都不因此创建 PTY。退出 / 关窗 / Restart 在动作时重新检查，不依赖可能滞后的状态栏快照。
- 使用 SwiftTerm 1.15.0 的原生终端视图与真实 PTY，默认启动当前用户的交互登录 shell；Settings → Terminal 可选择 System Login Shell 或 Custom Shell。自定义项是绝对可执行文件路径，不接受附加参数或命令片段；保存与实际启动分别验证，缺失或不可执行时显示内联错误。shell 选择只在下一次新建会话 / 重启生效，重新显示已有面板不应用新 shell 或结束原进程。
- 字体可选已安装等宽字体及 System Monospaced，默认系统等宽 12 pt，允许 8–36 pt；输入后按 Return 或移走焦点（包括 Tab）提交并校验，步进器也走相同持久化。颜色默认 Follow Appearance，也可固定 Dark / Light 或 Custom 的六位十六进制文本 / 背景色；字体与颜色立即应用到所有已打开终端，不重启 shell 或写入输入。Restore Terminal Defaults 恢复上述工厂值。固定方案不随系统亮暗切换；自定义颜色只定义文本 / 背景，不宣称完整 ANSI 调色板编辑器。
- 初始目录为首次打开面板时的活动目录；活动 pane 在 ZIP 内时，使用原 ZIP 所在目录，不在临时副本内启动或重启 shell。只有开关启用且首次显示 / 显式 Start 或 Restart 时才启动进程。
- 浏览器导航、切换标签或 pane 只更新 Restart in Current Folder 的目标，不向现有 shell 注入 `cd`，也不根据终端输出驱动文件浏览器导航。
- 面板区分 Started in（启动目录）与 Shell folder（收到当前会话的本地 OSC 7 报告后）；没有目录报告时不把启动位置当作实时 shell 目录。独立第二行显示启动或重启目标。自然退出或启动失败后保留状态和输出，后续导航不覆盖结束提示；可按 Start in Current Folder 开始新会话。
- 工具栏 / F4 / 面板标题栏关闭按钮只隐藏面板；所属窗口继续持有原 PTY、输出与任务，再显示时使用同一会话。禁用终端入口同样只隐藏并保留，重新启用后可展开继续；字体与颜色修改仍更新这些隐藏会话。
- Restart、关闭所属窗口或退出应用才结束会话。检测覆盖当前 PTY 的前台、后台和已停止任务；状态未知时保守询问。确认默认选择 Cancel；取消不结束 shell、不清空输出，也不开始窗口或应用清理。Restart 接受后回收旧会话，再在当前目标目录新建。
- 应用退出先汇总所有窗口的会话（包括隐藏或入口禁用的面板）并确认；通过之后才设置退出状态、同步保存逻辑工作区、取消传输和等待所拥有 PTY 的回收。窗口关闭只处理自己的终端；显式接受不会影响其他窗口终端。
- 本轮不提供多个终端标签、跨应用重启的 PTY 会话恢复或自动双向目录同步。任务判断来自进程状态，不执行探测命令；检测的具体边界和验证阶段见[会话生命周期](research/terminal-session-lifecycle.md)。

设置实现与 Rascal 源码差异见[终端自定义](research/terminal-customization.md)；收起保留及终止确认以[会话生命周期](research/terminal-session-lifecycle.md)为准。

## 18. ZIP 浏览

- 开关默认开启；在普通目录 Open / 双击 ZIP 会进入当前 pane 的 ZIP 根目录，不再打开独立归档窗口。保留归档原始根结构，不自动省去单个顶层文件夹或添加包装层。
- 复用列表 / 图标视图、就地展开、分组、排序、缩放和当前目录名称过滤；过滤仍非递归搜索。地址栏与面包屑显示原 ZIP 路径及内部目录，例如 `/Downloads/Sample.zip/Notes`，不会显示临时路径。输入 ZIP 根或子目录可进入；输入归档内普通文件不会触发外部打开。
- Back / Forward、历史菜单、标签页和分栏按普通目录方式工作。Up 从内部目录回到上层；在 ZIP 根执行 Up 返回原 ZIP 所在目录并选中 ZIP。关闭标签页或离开归档不清理其副本，历史仍可返回。
- 所有归档目录只读：不能新建、重命名、剪切、粘贴、拖入、删除、创建 Duplicate 副本、压缩 / 解压内部项目或移动到另一 pane，也不提供可编辑的 Get Info / Inspector。Copy 与拖出只复制；可复制到普通目录或另一可写 pane。Quick Look、Share 和显式 Open 使用经过路径校验的临时副本。
- 状态栏显示简短的 `ZIP · Read-only`；tooltip 解释临时副本、外部编辑不回写与 Save As。没有额外范围栏或 Extract All 按钮；需要解压时返回普通目录选中原 ZIP，按 §14 使用 Extract。
- 首次打开在后台准备完整的私有解压副本，同一归档的 pane 共用会话。准备时显示 Opening 文件名和 Cancel；文件视图聚焦时 Escape、Back 也可取消。取消保留原目录 / 选区，首次恢复尚无目录时退到原 ZIP 的父目录。离开或关闭 pane / 标签 / 窗口取消自身等待，最后一个等待者取消底层进程并清理未完成副本；关闭后重开标签会重新准备原目标。退出先保存逻辑位置，再等待准备进程结束与清理。副本保留到 Tursora 退出，避免外部应用丢失正在使用的文件；修改不写回 ZIP，需要保留编辑结果时使用 Save As。
- 准备失败显示内联错误、Retry 和 Open Enclosing Folder，保留可见的原目录与选区；启动恢复失败仍记原逻辑目标，标签和窗口显示请求位置名称，Reload / ⌘R 可重试；修复原 ZIP 后可通过系统目录别名继续打开内部目标。一个临时副本成员在枚举期间消失时只跳过该项，其他读取错误仍报告。
- 关闭 ZIP 浏览开关后，已有归档页与历史仍可安全只读浏览，普通目录中新打开 ZIP 恢复默认解压。归档内嵌套 ZIP 的普通 Open 使用系统默认应用，不自动进入另一归档会话。仅支持普通 ZIP；密码、其他格式、归档写回与原 ZIP 外部改变后的自动重载不属于本次实现。实现与验证边界见 [归档浏览研究](research/archive-browsing.md)。

## 19. 搜索（Dolphin 语义，macOS 后端）

- 当前目录过滤后出现的 **Search Options…** / View → Search… / `⇧⌘F` 展开当前 pane 的递归搜索条件，沿用工具栏名称输入。选项包含正文、范围、类型、修改日期与保存条件；无需再次点击执行 Search。名称 / 正文停止输入 500 ms 自动执行，Return 立即执行；类型 / 日期 / 范围改变也自动执行。输入法未提交组合文字时不启动查询。名称搜索是文字包含，原过滤的 `*` / `?` 只在当前目录过滤模式解释为通配符。
- 范围是 Current Folder（含子目录）或 Home（含子目录）；显示具体根路径。名称、正文、类型、修改时间条件按 AND 组合，名称为不区分大小写的文字包含。日期支持预设与自定义起止界限；起点包含、终点排除，保存时预设转为固定日期，重开显示实际界限。Clear 清空条件、结果和请求，保留范围，不启动广泛遍历；重新输入或选取有效条件才执行，清空后的 Reload 不会恢复旧请求。所有条件均为空时不自动扫描整棵目录。
- 没有正文条件时在后台递归枚举，未索引目录仍可按名称、类型、日期查询；不递归包、ZIP、符号链接。正文通过 Spotlight，受系统索引、权限与格式支持限制；状态文字解释限制，零结果不宣称已完整扫描正文。
- 查询和待执行输入按 pane 保存，执行新查询会清空旧名称过滤；Reload / 文件操作完成、撤销与目录变化刷新优先重新执行当前搜索，保留仍能命中的真实 URL 选区，不因来源目录键检查退出搜索。Cancel 同时取消待执行输入和当前查询，保留已有部分结果并标记取消；旧查询迟到结果不覆盖新查询。切标签 / 激活另一 pane 不串状态，延迟查询仍属于原 pane 且不抢焦点；导航、关 pane / 标签 / 窗口会取消待执行输入。Back、Close Search、工具栏 Esc / ⓧ 返回原目录并清空输入。
- 搜索结果不作为目录或 ZIP 逻辑地址。列表 Location 列、图标位置标签和完整路径 tooltip 展示来源；切模式、过滤、分组、选择与后续文件命令按真实 URL 工作。Open / Quick Look / Copy / Get Info / Rename / Duplicate / Trash / 跨 pane 传输可用；Reveal in Enclosing Folder 在本 pane 打开父目录并选中精确项。无默认写入目标，所以结果背景不支持 Paste / New Folder / Compress / Extract；拖到明确的目录结果仍使用该目录。
- Save 输入名称后保存当前条件与范围；Saved Searches 菜单、Open、Delete 可发现。删除仅删除保存条件；重启后仍可再次执行。应用保存格式不与 Finder Smart Folder 互通。
- ZIP 内搜索禁用，不遍历临时解压副本；普通目录可搜到 ZIP 文件本身。Reload 重新执行当前请求。权限、启动失败、取消和空结果均用非模态状态说明。实现依据和边界见 [搜索研究](research/search.md)。

- 单次最多展示 50,000 项；递归按匹配结果截断，Spotlight 最多检查前 50,000 个索引候选；达到上限明确提示收窄条件。

搜索批次改变行序时，已打开的右键菜单仍绑定打开时的真实文件。批量文件操作同时选中普通目录及沿真实目录路径的后代时，仅处理最上层目录一次；Trash 的撤销可恢复整棵目录。Copy / Move / Duplicate 在创建任务时也归一化同一组源，Duplicate 将各保留源复制到其实际父目录。符号链接不覆盖显式选择的 `link/child`；即使只选实际目录 `root` 和 `root/link/externalChild`，中间的链接也使后者成为独立源。若选中链接下的实际目录及其普通子项，两者之间没有链接，仍按父目录去重；不通过解析链接把操作对象替换为目标。

## 20. 软件更新（Sparkle 原生更新流程）

- 正式打包应用通过 Sparkle 2.9.6 检查、下载、校验、安装及重新启动更新。Tursora → Check for Updates… 与 Settings → Updates 的同名按钮共用一个应用级 updater；不受标签、分栏或当前目录影响，无新增快捷键。
- Automatically check for updates 默认开启，按 Sparkle 的每日周期检查，可关闭并记住选择。关闭自动检查仍可手动检查；不在每次启动时覆盖用户已保存的偏好，也不额外强制联网查询。
- Automatically download and install updates 为独立选项，默认关闭。启用后可在后台下载，校验成功的更新可在退出时安装；需要授权或其他用户操作时由 Sparkle 提示。关闭自动检查会禁用该控件但保留原选择，重新启用检查后恢复可操作状态。
- 两个选项控制后续检查和自动更新策略，不取消已下载或已经安排退出安装的更新；保留 Sparkle 的既有会话语义。手动检查入口的可用性由 updater 当前状态决定，后台处理期间不能重复启动新检查。
- Updates 显示最近检查时间或尚未检查；updater 配置启动失败时内联显示原因并禁用对应操作。未打包的 SPM 可执行文件与 smoke 模式完全不构造 Sparkle，不安排更新网络请求或更新弹窗。测试使用注入 driver 验证控件和状态。
- 更新只跟随 GitHub 的最新正式 release；prerelease 不进入稳定通道。公开 HTTPS feed 位于最新 release 的 `appcast.xml`，其中 DMG 指向对应版本的固定资产 URL，下载内容经 Ed25519 签名校验后才提取应用安装。不发送可选系统 profile；应用仍是 ad-hoc 签名、未公证，更新签名不改变这个状态。
- 原始 `0.1.0` 不含 updater，必须先手动下载一次含此功能的版本。实现、签名配置、实际发布和验证阶段分别记录于[软件更新研究](research/app-updates.md)；实现完成不等于稳定 feed 已上线。

## 21. 下载与安装

- README 简介后、功能表前直接提供 0.2.0 安装步骤与 Homebrew 命令。网站首屏主按钮及导航中的“安装指南”是页内 `#installation` 跳转；“免费下载”单独指向真实最新稳定 release。安装区逐步说明下载 DMG、打开、拖入 Applications、从 Applications 启动，复用真实透明安装截图，并链接可信下载的首次启动说明。在 release 成功之前保留准备中 / 历史 0.1.0 ZIP 的真实状态，不链接不存在的新版资产。
- 项目自己的 Homebrew tap 直接使用本仓库 `Casks/tursora.rb`。合入公开 `main` 后可 `brew tap zerolfx/tursora https://github.com/zerolfx/Tursora`，再 `brew install --cask zerolfx/tursora/tursora`。固定已发布版本与 SHA-256；当前 cask 用真实 `0.1.0` ZIP。不需要为自有 tap 先购买 Apple 会员，但安装包仍未公证；保留下载隔离，不在 cask 中执行绕过命令。官方 `homebrew/cask` 接纳条件与自有 tap 分开，见[Homebrew 依据与实装验证](research/homebrew.md)。
- README、研究记录和网站的 canonical 截图必须是实际窗口 PNG，原生圆角外侧透明且边缘带抗锯齿；确定性处理保护内部像素，不能生成或修饰 UI。网站构建检查整个图片目录，不能靠 CSS 覆盖白底，见[本轮截图审计](research/screenshot-audit-2026-09-13.md)。

- 后续 release 直接提供 `Tursora-<version>-macOS-arm64.dmg` 与 SHA-256 校验文件，正式版另附更新 appcast。打开镜像后，窗口中左侧为 Tursora、右侧为 Applications，中间箭头指向目标；将应用拖入 Applications 完成安装。Applications 是 `/Applications` 的链接，没有额外安装脚本。
- 镜像预设 640 × 280 窗口、128 px 图标，布局在构建时直接写入 Finder 元数据。用户正常拖拽应用时由 macOS 执行复制；不修改文件管理器的 ZIP 浏览或普通文件操作行为。
- 原始 `0.1.0` 继续保留已发布 ZIP，不重写历史资产。网站和 README 在首个 DMG 发布前明确区分已发布 ZIP 与准备中的 DMG。
- 安装说明按下载、拖入 Applications、从 Applications 启动排列。当前 ad-hoc 且未公证，可信下载被系统以无法验证开发者为由阻止时，按 Apple 指引先尝试打开，再到 System Settings → Privacy & Security → Open Anyway 并确认 Open。README 另提供折叠终端备选，仅在确认官方来源及同版本 SHA-256 一致后，移除该应用包的 `com.apple.quarantine` 属性；不清空全部扩展属性，不赋予公证或修复损坏。损坏提示先重下核验，恶意软件警告不按普通隔离提示处理。网站仅提供简短步骤与 README 详情链接；不执行系统安全设置变更。
- 本轮没有可用 Developer ID 签名身份，用户也确认尚无证书，因此维持 ad-hoc 签名。Apple Developer Program 资格、Developer ID 证书与公证凭据就绪后再单独接入并验证签名 / 公证；不以 DMG 外观或 Sparkle 签名代替 Apple 信任。Mac App Store 分发与其 sandbox 设计另行评估。

## 22. 工作区会话恢复（工作连续性）

- Reopen windows and tabs on launch 默认开启。正常启动重建已保存的浏览窗口及其标签顺序、选中标签、自定义名、每标签一到两个 pane 的位置、活动侧与分栏比例；同时恢复活动窗口、窗口位置和尺寸、最小化状态、侧栏宽度及折叠状态、Folders 树可见性 / 高度比例 / 隐藏文件夹与 Home 限制选项。旧会话缺少树字段时默认隐藏。显式关闭的窗口或标签不在下次启动时复活；当前没有浏览窗口时启动打开 Home。
- 保存的是逻辑位置与已执行搜索的条件，启动重新导航并重新查询，不保存搜索结果或尚未执行的草稿。ZIP 使用原归档加内部目录的逻辑 URL，准备过程中也保留目标，不写入临时解压目录。关闭 ZIP 浏览且能识别实际归档时改开归档父目录；离线或缺失路径不按 `.zip` 后缀猜测，不把同名普通目录改为归档。
- 不存在、未挂载或无权限的目录仍保留原路径，由既有异步浏览错误在 pane 内说明，不自动替换为 Home，不自动挂载或重新认证服务器。重新连接卷后可 Reload 或继续导航。窗口按当前屏幕的可见区域约束，移除显示器不会让恢复窗口留在屏幕外；分栏暂时受窄窗口最小宽度约束时，仍保留原比例供放宽后恢复。
- 过滤文字、选区、滚动、Back / Forward 历史、最近关闭标签、终端进程、文件任务和撤销历史不持久化。两种文件视图继续按 §5 读取目录属性；搜索与 ZIP 的临时视图属性不并入会话库。退出通过 §17 的终端任务确认后才取消传输并等待清理，恢复工作区不会继续复制或执行终端命令。
- 工作区位于 `~/Library/Application Support/Tursora/WorkspaceSession.json`，与目录视图库分离。位置、搜索、标签、分栏、侧栏及窗口状态变化在 0.4 秒停止变化后合并写入；退出确认通过后先捕获并同步保存，随后才清理任务和临时归档，取消退出不进入清理状态。文件用私有权限原子替换，不写浏览目录。读取保护上限为 16 个窗口、每窗口 32 个标签和 2 MiB 文件；超限保存明确提示失败并保留旧文件，不能静默截断当前工作区。不接受远程协议 URL。
- 损坏、未知版本或无法读取的会话文件保留原样，当次仍可使用 Home；后续导航及退出也不自动覆盖它。Settings → General 内联显示错误，Retry Saving Workspace 明确以当前工作区重试保存；关闭再开启选项也开始保存当前工作区。普通保存失败同样内联提示，不弹模态对话框。
- 关闭选项立即取消待保存并清除会话文件，当前窗口继续工作；重新开启立即保存当前工作区。清除失败显示 Retry Clearing Saved Workspace，不能把失败记作已经删除。

本轮实现及已完成的三轮自动化、打包和实机验证见[会话恢复记录](research/workspace-sessions.md)。既有功能的历史通过次数不作为本轮验证结果。

# Tursora vs Dolphin — 功能差距清单

依据 `upstream/dolphin/src` 里实际注册的 action / 面板 / 设置页 / 右键项，对照 Tursora 当前实现整理。
**粗体** = 高频且实现成本低到中，建议优先。「(mac)」= macOS 上有更合适的原生替代。

## A. 视图与浏览

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| 分栏各自地址栏、同时展示两侧的标签标题 | ✅ | 每 pane 可编辑路径；标题固定物理左右顺序，以竖线分隔，活动侧由 pane 提示线标记，tooltip 显示完整逻辑路径；[依据与验证状态](../research/pane-paths-and-tab-actions.md) |
| 标签右键（New / Detach / Rename / Close Other / Close Left / Close Right / Close） | ✅ | 操作捕获右键页身份；自定义名称可清空；Detach 按位置及搜索请求新建窗口，不迁移历史或任务。标签栏始终显示是本应用默认选择 |
| 过滤栏（`show_filter_bar`，即时按名称过滤当前视图） | ✅ 默认 `⌘F`，可自定义 | 子串 + 通配符，切目录清空 |
| 分组显示（`group_by`） | ✅ 按 Finder 的 Use Groups / Group By 做，9 种键（含 None，Tags 明确不做） | 列表组头吸顶，图标视图分节 |
| **附加信息列**（`additional_info`，约 30 列：创建/访问时间、扩展名、权限、所有者、链接目标、路径、评分、标签、注释、字数、行数、图片尺寸、时长、艺术家…） | 普通目录有 名称/修改日期/大小/种类；搜索另有 Location | (mac) 大部分可由 Spotlight 元数据（`kMDItem*`）提供 |
| 排序选项：降序 / 文件夹优先 / **隐藏文件靠后** | 升降 ✅，文件夹优先固定开 | 缺"隐藏靠后"，"文件夹优先"不可关 |
| **文件夹项目数 / 递归大小列**（`KDirectoryContentsCounter`） | ✅ | Size 列默认显示条目数（Finder 的 "N items"），`Calculate all sizes` 打开后显示递归字节数；后台计算、按目录记忆、ZIP 与搜索结果只算条目数（[记录](../research/sort-columns-folder-sizes.md)） |
| **每目录视图属性**（模式 / 排序 / 缩放 / 隐藏与恢复默认） | ✅ 每目录记忆 / 统一默认、保存当前默认、恢复当前目录 | 两种缩放档位、分组和预览一并保存；应用自身版本化路径库，无 `.directory` 或 xattr。递归应用到子目录、列宽 / 附加列与随移动追踪仍未实现；依据及边界见[研究](../research/directory-view-properties.md) |
| Compact 视图（第三种模式） | ❌ | 优先级低 |
| 悬停 tooltip（元数据 + 预览） | ❌ | Quick Look 部分替代 |
| `.hidden` 文件 / `UF_HIDDEN` 标志（Dolphin 只认点文件） | ❌ | (mac) 必须做：`/usr`、`Icon\r`、`.fseventsd` 等 |

## B. 面板

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **Folders 面板**（目录树，可与视图同步） | ✅ 已实现并验证 | Places 下方独立 NSOutlineView 树；F7、活动 pane 跟随、按需读取、隐藏 / Home 选项、上下比例与可见性会话记忆；没有任意停靠 / 浮动，见[记录](../research/folder-tree.md) |
| Information 面板（预览 + 元数据 + 媒体自动播放、"悬停时显示"） | ❌ | (mac) Quick Look 覆盖预览；元数据面板可做成 Inspector |
| Terminal 面板（内嵌终端，随目录同步，`switch_terminal_url_sync`） | ✅ 默认启用 | 原生 SwiftTerm 1.15.0 + PTY，工具栏 / 默认 F4；可设 shell、等宽字体和文本 / 背景配色。隐藏保留会话，终止前任务确认见[生命周期](../research/terminal-session-lifecycle.md)。zsh、bash 与 fish 都自动双向跟随：浏览目录送给 shell（zsh 在空提示符即时，bash / fish 在下一个提示符），shell 自己换目录时当前 pane 跟随，两个方向各有开关且默认开，保留运行程序与未提交输入。其他 shell 手动 Restart。顶部紧凑，底部无终端状态或容量；[0.2.1 范围](../research/terminal-navigation-0.2.1.md)、[双向同步与 bash / fish](../research/terminal-shell-sync.md) |
| Places：隐藏条目 / 显示全部、"最近使用"与"搜索"分组 | 部分 | 我们有增删拖拽重排、推出 ✅ |
| 面板锁定 / 布局记忆 | 部分 | 会话恢复已有侧栏宽度 / 折叠及分栏比例；本轮加入 Folders 可见性 / 高度比例 / 选项。面板锁定、任意停靠及终端布局恢复仍未实现 |

## C. 文件操作

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **批量重命名**（多选后 Return → `KIO::RenameFileDialog`，`name#` 模式） | ✅ Finder 式 | 多选走 File ▸ Rename N Items… 的 sheet（Dolphin 用 Return）；`name#` 占位符未做，用 Name and Index / Name and Counter 代替；预览列表与 Dolphin 一致 |
| **新建 ▸ 模板**（`Create New`：文本文件/HTML/…，来自 Templates 目录） | 只有新建文件夹 | |
| **反选**（`invert_selection`） | ❌ | 几行代码 |
| **操作进度与取消**（KJob 进度、暂停/取消、多任务） | 复制 / 移动 / Duplicate 已实现逐任务控制，验证见[专项记录](../research/file-operation-tasks.md) | 大文件中途可暂停 / 继续 / 取消（逐块检查）；独立冲突与安全撤销。元数据系统调用、同卷原子移动与 ZIP 工具阶段不冒称可逐字节暂停；不实现全部 KIO 后端 |
| 冲突对话框的批量选项（全部跳过/全部覆盖/自动重命名） | ✅ Finder 式 | Keep Both / Skip / Stop / Replace / Merge + "Apply to all" |
| 属性对话框（`properties`：权限、大小统计、打开方式、图标） | ✅ Get Info / Inspector | (mac) Finder 文字与系统预览；权限为 POSIX 子集 |
| 显示链接目标（`show_target`） | ❌ | |
| 清空废纸篓 / 浏览 `trash:/` / 放回 | ✅ 用户废纸篓 | 边栏 / Go 菜单进入，普通列表浏览；Put Back 用自建日志（Finder 的 put-back 记录在私有 `.DS_Store` 里），Empty Trash… 用 Finder 文案；卷级废纸篓未实现（[记录](../research/trash.md)） |
| 拖放松手弹出 复制/移动/链接 菜单 | 按 Finder 规则自动决定 | 设计选择，可做成偏好。⌘ 强制移动、弹簧加载文件夹与面包屑投放已实现（[记录](../research/drag-and-drop.md)） |
| 在终端中打开（`open_terminal_here`） | ❌ | (mac) Terminal.app / iTerm |
| 压缩/解压（Ark 服务菜单） | ✅ 普通 ZIP | 系统 ditto / libarchive；密码和其他格式未实现 |
| 比较文件（Kompare）、磁盘空间（Filelight） | ❌ | 外部工具，低优先 |
| 撤销/重做、复制/移动到另一 pane、复制路径、Open With、复制/剪切/粘贴 | ✅ | |

## D. 导航与查找

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **搜索**（`toggle_search`：文件名/内容，日期/类型/评分/标签 chip 筛选） | 名称 / 正文 / 类型 / 日期 / 保存条件 ✅；评分 / 标签 ❌ | 名称后台递归；正文 NSMetadataQuery，受系统索引限制。范围为当前文件夹或 Home，不搜 ZIP；单次 50,000 项上限，不做实时结果增量或 Finder 保存搜索互通 |
| **会话恢复**（记住打开的标签/pane，启动时恢复） | ✅ 已实现并验证 | 默认恢复窗口、标签顺序 / 名称 / 活动页、双 pane 位置 / 活动侧 / 比例及侧栏 / 窗口布局；可关闭并清除，已执行搜索重跑。历史、选区、过滤、终端与任务不恢复；[范围与验证](../research/workspace-sessions.md) |
| **最近关闭的标签列表**（`closed_tabs` 菜单，可挑选恢复） | 只有 `⌘⇧T` 恢复最后一个 | |
| 书签（`bookmarks` 菜单） | ❌ | 与收藏有重叠，可合并 |
| 地址栏以 Place 为根（"Downloads › …"） | 只有 Home / 卷 | |
| Pop out split（把 pane 弹到新窗口）、Split stash（`stash:/` 暂存区） | ❌ | 低优先 |
| `focus_places_panel` 等焦点快捷键 | ❌ | |
| 图标视图 type-ahead | 列表 ✅ 图标 ❌ | |
| 选择模式（触屏向） | 不做 | 设计决定 |

## E. 远程与协议（KIO）

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| sftp / smb / webdav / ftp / fish | SMB / WebDAV 等系统挂载 ✅；SFTP / FTP / fish ❌ | NetFS 连接后复用本地浏览，另支持 NFS / legacy AFP；没有 KIO 后端，真实服务端仍待验证 |
| `archive://` 浏览压缩包、`trash:/`、`recentlyused:/`、MTP、iOS(afc) | ZIP 浏览 ✅；其他 ❌ | ZIP 默认启用，启用后在当前 pane 只读浏览，复用历史 / 地址栏 / 两种视图 / 分组 / 名称过滤，支持复制与拖出；使用临时副本，不实现 KIO 虚拟协议或归档写回 |

## F. 集成、设置与外观

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **偏好设置窗口**（通用/启动/视图模式/上下文菜单/废纸篓/确认对话框/预览） | ✅ General / Shortcuts / Terminal / Updates 与目录视图策略 | Startup 提供默认开的会话恢复开关及保存失败重试；另有扩展名、完整应用命令快捷键、终端外观 / Shell、终端与 ZIP 开关、每目录记忆 / 统一默认。独立更新页提供自动检查开关、可选下载安装和手动检查。更新是 Tursora 的 macOS 分发功能；其他行为策略仍待实现 |
| **本地化** | 应用界面仅英文；网站英文 / 中文 | 应用中文界面仍待实现；网站默认英文，提供独立中文页 |
| 版本控制插件（git/svn 状态角标、命令） | ❌ | |
| 服务菜单 / 文件动作插件 | ❌ | (mac) 对应 Finder 扩展 / Services 菜单 |
| 快捷键自定义、工具栏自定义 | 应用命令快捷键 ✅；工具栏定制 ❌ | 可搜索所有主菜单命令及已有额外键盘动作，录制 / 清除 / 单项和全部重置、冲突归属提示；原生文本与 shell 控制不重定义。组合三轮 smoke 与实机范围见[定制功能整合记录](../research/customization-integration.md) |
| 完成通知（KNotification） | ❌ | (mac) `UNUserNotification` 需签名 bundle |
| 窗口配色方案 | 不做 | 跟系统外观 |
| 作为默认文件管理器 / "在 Tursora 中显示" | 部分（从 Dock 拖入文件夹 ✅） | |

## Tursora 有而 Dolphin 没有的

Quick Look（空格）、移入系统废纸篓及撤销、拖到 Finder/其他 App、行内地址补全 + 候选面板、拖标签拆分 pane、原生外观与手势。废纸篓浏览与 Put Back 尚未实现。

## 建议的下一批（按性价比）

用户将工作连续性排到小功能之前；会话恢复本轮已实现，当前先完成其构建、三轮 smoke 和实机验证，见[记录](../research/workspace-sessions.md)。以下保留其余候选功能的成本排序。

1. ~~过滤栏~~、反选、最近关闭标签列表、`.hidden`/`UF_HIDDEN` —— 小
2. 新建模板 —— 中
3. ~~会话恢复（本轮实现与验证完成）~~、~~复制 / 移动进度与逐任务控制~~、~~冲突批量选项~~ —— 中
4. 面板停靠 / 浮动、更多偏好策略、中文本地化 —— 中大
5. 更多信息列（Spotlight 元数据）、视图属性递归应用与列布局持久化 —— 中大
6. 终端多会话 / 恢复、Compact 视图、版本控制、更多远程协议 —— 大 / 后续

## 2026-09-12 过滤交互复核

- [x] 区分当前目录过滤与递归搜索的界面语义：去掉无操作的范围栏，保留状态栏计数。
- [ ] 过滤模式（普通文本 / 通配符 / 正则）、大小写开关、跨目录保留锁。
- [x] 独立递归搜索和后端支持的范围 / 类型 / 日期 / 内容条件；保存搜索可重启后重新执行。

源码证据见 [过滤与搜索对照](../research/dolphin-filter-search.md)。上述勾选表示实现范围；独立搜索阶段验证见[搜索专项记录](../research/search-verification.md)，与目录属性、操作任务的组合验证见 [PR 整合记录](../research/pr-integration-2026-09-12.md)。

## 2026-09-12 更新设置与公开分发

- [x] 原生软件更新入口、General / Updates 设置分页、每日自动检查开关及独立自动下载安装选项。
- [x] 关闭自动检查保留手动入口和下载偏好；注入 driver 的无网络回归、包内 updater 与 release 元数据校验。
- [x] 公开产品页的 GitHub Pages 工作流与最新正式版本下载入口。
- [x] 直接 DMG 分发与 Tursora → Applications 拖拽安装布局，构建与签名工具检查。
- [x] 签名私钥配置为 GitHub Actions secret，首个含 updater 的正式 0.2.0 与 appcast 已发布；字节与签名见[发布记录](../research/release-0.2.0.md)。
- [x] 使用临时 QA key 与本机 feed 完成 Sparkle DMG 下载、验证、安装和重启；另有错误 key / 同长度篡改的离线签名负测。
- [ ] 完成线上生产 feed 的下载、安装和重启验证。Developer ID / Apple 公证尚无证书，后续独立接入。
- 勾选表示实现范围，不代表新版本或网站已经发布；本轮工具 / smoke / 实机检查见[软件更新记录](../research/app-updates.md)与[Pages 记录](../research/github-pages.md)。

## 2026-09-12 每目录视图属性

- [x] 每目录记住模式、排序和方向、两种缩放、分组、隐藏和预览；新标签 / pane 与再次访问恢复。
- [x] 独立默认值、统一策略、当前目录恢复默认；版本化存储与损坏回退，ZIP 逻辑页及临时路径不持久化。
- [ ] 递归应用子目录、列布局持久化、按卷和文件身份跟随重命名 / 移动、特殊逻辑页的专用持久化。
- 上述勾选表示实现范围；本功能三轮 smoke 与实机验证见[目录视图验证记录](../research/computer-use-2026-09-12-directory-views.md)，不沿用此前 739 项结果。

## 2026-09-12 分栏路径与标签菜单

- [x] 每 pane 的可编辑路径与补全，分栏两边同时可见；路径、历史、查询和过滤独立。
- [x] 左右固定顺序的分栏标题、独立的活动 pane 提示、自定义标签名与完整路径 tooltip。
- [x] 七项标签右键动作、目标身份固定、后台 / 批量关闭保留活动页、关闭恢复自定义名。
- [x] Detach 按一到两个逻辑位置新建窗口，保留活动侧与搜索请求；任务和撤销归原窗口。
- [ ] 合并窗口、单独弹出一个 pane、完整标签栏显示偏好；该阶段待做的启动会话恢复见下方新阶段。
- 勾选表示本轮实现范围；完整自动检查与打包应用实测的完成状态见[专项记录](../research/pane-paths-and-tab-actions.md)，不沿用上一轮 1,253 项结果。

## 2026-09-13 工作区会话恢复

- [x] 默认重开窗口、按顺序恢复标签 / 自定义名 / 选中项、双 pane 位置 / 活动侧 / 比例、侧栏 / 窗口几何和最小化状态。
- [x] 逻辑 ZIP 地址、已执行搜索条件重跑、离线路径保留与普通目录异步错误。
- [x] 开关禁用并清除保存，0.4 秒防抖与退出同步写入，损坏 / 未知版本保留到明确重试，失败内联反馈。
- [x] 独立会话恢复阶段 2,418 项 smoke 连续三次通过，构建和打包应用真实退出 / 重启与设置控件实测完成，证据见[会话恢复记录](../research/workspace-sessions.md)；本轮扩展目录树后的结果见下方。

## 2026-09-13 操作定制与开源分发

- [x] 应用命令快捷键自定义与持久化，覆盖默认无绑定项，保留原 Filter 迁移。
- [x] 终端启动 shell、字体 / 字号、主题 / 文本背景色和工具栏入口。
- [x] Places 旁的独立 Folders 树：本实现位于其下方，允许拖动高度，保持收藏可见。
- [x] MIT 许可、免费开源说明和自有 Homebrew tap 配置；隔离安装 / 卸载通过。
- [x] 最终 95 份 Swift 源码 3,194 项 smoke 连续三轮通过，交付 app / DMG、实机与全部 29 张透明截图检查完成；阶段和范围见[定制功能整合记录](../research/customization-integration.md)。
- [x] 隐藏保留终端与退出 / 关窗 / Restart 任务确认，101 份源码 3,329 项 smoke 连续三轮及实机追加验证通过；[生命周期范围](../research/terminal-session-lifecycle.md)。
- [x] 公开 main 上的原始 tap 与 0.2.0 正式 release 已发布，下载字节、签名和安装布局核验通过。
- [x] 0.2.0 cask 与安装文案 follow-up 的隔离安装 / 卸载、网站构建及引用检查通过；这是合入前本地范围。线上提交结果见 [Homebrew runs](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml)、[Pages runs](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml) 及对应 PR；[发布记录](../research/release-0.2.0.md)。

## 0.2.1 终端目录跟随与状态栏简化

- [x] zsh 在安全提示符跟随文件浏览；私有数据通道保留 shell 输入，隐藏终端仍可跟随。多个终端会话仍未实现。
- [x] 终端只保留一行标题 / Start 或 Restart / Hide 操作，目录与错误详情通过提示及辅助功能说明呈现。
- [x] 移除右下角全部终端状态和轮询，移除可用容量文本及文件系统查询；保留文件计数、上下文、缩放和操作进度。
- [x] 0.2.1 正式发布，实际资产与签名、打包应用启动及生产源最新版本检查通过；[发布核验](../research/release-0.2.1.md)。
- 勾选表示实现范围；完整 smoke、打包实机与发布结果见[0.2.1 记录](../research/terminal-navigation-0.2.1.md)，不把 0.2.0 的三轮检查当作本轮验证。

## 终端双向目录同步与 bash / fish

- [x] 反向同步：shell 换目录时窗口的活动 pane 跟随，只在面板可见时生效，两种文件视图、分栏和多标签一致；四道防回环。
- [x] bash 与 fish 的自动同步：临时 `--rcfile` / `--init-command` 读用户自己的启动文件，请求在下一个提示符生效；三种 shell 都用 OSC 7 汇报目录。
- [x] Settings → Terminal 两个方向开关（默认开），旧版偏好迁移保留 shell 与外观。
- bash / fish 空闲时不跟随、没有失败应答；范围、证据与限制见[双向同步记录](../research/terminal-shell-sync.md)。

## 命令面板

- [x] ⇧⌘O 打开的模糊命令面板，覆盖全部命令、侧栏收藏与当前窗格历史目录；命令按菜单语义执行，不可用命令置灰列出。Dolphin 无此功能，属 Tursora 自有能力。
- 打包应用的可视检查仍待补；范围与推断见[命令面板记录](../research/command-palette.md)。

## 排序、列、文件夹大小与拖放

- [x] 排序键补齐 Date Created / Date Added / Date Last Opened，三处入口一致；无日期项两个方向都垫底。
- [x] 详情视图可选列（右键表头勾选）与按目录持久化；列宽不持久化，Version / Comments / Tags 未做。
- [x] 文件夹条目数与可选的递归大小计算，后台取消与缓存失效；ZIP 与搜索结果只算条目数。
- [x] ⌘ 强制移动、弹簧加载文件夹（列表 / 图标 / 侧栏 / 文件夹树）、面包屑分段投放。
- Dolphin 的「松手弹出 复制/移动/链接 菜单」仍是设计选择，未实现。

## 废纸篓

- [x] 浏览用户废纸篓、Put Back（自建日志）、Empty Trash…（Finder 文案 + 确认）、无权限时的窗格内横幅。
- 卷级废纸篓、Finder 之外移入项目的放回仍未实现；范围见[废纸篓记录](../research/trash.md)。

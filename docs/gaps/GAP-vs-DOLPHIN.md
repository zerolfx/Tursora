# Tursora vs Dolphin — 功能差距清单

依据 `upstream/dolphin/src` 里实际注册的 action / 面板 / 设置页 / 右键项，对照 Tursora 当前实现整理。
**粗体** = 高频且实现成本低到中，建议优先。「(mac)」= macOS 上有更合适的原生替代。

## A. 视图与浏览

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| 分栏各自地址栏、同时展示两侧的标签标题 | ✅ | 每 pane 可编辑路径；标题固定物理左右顺序，括号标记非活动侧，tooltip 显示完整逻辑路径；[依据与验证状态](../research/pane-paths-and-tab-actions.md) |
| 标签右键（New / Detach / Rename / Close Other / Close Left / Close Right / Close） | ✅ | 操作捕获右键页身份；自定义名称可清空；Detach 按位置及搜索请求新建窗口，不迁移历史或任务。标签栏始终显示是本应用默认选择 |
| 过滤栏（`show_filter_bar`，即时按名称过滤当前视图） | ✅ 默认 `⌘F`，可自定义 | 子串 + 通配符，切目录清空 |
| 分组显示（`group_by`） | ✅ 按 Finder 的 Use Groups / Group By 做，9 种键（含 None，Tags 明确不做） | 列表组头吸顶，图标视图分节 |
| **附加信息列**（`additional_info`，约 30 列：创建/访问时间、扩展名、权限、所有者、链接目标、路径、评分、标签、注释、字数、行数、图片尺寸、时长、艺术家…） | 普通目录有 名称/修改日期/大小/种类；搜索另有 Location | (mac) 大部分可由 Spotlight 元数据（`kMDItem*`）提供 |
| 排序选项：降序 / 文件夹优先 / **隐藏文件靠后** | 升降 ✅，文件夹优先固定开 | 缺"隐藏靠后"，"文件夹优先"不可关 |
| **文件夹项目数 / 递归大小列**（`KDirectoryContentsCounter`） | ❌ | 大小列对文件夹显示 `--` |
| **每目录视图属性**（模式 / 排序 / 缩放 / 隐藏与恢复默认） | ✅ 每目录记忆 / 统一默认、保存当前默认、恢复当前目录 | 两种缩放档位、分组和预览一并保存；应用自身版本化路径库，无 `.directory` 或 xattr。递归应用到子目录、列宽 / 附加列与随移动追踪仍未实现；依据及边界见[研究](../research/directory-view-properties.md) |
| Compact 视图（第三种模式） | ❌ | 优先级低 |
| 悬停 tooltip（元数据 + 预览） | ❌ | Quick Look 部分替代 |
| `.hidden` 文件 / `UF_HIDDEN` 标志（Dolphin 只认点文件） | ❌ | (mac) 必须做：`/usr`、`Icon\r`、`.fseventsd` 等 |

## B. 面板

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **Folders 面板**（目录树，可与视图同步） | ❌ | `NSOutlineView` 树 |
| Information 面板（预览 + 元数据 + 媒体自动播放、"悬停时显示"） | ❌ | (mac) Quick Look 覆盖预览；元数据面板可做成 Inspector |
| Terminal 面板（内嵌终端，随目录同步，`switch_terminal_url_sync`） | ✅ 实验，默认关闭 | 原生 SwiftTerm 1.15.0 + PTY，F4；导航只更新手动 Restart 目标，不注入 cd，不做自动双向同步 |
| Places：隐藏条目 / 显示全部、"最近使用"与"搜索"分组 | 部分 | 我们有增删拖拽重排、推出 ✅ |
| 面板锁定 / 布局记忆 | ❌ | 侧边栏宽度已由 `NSSplitView` 自动记忆 |

## C. 文件操作

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **批量重命名**（多选后 Return → `KIO::RenameFileDialog`，`name#` 模式） | ❌ | 单选重命名 ✅ |
| **新建 ▸ 模板**（`Create New`：文本文件/HTML/…，来自 Templates 目录） | 只有新建文件夹 | |
| **反选**（`invert_selection`） | ❌ | 几行代码 |
| **操作进度与取消**（KJob 进度、暂停/取消、多任务） | 复制 / 移动 / Duplicate 已实现逐任务控制，验证见[专项记录](../research/file-operation-tasks.md) | 大文件中途可暂停 / 继续 / 取消（逐块检查）；独立冲突与安全撤销。元数据系统调用、同卷原子移动与 ZIP 工具阶段不冒称可逐字节暂停；不实现全部 KIO 后端 |
| 冲突对话框的批量选项（全部跳过/全部覆盖/自动重命名） | ✅ Finder 式 | Keep Both / Skip / Stop / Replace / Merge + "Apply to all" |
| 属性对话框（`properties`：权限、大小统计、打开方式、图标） | ✅ Get Info / Inspector | (mac) Finder 文字与系统预览；权限为 POSIX 子集 |
| 显示链接目标（`show_target`） | ❌ | |
| 清空废纸篓 / 浏览 `trash:/` / 放回 | 移入 Finder 废纸篓 ✅ | (mac) "清空废纸篓"可调 Finder；浏览可列 `~/.Trash` |
| 拖放松手弹出 复制/移动/链接 菜单 | 按 Finder 规则自动决定 | 设计选择，可做成偏好 |
| 在终端中打开（`open_terminal_here`） | ❌ | (mac) Terminal.app / iTerm |
| 压缩/解压（Ark 服务菜单） | ✅ 普通 ZIP | 系统 ditto / libarchive；密码和其他格式未实现 |
| 比较文件（Kompare）、磁盘空间（Filelight） | ❌ | 外部工具，低优先 |
| 撤销/重做、复制/移动到另一 pane、复制路径、Open With、复制/剪切/粘贴 | ✅ | |

## D. 导航与查找

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **搜索**（`toggle_search`：文件名/内容，日期/类型/评分/标签 chip 筛选） | 名称 / 正文 / 类型 / 日期 / 保存条件 ✅；评分 / 标签 ❌ | 名称后台递归；正文 NSMetadataQuery，受系统索引限制。范围为当前文件夹或 Home，不搜 ZIP；单次 50,000 项上限，不做实时结果增量或 Finder 保存搜索互通 |
| **会话恢复**（记住打开的标签/pane，启动时恢复） | ❌ | 日常必需 |
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
| `archive://` 浏览压缩包、`trash:/`、`recentlyused:/`、MTP、iOS(afc) | ZIP 浏览 ✅ 实验；其他 ❌ | ZIP 默认关闭，启用后在当前 pane 只读浏览，复用历史 / 地址栏 / 两种视图 / 分组 / 名称过滤，支持复制与拖出；使用临时副本，不实现 KIO 虚拟协议或归档写回 |

## F. 集成、设置与外观

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **偏好设置窗口**（通用/启动/视图模式/上下文菜单/废纸篓/确认对话框/预览） | ✅ 基础设置与目录视图策略 | 扩展名、名称过滤快捷键、两个实验开关、每目录记忆 / 统一默认；其他行为策略仍待实现 |
| **本地化** | 仅英文 | 中文界面 |
| 版本控制插件（git/svn 状态角标、命令） | ❌ | |
| 服务菜单 / 文件动作插件 | ❌ | (mac) 对应 Finder 扩展 / Services 菜单 |
| 快捷键自定义、工具栏自定义 | 过滤快捷键 ✅；其他 ❌ | 带冲突检查的录制器；未开放通用命令或工具栏定制 |
| 完成通知（KNotification） | ❌ | (mac) `UNUserNotification` 需签名 bundle |
| 窗口配色方案 | 不做 | 跟系统外观 |
| 作为默认文件管理器 / "在 Tursora 中显示" | 部分（从 Dock 拖入文件夹 ✅） | |

## Tursora 有而 Dolphin 没有的

Quick Look（空格）、移入系统废纸篓及撤销、拖到 Finder/其他 App、行内地址补全 + 候选面板、拖标签拆分 pane、原生外观与手势。废纸篓浏览与 Put Back 尚未实现。

## 建议的下一批（按性价比）

1. ~~过滤栏~~、反选、最近关闭标签列表、`.hidden`/`UF_HIDDEN` —— 小
2. 批量重命名、新建模板、文件夹项目数列、分组显示 —— 中
3. 会话恢复、~~复制 / 移动进度与逐任务控制~~、~~冲突批量选项~~ —— 中
4. Folders 面板、更多偏好策略、中文本地化 —— 中大
5. 更多信息列（Spotlight 元数据）、视图属性递归应用与列布局持久化 —— 中大
6. 终端多会话 / 恢复、Compact 视图、版本控制、更多远程协议 —— 大 / 后续

## 2026-09-12 过滤交互复核

- [x] 区分当前目录过滤与递归搜索的界面语义：去掉无操作的范围栏，保留状态栏计数。
- [ ] 过滤模式（普通文本 / 通配符 / 正则）、大小写开关、跨目录保留锁。
- [x] 独立递归搜索和后端支持的范围 / 类型 / 日期 / 内容条件；保存搜索可重启后重新执行。

源码证据见 [过滤与搜索对照](../research/dolphin-filter-search.md)。上述勾选表示实现范围；独立搜索阶段验证见[搜索专项记录](../research/search-verification.md)，与目录属性、操作任务的组合验证见 [PR 整合记录](../research/pr-integration-2026-09-12.md)。

## 2026-09-12 每目录视图属性

- [x] 每目录记住模式、排序和方向、两种缩放、分组、隐藏和预览；新标签 / pane 与再次访问恢复。
- [x] 独立默认值、统一策略、当前目录恢复默认；版本化存储与损坏回退，ZIP 逻辑页及临时路径不持久化。
- [ ] 递归应用子目录、列布局持久化、按卷和文件身份跟随重命名 / 移动、特殊逻辑页的专用持久化。
- 上述勾选表示实现范围；本功能三轮 smoke 与实机验证的最终记录见 [HANDOFF](../HANDOFF.md)，不沿用此前 739 项结果。

## 2026-09-12 分栏路径与标签菜单

- [x] 每 pane 的可编辑路径与补全，分栏两边同时可见；路径、历史、查询和过滤独立。
- [x] 左右固定顺序的分栏标题、活动侧标记、自定义标签名与完整路径 tooltip。
- [x] 七项标签右键动作、目标身份固定、后台 / 批量关闭保留活动页、关闭恢复自定义名。
- [x] Detach 按一到两个逻辑位置新建窗口，保留活动侧与搜索请求；任务和撤销归原窗口。
- [ ] 启动会话恢复、合并窗口、单独弹出一个 pane、完整标签栏显示偏好。
- 勾选表示本轮实现范围；完整自动检查与打包应用实测的完成状态见[专项记录](../research/pane-paths-and-tab-actions.md)，不沿用上一轮 1,253 项结果。

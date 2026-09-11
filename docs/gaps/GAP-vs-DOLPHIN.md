# Tursora vs Dolphin — 功能差距清单

依据 `upstream/dolphin/src` 里实际注册的 action / 面板 / 设置页 / 右键项，对照 Tursora 当前实现整理。
**粗体** = 高频且实现成本低到中，建议优先。「(mac)」= macOS 上有更合适的原生替代。

## A. 视图与浏览

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| 过滤栏（`show_filter_bar`，即时按名称过滤当前视图） | ✅ `⌘F` | 子串 + 通配符，切目录清空 |
| 分组显示（`group_by`） | ✅ 按 Finder 的 Use Groups / Group By 做，10 种键 | 列表组头吸顶，图标视图分节 |
| **附加信息列**（`additional_info`，约 30 列：创建/访问时间、扩展名、权限、所有者、链接目标、路径、评分、标签、注释、字数、行数、图片尺寸、时长、艺术家…） | 只有 名称/修改日期/大小/种类 | (mac) 大部分可由 Spotlight 元数据（`kMDItem*`）提供 |
| 排序选项：降序 / 文件夹优先 / **隐藏文件靠后** | 升降 ✅，文件夹优先固定开 | 缺"隐藏靠后"，"文件夹优先"不可关 |
| **文件夹项目数 / 递归大小列**（`KDirectoryContentsCounter`） | ❌ | 大小列对文件夹显示 `--` |
| **每目录视图属性**（`.directory` 记住每个文件夹的模式/排序/缩放/隐藏；"视图属性…"可应用到子目录；"恢复默认") | 按 pane + 全局默认 | (mac) 可存到 xattr，别在用户目录里写 `.directory` |
| Compact 视图（第三种模式） | ❌ | 优先级低 |
| 悬停 tooltip（元数据 + 预览） | ❌ | Quick Look 部分替代 |
| `.hidden` 文件 / `UF_HIDDEN` 标志（Dolphin 只认点文件） | ❌ | (mac) 必须做：`/usr`、`Icon\r`、`.fseventsd` 等 |

## B. 面板

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **Folders 面板**（目录树，可与视图同步） | ❌ | `NSOutlineView` 树 |
| Information 面板（预览 + 元数据 + 媒体自动播放、"悬停时显示"） | ❌ | (mac) Quick Look 覆盖预览；元数据面板可做成 Inspector |
| Terminal 面板（内嵌终端，随目录同步，`switch_terminal_url_sync`） | ❌ | (mac) 先做"在终端中打开"；内嵌需 SwiftTerm 类库 |
| Places：隐藏条目 / 显示全部、"最近使用"与"搜索"分组 | 部分 | 我们有增删拖拽重排、推出 ✅ |
| 面板锁定 / 布局记忆 | ❌ | 侧边栏宽度已由 `NSSplitView` 自动记忆 |

## C. 文件操作

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **批量重命名**（多选后 Return → `KIO::RenameFileDialog`，`name#` 模式） | ❌ | 单选重命名 ✅ |
| **新建 ▸ 模板**（`Create New`：文本文件/HTML/…，来自 Templates 目录） | 只有新建文件夹 | |
| **反选**（`invert_selection`） | ❌ | 几行代码 |
| **操作进度与取消**（KJob 进度、暂停/取消、多任务） | 只有转圈，不可取消 | 需要自己写带进度回调的复制 |
| 冲突对话框的批量选项（全部跳过/全部覆盖/自动重命名） | ✅ Finder 式 | Keep Both / Skip / Stop / Replace / Merge + "Apply to all" |
| 属性对话框（`properties`：权限、大小统计、打开方式、图标） | ❌ | (mac) 可先接 Finder "显示简介"，长期做 Inspector |
| 显示链接目标（`show_target`） | ❌ | |
| 清空废纸篓 / 浏览 `trash:/` / 放回 | 移入 Finder 废纸篓 ✅ | (mac) "清空废纸篓"可调 Finder；浏览可列 `~/.Trash` |
| 拖放松手弹出 复制/移动/链接 菜单 | 按 Finder 规则自动决定 | 设计选择，可做成偏好 |
| 在终端中打开（`open_terminal_here`） | ❌ | (mac) Terminal.app / iTerm |
| 压缩/解压（Ark 服务菜单） | ❌ | (mac) `Archive Utility` / `ditto` |
| 比较文件（Kompare）、磁盘空间（Filelight） | ❌ | 外部工具，低优先 |
| 撤销/重做、复制/移动到另一 pane、复制路径、Open With、复制/剪切/粘贴 | ✅ | |

## D. 导航与查找

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **搜索**（`toggle_search`：文件名/内容，日期/类型/评分/标签 chip 筛选） | ❌ | (mac) `NSMetadataQuery`（Spotlight）；这是 Phase 0 审计里就定的方向 |
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
| sftp / smb / webdav / ftp / fish | ❌（v1 纯本地） | (mac) SMB/WebDAV 走系统挂载；sftp 需自研后端（`FileProvider` 抽象已留好） |
| `archive://` 浏览压缩包、`trash:/`、`recentlyused:/`、`tags:/`、MTP、iOS(afc) | ❌ | |

## F. 集成、设置与外观

| Dolphin 功能 | Tursora | 说明 |
|---|---|---|
| **偏好设置窗口**（通用/启动/视图模式/上下文菜单/废纸篓/确认对话框/预览） | ❌ | 目前全靠默认值；很多行为（拖放策略、重命名延迟、预览阈值）应可配 |
| **本地化** | 仅英文 | 中文界面 |
| 版本控制插件（git/svn 状态角标、命令） | ❌ | |
| 服务菜单 / 文件动作插件 | ❌ | (mac) 对应 Finder 扩展 / Services 菜单 |
| 快捷键自定义、工具栏自定义 | ❌ | `NSToolbar` 打开 `allowsUserCustomization` 即得一半 |
| 完成通知（KNotification） | ❌ | (mac) `UNUserNotification` 需签名 bundle |
| 窗口配色方案 | 不做 | 跟系统外观 |
| 作为默认文件管理器 / "在 Tursora 中显示" | 部分（从 Dock 拖入文件夹 ✅） | |

## Tursora 有而 Dolphin 没有的

Quick Look（空格）、与 Finder 一致的废纸篓与"放回"、拖到 Finder/其他 App、行内地址补全 + 候选面板、拖标签拆分 pane、原生外观与手势。

## 建议的下一批（按性价比）

1. ~~过滤栏~~、反选、最近关闭标签列表、`.hidden`/`UF_HIDDEN` —— 小
2. 批量重命名、新建模板、文件夹项目数列、分组显示 —— 中
3. 会话恢复、操作进度与取消、~~冲突批量选项~~ —— 中
4. 搜索（Spotlight）、Folders 面板、偏好设置窗口、中文本地化 —— 中大
5. 更多信息列（Spotlight 元数据）、每目录视图属性、Inspector —— 中大
6. 终端面板、Compact 视图、版本控制、远程协议 —— 大 / 后续

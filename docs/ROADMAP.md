# Roadmap

v1（纯本地）的功能已经齐了：地址栏、标签页、分栏、两种视图与缩放预览、文件操作与撤销、过滤、分组、Get Info。
新增功能已扩展到 ZIP 压缩 / 解压、系统分享、系统服务器挂载与设置；终端面板和当前 pane 的 ZIP 只读浏览为默认关闭的实验功能。接下来按"用户最常碰到、成本最低"排。难度尺度（S ≤ 半天 / M 1–2 天 / L 3–5 天 / XL > 1 周）与每项的依据见两份差距清单：

- [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md) — 对照 Finder 菜单 nib 逐项
- [gaps/GAP-vs-DOLPHIN.md](gaps/GAP-vs-DOLPHIN.md) — 对照 Dolphin 注册的 action / 面板 / 设置

## 下一批（S，各不到半天）

Deselect All、Move Items Here（⌥⌘V）、Copy as Pathname 快捷键对齐、New Folder with Selection、Show Package Contents、Always Open With、Print、Slideshow、Eject All、Go 菜单的标准文件夹快捷键、Cycle Through Windows、Services 菜单、Finder 别名解析、反选、在终端中打开。

## 之后（M）

批量重命名、Make Alias / Show Original、Recent Folders、右侧预览栏（复用 Get Info 的 FileInfo）、Customize Toolbar、Toolbar / Path Bar / Status Bar / Tab Bar 开关、Show All Tabs、Move Tab to New Window / Merge、spring-loaded folders、改扩展名警告、Paste Exactly、Show Clipboard、Add to Dock、快捷键与 Finder 对齐（可做成开关）、会话恢复、最近关闭的标签列表、附加信息列、文件夹项目数 / 递归大小列。

## 大件（L）

Column 视图、Gallery 视图、Show View Options（每目录视图属性）、更完整的偏好设置（确认策略、视图默认值等）、图标自由摆放、废纸篓视图（需要 Full Disk Access）、Quick Actions、中文本地化、Spotlight 搜索（`NSMetadataQuery`）、Folders 面板（目录树）、服务器历史 / 发现 / 重连、终端多会话与会话恢复。

## 不做 / 等公开 API

Tags、Import from iPhone（产品设计明确排除）；Customize Folder（私有存储）、Smart Folders（依赖搜索且结果不确定）、FinderSync 角标（只有 iCloud 公开）、桌面、选择模式。

## 新功能的后续验证

- 复制 / 移动 / Duplicate 的逐任务进度、暂停 / 继续 / 取消已实现；专项自动化与实机记录见[文件操作任务](research/file-operation-tasks.md)。跨卷故障分支可注入验证，真实独立卷和真实服务器专项实测应分别记录；ZIP 压缩 / 解压工具取消、崩溃后任务恢复、废纸篓 / 删除任务化仍未实现。

- 在有用户提供的服务器时验证 SMB / NFS / WebDAV / legacy AFP 的认证、读写和掉线；当前只验证系统挂载接口与无网络状态流转。
- 既有功能提交的 GitHub Build 已成功；本轮推送后仍需检查新提交的托管构建与下载产物，手动 Release 发布 / 安装尚未验证。本地打包不能替代对应提交的实际 Actions 运行。
- 实验性终端补充不同 shell、全屏程序、字体/主题与布局检查；目前没有自动目录同步，手动 Restart 会结束当前会话。
- 本轮 CUA 已完成工具栏 / Favorites 分栏与新标签、补全、过滤、两种视图、Quick Look / Share、同 pane ZIP 导航与只读菜单、外部打开临时副本、跨 pane 复制及撤销、Keep Both 与撤销、终端基础命令、服务器表单修复复测；13 组截图已核对。快照路径重映射问题已修复，最终 739 项 smoke 连续三轮通过；release build 5 重建与 strict codesign 通过。ZIP 拖出手势、归档内 Quick Look / Share 和关闭开关后既有页的专项 CUA 仍可补充，见[本轮记录](research/computer-use-2026-09-12-inline-zip.md)。
- ZIP 浏览仍使用完整暂存，进一步评估大归档的空间与响应；密码归档、其他格式、原 ZIP 外部改变后的自动重载和归档写回未实现。

## 已知的小差距

- Settings 窗口中按 ⌘W 未关闭窗口，需补窗口级关闭命令与对应回归；2026-09-12 本轮 CUA 发现。

- smoke test 在极窄分栏 / 超大图标档位时会输出 collection-view item width 超过可用宽度的布局警告；需补专项视觉检查及布局回归（2026-09-12）。

- 列表与图标视图的 Return/Enter 分支 `case 36, 76 where plain` 产生编译警告：`plain` 仅限制 Enter；带修饰键的 Return 路径需另行补回归检查（2026-09-12 构建时发现）。
- 浏览 pane 在**外部**改名后选择会丢（Info 窗口能按 inode 跟上，pane 还不能）。
- 文件夹大小在 Info 窗口里不随内容变化实时更新（避免 FSEvents 风暴）。
- 分组的 Size 桶边界、Kind 组顺序仍是推断。

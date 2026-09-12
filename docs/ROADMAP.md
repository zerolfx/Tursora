# Roadmap

v1（纯本地）的功能已经齐了：地址栏、标签页、分栏、两种视图与缩放预览、文件操作与撤销、过滤、分组、Get Info。
新增功能已扩展到 ZIP 压缩 / 解压、系统分享、系统服务器挂载与设置，以及每目录视图记忆 / 统一默认、可控制的文件操作任务、递归和保存搜索；终端面板和当前 pane 的 ZIP 只读浏览为默认关闭的实验功能。三项新功能的组合验证状态见 [PR 整合记录](research/pr-integration-2026-09-12.md)。接下来按"用户最常碰到、成本最低"排。难度尺度（S ≤ 半天 / M 1–2 天 / L 3–5 天 / XL > 1 周）与每项的依据见两份差距清单：

分栏独立地址栏、双侧标签标题与标签右键操作的本轮实现及验证状态见[专项记录](research/pane-paths-and-tab-actions.md)；会话恢复、合并窗口和单独弹出 pane 仍留待后续。

- [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md) — 对照 Finder 菜单 nib 逐项
- [gaps/GAP-vs-DOLPHIN.md](gaps/GAP-vs-DOLPHIN.md) — 对照 Dolphin 注册的 action / 面板 / 设置

## 下一批（S，各不到半天）

Deselect All、Move Items Here（⌥⌘V）、Copy as Pathname 快捷键对齐、New Folder with Selection、Show Package Contents、Always Open With、Print、Slideshow、Eject All、Go 菜单的标准文件夹快捷键、Cycle Through Windows、Services 菜单、Finder 别名解析、反选、在终端中打开。

## 之后（M）

批量重命名、Make Alias / Show Original、Recent Folders、右侧预览栏（复用 Get Info 的 FileInfo）、Customize Toolbar、Toolbar / Path Bar / Status Bar / Tab Bar 开关、Show All Tabs、Move Tab to New Window / Merge、spring-loaded folders、改扩展名警告、Paste Exactly、Show Clipboard、Add to Dock、快捷键与 Finder 对齐（可做成开关）、会话恢复、最近关闭的标签列表、附加信息列、文件夹项目数 / 递归大小列。

## 大件（L）

Column 视图、Gallery 视图、更完整的偏好设置（确认策略等）、图标自由摆放、废纸篓视图（需要 Full Disk Access）、Quick Actions、中文本地化、Folders 面板（目录树）、服务器历史 / 发现 / 重连、终端多会话与会话恢复。每目录视图属性的核心持久化已实现；完整 Show View Options 对话框、列布局持久化和递归应用仍待做。

## 不做 / 等公开 API

Tags、Import from iPhone（产品设计明确排除）；Customize Folder（私有存储）、Finder `.savedSearch` 互通（已有应用内保存搜索）、FinderSync 角标（只有 iCloud 公开）、桌面、选择模式。

## 新功能的后续验证

- 复制 / 移动 / Duplicate 的逐任务进度、暂停 / 继续 / 取消已实现；专项自动化与实机记录见[文件操作任务](research/file-operation-tasks.md)。跨卷故障分支可注入验证，真实独立卷和真实服务器专项实测应分别记录；ZIP 压缩 / 解压工具取消、崩溃后任务恢复、废纸篓 / 删除任务化仍未实现。
- 每目录视图属性使用应用私有路径库；原独立分支同步 `ae5e47a` 后的三轮 smoke、打包签名与实机证据见 [HANDOFF](HANDOFF.md)，三功能组合不能复用该检查数。后续项包括递归应用子目录、列布局与逻辑页专用属性；如需目录改名 / 移动后跟随或跨挂载点恢复，应独立评估卷身份与 bookmark，不将本次路径键行为暗改为 inode 跟随。会话恢复仍是独立功能。

- 在有用户提供的服务器时验证 SMB / NFS / WebDAV / legacy AFP 的认证、读写和掉线；当前只验证系统挂载接口与无网络状态流转。
- [0.1.0](https://github.com/zerolfx/Tursora/releases/tag/v0.1.0) 已发布，对应提交的 Build / Release 成功，重新下载的 ZIP 校验和、签名、版本、架构与资源核对通过，见 [HANDOFF](HANDOFF.md)。下载产物在其他机器上的首次安装 / 启动仍待验证；本地同源打包实测不替代该检查。
- GitHub Actions 本轮成功，但 checkout / upload-artifact 的 v4 版本出现 Node 20 运行时弃用提示；后续单独升级 action 并验证构建与发布流程。
- 实验性终端补充不同 shell、全屏程序、字体/主题与布局检查；目前没有自动目录同步，手动 Restart 会结束当前会话。
- 已完成检查按对应版本统一见 [HANDOFF](HANDOFF.md) 与[历史 ZIP 实机记录](research/computer-use-2026-09-12-inline-zip.md)；历史结果不替代本次合并后的检查。ZIP 拖出手势、归档内 Quick Look / Share 和关闭开关后既有页的专项 CUA 仍可补充。
- ZIP 浏览仍使用完整暂存，进一步评估大归档的空间与响应；密码归档、其他格式、原 ZIP 外部改变后的自动重载和归档写回未实现。

## 已知的小差距

- Settings 窗口中按 ⌘W 未关闭窗口，需补窗口级关闭命令与对应回归；2026-09-12 本轮 CUA 发现。

- smoke test 在极窄分栏 / 超大图标档位时会输出 collection-view item width 超过可用宽度的布局警告；需补专项视觉检查及布局回归（2026-09-12）。

- 列表与图标视图的 Return/Enter 分支 `case 36, 76 where plain` 产生编译警告：`plain` 仅限制 Enter；带修饰键的 Return 路径需另行补回归检查（2026-09-12 构建时发现）。
- 浏览 pane 在**外部**改名后选择会丢（Info 窗口能按 inode 跟上，pane 还不能）。
- 文件夹大小在 Info 窗口里不随内容变化实时更新（避免 FSEvents 风暴）。
- 分组的 Size 桶边界、Kind 组顺序仍是推断。

## 搜索后续边界

- 已实现独立递归名称搜索、Spotlight 正文、类型 / 日期 AND 条件及持久化保存搜索。见 [研究与验证](research/search.md)。
- 后续再评估更多范围和实时结果增量；Finder `.savedSearch` 互通、ZIP 内搜索、评分 / 标签不在本轮。未索引正文仍依赖用户的系统索引设置，应用不自建全文索引。单次结果与 Spotlight 候选均有 50,000 项上限；真实正向正文命中尚待单独验证。

- 后续评估显式同时选择符号链接与 `link/child` 时，移动 / 删除的源顺序：链接先移走会使后代路径失效。搜索不遍历链接，因此本轮搜索结果不会产生这种组合；普通展开视图或剪贴板仍可能出现。

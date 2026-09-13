# Roadmap

v1（纯本地）的功能已经齐了：地址栏、标签页、分栏、两种视图与缩放预览、文件操作与撤销、过滤、分组、Get Info。
新增功能已扩展到 ZIP 压缩 / 解压、系统分享、系统服务器挂载与设置，以及每目录视图记忆 / 统一默认、可控制的文件操作任务、递归和保存搜索；终端面板和当前 pane 的 ZIP 只读浏览默认启用，可在设置中关闭。三项新功能的组合验证状态见 [PR 整合记录](research/pr-integration-2026-09-12.md)。接下来按"用户最常碰到、成本最低"排。难度尺度（S ≤ 半天 / M 1–2 天 / L 3–5 天 / XL > 1 周）与每项的依据见两份差距清单：

分栏独立地址栏、双侧标签标题与标签右键操作的实现及验证状态见[专项记录](research/pane-paths-and-tab-actions.md)；合并窗口和单独弹出 pane 仍留待后续。

- [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md) — 对照 Finder 菜单 nib 逐项
- [gaps/GAP-vs-DOLPHIN.md](gaps/GAP-vs-DOLPHIN.md) — 对照 Dolphin 注册的 action / 面板 / 设置

## 本轮：0.2.1 目录跟随与界面简化

- [x] zsh 通过私有请求 / FIFO 在空的主提示符跟随当前活动 pane；正在执行的程序、read、续行和未提交输入不被打断，隐藏时保留会话与同步通道。其他 shell 仍手动 Restart，不做反向同步。
- [x] 终端顶部改为一行操作栏；移除底部所有终端状态、图标、动画、计时和轮询，同时移除状态栏可用容量及查询，保留项目 / 选中计数、筛选、搜索、ZIP、缩放与文件操作进度。
- [x] 网站默认英文，独立中文页面通过普通链接切换；两页共享截图、安装步骤与交互，应用界面仍为英文。
- 上述勾选表示实现范围；本轮完整 smoke、打包实机、截图和发布进度见[0.2.1 记录](research/terminal-navigation-0.2.1.md)，双语网站的静态 / 浏览 / 部署范围见[站点说明](../site/README.md)，不复用旧版检查数。

## 已完成阶段：终端会话与 0.2.0 发布

- [x] 收起 / 禁用入口保留窗口终端；退出、关窗与 Restart 对任务确认，取消退出保留传输与工作区。该阶段的右下角状态及轮询已由 0.2.1 移除；会话保留与确认继续有效。101 份源码 3,329 项 smoke 连续三轮及实机验证通过，见[生命周期记录](research/terminal-session-lifecycle.md)。
- [x] 新增源码三轮 smoke、打包实测与 General / Terminal 真实截图完成；0.2.0 正式发布，重新下载资产、签名与布局核验通过，见[发布记录](research/release-0.2.0.md)。
- [x] 0.2.0 cask 与安装文案 follow-up 已准备，隔离安装 / 卸载、网站构建及引用检查通过。此项勾选为合入前本地范围，线上提交状态见 [Homebrew runs](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml)、[Pages runs](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml) 和对应 PR；生产 feed 的旧版下载 / 安装 / 重启仍单独记录。

## 已完成阶段：操作定制与目录导航

- [x] 所有应用命令快捷键可搜索、录制、清除与重置，保留原生文本 / shell 控制；[范围与验证](research/custom-shortcuts.md)。
- [x] 终端 Shell、等宽字体 / 字号、外观和自定义文本 / 背景色；工具栏直接展开 / 收起；[实现与边界](research/terminal-customization.md)。
- [x] Places 下方独立 Folders 目录树，活动 pane 跟随、后台单层读取和会话布局记忆；[Dolphin 依据](research/folder-tree.md)。
- [x] MIT 许可与免费开源说明、自有 Homebrew cask 及安装 / 卸载本地验证；原始 0.1.0 cask 已随 main 发布，0.2.0 跟进见上方。
- [x] 最终 95 份 Swift 源码 3,194 项 smoke 连续三轮通过，交付 app / DMG 检查、打包应用实机与全部 29 张截图透明化通过；[定制功能整合记录](research/customization-integration.md)记录范围，远端 CI / 发布仍单独处理。

## 已完成：工作连续性

按用户反馈，会话恢复已排到小功能补齐之前。本轮已实现默认恢复窗口、多标签与双 pane 工作区，保留活动位置、名称、分栏比例、侧栏和窗口布局；Settings 可关闭并清除保存。已执行搜索重新查询，缺失目录保留原路径，不重放终端、传输或撤销操作。**本轮构建、2,418 项 smoke 连续三轮及打包应用真实退出 / 重启验证已完成**，精确范围统一见[会话恢复记录](research/workspace-sessions.md)。后续是否扩展选区 / 滚动、导航历史与关闭页记忆应独立评估，不计入本轮完成范围。

## 下一批（S，各不到半天）

Deselect All、Move Items Here（⌥⌘V）、Copy as Pathname 快捷键对齐、New Folder with Selection、Show Package Contents、Always Open With、Print、Slideshow、Eject All、Go 菜单的标准文件夹快捷键、Cycle Through Windows、Services 菜单、Finder 别名解析、反选、在终端中打开。

## 之后（M）

批量重命名、Make Alias / Show Original、Recent Folders、右侧预览栏（复用 Get Info 的 FileInfo）、Customize Toolbar、Toolbar / Path Bar / Status Bar / Tab Bar 开关、Show All Tabs、Move Tab to New Window / Merge、spring-loaded folders、改扩展名警告、Paste Exactly、Show Clipboard、Add to Dock、Finder 默认快捷键预设（现有命令已可逐项自定义）、最近关闭的标签列表、附加信息列、文件夹项目数 / 递归大小列。

## 大件（L）

Column 视图、Gallery 视图、更完整的偏好设置（确认策略等）、图标自由摆放、废纸篓视图（需要 Full Disk Access）、Quick Actions、中文本地化、面板任意停靠 / 浮动、服务器历史 / 发现 / 重连、终端多会话与会话恢复。每目录视图属性的核心持久化已实现；完整 Show View Options 对话框、列布局持久化和递归应用仍待做。

## 不做 / 等公开 API

Tags、Import from iPhone（产品设计明确排除）；Customize Folder（私有存储）、Finder `.savedSearch` 互通（已有应用内保存搜索）、FinderSync 角标（只有 iCloud 公开）、桌面、选择模式。

## 新功能的后续验证

- 复制 / 移动 / Duplicate 的逐任务进度、暂停 / 继续 / 取消已实现；专项自动化与实机记录见[文件操作任务](research/file-operation-tasks.md)。跨卷故障分支可注入验证，真实独立卷和真实服务器专项实测应分别记录；ZIP 压缩 / 解压工具取消、崩溃后任务恢复、废纸篓 / 删除任务化仍未实现。
- 每目录视图属性使用应用私有路径库；原独立分支同步 `ae5e47a` 后的三轮 smoke、打包签名与实机证据见[目录视图验证记录](research/computer-use-2026-09-12-directory-views.md)，三功能组合不能复用该检查数。后续项包括递归应用子目录、列布局与逻辑页专用属性；如需目录改名 / 移动后跟随或跨挂载点恢复，应独立评估卷身份与 bookmark，不将本次路径键行为暗改为 inode 跟随。会话恢复使用独立库，本轮验证见页首。

- 在有用户提供的服务器时验证 SMB / NFS / WebDAV / legacy AFP 的认证、读写和掉线；当前只验证系统挂载接口与无网络状态流转。
- [0.1.0](https://github.com/zerolfx/Tursora/releases/tag/v0.1.0) 已发布；其 ZIP 校验和、签名、版本、架构与隔离安装验证见 [Homebrew 历史记录](research/homebrew.md#初始-010-cask-的本地验证历史)。下载产物在其他机器上的首次安装 / 启动仍待验证；本地同源打包实测不替代该检查。
- GitHub Actions 本轮成功，但 checkout / upload-artifact 的 v4 版本出现 Node 20 运行时弃用提示；后续单独升级 action 并验证构建与发布流程。
- 终端 Shell / 字体 / 配色设置已实现；后续继续覆盖更多第三方 shell、全屏程序、真实多显示器布局和长时间运行。zsh 已实现安全提示符下单向跟随文件导航，其他 shell 自动同步与双向同步仍未实现；实现与本轮验证见[0.2.1 记录](research/terminal-navigation-0.2.1.md)。隐藏保留及 Restart 任务确认见[生命周期记录](research/terminal-session-lifecycle.md)。
- Ghostty 已作官方源码调查，留作 0.2.0 之后的独立原型：比较中文输入、复杂 TUI、滚动 / 重绘、CPU / 内存与现有 SwiftTerm（及其可选实验 Metal 路径）。公开 VT 库不包含绘制，完整 Metal 接口仍标为内部，不能当作稳定 Swift 控件直接替换；[证据与范围](research/ghostty-embedding.md)。
- 按[文档索引](README.md)查找对应版本和功能的验证记录；ZIP 早期操作证据见[历史实机记录](research/computer-use-2026-09-12-inline-zip.md)；历史结果不替代本次合并后的检查。ZIP 拖出手势、归档内 Quick Look / Share 和关闭开关后既有页的专项 CUA 仍可补充。
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

- [x] 终端入口与 ZIP 浏览默认启用，保留开关；ZIP 准备可取消、失败可重试，终端目录 / 结束状态在该阶段得到补充，见[历史记录](research/default-features-polish.md)；当前紧凑标题栏与目录同步见页首 0.2.1 范围。

- Folders 在 Home 根下按目录实际拼写定位；手动输入有效但大小写不同的路径时，文件浏览正常，树选中跟随仍需按卷的真实文件身份处理，不能简单把所有路径转成小写。

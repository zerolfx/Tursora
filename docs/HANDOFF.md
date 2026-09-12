# 交接说明（2026-09-12）

给接手这个项目的人或 agent。先读这一页，再按 [README.md](README.md) 的索引找细节。

## 现状

- 2026-09-12：此前 42 个提交已 squash 成一个基线并 force-push，工作树内容保留。应用图标采用两块蓝色玻璃窗格形成抽象尾鳍的设计，内部图形宽度已收至画布约 67%，为系统圆角边缘留出间距，背景仍为单层满版。资源在 `app/Resources/`，打包时嵌入 `.icns`。

- **Tursora**（原名 Otter File Manager，2026-09-11 改名）是 Swift + AppKit 原生 macOS 文件管理器，无 Xcode 工程，Command Line Tools 即可构建；终端使用 SPM 固定的 SwiftTerm 1.15.0。基础功能包括：地址栏（面包屑 + 兄弟目录菜单 + 行内补全）、标签页、Dolphin 式分栏、列表 / 图标视图与缩放预览、文件操作与撤销、拖放、Quick Look、过滤、Finder 的分组、Finder 的 Get Info / Inspector / Summary。现已加入 ZIP 压缩 / 解压、系统分享、NetFS 服务器连接与设置；终端面板、ZIP 只读浏览是默认关闭的实验功能。规格见 [SPEC.md](SPEC.md)。
- 最新提交在 `main`；发布包 `app/build/Tursora.app` 由 `app/tools/make-app.sh` 生成，ad-hoc 签名，未上架、未公证。
- 仓库：https://github.com/zerolfx/Tursora（私有）。`upstream/` 是 git-ignored 的 KDE 源码 checkout，只有 Phase 0 审计和对照 Dolphin 语义时用到；缺了可以重新 clone（版本 pin 在 [audit/00-ground-truth.md](audit/00-ground-truth.md)）。

## 验证状态——这一点最重要

之前的开发环境**没有屏幕访问权限**，所有验证靠应用内 smoke test（`TURSORA_SMOKE_TEST=1`，当时 367 项）。它覆盖模型、导航、标签、地址栏、文件操作、撤销、分栏、视图切换、FSEvents 刷新、过滤、分组、冲突对话框、Get Info 的全部数据路径。

**2026-09-12 已做 computer use 基础检查**：地址栏跳转、标签独立目录、双窗格与切换、后退、列表 / 图标切换、活动窗格过滤、Kind 分组、Quick Look、简介窗口，均在实际打包应用中操作。发现并修复了简介内容挤在右侧、工具栏模式不同步、保存图标模式后新窗格仍挂载列表三个问题。Smoke test 启动改为等待首轮加载完成（15 秒超时），不再固定等一秒；此前图标阶段记录的 392 项已连续通过三轮；重启、新标签页的保存视图模式，以及修复后的工具栏与简介排版也已实机复查。

**同 pane ZIP 改造前的验证记录**：设置、终端与旧独立 ZIP 窗口已完成当时的连续 smoke、release 包与签名检查，此前资源及 ZIP 打包往返检查也通过。解锁后已操作快捷键录制与冲突、扩展名与取消改名、终端交互及重启、旧 ZIP 窗口目录浏览及 TextEdit 打开临时副本、More / Share、压缩 / 解压与撤销重做、服务器协议校验；刷新后首行被表头遮住的问题也已修复并实机复测。详见[历史实机检查记录](research/computer-use-2026-09-12.md)。

**本轮 CUA、截图与最终自动化检查已完成**：工具栏分栏、Favorites → Other Pane / New Tab、地址补全、活动 pane 过滤、两种视图与 Kind、Quick Look、Share、同 pane ZIP 导航 / 只读菜单 / TextEdit 打开临时副本 / 复制到另一 pane 与撤销、文件冲突 Keep Both / 撤销、终端 pwd / ls 均已操作。窄分栏名称列可读；服务器失焦触发连接的回归已修复，并实测 Tab / Cancel 不连接、Return 校验协议、编辑清错、Escape 关闭。全部 13 组 README 截图已保存检查，服务器图来自最终修正版。详见[本轮实机记录](research/computer-use-2026-09-12-inline-zip.md)。

最终 debug 构建通过，含最新快照路径重映射修复的 release build 5 已重建并通过 strict codesign。**739 项 smoke 连续三轮通过**，均 exit 0、stderr 为空；日志与精确范围见[本轮实机记录](research/computer-use-2026-09-12-inline-zip.md)。开发中新增别名断言失败已解决，失败或旧版本运行均未计入最终三轮。测试前偏好已恢复：扩展名开、⌘F、终端关、ZIP 浏览开；演示 Favorite 已移除。归档边界见 [archive-browsing.md](research/archive-browsing.md)。

真实服务器读写未验证；自动化终端专测使用隔离的 `/bin/sh` PTY，实机检查另外验证了用户配置的 zsh。GitHub Actions 提供自动 Build 和手动 Release；[功能提交的 Build 已成功](https://github.com/zerolfx/Tursora/actions/runs/34631655771)并上传产物。Release 尚未发布版本。

**仍需专项视觉检查的东西**：

- 地址补全弹窗、Kind 组头与活动 pane 强调线已做基础检查，尚未覆盖全部边界；拖放的分栏高亮层仍需专项检查。
- Get Info 的文本文件简介排版已检查并修复宽度；长文件名、卷、多选汇总的视觉边界与 Inspector 浮动跟随手感仍需专项检查。
- 菜单栏和右键菜单里 SF Symbol 图标在 macOS 26 上的显示。
- 图标视图在超大档位（256 / 512）下的布局。
- 本次检查使用深色模式；浅色模式尚未专项检查。

用户反馈过、已修的问题都进了 smoke test；修 bug 时先写能复现的 check。

## 已知问题与小差距

- 浏览 pane 在**外部**改名后选择会丢（Info 窗口按 inode 能跟上，pane 还不能）。
- Get Info 里文件夹大小不随内容变化实时更新（为避免 FSEvents 风暴，只监听本项和同级）。
- 分组的 Size 桶边界与 Kind 组顺序仍是推断，"Earlier" 键未用。
- Finder 的 Get Info 里 Stationery pad、ACL、改 owner / group、Apply to enclosed items 没做。
- 快捷键与 Finder 有几处冲突（⌘1–4、⌘L、⇧⌘T、⇧⌘P、⌥⌘S），是有意的，见 [DECISIONS.md](DECISIONS.md) D9。
- 已有基础设置：扩展名只改显示、过滤快捷键可录制；其他偏好策略、本地化、会话恢复未实现。
- 实验性终端 F4 开关默认关闭；每窗口一个 PTY，浏览导航只更新手动 Restart 目标，Restart / 关闭面板会结束会话；在 ZIP 内启动 / Restart 使用原 ZIP 所在目录。ZIP 浏览默认关闭，启用后 Open 在当前 pane 进入；地址栏保留原 ZIP 加内部目录的逻辑路径。归档只读，复制 / 拖出只复制，Quick Look / Share / Open 使用临时副本，不写回归档，副本保留到退出。关闭实验开关后已有页仍只读，新打开 ZIP 恢复 Extract。
- 归档与服务器新增功能边界：仅普通 ZIP；远程走系统 NetFS 挂载，不含自建 SFTP / 重连；真实服务器读写还未验证。`FileOperations.report` 和 Eject 错误路径已防止 smoke 模式弹模态框。

## 下一步

[ROADMAP.md](ROADMAP.md) 按成本排了序；每项的难度依据在 [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md) 和 [gaps/GAP-vs-DOLPHIN.md](gaps/GAP-vs-DOLPHIN.md)。最便宜且最常用的一批：Deselect All、Move Items Here、New Folder with Selection、Show Package Contents、Go 菜单的标准文件夹快捷键、Services 菜单、会话恢复。

## 工作方式（这个项目的经验）

- 对标 Finder 的任何文字、图标、分组名，**从 Finder 自己的资源里抽**（`strings` 读 nib、`plutil` 读 `.strings`），不要凭记忆——记忆里的 Finder 细节错过好几次。方法和已抽出的内容在 [research/](research/)。
- Dolphin 的语义看 `upstream/dolphin/src`（例如 `DolphinTabWidget` / `DolphinTabPage` 决定了"标签下有 pane"而不是反过来）。
- AppKit 的坑列在 [DEVELOPMENT.md](DEVELOPMENT.md)，先查再调试。
- 改动文件系统的代码，写完请对 diff 做一次对抗性 review（找"会不会作用到错的文件"）——Get Info 那次 review 找到 3 处会改错文件的问题。
- 用户已明确允许本轮用 subagent 做有界并行任务；划定文件所有权后协作，避免多人改同一公共文件。不要恢复此前几十上百个并行估算或搜索的做法。
- 提交前 smoke test 三遍；提交信息写 what / why 和检查数；发布包重新生成并重启（`pkill -f "Tursora.app/Contents/MacOS/Tursora"; open app/build/Tursora.app`）。

## 环境

- 原交接记录：macOS 26.5 / Swift 6.3.3。2026-09-12 实机核验为 macOS 26.3（25D125）、Swift 6.2.4，SDK 26.2；此前基础功能的 debug / release 构建成功；本轮新增依赖与功能以最终验证记录为准。部署目标仍为 macOS 14。
- 这台机器的 gh 登录了两个账号（`fxlin_otterix` 为活动账号，`zerolfx` 拥有这个仓库）。仓库本地配置了 `credential.helper`，用 `gh auth token --user zerolfx` 取令牌，所以 push / fetch 不依赖哪个账号是活动的；换机器后要么 `gh auth login` 成 zerolfx，要么重新设置这条本地 helper。

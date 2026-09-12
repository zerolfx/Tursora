# 交接说明（2026-09-12）

给接手这个项目的人或 agent。先读这一页，再按 [README.md](README.md) 的索引找细节。

## 现状

- 2026-09-12：此前 42 个提交已 squash 成一个基线并 force-push，工作树内容保留。应用图标采用两块蓝色玻璃窗格形成抽象尾鳍的设计，内部图形宽度已收至画布约 67%，为系统圆角边缘留出间距，背景仍为单层满版。资源在 `app/Resources/`，打包时嵌入 `.icns`。

- **Tursora**（原名 Otter File Manager，2026-09-11 改名）是 Swift + AppKit 原生 macOS 文件管理器，无 Xcode 工程，Command Line Tools 即可构建；终端使用 SPM 固定的 SwiftTerm 1.15.0。基础功能包括：地址栏（面包屑 + 兄弟目录菜单 + 行内补全）、标签页、Dolphin 式分栏、列表 / 图标视图与缩放预览、文件操作与撤销、拖放、Quick Look、过滤、Finder 的分组、Finder 的 Get Info / Inspector / Summary。现已加入 ZIP 压缩 / 解压、系统分享、NetFS 服务器连接与设置；终端面板、ZIP 只读浏览是默认关闭的实验功能。规格见 [SPEC.md](SPEC.md)。
- 最新提交在 `main`；发布包 `app/build/Tursora.app` 由 `app/tools/make-app.sh` 生成，ad-hoc 签名，未上架、未公证。
- 仓库：https://github.com/zerolfx/Tursora（私有）。`upstream/` 是 git-ignored 的 KDE 源码 checkout，只有 Phase 0 审计和对照 Dolphin 语义时用到；缺了可以重新 clone（版本 pin 在 [audit/00-ground-truth.md](audit/00-ground-truth.md)）。

## 验证状态——统一入口

- **已提交阶段 `fbb6762`**：739 项 smoke 连续三轮通过，均 exit 0、stderr 为空；最新路径重映射修复的 release build 5 已重建并通过 strict codesign。日志、CUA 操作范围、13 组截图和偏好恢复证据统一保留在[同 pane ZIP 实机记录](research/computer-use-2026-09-12-inline-zip.md)。
- **当前整理阶段——应用与产品页已验证**：删除未使用的 PlacesModel 常量，简化始终为 true 的归档读取参数，不改变应用行为；本阶段重新完成 739 项 smoke 连续三轮，均 exit 0、stderr 为空，debug / release build 6 与 strict codesign 通过。新增真实标签页截图。中文产品页仅介绍地址栏、标签、分栏和 ZIP，已按 [site/README.md](../site/README.md) 完成静态构建、资源引用校验与桌面 / 窄屏浏览器 QA；功能切换、图片弹窗焦点恢复、锚点直达及无 JavaScript 回退均已检查。站点仅在本地预览，未部署。具体日志与阶段边界见[同日记录](research/computer-use-2026-09-12-inline-zip.md#整理阶段与产品页)。
- **历史结果**：[早期实机记录](research/computer-use-2026-09-12.md)包含旧独立 ZIP 窗口及先前 UI 修复。历史测试和 D28 保留原貌，不作为当前实现的新增验证。
- **外部验证边界**：真实服务器认证、挂载与读写未验证；GitHub [已提交阶段 fbb6762 的 Build 已成功](https://github.com/zerolfx/Tursora/actions/runs/34671658320)并上传产物，后续提交结果见 [Build 运行列表](https://github.com/zerolfx/Tursora/actions/workflows/build.yml)；手动 Release 尚未发布版本。产品页目前也未发布上线。

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

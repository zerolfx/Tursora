# 交接说明（2026-09-13）

给接手这个项目的人或 agent。先读这一页，再按 [README.md](README.md) 的索引找细节。

## 当前追加：安装说明简化与 0.2.1 终端改进

用户要求安装兼顾不同权限与位置；README / 网站现说明 `/Applications`、`~/Applications` 和其他可写目录，并直接展示仅删除安装副本 `com.apple.quarantine` 的命令及拖入应用填路径的方法。无需把个人目录设为唯一位置，普通账号拥有且可写入的副本通常无需管理员设置；Homebrew 自身权限与组织策略分开说明。网站原样发布 `install.md`，README 前部和网站提供可交给 agent 的安装指令。D59 记录取舍，不修改 cask 的隔离行为。

网站按维护者实际 About “A free and open-source MacOS file manager, an alternative to Finder. Native, simple, and versatile.” 改成直接介绍用途和功能的文案。截图规范已加入拍摄前移开鼠标、检查成图无指针和悬停提示、发现后重拍的要求；不通过涂改 UI 删除指针。

用户随后明确要求终端随文件导航同步目录，右下角只在有执行任务时显示可点击的终端图标、转圈与耗时，并在完成后发布 **0.2.1**。这部分由终端与状态 agent 并行开发，尚待整合、三轮 smoke、打包实机与新截图验证；不能用下面 0.2.0 的通过记录当作新功能已验证。安装说明可先独立发布，不重发 0.2.0 二进制。

安装文档本地检查：5 资产 / 41 引用 / 29 张截图 alpha 门槛通过，`install.md` 原样复制；独立 agent 验证 57 个本地链接以及 sh / zsh 中带空格路径和未设置变量保护。主任务以 UID 501 在自有无执行内容的应用形状 fixture 上验证指定属性递归删除、其他属性与文件字节不变，证据 `/private/tmp/tursora-0.2.1-qa-u1_phjba/attribute-verification.json`；这不是独立非管理员账号或受管理 Mac 的启动实测。网站实查 1200 / 390 px 首页及安装跳转，窄屏首次启动、Homebrew 三条命令和 agent 指令可读且无水平溢出；Markdown 链接作为文档下载，未称浏览器已渲染指南。安装区改为顶部对齐，避免新增长说明把左侧下载入口居中推低。线上部署另行核对。

## 已完成：Homebrew 显式单项信任纳入主流程

用户明确要求把信任和 tap / install 一起列出。当前 README、网站与维护文档统一依次执行完整 URL 的 tap、`brew trust --cask zerolfx/tursora/tursora`、完整名称 install；每步成功后继续，信任是文档主流程的必做步骤，只授予 Tursora cask。Homebrew 完整名称安装的自动信任已独立验证成功，因此不声称少一条必然失败；D58 记录此明确流程选择。

主任务已验证本次三步版本：新的隔离信任目录按 tap → 单 cask trust → install dry run 顺序均 exit 0，只有此 cask 被信任；证据 `/private/tmp/tursora-three-step-install-3liuppa5/verification.json`，不把 dry run 记为重新安装应用。6 项 cask 测试与 Ruby 语法通过；网站构建 5 资产 / 40 引用 / 29 图 alpha 通过，README 两个安装代码块及网站均精确保留三条实际命令。该阶段 101 份 Swift 源码哈希未变；下面两行流程及 83 项测试仍是此前阶段证据。提交 `89ac22f` 的 Build / Homebrew / Pages 部署均已成功，线上 8 站点文件、README 和 cask 字节与该提交一致；Homebrew CI 确认仅 trust 此 cask 成功后再真安装 0.2.0，完整证据为同目录 `ci.json` 与 `live-verification.json`。应用、cask 资产及 0.2.0 版本 / build 不变。

## 历史阶段：安装排错与说明简化

用户确认没有 0.1.0 用户，不需要该版本的迁移支持。当前 README、网站和发布操作说明以 0.2.0 安装与后续正常更新为准，去掉一次性手动升级及旧版开关提示；保留历史版本 / 标签 / 资产和当时的验证事实。下面早期阶段的 0.1.0 迁移文案属于当时假设，由此决定取代；见 D57。

用户报告 `homebrew-tursora` 仓库不存在，重试后报告 `untrusted tap`。原两条命令使用真实主仓库，已在清空自有测试 tap 后从公开 URL 重验成功；当时安装说明强调先完成含完整 URL 的 tap，再安装；现已由页首三步流程取代。单参数 tap 的默认仓库错误，以及启用信任检查时短名称安装的 untrusted 错误已独立复现；单项 `brew trust --cask` 和直接 fully-qualified install 的 dry run 均通过，只有指定 cask 获得信任，不改用户 Homebrew。完整记录见[Homebrew 排错](research/homebrew.md#安装排错仓库地址与单项信任)。

本轮仅修改文档和发布页面文字，不改 Swift、cask 资产或版本；现有 101 份 Swift 源码的 3 × 3,329 smoke 记录仍是同源码历史验证，不称为新跑。83 项工具测试与网站构建通过，5 资产 / 40 引用 / 29 张透明截图门槛通过；推送与线上部署另行核对，新的发布文案不需要重新生成或移动 0.2.0 标签。

## 本轮：终端会话保留与 0.2.0 发布

上一阶段已提交为 `eeaea1c`。用户进一步要求收起终端保留会话，退出有任务时询问，并已授权在这些改动完成后推送、合入和发布新版本；本轮选定 `0.2.0`。终端、窗口与退出协调由主任务和终端 agent 实现，文档与发布准备并行。

工具栏 / F4 / 面板关闭按钮只隐藏每窗口终端，再展开继续原 PTY、输出与任务。Settings 禁用入口也隐藏并保留；Shell 选择只在新建会话 / Restart 时应用。退出、关闭窗口或 Restart 对前台 / 后台 / 已停止任务及未知状态先确认，默认 Cancel；取消退出不进入最终保存和清理，不取消文件传输。仍不恢复跨应用重启的终端会话。精确检测边界、验证计划及后续实测统一见[会话生命周期](research/terminal-session-lifecycle.md)，行为见 SPEC §17 / §22、D55。

用户又确认把终端状态放在窗口右下角：当前标签最右 pane 的 footer 显示唯一入口，点击切换同一终端；初始、隐藏 / 运行、任务进程数、结束 / 错误 / 未知状态均有说明，窄栏缩为图标。现有会话约两秒后台采样，初始展示不启动 PTY，动作时即时检测；D56 记录取舍；独立发布包的初始状态、保留任务、默认取消、窄栏及退出清理已实测，最终 101 份 Swift 源码的 3,329 项 smoke 已连续三轮通过。README 的 0.2.0 安装说明已前置，网站导航 / 首屏“安装指南”跳转 `#installation`，含实际 DMG 图及 Homebrew 命令；当前页面构建（5 资产 / 39 引用）与新增入口桌面 / 390 px 实测通过，安装图弹窗和 Escape 返回焦点通过；精确点击范围见[截图记录](research/screenshot-audit-2026-09-13.md)。0.2.0 发布后的跟进已去掉 pending 安装文案，保留有效 latest 链接；该文案与新 cask 的后续合入 / 部署检查另记。网站复用现有 installation.png，资产数变为 5，canonical 图片总数仍为 29。

Ghostty 仅完成一手源码评估：公开 libghostty-vt 与内部完整 Metal 嵌入 API 的边界、MIT 许可及后续原型建议见[研究](research/ghostty-embedding.md)。本轮不替换 SwiftTerm，也不宣称做过性能横评。

**此追加阶段：101 份 Swift 源码，3,329 项 smoke 连续三轮通过**（194.4 / 188.4 / 187.6 秒，stderr 均为空，逐轮与当前源码哈希一致）。最终默认 0.2.0 release / DMG 构建、严格签名与安装布局检查及 83 项工具测试通过；公开 0.2.0 的下载字节、签名和安装布局核对通过，生产 feed 的最新版本检查和 cask 隔离安装 / 卸载通过，follow-up 的线上结果另记；下面的 3,194 项与 95 份源码只代表 `eeaea1c` 之前的定制阶段。独立发布包已实测隐藏 / Settings 禁用再启用仍保留实际 sleep 任务及相同 PID，默认 Cancel、Restart / 关窗取消、窄至 560 × 380 的可点击状态图标、接受退出后的 PID 清理，以及浅色重开初始无 shell / 自然结束。精确步骤和边界见[会话生命周期](research/terminal-session-lifecycle.md)。

General / Terminal 已替换为这轮真实截图，显示新的保留说明和右下角 `Terminal · 1 task`；保护区逐字节相同，明暗整体及四角检查通过，其余 27 张 canonical 字节未变。全部 29 张 alpha 检查与网站重建通过；`quit-hidden.jpg` 保留为独立交互证据。截图不替代最终源码测试，旧通过数不能用作新增生命周期的验证结论。

[0.2.0 已正式发布](https://github.com/zerolfx/Tursora/releases/tag/v0.2.0)，为当前 latest；[Release 34739914582](https://github.com/zerolfx/Tursora/actions/runs/34739914582) 成功，tag 精确指向 `3ca4ab9ffd43555e4c4118e5504eb6d39e6dc034`，build 为 `1789275959`。真实下载的 DMG / appcast 与校验文件及 GitHub asset digest / size 一致；主任务还验证实际包版本、arm64、strict codesign、项目和第三方许可、安装布局与 Ed25519 签名，挂载已卸载。DMG SHA-256 为 `2593f312772b6d7ee6a885c8017ce43b31d094fc2744f764e76e027178d1aef7`。完整字节和生产 feed 检查边界见[正式发布记录](research/release-0.2.0.md)。

cask 已从上述真实 release JSON、校验文件和 DMG 生成，固定 0.2.0 并加 `auto_updates true`；六项发布边界测试与 Ruby 语法通过。隔离 Homebrew 6.0.22 从公开 DMG 真安装，版本 / build、arm64、strict codesign、许可和保留 quarantine 核对通过，未启动应用；正常卸载后临时 app / Caskroom 均不存在。此 follow-up 的本地网站构建和安装锚点 / 命令 / 图片引用检查通过；这里记录该 follow-up 合入前的本地验证；线上提交结果以对应 PR、[Homebrew runs](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml) 与 [Pages runs](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml) 为准，精确运行号写入 PR 和最终证据文件，见[Homebrew](research/homebrew.md)。原始 0.1.0 ZIP 和标签保留，其用户仍需手动升级一次。主任务另用正式下载包的隔离身份副本确认 About 为 0.2.0 / build 1789275959、初始终端未启动 shell，以及不改生产 feed 的 Check for Updates 返回“已是最新”；latest/download/appcast.xml 与固定版本 feed 字节相同，副本已退出。未将历史 loopback 更新测试或仅检查 Up To Date 等同于旧版经生产 feed 下载、安装和重启。

[PR #8](https://github.com/zerolfx/Tursora/pull/8) 已以同一提交合入 main（2026-09-13 13:12:12 Asia/Shanghai）；其 [Build](https://github.com/zerolfx/Tursora/actions/runs/34739716326)、[Pages](https://github.com/zerolfx/Tursora/actions/runs/34739716315) 与 [Homebrew](https://github.com/zerolfx/Tursora/actions/runs/34739716318) 均成功。该 Homebrew 运行仍验证原 0.1.0 cask，该 Pages 仍有发布前文案；不能当作上述 0.2.0 follow-up 的验证结果。

## 已完成阶段：快捷键、终端设置、目录树与免费开源分发

当前整合分支 `codex/customization-and-distribution` 从 `b58c1ce` 开始。用户要求协调 agent 开发：所有应用快捷键可定制、终端 Shell / 字体 / 颜色设置、工具栏直接展开 / 收起终端、参考 Dolphin 的 Places 与目录树、README 强调免费开源、截图圆角外透明以及 Homebrew 分发；用户已明确选择 MIT 许可证。

- Settings 现分 General / Shortcuts / Terminal / Updates。Shortcuts 覆盖主菜单已有及未绑定命令、文件 Return / Space、标签定位与循环、备用缩放及归档取消；持久化录制 / 清除 / 单项或全部重置，保留原 Filter 绑定，冲突说明归属。文本、Info / Settings 编辑器与 SwiftTerm 的原生 Control / 功能键受保护，终端开关除外；默认绑定和精确范围见 [SHORTCUTS](SHORTCUTS.md)、[快捷键记录](research/custom-shortcuts.md)。
- Terminal 默认系统登录 Shell、系统等宽 12 pt、跟随外观；可选绝对可执行 Shell、已安装等宽字体 / 8–36 pt、Dark / Light / Custom 文本背景色。字体和颜色即时应用到所有已打开 PTY，Shell 下次启动才用。工具栏终端按钮及溢出菜单反映本窗口展开状态；当时收起终止会话的规则由页首追加阶段取代。Tursora 是 SwiftTerm + 真实 PTY，Rascal 当前是逐条 Process + Pipe 命令面板，源码依据与边界见[终端记录](research/terminal-customization.md)。
- View → Show Folders 默认 F7，在收藏与位置下方展开独立目录树，单层后台读取、活动 pane 跟随、独立隐藏 / Home 限制选项、右键打开到新标签 / 另一侧、文件拖入走既有任务。按窗口恢复可见性、上下比例及选项；隐藏树或收起侧栏停用监听。Dolphin 两种面板的区别、固定左侧布局取舍见[目录树记录](research/folder-tree.md)。
- 根目录 MIT 许可与 README / 网站免费开源说明已加入，第三方声明保留。Homebrew cask 复用本公开仓库，固定已发布 `0.1.0` ZIP，实际下载字节 / 校验文件 / GitHub digest 一致；独立临时 Homebrew 6.0.22 中真安装、包版本 / arm64 / strict codesign / 保留 quarantine 与卸载通过。此处为最初 0.1.0 cask 的验证阶段；0.2.0 和 main 跟进结果见页首。不声称官方 homebrew/cask 已接纳，不把 brew 安装当作 Apple 公证。维护工具与依据见[Homebrew](research/homebrew.md)。
- 新增标准库 PNG 检查和 Pages 门槛覆盖整个 canonical 目录；透明化处理器沿用实测边缘、原残差阈值和窄范围，保护真实内部，83 项 Python 工具测试通过。**全部 29 张截图通过 alpha 与逐张明暗 / 四角检查**：原有 20 张字节未改，六张旧不透明图真实重拍，并新增 Shortcuts / Terminal Settings / Folders。安装图使用同一 Finder 窗口配准参考，真实白色示意内部保留。网站完整构建（4 资产、36 引用）及 1200 / 390 px 浏览器复查通过，包含 ZIP 页签、透明图暗色弹窗和 Escape 焦点恢复；自有页签及服务器已关闭。来源、像素统计和阶段边界见[截图记录](research/screenshot-audit-2026-09-13.md)。

实机修复覆盖字号 Tab 提交、功能键录制、非美式 `+`、目录别名、树选区 / 异步回调与窄窗地址栏布局。树的展开权限查询现无副作用，实际展开后才加载；面包屑省略控件在多次 layout 中保持稳定。Backspace / Forward Delete 菜单匹配只规范化事件副本，保留原生输入。详细边界见[整合记录](research/customization-integration.md)和[快捷键记录](research/custom-shortcuts.md)。Settings 图实际演示终端自定义 F6、`/bin/zsh`、Menlo 14 pt 与配色；Updates 自动检查开、自动安装关，图片保留各自真实拍摄阶段。

修复后打包应用实机检查已完成：真实 560 × 380 最小窗口的长路径、分栏、树与终端按钮保持响应，再恢复 1100 × 740；正常退出并仅将 QA 进程切为浅色后重开，恢复 Folders 可见性 / 分隔比例、两个标签及分栏，未启动 shell，浅色 Terminal Settings 控件可读。受控自动化另覆盖 560 × 360，不能混写为实机窗口尺寸。

**最终 95 份 Swift 源码：3,194 项 smoke 连续三轮通过**。`smoke-7` / `8` / `9` 分别用时 196.1 / 190.5 / 190.9 秒，均 exit 0、stderr 为空、源码未变；三份源码清单和当前文件均与 `/private/tmp/tursora-customization-qa/delivery-sources.json` 一致。逐轮 `.json` / `.out` / `.err` 与 `*-sources.json` 保存在同目录；此前 2,566 / 3,160 等历史项数不代表这份源码。

交付 release app 与本地 DMG 构建通过，strict codesign、Info.plist、arm64、根 MIT 许可证打包、DMG 只读挂载 / 安装布局核对通过；日志 `package-delivery.out`、`dmg-delivery.out`。本地 DMG 的 `0.1.0` 文件名来自当前开发包版本，不是新公开 release，也未替换已发布的 `0.1.0` ZIP。最终菜单复查与 QA 清理见[整合记录](research/customization-integration.md)。该阶段尚未推送分支或发布新版本；后续 0.2.0 合入、分发和远端 CI 结果见页首。

## 本轮：默认启用终端与 ZIP 浏览

用户要求两项功能默认开启并打磨。缺少偏好记录时默认 true，保留既有显式关闭；General 改为 Terminal & ZIP，F4 展开时才创建 shell。ZIP 加入命名的准备状态 / Cancel、失败 Retry / Open Enclosing Folder，以及启动恢复失败的 Reload 重试。最后等待者取消底层准备并清理未完成副本，关闭后重开标签再准备原目标；退出先保存一次逻辑工作区，再等传输与归档清理。

终端区分 Started in / Shell folder，始终显示启动或重启目标；自然退出保留输出和 ended 状态，拒绝旧实例与无效地址报告。实现、取舍及验证进度见[本轮记录](research/default-features-polish.md)，SPEC §16–18、D49。实机发现并修复系统路径别名下的 ZIP 修复重试及启动失败标题；最终 83 份 Swift 源码 2,566 项连续三轮通过，stderr 为空且源码哈希一致。debug / release、strict codesign / plist 通过；最终包已实测坏 ZIP 修复后重试子目录、两个失败标签的标题与切换、正常退出重开及不启动 shell。General / 终端 / ZIP 恢复真实截图和网站默认说明已更新；QA 已退出，锁已释放。该默认功能阶段结束时尚未发布新版本。

## 本轮：工作区会话恢复

用户将“退出应用后双窗格、多标签丢失”列为高优先级。本轮已实现默认开启的会话恢复选项，保存浏览窗口、标签顺序 / 名称 / 当前项、双 pane 位置与活动侧、分栏比例、侧栏状态和窗口几何 / 最小化。普通目录视图继续读取每目录视图库；已执行搜索重新查询，ZIP 只记逻辑位置并重新准备。失效目录保留路径并显示内联错误，不静默丢掉工作区。

变动防抖 0.4 秒保存，退出在 ZIP / 终端清理之前同步保存。关闭恢复选项清理文件且停止保存，重新开启保存当前布局。坏文件 / 未知版本在显式重试或关闭后重开选项前保留原字节。第一版不恢复过滤、选区、滚动、历史、已关闭标签、终端会话、传输或撤销。容量与实现细节见[会话恢复记录](research/workspace-sessions.md)、SPEC §22、D48。

最终 81 份 Swift 源码 **2,418 项 smoke 连续三轮通过**，均 exit 0、stderr 为空，源码哈希前后一致。debug / release、strict codesign、plist lint 通过；独立发布包已实测两个窗口、三个主窗口标签、不同文件视图、活动侧、真实拖动的分栏 / 侧栏、最小化及正常退出重开。完整状态重存与退出前相同；关闭选项清理并重启回到 Home、重新开启保存当前布局也通过。General 与恢复后工作区真实 PNG 已更新。未改生产 bundle id 或用户工作区，自己的 QA 进程已退出、锁已释放；日志和精确边界见上述记录。

## 已完成：公开仓库、GitHub Pages、DMG 与软件更新

仓库已公开，GitHub API 核实 Pages 已选 GitHub Actions、HTTPS 开启，目标为 <https://zerolfx.github.io/Tursora/>。新增 Pages 工作流只从 `main` 发布 `site/dist/`，相关 PR 构建校验；产品页下载按钮指向最新正式 release 并移除私有登录要求。本地构建与 `/Tursora/` 子路径浏览器检查已完成，用户已授权提 PR 并合入。已随 [PR #5](https://github.com/zerolfx/Tursora/pull/5) 合入 `main`，提交 `57e0e78` 的 [Pages 部署](https://github.com/zerolfx/Tursora/actions/runs/34707107693) 与 [Build](https://github.com/zerolfx/Tursora/actions/runs/34707107688) 成功；线上首页及六份资源返回 HTTP 200 并与本地构建字节一致，详见 [Pages 记录](research/github-pages.md)。

软件更新使用固定 Sparkle 2.9.6。Settings 分 General / Updates 两页；每日自动检查默认开且可关，自动下载安装默认关。关闭自动检查时禁用自动下载控件但保留保存的选择，手动检查仍可用；已下载或已安排退出安装的会话不被开关取消。app menu 提供 Check for Updates…，bare SPM 与 smoke 完全不构造 Sparkle。原始 `0.1.0` 没有 updater，用户必须先手动安装一次含此功能的版本。

按用户补充要求，后续 release 改为直接 DMG 下载，窗口内 Tursora → Applications 拖拽安装；原始 `0.1.0` ZIP 保持不变。固定 dmgbuild 1.6.7 及三份 wheel hash，独立 Python venv 生成两图标、箭头背景和 Applications symlink，CI 无需 Finder UI。稳定 release 将附带携带 DMG Ed25519 签名的 `appcast.xml`，feed 在 GitHub Releases 的 `latest/download/appcast.xml`，与 Pages 分开。包 build 取源码提交 Unix committer timestamp；稳定发布检查 semver 和已有 feed build 递增，prerelease 不进入稳定通道。

最终 77 份 Swift 源码 **2,158 项 smoke 连续三轮通过**，stderr 均为空；Python 工具 **70 项通过**（更新元数据 / 布局 37 + 发布说明 33）。本地 `0.1.1` 应用和 DMG 的 strict codesign、updater 元数据、独立 framework rpath、只读挂载及保存的安装布局检查通过。General / Updates 已实测布局、开关、真重启持久化及关闭自动检查后的手动检查；真实截图已更新，ZIP 开启状态和左上系统指示如实保留，两张 JPEG 已转为像素一致的真正 PNG，抠角拒绝后未修改边缘。

完整本地 Sparkle 更新已从临时 `0.1.1` 经正常签名 DMG 下载、验证、安装并重启到 `0.1.2`，bundle / About / 进程核对通过；使用临时 QA key 与 loopback feed，**不代表生产线上已通**。错误 key、同长度篡改离线签名负测通过；篡改 DMG 的 GUI 安装动作被自动审批拒绝，已放弃该动作并使用离线检查，不记为 GUI 通过。最终 DMG 在 Finder 中正常打开，两侧图标与中间箭头完整可见，640 × 280 内容窗口和无工具栏布局已目视核对；[真实截图](images/features/installation.png)已转为 PNG 保留。

生产公钥已入 Resources，私钥已存 Keychain account `com.tursora.Tursora`；用户明确授权后，仓库 `SPARKLE_PRIVATE_KEY` secret 已于 2026-09-13 00:48:20（Asia/Shanghai）配置，并通过 GitHub secret 列表核实。上传前派生公钥与 Resources 一致，临时导出已清理，未将私钥写入源码或日志；此前自动审批拦截属于历史状态。用户另已授权提 PR / 合入，该软件更新独立阶段结束时尚未发布新的稳定 release，原 `0.1.0` 标签与资产未改；后续 0.2.0 结果见页首。本机没有有效 code-signing identity，用户确认尚无 Developer ID；本轮不加入 Apple 签名脚本，待会员、证书及公证凭据就绪再独立接入，Sparkle 签名不等于公证。日志、源码哈希与精确阶段见[软件更新记录](research/app-updates.md)，发布步骤见 [RELEASING.md](RELEASING.md)。

收尾核对 77 份 Swift 源码与最终测试哈希一致。测试应用、loopback server 和测试挂载已清理，只恢复本轮更新偏好并释放实机验证锁。最终网站下载区的桌面 / 390 px 复查、静态构建和文档链接 / PNG 格式校验通过；后续 PR #5 合入与线上验证见本段开头。

2026-09-13 按用户要求参考 Rascal，README 改为下载 → 拖到 Applications → 从 Applications 打开，并新增 First launch。主要流程依据 Apple 当前官方步骤；折叠终端备选只移除该可信、同版本 SHA-256 已核验应用的下载隔离属性，说明损坏与恶意软件警告的区别。网站增加简短步骤及 README 链接。仅修改说明，未执行 `xattr` 或改系统安全设置，也未把既有安装 / 更新验证扩展为首次 Gatekeeper 拦截实测；依据见[更新记录](research/app-updates.md#首次启动说明2026-09-13)。

## 0.1.0 发布阶段：外观、搜索、Dock 与文档（历史基线）

标签栏主要参考本机 Safari：连续中性底条、居中标题、柔和胶囊形选中面和悬停关闭，固定新增按钮，过多时滚动 / 文字溢出菜单。亮暗随系统，既有补全面板、活动 pane 线与任务边框随外观刷新。分栏标题改为 `Left | Right`，不再添加活动侧括号；所有 Reveal in Finder 入口移除，搜索结果仍在 Tursora 内定位。README / 产品页不再把通用标签页作为独立卖点，产品页改为路径、双窗格与 ZIP 三种工作流。

文本图标由整页缩小改为实际开头片段，7–10 pt 等宽字、3:4 浅色纸面，两种主题使用相同文档内容。读取、编码与排版有界；列表 / 图标共用缓存，缩放、关预览、复用与屏幕倍率变化不能被旧请求覆盖。Get Info 默认仅展开 General / Preview，其他分区折叠；新主动选择与旧自动保存值分开，旧 `true` 的迁移取舍见记录。

搜索按用户确认保留“先筛当前目录”：一个工具栏输入框，有输入后提供 Search Options，再展开正文 / 范围 / 类型 / 日期和保存条件。移除重复工具栏 Search 按钮与表单名称框；递归查询按 pane 防抖 500 ms，Return 立即执行，空条件不自动扫描。中文组合输入、空名称失焦、原生清空按钮、关闭重开草稿和同目录导航提示已加入回归；[Dolphin 对照与实现](research/search-input-reference.md)。正文仍查询 macOS Spotlight 已有索引，不读每个文件兜底。

README 特性改为说明 / 截图两列表格，含 11 项功能和 2 项默认关闭的实验；按用户要求不单独宣传通用标签页或预览。22 张功能证据图统一 PNG，脚本只处理窗口外白底和窄边缘，内部与原生 JPEG 解码像素逐字节核对。配准的亮色图复用同尺寸暗色图的 alpha；歧义边缘拒绝后重拍。README 本地亮暗预览和网站桌面 / 窄屏 / 弹窗已检查，线上 GitHub 渲染未实测；[截图管线与阶段](research/screenshot-transparency.md)。

Dock 右键增加 New Window / Downloads / Applications，均打开独立窗口并保持已有 pane 与标签；[菜单证据](research/dock-menu.md)。发布前审查修复中文候选词确认后文字未变时漏掉自动名称查询的问题，真实 marked text / unmark 路径在两种视图中回归。

加入 Dock 和 IME 修复后的最终源码 **2,123 项 smoke 连续三轮通过**，三次均 exit 0、stderr 为空；发布说明工具另有 33 项标准库测试通过。日志为 `/private/tmp/tursora-tabs-appearance-verification/final-release-smoke-{1,2,3}.{out,err}`。发布后逐行复核修正了原提交说明少计 16 项的记录；最终源码 75 个文件的哈希与测试快照一致，已发布标签保持不变。

最终 `0.1.0` release 构建、strict codesign、plist、arm64 架构和包内 ICNS 核对通过，独立副本的窗口与目录导航已目视检查。Dock 的系统界面无法通过当前工具读取，因此真实 Dock 右键点击和前台激活未实测；菜单与动作通过自动化验证，详见 [Dock 记录](research/dock-menu.md)。

截图阶段的组合 2,024 项也曾连续三轮通过；该阶段 release 构建、签名、plist 和包内图标核对通过，实测系统暗色及进程浅色、560→1200 宽度、标签与分栏、路径补全、64→96 pt 文本图标、Info 初始折叠和统一搜索流程。证据：[标签与外观](research/tabs-and-appearance.md)、[文本图标](research/text-thumbnails.md)、[Info 折叠](research/info-disclosures.md)。

首个 [Tursora 0.1.0](https://github.com/zerolfx/Tursora/releases/tag/v0.1.0) 已发布，tag 指向 `b0c1c20d705b0c047742b940e36372ecb35b1a9d`。[Build](https://github.com/zerolfx/Tursora/actions/runs/34696089665) 与 [Release](https://github.com/zerolfx/Tursora/actions/runs/34696116417) 均成功。已重新下载 ZIP / SHA256SUMS 并核对：版本 0.1.0、build 1、arm64、strict codesign、SwiftTerm 资源与包内 ICNS 一致性通过；ZIP 的 SHA-256 为 `7619e8ee33ade5283bbddf0eef306892bc806811801bdd36abdb4d8682b06124`。发布当时仓库为私有、站点未部署；本轮公开状态与 Pages 工作见页首。

CHANGELOG 已改为版本历史，保留 Unreleased 供后续更新；此前开发流水移至 [DEVELOPMENT_HISTORY.md](DEVELOPMENT_HISTORY.md)。发布工作流从对应版本节提取说明并检查完整性，具体维护流程见 [RELEASING.md](RELEASING.md)。本轮只退出用于最终检查的独立副本，保留用户原有应用及已使用的演示窗口；未用旧偏好快照覆盖用户后续改动。本地预览服务器已停止，共享验证锁已释放。

## 本轮分栏路径与标签操作

每个 pane 上方显示独立地址栏；路径与补全只导航所属 pane，切换时收起未提交的路径编辑。标签栏始终可见，分栏标题固定左右顺序（原括号标记已由上方新阶段取代），支持自定义名和 Dolphin 的七项标签右键动作。Detach 按逻辑位置在新窗口重新打开，保留活动侧、自定义名和搜索请求；历史、过滤、选区、任务及撤销栈留在原窗口上下文。

最终源码 **1,500 项 smoke 连续三轮通过**，三次均 exit 0、stderr 为空；release 构建、strict codesign、Info.plist lint 和包内 ICNS 一致性检查通过。打包应用实测覆盖独立路径 / 相对导航与 Back、活动侧标题、后台标签右键目标与边界、Rename / 清空、新标签、Detach、未提交编辑取消、路径补全和 560→1200 宽窗口重排。分栏、路径与标签三张实际截图已更新；菜单展开期间截图工具不可用，七项菜单由辅助功能树与真实点击验证，标签截图为菜单关闭状态。日志、范围及 Dolphin 差异见[分栏地址栏与标签操作](research/pane-paths-and-tab-actions.md)。下面 1,253 项及各历史阶段结果仍仅代表各自阶段。

用户补充指出应用图标的方形外沿。本轮保留原尾鳍画稿，新增确定的 CoreGraphics 导出：1024 px 画布中将背景裁为 `(80, 80)` 起、864 px 宽高、192 px 圆角的单底板，外侧透明，前景不缩放或移位；PNG 与 ICNS 一起更新。旧“系统自动裁圆角”假设已撤回，像素 / 图标族回归随最终三轮通过，打包资源一致性检查通过。实际图标视图中系统读取发布包图标，外沿透明、圆角平滑；产品页桌面 / 窄屏与截图弹窗复查通过，见[图标边缘记录](research/app-icon-edges.md)。自己的测试应用已退出，偏好和目录视图库已恢复，共享验证锁已释放。

## 本轮 PR 整合

三功能整合与审阅修复已完成：最终 **1,253 项 smoke 连续三轮通过**，debug / release 构建与 strict codesign 通过；打包应用实测覆盖搜索视图隔离、目录往返恢复、大文件暂停 / 继续 / 取消、精确 Duplicate / Undo 和保存条件重跑，原文件与清理检查通过。统一见 [PR 整合记录](research/pr-integration-2026-09-12.md)。PR [#1](https://github.com/zerolfx/Tursora/pull/1) / [#2](https://github.com/zerolfx/Tursora/pull/2) / [#3](https://github.com/zerolfx/Tursora/pull/3) 和 main 的远端构建状态以对应精确提交的 GitHub 记录为准。以下各功能历史检查数不代表三功能组合结果。

提交规范改为实际模块 scope；全局或跨模块提交不写 scope。main 提交信息重写保留每个 tree、作者 / 时间及旧历史备份，原功能分支不随之重写。

## 现状

- 文件操作任务：复制 / 移动 / Duplicate、剪贴板、拖放与 ZIP 复制出共用可暂停 / 继续 / 取消的传输引擎；Window → File Operations 管理多任务和内联冲突。安全暂存、Replace 恢复、跨卷移动与 Merge 的成功项撤销、目录身份竞态及退出清理的实现与专项验证统一记录在[文件操作任务](research/file-operation-tasks.md)。该段记录原独立功能阶段。
- 文件操作任务独立阶段验证：**928 项 smoke 连续三轮通过**，均 exit 0、stderr 为空；最终 release 构建与 strict codesign 通过。打包应用已实测列表 / 图标复制、逐任务暂停 / 继续 / 取消、同卷移动冲突、撤销 / 重做、暂停 Duplicate 后退出清理，更新两张实际截图；原文件及完整副本 SHA-256 检查通过。原生拖放手势和真实独立卷尚未完成实机验证，精确范围见上述记录。该独立阶段结束时已退出自己的应用、恢复偏好并释放共享验证锁。
- **每目录视图属性独立阶段**：`codex/directory-view-properties` 基于 `fbb6762`，Application Support 中独立保存默认值和目录记录，支持两种视图缩放、排序、分组、隐藏与预览。View / Settings 提供每目录或统一默认策略、保存当前默认和目录恢复。普通同目录 pane 重新进入读取最近保存值，统一策略同步普通 pane。按规范化路径记忆，symlink 换目标在刷新时更新身份，ZIP 无持久化记录；不做会话恢复。**854 项 smoke 已连续三轮通过**，最终 release / strict codesign 通过；最终发布包已实机复查目录往返、分栏、策略 / 默认菜单和真实重启，截图见[本功能验证记录](research/computer-use-2026-09-12-directory-views.md)。
- 新增独立搜索（⇧⌘F）：递归名称、Spotlight 正文、类型 / 日期和保存条件；每 pane 独立，结果按真实 URL 操作。未索引普通目录名称可用，正文受格式 / 索引限制；ZIP 内不支持搜索。搜索专项验证见 [search-verification.md](research/search-verification.md)。整合时搜索继承启动 pane 的视图，后续显示修改不写来源目录或统一默认，普通目录策略通知也不重置搜索；返回目录时重新读取保存值。复制 / 移动 / Duplicate 使用共同任务和真实源 URL，完成与撤销刷新当前搜索。组合验证状态见本页开头。

- 2026-09-12 历史基线：此前 42 个提交已 squash 成一个基线并 force-push，工作树内容保留。图标采用两块蓝色玻璃窗格形成抽象尾鳍，前景宽度约为画布的 67%；当时背景满版、依赖系统圆角的做法已由本轮透明轮廓导出取代。原画保存在 `app/Resources/AppIcon-artwork.png`，导出的 PNG / ICNS 位于同目录，打包嵌入后者。

- **Tursora**（原名 Otter File Manager，2026-09-11 改名）是 Swift + AppKit 原生 macOS 文件管理器，无 Xcode 工程，Command Line Tools 即可构建；终端使用 SPM 固定的 SwiftTerm 1.15.0。基础功能包括：地址栏（面包屑 + 兄弟目录菜单 + 行内补全）、标签页、Dolphin 式分栏、列表 / 图标视图与缩放预览、文件操作与撤销、拖放、Quick Look、过滤、Finder 的分组、Finder 的 Get Info / Inspector / Summary。现已加入 ZIP 压缩 / 解压、系统分享、NetFS 服务器连接与设置；终端面板、ZIP 只读浏览默认启用，可在设置中关闭。规格见 [SPEC.md](SPEC.md)。
- 三项功能 PR #1 / #2 / #3 已合并到 `main`，提交信息重写后的整合基线为 `5a6d786`。发布包 `app/build/Tursora.app` 由 `app/tools/make-app.sh` 生成，ad-hoc 签名，未上架、未公证。
- 仓库：https://github.com/zerolfx/Tursora（已公开）。`upstream/` 是 git-ignored 的 KDE 源码 checkout，只有 Phase 0 审计和对照 Dolphin 语义时用到；缺了可以重新 clone（版本 pin 在 [audit/00-ground-truth.md](audit/00-ground-truth.md)）。

## 验证状态——统一入口

- **独立搜索阶段**：原生正文查询修复、递归结果、保存条件与同名文件操作已完成；891 项 smoke 连续三轮通过，debug / release 构建及 strict codesign 通过；完整验证范围见[搜索专项记录](research/search-verification.md)。
- **每目录视图阶段 `eac9ffc` 与整合检查**：854 项 smoke 连续三轮通过，debug / release 与 strict codesign 通过；已实机检查逐目录 / 统一策略、默认与恢复菜单、分栏和真实重启。合入产品页阶段 `ae5e47a` 后，再次完成 854 项 smoke 连续三轮，均 exit 0、stderr 为空，debug / release 与 strict codesign 通过；整合未改变应用界面代码，沿用原阶段实机证据，未重复驱动整合包。`d309d87` 的 GitHub Build 已通过，下载产物的校验和与严格签名也通过。独立 review、布局回归、阶段边界及截图见[本功能记录](research/computer-use-2026-09-12-directory-views.md)。
- **已提交阶段 `fbb6762`**：739 项 smoke 连续三轮通过，均 exit 0、stderr 为空；最新路径重映射修复的 release build 5 已重建并通过 strict codesign。日志、CUA 操作范围、13 组截图和偏好恢复证据统一保留在[同 pane ZIP 实机记录](research/computer-use-2026-09-12-inline-zip.md)。
- **产品页阶段 `ae5e47a`——应用与产品页已验证**：删除未使用的 PlacesModel 常量，简化始终为 true 的归档读取参数，不改变应用行为；该阶段重新完成 739 项 smoke 连续三轮，均 exit 0、stderr 为空，debug / release build 6 与 strict codesign 通过。新增真实标签页截图。中文产品页仅介绍地址栏、标签、分栏和 ZIP，已按 [site/README.md](../site/README.md) 完成静态构建、资源引用校验与桌面 / 窄屏浏览器 QA；功能切换、图片弹窗焦点恢复、锚点直达及无 JavaScript 回退均已检查。站点仅在本地预览，未部署。具体日志与阶段边界见[同日记录](research/computer-use-2026-09-12-inline-zip.md#整理阶段与产品页)。
- **历史结果**：[早期实机记录](research/computer-use-2026-09-12.md)包含旧独立 ZIP 窗口及先前 UI 修复。历史测试和 D28 保留原貌，不作为当前实现的新增验证。
- **外部验证边界**：真实服务器认证、挂载与读写未验证；0.1.0 已发布并完成产物校验，见本页顶部；历史 [fbb6762 Build](https://github.com/zerolfx/Tursora/actions/runs/34671658320) 及后续 [Build 运行列表](https://github.com/zerolfx/Tursora/actions/workflows/build.yml) 保留各阶段记录。产品页已随 PR #5 上线，见页首部署证据。

**仍需专项视觉检查的东西**：

- 地址补全弹窗、Kind 组头与活动 pane 强调线已做基础检查，尚未覆盖全部边界；拖放的分栏高亮层仍需专项检查。
- Get Info 的文本文件简介排版已检查并修复宽度；长文件名、卷、多选汇总的视觉边界与 Inspector 浮动跟随手感仍需专项检查。
- 菜单栏和右键菜单里 SF Symbol 图标在 macOS 26 上的显示。
- 图标视图在超大档位（256 / 512）下的布局。
- 亮暗标签、分栏、搜索与文本图标已在本轮检查；尚未逐一覆盖全部弹窗、分享服务和真实多显示器切换。

用户反馈过、已修的问题都进了 smoke test；修 bug 时先写能复现的 check。

## 已知问题与小差距

- 浏览 pane 在**外部**改名后选择会丢（Info 窗口按 inode 能跟上，pane 还不能）。
- Get Info 里文件夹大小不随内容变化实时更新（为避免 FSEvents 风暴，只监听本项和同级）。
- 分组的 Size 桶边界与 Kind 组顺序仍是推断，"Earlier" 键未用。
- Finder 的 Get Info 里 Stationery pad、ACL、改 owner / group、Apply to enclosed items 没做。
- 快捷键与 Finder 有几处冲突（⌘1–4、⌘L、⇧⌘T、⇧⌘P、⌥⌘S），是有意的，见 [DECISIONS.md](DECISIONS.md) D9。
- 已有 General / Shortcuts / Terminal / Updates 设置：扩展名只改显示、所有应用命令快捷键可配置、终端 Shell / 字体 / 颜色可配置，每目录 / 统一默认视图策略已实现；本轮验证与发布进度见页首。会话恢复已实现，当前验证进度见页首；其他偏好策略、本地化仍未实现。
- 搜索支持普通目录递归名称与 Spotlight 正文，正文受索引 / importer / 权限限制，真实正向正文命中尚未验证。单次最多展示 50,000 项，Spotlight 最多检查 50,000 个候选；没有 ZIP 内搜索、Tags / 评分条件、Finder `.savedSearch` 互通或实时结果增量。
- 终端工具栏 / 默认 F4 入口默认启用，首次展开才启动 shell；每窗口一个 PTY，收起保留，浏览导航只更新手动 Restart 目标，Restart / 关窗 / 退出的任务确认见页首；在 ZIP 内启动 / Restart 使用原 ZIP 所在目录。ZIP 浏览默认启用，Open 在当前 pane 进入；地址栏保留原 ZIP 加内部目录的逻辑路径。归档只读，复制 / 拖出只复制，Quick Look / Share / Open 使用临时副本，不写回归档，副本保留到退出。关闭 ZIP 浏览开关后已有页仍只读，新打开 ZIP 恢复 Extract。
- 归档与服务器新增功能边界：仅普通 ZIP；远程走系统 NetFS 挂载，不含自建 SFTP / 重连；真实服务器读写还未验证。`FileOperations.report` 和 Eject 错误路径已防止 smoke 模式弹模态框。

## 下一步

[ROADMAP.md](ROADMAP.md) 按成本排了序；每项的难度依据在 [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md) 和 [gaps/GAP-vs-DOLPHIN.md](gaps/GAP-vs-DOLPHIN.md)。最便宜且最常用的一批：Deselect All、Move Items Here、New Folder with Selection、Show Package Contents、Go 菜单的标准文件夹快捷键、Services 菜单。会话恢复已在本轮优先实现，验证状态见页首。

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

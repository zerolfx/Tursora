# 交接说明（2026-09-13）

给接手这个项目的人或 agent。先读这一页，再按 [README.md](README.md) 的索引找细节。

## 本轮：默认启用终端与 ZIP 浏览

用户要求两项功能默认开启并打磨。缺少偏好记录时默认 true，保留既有显式关闭；General 改为 Terminal & ZIP，F4 展开时才创建 shell。ZIP 加入命名的准备状态 / Cancel、失败 Retry / Open Enclosing Folder，以及启动恢复失败的 Reload 重试。最后等待者取消底层准备并清理未完成副本，关闭后重开标签再准备原目标；退出先保存一次逻辑工作区，再等传输与归档清理。

终端区分 Started in / Shell folder，始终显示启动或重启目标；自然退出保留输出和 ended 状态，拒绝旧实例与无效地址报告。实现、取舍及验证进度见[本轮记录](research/default-features-polish.md)，SPEC §16–18、D49。实机发现并修复系统路径别名下的 ZIP 修复重试及启动失败标题；最终 83 份 Swift 源码 2,566 项连续三轮通过，stderr 为空且源码哈希一致。debug / release、strict codesign / plist 通过；最终包已实测坏 ZIP 修复后重试子目录、两个失败标签的标题与切换、正常退出重开及不启动 shell。General / 终端 / ZIP 恢复真实截图和网站默认说明已更新；QA 已退出，锁已释放。未发布新版本。

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

生产公钥已入 Resources，私钥已存 Keychain account `com.tursora.Tursora`；用户明确授权后，仓库 `SPARKLE_PRIVATE_KEY` secret 已于 2026-09-13 00:48:20（Asia/Shanghai）配置，并通过 GitHub secret 列表核实。上传前派生公钥与 Resources 一致，临时导出已清理，未将私钥写入源码或日志；此前自动审批拦截属于历史状态。用户另已授权提 PR / 合入，新的稳定 release 尚未发布，原 `0.1.0` 标签与资产未改。本机没有有效 code-signing identity，用户确认尚无 Developer ID；本轮不加入 Apple 签名脚本，待会员、证书及公证凭据就绪再独立接入，Sparkle 签名不等于公证。日志、源码哈希与精确阶段见[软件更新记录](research/app-updates.md)，发布步骤见 [RELEASING.md](RELEASING.md)。

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
- 已有 General / Updates 设置：扩展名只改显示、过滤快捷键可录制，每目录 / 统一默认视图策略已实现；软件更新开关与发布进度见页首。会话恢复已实现，当前验证进度见页首；其他偏好策略、本地化仍未实现。
- 搜索支持普通目录递归名称与 Spotlight 正文，正文受索引 / importer / 权限限制，真实正向正文命中尚未验证。单次最多展示 50,000 项，Spotlight 最多检查 50,000 个候选；没有 ZIP 内搜索、Tags / 评分条件、Finder `.savedSearch` 互通或实时结果增量。
- 终端 F4 入口默认启用，只有展开面板才启动 shell；每窗口一个 PTY，浏览导航只更新手动 Restart 目标，Restart / 关闭面板会结束会话；在 ZIP 内启动 / Restart 使用原 ZIP 所在目录。ZIP 浏览默认启用，Open 在当前 pane 进入；地址栏保留原 ZIP 加内部目录的逻辑路径。归档只读，复制 / 拖出只复制，Quick Look / Share / Open 使用临时副本，不写回归档，副本保留到退出。关闭 ZIP 浏览开关后已有页仍只读，新打开 ZIP 恢复 Extract。
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

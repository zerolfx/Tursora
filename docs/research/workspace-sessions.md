# 工作区会话恢复（2026-09-13）

## 产品范围

用户将退出后失去双窗格与多标签列为日常使用的关键障碍，本轮优先实现启动恢复。此功能是 Tursora 的产品选择，没有宣称逐项复制 Finder 或 Dolphin 的会话语义。

Settings → General → Startup 的 **Reopen windows and tabs on launch** 默认开启。重新启动恢复浏览窗口、窗口几何与最小化、侧栏宽度与折叠、标签顺序与当前标签、自定义名称、每标签一至两个 pane、活动侧和分栏比例。普通目录的模式、排序、分组和缩放仍由既有每目录视图库读取。

已经执行的搜索保存条件并重新查询，结果以当前文件为准。ZIP 保存原归档加内部目录的逻辑路径，重新启动重新准备只读内容；不能保存已提取临时目录作为工作位置。关闭 ZIP 实验选项时，能识别为真实归档的位置退回归档父目录；离线位置保留原路径，不根据 `.zip` 后缀猜测，因为它也可能是普通目录。

第一版不保存过滤文本、选区、滚动、导航历史、已关闭标签、终端进程 / 面板、传输任务或撤销栈。关闭的窗口和标签不复活；退出时没有浏览窗口则下次打开 Home。失效或未挂载位置保留路径并沿用内联错误，允许之后刷新或导航，不静默替换为 Home，也不自动挂载服务器。

## 存储与生命周期

- `WorkspaceSessionStore` 在 `~/Library/Application Support/Tursora/WorkspaceSession.json` 保存版本 1 JSON；不往浏览目录写任何文件。
- 有效变动防抖 0.4 秒保存；退出同步保存最终快照，随后才清理 ZIP 临时内容、终端和撤销日志。
- 同目录暂存文件先以 0600 权限创建，写入并同步后原子 rename。错误保留旧文件；设置显示错误和重试动作。
- 最多 16 个窗口、每窗口 32 个标签、每标签两个 pane，单文件最多 2 MiB。读取逐项丢弃无效结构并修正选中位置。当前工作区超过窗口 / 标签容量时保存报错并保留旧文件，不能静默截断。
- 非本地 URL、凭据、NUL 路径和无效几何被拒绝；路径存在性留给异步浏览，避免把临时离线当作永久删除。
- 损坏、未知版本或读取失败的文件保留原字节；启动和退出不能自动覆盖。用户点击 Retry Saving Workspace 或关闭后重开恢复选项，才用当前工作区重新保存。
- 关闭恢复选项立即清理保存内容并停止自动保存；重新开启保存当前窗口，不立即替换当前布局。清理失败也有内联重试。
- 启动前收到明确打开目录请求时仍恢复保存内容，并将明确请求的窗口置前。窗口位置根据当前显示器可用区域约束，移除的显示器不会让恢复窗口留在屏幕外。

## 侧栏宽度诊断

诊断第 4 轮确认窗口为 1000 × 640，测试找到实际侧栏 `NSSplitView` 并调用 `setPosition(245, ofDividerAt: 0)` 后再布局，侧栏仍回到 160 pt；不是窗口过窄。早先测试直接将 `sidebar.view.superview` 当作 split 的层级假设也已更正。

本机 SDK 证据位于 `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSSplitView.h`：第 79 行说明 `setPosition` 按用户拖动同样受约束；第 83–86 行说明 holding priority 应低于 `NSLayoutPriorityDragThatCannotResizeWindow`（490），较低优先级的 pane 先吸收窗口尺寸变化。`NSSplitViewItem.h` 第 115–116 行确认 item 的同名属性控制宽度保持优先级；默认值为 250。

原侧栏配置为 `.defaultHigh`（750），高于拖动优先级。生产修复改为 **260**，仍高于内容 pane 默认的 **250**，低于拖动的 **490**；不添加固定宽度约束，保持用户调整与收起 / 展开能力。修复已随最终三轮通过；打包应用真实拖动从 190 调到 245 点，重新启动仍为 245 点，见下方实机记录。

## 验证边界

模型和存储检查覆盖 JSON round trip、逐条损坏、容量、选择修正、权限、原子发布失败与重试、未知版本和旧字节保护。UI / 生命周期检查覆盖两种文件视图、后台标签、窄到宽分栏、搜索重跑、真实 ZIP 重新准备、失效路径与开关、立即退出保存和显式启动请求。

最终 81 份 Swift 源码 **2,418 项 smoke 连续三轮通过**，每轮 exit 0、stderr 为空，运行前后源码哈希一致。测试修正了侧栏原生祖先层级、固定窗口宽度与 macOS `/var` / `/private/var` 等价位置比较；真实侧栏优先级修复见下文。

审阅另外修复了 ZIP 导航失败后保存位置没有回到仍在显示的目录、Clear 搜索未触发自动保存，以及关闭恢复后清理失败在退出时未重试。三条均加入了真实路径回归；上述路径均随最终三轮通过。

## 发布包与真实重启

debug / release 构建、strict codesign 和 Info.plist lint 通过。测试副本使用独立 bundle identifier `com.tursora.sessionqa.s0913`、会话文件及每目录视图库；产品 bundle identifier 保持 `com.tursora.Tursora`。两包机器码 `__TEXT.__text` 哈希一致，重新签名造成的完整文件差异不误记成字节一致。QA 关闭 Sparkle 自动检查，不接触生产偏好或会话文件。

通过真实界面从一个演示目录建立 2 个窗口：主窗口含 Daily work / Inbox / Archive 三标签，Daily work 左侧 Design 为列表、右侧 Assets 为图标且活动；真实拖动侧栏到 245 点、双 pane 比例到 0.5738569753810082，第二个 Archive 窗口最小化。正常 ⌘Q 后重新启动，标签名与顺序、所选标签、活动右侧、两种视图、比例、侧栏、窗口位置 / 大小及一个最小化窗口恢复。切换标签后再次自动保存，完整 JSON 与首次退出快照相同。

Settings → General 的开关实际取消后文件立即消失；正常退出再启动只打开 Home 的单标签窗口，设置仍关闭。导航到演示 Design 后重新开启，保存的是当前单窗口，未复活先前布局。三次 QA 进程均正常退出，验证锁已释放。

真实截图：[恢复后的工作区](../images/features/workspace-restored.png)、[General 启动选项](../images/features/settings.png)。原生捕获是 JPEG，使用 `sips` 转成真正 PNG并重新目视检查，保留原始外沿、系统共享指示与鼠标位置；未生成或修饰 UI 像素。窗口分别为 1100 × 712 和 540 × 737。

自动化覆盖失效目录、ZIP 重提取、坏文件和未知版本、退出清理失败等；本轮实机范围是本地演示目录与重启设置，没有将模拟离线路径或屏幕几何测试记成真实外接卷 / 多显示器实测。未发布新 release。

证据目录：

- `/private/tmp/tursora-session-verification/final-smoke-{1,2,3}.{out,err}`、`final-results.json`、`final-source-hashes.json`；每轮 2,418 项。
- `/private/tmp/tursora-session-verification/package-final.log`；发布包构建。
- `/private/tmp/tursora-session-e2e/after-first-quit.json`、`after-restored-interaction.json`、`ui-results.json`、`bundle-evidence.json`，原始截图与 AX 文本同目录保留；QA 文件不提交。

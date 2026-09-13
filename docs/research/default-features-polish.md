# 默认启用终端与 ZIP 浏览（2026-09-13）

> 0.2.1 已取代本文早期的目录跟随与终端栏布局：zsh 在安全提示符单向跟随浏览目录，顶部精简为一行，底部不再显示终端状态或可用容量。当前行为与本轮验证见[0.2.1 记录](terminal-navigation-0.2.1.md)；本文原有检查数、截图与操作记录保留其历史阶段，隐藏保留和终止前确认仍有效。

> 本页记录 `b58c1ce` 的历史阶段。后续终端设置和收起保留 / 退出确认见[终端自定义](terminal-customization.md)与[会话生命周期](terminal-session-lifecycle.md)；下文 F4 回收和退出顺序只代表当时实测。

用户要求两项功能默认开启，并继续打磨首次使用与日常操作。新代码保留原 UserDefaults 键，缺少记录时读取 true；已有 false 不被覆盖。显式设置值即使与当前默认相同也落盘，但只在实际显示值改变时发通知。旧版未写入的默认 false 无法与从未选择区分，不猜测迁移意图。

General 的分组改为 Terminal & ZIP。终端按 F4 展开时才建立 shell；新窗口、导航、恢复工作区和勾选选项本身都不启动终端。ZIP 默认 Open 在当前 pane 浏览，明确 Extract 仍解压并支持撤销。关闭选项后，普通目录里的新 Open 恢复解压，既有只读页不被破坏。

## ZIP 打磨

准备期间在所属 pane 中显示 Opening 文件名与 Cancel。Escape 只在文件视图聚焦时取消，Back 也取消；离开目录或关闭 pane / 标签 / 窗口会释放自身准备订阅。原目录与选区在失败 / 取消时保留，没有旧目录的恢复启动取消后回 ZIP 所在目录。失败提供 Retry 和 Open Enclosing Folder，Reload 也重试保留的逻辑目标。关闭标签中止准备，重新打开该标签才再次准备。尚未建立 currentURL 的启动页以请求位置命名标签和窗口，失败后仍保留实际名称；该显示回退不改变文件操作的位置。

`ArchiveWorkspace.prepare` 返回订阅；每个等待者独立取消，最后一个等待者取消底层准备。每次工作有独立 ID，取消后立即重试同一 ZIP 时，旧完成不能覆盖新工作。已准备且可能被外部应用读取的副本仍保留至退出。

提取 token 在进程启动 / 退出、隔离属性传播和发布边界检查取消。`cancel()` 不在主线程等待子进程；worker 回收子进程后清理私有目录，退出 barrier 等待全部在途工作。AppDelegate 第一次终止请求先同步保存工作区，随后取消传输和归档准备，清理完成后回复 AppKit；最终 willTerminate 不再覆盖第一次捕获的位置。

实机检查发现系统目录别名的恢复边界：已有 ZIP 的 `/private/tmp` 前缀可能被 Foundation 标准化为 `/tmp`，但不存在于物理文件系统的 ZIP 成员路径保留原前缀。注册表现在匹配 ZIP 父目录的规范路径，再按成员组件映射快照；不解析成员 symlink，也不把指向原 ZIP 的普通 symlink 当作快照根。

条目枚举只跳过在目录列举后消失的成员；权限和其他错误仍报告。归档依旧完整解压、只读、不写回，不增加密码或其他格式支持。

## 终端打磨

标题为 Terminal。状态行以 Started in 表示启动目录；只有当前终端实例报告了有效的本地 OSC 7 地址才显示 Shell folder。默认 shell 未必发送 OSC 7，不能把启动目录描述成实时目录。独立第二行始终显示 Restart in / Start in 的完整可见目标（长路径截断并保留 tooltip）。浏览导航仍不注入 cd。

明确区分 ready / running / ended / failedToStart；自然退出保留输出，导航不覆盖结束提示，按钮变为 Start in Current Folder。关闭后的回调、旧终端实例回调和非本地 / 含凭据等无效 file URL 被忽略。沿用当前会话的关闭与 PID 回收规则，不恢复终端会话。

## 验证

初版 83 份 Swift 源码完成 **2,557 项 smoke 连续三轮通过**，均 exit 0、stderr 为空，源码哈希前后一致。覆盖隔离偏好默认值 / 已存关闭选择、两种文件视图的默认 Open 和显式 Extract / Undo、共享任务取消与旧完成竞态、坏 ZIP 启动恢复重试、终端头部状态 / 回调身份及现有 PTY 测试。该结果早于实机发现的系统路径别名和启动标题修复。修复后最终 83 份 Swift 源码 **2,566 项 smoke 连续三轮通过**，三次均 exit 0、stderr 为空，源码哈希前后一致；包含系统目录别名重试和准备中 / 失败后 / 切换标签的实际标题回归。

初次及最终 debug / release 构建、strict codesign 和 plist lint 通过；最终发布构建日志为 `package-final.log`。独立 QA 副本只更改自己的 bundle id 为 `com.tursora.featuresqa.s0913`，重新签名之前的可执行文件与生产构建逐字节一致（QA 签名会改变可执行文件内的签名数据）；使用自己的会话 / 目录视图文件和示例文件，不修改生产偏好或工作区。所有 smoke、打包和应用操作通过共享锁串行进行。

本轮实际界面操作已确认：

- 新实例的 General 中两项默认勾选；主窗口没有终端面板，所属进程树没有 shell。F4 打开后出现一个 zsh，F4 关闭后回收；重启恢复 ZIP 也不启动 shell。
- 文件窗格从 Sample Files 进入 Design，终端仍显示 Started in 原位置，Restart in 指向 Design；真实 `pwd` 输出仍为原目录。`exit` 后输出保留，提示 Session ended，按钮变为 Start in Current Folder；再导航不覆盖结束状态，点击 Start 可启动新 shell。
- 普通双击 ZIP 默认进入只读浏览。损坏 ZIP 显示文件名、错误原因、Retry / Open Enclosing Folder，重试未修复文件仍保留原目录和选区，返回所在目录可用。十万条目 ZIP 的 Opening / spinner / Cancel 实际可见，另一轮成功点击 Cancel 后回到原目录并保留所选 ZIP。
- 正常退出并重开恢复到 Sample.zip/Notes，两个成员、面包屑及只读状态正确。首次以 `/private/tmp` 坏 ZIP 内路径启动的修复后重试暴露了上述别名问题，已加入模型回归；最终重新打包后，实际启动的两个坏 ZIP 标签分别显示 Broken.zip / Notes，切换时窗口标题也正确。修复原 ZIP 后点击 Retry 成功进入 Notes，两个成员和只读状态正确；正常退出再启动仍保留两个标签、所选 Notes 和内部位置，所属进程树没有 shell。

隔离进程树记录、AX 状态与原始截图保存在 `/private/tmp/tursora-default-features-e2e/`。三轮 smoke 的早期日志为 `/private/tmp/tursora-default-features-verification/final-smoke-{1,2,3}.{out,err}`；修复后的最终日志为同目录 `recovery-final-{1,2,3}.{out,err}`，结果和源码快照为 `recovery-final-results.json` / `recovery-final-source-hashes.json`。第一次界面截图发生在别名 / 标题修复之前，设置、终端和普通目录失败提示未被这两个修复改变。

更新的 `settings.png` 为 540 × 737，`terminal.png` 和[ZIP 恢复截图](../images/features/zip-recovery.png)为 1100 × 712。原生截图均为 JPEG 字节；标准抠角工具因无法确定稳定外边缘拒绝处理，随后仅用 sips 转为真实 PNG。ImageIO 核实转换前后全部 RGBA 像素一致，未修改系统指示、控制状态、窗口边缘或其他 UI。

网站静态构建通过（4 份 canonical assets、34 处引用），修改的默认说明在 1200 px / 390 px 浏览器视口中可读且无水平溢出；ZIP 工作流的默认徽标、原截图及设置链接也已检查。没有重做未改动的图片查看器 / 全部键盘交互。终端当前实例 OSC 7 的有效 / 无效报告与隔离 PTY 子进程取消由自动化验证，本轮手动 shell 不自动发送 OSC 7，不将其描述为自动目录跟踪实测。没有发布新应用版本。

收尾：最终 QA 两次正常退出均 exit 0，所属进程树为空，验证锁已释放。83 份源码与最终三轮哈希一致。生产 bundle id、用户偏好、用户工作区和已发布的 0.1.0 均未改动。

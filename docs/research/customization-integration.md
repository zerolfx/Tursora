# 快捷键、终端、文件树与分发整合（2026-09-13）

本轮从公开 `main` 的 `b58c1ce` 快进后创建 `codex/customization-and-distribution`。按用户明确选择加入 MIT；文件树在核对 Dolphin 后实现；工具栏新增的是终端开关。

三个 agent 分别负责快捷键、终端 / 树专项测试、分发 / 文档 / 截图管线；主任务负责终端工具栏、文件树与窗口 / 会话集成、统一 smoke 和实际打包应用检查。没有新建用户侧任务、推送分支、发布版本或部署网站。

## 隔离与证据

- 验证锁：`/private/tmp/tursora-shared-verification.lock`，所有 smoke 与 GUI 由主任务串行执行；不与其他任务同时操作测试应用。
- 日志：`/private/tmp/tursora-customization-qa/`。`session.py` 记录每轮退出码、检查数、stderr 字节数和 Swift 源码前后 SHA-256 清单。每轮 smoke 自身保存 / 恢复覆盖到的偏好，包含新 shortcut 和 terminal map。
- GUI 副本：该目录内 `Tursora QA.app`，仅此副本标识 `com.tursora.customizationqa.s0913`；工作区和每目录视图库指向该目录中的独立 JSON，外观通过已有进程级测试变量分别检查暗色、浅色。生产 bundle id、用户偏好和用户工作区保持原样。
- 终端测试只在明确打开面板后启动。GUI 的 zsh 用该目录的 `ZDOTDIR`，没有更改用户 shell 配置。`/bin/bash` 自定义选择已通过实际新会话提示确认；真实受控 PTY 断言由终端专项 smoke 负责。

## 整合中修正

- 临时路径测试不能假设 Foundation `resolvingSymlinksInPath()` 保留 `/private/var` 拼写；测试用文件系统实际身份，产品全树跟随用后台物理祖先并按需保留 `/private`。
- 字号原来只按 Return 保存；改为 Return / Tab / 失焦均提交，同时保留尚未 Apply 的 shell 与颜色草稿。
- 快捷键不把 `+` 固定为美式 Shift–Equals；按当前输入源判断等价，不重写保存的字符。功能键使用 SDK 键码映射，避免空 characters 使 F6 录制失败。
- Shortcuts 程序化重载 / 重选期间抑制旧行选中回调，避免命令目标被旧 row 改写；初始选中项滚到可见区域。
- 树的排队刷新完成后才满足路径定位回调；过期树及被移除的加载节点清理回调，避免引用循环；选中行在最终布局中完整可见，手动滚动查看其他分支不被刷新强行拉回。

## 实机已观察

- General 四页布局、两个默认开启的功能入口；Updates 自动检查开关与自动下载控件联动。
- 终端工具栏打开 / 收起、选中状态与当前快捷键 tooltip 同步。多个命令间保留环境变量；字体 / 背景实时更新且旧输出保留，shell 选择下次启动生效；无效 shell 使用内联错误。
- 录制 Cmd-T 的冲突被拒绝；改成 Control-Command-T 后真实收起成功。修复后的 F6 可以录制，并且在文件区和终端内真实打开 / 收起。
- 字号输入 16 后按 Tab，stepper、预览及保存值一起更新；之后恢复演示用 14。
- F7 显示独立 Folders 与 Places。修复后的打包应用中，底部选中行完整可见；拖动两面板分隔线后仍能跟随，单击 Model 导航、右键 UI → Open in Other Pane 保留左侧并激活右侧。
- 安装图取自本轮实际生成并校验的 DMG，只读挂载，不安装镜像内 app。专用 Finder 窗口隐藏工具栏并完整显示两个图标；同一个浏览窗口在相同 641 × 281 几何中切到空目录拍暗色参照，再回到镜像拍最终源图。安装图内部白底是原始内容，只有窗口外沿透明化。

- AppKit 的 shouldExpandItem 是权限查询；旧实现会在辅助功能读取时加载并逐步展开其他 Home 子目录。现改为无副作用查询，只有实际 didExpand 才加载；修正后的实际截图和 AX 查询中，其他目录保持收起、Loading 状态结束。
- 窄窗实测发现既有面包屑 layout 每次重建省略按钮及反复切换根箭头可见性，形成布局循环；主线程采样定位后改为稳定控件与按需更新。修复后实际从 1100 × 740 拖到最小 560 × 380，双窗格、长路径与树保持响应，终端按钮仍可见并能打开 / 收起；再拖回原尺寸和正常退出通过。自动检查另覆盖 560 × 360 等受控窗口尺寸。
- 仅 QA 副本切换进程级浅色外观后重开，目录树显示状态、分隔比例、双窗格与两个标签恢复，终端未自动创建；浅色列表 / 树及 Terminal Settings 的字体、颜色、路径控件可读，随后正常退出。系统外观与生产偏好未改。
- 快捷键追加 Inspector 改绑后 Summary 替代菜单独立显示，以及 Forward Delete 对应菜单字符、与 Backspace 区分的回归。
- 最终 `package-delivery` 二进制的隔离副本中，Shortcuts 将终端录成 ⌘⌦；关闭 Settings 后真实按键打开终端，在终端内再次按同键收起，工具栏状态及提示同步更新。最终窗口截图观察完成，随后正常退出；应用清单确认专用 QA 应用已结束。

## 截图与网站

29 张 canonical PNG 全部通过 alpha 校验及亮暗背景 / 四角视觉检查；原 20 张保持字节一致，6 张旧不透明图重拍、新增 Shortcuts / Terminal Settings / Folders 三张。所有处理图保护区与原始 ImageIO 解码像素一致，详见[截图审计](screenshot-audit-2026-09-13.md)。各实际截图保留其拍摄阶段，不把较早的未变页面说成在最后一份二进制中重新拍摄。

网站构建 4 份资产、36 个引用通过；1200 × 850 与 390 × 844 实际浏览无横向溢出，免费 / MIT / Homebrew 说明、ZIP 图片查看器与 Escape 焦点恢复通过。浏览器 viewport 已重置、临时页和 loopback server 已关闭。

## 最终验证状态

最终连续三轮 smoke 全部通过：smoke 7 / 8 / 9 每轮 3,194 项，耗时分别 196.1 / 190.5 / 190.9 秒，退出码均为 0、stderr 均为空。三份源码清单及当前全部 95 份 Swift 源码 SHA-256 与 `delivery-sources.json` 一致。

smoke 1–3 记录初期断言与选择问题；smoke 4 的 3,160 项通过属于后续 AppKit 修正前阶段；smoke 5 的辅助功能数组 Swift 桥接崩溃已改为保留 NSArray 的 Objective-C 查询；smoke 6 暴露原生菜单的 Forward Delete 字符匹配差异，已修复。此前轮次保留，不计入最终连续通过数。

最终 debug 构建、release app、DMG 均成功；严格签名、arm64、版本 / plist、应用内 MIT 原文一致性和 DMG 只读挂载 / 布局检查通过。应用可执行文件 SHA-256 为 `80eb5ae9aef933107eae53323b48465d82fadc14ef2c7db6f705b178bbf9daf2`；本地 DMG 为 `260821113afd691ea615e9c952b6f4d69531b0fd6c7cee61df28605ea6b6513a`。打包日志为上述目录中的 `package-delivery.out`、`dmg-delivery.out`。

Python 工具检查共 83 项通过，含截图处理、alpha 验证及 Homebrew 生成器；Homebrew 隔离安装 / 卸载与网站实际浏览证据见各专项记录。专用应用、浏览器页、loopback server 和只读镜像均已关闭 / 卸载，主任务已释放验证锁。构建产物保持本地；分支推送、远端 CI、网站部署及包含这些功能的新版本发布尚未执行。（2026-09-13 补记：这些内容随后已随 0.2.0 / 0.2.1 发布，见[发布核验](release-0.2.0.md)；本记录其余内容为当时的整合阶段证据。）

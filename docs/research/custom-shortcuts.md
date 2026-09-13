# 全应用快捷键设置（2026-09-13）

本轮把原先仅可修改 Filter 的录制器扩展为完整应用命令目录。此记录描述实现边界与专项证据；本阶段最终组合 smoke 与实机范围见[定制功能整合记录](customization-integration.md)。

## 命令目录与持久化

`MainMenu.shortcutDefinitions()` 从无副作用的菜单声明生成目录；同一 selector 通过 representedObject 区分分组 / 排序，通过专用后缀区分 Edit Location / Go to Folder。动态标题仍保留最初稳定 ID，因此 Split View 改为 Close Right Pane、Close Tab 改为 Close Window 不会丢失绑定。所有菜单命令包括尚未分配默认键的 Compress、Extract、软件更新等都可编辑。

额外目录覆盖 Return / Enter 改名、Space Quick Look、取消 ZIP 准备、Control-Tab / Control-Shift-Tab、Command-Equals 和九个标签位置。每个替代键独立显示，不因清空主菜单绑定而悄悄消失。旧的 Use Groups 与 Group By None 同为 Control-Command-0 是歧义，现保留前者，None 默认不绑定但仍可自行指定。

`ShortcutStore` 用 `keyboardShortcutOverrides.v1` 的 JSON Data 保存覆盖；缺项表示默认，显式空项表示用户清除。旧 Filter 的 key / modifier 仅在新映射没有该项时读取。未知 ID 被忽略并在后续保存时保留；坏数据 / 错误格式 / 冲突覆盖回退为安全默认，读取不覆盖原数据。修改 / 单项恢复都检查当前目录和动态系统菜单冲突；占用新键需要先修改原命令。Reset All 原子恢复完整默认组。

## UI 与路由

Settings 分 General、Shortcuts、Terminal、Updates。Shortcuts 支持命令 / 分类搜索、单行录制、Clear、Reset 和 Reset All，错误在本页显示。录制时在菜单分发前截获按键，Quit 等只会成为候选快捷键，不会执行；Escape 取消录制。退出设置、失去焦点、切换录制命令时结束录制。

菜单继续走 AppKit 校验和 responder chain；未改为强制目标，避免文件操作截获文本编辑。`ShortcutDispatcher` 处理原来的窗口监视器别名及文件视图快捷键，两种视图都读取同一映射。文本字段、Info / Settings 字段编辑器、SwiftTerm 中，Control-only / 函数键留给当前输入；终端开关是例外，确保从 shell 内仍能收起。Command 组合继续按原生菜单分发；文件视图替代键仅在实际文件焦点生效。箭头选择、路径补全、对话框 Return / Escape、shell/readline 的编辑控制及鼠标手势仍由原生控件拥有，不属于应用命令映射。

菜单实时更新，Group By 的工具栏菜单也用同一设置。Get Info 三项只有满足 AppKit 的同键 / 修饰键包含关系时才继续用 alternate；自定义为不兼容组合时显示独立行，以免绑定后失去可见入口。Plus 等字符保持原样保存，不写死为美式键位。`ShortcutKeyboardLayout` 从 `NSEvent.characters(byApplyingModifiers:)` 读取当前输入源的 Shift 字符映射，只在冲突 / 事件比较时解析等价组合，并随输入源切换更新。美式 Plus 与 Shift-Equals 等价，德式独立 Plus 不会被改成 Equals；法式需要 Shift 的数字也可触发标签序号。依据为本机 AppKit `NSEvent.h` 对按当前 input source 重译的说明，以及 [Apple 菜单快捷键文档](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MenuList/Articles/SettingMenuKeyEquiv.html)。注入布局回归覆盖美式 / 德式 / 法式，不改变用户输入法。

## 新增验证内容

`ShortcutSmokeTests` 包含逐命令 Clear / 重新绑定 / Reset、唯一 ID / 默认无冲突、重新构造持久化、旧 Filter 迁移、坏映射保留、冲突错误、搜索与录制布局，以及真实 NSMenu.performKeyEquivalent、双标签 / 双 pane、列表 / 图标自定义事件、旧绑定停止、Info alternate、普通文本与 SwiftTerm 输入保护。原 Settings / Updates smoke 跟随新布局和有效键范围更新。

主任务已完成真实 Settings 布局与录制检查：Cmd-T 冲突被拒绝，Control-Command-T 改绑后能收起终端；F6 可以录制，并在文件区与终端内打开 / 收起。过滤 `Show` 后选中 Show Terminal 的真实截图已透明化，选中行、录制值与按钮一致。包含 Plus、删除键和菜单替代项回归的最终 95 份 Swift 源码，3,194 项组合 smoke 连续三轮通过（`smoke-7` / `8` / `9`），均 exit 0、stderr 为空、源码未变；交付 app / DMG 检查通过，精确结果见[定制功能整合记录](customization-integration.md)。

## 录制函数键与初始选区

真实设置页检查发现 F6 录制被当作空输入拒绝：某些函数键的布局重译结果是空字符串，旧的 `??` 仅处理 nil；传入字符本身也可能为空。现对 HIToolbox `Events.h` 明确标记的 layout-independent 虚拟键使用符号常量（F1–F20、方向、翻页等）；其余键仍采用当前布局，空重译回退 reported 字符。回归直接发送 `keyCode=97`、空 characters 与 Function 标志给录制器，不再只调用录制器的字符串接口。

Shortcuts 页打开时将已选命令滚入视口，保持搜索状态；此前逻辑选中 Filter 但列表仍停在 About 顶部。新增实际 row 可见区检查，随最终三轮通过。上述实机发现由 root 提供，修复后的真实 Show Terminal 选中与 F6 录制画面已核对。

## Backspace 与 Forward Delete 的菜单字符

AppKit 的事件字符与菜单字符不能直接混用：物理 Backspace 通常报告 U+007F，而菜单用 U+0008；Forward Delete 报告 U+F728，而菜单用 U+007F。2026-09-13 无窗口 AppKit 探针确认，`NSMenu.performKeyEquivalent` 和 `NSApplication.sendEvent` 按字符匹配，并不会靠 hardware key code、Function 或 Numeric Pad 修饰符自动转换。主菜单现使用 `ShortcutMenu`，仅为菜单匹配复制并规范化删除事件；未处理时 responder 仍接收原事件。Fn-Delete 即使报告 Backspace 的硬件码，也以 U+F728 的前向删除语义为准。

同一探针引用生产 helper 和菜单 subclass，验证原始 Forward Delete、Fn-Delete、Backspace 不误触 Forward Delete、经 NSApplication 分发及禁用项不执行均通过；AppKit 对禁用但匹配的项仍返回 handled=true，因此回归检查命令没有执行，而非假设返回 false。组合 smoke 增加以上行为及 Control-Forward Delete 文本输入保护，本阶段最终结果见[定制功能整合记录](customization-integration.md)。

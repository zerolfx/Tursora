# 终端设置与 Rascal 源码对照

2026-09-13。Tursora 定制阶段基线 `b58c1ce`，提交 `eeaea1c`；后续用户要求隐藏保留会话，本页当前行为已同步该范围，新增验证以[会话生命周期](terminal-session-lifecycle.md)为准。本记录区分源码事实、实现后的行为与实测结果。

## 本轮终端设置

Settings 增加独立 Terminal 页，设置保存在应用 UserDefaults 的 `terminalPreferences.v1`。所有窗口共用设置，终端进程仍由各自窗口持有。

- Shell：默认读取系统账户的 login shell，获取失败仍按原规则后备 `/bin/zsh`。可选择 Custom Shell 并输入完整可执行文件路径；点击 Apply Shell 或在路径框按 Return 保存。拒绝相对路径、控制字符、目录、不可执行文件和不存在的文件；不提供命令参数输入。路径中合法的空格、引号、分号和 `$` 当作文件名，不拼接进 shell 代码。
- 保存 custom shell 时验证，真正启动时再次验证。若文件后来消失，显示内联失败和 Settings → Terminal 提示，保留用户选择以便修正；不会悄悄换到另一种 shell。shell 变更只作用于下次新建会话 / Start / Restart，重新显示已有会话不结束或替换当前进程。
- 字体：System Monospaced 或本机已安装的等宽字体，8–36 pt；文本框按 Return、Tab / 移开焦点或步进器提交。字体被卸载后使用系统等宽字体，保留其他偏好。修改字号不会抹掉尚未 Apply 的 shell 路径或颜色草稿。
- 颜色：Follow Appearance、Dark、Light、Custom。自定义文字与背景使用六位 sRGB `#RRGGBB`，同时提交且不接受部分无效输入。跟随外观按终端所在窗口的实际外观解析；固定主题不受系统亮暗切换影响。程序自己的 ANSI 颜色仍由程序指定。
- 字体、默认前景 / 背景和光标颜色立即更新已打开的终端，不重建 PTY，也不发送任何命令。只修改 shell 时不重新赋字体，避免 SwiftTerm 的字体 setter 清除选区。Restore Terminal Defaults 重置这一页的设置。

本轮保留上一阶段的状态语义：Started in 是启动目录，Shell folder 只有当前实例发来有效本地 OSC 7 时才显示；浏览导航只改变下次 Start / Restart 的目标，不自动发送 `cd`。自然退出保留输出；设置变更不把 ended 状态变回 running。

## Tursora 当前实现

`TerminalPanelController` 嵌入 SwiftTerm 1.15.0 的 `LocalProcessTerminalView`。固定依赖提交为 `dd2fb8ac5b861e7bf617c872895e338f38165648`：

- [AppKit 终端视图](https://github.com/migueldeicaza/SwiftTerm/blob/dd2fb8ac5b861e7bf617c872895e338f38165648/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift)连接终端模拟器与本地进程，处理输入、控制序列、窗口列数 / 行数以及输出。
- [LocalProcess](https://github.com/migueldeicaza/SwiftTerm/blob/dd2fb8ac5b861e7bf617c872895e338f38165648/Sources/SwiftTerm/LocalProcess.swift)走 `forkpty` 后端（Subprocess 分支被条件编译关闭），使用 DispatchIO 和退出监听。每个曾启动终端的窗口持有一个交互式登录 shell，隐藏面板时继续保留。
- [MacTerminalView](https://github.com/migueldeicaza/SwiftTerm/blob/dd2fb8ac5b861e7bf617c872895e338f38165648/Sources/SwiftTerm/Mac/MacTerminalView.swift)提供 CoreGraphics / CoreText 默认渲染。Metal 是明确选择的实验路径；Tursora 未启用它。
- 启动固定 `/bin/sh` 包装脚本，先验证切换目录成功，再以独立 argv 中的路径 `exec` 用户 shell 并传 `-il`。环境设置 `TERM=xterm-256color`、`COLORTERM=truecolor` 与 `TERM_PROGRAM=Tursora`。
- 首次展开才创建进程；收起或禁用入口保留窗口拥有的 PTY 与输出，再显示继续同一会话。Restart、关闭窗口或退出才结束；前台 / 后台 / 已停止任务和未知活动状态先确认，默认 Cancel。自然退出后输出保留，Start 新建会话。终端会话不属于工作区持久化范围；生命周期实现与检测边界见[追加记录](terminal-session-lifecycle.md)。

## Rascal 的实际做法

读取官方公开仓库的精确提交 [108c1c56609573da00fd2e947e63bcfc21a6b7de](https://github.com/chang-07/rascal/tree/108c1c56609573da00fd2e947e63bcfc21a6b7de)，临时 checkout 只用于读源码，未构建或运行。

| 方面 | Tursora | 该提交的 Rascal |
|---|---|---|
| 输出视图 | SwiftTerm 终端模拟器 | `NSTextView` 追加文本，另有 `NSTextField` 输入框 |
| 子进程与输入 | 持续交互 shell、真正 PTY、键盘直接进入终端 | 每次 Return 创建一个 Foundation `Process`，shell 参数 `-l -c <本次命令>`；stdout / stderr 分别用 Pipe，没有 PTY |
| 命令之间的状态 | shell 自然保留变量、函数及交互状态 | 每条命令的新 shell 不保留上条 shell 的状态；历史列表由视图自己记录 |
| `cd` | shell 自己解析 | Swift 特判以 `cd ` 开头的字符串，修改视图的 `cwd`，不是 shell 的完整语法解析 |
| 文件浏览与 cwd | 浏览只更新重新启动目标；有效 OSC 7 仅更新状态显示 | pane 导航时更新可见 drawer 的 `cwd`，后续新命令从此目录启动；drawer 的 `cd` 只改自己的 `cwd` |
| 收起 / 关闭 | 收起保留原 PTY / shell；关窗、退出与 Restart 对活动或未知任务先确认，接受后回收 | 收起后 `terminateRunning()` 对当前 `Process` 调用 `terminate()`；view deinit 同样处理 |
| 设置与渲染 | 本轮新增独立字体和配色设置，默认渲染为 CoreGraphics | shell 可选，自定义无效值回退 `/bin/zsh`；文字写入时固定系统等宽 12 pt，背景 / 输入颜色跟随整个应用主题 |

源码锚点：[输入与输出控件](https://github.com/chang-07/rascal/blob/108c1c56609573da00fd2e947e63bcfc21a6b7de/Sources/FinderTwo/UI/TerminalDrawerView.swift#L8)、[`cd` 和每命令 Process / Pipe](https://github.com/chang-07/rascal/blob/108c1c56609573da00fd2e947e63bcfc21a6b7de/Sources/FinderTwo/UI/TerminalDrawerView.swift#L127)、[主题与退出](https://github.com/chang-07/rascal/blob/108c1c56609573da00fd2e947e63bcfc21a6b7de/Sources/FinderTwo/UI/TerminalDrawerView.swift#L211)、[收起 drawer](https://github.com/chang-07/rascal/blob/108c1c56609573da00fd2e947e63bcfc21a6b7de/Sources/FinderTwo/UI/PaneController.swift#L128)、[浏览导航更新 cwd](https://github.com/chang-07/rascal/blob/108c1c56609573da00fd2e947e63bcfc21a6b7de/Sources/FinderTwo/UI/PaneController.swift#L1033)、[shell 偏好读取](https://github.com/chang-07/rascal/blob/108c1c56609573da00fd2e947e63bcfc21a6b7de/Sources/FinderTwo/Model/Settings.swift#L269)。

由这些源码推断：Rascal 此实现适合 `git status`、`ls`、构建等一次性命令；Tursora 的基础设施更适合需要终端控制序列、持续 shell 状态和交互输入的程序。这个结论来自架构，不等于已经对所有 TUI、吞吐量、Unicode 或终端兼容性做了横评。本轮没有运行 Rascal，也不把官网的“inline terminal”当成真实 PTY 证据。

## 定制阶段验证（`eeaea1c`，不覆盖追加生命周期）

新增 `TerminalPreferencesSmokeTests`：隔离的 UserDefaults round-trip / 无效配置 / shell 路径 / 颜色 / 字体；两份 Settings 页真实 action dispatch 和 540 pt 页面几何；真实字号 field editor 输入后 Tab 提交，以及未提交 shell / 配色草稿保留；临时可执行脚本路径含引号、分号与 `$`，通过生产 launch configuration 启动真实 PTY；保留尚未提交输入时热更新字体 / 颜色；下一次 shell 选择、可执行文件消失与回收。测试脚本只执行 `/bin/sh -f -i`，临时 HOME、禁用 ENV，不读取用户 shell rc。

主任务已完成隔离打包应用实测：工具栏打开 / 收起与选中状态、F6 在文件区和终端内切换；多个命令间保留变量；字体与背景立即更新且输出保留；自定义 `/bin/bash` 在新会话生效，无效路径显示内联错误。字号输入 16 后按 Tab，stepper、预览及保存值同步，再恢复截图用 14。实际最小 560 × 380 窗口修复后终端按钮仍可见并能切换，返回 1100 × 740 正常；QA 副本浅色重开后 Terminal Settings 的路径、字体和颜色控件可读，恢复工作区未自动创建 shell。

真实 Terminal / Terminal Settings 截图及其透明外沿已核对，内部保护像素不变；具体隔离、操作与阶段见[整合记录](customization-integration.md)和[截图审计](screenshot-audit-2026-09-13.md)。最终 95 份 Swift 源码 3,194 项 smoke 连续三轮通过（`smoke-7` / `8` / `9`），均 exit 0、stderr 为空、源码未变；交付 app / DMG 构建及签名、包内容和安装布局检查通过，精确清单见 [HANDOFF](../HANDOFF.md)。生产终端偏好未改，未发布本轮新版本。

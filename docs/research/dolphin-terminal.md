# Dolphin 终端面板与 Tursora 实验功能

> 下文保留 2026-09-12 初版与验证记录；2026-09-13 起两项功能默认启用，开关保留，新增取消 / 重试及终端状态打磨见[后续记录](default-features-polish.md)。

2026-09-12。对照本地 `upstream/dolphin/src`；终端实现采用官方 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm/tree/v1.15.0)，SPM 固定 `1.15.0`（`dd2fb8ac5b861e7bf617c872895e338f38165648`）。

## 源码证据

- `dolphinmainwindow.cpp` 的 `setupActions()`：`show_terminal_panel` 使用 F4，停靠在底部；单独打开外部终端使用 ⇧F4。
- `panels/terminal/terminalpanel.cpp` 的 `urlChanged()`：只有面板可见、开启同步且没有前台程序时，才跟随浏览目录。
- `sendCdToTerminal()`：先发送 Ctrl-E / Ctrl-U 清掉已有命令行，再用 `KShell::quoteArg` 转义路径后发送 `cd`。源码明确指出拼接到用户未执行的命令后面会造成数据丢失。
- `hasProgramRunning()` 通过 Konsole 的前台进程信息判断是否有程序运行；这是 Konsole 提供的语义接口，不能直接等同于 macOS 上 `tcgetpgrp()` 与 shell PID 的简单比较。
- [SwiftTerm `MacLocalTerminalView.swift`](https://github.com/migueldeicaza/SwiftTerm/blob/v1.15.0/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift) 提供真实 PTY 与 AppKit 终端视图，转发按键、控制序列与窗口尺寸。
- [SwiftTerm `LocalProcess.swift`](https://github.com/migueldeicaza/SwiftTerm/blob/v1.15.0/Sources/SwiftTerm/LocalProcess.swift) 使用 `forkpty`、DispatchIO 和进程退出监听；`terminate()` 会取消退出监听，所以显式关闭时 Tursora 自己回收该子进程。

## 第一版范围与取舍

设置里的实验性终端默认关闭。仅当用户启用并展开面板后创建交互式 PTY；启动应用、创建窗口或隐藏面板时都不预先创建 shell。

新终端从当前文件夹启动，使用账户配置的 shell，后备 `/bin/zsh`，保留正常交互式登录 shell 的环境。目录作为独立 argv 传入固定脚本，目录不存在或已卸载时直接退出，不会误入别的工作目录。

支持正常 `pwd`、`cd`、交互输出、Ctrl-C 与终端滚动。浏览器切换目录只更新“Restart in Current Folder”的目标，不自动向 PTY 注入 `cd`：shell 内建 `read` 或用户尚未提交的输入，即使进程组仍是 shell，也不能安全接收自动命令。按钮会结束现有会话并在当前目录重新启动；检测到前台命令时先显示应用内确认。

关闭面板、窗口、禁用功能或退出应用会结束拥有的 shell 和前台进程组，关闭 PTY 并回收 shell。主动脱离终端的后台守护进程不属于该面板的会话管理范围。暂不支持 Konsole 式双向目录同步、会话保存和 SSH 终端；挂载的远程目录作为本地路径使用。

SPM 的 `SwiftTerm_SwiftTerm.bundle` 和 MIT 许可证随应用一起打包。默认使用 SwiftTerm 的 CoreGraphics 渲染；未启用 Metal 渲染实验选项。

## 验证范围

`TerminalSmokeTests` 不启动用户登录 shell、不创建终端 UI。它验证路径作为独立参数传递、headless 模式不启动面板进程，并使用临时 HOME、禁用 ENV 配置的 `/bin/sh -f -i` 实际检查 PTY、`pwd` / `cd`、Ctrl-C 与子进程回收。

2026-09-12 打包应用的 computer-use 实测：

- F4 打开终端后，zsh 正常渲染，`pwd` 显示正确目录；运行 `sleep 30` 可用 Ctrl-C 中断。
- 保留尚未提交的 `printf terminal-input-kept`，通过浏览器导航到含空格的 `Sample Files` 目录后，输入内容没有变化，也没有自动注入 `cd`。
- 点击 Restart in Current Folder 后，`pwd` 显示新目录；运行 `sleep 30` 时再点击 Restart 会显示确认，Cancel 有效。
- F4 隐藏后重新打开，获得新会话。

上述实测不涵盖真实远程连接或关闭所属浏览窗口后的会话回收；这些仍需单独验证，不能由 F4 的结果代替。

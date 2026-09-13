# 终端会话保留与终止确认

2026-09-13。基于定制阶段提交 `eeaea1c`，用户补充要求收起终端不结束 shell，退出有任务时先确认，并已授权完成后推送、合入和发布 0.2.0。本文记录该追加范围；实现 / 验证由主任务及终端 agent 完成，最终检查进度见文末。

## 确定的行为

- 终端仍按窗口拥有，与该窗口所有标签和左右 pane 共用。首次展开才启动 PTY；工具栏、F4 / 用户自定义绑定和标题栏关闭按钮只隐藏视图，保留原 shell、输出、变量、当前目录及任务。重新显示不能重建进程或注入输入。
- General 关闭终端入口会隐藏所有已有面板并保留会话，说明可重新启用后继续。即使入口关闭，退出仍检查这些隐藏终端；改变字体 / 颜色仍应用到它们。更改 shell 等到明确的新建会话或 Restart。
- 文件浏览导航只改变后续 Start / Restart 目标，不向运行中 shell 注入 `cd`。在 ZIP 中使用原 ZIP 的父目录；重新显示保留 shell 自己的当前位置。
- Restart、关闭所属窗口和退出应用才结束会话。检测到所拥有终端的前台、后台或已停止任务时先询问；无法确定活动状态时同样保守询问，默认按钮为 Cancel。
- 取消 Restart / 关窗 / 退出后，保留 shell、输出与窗口。应用退出必须在设置 `isTerminating`、最终保存工作区和取消文件传输之前完成确认；取消不会让后续导航停存或误触发清理。接受后才依次保存逻辑状态、取消任务并等待所拥有 PTY 的回收。
- 每个窗口关闭只结束自己的终端，应用退出汇总全部窗口。隐藏保留只在应用运行期间有效；不序列化 PTY、任务或终端布局，不在重启应用后重放命令。

## 进程检测与边界

`Model/TerminalActivity.swift` 使用 macOS libproc 的 BSD 进程元数据与 `getsid`，查询同一会话及其后代。`TerminalActivitySnapshot` 分开记录任务和 `informationUnavailable`，后者同样要求确认。它不向 shell 发送 `jobs`、探测字符或控制序列，也不读取用户命令内容；隐藏面板不执行进程终止操作。

- 已知 / 配置的空闲 shell 和僵尸不作为活动任务；已停止进程算任务。通过 `exec` 替换 shell 的非 shell 命令，即使继续使用原 shell PID，也纳入确认。
- 身份由 PID 和进程出生时间组成，每次发送信号、调用 SwiftTerm terminate 或 `waitpid` 前重新核对，避免已结束进程的 PID 被复用后误伤 / 回收无关子进程。范围限定为当前拥有的会话与后代；其他窗口和无关终端不属于该范围。
- 接受结束后，逐个向已捕获身份的拥有任务发 HUP / CONT，不整组盲发；关闭 PTY 后，150 ms 宽限期后只对仍存活且身份一致的拥有进程发 KILL。SwiftTerm terminate 自身会向 shell PID 发 SIGTERM，故仅在身份核实、直接子进程尚未被回收时同步调用；随后只回收匹配的直接 shell。重复 shutdown 共用完成屏障，`TerminalProcessLifecycle.whenAllStopped` 还等待已关闭窗口留下的在途终端清理，应用退出不能只遍历当前窗口。主线程不阻塞等待。
- `read` 等只在 shell 内部执行的内建命令无法仅凭进程元数据区别于空闲 shell。真正脱离、改变会话并离开原祖先链的守护进程不属于拥有范围。检测依据进程身份 / 名称而非完整 shell 作业控制，不能承诺识别所有 shell 内部执行状态。
- 完整枚举或相关元数据无法获得时保守询问；不把“无法读取”记为“没有任务”。
- 本机受控子进程观察发现未回收僵尸的 `proc_pidinfo(PROC_PIDTBSDINFO)` / `getsid` 可报 ESRCH，而 `sysctl(KERN_PROC_PID)` 仍提供原出生时间、父 PID 与 SZOMB；实现以此作元数据回退，仍要求精确身份才回收。Restart 带 shutdown generation，清理期间被关窗 / 退出中断时不能重新生出 shell。

实现已经过独立复查；准确的自动化 / GUI 范围见文末。

## 右下角状态入口

用户确认状态位于浏览窗口右下角。`TerminalStatusPresentation` 将显示状态与活动快照合成只读呈现；`MainWindowController` 仅把它放在当前标签最右 pane 的 `StatusBarView`，与活动侧无关，不给每个 pane 都放一个。点击与工具栏 / F4 共用窗口级开关。

- 从未启动显示 Terminal；运行会话按可见性显示 Running / Hidden。任务优先显示数量，tooltip 解释检测到的进程数及 stopped 数；不是解析 shell 后的作业数。
- 自然结束显示 Ended，启动失败显示 Error，无法检查活动显示 Check。宽度不足时只显示终端图标，完整状态仍在 tooltip 和辅助功能说明中。
- 设置禁用入口时，有保留会话仍显示状态和重新启用提示，按钮禁用；既没有会话又禁用入口时隐藏该项。
- 仅已有终端轮询，约每两秒在 utility 队列读取进程快照；一个窗口同一时刻只发一个请求，返回主线程验证 session / request 身份。自然结束且无未清理活动后停表。初始状态、导航、切换标签不启动 shell。
- 状态显示允许采样延迟；退出 / 关窗 / Restart 重新取即时快照再确认。读取 UI 不执行 shell 命令。

上述纯呈现、所有权、窄栏和异步路径已加入回归；最终逐轮结果见文末。

## 验证记录

最终 debug / release 构建通过；本地 `0.2.0` DMG 构建通过，脚本已只读挂载检查应用签名、元数据、arm64、Applications symlink 和保存的安装布局。83 项 Python 发布工具测试通过。日志位于 `/private/tmp/tursora-terminal-session-qa/`：`package-0.2.0-final.out`、`dmg-0.2.0.out`、`tool-tests-final.out`。本地包不是已发布资产，发布后还需重新下载核验。

最终 **101 份 Swift 源码：3,329 项连续三轮通过**。`smoke-7` / `8` / `9` 分别用时 194.4 / 188.4 / 187.6 秒，均 exit 0、stderr 为空、源码未变。三份逐轮源码清单与当前文件及 `delivery-sources.json` 完全一致；旧 3,194 / 3,321 项与本轮诊断失败不计作这份源码的通过。新增检查覆盖进程归属、前台 / 后台 / 停止 / exec / EOF、PID 出生时间与僵尸回收、重复与全局清理屏障、取消退出后的工作区保存、异步 footer、窄栏及真实原生菜单焦点。

诊断分别修正了僵尸 libproc 回退、原生菜单 key window 前提、macOS `/bin/sh` 实际名为 bash 的测试假设，以及受控交互 shell 的历史展开；不放宽进程身份检查。`smoke-6` 的文件树组合断言失败没有分项日志，不能精确归因到某个条件；复查发现测试把偏好文件写进监听目录，使全局请求计数可能受到真实文件事件刷新影响。现将该测试存储移到受控兄弟路径，等布局 / 选中目标就绪，并拆开正向 AX、精确请求历史和未展开子节点断言，增加请求路径 / generation 诊断；保留不枚举兄弟目录的严格要求，增加八项检查。后续只改了回归 fixture 和默认打包版本，下面的 GUI 功能代码一致。

最终打包日志为 `package-delivery.out` / `dmg-delivery.out`；`tools/make-app.sh` 不带版本环境覆盖时实际生成 `0.2.0`。最终 83 项工具测试日志为 `tool-tests-delivery.out`。

### 独立发布包实机检查

使用 `/private/tmp/tursora-terminal-session-qa/Tursora Session QA.app`，只改副本 bundle id、自己的 workspace / view-properties 文件、进程外观与 `ZDOTDIR`，ad-hoc 重签。用户原应用与偏好未改，GUI 与完整 smoke 串行，共享验证锁仍由主任务持有。

- 新启动右下角 Terminal 的辅助功能明确“尚未启动 shell”；点击后创建真实 shell。
- 受控 `sleep 600` 的 shell PID 为 55113、后台 PID 为 55145。状态显示 `Terminal · 1 task`。点击 footer 隐藏后按 ⌘Q，出现列出 sleep 的退出提示；按 Return 命中默认 Cancel，隐藏任务仍在。
- 从 footer 重新展开后，在 General 关闭 Terminal panel，入口禁用、任务状态仍显示 hidden；重新启用并按 F4，保留原 shell、输出和两个 PID。新的实际输出记录了保留的 PID，截图 `terminal.jpg`。
- Restart 的任务提示与实际窗口关闭按钮的提示均用默认 Cancel 取消。⌘W 在多标签时只关闭当前标签，窗口级终端继续存在；切换到保留标签后当前右 pane 仍显示同一状态。
- 实际拖动到 560 × 740，再到 560 × 380；终端状态变为可点击图标，完整 AX / tooltip 保留进程数，文件状态与界面仍响应。用图标隐藏，再按 ⌘Q 并接受 Quit and Stop Tasks，应用退出；`ps` 精确核对 55113 / 55145 均不存在。
- 仅把已退出的 QA 副本改成浅色后重开，恢复测试窗口的布局，初始状态没有 shell。展开后界面可读，输入 exit 后 footer 变为 Ended 并保留输出。正常退出并用精确路径 pgrep 确认 QA 已退出，再开始下一轮 smoke。
- General 新说明和终端 footer 截图已真实重拍，原始 JPEG 在 `screenshots/settings.jpg` / `terminal.jpg`；`quit-hidden.jpg` 仅为本地证据。两张 canonical PNG 的透明处理、内部像素保护与明暗检查见[截图审计](screenshot-audit-2026-09-13.md)，不声称全部旧图本轮重拍。

网站新安装区已通过静态构建和桌面 / 390 px 浏览器检查，精确点击、弹窗与清理范围见[网站说明](../../site/README.md)。上述不包含正式 Release / 在线 appcast / Homebrew 新版本验证，发布后单独记录。

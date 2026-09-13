# 终端与浏览目录双向同步，以及 bash / fish 支持

2026-09-13。在 [0.2.1 单向跟随](terminal-navigation-0.2.1.md) 的基础上补两件事：一是反向同步，shell 自己换目录时让窗口当前 pane 跟过去；二是把原本只有 zsh 的自动同步扩展到 bash 和 fish，并让三种 shell 都通过 OSC 7 汇报自己的目录。

0.2.1 的硬性边界全部保留：**不向 shell 输入任何字符，不发信号，不修改用户的启动文件**；面板不读写文件系统，导航仍走 `MainWindowController → BrowserViewController.navigate`；朝 shell 的目录变更只在安全的提示符发生。

## 证据与来源

- Finder 资源里没有“目录跟随”一类的开关文案。`plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings` 共 2,129 条，只有 `N67 = "Open in Terminal"` 与终端相关；`strings` 扫 `Base.lproj/*.nib` 没有匹配。**两个复选框的文案“Terminal follows the browser folder”“Browser follows the shell folder”是本项目自拟的中性措辞，不是 Finder 用词**，记为推断项。
- Dolphin 依据沿用 [0.2.1 记录](terminal-navigation-0.2.1.md)：`terminalpanel.cpp` 的 `urlChanged()` 要求面板可见。本轮工作树里没有 `upstream/dolphin` 检出，**没有重新核对 Dolphin 反向同步的实现细节**；“只在面板可见时同步”这一条沿用已记录的可见性前提，Dolphin 反向方向的具体代码未在本轮验证，记为未核对。
- OSC 7 的接收侧来自 SwiftTerm 1.15.0：`EscapeSequenceParser.swift:530` 把 OSC 7 交给 `Terminal.oscSetCurrentDirectory`，后者在 `isProcessTrusted` 为真时把原始字符串交给 `hostCurrentDirectoryUpdated`，`AppleTerminalView` 再转成 `hostCurrentDirectoryUpdate(source:directory:)`。macOS 的 `MacTerminalView.isProcessTrusted` 恒为 `true`，`LocalProcess` 默认在主队列投递，因此回调在主线程。
- fish 4.0.2 自己也会在 PWD 变化时发 OSC 7：受控会话里同一次 `cd` 收到两条完全相同的报告（见下方“去重”）。本轮同时观察到 fish 发送 OSC 133，SwiftTerm 记为 `Unknown OSC code: 133`，不影响功能。

## 设计

### 反向同步（shell → 浏览器）

`TerminalPanelController.hostCurrentDirectoryUpdate` 收到本机 OSC 7 后，除了更新标题提示，还通过新的 `onShellDirectoryChanged` 把目录交给窗口；`MainWindowController.followShellDirectory` 调用 `browser.navigate(to:)`，也就是当前标签的当前 pane。分栏、多标签、两种文件视图都自然适用，因为走的是同一条导航路径。面板本身不做任何文件系统访问。

四道防回环与噪声的闸门：

1. **面板不可见就不驱动浏览器。** 与 Dolphin 的可见性前提一致；隐藏的面板仍然保留 shell、通道和目录显示，只是不再改变文件视图。
2. **等于本面板刚请求过的目录就忽略。** `requestedDirectory` 记录浏览器 → shell 的最后一次请求。
3. **等于浏览器当前目录就忽略。** `pendingDirectory` 始终跟着浏览目录走，这条是最强的一道。
4. **目录没变就不是新闻。** `reportedShellDirectory` 单独记录 OSC 7 上一次报的目录。bash 每个提示符都汇报，fish 因为自带 hook 会汇报两次；只有真正换了目录才通知窗口。它必须与 `presentation.reportedDirectory` 分开，因为后者也被 zsh 的响应文件写入。

比较目录用 `TerminalPanelPresentation.isSameDirectory`，即比较 `standardizedFileURL.path`，这样 `/tmp` 与 `/private/tmp` 两种写法算同一处。

### 目录路径的规范化陷阱

`URL.standardizedFileURL`（等价于 `NSString.standardizingPath`）在 macOS 上会**去掉开头的 `/private`**。OSC 7 里 shell 报的是真实的 `$PWD`，原来的 `localDirectory` 用 `standardizedFileURL`，会把 `/private/tmp/x` 改写成 `/tmp/x`，于是“shell 说的目录”和请求的目录对不上。现在只用 `URL.standardized`（纯词法消解 `.` 与 `..`），保留 shell 自己的写法；跨写法的相等判断交给 `isSameDirectory`。这一条已加入自动检查。

### 两个开关

`TerminalPreferences.Configuration` 新增 `terminalFollowsBrowser`、`browserFollowsShell`，默认都为真，`browserFollowsShell` 为真即保持 0.2.1 的既有行为不变。`Configuration` 改为逐字段 `decodeIfPresent` 解码：0.2.1 存下来的 JSON 没有这两个键，用合成解码会整体解码失败并把用户的 shell、字体、配色一起重置。Settings → Terminal 两个复选框，关掉正向同步时仍然更新 Restart 目标，标题提示会说明原因。

### 三种 shell 的集成

`TerminalShellIntegration` 按可执行文件名识别 zsh / bash / fish；`/bin/sh`（在 macOS 上其实是 bash）等仍然只得到普通交互终端。启动仍是 argv 形式：`TerminalLaunchConfiguration` 新增 `shellArguments`，包装脚本改成 `cd -- "$1" || exit 1; tursora_shell="$2"; shift 2; exec "$tursora_shell" "$@"`，目录、shell 路径和集成文件路径都是独立 argv，不进入可执行文本。

| shell | 加载方式 | 请求何时生效 | 汇报方式 |
| --- | --- | --- | --- |
| zsh | 临时 `ZDOTDIR`（先恢复原值再读用户 `.zshenv`） | FIFO 唤醒 ZLE，空提示符立即生效 | 响应文件 + precmd 里的 OSC 7 |
| bash | 临时 `--rcfile` | 用户画出的下一个提示符 | `PROMPT_COMMAND` 里的 OSC 7 |
| fish | `--init-command` | 用户画出的下一个提示符 | `--on-variable PWD` 的 OSC 7 |

- **zsh**：`_ts_<token>_prompt` 在 `_ts_<token>_apply` 之后调用新的 `_ts_<token>_osc7`。编码在 `emulate -L zsh -o no_multibyte` 下逐字节进行，`printf -v hex '%%%02X' "'$char"` 取字节值，因此非 ASCII 路径按 UTF-8 字节百分号编码。ZLE 唤醒路径不发 OSC 7，避免在 widget 里写终端。
- **bash**：bash 对登录 shell 不读 `--rcfile`，所以会话改成交互非登录 shell，由生成的 rcfile 自己按登录顺序读 `/etc/profile` 和 `~/.bash_profile` → `~/.bash_login` → `~/.profile` → `~/.bashrc` 的第一个可读者。**另一个坑：bash 只在第一个短选项之前解析长选项**，`-i --rcfile x` 会让 bash 报 `--: invalid option` 并打印用法，因此参数顺序必须是 `--rcfile <file> -i`。编码函数用 `local LC_ALL=C` 让 `${#s}` 和 `${s:i:1}` 按字节切分。`PROMPT_COMMAND` 追加而不是覆盖，钩子先存 `$?` 再 `return`，提示符里的退出码不受影响。
- **fish**：`--init-command` 在 `config.fish` 之后求值，用户配置仍然说了算。百分号编码用 `string escape --style=url` 再把 `%2F` 换回 `/`，无论 fish 是否转义分隔符结果都正确。请求在 `--on-event fish_prompt` 的钩子里消费，NUL 分隔字段用 `read --null --local` 读。

三种脚本都只把生成的通道目录和十六进制 token 写进可执行文本，路径按数据读取；都没有 `trap`、`kill` 或 `eval`。请求只在成功应用后才被记为已消费，因此用户随后手动 `cd` 不会在下一个提示符被拉回去。

## 边界与已知限制

- **bash 和 fish 的正向同步在用户画出下一个提示符时才生效**，空闲时不会动。只有 zsh 有 FIFO/ZLE 的即时路径。这句话写进了面板标题提示和设置里正向复选框的 tooltip。
- bash 和 fish 没有确认通道：失败的 `cd`（例如目录不存在）不会像 zsh 那样报告 `failed`，请求会在后续每个提示符重试，界面一直显示等待。
- bash 会话不再是登录 shell，`shopt login_shell` 为 off、`$0` 不是 `-bash`；依赖这两点的用户配置会看到差别。用户之后自己覆盖 `PROMPT_COMMAND` 也会去掉钩子。
- fish 的 `fish_prompt` 事件钩子里 `_ts_<token>_osc7` 的输出在本机没有被观察到送达终端（apply 的 `cd` 确实执行了），所以“浏览器请求落在 shell 已经在的目录上”这种情况不靠它。面板改为在这种情况下直接把状态记为已同步，同时 `TerminalDirectorySync` 对 bash / fish 不再发布 `waiting`（没有应答通道，晚到的 `waiting` 会覆盖刚到的 OSC 7 结果）。**fish 事件钩子输出为何没到达没有进一步定位**，记为未查明。
- bash 的 rcfile 路径和 fish 的整段 init-command（含通道目录与 token）都在 argv 里，同机用户用 `ps` 可见。通道目录本身仍是 0700、文件 0600；token 只用于校验 zsh 的响应格式，fish 不用响应文件。
- fish 只在 `/opt/homebrew/bin/fish` 存在时验证；缺失时对应检查打印一行 `ok … skipped`。其他安装路径（MacPorts、`/usr/local`）未验证。
- bash 的字节编码用 `local LC_ALL=C`，本轮只用 ASCII 加空格的路径验证过；zsh 的字节编码路径有现成的 `雪` 与换行目录覆盖。
- 反向同步只改当前标签的当前 pane，不改另一半分栏，也不改其他窗口。面板隐藏期间 shell 换过的目录，在重新显示后不会补报，要等 shell 下一次换目录。
- 依旧不做一个窗口多个终端会话，这次明确不在范围内。

## 验证

`cd app && swift build` 干净，无新增警告。整轮 smoke 在实现完成后一次通过：`exit=0 ok=3509 fail=0`，用时 176 秒（基线 e202c2e 为 3,432 项）。新增 77 项检查，覆盖：

- 纯函数：三种 shell 的识别与 `/bin/sh` 不识别、argv 拼装与 bash 长选项顺序、三段脚本的内容约束（读用户启动文件、保留 `PROMPT_COMMAND`、按 NUL 读请求、不含 `eval` / `kill` / `trap`）、`/private` 写法保留与 `..` 消解。
- 偏好：两个方向默认开、旧版 JSON 迁移后保留 shell 与外观、两个设置页互相同步、存储往返、Restore Defaults、540 点页面内的布局。
- 面板（无进程）：只有 shell 知道的目录才交给浏览器、远端主机报告被忽略、自己的请求回来不成环、同一目录换写法不算移动、每个提示符重复汇报不重复导航、隐藏时不驱动、重新显示后恢复、关掉反向不报告、关掉正向仍然改 Restart 目标并解释原因。
- 窗口：详细视图与图标视图下当前 pane 跟随、分栏时只有活动 pane 跟随、切换活动 pane 后跟随对象随之切换、新标签成为当前后跟随、隐藏终端后窗口不再跟随。
- 真实 PTY：zsh 里手输 `cd` 经 OSC 7 让面板收到目录、浏览器请求在空闲提示符生效且不反弹、隐藏面板只更新目录不导航、关掉反向开关后不导航、浏览器跟上后再出提示符不再产生新报告；bash 收到请求后空闲不动、下一个提示符才应用、临时 rcfile 读到了用户的 `.bash_profile`、手输 `cd` 经 OSC 7 汇报、已消费的请求不会撤销用户的 `cd`；fish 同样一组检查，缺失时跳过。

诊断过程中修正的问题都在上面的“边界与已知限制”和“设计”里：bash 长选项顺序、fish 事件钩子输出、`/private` 规范化、重复汇报去重。`/private` 那条同时修好了既有 `TerminalDirectorySyncSmokeTests` 在加入 OSC 7 之后出现的失配，该套件的失败详情也补上了实际目录与期望目录。

**本轮只有自动化验证。** 没有打包 release、没有实机 GUI / computer-use 观察、没有截图更新，也没有在真实用户 shell 配置下试用；这些都不能当作已完成。

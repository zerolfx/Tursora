# 软件更新：实现、发布链与验证（2026-09-13）

## 当前状态

更新代码、设置和 DMG 发布工具已实现，尚未发布含 updater 的新版本。最终同源码 **2,158 项 smoke 连续三轮通过**，stderr 均为空；工具测试 **70 项通过**（发布说明 33、更新元数据 / 布局 37）。General / Updates 实机设置、重启持久化、本地 Sparkle DMG 下载 / 校验 / 安装 / 重启及最终 DMG 的 Finder 视觉检查均已完成。用户已授权提 PR 并合入；Pages 工作流合入 `main` 后部署，当前结果以 [Actions](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml) 为准，生产稳定 release 与 feed 另行发布。

Ed25519 公钥已写入 `app/Resources/SparklePublicKey.txt`，私钥保存在本机 Keychain 的 `com.tursora.Tursora` account。首次上传被自动审批拦截后，用户明确授权；`zerolfx/Tursora` 的 Actions secret `SPARKLE_PRIVATE_KEY` 已于 2026-09-13 00:48:20（Asia/Shanghai）成功配置，GitHub `updatedAt=2026-09-12T16:48:20Z`，secret 列表已核实名称与时间。上传前从现有 Keychain 导出到 mode-0600 临时文件，经 CryptoKit 派生公钥与 Resources 一致后通过 stdin 上传，trap 清理临时文件；私钥未进入源码或日志。新稳定 release 尚未发布，`0.1.0` 标签与资产保持原样。

原版 `0.1.0` 没有更新器，仍保留已发布 ZIP；用户必须手动安装一次含本功能的后续版本。后续 release 直接提供 DMG：打开后把 Tursora 拖入 Applications。首份正式 `appcast.xml` 随下一次稳定 release 发布；本机测试用一次性 QA key 与 loopback feed，不能据此宣称生产签名 key、线上 feed 或真实 release 已完成端到端验证。网站配置与本地检查另见 [GitHub Pages](github-pages.md)。

## 交互与偏好

Settings 分为 General 和 Updates 两页，初始选择 General。Updates 提供每日自动检查、自动下载安装、手动检查和最近检查时间。Tursora 菜单也提供 Check for Updates…，没有新增快捷键。

自动检查默认开启，可关闭；自动下载安装默认关闭。两个偏好交给 Sparkle 保存，应用启动不覆盖已有选择。自动检查关闭时，自动下载安装控件禁用；Sparkle 的有效 getter 可显示关闭，但已保存的选择仍保留，重新开启检查后恢复。手动检查继续可用，后台 updater 忙碌时由 `canCheckForUpdates` 禁用重复入口。

自动下载打开后，校验成功的更新可在退出时安装；需要授权或进一步操作时由 Sparkle 提示。关闭选项不销毁已有更新会话，也不取消已下载或已安排退出安装的更新。这是当前对 Sparkle 生命周期的使用方式，不额外承诺立即终止下载或删除其暂存。

## 代码与打包边界

- SPM 固定 Sparkle **2.9.6**；`AppUpdater` 包装一个 `SPUStandardUpdaterController`，在主线程启动、读取和变更设置；KVO 转为应用通知刷新界面。
- `AppUpdateDriver` 为测试注入边界。smoke 与裸 SPM 可执行文件的 shared factory 不构造 Sparkle，不启动网络检查、权限提示或安装服务。配置失败内联显示并禁用操作，成功重试可恢复。
- 初始值放在 Info.plist：`SUEnableAutomaticChecks=true`、`SUAutomaticallyUpdate=false`、`SUSendProfileInfo=false`、`SUVerifyUpdateBeforeExtraction=true`；不设 `SUAllowsAutomaticUpdates`，让检查状态决定自动下载资格。检查间隔使用 Sparkle 默认 86,400 秒。
- 打包将完整 Sparkle framework 通过 `ditto` 放入 `Contents/Frameworks`，保留 helper / XPC 签名、符号链接与执行权限。可执行文件使用包内 framework rpath，清理 SPM 开发目录路径；只给外层应用 ad-hoc 签名，不用 `--deep` 重签嵌套 helper。
- 更新属于应用生命周期，不经文件浏览器的用户文件撤销通道；既有退出逻辑仍先取消并等待文件传输清理。没有改动用户文件操作、pane 或标签的数据模型。

## 发布与信任链

稳定 feed 固定为 `https://github.com/zerolfx/Tursora/releases/latest/download/appcast.xml`。每次稳定 release 附带单项 appcast，包含嵌入版本说明、固定版本 DMG 地址、文件大小、macOS 14 与 arm64 要求，以及 DMG 的 Ed25519 签名。没有 delta 或 prerelease channel。feed XML 本身未签名，未开启 `SURequireSignedFeed`；HTTPS 提供元数据传输，应用内公钥验证待安装镜像。SHA-256 文件用于下载核对，不替代签名。

`make-appcast.sh` 将私钥通过 stdin 交给官方生成工具，验证元数据后再用 Sparkle 工具核对归档签名。私钥不写工作树、不作为命令行参数、不输出日志。公钥与对应私钥应持续复用，不在每次发布重新生成。

Build 与 Release 的 bundle build 默认都取源码提交的 Unix committer timestamp，避免各工作流 run number 不连续。稳定发布先要求 semver 大于现有 latest；已有 appcast 时，还要求新 build 大于其中每项。prerelease 不产生稳定 appcast、不成为 latest。只有原始 0.1.0 允许没有 appcast；后续 latest 若缺失该文件，发布校验会拒绝，避免跳过 build 顺序约束。

## DMG 安装布局与 Apple 签名边界

`make-dmg.sh [release-version]` 从已验证的应用生成 `app/dist/Tursora-<version>-macOS-arm64.dmg`；本机可通过 `TURSORA_PYTHON=/opt/homebrew/bin/python3.13` 选择 Python。最低 Python 3.10，CI 使用 3.13；独立 `.build/dmg-tools` venv 中固定 dmgbuild 1.6.7、ds-store 1.3.3 与 mac-alias 2.2.3，全部 wheel SHA-256 入版本库并强制检查。

镜像为压缩只读 HFS+，预写 640 × 280 窗口、128 px 图标；Tursora 位于 `(140, 120)`，Applications 位于 `(500, 120)`，中间使用箭头背景。`Applications` symlink 指向 `/Applications`。背景 MIT 许可保存在卷根隐藏文件，不加入已签名应用内部。构建脚本直接写入 `.DS_Store`，不依赖 Finder UI；只读挂载后核对包签名、平台、更新元数据、symlink、许可与布局再卸载。

本机有效 code-signing identity 数为 0，用户确认尚无 Developer ID。暂不添加无法验证的 Apple 签名脚本；会员资格、Developer ID Application 证书 / 私钥、公证凭据具备后，再接入 hardened runtime、notarization 与 stapling 并验证。Mac App Store 还涉及 App Sandbox 与分发设计，属于后续独立工作。Sparkle 签名与 DMG 容器均不能代替 Apple 公证。

维护步骤见 [RELEASING.md](../RELEASING.md)。更新签名没有替代 Developer ID 签名或公证，当前应用仍为 ad-hoc 签名、未公证。

## 依据

- [Sparkle 2.9.6 的 SPUUpdater API](https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html)：主线程调用、偏好持久化、KVO、动作可用性与 `allowsAutomaticUpdates` 的依赖。实现直接使用固定依赖的相同 API。
- [Sparkle 自定义设置](https://sparkle-project.org/documentation/customization/)：Info.plist 决定初始行为，每日周期、自动下载安装及授权边界。Tursora 的 General / Updates 页面布局与默认选择属于本应用决策，不宣称复刻 Finder。
- [Sparkle 官方集成文档](https://sparkle-project.org/documentation/)与[安全改进](https://sparkle-project.org/documentation/security-and-reliability/)：公钥、更新归档签名、打包组件与提取前验证。最终产物必须另行验证，读取文档不是安全测试。

## 验证记录

- 最终同源码 smoke：77 份 Swift 源码哈希记录于 `/tmp/tursora-updates-verification/final-source-hashes.json`，**2,158 项连续三轮通过**、三轮 stderr 均为空，日志为同目录 `final-smoke-{1,2,3}.{out,err}`。此前两轮诊断不计入最终三轮。
- Python 工具 **70 项通过**，覆盖公钥、稳定版 / build 顺序、appcast 大小与实体声明、bundle 默认值、平台 / 下载地址 / 长度 / 签名字段和 DMG 布局。
- 本地 `0.1.1` release 应用构建（124.11 秒）、`codesign --verify --deep --strict`、`verify-bundle` 与包内独立 framework rpath 检查通过，日志 `/private/tmp/tursora-updates-package.log`。最初的 5,286,744-byte ZIP 属于改用 DMG 前的试包阶段，不再作为最终分发格式。
- 最终 `0.1.1` DMG 的只读挂载、包签名、元数据、布局与隐藏背景许可检查通过；SHA-256 为 `f04b72da322101dcfa4556023007d08a821218b71f8452f432bf021463411e1d`。未修改签名脚本正测、错误 key 及同长度篡改负测均完成，后两者 exit 1 且未覆盖有效 feed。日志 `/private/tmp/tursora-dmg-signing-qa-u40p72o8/logs/result.json`，使用一次性 QA key，不读取 Keychain 生产 key。
- 实机 General / Updates 布局、开关、退出后重启的偏好持久化、关闭自动检查后的手动“已是最新”路径已检查。当前 `settings.png` / 新增 `updates.png` 来自本阶段真实窗口。
- 最终 DMG 视觉检查：Finder 正常打开镜像后，640 × 280 内容窗口内两侧完整显示 Tursora 与 Applications，箭头位于中间，没有工具栏杂项。截图见下；原始 `/private/tmp/tursora-updates-verification/dmg-installation.jpg` 转为真实 PNG，保留原始边缘与系统指示，不做抠角。
- 实机本地完整更新：临时应用从 `0.1.1` 经 Sparkle 正常签名 DMG 下载、验证、安装并重启到 `0.1.2`，通过 bundle、About 窗口和进程核对。使用 `/tmp` fixture、一次性 QA key 与 loopback URL，未更新用户应用或发布生产 feed。将篡改 DMG 交给 GUI 安装的动作被自动审批拒绝，已放弃该动作并改用离线签名负测验证拒绝，未把 GUI 负测记为通过。
- 截图格式修正：捕获返回的 JPEG bytes 最初使用 `.png` 文件名，现通过 `sips` 转为真实 540 × 737 PNG；两张转换前后 macOS ImageIO 解码 RGBA 逐字节一致。透明处理脚本拒绝两图左上彩色边缘（residual 49.9 / 51.5），因此保留完整原截图，没有伪造角落或修改开关。原始 JPEG、PNG 和像素校验脚本保存在 `/private/tmp/tursora-updates-screenshots-final/`。
- 最终文档校验：204 个本地 Markdown 链接目标存在；截图目录 24 张均为真正 PNG，README 特性表 15 张截图及下载区 1 张安装截图引用有效。安装图的 JPEG → PNG 也通过原生 ImageIO 逐像素一致性核对，尺寸 640 × 280；`git diff --check` 通过。
- 收尾：77 份 Swift 源码再次核对与最终三轮测试快照一致；测试应用已退出、本地 updater fixture server 已停止、挂载已卸载，只恢复本轮更新偏好，未覆盖用户其他设置，实机验证锁已释放。
- GitHub 签名 secret 已于上述时间配置；首个更新版稳定 release/appcast 与线上生产下载 / 安装 / 重启尚未完成。Pages 合入后运行，远端结果独立记录。

![最终 DMG 的真实 Finder 安装窗口](../images/features/installation.png)

## 首次启动说明（2026-09-13）

按用户要求参考 [Rascal 下载说明](https://github.com/chang-07/rascal#download)，采用下载 → 打开 DMG 拖入 Applications → 从 Applications 启动的顺序。Tursora 当前正式版仍为 `0.1.0` ZIP，README / 网站保留这一过渡事实，没有提供尚不存在的 Homebrew tap。Rascal 自有 [cask](https://github.com/chang-07/homebrew-tap/blob/main/Casks/rascal.rb) 将 ad-hoc / 未公证及隔离属性处理写在 `caveats`，没有在安装 hook 自动执行该命令；它的分发方式不作为 Tursora 已签名或已公证的证据。

[Apple《Safely open apps on your Mac》](https://support.apple.com/en-us/102445)（页面日期 2026-05-27，本次读取 2026-09-13）给出的单应用处理顺序为：先尝试启动，再进入 System Settings → Privacy & Security 选择 Open Anyway，确认提示中选择 Open。条件是使用者确信来源可信且未被篡改。README 以此为主路径，网站只提供简短说明与 README `#first-launch` 链接，不扩展静态构建器的外链白名单。无法验证开发者和无法检查恶意软件的提示不能作为恶意软件实际检出、撤销授权或文件损坏的统一解释；损坏先重下及同版本 checksum 核对，恶意软件警告不按普通隔离属性问题处理。

本机 macOS `man xattr` 明确 `-d` 删除指定名称的扩展属性、`-r` 递归处理目录内容、`-c` 清空全部扩展属性。因此 README 折叠终端备选使用 `xattr -dr com.apple.quarantine /Applications/Tursora.app`，没有照搬 Rascal 的 `-cr`。执行前提为官方 release 来源与同一版本 `SHA256SUMS.txt` 匹配；其作用仅是移除该应用下载隔离属性，不赋予 Developer ID / 公证，也不修复损坏。本轮只读取 man page 和编写说明，没有执行隔离属性命令、改变系统安全设置或实测首次 Gatekeeper 拦截；既有 77 份 Swift 源码、2,158 × 3 smoke 与正常更新实测的范围不因此扩大。

说明修改后的静态构建、文档链接和 `git diff --check` 通过；真实浏览器检查下载区的桌面及 390 px 视口，步骤和首次启动链接完整可读、无横向溢出。精确范围见 [Pages 记录](github-pages.md)。

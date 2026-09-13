# 0.2.0 正式发布核验

2026-09-13。[Tursora 0.2.0](https://github.com/zerolfx/Tursora/releases/tag/v0.2.0) 已发布为最新稳定版，非 draft / prerelease。用户已授权完成这些功能后推送、合入与发布，原 0.1.0 标签及资产未修改。

## 源码与流水线

[PR #8](https://github.com/zerolfx/Tursora/pull/8) 已合入，main、`v0.2.0` 及 Release checkout 精确对应 `3ca4ab9ffd43555e4c4118e5504eb6d39e6dc034`。Git 作者与提交者均为 `zerol <20219056+zerolfx@users.noreply.github.com>`；普通 fast-forward 推送，没有重写历史。

- 最终 101 份 Swift 源码的 3,329 项 smoke 连续三轮通过，逐轮 / 当前哈希一致，stderr 均为空；83 项工具测试、最终 release / DMG 构建及实机功能验证通过。具体范围见[终端生命周期](terminal-session-lifecycle.md)；发布后的 cask / 文档修订不改变这些 Swift 源码。
- main 的 [Build](https://github.com/zerolfx/Tursora/actions/runs/34739716326)、[Homebrew](https://github.com/zerolfx/Tursora/actions/runs/34739716318)、[Pages 部署](https://github.com/zerolfx/Tursora/actions/runs/34739716315) 均通过后才启动 Release。该阶段 Homebrew 验证的仍是当时 cask 固定的 0.1.0。
- [Release](https://github.com/zerolfx/Tursora/actions/runs/34739914582) 成功；`v0.2.0` 是直接指向上述提交的 tag，发布时刻 `2026-09-13T05:21:13Z`。短版本 `0.2.0`，build `1789275959` 为提交的 Unix committer timestamp。

## 公开资产与签名

实际使用 `gh release download` 下载三份正式资产到 `/private/tmp/tursora-release-0.2.0-verified`，不是使用本地试包。结果与 SHA256SUMS、GitHub asset size / digest 相符，校验文件本身也与 API digest 相符。

| 资产 | 字节 | SHA-256 |
|---|---:|---|
| `Tursora-0.2.0-macOS-arm64.dmg` | 5,794,277 | `2593f312772b6d7ee6a885c8017ce43b31d094fc2744f764e76e027178d1aef7` |
| `appcast.xml` | 5,787 | `2c96395442c61bb985d361189472dbef34f56bfdf683db328218222d41f037d4` |
| `SHA256SUMS.txt` | 174 | `03185719aaa44ed9d310ae834303f9bb8499a28aa7bb9a4bddb42af4da708c88` |

只读挂载后确认：应用版本 / build / bundle id、arm64、`codesign --verify --deep --strict`、包内 MIT / SwiftTerm / Sparkle 许可证和图标，Applications symlink、安装背景许可证及保存的两图标 / 箭头 / 640 × 280 布局均通过。根 MIT 文本与源码逐字节相同。镜像已卸载。

`verify-bundle` 和 `verify-appcast` 核验元数据；另用 CryptoKit 的 Ed25519 公钥验证对下载的完整 DMG 检查签名，避免把“元数据字段正确”混作密码学验证。本地验证只读取项目公钥，没有导出或读取私钥。实际 `releases/latest/download/appcast.xml` 与版本化下载的 appcast 字节一致。

这仍是 ad-hoc 签名、未 Apple 公证的直接分发应用。Sparkle 更新签名和 SHA-256 不代表 Developer ID / Gatekeeper 公证；首次安装按 README 指引操作。

## 正式包启动与线上更新检查

从已核验镜像复制应用，先验证原包，再仅修改测试副本的名称、bundle id、自动检查默认值和测试专用环境，并 ad-hoc 重签。使用 `com.tursora.releaseqa020.s0913` 与自己的 workspace / view-properties 文件，避免改用户原应用和偏好；保留原生产 feed URL / 公钥 / 版本 / build。

实机启动成功，About 显示 `0.2.0 (1789275959)`，右下角初始 Terminal 明确没有启动 shell。Settings → Updates → Check for Updates 实际访问生产源，提示 **You’re up to date!**，确认 0.2.0 是当前最新版本。证据为 `live-update-check.jpg`，随后正常退出，精确进程路径查询确认测试副本已退出。

本次没有把同一用户下的旧正式 bundle id 应用交给生产 installer 替换 / 自动重启：本机仍有用户应用运行，Sparkle 替换后按标准路径重启不会继承旧副本的临时隔离配置。受控 Foundation 探测还确认 `CFFIXED_USER_HOME` 仅改变 home 路径 API，不能隔离 UserDefaults，新的进程仍访问真实偏好目录；专用 QA 域与文件已清理，正式偏好未动。实际旧版本下载 / 安装 / 自动重启仍沿用此前**一次性 QA key + loopback** 的独立成功记录，不将其宣称为本次生产源端到端安装验证。原版 0.1.0 没有 updater，仍需手动升级一次。

## 安装入口与后续核验

README 安装段已前置，网站导航和首屏“安装指南”跳 `#installation`。新布局在桌面 / 390 px、安装图弹窗及 Escape 焦点恢复中通过；main 第一次部署的 8 个文件均 HTTP 200 且与本地构建逐字节相同。全部 29 张 canonical 图片透明圆角检查通过，General / Terminal 已更新，见[截图审计](screenshot-audit-2026-09-13.md)。

公开 0.2.0 资产通过核验后才生成 cask，启用 `auto_updates true`，隔离 Homebrew 实际安装 / 卸载及最终文案和 Pages 部署另见 [Homebrew 记录](homebrew.md)与 [Pages 记录](github-pages.md)。这些步骤与 Release 分开核实，后续提交不会移动已发布标签。

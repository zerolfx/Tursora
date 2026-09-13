# 0.2.1 正式发布核验

2026-09-13。[Tursora 0.2.1](https://github.com/zerolfx/Tursora/releases/tag/v0.2.1) 已发布为最新稳定版，非 draft / prerelease。用户已授权完成终端和文档改动后推送、发布；旧版本标签及资产未修改。

## 源码与发布

`v0.2.1` 精确指向 `c95f4d5aaaf483dd8176873685ac614b47c8100a`，build `1789288838` 是该提交的 Unix committer timestamp；作者与提交者均为项目要求的 zerol 身份，普通 fast-forward 推送没有重写历史。

- 最终 102 份 Swift 源码连续通过三轮完整 smoke，每轮 3,435 项，前后哈希一致、stderr 为空。83 项发布工具测试、release 包和本地 DMG 验证通过；保留隐藏任务、目录同步、退出取消、窄界面等实机范围见[终端验证](terminal-navigation-0.2.1.md)。
- 对应提交的 [Build](https://github.com/zerolfx/Tursora/actions/runs/34748295219) 和 [Pages](https://github.com/zerolfx/Tursora/actions/runs/34748295179) 均成功后，才启动 [Release 34748456904](https://github.com/zerolfx/Tursora/actions/runs/34748456904)。Release 的构建、更新签名、校验和与发布步骤全部通过，发布时间 `2026-09-13T08:50:03Z`。
- GitHub API 的最新 release 为 `v0.2.1`，标签 ref 与上述提交相同；证据位于 `/private/tmp/tursora-0.2.1-qa-u1_phjba/release/{release,latest,tag}.json`。

## 实际公开资产

使用 `gh release download` 下载正式文件，逐一与 GitHub asset digest / size 及 SHA256SUMS 核对，没有用本地试包替代公开产物。

| 资产 | 字节 | SHA-256 |
|---|---:|---|
| `Tursora-0.2.1-macOS-arm64.dmg` | 5,852,598 | `3458aa15670b75e8469398e4d0928ed73e6f038567c9ae7dba049e509333460b` |
| `appcast.xml` | 2,575 | `9d8b654d711731c44072f976d23694e49a13981ad559720f7769a4abc6b4cce1` |
| `SHA256SUMS.txt` | 174 | `cc356b563d51f201cbe3d05d5ef0bb4299367346987304d302401a0f0133bdcc` |

只读挂载检查版本 / build / bundle id、arm64、`codesign --verify --deep --strict`、MIT / SwiftTerm / Sparkle 许可证、图标和运行资源；许可证逐字节匹配发布提交。Applications symlink、安装背景许可证和两图标 / 箭头布局通过。`verify-bundle` / `verify-appcast` 校验元数据；另用 cryptography 的 Ed25519 验证器和包内公钥验证完整 DMG 签名，公钥也匹配发布源码，全程未读取私钥。保留 pristine app 副本并再次验证签名后卸载镜像。

报告 `/private/tmp/tursora-0.2.1-qa-u1_phjba/release/verification.json` 为 passed；实际原包位于该目录的 `verified-0.2.1-3tklxqe7/Tursora.app`。正常 TLS 访问 `releases/latest/download/appcast.xml` 返回 HTTP 200，与版本化下载逐字节一致，仅含 0.2.1 / build 1789288838 一项；`live-feed.json` 保存该核对及再次确认的 latest / tag。此应用仍是 ad-hoc 签名、未 Apple 公证；更新签名不代替 Gatekeeper 公证。

## 正式包启动与更新源

从 pristine app 再复制隔离测试包，仅调整副本的名称、bundle id 与测试文件环境并重签，使用 `com.tursora.releaseqa021.s0913`、独立工作区 / 目录属性文件和 ZDOTDIR，不修改用户原应用、偏好或 dotfiles。正式包正常启动；Settings → Updates → Check for Updates 访问生产 feed 后显示 **You’re up to date! Tursora Release QA 0.2.1 is currently the newest version available.** 证据为 QA 目录 `screenshots/live-update-check.jpg`，测试应用随后正常退出，精确进程查询确认已退出。

该检查证明正式版本可启动并查询生产源，不宣称本次完成了从旧版生产安装器替换与自动重启，也不等同于另一台标准用户或受管理 Mac 的首次安装测试。安装说明支持可写目录与针对已核验应用副本的 quarantine 属性处理；没有提供 0.1.0 迁移流程。

## 安装入口、网站与截图

README、默认英文首页、中文页和共享 agent 安装指南更新至 0.2.1；保留 tap / 单 cask trust / install 三步及实际安装路径说明。cask 在正式资产通过上述校验后，才由 `update-homebrew.py --auto-updates` 从真实 DMG 生成，固定本表 SHA-256。本地生成一致性、Ruby 语法、83 项工具测试和双语站点构建通过。最终跟进提交的线上安装结果以 [Homebrew 工作流](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml) 为准；本地生成检查不等同于实际 brew 安装。

源码发布阶段的两种语言已完成 1200 / 390 px 浏览器检查，10 个部署文件及默认根 URL 的 11 次正常 TLS 下载均与 `c95f4d5` 和本地构建一致。后续安装版本文案与 cask 使用独立跟进提交，不移动 release 标签。截图已记录鼠标移出、悬浮痕迹检查与透明圆角处理，详见[截图审计](screenshot-audit-2026-09-13.md)；历史研究图片的证据范围保持其实际拍摄阶段。

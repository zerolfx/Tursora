# Homebrew 分发（2026-09-13）

## 结论与一手依据

可以先支持自己的 Homebrew tap，无需购买 Apple Developer Program。用户提到的每年 99 美元对应 Apple 会员；Developer ID 签名与公证改善首次启动体验，和能否写一个自己的 cask 是不同环节。[Apple 会员说明](https://developer.apple.com/programs/)、[Developer ID](https://developer.apple.com/developer-id/)。

Homebrew 当前对官方 `homebrew/cask` 的要求是：macOS 可执行产物必须通过其 Gatekeeper 检查，不能依靠关闭或绕过 Gatekeeper。因此当前 ad-hoc、未公证的 Tursora 不声称已符合官方库收录条件，也不提交官方库。上述限制来自[官方库接纳规则](https://docs.brew.sh/Acceptable-Casks#platform-compatibility-and-macos-security-protections)。

Homebrew 支持在普通 Git 仓库中放置 `Casks/`，双参数 `brew tap <name> <URL>` 不要求仓库以 `homebrew-` 命名。因此复用 Tursora 公开仓库，不新增外部仓库。[Tap 维护](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)、[双参数 tap 与完整名称](https://docs.brew.sh/Taps)。

## 本轮实现

- [Casks/tursora.rb](../../Casks/tursora.rb) 固定真实公开版本 `0.1.0`，架构 Apple Silicon、最低 macOS 14。下载原发布 ZIP，SHA-256 为 `7619e8ee33ade5283bbddf0eef306892bc806811801bdd36abdb4d8682b06124`。未凭空引用尚未发布的 DMG。
- 安装使用标准 `app "Tursora.app"`，不执行额外 shell、删除隔离属性或修改系统安全设置。保留 Homebrew 默认下载隔离，首次启动仍按 README 中可信来源的步骤处理。没有 `zap`，卸载不删偏好、会话或用户文件。
- `0.1.0` 没有 Sparkle，因此 cask 不标 `auto_updates`。新版真实发布 DMG 和 appcast 后，维护工具可显式标记更新能力；用 `brew upgrade --cask --greedy zerolfx/tursora/tursora` 可让 Homebrew 检查具有自带更新能力的版本。
- [update-homebrew.py](../../app/tools/update-homebrew.py) 从保存的 GitHub release JSON、同版本校验文件与已下载资产生成 cask。拒绝草稿、预发布、非稳定标签、非官方或可变地址、重名资产、冲突校验、字节/大小/digest 不符；不处理凭据、不联网、不自动提交或发布。`--auto-updates` 还要求同版公开 `appcast.xml`，并拒绝历史 `0.1.0`。
- [Homebrew 工作流](../../.github/workflows/homebrew.yml) 在专用 macOS runner 验证 cask 安装与卸载，不启动应用，不改系统安全策略。工作流文件已准备，远端执行结果不能由本地测试代替。

合入并推送 `main` 后，用户可运行：

```sh
brew tap zerolfx/tursora https://github.com/zerolfx/Tursora
brew install --cask zerolfx/tursora/tursora
```

## 新稳定版本的维护

先按 [RELEASING.md](../RELEASING.md) 发布并核验真实 release，再更新 cask。下面以**已经发布的** `0.1.0` 演示可立即执行的维护过程；后续把 tag 与文件名替换为新发布版本（新格式为 `.dmg`）。临时目录必须新建，避免混入不同版本文件。

```sh
release_dir="$(mktemp -d -t tursora-homebrew-release)"
gh api repos/zerolfx/Tursora/releases/tags/v0.1.0 > "$release_dir/release.json"
gh release download v0.1.0 --repo zerolfx/Tursora \
  --pattern SHA256SUMS.txt --pattern Tursora-0.1.0-macOS-arm64.zip \
  --dir "$release_dir"
python3 app/tools/update-homebrew.py \
  --release-json "$release_dir/release.json" \
  --checksums "$release_dir/SHA256SUMS.txt" \
  --archive "$release_dir/Tursora-0.1.0-macOS-arm64.zip" \
  --output Casks/tursora.rb
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s app/tools -p 'test_homebrew.py'
ruby -c Casks/tursora.rb
```

含 Sparkle 的新版在上述生成命令末尾加 `--auto-updates`。审阅 cask diff，确认 version、SHA、immutable URL、最低系统和架构与真实包一致后，按项目规则提交并合入。不能提前把 cask 指向未发布资产；不能把 `sha256` 换成 `:no_check`。如果以后获得 Developer ID 并完成公证，先验证包的 Gatekeeper 结果，再移除 cask 的未公证提示并评估官方库接纳条件。

## 已完成的本地验证

验证目录 `/private/tmp/tursora-distribution-qa`；未修改用户 Homebrew 的 prefix、taps、trust、日志或已安装 Tursora，也未触碰 `/Applications`。

1. 实时 GitHub API 确认 `v0.1.0` 是公开稳定最新版，ZIP 为 4,101,534 字节；下载 ZIP / SHA256SUMS，实际 SHA 与 API digest、校验文件三者一致。生成工具输出与提交的 cask 逐字节相同。
2. Homebrew 6.0.22 在独立临时 prefix 读取 cask，正确解析版本、架构与 macOS 14。采用当前 `depends_on macos: :sonoma` 语法，无旧字符串比较弃用警告。
3. 真正执行 `brew install --cask --appdir=<owned temporary directory> zerolfx/tursora/tursora` 成功。包版本 `0.1.0`、arm64、strict codesign 通过；`com.apple.quarantine` 存在。没有使用 `--no-quarantine`，没有移除隔离，也没有启动应用。
4. `brew uninstall --cask zerolfx/tursora/tursora` 成功，临时 app 路径不再存在。
5. 发布边界测试 6 个方法通过，Ruby 语法通过；这些独立工具检查不代替最终组合应用 smoke。

用户已授权在新增终端生命周期完成后推送、合入并发布 0.2.0。当前仍只准备仓库内分发配置：`main` 的 cask、远端工作流及网站重新部署尚未执行。0.2.0 真实 DMG / appcast 发布核验后，用 [RELEASING 中的命令](../RELEASING.md#020-preparation-2026-09-13)生成后续 cask 并加入 `auto_updates true`，不能提前把当前 cask 指向未发布字节。这些状态由最终 HANDOFF 更新；本次也不算 Gatekeeper 首次启动实测或生产自动更新实测。

## 首次远端 CI 与工具链修正

PR #8 的首个 Homebrew job 已从自有 tap 安装真实 0.1.0 并通过严格 codesign，随后 Xcode 26.6 的 lipo 将 `-verify_arch arm64 <file>` 中的文件误当作后续架构参数。按工具提示把输入文件放到命令前：`lipo <file> -verify_arch arm64`；本机最终 0.2.0 包验证通过，远端重跑结果待补。失败不代表安装或签名失败，也没有执行到后续版本 / quarantine 核验。[原始 job](https://github.com/zerolfx/Tursora/actions/runs/34739359685/job/103676301695)。此修正只影响 CI 参数顺序，101 份 Swift 源码与已通过的三轮 3,329 项检查完全一致。

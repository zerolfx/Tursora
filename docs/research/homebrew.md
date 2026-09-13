# Homebrew 分发（2026-09-13）

## 结论与一手依据

可以先支持自己的 Homebrew tap，无需购买 Apple Developer Program。用户提到的每年 99 美元对应 Apple 会员；Developer ID 签名与公证改善首次启动体验，和能否写一个自己的 cask 是不同环节。[Apple 会员说明](https://developer.apple.com/programs/)、[Developer ID](https://developer.apple.com/developer-id/)。

Homebrew 当前对官方 `homebrew/cask` 的要求是：macOS 可执行产物必须通过其 Gatekeeper 检查，不能依靠关闭或绕过 Gatekeeper。因此当前 ad-hoc、未公证的 Tursora 不声称已符合官方库收录条件，也不提交官方库。上述限制来自[官方库接纳规则](https://docs.brew.sh/Acceptable-Casks#platform-compatibility-and-macos-security-protections)。

Homebrew 支持在普通 Git 仓库中放置 `Casks/`，双参数 `brew tap <name> <URL>` 不要求仓库以 `homebrew-` 命名。因此复用 Tursora 公开仓库，不新增外部仓库。[Tap 维护](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)、[双参数 tap 与完整名称](https://docs.brew.sh/Taps)。

## 本轮实现

- [Casks/tursora.rb](../../Casks/tursora.rb) 固定真实公开版本 `0.2.0`，架构 Apple Silicon、最低 macOS 14。下载正式 DMG，SHA-256 为 `2593f312772b6d7ee6a885c8017ce43b31d094fc2744f764e76e027178d1aef7`，由同版本 release JSON、校验文件与实际资产生成。
- 安装使用标准 `app "Tursora.app"`，不执行额外 shell、删除隔离属性或修改系统安全设置。保留 Homebrew 默认下载隔离，首次启动仍按 README 中可信来源的步骤处理。没有 `zap`，卸载不删偏好、会话或用户文件。
- 0.2.0 已含 Sparkle 并发布 appcast，因此当前 cask 标记 `auto_updates true`；历史 `0.1.0` 没有 updater，旧 cask 不带此标记。用 `brew upgrade --cask --greedy zerolfx/tursora/tursora` 可让 Homebrew 检查具有自带更新能力的版本。
- [update-homebrew.py](../../app/tools/update-homebrew.py) 从保存的 GitHub release JSON、同版本校验文件与已下载资产生成 cask。拒绝草稿、预发布、非稳定标签、非官方或可变地址、重名资产、冲突校验、字节/大小/digest 不符；不处理凭据、不联网、不自动提交或发布。`--auto-updates` 还要求同版公开 `appcast.xml`，并拒绝历史 `0.1.0`。
- [Homebrew 工作流](../../.github/workflows/homebrew.yml) 在专用 macOS runner 验证 cask 安装与卸载，不启动应用，不改系统安全策略。原始 cask 的 main 工作流已成功；0.2.0 cask 的远端结果以对应提交的 [Homebrew runs](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml) 为准，远端执行结果不能由本地测试代替。

用户通过本仓库 tap 安装；此分支的 0.2.0 cask 随 follow-up 合入 main 后生效：

```sh
brew tap zerolfx/tursora https://github.com/zerolfx/Tursora
brew install --cask zerolfx/tursora/tursora
```

## 新稳定版本的维护

先按 [RELEASING.md](../RELEASING.md) 发布并核验真实 release，再更新 cask。下面以**已经发布的** `0.2.0` 演示维护过程；后续把 tag 与文件名替换为新发布版本。临时目录必须新建，避免混入不同版本文件。

```sh
release_dir="$(mktemp -d -t tursora-homebrew-release)"
gh api repos/zerolfx/Tursora/releases/tags/v0.2.0 > "$release_dir/release.json"
gh release download v0.2.0 --repo zerolfx/Tursora \
  --pattern SHA256SUMS.txt --pattern appcast.xml --pattern Tursora-0.2.0-macOS-arm64.dmg \
  --dir "$release_dir"
python3 app/tools/update-homebrew.py \
  --release-json "$release_dir/release.json" \
  --checksums "$release_dir/SHA256SUMS.txt" \
  --archive "$release_dir/Tursora-0.2.0-macOS-arm64.dmg" \
  --auto-updates --output Casks/tursora.rb
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s app/tools -p 'test_homebrew.py'
ruby -c Casks/tursora.rb
```

`--auto-updates` 仅适用于已经发布 appcast 的含 Sparkle 版本。审阅 cask diff，确认 version、SHA、immutable URL、最低系统和架构与真实包一致后，按项目规则提交并合入。不能提前把 cask 指向未发布资产；不能把 `sha256` 换成 `:no_check`。如果以后获得 Developer ID 并完成公证，先验证包的 Gatekeeper 结果，再移除 cask 的未公证提示并评估官方库接纳条件。

## 初始 0.1.0 cask 的本地验证（历史）

验证目录 `/private/tmp/tursora-distribution-qa`；未修改用户 Homebrew 的 prefix、taps、trust、日志或已安装 Tursora，也未触碰 `/Applications`。

1. 实时 GitHub API 确认 `v0.1.0` 是公开稳定最新版，ZIP 为 4,101,534 字节；下载 ZIP / SHA256SUMS，实际 SHA 与 API digest、校验文件三者一致。生成工具输出与提交的 cask 逐字节相同。
2. Homebrew 6.0.22 在独立临时 prefix 读取 cask，正确解析版本、架构与 macOS 14。采用当前 `depends_on macos: :sonoma` 语法，无旧字符串比较弃用警告。
3. 真正执行 `brew install --cask --appdir=<owned temporary directory> zerolfx/tursora/tursora` 成功。包版本 `0.1.0`、arm64、strict codesign 通过；`com.apple.quarantine` 存在。没有使用 `--no-quarantine`，没有移除隔离，也没有启动应用。
4. `brew uninstall --cask zerolfx/tursora/tursora` 成功，临时 app 路径不再存在。
5. 发布边界测试 6 个方法通过，Ruby 语法通过；这些独立工具检查不代替最终组合应用 smoke。

## 0.2.0 正式 DMG 的隔离安装验证

[正式 0.2.0](https://github.com/zerolfx/Tursora/releases/tag/v0.2.0) 于 [Release 34739914582](https://github.com/zerolfx/Tursora/actions/runs/34739914582) 发布。主任务保存并核验 `/private/tmp/tursora-release-0.2.0-verified/` 的真实 release JSON、SHA256SUMS、DMG 与 appcast；应用包、签名和布局细节由[发布记录](release-0.2.0.md)统一维护。

本轮 `update-homebrew.py --auto-updates` 以这三份实际输入生成 cask，DMG 为 5,794,277 字节、SHA 如上。6 个发布边界测试和 Ruby 语法通过。复用此前**自有隔离** Homebrew 6.0.22 runtime `/private/tmp/tursora-distribution-qa/homebrew`，确认旧 Caskroom 为空，再仅更新其中的测试 tap；cache / logs / config / temp / apps 使用新建目录 `/private/tmp/tursora-homebrew-0.2.0-i_9y61y8/`。没有覆盖 HOME、接触用户 prefix 或 `/Applications`。

实际 `brew install --cask --appdir=<该目录>/apps zerolfx/tursora/tursora` 从正式 URL 下载并安装成功。首次 sandbox 无 DNS 权限只造成下载失败，允许网络的同范围重试成功；没有预装伪造资产或去掉 quarantine。随后核对：

- 包版本 `0.2.0`、build `1789275959` 与 cask / 正式 release 相同，`auto_updates` 为 true。
- `lipo <file> -verify_arch arm64` 与 `codesign --verify --deep --strict` 通过。
- `com.apple.quarantine` 保留；MIT 文件与根 LICENSE 字节一致，Sparkle / SwiftTerm 声明存在。
- 不启动应用；正常 `brew uninstall --cask zerolfx/tursora/tursora` 成功，临时 app 及 Caskroom 记录均不存在。

`cask-info.json`、`installed-verification.json`、`install-network.{out,err}`、`uninstall.{out,err}` 与 `scope.json` 保留在新目录。此检查不等于首次 Gatekeeper 启动，也不等于旧版经生产 feed 下载、安装和重启。本节记录 follow-up 合入前的本地验证；其合入和远端结果以对应 PR、[Homebrew runs](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml) 与 [Pages runs](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml) 为准。主任务在 PR 与最终证据 JSON 记录精确运行，不用旧 0.1.0 job 代替新版结果。

## 首次远端 CI 与工具链修正

PR #8 的首个 Homebrew job 已从自有 tap 安装真实 0.1.0 并通过严格 codesign，随后 Xcode 26.6 的 lipo 将 `-verify_arch arm64 <file>` 中的文件误当作后续架构参数。按工具提示把输入文件放到命令前：`lipo <file> -verify_arch arm64`；本机最终 0.2.0 包验证通过；随后 [PR 重跑](https://github.com/zerolfx/Tursora/actions/runs/34739465732) 和 [main 运行](https://github.com/zerolfx/Tursora/actions/runs/34739716318) 均成功，安装 / 版本 / quarantine / 卸载步骤完成。它们验证当时的 0.1.0 cask，不能当作新 0.2.0 cask 的远端结果。失败不代表安装或签名失败，也没有执行到后续版本 / quarantine 核验。[原始 job](https://github.com/zerolfx/Tursora/actions/runs/34739359685/job/103676301695)。此修正只影响 CI 参数顺序，101 份 Swift 源码与已通过的三轮 3,329 项检查完全一致。

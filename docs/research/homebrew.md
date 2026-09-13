# Homebrew 分发（2026-09-13）

## 当前版本：0.2.1

`Casks/tursora.rb` 已从实际公开的 0.2.1 DMG、release JSON 和 SHA256SUMS 生成，保持 `auto_updates true`。DMG 为 5,852,598 字节，SHA-256 `3458aa15670b75e8469398e4d0928ed73e6f038567c9ae7dba049e509333460b`；真实资产、代码签名、Ed25519 更新签名和安装布局见[发布核验](release-0.2.1.md)。本地 83 项工具测试、cask 精确重生成和 Ruby 语法检查通过；对应 main 推送的实际安装 / 卸载结果由 [Homebrew 工作流](https://github.com/zerolfx/Tursora/actions/workflows/homebrew.yml) 单独记录。下文保留早期版本和安装说明调整的历史证据。

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

0.2.0 cask 已随 [PR #9](https://github.com/zerolfx/Tursora/pull/9) 合入 main，其[真实安装检查](https://github.com/zerolfx/Tursora/actions/runs/34741008373)通过。按用户明确要求，主安装流程依次执行以下三条，每步成功后再继续：完整 URL 添加 tap、显式仅信任 Tursora cask、安装。第二步是此文档流程的必做步骤，见 D58：

```sh
brew tap zerolfx/tursora https://github.com/zerolfx/Tursora
brew trust --cask zerolfx/tursora/tursora
brew install --cask zerolfx/tursora/tursora
```

当前三步流程已由主任务在新的隔离信任目录中顺序验证：tap、`trust --cask`、install dry run 均 exit 0；信任 JSON 只有此 cask，没有 tap / formula / command 授权，用户 Homebrew 未变。证据为 `/private/tmp/tursora-three-step-install-3liuppa5/verification.json`。这是流程与信任范围检查，未重新安装应用；此前真实 DMG 安装 / 卸载及新增显式 trust 的 CI 结果分别记录。

## 当前安装位置与普通账户说明

用户明确安装位置不必统一。新增[英文纯 Markdown 安装指南](../../site/install.md)，站点地址为 `https://zerolfx.github.io/Tursora/install.md`，供用户或获得安装请求的 agent 按实际条件执行。先检查既有安装与用户意图，选用实际可写的 `/Applications`、`~/Applications` 或其他目录；不强制迁移已有应用。上面的三条命令沿用 Homebrew 默认目的地；若选择其他目录，将实际绝对目录赋给 `app_dir`，第三条添加 `--appdir="$app_dir"`。已有 Homebrew 管理的安装走正常版本检查 / 升级，直接 DMG 复制遇到同名应用则先确认冲突，不能默默覆盖。

`--appdir` 只改变应用落点，不改变 tap / Caskroom 等 prefix 的权限。Homebrew 默认只有安装它的拥有者能修改 prefix；普通账户是否可用由实际权限决定。没有可用 Homebrew 时，直接下载正式 DMG 与同版校验文件，核对完整 SHA-256 后复制出只读镜像，不为了安装应用而擅自安装 Homebrew、提权或修改所有权。[Homebrew 参数](https://docs.brew.sh/Manpage#global-cask-options)、[默认权限](https://docs.brew.sh/FAQ#what-are-the-default-ownership-and-permissions-used-by-homebrew)。

首次启动的定向命令为 `xattr -dr com.apple.quarantine "$app_path"`，`app_path` 必须是实际已安装、可信且通过下载校验的应用副本。仅删除该属性，不用 `sudo`，不清全部属性，不关闭系统策略；cask 本身仍保留 quarantine。普通账户与组织管理限制是两个问题，设备策略若仍阻止运行需 IT 处理，不能承诺该命令可绕过管理规则。[Apple 管理限制](https://support.apple.com/en-euro/guide/deployment/dep61dc030/web)。本节记录指南与一手资料核查，不新增非管理员账户安装或首次 Gatekeeper 启动的验证结论；部署结果另由主任务记录。

## 安装排错：仓库地址与单项信任

2026-09-13 用户先报告找不到 `homebrew-tursora`，重试后报告 `untrusted tap`。没有收到完整原始命令 / 输出，不能断言用户具体省略了哪一步；以下是独立复现和已核对的 Homebrew 行为。

单参数 `brew tap zerolfx/tursora`，或尚未 tap 时直接安装 fully-qualified cask，会按约定访问 `https://github.com/zerolfx/homebrew-tursora`。我们复用的真实仓库是 `https://github.com/zerolfx/Tursora`，必须先双参数 tap。即使 remote 正确，本地目录依然叫 `Library/Taps/zerolfx/homebrew-tursora`；仅看到 `Cloning into` 的目录名并不表示失败。[官方 tap 规则](https://docs.brew.sh/Taps)。

`untrusted tap` 是 Homebrew 的第三方安装定义信任检查，与 Apple 公证无关。安装定义是可执行 Ruby；当前主流程明确先授权 Tursora cask，再安装，不扩大到整个 tap，也不关闭全局信任检查。

[官方说明](https://docs.brew.sh/Tap-Trust)规定 fully-qualified install 本身也会信任指定项。此前两条 tap / install 的默认流程及遇错才显式 trust 是**历史排错阶段**；用户随后要求把单 cask trust 放进主安装命令，现由 D58 的三步流程取代。这个文档选择不等于所有 Homebrew 安装都必须靠单独 trust 才能成功；下面的自动信任成功记录仍如实保留。没有替用户修改本机 Homebrew 信任设置。

历史排错验证：在自有隔离 Homebrew 6.0.22 中清除旧测试 tap 后，省略 URL 的 tap 实际失败并显示默认仓库不存在；双参数从公开仓库 clone 成功，remote 精确匹配，cask 解析为 0.2.0 和正式 SHA。随后用两个新的临时信任目录并明确启用信任检查：短名称安装的 dry run 复现 `untrusted tap`；单项 trust 后安装 dry run 成功。另一个空信任目录直接 fully-qualified install dry run 也成功；两份 JSON 均只有一个 cask、没有全 tap / formula / command 信任。本次不安装或启动应用，不修改用户 prefix 或信任文件。证据在 `/private/tmp/tursora-tap-diagnosis-3mrphmee/{result.json,trust-result.json}`；dry run 不替代前面的真实 DMG 安装 / 卸载记录。

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

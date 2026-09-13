# GitHub Pages 配置与验证（2026-09-12）

## 当前双语站点与 0.2.1

默认入口改为英文 `index.html`，中文为 `zh.html`，普通 English / 中文链接双向切换。两页共享截图、样式、脚本及英文 `install.md` agent 指南；安装目标为已发布的 0.2.1。源码提交 `c95f4d5aaaf483dd8176873685ac614b47c8100a` 的 [Pages 34748295179](https://github.com/zerolfx/Tursora/actions/runs/34748295179) 成功，10 个部署文件及根 URL 的 11 次正常 TLS 下载均与该提交和本地构建相同。1200 / 390 px 双语浏览、安装跳转、图片查看器和键盘关闭通过；新截图实际尺寸为 1100 × 740。安装版本文案在正式资产核验后以独立跟进提交更新，其部署须按该提交单独核对；[站点说明](../../site/README.md)与[0.2.1 发布核验](release-0.2.1.md)记录范围。下文为较早的中文站点与安装调整历史，不再作为当前页面描述。

## 0.2.0 发布后的安装说明

[PR #8](https://github.com/zerolfx/Tursora/pull/8) 于 2026-09-13 合入 `3ca4ab9ffd43555e4c4118e5504eb6d39e6dc034`；[main Pages 34739716315](https://github.com/zerolfx/Tursora/actions/runs/34739716315) 成功。该部署发生在正式 Release 前，页面当时保留真实的“准备中”说明。[0.2.0 发布](release-0.2.0.md)后，本 follow-up 去掉未来 DMG / tap 待发布文案，说明已发布 0.2.0 与固定 SHA 的 Homebrew 安装，保留 `#installation`、latest release CTA、MIT、未公证和原 0.1.0 一次手动升级提示。

此 follow-up 本地构建通过：5 资产、39 引用、约 1,629 KiB、全部 29 图 alpha 通过；静态检查两个安装锚点、两个 latest CTA、精确保留的两行 Homebrew 命令，以及 README 的 20 个不同截图引用。五份网站资产与此前浏览器实测版本字节相同。证据 `/private/tmp/tursora-homebrew-0.2.0-i_9y61y8/site-static.json` 与 `site-build.{out,err}`。本轮未驱动浏览器或应用，该 follow-up 合入后的线上结果以 [Pages runs](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml)、对应 PR 与最终 HTTP 核验证据为准，不能用上一个部署成功代替它；历史 1200 / 390 px 安装区与图片查看器实测范围不扩大。

## 实现

公开产品页目标地址为 <https://zerolfx.github.io/Tursora/>。沿用 `site/` 的中文静态页面、真实应用截图与 Python 标准库构建器；部署产物只有 `site/dist/`。全部资源保持相对引用，适配项目站点 `/Tursora/` 子路径。

新增 `.github/workflows/pages.yml`：影响站点或四份源资产的 PR 运行静态构建和引用校验；同类变更进入 `main` 或手动在 `main` 触发时，构建产物交给 GitHub 官方 Pages Actions 发布。其他分支与 PR 不上传 Pages 产物、不部署。构建任务只读仓库与 Pages 配置；部署任务拥有 `pages: write` / `id-token: write`，依赖构建成功，使用 `github-pages` environment，并记录正式页面 URL。并发组保留正在进行的部署。

下载按钮改为 `https://github.com/zerolfx/Tursora/releases/latest`，自动指向最新正式发布页。文案保留 Apple Silicon、macOS 14+、SHA-256、ad-hoc 签名与未公证的实际边界，移除私有仓库登录要求。早期按要求准备直接 DMG 分发及应用 → Applications 拖拽安装，当时页面明确区分已发布的 0.1.0 ZIP 与未来 DMG；这段过渡说明已在页首的 0.2.0 follow-up 移除。ZIP 浏览功能介绍不变。

## 依据与远端只读核验

- GitHub 官方[自定义 Pages 工作流](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)说明 `configure-pages@v5`、`upload-pages-artifact@v4`、`deploy-pages@v4`，以及部署权限、环境与构建依赖。
- GitHub 官方[发布源配置](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)说明以 GitHub Actions 为 source，并建议限制部署 environment 的分支。
- 2026-09-12，GitHub API 的仓库响应为 `visibility=public`、`default_branch=main`、`has_pages=true`；Pages 响应为 `build_type=workflow`、`html_url=https://zerolfx.github.io/Tursora/`、`https_enforced=true`、`cname=null`、`status=null`。现有 Pages 已选 Actions，无需重复创建。
- 同日 `releases/latest` 为正式非草稿的 `v0.1.0`，资产包括 `Tursora-0.1.0-macOS-arm64.zip`（4,101,534 bytes）与 `SHA256SUMS.txt`（96 bytes）。本阶段只读取 release 元数据，未重复下载并验证应用；后续独立的 ZIP 校验与隔离安装证据见 [Homebrew 历史记录](homebrew.md#初始-010-cask-的本地验证历史)。

## 本地验证与边界

- `python3 site/build.py` 通过：4 份源资产、33 处引用、约 1,559 KiB；校验涵盖本地文件、目录逃逸、fragment、重复 ID、图片 alt 与三个 workflow panel。
- Ruby 标准库解析工作流 YAML 成功，并确认静态构建命令与部署的 `needs: build`。本机没有 `actionlint`，未把 YAML 解析宣称为完整 Actions 执行验证。
- 本地临时 HTTP 服务在 `/Tursora/` 下预览。浏览器实测 1280 px 页面与下载区，下载链接确认为 `/releases/latest`；四份资产均成功加载，ZIP fragment 正确选中第三项，截图弹窗成功打开，Escape 关闭后焦点回到截图链接。
- 390 px 视口的 `document.documentElement.scrollWidth` 为 390，未出现整页横向溢出；本轮未重跑历史的全部键盘、禁用 JavaScript 或 reduced-motion 检查。视口覆盖已清除，预览标签与临时服务已关闭。
- `git diff --check` 通过。应用 smoke 由同一改动的整合验证统一记录，本阶段不单独声称应用三轮通过。

DMG 下载说明补充后的最终静态构建仍为 4 份资产、33 处引用、约 1,559 KiB。最终浏览器复查 `/Tursora/#download`：1722 px 桌面下载区文字和两项入口完整可见，CTA 仍指向 `/releases/latest`；390 px 视口的整页宽度为 390，文案明确区分未来 DMG 与现有 `0.1.0` ZIP，没有横向溢出。此轮只重查变更的下载区，不重复宣称全部历史交互已重测。预览标签、视口覆盖与临时服务器均已清理。

2026-09-12 本地验证结束时，仅完成工作流与本地页面配置，未 push、触发远端部署或验证线上 HTTP。2026-09-13 用户已授权提 PR 并合入；本工作流合入 `main` 后部署，当前结果以 [Pages workflow](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml) 和 GitHub 部署记录为准，本地构建成功不作为线上部署证据。

2026-09-13 首次启动说明补充：构建通过，4 份资产、34 处引用、约 1,560 KiB。实际浏览器复查 `/Tursora/#download` 的 1722 px 桌面与 390 px 视口，并按文档坐标截取窄屏原尺寸下载区：四条步骤完整换行、蓝色首次启动链接清楚可见，页面宽度分别为 1722 / 390，无横向溢出；链接指向 GitHub README `#first-launch`，CTA 仍为最新稳定 release。此轮仅重查修改的下载区，不扩展既有整站交互或应用测试范围；视口覆盖、预览标签和临时服务器已清理。

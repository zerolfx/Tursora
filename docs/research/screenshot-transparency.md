# 真实截图透明圆角与 README 表格（2026-09-12）

用户明确选择“用脚本把窗口外背景变透明，保留真实圆角和窗口内部像素”。本轮据此处理真实打包应用截图，没有使用 AI 生成或重绘界面。README 改为说明 / 截图两列的两张 HTML 表格；按用户后续要求移除独立预览介绍后，包含 11 项常规功能、2 项默认关闭的实验功能，共 14 张功能截图，顶部图标和状态徽章不计入。Quick Look 等已有截图可保留为历史实现证据。

## GitHub 能力证据与边界

- GitHub 官方文档确认 `.md` 可以嵌入仓库图片，推荐相对路径，并给出 PNG 示例；私有仓库图片仍受读取权限限制。它也明确支持 `<picture>`。[图片与相对路径](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#images)
- GitHub 的 Primer 源码在 Markdown 表格内对 `img` 设置 `background-color: transparent`；普通图片规则约束最大宽度，没有强制白底。表格行仍有随主题变化的底色，透明像素显示的是所在行背景。[表格规则](https://github.com/primer/css/blob/main/src/markdown/tables.scss#L39)、[图片规则](https://github.com/primer/css/blob/main/src/markdown/images.scss#L5)
- 官方博客展示了按亮暗主题选择图片的 `<picture>` 用法。这是可用能力，本轮 README 并未实现随网页主题自动切换截图。[GitHub 官方示例](https://github.blog/developer-skills/github/how-to-make-your-images-in-markdown-on-github-adjust-for-dark-mode-and-light-mode/)

这些证据支持采用透明 PNG；不能由此宣称已经检查了本仓库的线上渲染，也不构成对未来 GitHub CSS 的保证。本轮只访问上述公开资料、检查本地 README 预览，未访问或发布实际私有 GitHub README 页面。

## 处理规则

工具为 [`app/tools/prepare-screenshots.swift`](../../app/tools/prepare-screenshots.swift)，使用系统 Swift、ImageIO、CoreGraphics 和 CoreText，无额外图像处理依赖。具体命令见 [截图维护流程](../images/README.md#capture-and-preparation-workflow)。

自动模式只接受四角存在近白外部背景、且能找到稳定暗色窗口边缘的截图。它在有界四角区域内，从外角连通填充识别背景，再处理紧邻边缘的窄带及实测外边界的抗锯齿尾部。没有拟合圆角矩形、统一半径裁剪、缩放或重排窗口内容。边缘依照白底混合关系 `C = αF + (1 − α)M` 估计覆盖度并去除白底混色，避免仅改 alpha 留下白晕；无法可靠估计时拒绝输出。

`--mask-from` 供调用者已经确认配准的截图使用：窗口边界、裁切、像素尺寸和倍率必须一致。本轮根任务目视确认同一 1200×720 窗口后，才将已准备暗图的四角 alpha 用于亮图。脚本只检查尺寸和受限角区，不会自动证明配准或调整位置；参考中 alpha 为 255 的内部像素完全取自输入图。不得用相同尺寸的另一个窗口作为几何证据。

符合输入格式且四个最外角像素 alpha 均为 0 的 PNG 逐字节复制，不重新编码。其他输入在 PNG 暂存文件重新解码后，逐像素核对全部受保护 RGBA；不符即拒绝。输出、原图、比较图不能同址，也不覆盖已有文件。路径检查先解析父目录 symlink，避免尚不存在的文件名绕过别名比较；主图与比较图分别先写唯一临时文件，再以不覆盖方式移动到目标位置。

“内部像素保留”指与 **macOS ImageIO 对源截图解码得到的 RGBA** 一致，包括 PNG 编码后的复核。JPEG 已有压缩和白底合成损失，不能声称找回原始未压缩截图或精确原始 alpha；不同 JPEG 解码器也可能有约 1 级通道差异。保持源色彩空间且不重采样，不能消除这些既有损失。统计中的 `changedPixels`、四角范围、透明 / 半透明数量、`protectedRGBABytes` 和 `protectedBytesEqual` 用于核对实际处理范围。

## 本轮素材与验证

`docs/images/features/` 现在共有 22 张 PNG。17 个旧 JPEG 入口已转换或由新截图替换，文档与站点引用迁移到 `.png`；另增 `text-preview.png`、`split-panes-light.png`、`search-light.png`。`favorites.png` 改用新亮色分栏截图，呈现 Favorites 侧栏、菜单关闭。当前菜单另外由辅助功能树确认，没有 Reveal in Finder，不能把关闭菜单截图当作菜单证据。

| 检查 | 结果及范围 |
|---|---|
| 旧图批处理 | 14 个候选通过：12 个 JPEG 角区恢复、2 个已有透明 PNG 字节复制；旧 Favorites 候选最终未采用，由新图替换。独立 ImageIO 审计验证尺寸、内部像素和有界角区，全部比较图已检查。 |
| 新图处理 | 8 个准备文件通过，全部 1200×720，共 27,620,680 个受保护 RGBA 字节逐字节保留；角区之外没有修改或新增透明度。新亮色分栏图同时成为 `favorites.png`。 |
| 保守拒绝 | 暗色名称过滤图在右上角边缘估计时残差 24.2 超过 22；借用配准参考仍发现非白外部像素。其搜索框蓝色焦点环靠近圆角，可能污染 JPEG 边缘，但这一原因仅是推断。改用失焦后重新拍摄的亮色过滤图，处理成功。Info 暗图左上残差 48.7，保留原始临时证据，未发布 PNG。没有为这两张图放宽阈值。 |
| 工具回归 | 重复运行和同图 mask 重放得到相同 PNG 字节；已有透明 PNG 原字节复制；已有输出、非白角、尺寸不符、symlink 同址比较图等拒绝测试通过。别名冲突在写主图前拒绝。 |
| 放大检查 | 每张不同的成功图均检查原图、亮 / 暗棋盘底和四角 4× 放大图，没有明显连续白底残边。窗口内容未被重绘。 |

新路径、分栏、标签、搜索、名称过滤和文本预览图来自 **2,024 项 smoke 连续三轮通过之后的打包应用截图阶段**。这不是后续 Dock 调整后的最终自动化结果。其他图片仍反映各自先前已验证的发布包阶段：每目录视图、文件任务、ZIP、Quick Look 等旧内容不会因为转换为 PNG 就成为本轮组合 UI 的实机证据。旧研究记录保留其原测试数和范围；部分 canonical 图片已替换，不能把当前图片当成旧阶段原始截图。具体归属见 [截图目录说明](../images/README.md#current-captures-and-historical-stages)，最新整体验证见 [HANDOFF](../HANDOFF.md)。

本地临时证据位于 `/private/tmp/tursora-tabs-appearance-verification/`：`transparency-probe/final-verification.json` 为工具回归，`prepared-assets/independent-validation.json` 为旧候选审计，`final-prepared/batch-summary.json`、`independent-validation.json` 和 `visual-review.txt` 为新图检查。临时目录未作为永久仓库资源提交。

## 网站与 README 显示检查

站点仍有路径、分栏、ZIP 三个工作流，共 4 个 canonical 资源；构建复制图片原字节，不执行透明化。截图链接、图片和弹窗图片使用透明底，容器限制溢出并保留显示圆角；弹窗标题独立成块，避免白色外框填满截图角落。这些 CSS 只影响展示，不修改 PNG 内部像素，也不代表产品页本身新增暗色主题。

PNG 刷新阶段静态构建通过，4 个资源、33 个本地引用，总计约 1,559 KiB。根任务在本地浏览器检查桌面图片弹窗及关闭后的焦点恢复，390 px 宽度没有页面横向溢出；本地 README 在 1000 px 视口中两张表格和当时 15 张功能图片全部加载，亮暗背景透明角显示正常。随后按用户要求删去独立预览行，最终表格为 14 张功能图片；数量与引用另作静态复核，不将此前浏览器检查表述为新布局重测。站点未部署，实际 GitHub 页面未验证。先前无 JavaScript、选择器键盘和其他浏览器检查仍以各自历史阶段记录为准，不计作本轮全部重跑。

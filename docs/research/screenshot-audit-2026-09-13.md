# README 与网站截图圆角审计（2026-09-13）

用户要求所有截图的原生窗口圆角外侧透明，不残留白底或其他底色，并明确授权确定性的截图 alpha 处理。真实界面内部不能因此修改；新功能截图须由最终打包应用实测后重拍。

## 0.2.1 已下载正式包：四张 README 指针重拍

对其余 25 张旧 canonical 的只读实图检查发现七处明显鼠标箭头 / 光晕；四张用于 README，另三张仅用于历史研究。主任务从已下载并完整核验的正式 0.2.1 pristine app 创建隔离 QA 身份 `com.tursora.releaseqa021.s0913`，实际操作后重拍 `/private/tmp/tursora-0.2.1-qa-u1_phjba/screenshots/{folders,share,terminal-settings,updates}.jpg`。该身份仅用于隔离验证，不能写成正式包身份；发布字节与签名检查由[0.2.1 记录](terminal-navigation-0.2.1.md)另行维护。

Folders / Share 均为 1100 × 740，侧栏实际宽 300 pt：左 pane 为 Seabreeze 演示目录，右 pane 为公开 Tursora 仓库的 Model，截图范围内没有其他项目名。Folders 选中 Model；Share 实际打开 `FileItem.swift` 的系统分享菜单，没有选择任何外部发送目标。Terminal Settings / Updates 均为 660 × 777：前者显示 System Login Shell、System Monospaced 12 pt、Follow Appearance，后者显示自动检查开启、自动安装关闭。Terminal Settings 最初的缓存帧未使用，采用单独获取截图后最后覆盖的版本。

处理前逐张查看原始图，未见鼠标指针或悬停提示；随后使用未修改的 `prepare-screenshots.swift`，四次处理 exit 0、stderr 为空。未修改 UI、降低阈值或抹去鼠标像素。原图、旧 canonical、处理 PNG、stats、亮暗比较图、哈希及全量 alpha 结果保存在 `/private/tmp/tursora-021-released-screenshots-i9q9qs45/`。

| Canonical | 改变的角像素 | 保护像素 / RGBA 字节不变 | 全透明 / 半透明 | 测量边色回退 | PNG SHA-256 |
|---|---:|---:|---:|---:|---|
| `folders.png` | 847 | 813,153 / 3,252,612 | 519 / 328 | 0 | `dc0966a610febd20fb85a12d9cb5facb2456237e03b8faa2f8ae5df7c3dfd2cb` |
| `share.png` | 847 | 813,153 / 3,252,612 | 519 / 328 | 0 | `4a185525175a148332c8695a24ccb6c9608ea50307771c81778cdae2862e2e13` |
| `terminal-settings.png` | 362 | 512,458 / 2,049,832 | 176 / 186 | 6 | `6be8e60517b3377e95221ac251d5401768310ff0744908b7f526238058b2b911` |
| `updates.png` | 362 | 512,458 / 2,049,832 | 176 / 186 | 6 | `7ad0cbc1d81fdd7553d0da7c8caed6d737aea11aead9ed6128377e75e2a9cdb6` |

完整亮暗棋盘和四角 4 倍比较均经目视核对，无白色外沿残留；保护区在 PNG 编码后逐字节相同，紫色系统标记及原生控件保持原样。正式目录只替换这四张，与已审阅暂存 PNG 字节相同；本 follow-up 其余 25 张哈希不变，29 张全部通过 alpha 门槛。

当前 README 的 20 张不同截图及网站四图未再发现明显鼠标指针 / 悬停痕迹；这属于实图目视复查，不是自动逐像素光标识别保证。**不声明全部 29 张无指针**：`app-icon-edges.png`、`text-preview.png`、`views-and-groups.png` 保留 2026-09-12 历史研究中的真实指针，当前 README 与产品页均不引用它们。此前七处发现及定位图见 `/private/tmp/tursora-cursor-review-r4nysli7/review.json`；四处公开宣传图的问题由此次重拍解决，另外三张不涂改历史证据。静态宣传引用清单与新图统计在本轮 `verification.json`；线上渲染、部署及应用更新检查由主任务单独记录。

## 0.2.1 最终界面：四张 canonical 正式替换

主任务在最终 0.2.1 release app 中捕获 `/private/tmp/tursora-0.2.1-qa-u1_phjba/screenshots/{terminal,split-panes,path-navigation,zip-browsing}.jpg`，四张均为 1100 × 740；捕获前，同一份 102 个 Swift 文件已完成 3 × 3,435 项 smoke，精确验证与操作范围见[0.2.1 记录](terminal-navigation-0.2.1.md)。处理前逐张检查真实原图，无鼠标指针或悬停提示；Terminal 使用主任务最后覆盖的已清除文本选区版本，保留实际 shell 光标。

Terminal 展示默认深色外观、System Monospaced 12 pt、一行标题 / 重启 / 隐藏操作和 Source 中实际 pwd / ls 输出。分栏图为左侧 Seabreeze 列表、右侧 Source 图标；路径图显示 Design Archive 补全；ZIP 图为左侧 Delivery.zip 只读内容、右侧 Source 图标。四图均未展开 Folders；底部只保留文件上下文和缩放，不显示终端状态、动画、时长或可用容量。

原始副本、旧 canonical、处理 PNG、逐图 stats、明暗对比图和完整验证 JSON 均保存在 `/private/tmp/tursora-021-screenshots-ouuu25vr/`。使用未修改的 `prepare-screenshots.swift`，临时 module cache 与输出均归本轮目录；四次处理 exit 0、stderr 为空。未降低阈值、拟合通用圆角或修改界面内部，PNG 编码后再次核对全部保护像素。

| Canonical | 改变的角像素 | 保护像素 / RGBA 字节不变 | 全透明 / 半透明 | 测量边色回退 | PNG SHA-256 |
|---|---:|---:|---:|---:|---|
| `terminal.png` | 850 | 813,150 / 3,252,600 | 518 / 332 | 0 | `f6276b992c149cecec723c2c0450df36244b69ba696b21bd7767bd0ea9042e70` |
| `split-panes.png` | 837 | 813,163 / 3,252,652 | 519 / 318 | 0 | `e8c56d538b662ea701f12a9978ba2b6428d6682e681d04a88582838b3c9698d0` |
| `path-navigation.png` | 837 | 813,163 / 3,252,652 | 519 / 318 | 0 | `cbf111015f6ce7899bd92b32b5368bea6a8533343fbccfab609a09ab7652305c` |
| `zip-browsing.png` | 837 | 813,163 / 3,252,652 | 519 / 318 | 0 | `82968cd19725609803ed95fc9207bc4db999de1af7ff15a9225f319adfbbbc86` |

逐张检查原图、完整亮暗棋盘合成和四角 4 倍图，未见白色外沿残留；紫色系统标记、文字、控件及真实轮廓均保留。只替换这四张 canonical，与已检查暂存 PNG 逐字节相同；其余 25 张哈希不变，全目录 29 张通过 `screenshot_alpha.py`。逐图原始 / PNG 哈希与保护区统计见 `verification.json`，全量 alpha 结果见 `canonical-alpha.json`。网站构建、浏览器检查和正式部署由主任务分别记录，本轮图片处理不代替这些步骤。

主任务另外实测隐藏前后同一 shell PID 68154、30 秒前台 sleep 期间导航等待、返回安全提示符后从 Seabreeze 跟随至 Source，以及隐藏任务的退出确认 Cancel 保留任务。截图只记录最后可见界面，不能用其中的 pwd 文本单独证明上述过程。下文的 0.2.0 状态栏、早期手动 Restart 与旧截图统计均保留原历史范围；当前 Terminal 和三张主工作流图以上述四张为准。

## 0.2.0 安装页静态检查（新增终端截图替换前）

0.2.0 安装入口前置后，当前 `python3 site/build.py` 通过：**5 份资产、39 处引用、约 1,629 KiB，全部 29 张 canonical PNG 通过 alpha 门槛**。新增站点资产复用已验证的 `installation.png`；五份分发资产与源文件逐字节一致，未新增 canonical 图片或重新编码。

独立静态解析确认：导航与首屏两个“安装指南”均为 `#installation` 页内链接，唯一目标及旧 `#download` 兼容锚点存在；两个“免费下载”仍指向真实 latest release，无未发布 0.2.0 固定资产链接；Homebrew 代码保留两条实际命令行。README 安装段位于 Features / 首个表格之前，20 个不同截图引用均存在。页面与 README 保留准备中 0.2.0 / 已发布 0.1.0 的真实阶段说明。

证据（含资产 SHA、全部 alpha 清单及链接）为 `/private/tmp/tursora-installation-site-static-wu6hgft4/checks.json`；`git diff --check` 通过。本次未操作浏览器或应用、不运行 smoke，不能据此声明锚点的实际滚动、窄屏换行 / 图片查看器或新终端状态已实测。该静态检查时，新的 General / Terminal 原始截图尚未提供；随后替换阶段见下节。

随后主任务完成独立浏览器实测：1200 × 850 中点击导航“安装指南”，URL fragment 变为 `#installation`，安装区顶部距视口 100 px，页面宽度 1200；390 × 844 中点击首屏“安装指南”跳到同一目标，页面宽度 390、无横向溢出。窄屏实际截图确认四步 DMG 说明和 Homebrew 命令可读；tap URL 视觉换行，但 `pre.textContent` 仍精确保留两条原命令。

桌面和窄屏均实际打开安装图弹窗，窄屏暗色遮罩中的原生透明外沿经目视确认；Escape 均将焦点返回原安装图链接（AX label：`查看 DMG 安装窗口完整截图`）。实点范围只有桌面导航与窄屏首屏按钮，其余同目标结论来自上述静态解析；未扩展为所有键盘、无 JavaScript 或应用交互测试。主任务已重置视口并关闭自有页签，服务器停止另由主任务处理。

## 0.2.0 会话保留与状态栏截图正式替换

主任务提供 `/private/tmp/tursora-terminal-session-qa/screenshots/settings.jpg` 与 `terminal.jpg`，分别为真实 660 × 777 General 和 1100 × 740 终端窗口。已先保存独立原始副本，再使用未改动的 `prepare-screenshots.swift` 确定性处理，未使用任意几何遮罩或编辑界面内部。首次 Swift 编译的默认 module cache 无写权限，改用本轮临时目录内的 cache 后两次处理均 exit 0；没有更改工具链或应用源码。

General 实际开启终端与 ZIP，并说明收起或禁用面板仍保留会话；原紫色系统标记完整保留。Terminal 显示目录树、分栏、自定义颜色、右下角 `Terminal · 1 task`，以及实际打印的 Shell PID `55113` / Background PID `55145`。主任务报告此捕获位于隐藏、禁用、重新启用并恢复会话之后；操作顺序与存活核对由[会话生命周期记录](terminal-session-lifecycle.md)单独说明，不能仅凭截图中的文字断言任务检测或清理已通过。`quit-hidden.jpg` 是独立退出交互证据，未加入 canonical。

| Canonical | 改变的角像素 | 保护像素 / RGBA 字节不变 | 全透明 / 半透明 | 测量边色回退 | PNG SHA-256 |
|---|---:|---:|---:|---:|---|
| `settings.png` | 362 | 512,458 / 2,049,832 | 176 / 186 | 6 | `7922bbc6461fd836d9823fcc4ae4e7af0eee4d7123e90a9f52fad1338b91352d` |
| `terminal.png` | 849 | 813,151 / 3,252,604 | 519 / 330 | 0 | `49cbc1faa7f19edced3b9cd738dbd6db3db974813eb1c6d3a6f214422df6f402` |

原始图、明暗棋盘整体与四角 4 倍细节均逐一查看，边缘未见残留白底，原内部与窗口轮廓保留。处理器编码后重新解码核对保护区，`protectedBytesEqual` 均为 true。已替换两份 canonical，拷贝与暂存 PNG 字节相同；其余 27 张图片 SHA 全部未变。README alt 与图片清单已更新到实际可见内容。

所有证据保存在 `/private/tmp/tursora-lifecycle-screenshots-qapzdqgt/`：`sources.json` 含原图来源和 SHA，`*.raw.jpg` / `*.png` / `*-stats.json` / `*-contact.png` 为处理链，`*.previous.png` 保留上一阶段图片，`before-inventory.json` / `replacement-inventory.json` 记录替换范围。此段只报告截图检查，最终应用源码、三轮 smoke 和发布验证另由主任务记录。

替换后独立 `screenshot_alpha.py --json` 全量检查 **29 张通过、0 错误**；清单为同目录 `alpha-audit.json`。`site/build.py` 再次通过，5 份资产、39 处引用、1,629 KiB，所有网站资产的 SHA 与替换前检查一致；日志为 `site-build.out` / `site-build.err`，stderr 为空。General / Terminal 未被网站独立复制，但仍受其全量 canonical 检查门槛覆盖。`git diff --check` 通过；此步没有重跑浏览器或应用。

## 初始盘点

`docs/images/features/` 初始共 26 张真实 PNG。用原生 ImageIO 解码逐图检查 alpha，20 张四角已完全透明且带半透明抗锯齿，6 张完全不透明。网站的三张截图复用透明的 canonical PNG，本轮初始没有网站独立副本或 CSS 白底问题。

| 初始状态 | 文件 |
|---|---|
| 需修复；README 安装区使用 | `installation.png`，640 × 280 |
| 需随新 Settings 重拍；README 使用 | `settings.png`、`updates.png`，540 × 737 |
| 需重拍；README 使用 | `terminal.png`、`workspace-restored.png`，1100 × 712 |
| 需重拍；研究记录使用 | `zip-recovery.png`，1100 × 712 |
| 已透明；网站与 README 共用 | `path-navigation.png`、`split-panes.png`、`zip-browsing.png` |
| 已透明；其他 canonical 截图 | `app-icon-edges.png`、`compress-extract.png`、`connect-server.png`、`favorites.png`、`file-operation-tasks.png`、`file-operations.png`、`folder-views-unified.png`、`folder-views.png`、`name-filter.png`、`quick-look.png`、`search-light.png`、`search.png`、`share.png`、`split-panes-light.png`、`tabs.png`、`text-preview.png`、`views-and-groups.png` |

原始统计保存在 `/private/tmp/tursora-distribution-qa/initial-alpha.jsonl`。原脚本对六张不透明图均拒绝：安装图和 Updates 左上存在带颜色的系统指示边缘，局部颜色残差超出阈值；其余四图缺少可可靠区分白底的深色边界。本轮没有降低旧处理器的安全阈值，也没有套一个任意圆角矩形。

## 防止再次混入白底截图

新增 [screenshot_alpha.py](../../app/tools/screenshot_alpha.py)，只使用 Python 标准库，可在 macOS 与 Pages 的 Linux runner 运行。它验证真实 PNG 签名、chunk CRC、8-bit RGBA 非交错格式、解压后尺寸与 PNG 行过滤；报告每图 SHA-256、尺寸、四角 alpha、全透明及半透明像素数。四角必须为 alpha 0，且必须存在半透明边缘。它只检查，不改像素。

```sh
PYTHONDONTWRITEBYTECODE=1 python3 app/tools/screenshot_alpha.py --json
python3 site/build.py
```

无路径参数时检查整个 `docs/images/features/`，不是只抽查 README 或网站当前用到的几张图。`site/build.py` 在拷贝资产之前运行相同检查；Pages 工作流触发路径涵盖所有 canonical 图片与检查脚本。因此未来只更新研究截图或 README 截图，也会触发验证。PNG 通过检查仍需要人工确认真实原生轮廓和亮暗背景外观；透明几个角不能单独证明所有边缘都正确。

## 本轮验证阶段

- 初始 20 张透明 PNG 的 Python 统计与原生 ImageIO 的四角、全透明、半透明像素数逐项一致；6 张不透明图均被新检查器拒绝。
- 4 个截图检查器测试通过，包括真实现有图、已知 RGBA 边缘、RGB / 假 PNG 拒绝，以及 CRC / 截断 / 解码尺寸错误。
- （已被上文 0.2.1 重拍章节取代）新功能合并后的真实窗口重拍、透明化及最终全量检查由整合阶段继续；本段初始盘点不代表那些当时尚未进行的截图已完成。最终结果须追加实际 raw / processed 来源、像素保护统计和亮暗目视范围。

这是截图与网站构建检查，不能替代应用 smoke，也不能把历史截图宣称为本轮新增交互的实测证据。

## 深色边缘的保守回退

`prepare-screenshots.swift` 新增的回退只在原对角保护样本无法满足残差时生效：尝试当前角已测到的顶边或侧边颜色，仍要求前景均值 < 205、对比平方和 > 7,500、残差 ≤ 22 与有效 alpha。没有扩大白色连通区域、候选窄边界或修改任意内区；统计新增 `stableEdgeFallbackPixels`。颜色仍解释不了的边缘继续失败，亮色轮廓继续要求原生 alpha 或已验证配准的深色参考。

回归使用明确标记的合成测试图，不作为产品截图：深色圆角旁紫色内区使旧版本以残差 63.2 拒绝，新版本通过；无法解释的彩色边缘和浅色边缘仍拒绝。三个 macOS 原生工具测试通过，全部 Python 工具测试当前共 83 个通过。

旧 `updates.png` 的诊断输出只使用 5 个回退候选，改变 360 个角像素；397,620 个保护像素 / 1,590,480 RGBA 字节与源图相同。`updates-improved-contact.png` 在明暗棋盘与四角 4 倍图上已目视核对，紫色系统标记未修改；这些诊断文件位于 `/private/tmp/tursora-distribution-qa/`。Canonical Updates 尚未用旧画面替换，新 Settings 页面仍由最终发布包重拍。安装图的顶角通过，但底部白色内容边界继续被拒绝，未输出或替换。

## 初轮新版窗口暂存验证（非最终截图）

主任务提供 `/private/tmp/tursora-customization-qa/screenshots/settings.jpg` 与 `terminal.jpg`，先复制为独立 raw，再处理到 `/private/tmp/tursora-distribution-qa/provisional-customization/`。此阶段 Settings 为 660 × 777，终端主窗为 1100 × 740，均深色真实窗口。Settings 改变 362 个角像素，512,458 个保护像素一致，6 个测量边色回退候选；Terminal 改变 850 个角像素，813,150 个保护像素一致，无回退。两张都通过跨平台 alpha 门槛与明暗棋盘、四角 4 倍目视，真实控件、文本和紫色系统标记保留。

这两张暂存图未替换 canonical。字号 Tab 提交与系统目录别名跟随后续修复，主任务将对最终包重新验证并重拍；这些 raw / contact / stats 只记录初轮处理器可行性。安装图等待同一 Finder 窗口的精确配准深色参考，不推断白色内容下方几何。

## Settings 三页正式替换

2026-09-13 10:17–10:19（Asia/Shanghai）的主任务真实截图来自已修复字号 Tab 提交、F6 终端开关和系统物理路径的应用包。随后仍在进行的树异步 / 选区与快捷键程序化重选修复不改变这三页外观；最终组合验证单独记录。

源文件 `/private/tmp/tursora-customization-qa/screenshots/{settings,terminal-settings,updates}.jpg` 已复制到 `/private/tmp/tursora-distribution-qa/canonical-settings-20260913/` 作为独立 `*.raw.jpg`；同目录保留输出 PNG、逐图 `*-stats.json`、明暗 `*-contact.png` 和该阶段全量 `alpha-audit.json`。已分别更新 canonical `settings.png` / `updates.png` 并新增 `terminal-settings.png`，拷贝后与暂存输出逐字节一致。

三图均为 660 × 777，每图只改变 362 个角像素；512,458 个保护像素 / 2,049,832 RGBA 字节与原始解码一致，alpha 0 像素 176、半透明像素 186，同角测量边色回退候选 6。已检查原始截图、明暗棋盘和四角放大，真实系统标记、焦点、控件和示例预览均保留。

- General：终端与 ZIP 均启用。
- Terminal：实际展示 Custom Shell `/bin/zsh`、Menlo-Regular 14 pt、Custom 文本 `#E6E6E6` / 背景 `#14202B`，这是用户可选配置的实机演示，不是默认值截图。
- Updates：自动检查开、自动安装关。主任务之后将隔离 QA 设置的自动检查恢复为关闭；图片如实保留拍摄时的开关状态。

此阶段 canonical 共 27 图，23 图通过 alpha 门槛；旧 `installation.png`、`terminal.png`、`workspace-restored.png`、`zip-recovery.png` 仍不透明且等待主任务重拍。新增 `folders.png` / `shortcuts.png` 也在拍摄中，最终预计 29 图。因此当前网站完整构建仍应拒绝通过，不将三页替换计为全部截图完成。

## 安装窗口：同一 Finder 窗口配准后正式替换

2026-09-13 10:25（Asia/Shanghai），主任务在本轮生成的 `app/dist` DMG 只读挂载中打开自有 Finder 窗口，隐藏工具栏并调整到完整显示两图标和箭头的 641 × 281 窗口，拍摄 `installation.jpg`。随后在**同一个 Finder 浏览窗口**显示工具栏、Go to Folder 导航到自有空目录，再隐藏工具栏拍摄 `installation-dark-reference.jpg`；再次显示工具栏、Back 回安装卷、隐藏工具栏并重拍原图，确认仍为相同的 641 × 281 frame。注册依据是此实际同窗口往返流程及未变的裁切、尺寸、比例，不是仅因两张图片同尺寸而推定。此流程未安装应用，未改 DMG。

两份 raw 已独立保存在 `/private/tmp/tursora-distribution-qa/canonical-installation-20260913/`。先透明化实际深色参考，再以 `--mask-from installation-reference.png` 处理安装原图；同目录保留两份 stats、明暗棋盘 / 四角 4 倍 contact sheet 和全量 alpha 审计。深色参考使用 5 个同角边色回退候选；最终安装图仅改变 361 个角像素，179,760 个保护像素 / 719,040 RGBA 字节与原始解码完全一致，174 个全透明及 187 个半透明像素。安装图内部白色是实际 DMG 示意图背景，已完整保留；紫色系统标记、图标、箭头和文字未修改。

原图、参考图与两份明暗 contact sheet 已逐角目视检查，canonical `installation.png` 与暂存输出字节一致，SHA-256 为 `4525fe6cfb3d147a288cbf540254ce454b16fa50834ca84dd9a73d4550b330d4`。此阶段仍为 27 张 canonical，24 张通过；剩余旧 `terminal.png`、`workspace-restored.png`、`zip-recovery.png` 及新增 Folders / Shortcuts 等待重拍。该图证明当前本地安装布局与透明外沿，不代表新 release 已发布或已公证。

## 保留的 20 张透明图全量目视复核

初始表中所有 20 张已透明 PNG 均经处理器 `unchanged-transparent-png` 路径生成字节完全相同的暂存副本及 contact sheet，canonical 本身没有重新编码或修改。证据保存在 `/private/tmp/tursora-distribution-qa/retained-transparent-20260913/`，每图有 PNG、stats 和明暗 contact。已逐张查看原图 / 亮色棋盘 / 暗色棋盘整体及四角 4 倍细节，覆盖 README、网站的三张共用图，以及仅用于研究的图；没有发现圆角外的白色矩形背景或其他不透明底色，真实亮色内部和系统标记保持原样。

此复核补齐旧图的本轮透明外沿视觉覆盖，不把旧 UI 内容计为本轮新快捷键、终端设置或目录树的实测。全量最终数量仍随其余真实新图加入后重新统计。

## Shortcuts 页正式加入

2026-09-13 10:37:25（Asia/Shanghai）主任务拍摄的真实 `shortcuts.jpg` 已复制至 `/private/tmp/tursora-distribution-qa/canonical-shortcuts-20260913/shortcuts.raw.jpg`。画面过滤词为 `Show`，选中 `View → Show Terminal` 并显示自定义 F6；录制按钮同样为 F6，Clear / Reset / Reset All 与原生输入范围说明完整可见。随后的目录树 AppKit 回调修复不改变 Settings 四页内部。

处理后新增 canonical `shortcuts.png`，660 × 777；只改变 362 个角像素，512,458 个保护像素 / 2,049,832 RGBA 字节一致，176 个全透明与 186 个半透明像素，6 个同角边色回退候选。原图及明暗 contact、四角放大均已检查；stats、contact 与 alpha 审计保存在同一暂存目录。SHA-256 为 `e7e24f47d186e05a943ac121d0021d6371f5a28aa1f5aabc11b6f682c67276f7`。当前 28 张 canonical 中 25 张通过，剩余三个旧不透明图和一张新增 Folders 图仍待重拍；最终三轮应用验证另行记录。

## 终端与 ZIP 失败界面正式替换

主任务提供 2026-09-13 10:38:53 的 `terminal.jpg` 与 10:39:23 的 `zip-recovery.jpg`（Asia/Shanghai），均为真实 1100 × 740 深色应用窗口。两图隐藏目录树，后续只修复树 AppKit 展开回调不改变这些内部画面。终端实机演示 Menlo 14 pt、自定义文本 / 背景色、选中的工具栏按钮，以及 `ls Source`、`export DEMO=ready`、`printenv DEMO` 返回 `ready`；ZIP 使用自有无效 `Recovery.zip`，实际显示 Retry / Open Enclosing Folder，并保留原目录内容。

| Canonical | 改变的角像素 | 保护像素 / RGBA 字节不变 | 全透明 / 半透明 | SHA-256 |
|---|---:|---:|---:|---|
| `terminal.png` | 849 | 813,151 / 3,252,604 | 519 / 330 | `0a15e8ff2063a7d5260e861209d99f3511993a0d25e6025e0a84d90ccbe384a0` |
| `zip-recovery.png` | 839 | 813,161 / 3,252,644 | 519 / 320 | `3c8a22ac9d3dc671ce81f76b533f41606cf7b92b39ba702bae27199e175b750d` |

两图均无边色回退；原图、明暗整体与四角放大已检查，canonical 和暂存输出字节一致。独立 raw / PNG / stats / contact 分别保存在 `/private/tmp/tursora-distribution-qa/canonical-terminal-20260913/` 与 `canonical-zip-recovery-20260913/`。后者的全量审计为 28 图、27 图通过，仅旧 `workspace-restored.png` 不透明；新增 `folders.png` 同样等待最终包重拍。网站门槛仍应拒绝旧工作区图，不将此阶段误记为完整构建通过。

## 最后两图与全量通过

2026-09-13 的 `workspace-restored.jpg`（10:43:22）与 `folders.jpg`（10:44:23，Asia/Shanghai）来自修复 `shouldExpand` AppKit 回调后的实际应用包。工作区图经过正常退出与重开，恢复双 pane、两个标签和右侧活动图标视图，没有恢复终端。Folders 图实际手动沿 Home → Tursora → app → Sources → Tursora → Model 展开并导航；选中 Model 行完整可见，兄弟节点保留折叠，未出现循环 Loading。后续快捷键边界与测试桥接修复的最终 smoke 单独记录，不能由这两图代替。

| Canonical | 尺寸 | 改变的角像素 | 保护像素 / RGBA 字节不变 | 全透明 / 半透明 | SHA-256 |
|---|---|---:|---:|---:|---|
| `folders.png` | 1100 × 740 | 834 | 813,166 / 3,252,664 | 520 / 314 | `0689f743770c231f1cc012cff1066bf991b9125e54d833f3287fc31e408e9079` |
| `workspace-restored.png` | 1100 × 740 | 842 | 813,158 / 3,252,632 | 518 / 324 | `65dd671a03d3bd848d04ad812bab7c7344aebcd8b6eaa0c95c3574416aa6ae44` |

独立 raw、输出、stats 与明暗 contact 保存在 `/private/tmp/tursora-distribution-qa/canonical-final-two-20260913/`。两图无边色回退，原图、亮暗整体及四角放大均已检查，canonical 与输出字节一致。README alt 已改为真实 Model 树和两个标签 / 右侧图标的恢复状态。

**本轮截图完成：29 张 canonical 全部通过 alpha 门槛，0 错误。** 初始 20 张保留字节不变；六张原不透明图全部以真实新图替换；新增 Shortcuts、Terminal Settings、Folders 三图。所有 29 张都覆盖明暗整体及四角视觉复核，新处理图逐一验证内部保护像素。全量 JSON 清单包含各图尺寸、alpha 数量和 SHA-256，保存于 `/private/tmp/tursora-distribution-qa/final-alpha-audit.json`。

`site/build.py` 完整构建通过：4 份 canonical 资产、36 个引用、约 1,560 KiB，并再次检查全部 29 张图。网站的三张真实截图与源文件字节一致；构建记录为 `/private/tmp/tursora-distribution-qa/site-build-final.{out,err}`。浏览器桌面 / 窄屏检查由主任务另行完成；网站发布和最终应用 smoke 不属于此截图检查的完成结论。

## 本地网站浏览器复查

主任务在独立的 in-app browser 页签检查本次 `site/dist`，由 `127.0.0.1:8093` 仅提供构建目录。1200 × 850 桌面与 390 × 844 窄屏均看到免费开源 hero、MIT、下载、首次启动及 Homebrew 说明；页面宽度与 `scrollWidth` 分别都为 1200 / 390，没有横向溢出。切换 ZIP 页签正常；390 px 下打开截图查看器，透明截图在暗色遮罩上外沿干净，Escape 关闭后焦点回到 aria-label 为 `查看ZIP浏览完整截图` 的原链接。

所有**可见**图片均已加载；最初隐藏工作流里的 lazy 图片不计为加载失败，本次不宣称所有隐藏图片都在初始载入时下载。浏览器真实 PNG 保存在 `/private/tmp/tursora-customization-qa/screenshots/site-desktop.png` 与 `site-narrow.png`，记录下载区实际排版；两图也由文档任务查看。主任务恢复 viewport 并关闭自有页签，临时服务器 session 1525 已用 KeyboardInterrupt 正常退出（exit 0）。此次检查未发布网站、未访问或修改线上 GitHub README，也不代替应用的窄窗布局测试及最终三轮 smoke。

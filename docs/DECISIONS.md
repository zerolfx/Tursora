# 决策记录

按时间顺序。每条写清选了什么、为什么、代价是什么。改主意时在原条目下追加，不删。

| # | 日期 | 决策 | 理由 / 代价 |
|---|---|---|---|
| D0 | 2026-08-19 | **不移植 Dolphin / KIO，原生重写** | Phase 0 审计（[audit/PHASE-0-REPORT.md](audit/PHASE-0-REPORT.md)）：移植可行，但基础功能在 macOS 原生 API 上几乎免费，KIO 栈几乎纯是成本；Dolphin 的差异化在 UI 行为。审计不作废，它记录的 APFS 大小写、NFD/NFC、`UF_HIDDEN`、per-volume `.Trashes` 原生路线一样会踩 |
| D1 | 2026-09-10 | 标签栏**自绘**，不用 `NSWindow.tabbingMode` | 原生窗口标签把"每标签一个 window"绑死，和分栏打架；也做不出 Dolphin 式紧凑标签。代价：标签的拖拽、重排、关闭按钮全部自己画 |
| D2 | 2026-09-10 | v1 视图 = 列表（`NSOutlineView`，可就地展开）+ 图标（`NSCollectionView`），带缩放与预览 | 原定图标视图 v2，用户要求提前。紧凑视图不做 |
| D3 | 2026-09-10 | `Return` = 重命名（Finder），`⌘↓` = 打开；点击已选中项的文字延迟进入重命名 | 跟 macOS 用户的肌肉记忆，不跟 Dolphin。判断不依赖 `mouseDown` 与拖放会话回调的先后 |
| D4 | 2026-09-10 → 2026-09-11 | 应用名 **Tursora**，bundle id `com.tursora.Tursora`（打包脚本 `TURSORA_BUNDLE_ID` 可覆盖） | 原名 Otter File Manager / `com.otterfm.Otter`，2026-09-11 改名。代价：release 版的 UserDefaults 域随 bundle id 变，旧的收藏与偏好不迁移 |
| D5 | 2026-09-11 | 分栏提前到 v1，结构照 Dolphin（标签 → 1–2 pane），不是"每 pane 多标签" | 用户确认对标 Dolphin |
| D6 | 2026-09-10 | **不用 Xcode**：SPM + 打包脚本产出 `.app`，无 nib / storyboard / asset catalog | Command Line Tools 就够；代价：所有 UI 在代码里建，图标只能用 SF Symbol 与系统图标 |
| D7 | 2026-09-10 | `swift-tools-version:5.9`，Swift 5 语言模式 | 避开 Swift 6 严格并发的整改成本；AppKit 代码大量主线程回调 |
| D8 | 2026-09-10 | 验证靠**应用内 smoke test**（`TURSORA_SMOKE_TEST=1`），不靠截图 | 开发环境拿不到屏幕访问权限；每个功能都要加 headless 可查的检查，跑三遍看稳定性。代价：外观只能由人看 |
| D9 | 2026-09-11 | 快捷键：`⌘1…9` = 标签页（Dolphin），视图模式用 `⌘⌥1/2`；`⌘L` = 编辑地址 | 与 Finder 的 `⌘1–4` 视图、`⌘L` 替身冲突，接受；对齐留作后续项（[gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md)） |
| D10 | 2026-09-11 | 文件操作语义照 Finder：拖放不弹菜单（同卷移动 / 跨卷复制 / `⌥` 复制）；冲突对话框照 Finder 的 Keep Both / Skip / Stop / Replace + Apply to all | Dolphin 的"松手弹菜单"和"全部跳过 / 覆盖 / 自动重命名"都改成 macOS 用户熟悉的形态 |
| D11 | 2026-09-11 | 过滤：形态照 Finder（工具栏搜索框 + 范围栏），语义照 Dolphin（子串 + 通配符，按 pane） | 两边各取一半，见 SPEC §8 |
| D12 | 2026-09-11 | **Finder 证据规则**：凡是"对标 Finder"的标签、措辞、图标、分组名，只用 Finder 自己的资源（`strings` 抽 nib、`plutil` 读字符串表）做依据；推断出来的要在文档里标"仍是推断" | 记忆里的 Finder 细节经常错（组名、分组顺序）；代价：nib 去重后拿不到每一项的图标名 |
| D13 | 2026-09-11 | 撤销按窗口，不做 Finder 式全局撤销栈 | `NSWindow.undoManager` 现成；Info 窗口里的改名注册到 Info 窗口自己的栈 |
| D14 | 2026-09-11 | Info 窗口永不成为 main window | 否则 Inspector 与 Go 菜单会跟着 Info 窗口走。用 `canBecomeMain = false` 子类 |
| D15 | 2026-09-11 | 读文件 flag（锁定、隐藏扩展名、可读写）走 `FileManager`，不走 `URL.resourceValues` | 后者在同一次 run loop 内缓存，写完立刻读拿到旧值 |
| D16 | 2026-09-11 | 文件夹始终排在文件前，不可关 | Finder / Dolphin 默认；可关做成偏好留作后续 |
| D17 | 2026-09-11 | 后台 agent 只用于读代码出文档、对 diff 做一次对抗性 review；难度估算这类不再大规模并行 | 用户反馈 97 个 agent 过度且撞额度 |
| D18 | 2026-09-12 | smoke test 启动等待首轮目录加载完成，最多 15 秒 | 固定等一秒会把尚未完成的异步加载当成空目录；按 generation 等待，空目录与错误也会结束等待，超时明确失败。代价：卡住的加载最多等 15 秒；不承诺冷启动目录能在一秒内列完 |

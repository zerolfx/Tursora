# 文件夹树与 Dolphin Places 对照（2026-09-13）

用户明确要求 Dolphin 有文件树就实现。此项在 `codex/customization-and-distribution` 开发，最终组合验证与实机证据见页末。

## 固定依据

本地 `upstream/dolphin` 固定提交 `5e457ee9e88aa6277fbf056cd5c32462c5318866`：

- `src/dolphinmainwindow.cpp` 的 Folders / Places dock 创建代码：两者独立，均允许左右停靠；Folders 用 F7，Places 用 F9，默认显示 Places、隐藏 Folders，活动 URL 连接到树面板。
- `src/panels/folders/folderspanel.cpp`：首次显示时才创建模型，`setShowDirectoriesOnly(true)`，支持展开和单击打开目录。
- `src/panels/folders/dolphin_folderspanelsettings.kcfg`：默认不显示隐藏文件夹、LimitToHome 开启，允许自动滚动。

[官方面板说明](https://docs.kde.org/stable_kf6/en/dolphin/dolphin/panels.html)分别解释 Places（收藏位置和设备）与 Folders（目录层级）。它们能同时显示，Places 并不是文件树的另一种名字。

## Tursora 实现与取舍

- 保留原 Favorites / Locations 列表；View → Show Folders（默认 F7，可自定义）在侧栏下方展开独立 **Folders**，可拖动两者之间的分隔线。默认隐藏，折叠整个侧栏暂停目录树；再次打开恢复。
- 使用原生 `NSOutlineView`，只显示可导航的文件夹，不进入应用包。按需后台加载展开节点和活动路径的祖先，不在启动时递归扫描磁盘；隐藏面板取消过期结果和文件监听。
- 单击树节点导航当前活动 pane；切换 pane、标签和普通目录时展开并选中活动路径。ZIP 对应原归档所在目录，不展示临时解包副本或把逻辑 ZIP 路径当成本地目录。
- 右键操作捕获实际目标 URL，提供 Open、Open in New Tab、Open in Other Pane；文件拖到目录沿用既有同卷 Move / 跨卷 Copy / Option 强制 Copy 判断，变更通过 Browser 的 FileOperations 与撤销流程。
- Show Hidden Folders 与 Limit to Home Directory 是目录树自己的选项，不改变文件区的隐藏、过滤、排序和分组。Home 内默认从 Home 展示，Home 外从 `/` 展示；路径不存在或读取失败在面板内显示，不弹模态对话框。
- 会话文件兼容旧版本，新增显示状态、侧栏内分隔比例及两个选项；不存整棵目录树、展开全集或文件缓存。关闭会话恢复时沿用原不保存策略。
- 与 Dolphin 的差别：本轮采用同一侧栏中的上下布局，没有实现可拆卸、可移到右侧的 dock 框架；没有新增 Dolphin 的 Places F9 默认快捷键，以保留现有 Toggle Sidebar 习惯（可自行改键）。

## 实现边界

`FolderTreeModel` 负责 provider 读取、节点身份、过期请求拒绝及目录变更刷新；`FoldersPanelController` 负责树与上下文菜单；`SidebarViewController` 组合两面板；`MainWindowController` 负责活动 pane、会话和动作路由。树隐藏时不启动 provider 枚举，缓存刷新保持仍存在节点的身份；节点被删除时清除选区，不能把旧行号套到下一个目录。

`NSOutlineView.shouldExpandItem` 只回答权限，不修改 expanded 集合或发起读取；AppKit 辅助功能查询也会调用它。只有真实 `outlineViewItemDidExpand` 才记录并异步调用模型加载，避免在展开中途用 Loading 更新重建行。同步重载 / 重选抑制回调，路径定位等排队刷新完成后再交付，移除节点清理等待回调；选中行在最终布局后滚到完整可见区。

## 验证状态

`FolderTreeSmokeTests` 覆盖模型与窗口路径，包括辅助功能查询不加载其他目录的回归；最终 95 份 Swift 源码 3,194 项 smoke 连续三轮通过（`smoke-7` / `8` / `9`），均 exit 0、stderr 为空、源码未变。交付 app / DMG 构建与签名、包内容及安装布局核对通过；精确源码清单和组合日志见[定制功能整合记录](customization-integration.md)。

打包应用实测已完成：F7 打开独立 Folders，实际沿源码层级展开并单击 Model 导航，选中行完整可见，其他分支保持折叠且 Loading 结束；拖动上下分隔线后继续跟随，右键 UI → Open in Other Pane 保留左侧并激活右侧。修复地址栏布局后，从 1100 × 740 实际拖到窗口最小 560 × 380，树、分栏和导航保持响应，再恢复原尺寸。正常退出并仅让 QA 副本以浅色重开后，树可见性、分隔比例、分栏及两个标签恢复，未启动终端；系统外观与生产偏好未改。

真实 `folders.png` 与工作区恢复图已透明化，内部保护像素不变；29 张截图全量检查通过。原始图片、具体操作与阶段边界见[整合记录](customization-integration.md)和[截图审计](screenshot-audit-2026-09-13.md)。本轮不把上述点击和菜单验证扩大为所有原生拖放手势已经实测。

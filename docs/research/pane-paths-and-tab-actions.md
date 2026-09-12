# 分栏地址栏与标签操作

**后续变更**：本篇保留原阶段证据；当前分栏标题已按用户要求简化为 `Left | Right`，去除活动侧括号，标签视觉与验证见[后续记录](tabs-and-appearance.md)。

本轮让每个 pane 显示自己的可编辑路径，并补齐分栏标签标题与标签右键菜单。最终源码已完成 **1,500 项 smoke 连续三轮**、release 构建与签名检查，并完成下述打包应用实机验证；本文分别记录固定 Dolphin 源码、实现取舍和实际验证范围。

## Dolphin 源码依据

固定版本：`5e457ee9e88aa6277fbf056cd5c32462c5318866`，本地 `upstream/dolphin`，与 [Phase 0 固定版本](../audit/00-ground-truth.md) 相同。以下路径均相对该 checkout 的 `src/`。

| 行为 | 文件与行号 | 实际语义 |
|---|---|---|
| 两个独立地址栏 | `dolphintabpage.cpp:229–239` | primary / secondary 分别连接自己的 navigator |
| 地址栏对齐 pane | `dolphinnavigatorswidgetaction.cpp:46–52, 102–114` | 创建第二个 navigator，按两个内容区的几何尺寸分配地址栏宽度 |
| 地址操作属于对应 pane | `dolphinviewcontainer.cpp:280–305` | navigator 的 URL 变化连接对应 view；激活地址栏会激活自己的 view；释放焦点回到自己的文件区 |
| 分栏标题 | `dolphintabwidget.cpp:536–560` | 固定 primary / secondary 顺序；左侧活动时 `Left \| (Right)`，右侧活动时 `(Left) \| Right`；非活动侧加括号 |
| 单 pane 标题 | `dolphinviewcontainer.cpp:581–624` | 搜索用 query title，地点可用 Places 名称，普通本地目录用最后一段，根目录用 `/` |
| 自定义标签名 | `dolphintabwidget.cpp:125–138, 500–503` | 非空 custom label 覆盖自动标题；清空恢复自动标题 |
| 自定义名随关闭恢复 | `dolphintabpage.cpp:302–327, 397–399` | custom label 写入 tab state，恢复时读取 |
| 标签右键菜单 | `dolphintabbar.cpp:175–230` | 菜单目标取鼠标位置的 tab index；七项动作见下表 |
| New Tab 目标 | `dolphintabwidget.cpp:420–425` | 使用右键 tab 的活动 view URL，新建单 pane tab；不复制两个 pane 或历史 |
| Detach Tab | `dolphintabwidget.cpp:399–417` | 向新 Dolphin 窗口传 primary URL、可选 secondary URL 和 `--split`，然后关闭原 tab；不是完整状态搬迁 |
| 关闭与恢复 | `dolphintabwidget.cpp:309–325, 351–354` | 关闭普通 tab 先保存状态；关闭最后一个 tab 关窗口；恢复创建 tab 后载入状态 |
| 单标签时栏可见性 | `dolphintabwidget.cpp:47` | 是否自动隐藏由 `alwaysShowTabBar` 设置决定 |

固定源码链接：[标签标题与动作](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/dolphintabwidget.cpp)、[标签右键菜单](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/dolphintabbar.cpp)、[地址栏绑定](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/dolphintabpage.cpp)。行号由本地固定 checkout 读取，不以未固定的网页版本代替。

菜单顺序及边界：

| 菜单项 | Dolphin | Tursora |
|---|---|---|
| New Tab | 右键 tab 的活动 URL，新建并激活单 pane | 普通 / ZIP 用活动逻辑 URL；搜索重新执行活动 pane 的 `SearchRequest`，仍为单 pane，不复制旧结果；活动侧正在准备 ZIP 时禁用 |
| Detach Tab | 一到两个 URL 在新窗口打开，再关闭原 tab | 新窗口重新建立一到两个逻辑位置，保留左右顺序、活动侧、自定义名和各自搜索请求；不迁移历史、选区、过滤、滚动、文件任务或撤销栈；任一侧正在准备 ZIP 时禁用 |
| Rename Tab | 分隔线后显示；用户确认后设置名称 | 编辑右键 tab 的自定义名；空名称恢复自动标题；不会重命名文件夹 |
| Close Other Tabs | 再一条分隔线后显示；保留目标 tab | 保留右键 tab；没有其他 tab 时禁用 |
| Close Tabs to the Left | 最左侧禁用 | 只关闭目标左边；最左侧禁用 |
| Close Tabs to the Right | 最右侧禁用 | 只关闭目标右边；最右侧禁用 |
| Close Tab | 最后一页关窗口 | 最后一页使用既有窗口关闭流程，包含原窗口任务的取消与清理 |

## Tursora 的约定与边界

- 每个 `BrowserViewController` 持有自己的 `BreadcrumbBar`，布局在搜索表单与文件区上方。两边路径同时可见，并随 pane 分隔线缩放。`TabsController.addressBar` 只是当前活动 pane 地址栏的计算属性，供 `⌘L` / `⇧⌘G` 等既有入口使用。
- 点击某侧路径、面包屑或补全先激活其所属 pane；导航只交给该 pane。另一侧路径、查询、过滤和历史不跟随改变。切 pane / tab 时结束离开位置的路径编辑并收起补全，不提交尚未确认的路径，也不把迟到回调交给新活动 pane。
- 自动标签标题保持物理左右顺序，用括号标记非活动侧；自定义名称覆盖整个 tab。完整路径保留在 tooltip 中，即使两边同名、标题被截短或已自定义，也能识别位置。ZIP 使用逻辑路径，不能泄露临时解压位置。
- 搜索标题使用 `Search: <名称条件>`；没有名称条件时显示 `Search Results`，不把搜索误标成来源目录。`TabPaneSnapshot` / `TabSnapshot` 只捕获逻辑 URL、搜索请求、活动侧和自定义名称，负责 New Tab / Detach 的重新打开语义。
- **标签栏始终显示**，包括只有一页时，保证分栏双路径标题和右键入口可以发现。这是 Tursora 的默认选择，不宣称复刻 Dolphin 的所有显示设置。
- 右键命令捕获实际 `TabPage` 身份，执行时重新确认它仍属于该窗口，避免 tab 重排 / 关闭后按旧索引操作其他页。右键本身不切换当前 tab；后台或批量关闭后，只要原活动页仍在就保留它；活动页被关闭才选相邻保留页。
- 关闭后恢复继续保留整页对象、两边历史、分栏和自定义名。Detach 按位置新建窗口，不把原 `TabPage`、进行中的任务或 undo manager 转给另一窗口；原窗口剩余页可以继续使用原任务，原窗口关闭仍按既有机制取消任务并等待清理。
- 本轮不增加会话恢复、标签固定、合并窗口、单独弹出一个 pane、通用快捷键定制或 Dolphin 的全部标签栏偏好。

## 焦点回归与修复

整合检查发现两条“活动侧正确、键盘目标错误”的路径：Detach 恢复左侧活动的分栏时，新建右 pane 留下的键盘焦点必须明确交回左侧；关闭正在编辑路径的活动 pane 时，必须把焦点交给剩余文件区。关闭非活动 pane 则保留原活动侧的路径编辑，不额外抢焦点。

真实窗口测试还暴露字段编辑器重入：AppKit 给路径框重新取得窗口共享的 `NSTextView` 时，可能同步送达旧编辑会话的结束通知。`BreadcrumbBar.beginEditing` 在取得编辑器期间加守卫，结束通知验证实际拥有的文本框对象；切换时使用不回抢焦点的结束编辑路径。`PanePathsSmokeTests` 显示其自有窗口并使之成为 key，先要求存在真实 `NSTextView` 再核对 first responder，避免两个空引用身份相等造成假通过。这些修复与最新编辑器取得回归均包含在最终连续三轮结果中。

## 验证状态

- 固定 Dolphin 源码核对已完成。
- 最终源码完整 smoke **1,500 项连续三轮通过**，三次均 exit 0、stderr 为空。覆盖列表 / 图标、两边地址输入与补全、切换时编辑清理、普通 / 搜索 / ZIP 标题、后台右键目标、菜单边界、批量关闭、恢复、Detach 与焦点回归；同一套检查包含本轮图标资源的像素 / ICNS 回归。日志为 `/private/tmp/tursora-pane-tabs-verification/final/smoke-{1,2,3}.{out,err}`。
- release 构建成功，strict codesign、Info.plist lint 和包内 ICNS 与当前资源一致性检查通过。构建日志为 `/private/tmp/tursora-pane-tabs-verification/release-final.log`。构建仍有既有 Swift warning，不将成功表述为无 warning。
- 上一轮三功能的 1,253 项检查及其历史截图保留为原阶段证据；本轮使用上述新结果。图标的系统界面实机观察另记于[图标边缘记录](app-icon-edges.md)，不由这里的资源检查或文件浏览实测推导。

## 打包应用实机检查

以下通过实际界面操作完成：

| 场景 | 观察结果 |
|---|---|
| 左右独立路径 | 左侧输入相对路径 `Design` 后只导航左侧，右侧 `Delivery` 不变；Back 返回原位置，自动标签标题与活动侧标记同步 |
| 路径编辑与补全 | 输入中途点击另一 pane 安静取消未提交路径；`Design` / `Design-Review` 候选弹窗正常出现，另一 pane 的目录不改变 |
| 后台标签右键 | 七项选项与禁用边界通过辅助功能树核对，并以真实点击验证；右键目标不误用当前标签 |
| Rename Tab | 自定义名显示于目标标签，清空后恢复自动双侧标题 |
| New Tab | 后台标签右键 New Tab 继承被点标签的活动 pane 位置；`⌘T` 也可正常新建 |
| Detach Tab | 新窗口恢复左右 URL 和活动侧；新导航历史不继承原页历史。自定义名随 Detach 保留由自动检查覆盖 |
| 窄窗与重新展开 | 窗口从 560 宽调整至 1200 宽，地址栏和标签随布局重新排列 |

已更新实际截图：[分栏与独立路径](../images/features/split-panes.png)、[路径补全](../images/features/path-navigation.png)、[标签页](../images/features/tabs.png)。截图工具在 `NSMenu` 展开期间不可用，因此标签菜单验证依靠辅助功能树与实际点击，**没有菜单展开截图**；`tabs.png` 展示的是菜单关闭后的标签界面。自动覆盖的搜索 / ZIP 与生命周期边界不另声称均已完成本轮实机操作。

产品页同步更新三张图与对应尺寸、文案。静态构建通过（5 个资源、36 个引用）；1280 × 720 桌面与 390 × 844 窄屏检查图标和新版截图，标签 / 路径图片弹窗显示比例正确，关闭后焦点返回触发链接，窄屏无横向溢出。该轮不重复声称完成旧阶段的全部浏览器回退检查。自己的测试应用和预览页已退出，原偏好、目录视图库及共享验证锁已恢复。

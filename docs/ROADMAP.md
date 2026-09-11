# Roadmap

v1（纯本地）的功能已经齐了：地址栏、标签页、分栏、两种视图与缩放预览、文件操作与撤销、过滤、分组、Get Info。
接下来按"用户最常碰到、成本最低"排。难度尺度（S ≤ 半天 / M 1–2 天 / L 3–5 天 / XL > 1 周）与每项的依据见两份差距清单：

- [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md) — 对照 Finder 菜单 nib 逐项
- [gaps/GAP-vs-DOLPHIN.md](gaps/GAP-vs-DOLPHIN.md) — 对照 Dolphin 注册的 action / 面板 / 设置

## 下一批（S，各不到半天）

Deselect All、Move Items Here（⌥⌘V）、Copy as Pathname 快捷键对齐、New Folder with Selection、Show Package Contents、Always Open With、Share、Print、Slideshow、Eject All、Go 菜单的标准文件夹快捷键、Cycle Through Windows、Services 菜单、Finder 别名解析、反选、在终端中打开。

## 之后（M）

批量重命名、Compress、Make Alias / Show Original、Recent Folders、右侧预览栏（复用 Get Info 的 FileInfo）、Customize Toolbar、Toolbar / Path Bar / Status Bar / Tab Bar 开关、Show All Tabs、Move Tab to New Window / Merge、spring-loaded folders、扩展名显示与改扩展名警告、Paste Exactly、Show Clipboard、Add to Dock、快捷键与 Finder 对齐（可做成开关）、会话恢复、最近关闭的标签列表、附加信息列、文件夹项目数 / 递归大小列、操作进度与取消。

## 大件（L）

Column 视图、Gallery 视图、Show View Options（每目录视图属性）、设置窗口、图标自由摆放、废纸篓视图（需要 Full Disk Access）、Quick Actions、中文本地化、Connect to Server、Spotlight 搜索（`NSMetadataQuery`）、Folders 面板（目录树）、内嵌终端。

## 不做 / 等公开 API

Customize Folder（私有存储）、Smart Folders（依赖搜索且结果不确定）、FinderSync 角标（只有 iCloud 公开）、桌面、选择模式。

## 已知的小差距

- 列表与图标视图的 Return/Enter 分支 `case 36, 76 where plain` 产生编译警告：`plain` 仅限制 Enter；带修饰键的 Return 路径需另行补回归检查（2026-09-12 构建时发现）。
- 浏览 pane 在**外部**改名后选择会丢（Info 窗口能按 inode 跟上，pane 还不能）。
- 文件夹大小在 Info 窗口里不随内容变化实时更新（避免 FSEvents 风暴）。
- 分组的 Size 桶边界、Kind 组顺序仍是推断。

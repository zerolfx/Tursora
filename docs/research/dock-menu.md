# Dock 右键菜单（2026-09-12）

用户要求 Tursora 的 Dock 图标像 Finder 一样提供常用动作。本轮增加应用自定义菜单：`New Window`，分隔线，`Downloads`、`Applications`。每个动作都打开新的 Tursora 窗口，不复用或导航已有 pane；New Window 沿用应用的 Home 起点。常用目录入口是 Tursora 的取舍，不声称完全复制 Finder 的实际 Dock 菜单项目或顺序。

## 本机 Finder 文案证据

只读核对本机 Finder 资源：

```sh
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
```

| 本机资源 | 提取结果 | 本轮使用范围 |
|---|---|---|
| `LocalizableMerged.strings` | `N80 = New Finder Window`、`FR12 = New Window` | Tursora 沿用自己 File 菜单的 `New Window`，不用 Finder 的应用名称 |
| `MenuBar.nib` | `300850.title` 附近的 `Downloads`、`cmdGoToDownloads:` | 常用目录英文标签 |
| `MenuBar.nib` | `258.title` 附近的 `Applications`、`cmdGoToApplications:` | 常用目录英文标签 |
| `MenuBar.nib` / `LocalizableMerged.strings` | `Home`、`cmdGoHome:`；`FF21 = Home` | 核对既有 New Window 的 Home 语义；不再添加重复 Home 项 |

这些资源能核对文案和命令名称，不能证明项目在 Finder 的 Dock 菜单中出现，不能推导当前 Finder Dock 菜单的层级或顺序。本轮未用资源字符串冒充 Finder Dock 的实际点击观察。

## AppKit 依据与实现选择

[Apple 的 `applicationDockMenu(_:)` 文档](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationdockmenu%28_%3A%29)允许应用代理返回动态 `NSMenu`，无须为本项目增加 nib。文档说明 Dock 使用菜单项的 target / action 向应用分发动作，发送者可能为空。因此每项使用不同 selector 和明确的 `AppDelegate` target，不从 `sender`、菜单索引或 `representedObject` 推导目的地；其他窗口获得焦点也不会改变动作目标。

[Apple 的 Dock menus 指南](https://developer.apple.com/design/human-interface-guidelines/dock-menus)建议提供简短、常用、在应用未处于前台或没有窗口时仍有用的动作，并在其他界面保留相应入口。Tursora 的 New Window 已存在于 File 菜单，两个目录也可通过地址栏打开。这里仅返回三项自定义动作；标准 Dock 项目由 macOS 管理，不另造窗口列表、近期目录、标签或 Trash 功能。

- `DockMenuDirectories.system` 在模型层通过 `FileManager` 的标准目录 API 解析 Downloads（user domain）和 Applications（local domain），Home 使用现有 `FileProvider.homeURL`。不硬编码用户目录，不创建缺失目录；系统未返回目的地时对应项禁用，直接分发该动作也不执行。
- `DockMenu.make` 仅构建菜单，无文件系统读写；`AppDelegate.applicationDockMenu` 返回菜单。固定动作调用既有 `newWindow(at:)`，保留窗口注册、关闭清理与层叠行为，再激活应用。
- 每次动作都创建独立窗口与初始 pane，不改变已有分栏、活动标签、路径、过滤、分组、选区、搜索请求或撤销栈。不增加新的文件操作。
- 应用保留原有的 Dock 重开与拖入路径处理；本轮只补充右键菜单。

## 验证状态

`DockMenuSmokeTests.swift` 接入完整 smoke 链，使用临时目录和注入的 provider / 标准目录配置，覆盖目的地、目录不可用、菜单顺序 / 分隔 / 显式动作，以及无窗口时的空 sender 分发。真实窗口路径检查还覆盖两种文件视图下已有分栏、后台标签、过滤、分组与选区保持，测试仅关闭自己创建的窗口。

最终源码（含 Dock 与后续 IME 修复）的完整 smoke **连续三轮通过，每轮 2,123 项**，均 exit 0、stderr 为空。计数已按三份最终日志的 `ok` 行复核，修正原记录少计 16 项的问题；源码未变。`0.1.0` 发布包构建、strict codesign、plist、arm64 架构与包内 ICNS 一致性均通过；独立副本的窗口及目录导航已目视检查。

**实机边界：**界面工具通过 bundle ID、Dock.app 路径及先聚焦 Dock 三种方式均无法读取系统 Dock，因此没有完成真实 Dock 右键点击或由 Dock 激活应用的观察。菜单内容、空 sender 分发、新窗口目录和既有 pane 状态保持由上述自动化覆盖，不能改写为 Dock 实机验证通过。此前 2,024 项三轮与界面截图属于加入 Dock 前的阶段。

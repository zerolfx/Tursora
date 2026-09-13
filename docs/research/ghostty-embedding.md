# Ghostty 嵌入评估（2026-09-13）

用户询问嵌入 Ghostty 是否效果更好。本轮只读官方资料与源码，未构建、接入或跑性能对照；0.2.0 继续使用 SwiftTerm 1.15.0。建议在发布后独立做原型，而不是由架构名称推断实际效果。

## 当前官方接口

GitHub API 核实 Ghostty main 为 [`5252b193cfd52b4bcd868135e21e4563f2f326ec`](https://github.com/ghostty-org/ghostty/tree/5252b193cfd52b4bcd868135e21e4563f2f326ec)，提交时间 2026-09-13 03:49:39 UTC。以下采用该提交；官网关于初次发布和 2025 年的 roadmap 不能代替当前 API 状态。

| 层级 | 已有能力与边界 |
|---|---|
| Ghostty 独立应用 | macOS 的 Swift / AppKit / SwiftUI 外壳和 Metal 渲染，支持现代终端协议、字体处理与原生应用功能。[官方介绍](https://ghostty.org/docs/about)、[项目说明](https://github.com/ghostty-org/ghostty#native-platform-experiences) |
| `libghostty-vt` | C / Zig 接口已可用，包含终端解析 / 状态、输入编码、滚动与重排、供自定义渲染器使用的状态。当前头文件仍明确 API 未稳定、预期会变化。[VT 头文件](https://github.com/ghostty-org/ghostty/blob/5252b193cfd52b4bcd868135e21e4563f2f326ec/include/ghostty/vt.h) |
| 完整嵌入接口 | `include/ghostty.h` 接受 macOS `NSView`，提供 surface 创建、输入 / IME、剪贴板、绘制和生命周期回调；但当前明确名为 `libghostty-internal`，为自身 macOS 应用定制，未设计为外部通用接口。[内部接口](https://github.com/ghostty-org/ghostty/blob/5252b193cfd52b4bcd868135e21e4563f2f326ec/include/ghostty.h) |

官方 [Ghostling](https://github.com/ghostty-org/ghostling#what-is-libghostty) 说明 VT 库不包含绘制 / 窗口代码，示例自行使用 Raylib。已有 [Swift XCFramework 示例](https://github.com/ghostty-org/ghostty/tree/5252b193cfd52b4bcd868135e21e4563f2f326ec/example/swift-vt-xcframework)，但只展示创建 VT、写控制序列并转成纯文本，不能当作现成完整 Metal 终端视图。

Ghostty 自己的 [SurfaceView_AppKit.swift](https://github.com/ghostty-org/ghostty/blob/5252b193cfd52b4bcd868135e21e4563f2f326ec/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift) 实现输入事件、`NSTextInputClient`、marked text 与 surface 调用。由此推断 Tursora 若走内部完整接口，仍需维护宿主焦点、输入法、快捷键、剪贴板、视图尺寸与生命周期适配，并引入固定 Zig / 库构建；不是仅改一项 SPM 依赖。

## 与当前实现的关系

Tursora 当前使用 SwiftTerm 的 AppKit `LocalProcessTerminalView` 和真实 PTY，默认 CoreGraphics 路径。固定 1.15.0 本身也提供实验 Metal 路径，源码标明仍在演进；本项目未启用。[SwiftTerm 固定源码](https://github.com/migueldeicaza/SwiftTerm/blob/dd2fb8ac5b861e7bf617c872895e338f38165648/Sources/SwiftTerm/Mac/MacTerminalView.swift)

Ghostty 的 GPU 与协议核心值得用于大量输出 / 复杂 TUI 对照，但本次没有证据证明在 Tursora 的真实任务中更快或更省资源。右下角状态、隐藏保留、关闭确认、文件浏览与窗口恢复均属应用集成工作，不会因替换解析 / 渲染后端自动完成。

Ghostty 本体为 [MIT 许可](https://github.com/ghostty-org/ghostty/blob/5252b193cfd52b4bcd868135e21e4563f2f326ec/LICENSE)，与项目免费开源方向相容；嵌入分发须保留其许可及纳入的依赖声明。Ghostty 独立应用的签名不赋予 Tursora Developer ID 或公证状态。

## 后续建议

固定上游提交做隔离原型，比较中文输入 / 组合文字、字体与 Unicode、Neovim / agent TUI、滚动与重绘、复制粘贴、CPU / 内存以及 shell 生命周期。使用相同优化构建、字体、窗口尺寸和输入负载；同时以当前 SwiftTerm 的默认与实验 Metal 为对照。确认收益及维护成本后再决定是否替换，结果未完成前不写性能宣传。

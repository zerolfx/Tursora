# 文本文件图标缩略图（2026-09-12）

用户指出的是文件图标内部的文字，不是 Quick Look 或 Get Info 的 Preview。此前所有类型使用系统 Quick Look 缩略图；文本页缩小后文字难以辨认，失败时则保留类型图标。本轮为纯文本增加专用开头片段渲染，其他类型继续使用原有后端。

## Finder 与 Dolphin 依据

Finder 的 `ViewOptionsWindow.nib` 中可提取 `Icon size`、`Text size`、`Show icon preview` 及 `iconViewShowIconPreview` 绑定；这里的 Text size 指文件名标签，不意味着能单独调图标内容字号。本轮在本机 Finder 查看同一 `Feedback.md`，观察到白纸上的微小文字；没有量取准确纸面点尺寸，也没有证明 Finder 私有缩略图实现使用与 Tursora 相同的请求参数。

Dolphin 的预览请求来自本地固定源码 `5e457ee9e88aa6277fbf056cd5c32462c5318866` 的 `src/kitemviews/kfileitemmodelrolesupdater.cpp:977–1044`，请求标准预览并处理屏幕倍率。文本生成器实际属于 KIO Extras：[固定 textcreator.cpp](https://github.com/KDE/kio-extras/blob/6ddac4968aad8ca39862b0420bcc529cc480fe60/thumbnail/textcreator.cpp)。它绘制文件开头文字，纸面约 3:4，等宽字号按可用高度计算并限制在 7–10 个逻辑像素，裁切超出文字；部分构建可语法高亮。Tursora 参考其保留字号、显示片段的方式，采用 CoreText 实现，不声称完全复刻 KDE 的字体、像素或高亮。

Quick Look 请求里的 `.thumbnail` 是内容缩略图，不是通用图标；`iconMode` 影响图标装饰，不能当作提高文字字号的开关。本轮没有用该开关解释或修复可读性问题。

## 当前行为与边界

- 普通可读文件中，UTType 为 plainText、sourceCode、JSON、XML，或扩展名为 Markdown、YAML、TOML、INI、log 时，优先走文本渲染。富文本、其他类型和不支持的编码继续走 Quick Look。
- 模型层后台非阻塞打开并通过文件描述符确认普通文件，最多读取 64 KiB；严格解码 UTF-8 或带 BOM 的 UTF-16 LE / BE，仅在文件确实被截断时修补不完整末尾字符。拒绝二进制控制字符，空内容回退原后端。视图不读取文件。
- 最多排版 8,192 字符，使用 3:4 浅色纸面、深色文字与 7–10 pt Menlo / CoreText 字体回退。纸张是文档内容，在深色主题也保持浅色。按目标屏幕倍率生成实际像素；没有语法高亮。
- 列表和图标视图保持 ≥32 pt 的原预览阈值。小图标主要帮助辨识内容；需要阅读更多文字时放大或打开 Quick Look。放大显示更多文字，而非把整份长文缩成一页。
- 缓存区分路径、点尺寸、屏幕倍率、修改时间和文件大小。重载、缩放、关闭预览和单元复用都使旧请求失效；窗口的屏幕倍率改变时，两种视图重新请求当前倍率的预览，并拒绝旧倍率的迟到回调。关闭预览时倍率变化不启动请求。ZIP 内容在读取和交付时重新验证可读映射。

## 验证状态

本轮 Dock 与后续输入法调整之前的截图阶段，组合源码完整 smoke **连续三轮通过，每轮 2,024 项**，三次均 exit 0、stderr 为空；这是包含文本缩略图回归的组合套件总数。后续最终源码的结果以 [HANDOFF](../HANDOFF.md) 为准。

`TextThumbnailSmokeTests.swift` 覆盖 UTF-8 / UTF-16、CJK 与代理对、读取截断和非法编码、64 KiB 读取 / 8,192 字符排版上限、空白与二进制内容回退、FIFO / 非普通文件拒绝，以及普通文件符号链接。渲染检查验证真实文字产生不同像素、逻辑尺寸与 1× / 2× 栅格尺寸；不以固定字体像素图作为跨系统金样。

两种实际视图的回调测试覆盖缩放、关闭预览、单元复用与屏幕倍率变化：新请求可交付，旧尺寸或旧倍率回调不能覆盖；挂入窗口后的倍率更新会触发重载，相同倍率不重复重载，关闭预览时不发请求。Provider 集成检查包含异步合并、主线程交付与缓存命中。

上述截图阶段 release 构建通过，日志为 `/private/tmp/tursora-tabs-appearance-verification/release-final.log`；根任务确认 strict codesign、Info.plist lint 和包内图标一致性检查通过。打包应用在系统暗色及仅限该进程的浅色外观下实际显示了 `Brief.md`、`Components.swift` 的开头片段，并检查预览关闭 / 重新打开。图标缩放滑块从档位 2 调到 4；按 `ZoomLevel.iconSizes` 对应名义图标尺寸 64→96 pt，不是 128 pt，也不是对纸面实际尺寸的像素测量。见[文本片段图标](../images/features/text-preview.png)、[暗色分栏](../images/features/split-panes.png)及[浅色分栏](../images/features/split-panes-light.png)。

同一组中的 `Palette.css` 在该实测档位仍显示 Firefox 类型图标，不能据此宣称全部源码格式已显示文字缩略图。真实多显示器移动没有测试，倍率变化仍只有上述自动化栅格与生命周期证据。上述原生检查来自 2,024 项阶段发布包，后续 Dock / 输入法调整后的最终源码验证另行记录；图片透明角处理没有改变窗口内部内容。

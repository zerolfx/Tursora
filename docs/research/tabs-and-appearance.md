# 标签栏与亮暗外观

## Apple 参考与证据范围

本轮以 **Safari 的独立标签栏**为主要视觉参考。2026-09-12 在本机 Safari 打开两个临时 Apple 页面，与原起始页形成三标签，实际查看深色界面，再关闭临时标签恢复原页面。观察到：标签在地址工具栏下方；后台标签共用连续底条；当前标签为柔和的胶囊形亮面；标题居中；多标签等分可用宽度。Safari 的新增入口位于上方工具栏，Tursora 则放在标签栏右端，便于文件工作流发现；没有宣称完全复制 Safari 布局或网页着色。

![Safari 深色标签栏实机参考](../images/research/safari-tabs-dark.jpg)

Finder 是辅助对照：也支持 `⌘T`，新建第二个标签即可显示标签栏。本机深色实测同样有连续底条、较亮的当前标签和居中标题；关闭临时标签后恢复原窗口。没有取得这些应用私有控件的尺寸或材质参数。

Apple 官方文档提供另外两种应用的参考：

- [Safari 标签设置](https://support.apple.com/en-au/guide/safari/ibrw1045/mac)：Separate 将标签置于工具栏下方；Compact 将活动标签变成地址搜索框。Tursora 每个 pane 有独立地址栏，因此采用前者的分层方式。
- [Safari 标签整理](https://support.apple.com/en-au/guide/safari/ibrwbb6e21e4/mac)：标签超过可见宽度时可横向滑动。Tursora 保留可读宽度，溢出后滚动，并提供文字菜单入口。
- [Safari 标签关闭](https://support.apple.com/en-gb/guide/safari/ibrwd0cea393/mac)及[系统窗口标签](https://support.apple.com/en-gb/guide/mac-help/mchla4695cce/mac)：关闭控件在悬停后出现，减少常驻操作噪声。
- [Terminal 标签设置](https://support.apple.com/en-asia/guide/terminal/trmltab/mac)：标题可表达目录、路径和进程，也可自定义。Tursora 延续目录 / 搜索 / 分栏标题与完整路径 tooltip。
- [Apple 外观适配](https://developer.apple.com/documentation/uikit/supporting-dark-mode-in-your-interface)和[AppKit 语义颜色](https://developer.apple.com/documentation/appkit/ui-element-colors)：用语义颜色和模板图像适配外观；转换成 CGColor 后需在更新周期重新解析。前一文档虽位于 UIKit URL，也明确包含 AppKit / NSView 的说明。

Safari 有上述深色实机观察；Terminal 本轮参考为官方文档。均未声称量取它们的精确像素参数。新增圆角、间距及配色混合比例是 Tursora 的设计选择。

Finder 文案证据通过只读资源提取核对：

```sh
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
```

前者包含 `New Tab`、`Show All Tabs`、`Hide Tab Bar`、`New Window as Tab`；后者 `FR13 = New Tab`、`FV17 = Open in New Tab`、`FV18 = Open in New Tab and Close`、`N151.1 = Open in New Tab`、`N151.2 = Open in New Tabs`。本轮不改 Dolphin 七项右键文案，不把文字溢出菜单称为 Finder 的缩略图总览。

## 产品介绍边界

标签页本身是 Finder 和 Safari 已有的通用能力，不再作为 README / 产品页的独立卖点。技术文档保留快捷键、菜单和行为说明；产品介绍聚焦双分栏、每 pane 独立可编辑路径等工作流。

## 实现约定

标签栏采用中性底条和柔和的选中面；标题两侧预留相同空间，关闭按钮悬停显示且不挤动文字。新增按钮固定在右侧；标签过多时横向滚动，选择标签会将它带入可见区域，溢出菜单列出所有标题。

应用默认跟随系统亮 / 暗外观，不写入全局外观偏好。标签绘制实时解析语义颜色；补全面板、活动 pane 指示线及传输任务卡片也在外观改变时刷新 layer 颜色。分栏标题固定为 `Left | Right`，不为非活动侧添加括号；活动侧由 pane 指示线表达。过滤、分组、拖拽与七项标签右键动作保留。文件区和侧栏移除所有 Reveal in Finder 入口；搜索结果既有的 Reveal in Enclosing Folder 仍在 Tursora 内导航。

## 验证状态

本轮 Dock 与后续输入法调整之前的截图阶段，组合源码完整 smoke **连续三轮通过，每轮 2,024 项**，三次均 exit 0、stderr 为空。该数量是包含本专题的组合套件总数；之前 1,500 项三轮结果仅代表上一阶段，后续最终源码的结果以 [HANDOFF](../HANDOFF.md) 为准。

`TabAppearanceSmokeTests.swift` 覆盖窄宽窗口几何、居中标题与关闭目标、悬停不挤动文字、溢出滚动和当前标签可见性、过期菜单目标，以及滚动后的点击、分栏拖放、重排和重载取消。亮 / 暗与活动 / 非活动配色检查包含文字对比度、实际绘制像素及既有文字控件更新。

`AppearanceSmokeTests.swift` 在实际挂入窗口的视图上验证亮 → 暗 → 亮的 layer 重绘，覆盖补全面板打开期间与隐藏后重开、活动 pane 指示线和传输卡片边框；不依赖只检查源码中的颜色常量。

上述截图阶段已生成 release 包，构建日志为 `/private/tmp/tursora-tabs-appearance-verification/release-final.log`；根任务确认 strict codesign、Info.plist lint 及包内图标资源一致性检查通过。随后在真实系统暗色和仅作用于应用进程的浅色外观下驱动打包应用，没有修改系统外观偏好。检查从初始 560 px 宽窗口到 1200×720 窗口，实见选中 / 未选中标签的居中标题与中性底条、`Left | Right` 分栏标题、活动 pane 指示线，以及暗色路径补全面板。当前实机截图为[暗色分栏](../images/features/split-panes.png)、[浅色分栏](../images/features/split-panes-light.png)、[标签栏](../images/features/tabs.png)和[路径编辑与补全](../images/features/path-navigation.png)。截图角区透明处理及原生内部像素核对见[透明截图记录](screenshot-transparency.md)。

侧栏实际右键菜单的辅助功能树包含 `Open`、`Open in New Tab`、`Open in Other Pane`、`Remove from Favourites`、`Reset Favourites`，没有 Reveal in Finder。当前[侧栏截图](../images/features/favorites.png)为菜单关闭状态，不能拿它证明菜单内容。以上均为 2,024 项阶段发布包的原生检查，不替代后续 Dock / 输入法调整后的最终构建与验证，也不宣称所有溢出、拖放和菜单边界均重做了实机测试。

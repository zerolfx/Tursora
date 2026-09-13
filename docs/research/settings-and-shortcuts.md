# 设置窗口、扩展名显示与快捷键

> 下文保留 2026-09-12 初版与验证记录；2026-09-13 起两项功能默认启用，开关保留，新增取消 / 重试及终端状态打磨见[后续记录](default-features-polish.md)。

2026-09-12。新增设置入口来自用户明确要求；这些是 Tursora 的应用级设置，独立于每个 pane 的分组、隐藏文件与过滤状态。

## 数据与默认值

| 设置 | 默认 | 存储/API |
|---|---|---|
| 文件名扩展名显示 | 开 | `AppPreferences.showFileExtensions` |
| Filter by Name 快捷键 | ⌘F | `AppPreferences.filterShortcut` |
| 实验性终端面板 | 关 | `AppPreferences.experimentalTerminalEnabled` |
| 实验性 ZIP 浏览 | 关 | `AppPreferences.experimentalZIPBrowsingEnabled` |

`AppPreferences.Store` 使用 UserDefaults，实际变更后发布 `.tursoraPreferencesChanged`。设置窗口的勾选立即保存；消费者收到通知更新界面。扩展名开关只影响显示，不修改文件名或文件系统的隐藏扩展名标志。启用终端开关只开放入口，不启动 shell。ZIP 开关启用后，普通 Open 在当前 pane 浏览归档；关闭后，普通目录中新打开 ZIP 恢复解压，已准备的归档页与历史仍可只读导航和补全，不突然跳转或清除副本。设置说明明确写明 current pane；完整行为见 [归档浏览研究](archive-browsing.md)。

## 快捷键录制

- 保留现有名称过滤含义，因此设置项称 `Filter by Name`，没有暗示全文索引搜索。
- 按钮进入录制后捕获 key-down；先于菜单派发拦截，所以录制 ⌘Q 会提示冲突而非退出应用。Escape、关闭设置窗口或窗口失去焦点结束录制。
- 允许单个字母、数字或支持的标点；必须含 Command 或 Control，可叠加 Option/Shift。单独 Option 会用于输入重音字符，因此不能抢占；Tab、空格、回车、方向键与功能键不提供为此项的绑定。
- 通过 NSEvent 按当前键盘布局获取未修饰字符，修饰键分开保存；显示采用 ⌃⌥⇧⌘ 顺序。
- 静态保留现有菜单及窗口 monitor 的快捷键，包含数字标签切换、⌘K、⌘逗号、⌃⌘S 等；保存时还检查实际主菜单，忽略 Filter 自己的条目。
- 系统常见保留组合包括切换窗口、Help、锁屏等；不声称能检测用户在系统设置或第三方工具中自定义的全部全局快捷键。F4 不在允许字符范围，留给实验性终端。
- 无效输入在设置窗口内提示，不覆盖已保存的值。Reset 恢复 ⌘F；磁盘里无效或已冲突的绑定读取时退回默认值。

## Finder 对照范围

核验命令：

```bash
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/PreferencesWindow.nib
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
```

本机 Finder `MenuBar.nib` 仍保留 `Preferences` / `cmdPreferences:` / `gear`，`PreferencesWindow.nib` 的窗口标题则为 `Finder Settings`，并有 `General`、`Advanced` 和 `Show all filename extensions`。Tursora 采用这个扩展名开关文字；General / Keyboard / Experimental 的具体布局是自身设计，不声称复刻 Finder 设置窗口。此功能不引入 Tags。

## 验证边界

`SettingsSmokeTests.run()` 使用独立临时 UserDefaults domain 和 NotificationCenter，覆盖默认值、持久化、通知、冲突/无效绑定、重置、设置控件写入和刷新、录制事件与 Escape，以及窗口内布局。不打开设置窗口、不触发外部程序、终端或真实 ZIP 浏览。主流程的 `SmokeTest.preferencesIntegration` 另覆盖实际菜单绑定、实验开关入口、两种文件视图的扩展名显示与重命名真名；后续完整快捷键目录及整合验证分别见[快捷键研究](custom-shortcuts.md)与[定制功能整合记录](customization-integration.md)。

同 pane ZIP 与设置的实际操作、示例截图和偏好恢复记录见[实机记录](computer-use-2026-09-12-inline-zip.md)。默认值按本文的数据表定义，不从演示截图或某位用户的当前偏好推断。

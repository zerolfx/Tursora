# Finder 操作与分享菜单对照（2026-09-12）

当前系统 Finder 资源：

```bash
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
```

输出中直接核验的文字：New Folder、Open、Get Info、Rename、Duplicate、Copy、Paste、Move to Trash、Share。Share 相邻的图标资源名为 `square.and.arrow.up`，action 为 `cmdShare:`。其余现有操作图标见 [原始菜单图标记录](finder-menu-icons.md)。

Tursora 的工具栏 More 菜单聚合已实现的文件操作，按活动 pane 的选择验证；这是适合当前功能范围的整理，不声称复刻 Finder 更多菜单的全部项目或顺序。三点按钮使用 `ellipsis.circle`（图标选型，未从 Finder nib 证实）。Share 使用 `NSSharingServicePickerToolbarItem`，从活动 pane 提供选中的 URL；无选择时禁用。测试只验证传入对象和启用状态，不发送文件。

用户明确的产品边界：不支持任何 Tags 功能，不支持 Import from iPhone。已删除旧的 Tags 分组及文件标签读取；不改动磁盘上用户已有标签。系统分享选择器列出的第三方服务由系统与已安装应用决定。

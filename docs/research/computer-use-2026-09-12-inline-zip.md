# 当前 pane ZIP 与分栏界面实机检查（2026-09-12）

本轮通过 computer use 操作实际打包的 `app/build/Tursora.app`，前半轮使用 bundle build 5，服务器表单修复后重新构建 debug / release，并以修正版复测该表单、替换截图。使用演示项目和深色外观；记录只包含实际操作结果，不以截图文件存在、AX 树或 smoke 代替视觉检查。早期独立 ZIP 窗口的结果保留在[上一份记录](computer-use-2026-09-12.md)，不作为本轮同 pane 流程的证据。

## 已观察的界面与交互

| 检查 | 实际观察 | 已保存截图 |
|---|---|---|
| 工具栏分栏 | 分栏按钮可操作，当前界面显示并排 pane | [split-panes.jpg](../images/features/split-panes.jpg) |
| Favorites 的另一 pane | 右键 Open in Other Pane 创建分栏，原 pane 保留原目录 | [favorites.png](../images/features/favorites.png) |
| Favorites 的新标签 | Open in New Tab 创建第三个标签，进入右键地点 | 同上；菜单截图本身不证明后续导航 |
| 窄分栏名称列 | 名称列最小宽度改为 180 pt 后，窄 pane 的文件名可读；对应 smoke 检查已纳入最终连续三轮通过 | [split-panes.jpg](../images/features/split-panes.jpg) |
| 地址补全 | 输入路径时真实弹窗显示 Design / DesignArchive 候选 | [path-navigation.jpg](../images/features/path-navigation.jpg) |
| 名称过滤 | `*.png` 只过滤活动 pane，另一 pane 内容保留 | [name-filter.jpg](../images/features/name-filter.jpg) |
| 列表 / 图标与分组 | 两种视图和 Kind 分组已操作并观察 | [views-and-groups.jpg](../images/features/views-and-groups.jpg) |
| Quick Look | 文本文件可显示预览内容 | [quick-look.jpg](../images/features/quick-look.jpg) |
| 系统分享 | Share picker 实际出现；没有执行发送 | [share.jpg](../images/features/share.jpg) |
| 设置示例状态 | 截图中两个实验开关均关闭；这不是本轮结束时用户的原始 ZIP 偏好 | [settings.jpg](../images/features/settings.jpg) |
| ZIP 进入与导航 | ⌘↓ 在当前 pane 进入 ZIP 根，保留原始根结构；双击 Documents 进入内部目录。Up 回根并选中 Documents，再 Up 退出 ZIP 并选中原 ZIP；Back / Forward 无路径错误 | [zip-browsing.jpg](../images/features/zip-browsing.jpg) |
| ZIP 只读菜单 | More 中 New Folder、Get Info、Rename、Duplicate、Compress、Extract、Paste、Trash 均禁用 | 同上 |
| ZIP 文件打开 | Open 将 ReleaseNotes 文本交给 TextEdit，显示演示内容及私有临时快照 URL | 临时路径只在外部编辑器中出现，不作为 pane 的导航路径 |
| ZIP 复制与撤销 | ⇧⌘C 将 167 字节的文件复制到普通 Delivery pane，⌘Z 移除复制产物 | 操作结果已核对；截图不代替字节结果 |
| 文件冲突 | Keep Both 创建 153 字节的 README 编号副本，原有 63 字节文件保留；⌘Z 移除副本 | [file-operations.jpg](../images/features/file-operations.jpg) |
| Compress / Extract 展示 | 相关界面截图已保存并检查；早期版本的完整压缩 / 解压往返操作保留在旧记录 | [compress-extract.png](../images/features/compress-extract.png) |
| 终端 | F4 打开 zsh，pwd / ls 显示同一演示项目；结束后关闭终端并恢复实验关闭 | [terminal.jpg](../images/features/terminal.jpg) |
| 修复后的服务器表单 | 有效 SMB 地址按 Tab 不启动连接；Cancel 关闭，重新打开仍可编辑且无 spinner；ftp 地址按 Return 显示协议错误，改为有效地址清除错误；Escape 关闭 | [connect-server.jpg](../images/features/connect-server.jpg)，已替换为最终修正版 |

## 本轮发现与处理状态

- 新建 pane 的延迟初始导航可能覆盖随后明确选中的地点。实现已增加 `navigationGeneration == 0` 条件；与窗口、侧栏和标签相关的回归已随最终 smoke 连续通过。
- 窄分栏的名称列被其他列挤窄；设置名称列最小宽度为 180 pt，build 5 已观察到名称可读。自动化几何检查已随最终 smoke 连续通过。
- 服务器地址框原先会在失焦时执行 action，点击 Cancel 也可能启动挂载。现已限制为明确提交，并完成上表所列修正版 CUA：Tab / Cancel 不连接，重新打开状态正常，Return 触发协议校验，编辑可清错，Escape 关闭。新增专门回归检查已通过最终三轮；本次没有验证真实服务器认证或挂载成功。
- ZIP 临时快照别名检查曾暴露路径重映射问题，已修复；相应回归纳入最终连续三轮通过，失败运行不计入通过轮次。

## 截图方法

使用原生 `screencapture -x -o -l<windowID>` 捕获目标窗口，可保存相关菜单状态。尝试按屏幕矩形 `-R` 截图时曾误取背景应用，错误图片已替换；后续按窗口 ID 捕获并核对内容。CUA 返回的 11 张图片实际为 JPEG，已按真实格式改用 `.jpg` 后缀；Favorites 与 Compress / Extract 的两张原生捕获保留 `.png`，没有修改图片像素。截图维护规则见 [images/README.md](../images/README.md)。

## 截图、构建与最终自动化状态

README 全部 13 组截图均已保存并逐一检查，包括压缩 / 解压、文件操作、ZIP、终端和服务器；服务器截图已替换为最终修正版。演示图展示相关界面，不将菜单截图扩展为未执行过的文件操作或远程连接证据。

最终 debug 构建通过；包含最新路径重映射修复的 release build 5 已重建并通过 strict codesign 检查。最终 **739 项 smoke 连续三轮通过**，三个进程均以 0 退出，stderr 均为空。日志为 `/tmp/tursora-alias-fixed-smoke.log`、`/tmp/tursora-final-smoke-2.log`、`/tmp/tursora-final-smoke-3.log`。最终测试包含名称列、快照别名和服务器表单回归；此前别名断言失败已解决，旧版本的一次通过和失败运行均不计入这三轮。

## 收尾与边界

已恢复本次测试前的用户偏好：显示扩展名 = 开、过滤快捷键 = ⌘F、终端实验 = 关、ZIP 浏览实验 = 开。ZIP 开启是用户原有选择，不改变该功能新安装默认关闭的规格。演示 Favorite 已移除并核对。

真实服务器认证、挂载、读写、掉线和 Eject 未验证。终端关闭所属浏览窗口时的进程回收、ZIP 拖出手势及 ZIP 内 Quick Look / Share 的专项 CUA、浅色模式和全部屏幕尺寸仍未在本轮逐项覆盖；对应模型 / 集成检查不能替代这些视觉或服务端验证。历史终端中断、Restart 与关闭实验的操作见[此前记录](computer-use-2026-09-12.md)。

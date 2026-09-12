# 新功能实机检查（2026-09-12）

环境：macOS 26.3（25D125），深色模式；通过 computer use 操作 `app/build/Tursora.app`。初始检查版本为 `cba1ccb` 对应的 0.1.0（2）。本记录补充自动化 smoke，不把 UI 树或模型检查当成视觉验证。

文件操作全部使用 `/tmp/tursora-visual-check` 内本轮创建的样本：`Sample Files/Welcome.txt`、`Sample Files/Notes/Checklist.txt` 与保留顶层目录的 `Sample.zip`。没有对用户文件做改名或归档操作。

## 已完成的操作

| 检查 | 实际结果 |
|---|---|
| 设置窗口 | General、Keyboard、Experimental 各区域文字和控件完整，无重叠；初始两项实验功能均关闭 |
| 过滤快捷键 | 录制 ⌘Q 被冲突校验拦截，应用没有退出；录制 ⇧⌘F 后能聚焦过滤框，Reset 恢复 ⌘F |
| 文件名过滤 | `*.zip` 只保留 ZIP，计数正确；Escape 清空，没有多余的 Filter / 文件夹范围行 |
| 隐藏扩展名 | `Sample.zip` 显示为 `Sample`，文件夹名不变；恢复显示后立即更新 |
| 取消改名 | List 与 Icons 的编辑框均包含完整 `Sample.zip`，选中 basename；输入 `MustNotRename` 再 Escape 均恢复原名，磁盘检查无错误改名产物 |
| 窗口布局 | 侧栏与内容区域共用平直边界；Home 图标与其他项目大小协调；标题栏无重复路径；折叠 / 展开侧栏时左上角按钮位置稳定 |
| Favorites 与分组 | 点击 Home 后 Group 菜单仍能打开；Kind 分组可用，图标视图实际显示 Folders / Other 标题 |
| 终端 | F4 显示并正确渲染 zsh；`pwd` 正确；`sleep 30` 可用 Ctrl-C 中断 |
| 终端与目录切换 | 未提交的 `printf terminal-input-kept` 在浏览器导航后保持不变；Restart in Current Folder 在含空格的路径启动新会话，`pwd` 正确 |
| 终端生命周期 | 前台命令运行时 Restart 显示确认，Cancel 可取消；F4 隐藏重开获得新会话；禁用设置后面板消失 |
| ZIP 浏览 | 独立只读窗口保留顶层 `Sample Files`，可进入 Notes，Back / Up 可用，根目录按钮禁用；底部临时副本说明完整换行 |
| 打开 ZIP 内文件 | Return 打开 Welcome.txt，TextEdit 显示预期内容及应用临时目录路径；关闭 ZIP 浏览窗口后文档仍可读；测试结束关闭该文档，没有编辑 |
| More 菜单与分享 | 操作随选择启用，菜单没有文件 Tags 或 Import from iPhone；原生分享弹窗显示选中文件名 / 类型和系统服务，未发送 |
| 压缩与解压 | Compress 生成 `Sample Files.zip`；显式 Extract 在浏览实验开启时仍可用，同名目录保留并生成 `Sample Files 2`；撤销移除产物，重做恢复 |
| 默认 ZIP 行为 | 关闭 ZIP 浏览实验后，普通 Open 恢复解压，生成并选中 `Sample Files 3` |
| 归档内容核对 | 用 ZIP 读取和磁盘字节比较确认两个文本文件压缩 / 解压内容一致 |
| 服务器表单 | ⌘K 打开表单；`sftp://example.invalid/test` 被本地校验拦截并显示支持的协议，文字没有截断；取消正常 |
| 图标 | About 窗口显示抽象蓝色尾鳍和一层背景，没有旧版内嵌方形图块 |

## 发现并修复的问题

刷新列表后，首个文件夹会藏到列标题下面，AX 仍有该项目，磁盘内容和项目计数也正确。最初通过 List + Kind 下 Extract → Undo → Redo 发现；随后在不分组的列表中 Compress 也能复现。向上滚动和取消分组不能恢复，打开 / 关闭终端触发重新布局后恢复。

根因为滚动恢复把原始 clip y 强制夹到零，而系统表头使真正顶部可以位于负 y。现按原生顶部保存逻辑距离，再交给 `NSClipView.constrainBoundsRect` 恢复；水平位置也保留。

已构建含修复的 0.1.0（3）release 包并再次通过 computer use 操作：普通列表 Compress 生成 `Sample Files 2.zip` 后，首行完整显示且点击可选中；Kind 下 Open 解压生成 `Sample Files 4`，Undo / Redo 后所有文件夹和组头完整可见，点击首个 `Sample Files` 正确选中；取消分组后首行仍完整显示。没有依靠切换终端或调整窗口来恢复。

自动化新增受控表头 inset、非零逻辑位置、水平滚动和列表缩短检查；归档操作刷新链还比较实际行与表头的几何位置、行高度和点击命中，避免只检查 AX 数量。

最终 debug 构建通过，**618 项 smoke 连续三轮通过**（比此前增加 13 项）；日志为 `/tmp/tursora-cua-fix-smoke-{1,2,3}.log`。最终 release 包已重建，ad-hoc 签名验证通过。

## 收尾与边界

测试后已恢复：显示全部扩展名、⌘F、终端关闭、ZIP 浏览关闭；清空过滤并取消分组。测试文档已关闭。

尚未覆盖：真实服务器认证 / 挂载 / 读写 / Eject，关闭所属浏览窗口时的 PTY 回收，以及浅色模式和所有屏幕尺寸。无真实服务器可用，本轮只验证连接表单及协议校验。终端使用用户配置的本地 shell，未执行远程连接。

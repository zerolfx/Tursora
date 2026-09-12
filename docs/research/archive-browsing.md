# 当前 pane 的 ZIP 浏览实验（2026-09-12）

用户希望借鉴 Windows Explorer：打开 ZIP 后按目录层级浏览，并直接打开其中的文件。实验仍默认关闭；启用后，普通目录的 Open / 双击在当前 pane 进入 ZIP，不再建立另一种独立浏览窗口。

## 参考与取舍

Microsoft 的[ZIP 与解压说明](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/zip-and-unzip-files)说明可以打开压缩文件夹查看内容，并将项目拖到其他位置取出。本实验借鉴这种目录式浏览与拖出复制；不声称实现 Windows 的完整归档写入能力，也不把 ZIP 浏览说成 Finder 的默认打开行为。

归档内容使用现有 BrowserViewController、DirectoryModel 与列表 / 图标视图，保留分组、排序、缩放、名称过滤、标签与分栏。状态栏仅增加 `ZIP · Read-only`；tooltip 解释临时副本和 Save As，没有额外范围栏、独立窗口或 Extract All 按钮。显式 Extract 仍用于在普通目录选中的 ZIP。

首次进入时，后台将整个 ZIP 解压到权限为 `0700` 的独占临时目录；不是按条目读取的虚拟文件系统。该选择复用安全解压路径，多文件文档和应用包也能找到同目录依赖；代价是大 ZIP 初次打开需要完整解压的时间和磁盘空间。没有启用实验、没有打开 ZIP 时不会做这些工作。归档原始根结构保留：不省去单个顶层文件夹，不额外包装多个顶层项目，空 ZIP 显示空目录。

## 逻辑导航与只读边界

`ArchiveWorkspace` 为同一 ZIP 共用并保留 `ArchiveBrowsingSession`。`ArchiveFileProvider` 将临时目录条目映射成原 ZIP 路径下的逻辑 file URL，例如 `/Downloads/Sample.zip/Notes/readme.txt`；这些 URL 是应用内位置，不表示磁盘上存在同名目录。`FileItem.url` 用于导航与身份，读取内容时才解析到安全的临时副本。

地址栏、面包屑、历史菜单、标签与分栏始终使用逻辑路径。⌘L 可以输入 ZIP 根或内部目录；尚未准备的归档先在后台准备，再确认目标是目录，输入普通文件不会启动外部应用。已准备目录的补全与子目录菜单使用同一安全条目模型。Back / Forward 可以跨越 ZIP 和普通目录；ZIP 根的 Up 返回原 ZIP 所在目录并选中 ZIP。进入内部子目录仍沿用普通目录的过滤清空规则。

所有归档页保持只读。禁用新建、重命名、剪切、粘贴、拖入、删除、Duplicate、内部 Compress / Extract、移动到另一 pane，以及可修改文件的 Get Info / Inspector。复制到普通目录与拖出仅执行 copy；Quick Look、Share、缩略图与显式 Open 读取经校验的临时副本。准备、列目录和选择项目不会调用外部打开器。普通文件的双击或 Open（⌘↓）才交给默认应用；Return 保留普通文件视图的改名含义，在只读归档内不执行改名。

窗口的 represented URL 使用原 ZIP；终端的启动 / Restart 目标使用原 ZIP 所在目录，不能把临时快照当作工作目录。关闭实验开关不打断已有只读页、历史和补全；普通目录中新打开 ZIP 恢复默认 Extract。

## 路径、生命周期与文件保护

解压继续使用 [Finder 归档研究](finder-archives.md) 中的安全路径，包括 libarchive 路径保护、无密码询问、资源叉恢复及下载 quarantine 传递。导航与内容读取同时检查词法路径和解析符号链接后的路径，按完整路径组件判断包含关系；使用时再次校验，防止外部编辑器将副本替换成越界链接。指向归档外部的符号链接可以显示名称，但不能读取目标元数据、导航或传给外部打开器。

离开归档、关闭标签页或窗口都不删除副本，以免外部应用丢失正在使用的文件。Tursora 正常退出时清理准备中与已完成会话的自有目录；退出后才完成的准备结果也会丢弃和清理。临时目录记录创建时的文件 ID，清理前确认仍是原来的自有目录；删除内部符号链接时不跟随其指向。

外部应用可能修改临时副本，但没有重新压缩或写回源 ZIP 的路径。需要保留修改必须 Save As 到普通目录。崩溃或强制终止后的临时目录由系统临时文件生命周期管理，不提供编辑恢复功能。

## 验证状态与限制

本轮已通过 computer use 操作当前 pane 进入 ZIP、原始根结构与 Documents 导航、More 只读禁用项、TextEdit 打开临时副本、复制 167 字节文件到普通 Delivery pane 与撤销，以及 Up / Back / Forward。详见[本轮实机记录](computer-use-2026-09-12-inline-zip.md)。快照路径重映射已修复，包含别名回归的最终 739 项 smoke 连续三轮通过；拖出手势、归档内 Quick Look / Share 和关闭实验后既有页的专项 CUA 仍未逐项完成。

**历史证据：旧独立窗口实现。** 2026-09-12 曾在打包应用中检查独立 ZIP 窗口布局、原始根结构、嵌套目录和 Back / Up；Return 将文本交给 TextEdit，确认读取临时副本，关闭 ZIP 窗口后副本仍可读。旧窗口的只读 / Save As 说明、关闭实验后恢复解压也已检查。详见[实机检查记录](computer-use-2026-09-12.md)。这些结果说明旧实现当时的行为，不能视为当前 pane 导航与菜单已通过实测。

当前不支持归档写回、密码、其他压缩格式、递归 / 内容搜索或原 ZIP 外部改变后的自动重载。普通 Open 将归档内嵌套 ZIP 作为文件交给系统关联应用，不自动递归进入另一个归档。当前目录名称过滤、拖出复制和 Quick Look 已纳入同 pane 实现，不能再列为未实现项。

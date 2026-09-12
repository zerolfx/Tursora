# Tursora vs Finder — 功能差距与难度

依据本机 Finder 的菜单 nib（`Finder.app/Contents/Resources/Base.lproj/MenuBar.nib`、`ArrangeByMenu.nib`，用 `strings` 抽出的菜单项）逐项对照。
Tags 与 Import from iPhone 明确不做；Recents、Shared / iCloud / AirDrop 暂不在此表展开。系统服务器挂载纳入 Go 菜单对照。

**难度**按一个熟悉 AppKit 的人、含 smoke test 与真机验证估：
S ≤ 半天（< 100 行，标准 API 直接可用）· M 1–2 天（100–400 行，新 view/controller 或改 model）· L 3–5 天（400–1000 行，新子系统或跨层）· XL > 1 周（> 1000 行，或依赖没有公开 API 的东西）。
估算方法：7 个按类别的 agent 对着 Tursora 源码逐项估（工时、行数、要碰的文件、API），再由部分对抗性复核（"更难"/"更容易"各一方）校正；余下由我按同样尺度校正。**粗体** = 高频且成本低到中。

## File 菜单

| Finder | Tursora | 难度 | 备注 |
|---|---|---|---|
| **Get Info**（⌘I）/ Show Inspector（⌥⌘I）/ Get Summary Info（⌃⌘I） | ✅ 已做 | — | 见 PLAN 2.10。未做：Stationery pad、ACL、改 owner/group（要提权，无公开 API → 单独算 L）、Apply to enclosed items |
| **Rename（多选 = 批量重命名对话框）** | 单选 ✅ 批量 ❌ | M | 替换文本 / 添加文本 / 格式三种模式；连锁改名（a→b 而 b 也在批里）要两遍临时名 |
| **New Folder with Selection**（⌃⌘N） | ❌ | S | createDirectory + 现有 transfer；撤销要合成一个组 |
| **Compress** / Compress with password | 普通 ZIP ✅；密码 ❌ | 密码 M | 压缩 / 解压支持重名保留、撤销重做；可选当前 pane 只读 ZIP 浏览默认关闭（浏览交互参考 Windows） |
| **Make Alias**（⌃⌘A）/ Show Original（⌘R） | ❌ | M | `URL.bookmarkData(options: .suitableForBookmarkFile)` + `writeBookmarkData`；⌘R 与我们的 Reload 冲突 |
| Always Open With（⌥ + Open With） | ❌ | S | `setDefaultApplication(at:toOpen:)`（已在 Get Info 的 Change All 用上）；上下文菜单要保留备选项对 |
| **Show Package Contents** | ❌ | S | 右键 .app 直接 navigate 进包目录 |
| Add to Dock | ❌ | M | 只有写 `com.apple.dock.plist` + 重启 Dock 这条路，格式未文档化 |
| Print | ❌ | S | `NSWorkspace.open(_:withApplicationAt:configuration:)` 让默认程序打印，无回执 |
| Share… | ✅ 工具栏系统分享选择器 | — | 按活动 pane 的选中文件分享；不直接发送 |
| Slideshow（⌥空格） | ❌ | S | `QLPreviewPanel.enterFullScreenMode`；方向键当前会改选择，要拦 |
| Customize Folder（文件夹颜色/表情，macOS 26） | ❌ | XL | 存储格式私有（可能在 IconServices 数据库里），不可靠 |
| Copy as Pathname（⌥⌘C） | ✅ Copy Path | S | 只是把快捷键对齐，做成 Copy 的 ⌥ 备选项 |
| New Smart Folder / Burn Folder / Burn Disc | ❌ | XL | 已有应用内保存搜索；尚不支持 Finder .savedSearch 互通或刻录 |
| Eject All（⌥⌘E） | ❌ | S | 逐个 `unmountAndEjectDevice`，要放后台；同一物理盘的分区会一起弹 |

## Edit 菜单

| Finder | Tursora | 难度 | 备注 |
|---|---|---|---|
| **Move Items Here**（⌥⌘V） | ❌ | S | 已有 transfer(.move)；做成 Paste 的 ⌥ 备选项 |
| Paste Exactly / Duplicate Exactly（⌥） | ❌ | M | 保留属主/权限要 `NSWorkspace.requestAuthorization(to: .replaceFile)`，异步授权与现有 transfer 的队列要接起来 |
| **Deselect All**（⌥⌘A） | ❌ | S | 几行；侧栏/地址栏有焦点时不可用（和 Finder 一样） |
| Show Clipboard | ❌ | M | 一个列出剪贴板 URL 的窗口，定时刷新 |

## View 菜单

| Finder | Tursora | 难度 | 备注 |
|---|---|---|---|
| **as Columns**（⌘3） | ❌ | L | 第三个 `FileViewing` 实现（NSBrowser 或自绘），末列预览、←→ 进出、拖放、改名、右键都要有；⌘3 与标签页 ⌘1–9 冲突 |
| as Gallery（⌘4） | ❌ | L | 大 QLPreviewView + 底部缩略条；QLPreviewView 要单例复用，有焦点和自动播放的怪癖 |
| **Show Preview**（⇧⌘P 右侧预览栏） | ❌ | M | 复用 Get Info 的 FileInfo + QLPreviewView；我们的 ⇧⌘P 现在是"显示缩略图"，要先挪 |
| **Show View Options**（⌘J，每文件夹视图设置） | 每目录持久化 ✅；Finder 式完整对话框 ❌ | 对话框 M | 现有模式 / 排序 / 两种缩放 / 分组 / 隐藏 / 预览按目录保存；View 与 Settings 有策略、默认和重置入口。应用私有路径库，不写 `.DS_Store`；没有 ⌘J、列布局或自由摆放设置 |
| Clean Up / Snap to Grid / 图标自由摆放 | ❌ | L | 图标视图从流式网格改成自由布局 + 每文件夹坐标持久化；NSCollectionView 内部拖动现在被当成文件投放拒绝 |
| Toolbar（⌥⌘T）/ Path Bar（⌥⌘P）/ Status Bar（⌘/）/ Tab Bar（⇧⌘T）开关 | 只有 Sidebar | M | 本身简单；⇧⌘T 与我们的"恢复关闭的标签"冲突 |
| **Customize Toolbar…** | ❌ | M | `allowsUserCustomization = true` + 更多 allowed items；delegate 现在对调色板的副本也存引用，要改 |
| Show All Tabs（标签总览） | ❌ | M | 截图隐藏 view 在 macOS 14 上可能是空位图，要先试 |
| Increase/Decrease Icon Size | ✅ 缩放 | — | |
| Enter Full Screen | ✅ 系统 | — | |

## Go 菜单

| Finder | Tursora | 难度 | 备注 |
|---|---|---|---|
| **Computer / Desktop / Documents / Downloads / Applications / Utilities / Library（⌥）** | 只有 Home | S | ⇧⌘C 与 Copy to Other Pane、⇧⌘D 与 Split View 冲突，要先让位 |
| **Recent Folders ▸**（含 Clear Menu） | ❌ | M | 跨会话持久化；每个新标签的首次 Home 也会被记，要过滤 |
| Go to Folder（⇧⌘G） | ✅ 进地址栏编辑 | — | 行为等价 |
| Connect to Server（⌘K） | ✅ 系统 NetFS | 历史 / 发现待做 | SMB、NFS、WebDAV、legacy AFP；真实服务端互操作未实测 |

## Window 菜单

| Finder | Tursora | 难度 | 备注 |
|---|---|---|---|
| Move Tab to New Window / Merge All Windows | ❌ | M | TabsController 加 release/adopt page；自定义标签栏，不用 NSWindow tabbing |
| Cycle Through Windows（⌘`） | ❌ | S | 没有公开的 cycleWindows:，自己按 orderedWindows 轮；系统级 ⌘` 热键可能先吃掉按键 |

## 非菜单行为

| Finder | Tursora | 难度 | 备注 |
|---|---|---|---|
| **Spring-loaded folders** | ❌ | M | `NSSpringLoadingDestination`，列表、图标、侧栏、面包屑四处；NSOutlineView 自带的悬停展开不能重复触发 |
| **Finder 设置窗口** | ✅ 基础设置与目录视图策略 | 扩展项 M–L | 扩展名显示、过滤快捷键、每目录记忆 / 统一默认、默认关闭的终端 / ZIP 浏览实验；废纸篓策略、Keep folders on top 等未实现 |
| 显示/隐藏文件扩展名 + 改扩展名警告 | 显示开关 ✅；警告 ❌ | 警告 M | 全局只改列表 / 图标标签，普通文件夹名不变；重命名、排序、过滤保留真名；不是 Finder 逐文件 flag 策略的完整复制 |
| Quick Actions（Rotate / Markup / Create PDF） | ❌ | L | Finder 的注册表是私有的，Markup 无公开 API；只能自己实现 Rotate/Create PDF |
| 右键 ▸ Services 菜单 | ❌ | S | `NSApp.servicesMenu`；一个 NSMenu 只能有一个父菜单，上下文菜单要复制 |
| 废纸篓视图（Put Back、清空） | ❌ | L | 本机已验证 `ls ~/.Trash` 被拒：需要 Full Disk Access，无系统弹窗，用户得手动授权 |
| Finder 别名双击解析 | symlink 跟随 ✅；Finder alias 自动解析 ❌ | S | 每目录视图库不新增 alias 解析；以后可用 `URL(resolvingAliasFileAt:options: .withoutMounting)` 在打开时解析目标 |
| FinderSync 角标（云同步状态） | ❌ | XL | 只有 iCloud 的 ubiquity 键是公开的；Dropbox 等的角标无公开 API |
| 中文本地化 | ❌ | L | 代码里建的菜单/字符串全部抽出；SPM 资源包在 .app 与裸二进制两种启动方式下都要找得到 |
| 快捷键与 Finder 对齐（⌘1–4、⌘L、⇧⌘T、⇧⌘P、⌘O、⌘I） | ⌘I ✅ | M | 菜单在运行中重建；同键多项的备选项要保持相邻 |

## 建议顺序（按成本）

1. S：Deselect All、Move Items Here、Copy as Pathname 对齐、New Folder with Selection、Show Package Contents、Always Open With、Print、Slideshow、Eject All、Go 菜单快捷键、Cycle Through Windows、Services 菜单、别名解析
2. M：批量重命名、Make Alias / Show Original、Recent Folders、Show Preview 预览栏、Customize Toolbar、Bar 开关、Show All Tabs、Move Tab to New Window、Spring-loaded、改扩展名警告、Paste Exactly、Show Clipboard、Add to Dock、快捷键对齐
3. L：Column 视图、Gallery 视图、完整偏好策略、图标自由摆放、废纸篓视图、Quick Actions、中文本地化、服务器发现 / 历史 / 重连；Show View Options 完整对话框另列 M（每目录持久化已实现）
4. XL / 不建议：Customize Folder、Smart Folders、FinderSync 角标

## 2026-09-12 更新

- [x] 工具栏 More 常用文件操作与系统分享按钮。
- [x] ZIP Compress / Extract，重名保留、后台处理、撤销重做。密码与其他格式未实现。
- [x] 复制 / 移动 / Duplicate 独立进度任务，支持大文件传输中暂停 / 继续 / 取消、安全 Replace 和成功项撤销；验证范围及不可暂停系统调用边界见[专项记录](../research/file-operation-tasks.md)。
- [x] Connect to Server（⌘K）与系统挂载网络卷的浏览 / Eject；真实服务端互操作尚未实测。
- [x] 基础设置窗口、扩展名显示开关、自定义名称过滤快捷键。
- [x] 每目录视图记忆、统一默认、保存当前默认与恢复目录默认；列表 / 图标均保存，完整 Finder 视图选项对话框仍未实现。自动与实机验证见本功能 [HANDOFF](../HANDOFF.md)。
- [x] 默认关闭的终端面板与当前 pane ZIP 只读浏览实验；归档支持复制 / 拖出、Quick Look 与分享，不支持写回。
- Tags、Import from iPhone 为明确不做的产品边界。

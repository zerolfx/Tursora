# 拖放行为：弹簧文件夹、面包屑投放、⌘ 强制移动

本记录覆盖三项 Finder 拖放行为在 Tursora 中的落地：**弹簧加载文件夹**（spring-loaded folders）、**面包屑分段作为投放目标**、**⌘ 拖拽强制移动**。共享投放规则仍然是 `FileOperations.dropOperation(for:into:sourceMask:)`；本次只新增 ⌘ 分支，其余判定未改。

相关代码：`app/Sources/Tursora/Model/DragAndDrop.swift`、`app/Sources/Tursora/UI/SpringLoading.swift`、`app/Sources/Tursora/UI/BreadcrumbBar.swift`、`app/Sources/Tursora/DragAndDropSmokeTests.swift`。

---

## 1. 取证（本机实际读取）

### 1.1 AppKit 头文件 —— `NSDragOperation` 与弹簧加载协议

来源：`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSDragging.h`（Xcode Command Line Tools，macOS 26 SDK）。

**已观测**（第 25–33 行）：

```
NSDragOperationNone    = 0,
NSDragOperationCopy    = 1,
NSDragOperationLink    = 2,
NSDragOperationGeneric = 4,
NSDragOperationPrivate = 8,
NSDragOperationMove    = 16,
NSDragOperationDelete  = 32,
```

**已观测**（第 165–198 行）：`NSSpringLoadingOptions`（`NSSpringLoadingDisabled` / `NSSpringLoadingEnabled` / `NSSpringLoadingContinuousActivation` / `NSSpringLoadingNoHover`，macOS 10.11+）与 `NSSpringLoadingDestination` 协议：必需方法 `springLoadingActivated:draggingInfo:`、`springLoadingHighlightChanged:`，可选 `springLoadingEntered:` / `springLoadingUpdated:` / `springLoadingExited:` / `draggingEnded:`。头文件对 `NSSpringLoadingEnabled` 的注释原文说明激活方式是「Force Click release and hover timeout **depending on user preferences**」——**计时器属于系统，应用不实现它**。

**已观测的空缺（重要）**：该头文件**没有**记录「修饰键 → 掩码收窄」的映射。全文与修饰键有关的只有 `ignoreModifierKeysForDraggingSession:`（第 159 行）和一条已废弃的 `ignoreModifierKeysWhileDragging`（第 207 行）；`draggingSourceOperationMask`（第 72 行）只被描述为「拖拽源的操作掩码」。在 `NSDragging.h` 与 `NSPasteboard.h` 中检索 `option key` / `command key` / `control key` / `modifier` 均无映射说明。

**推断（未能由本机头文件证实）**：⌥ → `.copy`、⌃ → `.link`、⌘ → `.generic` 是 AppKit 运行期行为（Apple *Drag and Drop Programming Topics* 的长期约定），本次按此实现。落地方式是**只放宽拖拽源的供给**而不猜测收窄逻辑：源掩码加入 `.generic`，目的地读回 `NSDraggingInfo.draggingSourceOperationMask`，若正好等于 `.generic` 即判定为 ⌘。若某个 macOS 版本的实际映射不同，表现是「⌘ 拖拽退化为普通拖拽」，而不是错误的文件操作——这是有意选择的失败方向。无头运行无法产生真实修饰键拖拽，因此本条**只有规则级验证，没有真实 ⌘ 拖拽的自动化证据**。

### 1.2 Finder 的弹簧加载

命令与输出（本机）：

```
$ strings -a /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder | grep -i spring | sort -u
NSSpringLoadingDestination
TSpringLoadingDestinationDelegate
SpringingEnabled
SpringingDelayMilliseconds
com.apple.springing.delay
com.apple.springing.enabled
com.apple.springing.prefchanged
-[TBrowserWindowController springDragEnterWindow:]
-[TBrowserViewController springNodeDetails:globalMouse:spawnNewWindow:]
_springCloseWhenDragLeavesWindow
_springRememberedTargetPath
_springRememberedViewStyle
_springRememberedWindowWeWereBehind
_springToFrontTimer
anyWindowIsSpringing
...
```

```
$ defaults read -g com.apple.springing.enabled   → 1
$ defaults read -g com.apple.springing.delay     → 0.5
```

**已观测结论**：Finder 自己就采用 `NSSpringLoadingDestination`；开关与延迟存放在全局域 `com.apple.springing.enabled` / `com.apple.springing.delay`（本机为开启、0.5 秒）。因此 Tursora **不自建计时器**，只声明目的地，延迟与开关由系统统一决定；Tursora 的 `DragAndDrop.systemSpringLoadingDelay` 只读取该键用于诊断与冒烟记录。

**已观测**：`_springRememberedTargetPath`、`_springCloseWhenDragLeavesWindow` 等符号说明 Finder 会在拖拽离开后回滚它弹开的窗口。**Tursora 未实现回滚**（见 §4 边界）。

**文案取证**：`Base.lproj/*.nib` 与 `en.lproj/Localizable.strings`、`LocalizableMerged.strings` 中检索 `spring` 均无命中（`strings -a .../Base.lproj/PreferencesWindow.nib | grep -i spring` 无结果）。本次实现**没有新增任何用户可见文案、菜单项或对话框**，因此不存在需要对标 Finder 措辞的地方；上文标题中的「弹簧文件夹」只是本记录的中文说法，不出现在界面上。

### 1.3 Finder 的路径栏（面包屑）

```
$ strings -a /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder | grep -i pathbar | sort -u
TPathBarController
TEphemeralPathBarDisplayController
-[TPathBarController pathControlSingleClick:]
-[TPathBarController pathSelect:didSelectNode:]
ShowPathbar / ShowEphemeralPathBar / PathBarRootAtHome / SingleClickPathBarRetarget
...
```

**已观测**：Finder 的路径栏建立在 `NSPathControl` 之上（`pathControlSingleClick:`、`pathSelect:didSelectNode:`）。`NSPathControl.h` 第 34 行与第 105–116 行记录了它的投放支持：可编辑时接受拖入，`pathControl:validateDrop:` / `pathControl:acceptDrop:` 可自定义。

**推断**：`NSPathControl` 的默认投放语义是「改变控件的值」，而**「把文件拖到某一段就把文件搬进那个文件夹」是 Finder 自己的行为**，无法从上述符号直接证实；本记录在无屏幕访问的条件下写成，未做 Finder 的人工对照观察。Tursora 采用的语义是「与列表/网格/侧栏/文件夹树/标签条完全相同的共享规则，目标是该分段所指的文件夹」——这是与本项目既有规则一致的选择，而不是对 Finder 的复刻声明。

---

## 2. 已实现的行为

### 2.1 ⌘ 强制移动

`FileOperations.dropOperation` 的判定顺序（只新增第 4 步）：

1. 空拖拽 → 拒绝。
2. 目标就是被拖对象之一 → 拒绝。
3. `sourceMask == .copy`（⌥）→ 复制，**始终**。
4. 拖入自己所在的文件夹 → 拒绝。
5. **`sourceMask == .generic`（⌘）→ 移动，跨卷也移动。**（新增）
6. 同卷移动 / 跨卷复制。

拖拽源掩码集中在 `DragAndDrop.sourceMask(readOnly:local:)`：可写来源本地 `[.copy, .move, .generic]`、外部 `[.copy, .move, .link, .generic]`；只读来源（ZIP 条目）仍然只给 `.copy`，因此 ⌘/⌃ 在只读来源上收窄为空掩码、投放被拒——归档内容可以拷出但不可移动，这一条未变。

`DragAndDrop.validationOperation(_:sourceMask:)`：AppKit 把 ⌘ 拖拽的掩码收窄为 `.generic`，验证方法必须回答在该掩码之内，否则目的地会停止接受；因此规则判定为 `.move` 时对 AppKit 回答 `.generic`。实际执行不受影响——`BrowserViewController.dropFiles` 把一切非 `.copy` 的操作当作移动。两个文件视图与文件夹树的 `validateDrop` 都改为经过这一层；`acceptDrop` 仍然直接用共享规则，传给 `onDropFiles` 的仍是 `.move`。

### 2.2 弹簧加载文件夹

- `FileOutlineView`、`FileCollectionView`、`SidebarOutlineView`（侧栏与文件夹树共用）以扩展方式声明 `NSSpringLoadingDestination`，不新增存储属性：视图通过自己的 `dataSource` / `delegate` 找到所属控制器（`SpringLoadingHost`）。
- 视图**只负责报告**：把指针位置、拖拽的 URL 和收窄后的掩码交给控制器；导航由控制器完成。**视图不触碰文件系统**，弹簧加载本身不移动/复制任何东西。
- 判定 `DragAndDrop.canSpringLoad(into:isNavigable:isReadOnly:urls:sourceMask:)`：只在「投放会被接受」的地方弹开，并且额外排除文件、只读面板、归档位置、被拖对象自身、以及被拖对象已经在的那个文件夹（⌥ 拖拽也排除——共享规则对 ⌥ 会回答 `.copy`，但那不是用户要求的导航）。
- 各目的地的动作：列表 / 网格 → 面板导航进该文件夹；Places 侧栏 → 选中该位置（`onSpringLoad` 由 `MainWindowController` 接到 `browser.navigate`）；文件夹树 → **就地展开节点**，面板不导航。
- 现有投放校验完全未改。
- 无头测试入口：`activateSpringLoading(atRow:urls:sourceMask:)`（列表/侧栏/文件夹树）与 `activateSpringLoading(at:urls:sourceMask:)`（网格，按 `IndexPath`），即 AppKit 计时器到点后会走的同一条路径。

### 2.3 面包屑投放

`BreadcrumbBar` 注册 `.fileURL`，每个**可见**分段是一个投放目标：

- `segmentIndex(at:)` 只命中未折叠的分段按钮；`…` 溢出菜单里的隐藏分段**不是**目标（本次范围之外）。
- `dropOperation(for:atSegment:sourceMask:)` 用共享规则针对该分段的 URL 判定，并拒绝归档位置与编辑态（路径输入框展开时整条栏不接受投放）。
- `performDrop(urls:sourceMask:onSegment:)` 调用 `onDropFiles`，由 `BrowserViewController` 接到既有的 `dropFiles(_:to:op:)`——撤销、`DirectoryChanges.post`、冲突处理、传输任务全部沿用既有路径。
- 悬停时该分段高亮（一层 `selectedContentBackgroundColor` 的半透明底），拖拽离开或结束即清除。

---

## 3. 验证

`DragAndDropSmokeTests`（`checkPrefix = "drag and drop: "`）：

- **纯规则**：源掩码（可写/只读、本地/外部、⌘ 在只读来源上收窄为空）；`validationOperation` 的四种情形；`dropOperation` 的同卷移动、跨卷复制、⌥ 复制、⌘ 同卷移动、⌘ 跨卷移动、⌘ 仍拒绝自身与自己所在文件夹、空拖拽拒绝。跨卷用「不存在的目标路径」作替身——它没有卷标识符，`sameVolume` 因此为假，无需挂载任何卷。
- **纯弹簧规则**：文件不弹、自身不弹、自己所在文件夹不弹（普通与 ⌥ 两种掩码）、只读不弹、拖拽结束（URL 为空）不弹、无目标不弹；`springLoadingOptions` 与 `canSpringLoad` 一致；系统延迟键可读。
- **面包屑**（details 与 icons 两种视图、带分屏与分组）：末段是当前目录、前一段是父目录；拖入父段为移动、⌥ 为复制、⌘ 为移动、拖到自己所在的那段被拒、空白处被拒、空拖拽被拒；按钮命中测试；编辑态整条栏拒绝；真实投放后文件确实搬到父目录。
- **弹簧加载 UI**（details 与 icons、带分屏与分组）：文件行/图标不弹、已在该文件夹的拖拽不弹、拖拽结束不弹、越界行/索引不弹、分组标题行不弹、只读面板不弹；悬停文件夹弹开一次且只弹一次，面板导航进去，分屏另一侧不动，且没有任何文件被移动。
- **侧栏与文件夹树**：分区标题不弹、拖拽结束不弹、悬停收藏项弹开并报告该位置；文件夹树节点就地展开且面板不导航；两者都不移动文件。收藏顺序在套件结束时还原。

夹具目录为 `$TMPDIR/tursora-drag-drop-<UUID>`，用后删除；不读取也不改写用户的真实文件或偏好（`favouritesOrder` 保存后还原）。

---

## 4. 边界与未做

- **⌘/⌥/⌃ 的真实修饰键拖拽没有自动化证据**：无头运行不能产生真实拖拽会话，只能验证规则与掩码。本机头文件也没有记录该映射（§1.1）。
- **溢出菜单里的隐藏面包屑分段不是投放目标**，按任务范围有意排除。
- **不做 Finder 的「弹开后回滚」**：Finder 会记住弹开前的窗口与视图并在拖拽离开后还原（`_springRememberedTargetPath` 等）；Tursora 弹开后就停在那里。
- **Force Click 激活未验证**：`NSSpringLoadingEnabled` 同时支持 hover 与 Force Click，本次未设 `NSSpringLoadingContinuousActivation`，也没有触控板压感的自动化验证。
- **没有计算机使用（截图/人工对照）证据**：本记录全部来自本机的二进制/头文件/`defaults` 读取与冒烟测试，没有对 Finder 或打包后的 Tursora 做视觉观察。

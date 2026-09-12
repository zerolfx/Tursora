# 每目录视图属性：Dolphin 依据与 Tursora 取舍

2026-09-12。以下 Dolphin 结论来自本机只读源码 `/Users/zerol/Workspace/Tursora/upstream/dolphin/src`，已核对 Git HEAD 为 `5e457ee9e88aa6277fbf056cd5c32462c5318866`（项目固定参考版本，2026-08-18）。行号针对该 pin；没有修改或运行上游源码。Tursora 的具体实现、自动验证与实机检查状态分别以 [ARCHITECTURE](../ARCHITECTURE.md)、[SPEC](../SPEC.md) 和 [HANDOFF](../HANDOFF.md) 为准。

## Dolphin 的已核对语义

| 主题 | 固定源码位置 | 观察 |
|---|---|---|
| 两种策略 | `settings/viewmodes/generalviewsettingspage.cpp`，构造函数与 `applySettings()`（约 40、214 行）；`settings/dolphin_generalsettings.kcfg`，`GlobalViewProps` | 设置明确区分所有文件夹共用显示样式与每文件夹记忆；上游默认统一策略。切换到统一策略时，主动将当前目录样式复制为全局样式。 |
| 属性范围 | `settings/dolphin_directoryviewpropertysettings.kcfg`；`views/viewproperties.cpp`，`setDirProperties()`（579 行） | 包括模式、缩放、预览、隐藏、分组开关和字段、排序字段和方向、文件夹优先、隐藏项排后、可见列与列宽。没有过滤文字、选中项、滚动位置或导航历史。 |
| 缩放细节 | `views/viewproperties.cpp`，`setZoomLevel()`；`views/dolphinview.cpp`，`setZoomLevel()`（506 行）、`applyViewProperties()`（2412 行） | 目录记录只有一个 `ZoomLevel`，`-1` 表示使用模式默认档位；应用目录缩放的代码只在每目录策略下执行。Tursora 分别保存列表和图标缩放是本次需求的扩展，不声称逐字照搬上游。 |
| 可写目录存储 | `views/viewproperties.cpp`，构造函数（152 行）、`loadProperties()`（42 行）、`save()`（612 行） | 适合本地直存的目录优先用 `kde.fm.viewproperties#1` 扩展属性；不支持元数据时使用 `.directory`。读取兼容已有 `.directory` 中的 Dolphin / Settings 分组；成功迁入扩展属性后清理这些分组，保留自定义图标等其他分组。扩展属性空间不足时也回退 `.directory`。 |
| 本地回退和远程 | 同文件构造函数、`destinationDir()`（744 行）、`directoryHashForUrl()`（861 行） | home 外、慢速或不可写等目录使用应用数据目录中的 `view_properties/local/`；远程使用 `remote/`。子键为 URL 编码后的 SHA-1，再 Base64 编码并替换 `/`，不是 inode 或卷 ID。旧全路径回退存储有一次迁移。 |
| 符号链接 | 同文件构造函数（约 186 行）；`tests/viewpropertiestest.cpp`，`testSymlinkSharesProperties()` | 本地 URL 先取可用的 `canonicalFilePath()`，保证符号链接与目标共享回退记录。上游测试专门覆盖了只读目标经符号链接访问的情形。 |
| 默认与恢复 | 同文件 `defaultProperties()`（102 行）、`restoreToDefaults()`（123 行）、`isDefaults()`（130 行）；`views/dolphinview.cpp`，`restoreViewSettingsToDefaults()`（2075 行） | 没有目录记录时读取全局默认；恢复默认将目录属性替换为当前全局默认。与默认完全一致的非全局扩展属性可被清除，以后随默认回退。 |
| 默认入口 | `settings/viewpropertiesdialog.cpp`，构造函数（约 163 行）、`applyViewProperties()`（306 行）；`views/dolphinviewactionhandler.cpp`（约 401 行） | 属性对话框有使用当前设置作为默认值、应用于本目录 / 子目录 / 所有目录；视图设置菜单另有恢复默认。应用所有目录会更新统一时间戳，使更早的记录失效。Tursora 本次只实现用户要求的默认和当前目录恢复入口，不做递归批量应用。 |
| 版本和保存 | `views/viewproperties.cpp`，版本常量、构造函数（约 300 行）、析构函数（322 行）、`update()`（606 行） | 当前格式版本是 4，旧字段逐步迁移。实际变更标记 dirty 和时间戳；自动保存启用时由析构保存。不能由此推断任意损坏配置都能恢复；Tursora 的损坏处理须独立验证。 |
| 特殊位置 | 同文件构造函数（约 164–298 行）；`views/dolphinview.cpp`，`viewPropertiesUrl()`（2728 行） | 搜索、废纸篓、最近使用等有独立应用数据键和首次默认样式，统一策略也有例外。`viewPropertiesUrl()` 可用逻辑 context 替换实际位置。不能由这段代码推断 macOS ZIP 临时副本应当落入普通目录持久化。 |
| 恢复与 UI 通知 | `views/dolphinview.cpp`，`setViewMode()`（312 行）、`applyViewProperties()`（2412 行） | 恢复时用事务包住视图更新，按变化发出模式、排序、分组、隐藏、预览和缩放信号；模式切换直接应用内存中的属性，避免保存失败导致交互失败。本文没有宣称上游在两个已打开视图间实时同步普通修改。 |

## Tursora 的设计边界

本次默认采用**每目录记忆**；设置与 View 菜单提供明确策略入口。**统一默认**直接使用已经保存的默认值；切换策略不会悄悄将活动 pane 提升成默认。用户通过独立的 **Use Current Settings as Default** 操作主动指定默认值。这与 Dolphin 切换统一策略时复制当前样式的实现不同，目的是让策略选择和默认值修改各自可预期。

保存项是模式、排序字段与方向、列表及图标各自缩放档位、分组、隐藏文件和预览开关；另保存 Use Groups 上次使用的分组键；foldersFirst 保持已有固定策略，不新增其持久化。过滤文字、选中项、滚动位置和历史仍是当次 pane 状态，不进入目录记录。这不是会话恢复：应用重启只恢复访问目录时的显示属性，不重建上次窗口和标签。

每目录策略下，普通修改立即更新该目录保存值，但不会使另一已打开的同目录 pane 突然换样式。另一 pane 重新进入目录时读取最新值；若两个 pane 分别主动修改，最后一次明确修改的整套属性为保存值。默认、策略切换和恢复默认是明确的全局 / 目录操作，会让受影响的已打开 pane 重新计算适用属性；统一策略下普通修改更新共同默认，并同步使用统一默认的 pane。恢复属性本身不能再次走用户修改保存路径，避免递归通知、覆盖默认或导航到其他目录。

持久化库放在 Tursora 自己的 Application Support 内，采用版本化结构，内存先生效、合并连续写入并以原子替换保存。默认值与目录记录分开；无记录使用默认，恢复当前目录删除其定制记录，使其以后跟随默认。损坏或不能识别的版本回退到可用默认，不弹出会挂住 headless 测试的模态；持久化失败不能阻止当次视图操作。具体版本、迁移规则、错误呈现及最终检查以实现文档和 smoke 结果为准，不能把这段设计说明当成已运行的验证记录。

| 身份或位置 | Tursora 策略与代价 |
|---|---|
| 普通本地目录 | 用规范化的本地路径字符串作键：折叠路径表示差异、忽略目录尾斜杠，并解析符号链接；查询和片段不属于身份，形成键时去除。拒绝非 file URL、非本地主机和已标记的虚拟页。键计算不要求路径当前可访问，因此暂时离线的位置仍能使用已有样式，也保留 FileProvider 测试接口；真实列目录和错误处理继续由导航层负责。 |
| 路径大小写 | 不主动全部转小写；保留 Foundation 规范化得到的拼写。因此不承诺把大小写不敏感卷上所有等价拼写合并成同一记录，避免误合并大小写敏感卷上的两个目录。 |
| 符号链接 / Finder alias | symlink 与目标共享规范化键，pane 在接受导航时固定本次键，后续编辑不反复解析链接而误写新目标；刷新发现链接换目标时重新载入。模型不解析 Finder alias bookmark，也不把 alias 与 symlink 混为一谈：只有调用方已解析并进入的目标目录 URL 才共享目标记录。本功能不扩展现有 alias 文件的打开 / 导航行为。 |
| 重命名、移动、替换 | 不用 inode、bookmark 或文件 ID 追踪。路径变化后读取新路径已有记录，无记录则使用默认；旧记录保留，原路径以后出现新的目录时可继承旧记录。应用内和外部移动规则相同，不暗示“属性随文件夹移动”。 |
| 挂载卷 | NetFS 挂载后按本地挂载路径处理，无需向远端写属性；同卷换挂载点不会跟随，另一个卷复用同一路径可能继承记录。不加入会阻塞浏览的远程身份查询，也不承诺按卷 UUID 自动匹配。 |
| ZIP 与搜索等逻辑页 | 不持久化：进入时采用默认，当次更改仅留在该 pane；不会覆盖默认或普通目录记录。返回普通目录重新读取其配置。归档判定先于路径键计算，不能把 ZIP 逻辑地址误当磁盘目录，更不能存储解压临时路径；既有只读操作限制保持。 |

Application Support 路径键避免污染用户目录，也不需要目录写权限；不像扩展属性那样能自然随同卷移动，也不会随文件夹复制到另一台机器。没有采用 inode 的原因是其需结合卷身份、可能重用、跨卷移动变化，且网络卷信息可能慢或不稳定；没有采用 bookmark 的原因是它增加恢复和安全作用域生命周期复杂度。路径字符串还会在私有库中暴露目录名称；此库只保存在应用自己的用户数据范围，不发布或写入项目文件夹。

## 验证原则

模型用独立库和临时目录验证两目录往返、无记录默认、重建库模拟重启、重置、策略切换、旧版 / 损坏数据与路径边界；UI 验证同目录多 pane 规则、两种模式所有属性、过滤 / 选择隔离、活动工具栏及滑块同步。快速 A → B 导航时，只有当前导航的结果能应用属性，A 的迟到结果不能覆盖 B。归档验证同时检查没有临时路径记录和只读动作仍被禁止。最终 smoke 数量、三轮日志、strict codesign 及 packaged-app computer-use 证据由本功能交接记录更新；上游源码阅读不等于这些检查已通过。

## 独立对抗性 review 与修复复查

2026-09-12，由未编写实现的 agent 独立阅读存储、pane 恢复、导航、列表排序、标签 / 分栏构造和退出路径，重点检查配置会不会写到错误目录、迟到回调、通知递归、临时状态串入新目标和保存失败。发现以下三项问题，随后对修订源码逐项复查；这是代码证据，不是运行结果。

| 发现 | 复查到的修复 |
|---|---|
| 每次编辑都解析当前 symlink：当链接从 A 改指 B、pane 仍显示 A 时，可能把 A 的配置写入 B。 | `BrowserViewController.viewPropertiesKey` 改为保存的属性；`load(_:)` 接受导航时固定目标键，`BrowserViewProperties.persistViewProperties()` 仅使用此键。`reload()` / `refreshPreservingSelection()` 发现目标键变化时先重新进入并恢复新配置。 |
| 换目标后 URL 字面没有变，原判断会保留 A 的过滤词、同名选择和待处理改名。 | `load(_:)` 同时比较 URL 与目录键；retarget 清空当前历史条目的选择 / 滚动记录及 pending selection，目录变化清空 pending renames，并采用既有清除过滤路径。 |
| 合并保存的后台错误被吞掉，界面无法解释为什么重启后设置丢失。 | `DirectoryViewPropertiesStore.writeIfNeeded()` 保留错误与 dirty 数据，将 `writeStatus` 异步投递到主队列；重试成功清错并通知。Settings 显示本次会话仍可用的失败说明与 Retry Saving View Settings。pane 明确忽略保存状态通知，防止错误消息触发属性恢复；没有在存储串行队列内同步通知主线程，避免与 `flush()` / 读取属性的 `queue.sync` 互锁。 |

复查期间的探索性 symlink 列目录断言曾失败；固定目录键与修复目录枚举是两个独立问题，失败运行均未计入最终连续三轮。

探索运行确认 Foundation 对 symlink 根目录直接枚举返回 ENOTDIR。`LocalFileProvider` 已改为解析目标后枚举、将子项 URL 保留在请求路径下；属性键正确恢复和链接改指向后的临时状态清除由专项 smoke 覆盖。最终三轮与实机结果见 [本功能验证记录](computer-use-2026-09-12-directory-views.md)。

实机另外发现窄 pane 从 Kind 图标视图恢复统一列表时，过渡中的旧分组展开会横向滚动，使 Name 列不可见。独立源码复核确认原恢复只处理纵向偏移。最终恢复先设置模型，再挂载视图，并在布局后还原该 pane 既有列表横向位置；新增断言既检查默认 x=0 的名称列，也检查主动横移 x>0 不被归零。这不是将滚动位置写入目录记录。

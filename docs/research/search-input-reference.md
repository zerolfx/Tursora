# 搜索输入与条件入口对照（2026-09-12）

本记录核对本仓库固定版本的 Dolphin 源码、Apple 官方文档，并记录本轮已实现的 Tursora 统一搜索入口。Dolphin checkout 为 `5e457ee9e88aa6277fbf056cd5c32462c5318866`，查阅时工作树干净；没有运行 Dolphin 或据此声称完成视觉验证。下文区分上游事实、Tursora 的产品选择与实现状态；末节记录 2,024 项测试之后的打包应用截图阶段，后续 Dock / 输入法调整的最终结果以 [HANDOFF](../HANDOFF.md) 为准。既有后端与历史验证范围见 [search.md](search.md)、[search-verification.md](search-verification.md)。

## Dolphin 实际交互：输入执行搜索，按钮展开条件

固定版本的 `Search::Bar` 首行依次是搜索输入、`Filter` 按钮与关闭按钮，没有独立的执行 `Search` 按钮。输入框自带清空动作，末端还放了保存搜索动作；`Filter` 使用 `InstantPopup` 打开条件菜单，作用是修改查询。第二行显示 `Here` / `Everywhere` 范围和当前已选条件。证据：[bar.cpp:53–163](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/bar.cpp#L53)。

| 输入或操作 | 固定版本源码行为 |
|---|---|
| 编辑搜索词 | 重启单次计时器；停止输入 500 ms 后提交当前配置 |
| Return | 停止待执行计时器，立即提交，并请求焦点移到结果视图 |
| 修改范围、搜索方式或条件 | 配置改变后立即提交，不另按执行按钮 |
| Escape | 有搜索词时清空；词已空时关闭搜索栏 |
| 搜索词和有效条件均为空 | 返回搜索开始前的位置，避免无条件扫描 |
| 只有类型等有效条件 | 索引后端仍可查询，不要求必须有搜索词 |

证据：[bar.cpp:38–44](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/bar.cpp#L38)、[bar.cpp:279–332](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/bar.cpp#L279)。这里的 Return 是“立即执行并进入结果”，不等于把第一个结果打开。

条件弹层包含文件名 / 正文搜索方式；构建包含 Baloo 时还提供简单搜索 / 文件索引后端，以及类型、修改日期、评分、标签选择器。后端与索引可用性会影响选项是否可用、是否展示。因此不能概括为“Dolphin 所有条件在任何目录都可用”。证据：[popup.cpp:72–105](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/popup.cpp#L72)、[popup.cpp:107–243](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/popup.cpp#L107)、[popup.cpp:273–319](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/popup.cpp#L273)。

已经生效的类型、日期、评分、标签在主搜索栏显示为可编辑、可移除的条件块，宽度不足时换行；不需要一直展开整张条件表单。证据：[bar.cpp:240–276](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/bar.cpp#L240)、[chip.h](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/chip.h)、[barsecondrowflowlayout.cpp](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/barsecondrowflowlayout.cpp)。

**与用户要求的差别：** Dolphin 的 `Filter` 入口在输入为空时也已存在；源码没有“输入后才出现入口”的条件。Tursora 采用输入后提供展开入口，是遵循本次用户要求的布局选择，不能写成原样复刻 Dolphin。

## 不要混淆独立 Filter Bar 与 Search 的条件按钮

Dolphin 的独立 `FilterBar` 输入直接触发 `filterChanged`，沿 `DolphinViewContainer.setNameFilter` → `DolphinView.setNameFilter` → 当前模型过滤；它筛选当前视图中的名称，不负责发起递归搜索。它有保留过滤条件、大小写和文本 / glob / 正则模式。搜索栏内的 `Filter` 则打开上述搜索条件弹层，改变递归搜索请求。证据：[filterbar.cpp:26–78](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/filterbar/filterbar.cpp#L26)、[dolphinviewcontainer.cpp:112](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/dolphinviewcontainer.cpp#L112)、[dolphinview.cpp:681](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/views/dolphinview.cpp#L681)。

同样，Dolphin 的 `Everywhere` 不能直接用于命名 Tursora 的 Home 范围：前者在简单搜索后端从文件系统根开始，在索引后端覆盖索引位置；Tursora `SearchRequest.effectiveRootURL` 明确只选择当前起点或当前用户 Home。范围文字应让用户知道实际查找位置。Dolphin 证据：[bar.cpp:222–239](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/bar.cpp#L222)；本地证据：`app/Sources/Tursora/Model/SearchRequest.swift` 的 `effectiveRootURL`。

## Spotlight：查询已有索引与读取文件正文的区别

Apple 的 `NSMetadataQuery` 通过 predicate 和搜索范围查询 Spotlight 元数据。初始阶段查已有 Spotlight 存储，完成后发送 `NSMetadataQueryDidFinishGathering`；API 也支持后续更新阶段。指定目录 URL 限制结果范围，不会因此把该目录每个文件当场读一遍或自动保证正文已入库。前两句为官方 API 行为，最后一句是由“查询已有存储”推导出的使用边界。证据：[Apple：Querying Metadata，Limiting the Search Scope / Running the Search](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryingMetadata.html)、[NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery)。

文件格式的 importer 可以向 `kMDItemTextContent` 提供文件内容的文本表示，应用据此查询。Apple 明确该属性可查询，但不能直接读出属性值；所以仅看到 `mdls` 的该字段为空，不能单独证明文件正文没有被索引。证据：[Apple：Assigning Values to Metadata Attributes](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/MDImporters/Concepts/AssigningDataToAttrs.html)。

用户还可在系统 Spotlight 的 Search Privacy 中排除目录或磁盘。正文能否命中取决于当前索引是否具有可搜索的文本、格式支持与范围 / 排除条件，不能把“文件存在”或“磁盘已启用索引”当成具体正文已可查的证明。排除机制来自[Apple：Prevent Spotlight searches in specific folders or disks](https://support.apple.com/en-gb/guide/mac-help/mchl1bb43b84/mac)；具体文件是否已入库的判断边界是上述 API 的推论。

查阅时 Tursora 后端的实际分工：

- 没有正文条件时，用后台文件系统遍历做递归名称、类型与日期匹配；名称搜索不依赖 Spotlight 索引。
- 正文非空时，`usesSpotlight` 选择 `NSMetadataQuery`，正文条件绑定到 `kMDItemTextContent CONTAINS[cd]`，范围为请求的实际起点 URL。没有逐文件读取正文的兜底，也没有 Tursora 自建全文索引。
- 收到初始聚集完成后主动 `stop()`，分批复制路径并核对文件仍存在、仍在范围内及元数据条件，形成一次结果快照。API 支持实时更新不表示 Tursora 已采用实时更新。

本地证据：`app/Sources/Tursora/Model/SearchRequest.swift` 的 `usesSpotlight` / `metadataPredicate`；`app/Sources/Tursora/Model/SearchBackend.swift` 的后端选择、`beginQuery` / `gathered` / `copyPaths`。30 秒超时、最多检查 50,000 个 Spotlight 候选、快照结束后重跑均是 Tursora 的实现选择，不是 Apple API 的固定限制。

## 本次 Tursora 的确定选择与实现

用户确认使用一个输入框：先过滤当前文件夹，输入后提供详细搜索入口。实现已移除独立工具栏 Search 按钮和面板内的 Search 执行按钮；可见名称编辑器始终是原工具栏输入框。空过滤词时没有附加面板，输入后在所属 pane 显示 `Current Folder` 与 `Search Options…`。点击后保留输入词、展开正文 / 范围 / 类型 / 日期条件；⇧⌘F 仍可在空输入时直接展开。展开后使用常驻条件面板，Close 退出搜索，不是 Dolphin 的条件弹层与条件块复刻。

| 状态或操作 | Tursora 已实现的行为 |
|---|---|
| 普通输入 | 立即过滤当前列表，支持 `*` / `?`；不启动递归后端 |
| 展开 Search Options | 输入变为递归名称条件；保留原文字，按字面包含匹配，不把 glob 转成查询表达式；占位提示由 Filter by Name 改为 Search by Name |
| 编辑名称、正文或调整条件 | 合并连续变更，500 ms 后自动查询；名称输入框 Return 立即执行并把焦点交给文件视图，自动执行保持编辑焦点 |
| 输入法组合 | 名称 / 正文仍有 marked text 时取消待提交的自动查询；组合提交后重新安排查询 |
| 条件全空 | 清空请求和结果，不开始无条件递归扫描；打开空的保存条件也走同一保护；正文 / 类型 / 日期单独有效时仍可查询 |
| 清空与退出 | Clear 清空条件、结果和请求，保留范围及展开面板；工具栏取消按钮 / Escape 明确退出搜索并回到目录；空名称仅失焦时保留正文或类型搜索 |

范围、草稿、计时器与 SearchSession 都属于 pane；窗口工具栏只显示活动 pane 的当前状态。切换 pane / 标签不会把待提交查询转交给新的活动 pane。导航、退出和关闭取消待提交的计时器；重新打开关闭的标签时，若保留草稿不同于已提交请求，会重新安排该 pane 的查询。同目录导航保留的过滤词也重新显示详细入口。

实现还区分 AppKit 的首次搜索事件和状态同步：首次编辑先写入所属 pane，避免系统先发送开始搜索通知时，用旧空值覆盖刚输入的字符。保存条件的 Open 通过统一提交路径校验日期与空条件；搜索文件操作的刷新仍使用所属 pane 已提交的请求，保持真实 URL 与原有 selection / generation 规则。

正文条件的 tooltip 和正文查询状态用普通文字解释 macOS 索引、支持的格式以及未索引 / 被排除的缺失；普通名称过滤不显示索引限制。可以向用户概括为：“名称会查找文件夹及其子文件夹；正文使用 macOS 的 Spotlight 索引，只能找到系统已索引且支持的内容。”无命中、启动失败与超时仍是不同状态。

本地实现：`MainWindowController.swift` 的单一工具栏字段和 delegate；`BrowserSearch.swift` 的所属 pane 路由；`SearchPanelController.swift` 的条件面板、500 ms 计时器、空条件与输入法组合处理；`TabsController.swift` / `TabPage.swift` 的关闭与重开路径。统一入口和上述边界已加入 `SearchEntrySmokeTests.swift`，原搜索后端 / 文件操作用例保留。

## 本轮验证状态

本轮 Dock 与后续输入法调整之前的截图阶段，组合源码完整 smoke **连续三轮通过，每轮 2,024 项**，三次均 exit 0、stderr 为空；这是包含统一搜索入口回归的组合套件总数。测试覆盖单一可见输入框、两种文件视图、自动提交与立即执行、空条件保护、取消、pane / 标签草稿隔离、同目录提示及关闭后重开草稿。

该截图阶段 release 构建通过，日志为 `/private/tmp/tursora-tabs-appearance-verification/release-final.log`；根任务确认 strict codesign、Info.plist lint 及包内图标一致性检查通过。在真实系统暗色和仅限应用进程的浅色外观下，实际使用同一个工具栏输入框在 Delivery pane 输入 `Notes`：先筛当前目录，出现 Search Options，展开后自动得到一个 `Release Notes.md` 结果。另一侧 Design pane 的内容不受影响。原生取消按钮 `×` 返回目录、Escape 退出也已实际操作。窗口由初始 560 px 宽调整到 1200×720；搜索流程与最终截图在后者完成，不据此宣称全部窄窗搜索状态均实测。

当前图片为[失焦后的浅色名称过滤](../images/features/name-filter.png)、[暗色搜索条件与结果](../images/features/search.png)、[浅色搜索条件与结果](../images/features/search-light.png)。这些图来自 2,024 项阶段发布包，透明角处理保留原生窗口内部像素；不是后续 Dock / 输入法调整后的最新二进制截图。上述实际输入使用拉丁文字 `Notes`，不能代替中文组合输入的真实键盘验证；本轮自动化之外的输入法覆盖及最终源码验证另行记录。

本轮没有为此改变 Spotlight 设置或重建索引。历史原生 predicate 启动 / 完成验证均为零结果，仍不能当成真实正向正文命中已验证，详见 [search-verification.md](search-verification.md)；这次入口重排不改变该历史边界。

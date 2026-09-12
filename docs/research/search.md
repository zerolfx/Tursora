# 搜索：语义、后端与边界（2026-09-12）

## 依据

只读核对原工作区 Dolphin pin `5e457ee9e88aa6277fbf056cd5c32462c5318866`：`src/search/bar.cpp` 的自动搜索、条件入口、保存条件、Here / Everywhere；`src/search/popup.cpp` 的文件名 / 正文、类型、日期与后端能力提示。输入、500 ms 计时器、Return 与独立 Filter Bar 的固定源码证据，以及本轮统一入口的实现状态，详见[搜索输入与条件入口对照](search-input-reference.md)。保留[之前的过滤对照](dolphin-filter-search.md)作为历史记录。本功能没有声称逐字复刻 Finder 搜索文字，也没有原样复刻 Dolphin 的独立搜索栏与条件弹层。

Apple 的 [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery) 和[异步元数据查询说明](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryingMetadata.html)支持 URL 范围、异步 gather 通知、停止查询；访问结果时必须停止或暂停更新。Spotlight 只返回系统索引中可见的内容，用户的隐私排除和格式 importer 会改变结果。SDK 的实际声明与编译是本地 API 校验依据。

## 选择

- 用户确认使用同一个工具栏输入框：默认立即过滤当前文件夹；输入后出现所属 pane 的 Search Options 入口，展开后以原词搜索子目录并提供正文、范围、类型和日期条件。不再有独立 Search 工具栏按钮或面板执行按钮，也不增加第二个可见名称输入框。⇧⌘F 仍可从空输入直接展开。
- 普通过滤保留 `*` / `?` 规则；展开后的名称条件改为字面包含，原词原样带入，通配符不再展开。占位提示与 tooltip 随模式切换。展开后名称、正文和条件变更合并为 500 ms 自动提交，Return 可立即提交；工具栏 Return 把焦点交给结果视图，自动提交不抢走编辑焦点。名称 / 正文输入法组合未提交时取消待提交的自动查询。
- 当前文件夹递归，或明确标为 Home 的更广递归范围；Home 不代表整台 Mac，也不等于 Dolphin 的 Everywhere 后端全集。
- 不含正文条件时，后台枚举普通目录，以文件名、UTType、修改日期做 AND 匹配。名称是忽略大小写的包含文字。遍历不进入遇到的包、ZIP 或符号链接目录；显式选择的根路径先解析链接，按该实际目录搜索。
- 含正文条件时，使用 `NSMetadataQuery` 的 `kMDItemTextContent` 与元数据条件；不读取每个文件做自建全文索引。索引未包含的正文无结果不能解释为磁盘上不存在对应内容。正文条件 tooltip 与正文查询状态说明 macOS 索引、格式支持和排除边界，普通名称过滤不显示无关的索引说明。
- 查询是一次结果快照；编辑条件自动重跑，Return 或 Reload 也可重新执行。在结果中的应用文件操作通过 `DirectoryChanges` 触发刷新，仍使用所属 pane 已提交的请求和真实文件 URL；外部更改后可 Reload。
- 草稿、待提交计时器与 SearchSession 都属于 pane；共享工具栏随活动 pane 切换，不转移查询所有权。取消和替换先增加 generation，迟到回调不能覆盖新状态。退出搜索或导航清除搜索上下文；关闭 pane、标签或窗口取消尚未发出的自动提交。关闭标签保留其 pane 状态供重开；重开时草稿若不同于已提交请求，会重新安排查询。同目录导航保留过滤时也保留 Search Options 入口。
- 日期下界包含、上界排除；Today / Last 7 Days / Last 30 Days 保存为当时的固定起止日期，重新打开仍使用这些日期界限，不滚动更新。Clear 清空条件、结果和请求并保留范围与展开面板；全空输入及空的保存条件均不启动广泛扫描，单独正文 / 类型 / 日期仍可查询。工具栏取消按钮与 Escape 明确退出搜索；名称为空时仅失焦不会关闭正文或类型搜索。
- 单次上限 50,000：递归按匹配结果截断；Spotlight 最多检查前 50,000 个索引候选，两者均提示收窄条件。
- 保存搜索是应用偏好中的条件与范围，不是 Finder `.savedSearch` 文件；删除只删条件。打开保存项恢复条件并经统一提交路径校验后重新执行，不保存陈旧结果。
- 搜索结果使用真实 URL，列表 Location 列、图标位置标签与路径 tooltip 表明来源；同名结果仍分别选择。无默认写入目录，所以 New Folder、Paste、Compress、Extract 不在结果上下文提供。Open、Reveal in Enclosing Folder、Quick Look、Copy、Rename、Duplicate、Trash、跨 pane 传输使用真实来源；有明确目录目标的拖入仍可用。
- ZIP 内 Search 入口禁用，不搜索已解压临时副本；普通目录可以找到 ZIP 文件本身。Tags、评分、正则、自建全文索引与 Finder Smart Folder 互通未实现。

## 验证

原独立搜索阶段的自动化、Spotlight 实机路径和打包应用 computer-use 结果保留在 [search-verification.md](search-verification.md)。其中原生 predicate 启动 / 完成结果均为零，未验证真实正向正文命中；本次入口调整不改变这一历史边界，也不把索引延迟当作稳定 smoke 前提。

本轮 Dock 与后续输入法调整之前的截图阶段，组合源码完整 smoke **连续三轮通过，每轮 2,024 项**，三次均 exit 0、stderr 为空；这是包含搜索后端、文件操作与统一入口回归的组合套件总数。后续最终源码的结果以 [HANDOFF](../HANDOFF.md) 为准。

`SearchEntrySmokeTests.swift` 覆盖两种视图、单一输入框、自动提交与立即执行、pane / 标签草稿、明确取消、空名称失焦、空保存条件、同目录提示和重开草稿；原搜索后端与文件操作用例保留。

该截图阶段的 release 构建、strict codesign、Info.plist lint 和包内图标一致性检查通过，构建日志为 `/private/tmp/tursora-tabs-appearance-verification/release-final.log`。打包应用在系统暗色和进程内浅色外观下实际完成 Delivery pane 输入 `Notes` → 当前目录过滤 → Search Options → 自动得到一个 `Release Notes.md` 结果，Design pane 不受影响；工具栏原生 `×` 和 Escape 返回目录已检查。见[当前过滤图](../images/features/name-filter.png)、[暗色搜索图](../images/features/search.png)、[浅色搜索图](../images/features/search-light.png)及[实机范围](search-input-reference.md#本轮验证状态)。这些是 2,024 项阶段包的名称搜索证据，不是后续 Dock / 输入法调整后的最新二进制验证，也不改变真实正向正文命中尚未验证的边界。

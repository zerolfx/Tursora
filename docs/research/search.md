# 搜索：语义、后端与边界（2026-09-12）

## 依据

本轮只读核对原工作区 Dolphin pin `5e457ee9e88aa6277fbf056cd5c32462c5318866`：`src/search/bar.cpp:63–117` 的独立搜索、保存条件、Here / Everywhere；`src/search/popup.cpp:72–104,199–223,273–314` 的文件名 / 正文、类型、日期与后端能力提示。保留[之前的过滤对照](dolphin-filter-search.md)作为历史记录。本功能没有声称逐字复刻 Finder 搜索文字。

Apple 的 [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery) 和[异步元数据查询说明](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryingMetadata.html)支持 URL 范围、异步 gather 通知、停止查询；访问结果时必须停止或暂停更新。Spotlight 只返回系统索引中可见的内容，用户的隐私排除和格式 importer 会改变结果。SDK 的实际声明与编译是本地 API 校验依据。

## 选择

- 当前文件夹递归，或明确标为 Home 的更广递归范围；Home 不代表整台 Mac，也不等于 Dolphin 的 Everywhere 后端全集。
- 不含正文条件时，后台枚举普通目录，以文件名、UTType、修改日期做 AND 匹配。名称是忽略大小写的包含文字；原工具栏 Filter 仍支持独立的 `*` / `?` 规则。遍历不进入遇到的包、ZIP 或符号链接目录；显式选择的根路径先解析链接，按该实际目录搜索。
- 含正文条件时，使用 `NSMetadataQuery` 的 `kMDItemTextContent` 与元数据条件；不读取每个文件做自建全文索引。索引未包含的正文无结果不能解释为磁盘上不存在对应内容，界面持续说明这一限制。
- 查询是一次结果快照；Reload / Search 重新执行。在结果中的应用文件操作通过 `DirectoryChanges` 触发刷新；外部更改后可 Reload。
- SearchSession 与 pane 同生命周期，取消和替换先增加 generation，迟到回调不能覆盖新状态。离开搜索、导航或关闭 pane 后释放查询。
- 日期下界包含、上界排除；Today / Last 7 Days / Last 30 Days 保存为当时的固定起止日期，重新打开仍使用这些日期界限，不滚动更新。Clear 清空条件、结果和请求并保留范围，不自动开始广泛扫描。
- 单次上限 50,000：递归按匹配结果截断；Spotlight 最多检查前 50,000 个索引候选，两者均提示收窄条件。
- 保存搜索是应用偏好中的条件与范围，不是 Finder `.savedSearch` 文件；删除只删条件。打开保存项重新执行，不保存陈旧结果。
- 搜索结果使用真实 URL，列表 Location 列、图标位置标签与路径 tooltip 表明来源；同名结果仍分别选择。无默认写入目录，所以 New Folder、Paste、Compress、Extract 不在结果上下文提供。Open、Reveal in Enclosing Folder、Quick Look、Copy、Rename、Duplicate、Trash、跨 pane 传输使用真实来源；有明确目录目标的拖入仍可用。
- ZIP 内 Search 入口禁用，不搜索已解压临时副本；普通目录可以找到 ZIP 文件本身。Tags、评分、正则、自建全文索引与 Finder Smart Folder 互通未实现。

## 验证

自动化、Spotlight 实机路径和打包应用 computer-use 结果在本轮完成后记录到 [search-verification.md](search-verification.md)，不把索引延迟当作稳定 smoke 前提。

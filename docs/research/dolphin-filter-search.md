# Dolphin 的过滤与搜索（2026-09-12）

> 这是独立搜索实现前的历史记录；2026-09-12 后续实现与当前边界见 [搜索研究](search.md)。

直接核对 `upstream/dolphin`，提交 `5e457ee9e88aa6277fbf056cd5c32462c5318866`，与项目 Phase 0 pin 一致。

- `src/filterbar/filterbar.cpp:26–96`：过滤栏含跨目录保留锁、输入框、大小写按钮、Plain Text / Glob Pattern / Regular Expression 模式与关闭按钮。`clearIfUnlocked()` 在导航时清除未锁定过滤。
- `src/search/bar.cpp:63–117`：搜索是独立界面，有保存搜索、Filter 条件菜单、Here / Everywhere 范围按钮。`setSearchPath` 的 tooltip 明确 Here 含子目录。
- `src/search/popup.cpp:73–112,208–239,307–314`：选择文件名 / 内容、搜索后端，以及文件类型、修改时间、评分、标签；可用条件受后端限制。

Tursora 当前只实现本目录名称子串和 `*` / `?` 通配符，忽略大小写，按 pane 保存，导航清空。旧的 `Filter: [当前目录]` 行只是不能点击的占位，既不能切范围也没有附加条件，现移除。工具栏明确写 `Filter by Name`，底部状态栏显示匹配数量；真正递归搜索、条件选择与高级过滤仍列为差距。

官方源码：[FilterBar](https://github.com/KDE/dolphin/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/filterbar/filterbar.cpp)、[Search::Bar](https://github.com/KDE/dolphin/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/bar.cpp)、[Search::Popup](https://github.com/KDE/dolphin/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/popup.cpp)。

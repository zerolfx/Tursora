# 搜索专项验证（2026-09-12）

本记录对应独立 worktree `d660/Tursora`，原始基线 `fbb6762`，提交前已同步 `main` 的 `ae5e47a`（保留产品页与维护整理），分支 `codex/recursive-saved-search`。其他功能 worktree 的未提交内容未搬入。

## 自动化范围

`SearchSmokeTests.swift` 先测纯条件和注入后端，再测真实 pane。内容条件用确定性的索引夹具验证，不依赖系统索引何时可见。

- 名称 / 正文区别，大小写与变音符号，字面引号不注入 predicate，类型与日期 AND，起点包含 / 终点排除。
- 嵌套同名文件、未索引目录递归、空结果 / 无效目录、符号链接 / 包边界。
- 取消、替换、clear 后的迟到结果；同步、重复批次、终态后回调；权限失败和日期错误无模态。
- 保存请求跨 Store 与 JSON 往返，Save / Open / Delete / Clear 真实控件；删除条件保留文件。
- 列表与图标、分组与名称过滤、Location、真实 URL 的 Open / Quick Look / Share / Info / Reveal、改名 / 撤销；迟到改名通知不误改同名项。
- 分栏与标签隔离，导航取消，原目录历史不被搜索选择覆盖，ZIP 搜索入口和保存条件不能越过只读边界。

独立对抗性审查发现并修复：导航历史混入搜索 basename；行内编辑在结果重用后绑定错目标；图标分组后用旧 indexPath 解析新结果；结果批次重排行后右键菜单目标漂移；父目录 / 后代同时 Trash 未注册撤销；符号链接叶子的 `skipDescendants()` 导致后续目录漏搜。最后一项已用独立 Foundation 探针对失败夹具复现，修复后不再手动跳过 symlink leaf。

开发中还修正了测试的 `/var` / `/private/var` 表示差异，以及跨测试保留文件类型条件的设置；这些失败不计为最终通过轮次。CUA 前版本曾有 854 项连续三轮通过、stderr 为空及 release / strict codesign 通过；实机正文查询随后发现单子项 AND/OR 不受 NSMetadataQuery 支持而异常退出。单条件改为直接 predicate，空条件用受支持的文件名 match-all；已补实际生产 predicate 的 74 组原生启动 / 完成检查和纯结构检查，最终集成版本已完成 **891 项连续三轮通过**，均 exit 0、stderr 为空；debug / release build 与 strict codesign 通过。日志为 `verified-1/2/3.stdout` 与对应 `.stderr`。旧快捷键集成测试已改为未被 Search 占用的 ⌥⇧⌘F。

## 实际 Spotlight 路径

修复后将实际 `SearchRequest.swift` 编入原生探针，74 组条件全部 `start() == true` 并收到 DidFinishGathering，stderr 为空；包含每种类型、名称 / 日期组合，以及引号、通配符和反斜杠字面值。结果均为 0，这验证 API 接受实际生成的条件，不代表正向正文命中。日志位于 `/private/tmp/tursora-search-exact-predicate-probe/`。

此前独立 `NSMetadataQuery` 探针实际向元数据服务查询本 worktree：文件名、正文 `CONTAINS[c]` / `CONTAINS[cd]`、文本类型四个 predicate 均 `start() == true` 并收到 DidFinishGathering。四个结果均为 0；`mdfind` 同范围正文计数也为 0；`mdutil -s /` 显示 Indexing enabled。原源码目录 `/Users/zerol/Workspace/Tursora` 只读探针亦为 0。

执行工具的限制沙箱无法访问元数据服务，`start()` 返回 false；授权的本地运行成功。这里验证了实际 API / 服务的启动、终态和空索引路径，**没有把正向正文命中视为已验证**，也没有更改索引设置或强制重建索引。正文由 Spotlight 支持的格式、权限、隐私排除和当前索引决定，应用持续显示限制。

探针和本地构建 / smoke / codesign 日志保存于本机专属目录 `/private/tmp/tursora-search-verification-d660/`。所有 smoke 与 CUA 横跨实际运行过程持有 `/private/tmp/tursora-shared-verification.lock` 的排他 flock；运行前保存偏好，结束后恢复，只处理本 worktree 的绝对路径或自身 PID。

## 打包应用 computer-use

已在本 worktree 的 release 包操作专属演示目录 `/private/tmp/Tursora-Search-d660`（没有个人文件）：

- 正文单条件查询正常结束为 0，界面可见 Spotlight 索引 / 格式限制，运行日志 stderr 为空。
- 名称 `Project Notes` 递归返回 Delivery、Design、Research/Notes 三个同名文件；列表 Location 与图标父路径各自显示真实位置。
- 分栏后左侧保留三项结果，右侧独立搜索 `Meeting`，图标视图只显示 Research 中的一项。
- Save 命名条件，结束自身 PID 后真实重启；从 Home 的 Saved Searches → Open 恢复原演示目录及三项结果。Delete 之后条件列表为空，演示文件仍完整；Clear 移除当前结果与条件而不启动全目录查询。
- 较早的打包检查已实际选择 Design 同名项并用 Space 预览，正文是 Design 的演示文本；Reveal in Enclosing Folder 导航到 Design 并选中准确文件。

三轮烟测后，对包含菜单目标与父子选择修复的最终 release 包再次检查：搜索右键菜单没有 Compress，点击 Design 结果的 Reveal 后到达真实 Design 目录并选中准确文件；分栏独立查询、保存条件和正文单条件完成均再次操作。

已从确认过的本 worktree PID `80602`、主窗口 ID `7467` 用 `screencapture -x -o -t jpg -l7467` 保存并查看 [search.jpg](../images/features/search.jpg)（3840 × 1920）。截图展示左侧三个同名结果及保存条件，右侧独立图标查询。最终运行 stderr 为空；只停止自身 PID，恢复运行前偏好后释放共享锁。

同步上游产品页时更正了仍称正文 / 跨目录搜索未实现的说明，`python3 site/build.py` 通过（5 个规范资源，36 处引用）。本轮只改变该页的功能边界文字，没有部署页面。

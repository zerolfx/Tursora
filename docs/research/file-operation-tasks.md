# 文件操作任务与验证

## Dolphin 源码依据

只读参考 `/Users/zerol/Workspace/Tursora/upstream/dolphin/src`，已核对 pin 为 `5e457ee9e88aa6277fbf056cd5c32462c5318866`（2026-08-18）。

- `views/dolphinview.cpp:945–986`：Copy / Move 为独立 `KIO::CopyJob`，绑定发起窗口、订阅结果与创建项目通知，并交给 `FileUndoManager` 记录。
- `views/dolphinview.cpp:1001–1050`：Duplicate 使用异步 `KIO::copyAs`，自动改名，记录撤销。
- `views/dolphinview.cpp:1517–1545`：拖放由 DropJob 路由实际复制任务。
- `views/dolphinview.cpp:2637–2657`：Paste 使用独立 PasteJob，监听复制任务和最终结果。

上述代码支持统一任务化、固定窗口上下文和以成功结果驱动撤销；进度呈现、挂起能力本身由外部 KIO / KJob 提供，此处没有其实现，不能据此声称复刻其全部细节。Tursora 使用本地传输引擎与原生 AppKit 任务窗口，不增加网络协议后端。

## 本轮实现与边界

普通文件数据逐块读写，可中途暂停 / 继续 / 取消；扫描总量未知、元数据 / fsync 与原子发布显示真实阶段。原有权限、时间、ACL、扩展属性、资源叉、隔离标记、符号链接与包由系统元数据复制和受控暂存保留。Locked 副本只在应用拥有的改名期间暂时调整标记，立即恢复；不解锁用户原始源或既有替换目标。

临时存储由系统 `.itemReplacementDirectory` 提供，并验证与相应文件同卷；不会把内部恢复目录留在普通浏览目录中。成功后撤销日志保留所需恢复内容，取消 / 故障先清理再发终态。跨卷移动在目标完成后才将源移至同卷恢复区，撤销历史释放时回收。代价是额外空间，不支持崩溃后恢复会话。

同卷移动、元数据系统调用和短发布事务不能保证在一次系统调用内立即停止；Cancel 在下一个边界生效。已发布的成功项仍属于成功变更，批次显示部分完成，并可撤销。关闭浏览窗口取消其任务并等待；关闭任务窗口只隐藏；退出先取消传输，再关闭归档工作区。ZIP 压缩 / 解压工具阶段、废纸篓、删除不在可暂停传输范围。

## 独立对抗性审查

由未编写引擎的协作者审查文件操作和异步生命周期，确认并补修：

- 冲突等待或 Merge 子项之间源 / 目标目录被替换，会导致任务作用于新目录：固定目录身份，子项及空目录移走前再次验证。
- Replace 等待后相同 inode 内容被更新，以及跨卷源在等待提交锁时被更新：持锁后核对完整文件状态。
- 终态早于暂存清理：先清理，再交付终态，退出不会早于工作线程清理。
- 退出取消完成回调同步触发、或 Clear Finished 清走部分终态导致等待永远不结束：异步完成回调，以仍活跃任务集判断结束。
- 系统元数据复制会保留 Locked 标记，导致暂存发布 EPERM：在隔离 fixture 实测复现，修复副本发布 / 撤销 / 重做与丢弃暂存的标记处理。
- 跨卷移动后文件被编辑、合并重做前添加新子项：拒绝恢复过时副本或移走新内容。
- 快速失败未打开任务窗口、新冲突被旧历史挡住：失败自动提示一次，新任务置顶并定位到需要操作的任务。
- macOS 临时目录的 `/var` 与 `/private/var` 别名会误判恢复内容的保留集合：统一系统恢复根的物理路径，同时保留叶符号链接本身。
- `copyfile` 会改写隔离属性的来源字段：fixture 核对字节差异后，对隔离属性作精确保留。

## 验证记录

2026-09-12，功能分支以 `fbb6762` 为基线，最终 debug 构建后 **928 项 smoke 连续三轮通过**，每轮 exit 0、stderr 为空。旧文档中的 739 项三轮属于基线；开发阶段的失败运行、922 项通过，以及补充显式 ACL 断言前的 926 项三轮不计入最终三轮。

专项覆盖单文件中途暂停 / 继续 / 取消、独立并发任务、扫描 / 写入 / 发布 / 源移走边界的取消与故障、Replace / Merge / Keep Both / Skip / Apply to all、成功项撤销重做、目录身份变化、替换等待时内容变化、跨卷恢复副本被编辑及合并目录后来新增内容。元数据 fixture 检查权限、时间、ACL、扩展属性、资源叉、隔离属性、Locked、包和悬空符号链接。控制器检查覆盖列表 / 图标、过滤与分组、分栏 / 导航 / 新标签 / 关闭标签期间固定上下文、剪贴板和拖放回调、Duplicate、后台 pane 刷新、任务按钮和窗口关闭清理；快速失败提示及旧任务冲突定位也有专项断言。既有 ZIP 复制出测试通过同一引擎继续运行。

最终 release 包由 `tools/make-app.sh` 生成，`codesign --verify --deep --strict --verbose=2 app/build/Tursora.app` 通过。日志保存在本工作树的 `app/build/transfer-verification/smoke-{1,2,3}.log`、对应 `.stderr` 和 `codesign.log`（不提交构建产物）。全部 smoke 在 `/private/tmp/tursora-shared-verification.lock` 的独占锁内运行，前后保存 / 恢复 `Tursora` 与 `com.tursora.Tursora` 两个偏好域。

跨卷分支通过 `forceCrossVolumeMove` 注入验证；本机没有第二个可写独立卷，不将此结果称为真实跨卷实机验证。真实服务器读写也未验证。

## 实际打包应用检查

最终 release 包通过 CUA 实际操作；核对进程为本工作树 `app/build/Tursora.app/Contents/MacOS/Tursora`（PID 79930），没有操作其他工作树的应用。最终三轮 smoke 与下列 CUA 连续处于同一次独占锁内；应用正常退出后恢复两个偏好域并释放锁。后续文档、提交和 CI 不持有验证锁。

演示 fixture 位于本工作树 `app/build/transfer-verification/demo`。两个 128 MiB 文件使用进程环境 `TURSORA_TRANSFER_TEST_DELAY_MS=100` 放慢块传输，以稳定观察中途操作；这是实际文件读写，截图中的速度不是性能基准。

- 列表视图中通过 Copy / Paste 复制 `Research footage.bin`，在 101.2 MB / 134.2 MB 处点击 Pause；随后多次观察值不变，目标目录没有未完成文件。
- 关闭任务窗口、切换目录和图标视图，通过 Copy / Paste 启动 `Delivery assets.bin`。再次从 Window → File Operations 打开，前一项仍暂停，后一项独立传输并显示速度 / ETA。只取消第二项，第一项 Resume 后完整完成。
- 图标分栏中执行 Move to Other Pane，`Readme.txt` 冲突自动定位到任务顶部；原生同卷移动显示 No file data to transfer。清除旧任务记录不影响冲突；Keep Both 后两 pane 刷新，既有目标保留，源移到 `Readme 2.txt`。
- 在发起窗口中撤销 Move，再撤销早先 Copy，随后重做 Copy；操作仍作用于最初目标，且 Clear Finished 不清空窗口撤销历史。
- 图标视图 Duplicate 同样出现任务，在 44.3 MB / 134.2 MB 处暂停后按 ⌘Q；应用正常退出（exit 0），暂停线程被取消，未留下副本。
- 退出后逐个比较演示前的 SHA-256：三个源文件、原有目标 `Readme.txt` 均未变；恢复后完成的 Copy 与原文件一致；取消的 Copy、退出取消的 Duplicate、撤销的 Keep Both 输出均不存在。结果保存在 `app/build/transfer-verification/demo-after-checks.json`。

实际 JPEG 截图：[`file-operation-tasks.jpg`](../images/features/file-operation-tasks.jpg) 为一项暂停、一项传输；[`file-operations.jpg`](../images/features/file-operations.jpg) 为位于历史记录前方的内联冲突。已检查实际图片格式与可读性，未拼接或模拟界面。清除历史后即时截图未显示卡片，未用作完成证据；保留清除前已目视确认的原始截图，随后实际 Keep Both 按钮操作成功。

实机边界：本轮拖放手势尝试仅改变选择、未触发传输，因此不记录为成功的原生拖放证据；随后验证的是 Move to Other Pane 命令。两种视图接受拖放后的实际控制器回调有自动化覆盖；原生拖放手势、真实跨卷 / 服务器、浅色模式和极端长路径布局仍需专项实测。

# 三项 Dolphin 功能的 PR 整合（2026-09-12）

## 基线与方法

从 main `ae5e47a` 核对 PR #1 每目录视图（`820cf4e`）、PR #2 文件操作任务（`88714d4`）及 PR #3 搜索（`31203d6`）；三个原始 PR 的 GitHub Build 均通过。原任务各自的 smoke 和实机证据保留在功能研究记录中。

整合在 `/private/tmp/tursora-merge-integration` 完成，保留主工作区及三个开发 worktree。先把目录视图接入操作任务，再接入搜索；后续 PR 通过包含前序分支的合并提交解决冲突，最终按 #1、#2、#3 顺序合入。构建可并行，smoke 与打包应用检查使用共同的 `fcntl.flock`，前后保存恢复两个应用偏好域。

## 审阅发现与回归

- 同卷原子移动不应递归读取无需复制的后代；含 FIFO 或不能枚举后代的目录仍应能原子移动。
- 撤销日志在身份检查失败时不能因 UndoManager 消费动作而删除唯一恢复副本；保留恢复位置并向用户报告。
- 恢复目录视图后，传输 smoke 的图标轮需在最终目录加载后设置图标模式并检查真实模式。
- 搜索页必须隔离来源目录和统一默认的持久化属性、观察者及默认/重置动作，刷新不能意外退回普通目录。
- 搜索结果文件传输使用真实 URL 和父子去重，完成与撤销继续刷新搜索，不能把无默认目标的搜索页当作可粘贴目录。所选祖先与子项之间若有符号链接，显式子项仍单独保留；自动化覆盖实际复制后的目录、链接原文和外部文件内容。

## 当前验证状态

目录视图与文件操作任务组合（含审阅修复）已完成 `swift build`，1,063 项 smoke 连续三轮通过、stderr 为空；站点构建通过。旧 ZIP 测试改为追踪本次操作新增的窗口身份，避免其他测试窗口异步关闭导致总数判断不稳定，并覆盖同数换窗的反例。

最终三功能组合（含中间符号链接修复）的验证：

- Debug 构建成功，**1,253 项 smoke 连续三轮通过**，每轮 exit 0、stderr 为空，耗时 74.8 / 74.2 / 74.0 秒。日志在 `/private/tmp/tursora-integration-verification/final-verified/`。此前 1,249 项的三轮对应链接修复前，不计入最终结果。
- `tools/make-app.sh` release 构建成功，`codesign --verify --deep --strict --verbose=2` 通过。已有编译器警告仍在，不称为无警告构建。
- 站点构建通过，检查 36 个引用与 5 个 canonical assets。
- PR #2 整合提交 `1464169` 的 [GitHub Build](https://github.com/zerolfx/Tursora/actions/runs/34685214129) 通过。最终 PR #3 和 main 的精确提交 CI 在发布时单独核对；本地结果不能代替远端检查。

## 最终打包应用实测

使用上述 release 包和 `/private/tmp/tursora-integration-verification/cua-demo` 一次性夹具；进程设置 `TURSORA_TRANSFER_TEST_DELAY_MS=100`，以观察真实大文件块传输，速率不是性能基准。

- Sources 的 First / Second 各有同名 `needle.txt`，另有 128 MiB `needle-large.bin`。递归名称查询得到 3 个结果，列表和图标显示各自原始位置。
- Sources 保存 List；搜索中切到 Icons，关闭搜索恢复 List。Destination 保存 Icons；Back 回 Sources 为 List，Forward 再进 Destination 为 Icons。
- 从列表搜索结果 Duplicate 大文件，任务窗显示字节、速率和剩余时间。Pause 在 59.8 / 134.2 MB 确认，后续观察字节不变；Resume 后继续到 60.8 MB，Cancel 在 73.9 MB 结束，显示 0 completed。原文件 SHA-256 保持 `a626d17da2e502f5b4b8e3ebd23f0bf9daef6255688d8e0bb482b3ae3794a682`，没有半成品或暂存残留。
- Duplicate 小文件后搜索得到 4 项，并精确选中 First 中的副本；撤销后恢复 3 项，两个同名原文件内容不变。
- 保存命名条件 `Integration Needle`，Clear 后 Open 重跑得到 3 项。跨进程保存的专项实测见[独立搜索记录](search-verification.md)，本轮同进程重跑不称为重启验证。
- 已查看搜索与暂停任务的实际布局；已有 feature 截图仍对应当前界面。结束后退出本轮应用、确认原文件完整与清理完成，恢复两个偏好域和目录视图库，释放共同锁。

本轮没有新增真实 Spotlight 正文正命中、第二物理卷或服务器、原生拖放手势的实机证据。正文注入夹具与原生查询生命周期、跨卷故障注入及 drop controller 路径的自动化边界仍按原记录区分。

## 提交信息约定

按用户要求，AGENTS 与 DEVELOPMENT 改为具体模块 scope（例如 `search`、`transfers`、`view-settings`）；全局或跨模块提交省略 scope。三个 PR 完成后对 main 作提交信息重写，保留原作者、时间、父子关系和每个 tree；旧历史以备份引用保留，发布使用精确的 force-with-lease。重写前后 tree 校验及远端 CI 在完成后由交付记录确认。

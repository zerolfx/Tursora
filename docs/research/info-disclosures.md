# Get Info 分区折叠状态（2026-09-12）

本轮用户要求 Get Info 的初始展开状态与本机 Finder 保持一致，避免首次打开时全部展开。这里记录的是本机已观察的 Finder 状态，并非 Apple 出厂默认值；Finder 会记忆分区选择，本机已有历史偏好。

## Finder 证据

从 `/System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/InfoWindow*.nib` 执行 `strings`，确认七个分区的英文标签以及它们的 `value: expanded` / `expanded` 控制器绑定。Nib 的这些字符串能确定标签和绑定，不能单独证明没有偏好时的初始展开值。

Finder 可执行文件的 `strings` 将下列 nib 与偏好标识对应：

| Nib | 分区标签 | Finder 标识 | 本轮 `Feedback.md` Info 辅助功能树状态 | Tursora key |
|---|---|---|---|---|
| `InfoWindowGeneralView.nib` | `General:` | `General` | 1，展开 | `general` |
| `InfoWindowMoreInfoView.nib` | `More Info:` | `MetaData` | 0，折叠 | `moreInfo` |
| `InfoWindowNameView.nib` | `Name & Extension:` | `Name` | 0，折叠 | `name` |
| `InfoWindowCommentsView.nib` | `Comments:` | `Comments` | 0，折叠 | `comments` |
| `InfoWindowOpenWithView.nib` | `Open with:` | `OpenWith` | 0，折叠 | `openWith` |
| `InfoWindowPreviewView.nib` | `Preview:` | `Preview` | 1，展开 | `preview` |
| `InfoWindowPermissionsView.nib` | `Sharing & Permissions:` | `Privileges` | 0，折叠 | `sharing` |

本轮根任务通过实际 Finder UI 读取上述七项辅助功能状态。资源检查时，`defaults read com.apple.finder FXInfoPanesExpanded` 返回 `Comments = 0; MetaData = 0; Name = 0;`；它包含用户保存值，不能被称为出厂默认字典。`InfoDisplayOptions.plist` 只有文件种类对应的显示数值，没有给出上述七项展开偏好。

Tursora 采用这一可复核的本机基线：**General 与 Preview 展开，其余分区折叠**。Inspector 及 Summary 对存在的同名分区使用同一策略；Summary 只有 General。未来未列出的分区默认折叠。

## 旧偏好迁移与选择记忆

旧实现为所有缺省分区返回 `true`，并在每次初始化时立即写入 `InfoSection.<key>`。因此已有 `true` 无法区分用户主动展开与程序自动保存；单纯保留全部旧 `true` 会让已安装应用继续全部展开。

新实现使用以下读取顺序：

1. 新键 `InfoSection.ExplicitExpanded.v2.<key>` 存在 Bool 时，完整尊重该值。
2. 没有新键，旧键 `InfoSection.<key>` 为 `false` 时，保留旧折叠选择。
3. 旧键缺失或为 `true` 时，采用本轮观察基线。

只在明确设置 / 切换展开状态时写入新键；构造分区、打开新窗口不产生偏好。旧键不删除、不覆写。Info、Inspector 与 Summary 共用同名分区偏好，新打开或重建的窗口读取最近选择；已经打开的其他窗口不被强制同步折叠。

这是有意的一次兼容性取舍：**旧版本里主动展开但只保存为旧 `true` 的选择也会采用新基线**，因为旧格式没有区分依据。用户本轮或之后再次主动展开后，会以新键明确保存，不再被迁移规则覆盖。不能声称所有历史手动展开都能无损保留。

## 验证状态

本轮 Dock 与后续输入法调整之前的截图阶段，组合源码完整 smoke **连续三轮通过，每轮 2,024 项**，三次均 exit 0、stderr 为空；这是包含 Info 折叠回归的组合套件总数。后续 Dock / 输入法调整阶段的最终结果见 [Dock 研究记录](dock-menu.md)。

`InfoDisclosureSmokeTests.swift` 使用隔离的 UserDefaults suite 与临时文件，覆盖缺省值、旧自动 `true`、旧 `false`、新显式 `true` / `false` 优先级、初始化不写偏好、展开与折叠后重开、真实 Info / Inspector / Summary 的分区构建和跨窗口记忆。主 smoke 中相应 fixture 已改用新显式键，并在测试开始时隔离、结束时恢复旧键和新键，避免已有选择影响结果或测试改写用户偏好。

Finder 的实际状态已有上述辅助功能证据。Tursora 在该截图阶段的 release 包构建通过，日志为 `/private/tmp/tursora-tabs-appearance-verification/release-final.log`；根任务确认 strict codesign、Info.plist lint 和包内图标一致性检查通过。实际打开 `Brief.md Info`，原生辅助功能树确认 General 与 Preview 展开，More Info、Name & Extension、Comments、Open with、Sharing & Permissions 折叠，窗口中可见该 Markdown 文件的正文片段。

手动切换后重开记忆本轮没有单独完成实机验证，证据限于上述自动化测试。原始暗色 Info 截图因角区估计残差被透明处理工具拒绝，没有发布 PNG；本节使用实际辅助功能状态，不用其他图片替代，见[拒绝案例](screenshot-transparency.md#本轮素材与验证)。以上为 2,024 项阶段发布包的原生观察，后续 Dock / 输入法调整后的最终验证另行记录。

# Finder 压缩与解压对照（2026-09-12）

实机：macOS 26.3（25D125）。范围是普通 ZIP 压缩与解压；密码、Apple Archive、CPIO、分卷包不在本次实现中。

## Finder 本机资源证据

提取命令：

```sh
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/Localizable.strings
```

`MenuBar.nib` 中有 `Compress` → `cmdArchive:`；还有单独的密码压缩命令，本次不实现。

`LocalizableMerged.strings`：

| Key | 英文值 |
| --- | --- |
| `N168_V1` | `Compress` |
| `N168_V2` | `Compress “^1”` |
| `N168_V3` | `Compress ^0 Items` |
| `AR40` | `Archive` |
| `CO2` | `Zip archive` |
| `CO3` | `Apple Archive` |
| `CO4` | `CPIO archive` |
| `CO5` | `CPGZ archive` |

Apple 的[压缩与解压说明](https://support.apple.com/en-ie/guide/mac-help/mchlp2528/mac)描述了右键压缩、单项名称加 `.zip`、多项 `Archive.zip`，以及双击 ZIP 解压。Tursora 的显式 `Extract` 菜单是为了让应用内操作可发现；未从上述 Finder 资源提取到对应菜单文案，不宣称这是 Finder 的同名菜单。

## 系统工具证据与实现边界

本机 `man ditto` 的示例明确用 `-c -k --sequesterRsrc --keepParent` 对照 Finder 压缩。Tursora 先将选择项复制到独占工作目录，再对工作目录内容使用 `-c -k --rsrc --sequesterRsrc`，因此 ZIP 根目录直接包含所选项，不额外套一层临时目录。

本机 `/usr/bin/tar --version`：`bsdtar 3.5.3 - libarchive 3.7.4`。`man bsdtar` 的 `SECURITY` 和 `-P` 段说明：默认去掉绝对路径的开头斜线、拒绝含 `..` 的条目、拒绝经中间符号链接写入其他目录。实现不使用关闭这些保护的 `-P` 或 `-U`。解压根目录始终全新；失败时丢弃整棵工作树，不将部分结果合并到用户目录。

`--no-same-owner`、`--no-same-permissions`、`--no-acls`、`--no-fflags` 限制所有者和权限恢复；`--mac-metadata` 保留 ZIP 的 AppleDouble 资源叉。实机对照证实：只传 `--xattrs` 不能恢复资源叉，必须有 `--mac-metadata`。已用带资源叉和执行权限的文件完成往返验证。下载 ZIP 的 quarantine 会额外传递给解压产物，遍历及设置属性不跟随符号链接。

标准输入为 `/dev/null` **不足以**阻止密码询问：工具可能打开 `/dev/tty`。[libarchive 的 `tar/read.c`](https://raw.githubusercontent.com/libarchive/libarchive/master/tar/read.c) 在提供 `--passphrase` 时不安装交互回调。实现传入随机值，让加密包无提示失败；没有密码输入或密码保存功能。

只有工具成功结束后才发布结果。单一根项目直接落到目标目录；多个根项目放入压缩包名称对应的文件夹。碰撞按已有项目的数字后缀规则递增；`renamex_np(RENAME_EXCL)` 同时保证原子发布与不覆盖，包含并发请求及悬空符号链接。该发布/碰撞策略是 Tursora 的明确选择，不把尚未逐项实测的 Finder 边界当作证据。

## 自动验证

`ArchiveSmokeTests.run(completion:)` 为主 smoke suite 提供独立的 31 项模型检查：单项/多项/文件夹往返、空格/Unicode/开头短横线、同名文件/目录/悬空链接、并发发布、相对符号链接、资源叉、执行权限、quarantine、损坏/加密/空包失败、父路径与符号链接逃逸、错误后的清理和原文件保留。所有成功及失败回调另断言运行在主线程。UI 路径由主 smoke suite 覆盖。

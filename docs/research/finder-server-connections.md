# Finder 连接服务器与挂载卷

核验环境：macOS 26.3，2026-09-12。本次只核验系统资源、公开 SDK、本地卷枚举及无网络测试；用户没有提供服务器地址，因此没有连接远端，也没有声称实测各协议互通。

## Finder 的文字与资源证据

```bash
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/ConnectToWindow.nib
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
```

`ConnectToWindow.nib` 的可见文字有 `Connect to Server`、`Server Address`、`Connect`、`Favorite Servers:`、`Clear Recent Servers`；图标资源为 `NSNetwork`。`MenuBar.nib` 的 `Connect to Server` 旁关联 `rectangle.connected.to.line.below`，selector 为 `cmdConnectTo:`；推出项使用 `Eject` 和 `eject`。Tursora 的地址窗口采用前三个文字，网络卷使用 SF Symbol `network` 是自身设计选择，未声称与 Finder 的 `NSNetwork` 图形完全一致。

## 系统挂载接口

SDK 文件：`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/NetFS.framework/Versions/A/Headers/NetFS.h`。

- `NetFSMountURLAsync` 通过 NetAuth agent 挂载。传入空 mountpath 由系统选择挂载点；未提供密码时由系统询问；服务器没有指定共享目录时可由系统选择共享。
- 回调在指定 dispatch queue 上返回状态及 POSIX 挂载路径。Tursora 把这些路径转成 `file://` URL，首个路径交回发起窗口导航，其余挂载同样出现在 Locations。
- `NetFSMountURLCancel` 取消等待；SDK 明确说取消后不调用 completion。Tursora 也使用 generation 排除已经排队的旧回调。
- 正错误码为 errno，负值为 OSStatus；`-128` 表示用户取消。错误在地址窗口内显示，测试模式不允许实际网络调用或系统凭据窗口。
- WebDAV 的 `http://` / `https://` 直接进入 NetFS；绝不调用默认 URL handler，否则会打开浏览器。
- 挂载选项传入 `kNetFSOpenURLMountKey`，保留系统针对用户打开 URL 所适用的 quarantine 处理。

本机 `/System/Library/Filesystems/NetFSPlugins/` 有 `smb.bundle`、`nfs.bundle`、`http.bundle`、`afp.bundle`（另有 ftp/xpc）；`/System/Library/Filesystems/` 有对应 smbfs、nfs、webdav、afpfs。Tursora 接受 SMB（CIFS 别名归一成 SMB）、NFS、WebDAV HTTP/HTTPS、legacy AFP。协议可用性、认证方式、服务器兼容性仍由实际 macOS 版本与服务端决定；不提供 FTP、SFTP 或自实现网络协议。

Apple 的当前 [服务器连接说明](https://support.apple.com/en-gb/guide/mac-help/mchlp3015/mac) 与 [WebDAV 连接说明](https://support.apple.com/guide/mac-help/connect-disconnect-a-webdav-server-mac-mchlp1546/mac) 是协议与 Finder 操作的补充依据。网络共享挂载后使用本地路径，与 Tursora 原有文件操作、标签页、分栏、过滤及分组共用实现。

## Tursora 的实现范围

- Locations 已通过 `mountedVolumeURLs` 和 `NSWorkspace` 的 mount/unmount/rename 通知自动刷新，保留此机制；新增用 `volumeIsLocal` 区分网络卷。
- 网络卷即使没有 removable/ejectable 标记也提供 Eject；只允许卷根路径，避免对卷内的普通收藏夹意外推出整个设备。实际推出继续使用系统的 `unmountAndEjectDevice`。
- 地址要求显式协议、主机和有效端口；不接受 query/fragment 或嵌入密码。凭据留给系统，不写 Tursora 设置或日志。
- 本次没有 Finder 的服务器发现页面、常用/最近服务器管理，也没有自动重连、协议配置或离线缓存。
- 无网络 smoke 覆盖 URL 验证、远程卷分类、推出条件、窗口错误/忙碌/成功/取消，以及禁止测试环境发起真实连接；真实认证、共享选择、连接丢失、多个远程协议读写仍需有服务器时实测。

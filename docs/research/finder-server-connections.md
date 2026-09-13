# Finder Connect to Server and Mounted Volumes

Verification environment: macOS 26.3, 2026-09-12. This round only verified system resources, the public SDK, local volume enumeration and tests without a network; the user did not supply a server address, so nothing remote was connected and there is no claim of having measured interoperability over each protocol.

## Text and Resource Evidence from Finder

```bash
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/ConnectToWindow.nib
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
```

The visible text in `ConnectToWindow.nib` includes `Connect to Server`, `Server Address`, `Connect`, `Favorite Servers:` and `Clear Recent Servers`; the icon resource is `NSNetwork`. In `MenuBar.nib`, `Connect to Server` is associated with `rectangle.connected.to.line.below` and the selector `cmdConnectTo:`; the eject item uses `Eject` and `eject`. Tursora's address window adopts the first three strings, while using the SF Symbol `network` for network volumes is its own design choice and is not claimed to be identical to Finder's `NSNetwork` artwork.

## The System Mounting Interface

SDK file: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/NetFS.framework/Versions/A/Headers/NetFS.h`.

- `NetFSMountURLAsync` mounts through the NetAuth agent. Passing an empty mountpath lets the system choose the mount point; when no password is supplied the system asks for one; when the server names no share directory the system can choose the share.
- The callback returns the status and the POSIX mount paths on the specified dispatch queue. Tursora turns those paths into `file://` URLs and hands the first path back to the originating window for navigation, while the remaining mounts also show up in Locations.
- `NetFSMountURLCancel` cancels a pending mount; the SDK states explicitly that the completion is not called after a cancel. Tursora also uses a generation counter to rule out old callbacks that are already queued.
- A positive error code is an errno and a negative one an OSStatus; `-128` means the user cancelled. Errors are shown inside the address window, and test mode does not allow a real network call or a system credential window.
- WebDAV's `http://` / `https://` go straight into NetFS; the default URL handler is never invoked, since that would open a browser.
- Mount options pass `kNetFSOpenURLMountKey`, which keeps the quarantine handling the system applies to a URL the user opens.

On this machine `/System/Library/Filesystems/NetFSPlugins/` holds `smb.bundle`, `nfs.bundle`, `http.bundle` and `afp.bundle` (plus ftp/xpc); `/System/Library/Filesystems/` holds the corresponding smbfs, nfs, webdav and afpfs. Tursora accepts SMB (the CIFS alias is normalized to SMB), NFS, WebDAV HTTP/HTTPS and legacy AFP. Protocol availability, authentication methods and server compatibility are still decided by the actual macOS version and by the server; FTP, SFTP and self-implemented network protocols are not offered.

Apple's current [notes on connecting to a server](https://support.apple.com/en-gb/guide/mac-help/mchlp3015/mac) and [notes on connecting to a WebDAV server](https://support.apple.com/guide/mac-help/connect-disconnect-a-webdav-server-mac-mchlp1546/mac) are supplementary evidence for the protocols and for how Finder behaves. Once a network share is mounted it is used through a local path and shares its implementation with Tursora's existing file operations, tabs, split panes, filtering and grouping.

## The Scope of Tursora's Implementation

- Locations already refreshes automatically from `mountedVolumeURLs` and `NSWorkspace`'s mount/unmount/rename notifications, and that mechanism is kept; `volumeIsLocal` is now used to tell network volumes apart.
- A network volume offers Eject even without a removable/ejectable flag; only the volume root path is allowed, so an ordinary favourite inside the volume cannot eject the whole device by accident. The actual ejection still uses the system's `unmountAndEjectDevice`.
- An address must give an explicit protocol, a host and a valid port; a query/fragment or an embedded password is not accepted. Credentials are left to the system and are not written to Tursora's settings or logs.
- This round has no equivalent of Finder's server discovery page or its favourite/recent server management, and no automatic reconnection, protocol configuration or offline cache.
- The smoke tests without a network cover URL validation, classifying a remote volume, the conditions for Eject, the window's error / busy / success / cancel states, and the prohibition on the test environment opening a real connection; real authentication, share selection, a lost connection and reading and writing over several remote protocols still have to be measured on a real machine once a server is available.

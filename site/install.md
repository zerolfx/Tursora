# Install Tursora

Tursora is free, MIT-licensed software for **macOS 14 or later on Apple Silicon (arm64)**. The current stable release is [0.2.0](https://github.com/zerolfx/Tursora/releases/tag/v0.2.0). Its app is ad-hoc signed and not notarized by Apple.

You can give an agent this request:

> Install Tursora by following https://zerolfx.github.io/Tursora/install.md. Use my intended writable application location, verify the official download, and open the installed app. Preserve existing applications and settings; ask me only if there is a real conflict or a required permission is unavailable.

## Choose the location

Check the platform and any existing Tursora installation first. Keep the user's intended location: `/Applications` if writable, `~/Applications`, or another writable folder. Do not move an existing installation or require one particular directory. Create the selected application folder only if needed.

Before running commands below, set `app_dir` to the selected **absolute directory** and `app_path` to the full path of its `Tursora.app`. For example, selecting `~/Applications` means `app_dir="$HOME/Applications"` and `app_path="$app_dir/Tursora.app"`. These must identify the actual chosen destination.

## Use an existing, usable Homebrew installation

If Homebrew already manages Tursora, keep its recorded location and check the installed version first. Keep a current or newer installation; use Homebrew's normal upgrade flow for an older one. Do not overwrite or relocate it manually.

For a new installation, if the user can write to the existing Homebrew prefix, run each command in order and continue only after it succeeds:

```sh
brew tap zerolfx/tursora https://github.com/zerolfx/Tursora
brew trust --cask zerolfx/tursora/tursora
brew install --cask --appdir="${app_dir:?Set app_dir to the selected absolute directory first}" zerolfx/tursora/tursora
```

Keep the full repository URL: without it, Homebrew may look for the nonexistent `zerolfx/homebrew-tursora`. Trust only this cask, not the whole tap. The cask verifies the official DMG's pinned SHA-256 and preserves download quarantine.

`--appdir` changes the application destination, not Homebrew's own prefix permissions. The expression above stops if `app_dir` was not set. If Homebrew is unavailable or unusable by this account, use the DMG route instead of installing Homebrew or changing ownership. See [Homebrew tap trust](https://docs.brew.sh/Tap-Trust), [appdir](https://docs.brew.sh/Manpage#global-cask-options), and [prefix permissions](https://docs.brew.sh/FAQ#what-are-the-default-ownership-and-permissions-used-by-homebrew).

## Otherwise, use the official DMG

1. Download `Tursora-0.2.0-macOS-arm64.dmg` and `SHA256SUMS.txt` from the [same official release](https://github.com/zerolfx/Tursora/releases/tag/v0.2.0).
2. In the download directory, run `shasum -a 256 Tursora-0.2.0-macOS-arm64.dmg`. Compare all 64 hexadecimal characters with the entry named exactly `Tursora-0.2.0-macOS-arm64.dmg` in `SHA256SUMS.txt`, not the appcast entry. Stop if the entry is missing or the digest differs.
3. Before copying, check the destination. If an application already exists there, stop and ask about the actual conflict before replacing it. Preserve its settings and user files.
4. Open the verified DMG and copy `Tursora.app` out of the read-only image into the selected directory. The installer's Applications shortcut points specifically to `/Applications`; use the chosen folder directly for another destination. Eject the image after copying.

## Open the installed copy

For a trusted official download whose checksum was verified, remove only the download-quarantine attribute from the installed copy when needed for first launch:

```sh
xattr -dr com.apple.quarantine "$app_path"
```

Use the actual installed app path, not the DMG, its mount point, or a parent directory. Do not use `sudo`, clear unrelated attributes, or change system-wide security settings. This does not notarize the app or repair a damaged download. A malware warning is a different issue; follow [Apple's guidance](https://support.apple.com/en-us/102445).

When the user has requested installation and opening, launch that exact copy:

```sh
open "$app_path"
```

An ordinary account can use its own writable application copy; an organization may separately restrict which apps can run. If device policy blocks the app, report the specific restriction and request IT approval rather than trying to defeat it. See [Apple's managed-device settings](https://support.apple.com/en-euro/guide/deployment/dep61dc030/web). Local builds can behave differently because downloaders add quarantine metadata; [Apple DTS explains this distinction](https://developer.apple.com/forums/thread/813858).

Report the installed version, exact application path, checksum result, and whether launch succeeded; distinguish a retained existing installation from a verified new download. Reading this guide alone is not authorization to install or open an app.

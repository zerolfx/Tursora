<p align="center">
  <img src="app/Resources/AppIcon.png" width="112" alt="Tursora's two-pane tail-fin icon">
</p>
<h1 align="center">Tursora</h1>
<p align="center"><strong>Finder's familiar workflows. Useful ideas from Dolphin and Explorer.</strong></p>
<p align="center">
  <a href="https://github.com/zerolfx/Tursora/actions/workflows/build.yml"><img src="https://github.com/zerolfx/Tursora/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-AppKit-orange" alt="Native Swift and AppKit">
</p>
<p align="center">
  <a href="#features">Features</a> ·
  <a href="#experiments">Experiments</a> ·
  <a href="#what-finder-still-does-that-tursora-doesnt">Finder differences</a> ·
  <a href="#get-tursora">Get Tursora</a>
</p>

Tursora is a native macOS file manager built around a simple goal: **keep what feels familiar in Finder, then add the file-management ideas that make Dolphin and Windows File Explorer useful.**

That means Quick Look, macOS sharing, familiar file operations and a native AppKit interface—with Dolphin-inspired split panes, editable paths, instant filtering, recursive search and folder-specific view settings. Optional experiments add an integrated terminal and Explorer-style ZIP navigation in the same pane.

Tursora is an early project, and it does not yet cover everything Finder can do. The [differences below](#what-finder-still-does-that-tursora-doesnt) are part of the picture.

## Features

Click a screenshot to view it at full size.

<table>
  <thead>
    <tr><th align="left" width="42%">Feature</th><th align="left" width="58%">Screenshot</th></tr>
  </thead>
  <tbody>
    <tr>
      <td>
        <strong>Two folders, one workspace</strong>
        <p>Keep a source and destination side by side, each with its own editable path, history and selection. Copy or move files directly to the other pane.</p>
        <p>Click Split View or press <code>⇧⌘D</code>. <code>⌥Tab</code> switches panes; <code>⇧⌘C</code> copies to the other side.</p>
      </td>
      <td><a href="docs/images/features/split-panes.png"><img src="docs/images/features/split-panes.png" width="600" alt="Split panes with independent paths: source files on the left, delivery folder on the right"></a></td>
    </tr>
    <tr>
      <td>
        <strong>A path you can click—or type</strong>
        <p>Use either pane's breadcrumbs and folder menus, or press <code>⌘L</code> to type a path with completion. Back and Forward include history menus.</p>
        <p>Navigation stays in its pane. Switching panes or tabs dismisses an unfinished path edit without submitting it.</p>
      </td>
      <td><a href="docs/images/features/path-navigation.png"><img src="docs/images/features/path-navigation.png" width="600" alt="Editable address bar with folder completion"></a></td>
    </tr>
    <tr>
      <td>
        <strong>Open a favorite where you need it</strong>
        <p>Right-click a Favorite to open it in a new tab or the other pane. <strong>Open in Other Pane</strong> creates a split when needed, keeping the original folder in place.</p>
      </td>
      <td><a href="docs/images/features/favorites.png"><img src="docs/images/features/favorites.png" width="600" alt="The Favorites sidebar beside a split workspace in light appearance"></a></td>
    </tr>
    <tr>
      <td>
        <strong>Find a name without leaving the folder</strong>
        <p>Press <code>⌘F</code> and type part of a filename or a pattern such as <code>*.png</code>. The active folder filters immediately; other panes stay unchanged. Escape clears the filter, and its shortcut is configurable.</p>
        <p><strong>Typing first filters the current folder.</strong> Search Options appears after you type and expands recursive search conditions.</p>
      </td>
      <td><a href="docs/images/features/name-filter.png"><img src="docs/images/features/name-filter.png" width="600" alt="The active pane filtered by filename while the destination remains visible"></a></td>
    </tr>
    <tr>
      <td>
        <strong>Search across folders, then save the search</strong>
        <p>Choose Search Options or press <code>⇧⌘F</code>. Keep editing the same toolbar field to search subfolders or Home by filename, content, type and modification date. Search runs after a typing pause or on Return. Save named searches for later; each pane keeps its own query, cancellation and results.</p>
        <p>Name search works in unindexed folders. Content search depends on Spotlight's index and supported formats. Results retain their original locations and support file commands, Quick Look and Reveal in Enclosing Folder. ZIP contents are excluded.</p>
      </td>
      <td><a href="docs/images/features/search.png"><img src="docs/images/features/search.png" width="600" alt="Recursive search results with original locations"></a></td>
    </tr>
    <tr>
      <td>
        <strong>A view that fits your files</strong>
        <p>Browse expandable lists or thumbnail grids; group, sort and zoom with the slider, a pinch or <code>⌘</code>-scroll. <code>⌥⌘1</code> and <code>⌥⌘2</code> switch views. Folders remember their view, sorting, zoom, groups, hidden files and previews across restarts.</p>
        <p><strong>View → Folder View Settings</strong> chooses per-folder memory or one shared view, saves defaults and resets a folder. Memory uses Tursora's own path-based library, including for read-only folders. Existing panes pick up per-folder changes when revisited; renamed or moved folders use the new path's settings. ZIP views start from defaults and stay temporary. Search inherits the pane's view, keeps changes temporary, and restores the folder's saved view on closing.</p>
      </td>
      <td><a href="docs/images/features/folder-views.png"><img src="docs/images/features/folder-views.png" width="600" alt="Folder-specific icon grouping and list settings restored after restarting the app"></a></td>
    </tr>
    <tr>
      <td>
        <strong>Everyday operations, with a way back</strong>
        <p>Copy, cut, paste, rename, duplicate, drag or move files to Trash, with undo and redo for supported operations. Conflicts offer Keep Both, Skip, Replace or Merge where applicable, including batch choices.</p>
        <p><strong>Window → File Operations</strong> shows independent copy, move and duplicate tasks with pause, resume, cancel, transferred bytes, speed and remaining time. Each task handles its own conflicts; Replace preserves the old destination until the new copy completes. Preparation, atomic moves and finishing show their phase without a byte-based ETA. Undo recovery uses disk space while retained in the window's history.</p>
      </td>
      <td>
        <a href="docs/images/features/file-operation-tasks.png"><img src="docs/images/features/file-operation-tasks.png" width="600" alt="Independent file operations, with one paused and another transferring"></a>
        <br>
        <a href="docs/images/features/file-operations.png"><img src="docs/images/features/file-operations.png" width="600" alt="A real filename conflict with choices for handling the move"></a>
      </td>
    </tr>
    <tr>
      <td>
        <strong>Compress a selection. Extract beside the original.</strong>
        <p>Create a ZIP from selected files, or extract one beside the original. Numbered names avoid overwrites; both actions support undo. Opening a ZIP extracts it by default, unless <a href="#browse-zips-like-folders">ZIP browsing</a> is enabled.</p>
        <p>Supports ordinary ZIP archives. Password-protected ZIPs and other archive formats are not supported.</p>
      </td>
      <td><a href="docs/images/features/compress-extract.png"><img src="docs/images/features/compress-extract.png" width="600" alt="The More menu exposing archive actions for a selected ZIP"></a></td>
    </tr>
    <tr>
      <td>
        <strong>Local folders and system-mounted servers</strong>
        <p><code>⌘K</code> opens Connect to Server for SMB, NFS, WebDAV and legacy AFP. macOS handles authentication and mounting; volumes appear under Locations and disconnect with Eject.</p>
        <p>The screenshot shows the connection interface. <strong>Real-server interoperability still needs testing.</strong> There is no custom SFTP/FTP backend, server discovery or automatic reconnection.</p>
      </td>
      <td><a href="docs/images/features/connect-server.png"><img src="docs/images/features/connect-server.png" width="600" alt="Connect to Server with an example SMB address"></a></td>
    </tr>
    <tr>
      <td>
        <strong>macOS actions and sharing</strong>
        <p>The toolbar's More menu collects actions for the current selection. Share opens the system sharing picker, with services provided by macOS for the selected files.</p>
      </td>
      <td><a href="docs/images/features/share.png"><img src="docs/images/features/share.png" width="600" alt="The macOS sharing picker for a selected demonstration file"></a></td>
    </tr>
    <tr>
      <td>
        <strong>A few useful preferences</strong>
        <p>Choose per-folder views or a shared default, show or hide extensions, record a filtering shortcut, and enable experiments. Shortcut recording checks conflicts. Hidden extensions affect display only; renaming always shows the full filename.</p>
      </td>
      <td><a href="docs/images/features/settings.png"><img src="docs/images/features/settings.png" width="600" alt="Settings with folder view policy, extension display, shortcut recording and both experiments disabled"></a></td>
    </tr>
  </tbody>
</table>

## Experiments

Both experiments are **off by default**. Enable them in **Tursora → Settings…** (`⌘,`).

<table>
  <thead>
    <tr><th align="left" width="42%">Feature</th><th align="left" width="58%">Screenshot</th></tr>
  </thead>
  <tbody>
    <tr>
      <td>
        <strong>A terminal in your workspace</strong>
        <p>Press <code>F4</code> for an interactive <a href="https://github.com/migueldeicaza/SwiftTerm">SwiftTerm</a> terminal beneath the files. It starts in the active folder, or beside the original ZIP when browsing an archive.</p>
        <p>Navigation updates the target for <strong>Restart in Current Folder</strong> without injecting shell commands. Restarting, hiding the panel, closing the window or disabling the experiment ends its shell session.</p>
      </td>
      <td><a href="docs/images/features/terminal.png"><img src="docs/images/features/terminal.png" width="600" alt="The integrated terminal running in the same directory as the file pane"></a></td>
    </tr>
    <tr>
      <td>
        <a id="browse-zips-like-folders"></a><strong>Browse ZIPs like folders</strong>
        <p>Open a ZIP in the current pane and navigate with the address bar, Back, Forward and Up. Use split panes, list or icon views, sorting, grouping and filtering. Preview, open, share, copy or drag members into regular folders.</p>
        <p><strong>Archives are read-only.</strong> Opened files are temporary copies kept until quit; edits do not update the ZIP, so use Save As to keep them. Nested ZIPs open in the default app. Disabling the experiment restores extraction for new opens; existing archive pages stay read-only. Explicit Extract remains available on the original ZIP.</p>
      </td>
      <td><a href="docs/images/features/zip-browsing.png"><img src="docs/images/features/zip-browsing.png" width="600" alt="A ZIP folder opened in the current pane with its normal breadcrumb and read-only status"></a></td>
    </tr>
  </tbody>
</table>

## What Finder still does that Tursora doesn't

These are current gaps, not promises of complete Finder parity:

| Area | Not available in Tursora today |
|---|---|
| Views | Column view, Gallery view, a fixed preview sidebar, free icon placement |
| Search | Finder Smart Folder interoperability, Tags / rating conditions, ZIP contents |
| Organization | Batch rename, New Folder with Selection, Make Alias / Show Original, Show Package Contents |
| Trash | Browsing Trash, Put Back, emptying Trash; moving files to Trash and undoing that move are supported |
| Customization | Finder's full View Options dialog, column-layout memory and toolbar customization |
| System integration | Quick Actions, Services and FinderSync cloud status badges |
| File information | Full ACL editing, owner/group changes and recursive permission application |

**Outside the design:** file tags and Import from iPhone. These are intentionally excluded, rather than items waiting to be implemented.

Tursora currently has an English interface and does not restore tabs after quitting. See the [Finder comparison](docs/gaps/GAP-vs-FINDER.md), [Dolphin comparison](docs/gaps/GAP-vs-DOLPHIN.md) and [roadmap](docs/ROADMAP.md) for the detailed status.

## Get Tursora

Requires **macOS 14 or later**. Downloadable builds currently target **Apple Silicon** and are **ad-hoc signed, not notarized**.

- **Versioned releases:** download the application ZIP from [Releases](https://github.com/zerolfx/Tursora/releases), unzip it and move `Tursora.app` to Applications. Each release includes `SHA256SUMS.txt`; changes are recorded in the [changelog](CHANGELOG.md).
- **Development builds:** open a successful [Build workflow run](https://github.com/zerolfx/Tursora/actions/workflows/build.yml) and download its artifact ZIP. Unpack that artifact, then unpack the application ZIP inside it. Artifacts are kept for 14 days.

### Build locally

Use Apple's Command Line Tools with Swift 6.2+ and the macOS 26 SDK. The verified development setup is Swift 6.2.4 / SDK 26.2. No Xcode project is required.

```bash
git clone https://github.com/zerolfx/Tursora.git
cd Tursora/app
tools/make-app.sh
open build/Tursora.app
```

Swift Package Manager fetches the pinned SwiftTerm dependency on the first build. The packaging script assembles the complete application bundle.

### Build and release automation

**Build** runs on pushes to `main`, pull requests and manual requests. It builds the release app on macOS, validates the bundle and signature, then uploads a ZIP and SHA-256 checksum.

**Release is manual only.** In **Actions → Release → Run workflow**, select `main`, enter a new version without `v`, and optionally mark it as a prerelease. The workflow builds that exact commit, creates its version tag and publishes the application with its checksum. Existing tags are not overwritten; pushing a tag does not publish a release.

### Development and verification

```bash
cd app
swift build
for run in 1 2 3; do
  TURSORA_SMOKE_TEST=1 .build/debug/Tursora || exit 1
done
```

The in-app smoke suite exercises real models and controllers in a macOS desktop session. Run it three times before committing, then inspect the packaged application. GitHub Actions validates packaging; it does not replace those UI checks.

[Shortcuts](docs/SHORTCUTS.md) · [Specification](docs/SPEC.md) · [Architecture](docs/ARCHITECTURE.md) · [Development guide](docs/DEVELOPMENT.md) · [Changelog](CHANGELOG.md) · [Contributing rules](AGENTS.md)

The [product page](site/README.md) presents address navigation, split panes and ZIP browsing with real application screenshots. It builds into a standalone static site for local preview or hosting. Release preparation and changelog maintenance are documented in [Releasing](docs/RELEASING.md).

Tursora began with an audit of porting Dolphin and KIO to macOS. That research led to a native implementation, borrowing useful behavior rather than the entire stack. The two-pane tail-fin mark reflects those roots. [Read the original audit](docs/audit/PHASE-0-REPORT.md).

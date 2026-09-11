<p align="center">
  <img src="app/Resources/AppIcon.png" width="128" alt="Tursora — two glass panes forming an abstract tail fin">
</p>
<h1 align="center">Tursora</h1>
<p align="center"><strong>Two panes. Fewer detours. A file manager that feels at home on your Mac.</strong></p>
<p align="center">
  <a href="https://github.com/zerolfx/Tursora/actions/workflows/build.yml"><img src="https://github.com/zerolfx/Tursora/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-AppKit-orange" alt="Built with Swift and AppKit">
</p>
<p align="center">
  <a href="https://github.com/zerolfx/Tursora/releases">Releases</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="docs/SHORTCUTS.md">Keyboard shortcuts</a> ·
  <a href="docs/ROADMAP.md">Roadmap</a>
</p>

Tursora brings Dolphin's practical navigation ideas to a native macOS file manager: an editable path, independent tabs, two panes when you need them, and quick filtering that keeps you in the flow. Swift and AppKit provide the foundation, with Quick Look, system sharing, familiar file dialogs, and Finder-derived grouping and Info labels.

Work with local folders and mounted servers in a native Mac interface, then bring a terminal or archive browser into the workflow when you need one.

## Keep both sides of the job in view

Open a project in one pane and your destination in the other. Copy or move the selection across without juggling windows. Each tab can have its own split, so one workspace can compare folders while another stays simple.

- **Split on demand:** toggle with `⇧⌘D`, switch panes with `⌥Tab`, or drag a tab onto the left or right side of the content area.
- **Move across directly:** `⇧⌘C` copies to the other pane; `⇧⌘M` moves. You can also open a folder in the opposite pane.
- **Pick up where you left off:** tabs keep independent navigation history, selection, scroll position, sorting, grouping, and filters. Reopen a closed tab with `⇧⌘T`, including its split layout.

## Get to the folder, then get to the file

The address bar is both a breadcrumb and an editor. Click through folder menus, or press `⌘L` and type a path with inline completion and suggestions. Back and forward buttons have history menus; mouse side buttons and trackpad swipes work too.

Favorites keep frequent destinations nearby, with drag reordering and mounted volumes in the sidebar. To narrow a busy folder, press `⌘F` (customizable in Settings) and type a name or a pattern such as `*.swift`. Filtering is immediate, ignores case, and belongs to the active pane. Escape clears it.

**Filtering works within the current folder.** Recursive search, file-content search, and advanced search conditions are not implemented yet. [See the Dolphin comparison](docs/research/dolphin-filter-search.md).

## Choose the view that fits the work

| Working with… | Tursora gives you… |
|---|---|
| Deep folder trees | A details list with folders that expand in place |
| Images and visual assets | An icon grid with Quick Look thumbnails and multiple zoom levels |
| A crowded directory | Groups by name, kind, application, size, or dates, with sticky group headings |
| Files you need to inspect | Space for Quick Look; `⌘I` for Info; `⌥⌘I` for an Inspector that follows the selection |
| A folder changing in another app | Live refresh that preserves selection and scroll position where possible |

Switch views with `⌥⌘1` / `⌥⌘2`. Zoom with the status-bar slider, `⌘+` / `⌘−`, a pinch, or `⌘`-scroll. Preferences for each view mode carry into new panes.

## Everyday operations, close at hand

Copy, cut, paste, duplicate, rename, move to Trash, and drag between folders. File operations integrate with undo and redo. When names collide, choose Keep Both, Skip, Replace, or Merge where applicable, and apply the choice to the remaining batch.

**Compress and extract ZIPs:** create an archive from one file or a selection, then extract beside the original ZIP. Existing files are kept intact with numbered output names, and both operations support undo. By default, opening a ZIP extracts it; an optional archive browser lets you inspect it first. Passwords and other archive formats are not supported yet.

**Connect to your server:** `⌘K` opens Connect to Server for SMB, NFS, WebDAV, and legacy AFP. macOS handles authentication and mounting; the volume appears in Locations and works with the same panes and file operations. Eject disconnects it when you are finished.

The toolbar's **More** menu gathers common file actions and adapts to the active pane's selection. **Share** opens the macOS sharing picker for selected files; you choose the service and destination. Get Info includes metadata, previews, comments, default applications, and permissions.

## Make it yours

Open **Settings** with `⌘,` to choose a name-filter shortcut and show or hide filename extensions. Display preferences apply across your panes; rename always exposes the complete filename.

Two experiments are available in Settings, **both off by default**:

- **A terminal where you work.** Enable Terminal panel, then press `F4` to open an interactive terminal at the bottom of the window. It starts in the active folder and supports your shell and terminal programs through [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Browsing elsewhere updates the destination for **Restart in Current Folder**; it never sends `cd` into a running command. Restart ends the current shell and command. Hiding the panel, closing the window, or turning the experiment off ends its session too.
- **Look inside a ZIP.** Enable Browse ZIP archives to open ZIPs in a separate, read-only browser. Navigate folders and open contained files in their usual apps. Opened files are temporary copies, kept until Tursora quits; edits do not update the ZIP, so use **Save As** to keep them. Explicit **Extract** remains available.

## Get started

**Run:** macOS 14 or later. Downloadable builds currently target **Apple Silicon**.

Download a versioned application ZIP from [Releases](https://github.com/zerolfx/Tursora/releases), when available, unzip it, and move `Tursora.app` to Applications. Builds are currently ad-hoc signed and are not notarized. Development snapshots are available under a successful [Build workflow](https://github.com/zerolfx/Tursora/actions/workflows/build.yml) run's **Artifacts** section; they do not create a release.

To build locally, install Apple's Command Line Tools with Swift 6.2+ and the macOS 26 SDK (tested with Swift 6.2.4 / SDK 26.2):

```bash
git clone https://github.com/zerolfx/Tursora.git
cd Tursora/app
tools/make-app.sh
open build/Tursora.app
```

An Xcode project is not required. Swift Package Manager fetches the pinned SwiftTerm dependency on the first build; the packaging script produces the complete application bundle.

## Deliberately focused

Tursora is an early native file-manager project. **Tags and “Import from iPhone” are intentionally outside its design.** Tabs are supported; file tagging is not. Custom remote backends such as SFTP, recursive search, session restoration, localization, and broader preference customization remain future work. Server connections use system mounts; real server interoperability still needs field testing. The [roadmap](docs/ROADMAP.md) and [parity lists](docs/gaps/) distinguish shipped behavior from plans.

Tursora began with an audit of bringing Dolphin and KIO to macOS. That research led to a native implementation focused on the navigation behaviors that make Dolphin useful. The two-pane tail-fin mark reflects those roots. [Read the original audit](docs/audit/PHASE-0-REPORT.md).

## Build and release automation

- **Build:** runs for pushes to `main`, pull requests, or a manual request. Builds the release bundle on macOS, verifies its signature and property list, and uploads a ZIP plus SHA-256 checksum. Artifacts expire after 14 days.
- **Release:** manual only. In **Actions → Release → Run workflow**, choose `main`, enter a new version without `v` (for example `0.1.0`), and optionally mark it as a prerelease. It builds the exact selected commit, uploads the application and checksum, creates `v<version>`, and publishes generated release notes. Existing tags are never overwritten. Pushing a tag does not publish anything automatically.

These workflows verify packaging; the interactive AppKit smoke suite is run separately in a macOS desktop session before committing. No signing certificate is required for the current ad-hoc builds.

## Develop with confidence

```bash
cd app
swift build
for run in 1 2 3; do
  TURSORA_SMOKE_TEST=1 .build/debug/Tursora || exit 1
done
```

The in-app suite exercises real models and controllers: navigation, file operations and undo, both views, tabs and splits, filtering and grouping, Info windows, settings, archive handling, terminal lifecycle helpers, and UI regressions. Keep all three runs green before committing. See [the development guide](docs/DEVELOPMENT.md) for AppKit pitfalls and release checks.

| Learn more | |
|---|---|
| [Feature specification](docs/SPEC.md) | Exact behavior and Finder / Dolphin influences (中文) |
| [Shortcuts](docs/SHORTCUTS.md) | Every shortcut, menu command, and gesture |
| [Architecture](docs/ARCHITECTURE.md) | Controllers, data flow, filesystem operations, and refresh |
| [Decisions](docs/DECISIONS.md) | Trade-offs and intentional differences (中文) |
| [Handoff](docs/HANDOFF.md) | Current status and verification coverage (中文) |
| [Changelog](CHANGELOG.md) | What changed |

Contributions should follow [AGENTS.md](AGENTS.md), add regression coverage, and keep the specification current. Start with an issue for larger changes so the scope stays focused.

# Changelog

User-visible changes are recorded here. Add changes under Unreleased, then move them into a dated version section when publishing. GitHub release notes are generated from that version's section.

## [Unreleased]

## [0.2.1] - 2026-09-13

### Improved

- The zsh terminal follows the active folder, tab or pane, including while hidden. Running commands, shell reads and unfinished input defer directory changes until a safe prompt. Other custom shells retain manual restart in the current folder.
- A compact terminal header keeps restart and hide controls and removes the permanent Started in / Restart in rows. Hiding retains the shell and jobs; restarting, closing or quitting still asks before ending active jobs.
- Removed terminal status, task counts and available disk capacity from the bottom bar, leaving space for file counts, context and zoom.

### Documentation

- The website opens in English and offers a visible English / 中文 switch. Product descriptions use direct language and keep installation easy to find.
- Installation guidance supports any writable destination, makes the targeted first-launch quarantine command visible, and adds a ready-to-paste agent instruction linked to the website's complete Markdown installation guide.
- Homebrew installation now presents tap setup, explicit trust for the Tursora cask and installation together in one three-command block in README and the website; the Homebrew workflow follows the same sequence.
- Screenshot instructions require moving the mouse pointer outside the captured window and inspecting for hover artifacts. Removed the obsolete handoff document and updated documentation entry points.

## [0.2.0] - 2026-09-13

### Improved

- Hiding the terminal with its toolbar button, F4 or panel close button retains the shell, output and running jobs. Turning off terminal access in Settings also hides and retains existing sessions; showing them again resumes the same session.
- Quitting, closing a terminal's window or restarting checks foreground, background and stopped jobs before stopping them. Confirmation defaults to Cancel, including when activity cannot be established; cancelling quit leaves terminals, transfers and the workspace running. Sessions still do not survive application quit.
- Installation instructions now appear near the top of the README. The product page has prominent installation-guide links that jump to DMG steps, a real installer screenshot and Homebrew commands.
- Narrow split panes keep stable breadcrumb controls instead of repeatedly rebuilding the overflow button. Folder-tree accessibility queries leave collapsed directories unopened, and selection stays visible after resizing.
- Terminal font-size edits also apply when leaving the field with Tab; the Folders tree follows macOS temporary-directory aliases through their real system ancestors without enabling unrelated hidden folders.
- Terminal access and ZIP browsing are enabled by default while preserving saved opt-outs. Settings explains lazy terminal startup and explicit ZIP extraction.
- ZIP opening shows progress and cancellation, shares preparation across panes, and cancels unused workers before cleaning temporary files. Failed opens can retry or open the enclosing folder, including restored tabs; startup titles retain their requested names and retry handles system path aliases. Disappearing temporary members no longer break the whole listing.
- Terminal headers distinguish startup and reported shell folders, show the restart destination, preserve exit/failure status through navigation, and reject stale directory reports from previous sessions.

### Added

- A clickable Terminal status at the bottom right of the current tab, showing the window's retained session and detected task count even while hidden. Narrow panes retain an icon and explanatory tooltip; displaying status never starts a shell.
- Searchable customization for every application-command shortcut, including unassigned menu commands and file/window alternatives, with conflict explanations, clear/reset controls and existing Filter-binding migration.
- Terminal settings for the default/custom shell, installed monospaced fonts, font size and system/dark/light/custom colors. Font and color edits update open terminals without restarting their shells; shell selection applies on the next start.
- A toolbar button to show or hide the window's terminal, with a matching overflow action and current shortcut hint.
- A separate Folders tree below Favorites and Locations, with active-pane following, lazy directory loading, hidden/Home options, other-pane navigation and restored panel layout.
- The MIT project license and prominent free/open-source README and website copy; a checksum-pinned Homebrew cask in the project's own tap, with release-generation and installation checks.
- A build-time transparency check for all canonical README/site screenshots and conservative measured-edge recovery for native rounded corners next to colored system indicators.
- Workspace restoration on launch, enabled by default: reopen windows, ordered and named tabs, split panes, active locations and layout, and rerun existing search requests. General settings can disable restoration and clear the saved workspace; saving failures appear inline with a retry action. Navigation history, filters, selection, terminal sessions, transfers and undo are not restored.
- Software updates through Sparkle, with a manual Check for Updates command and a dedicated Updates settings page. Daily automatic checks default on and can be disabled; automatic download and installation is a separate option that defaults off.
- Signed update DMGs and a stable-release appcast carrying their signatures, published alongside release assets.
- Direct DMG downloads with a two-icon Tursora → Applications installer window and arrow background; automated packaging checks the mounted app, signature and layout.
- First-launch instructions for current unnotarized builds, with Apple's per-app approval steps and an optional quarantine command limited to trusted, checksum-verified downloads.
- GitHub Pages deployment workflow for the Chinese product page, with pull-request validation and a public latest-release download link.

## [0.1.0] - 2026-09-12

First release of Tursora, a native macOS file manager built with Swift and AppKit.

### Added

- Independent split panes with editable paths, completion, history, tabs and tab context actions.
- List and icon views with grouping, sorting, zoom, previews and per-folder view settings.
- Immediate filename filtering and expandable recursive search by name, content, type and modification date; saved searches and independent queries in each pane.
- File operations with undo/redo, conflict handling and a task window for pausing, resuming or cancelling transfers.
- Quick Look, Get Info, selection-following Inspector, Favorites, macOS sharing and Connect to Server.
- ZIP compression and extraction, plus optional read-only ZIP browsing and an integrated terminal; both experiments are disabled by default.
- Dock shortcuts for New Window, Downloads and Applications, opening fresh windows without changing existing panes.

### Improved

- Safari-inspired tab appearance with centered titles, hover close controls, scrolling and an overflow menu; adaptive Light/Dark surfaces throughout the interface.
- Split tab titles use `Left | Right`; file and sidebar menus keep navigation inside Tursora.
- Readable leading text excerpts in file icons, with bounded reads and protection against outdated thumbnail requests.
- Get Info initially expands General and Preview and remembers explicit disclosure choices.
- One toolbar search field: filter the current folder first, then expand Search Options for subfolders and additional conditions. Typing pauses run the query; Return runs it immediately. Confirming Chinese input candidates also triggers the query without duplicate submissions.
- README feature tables and actual application screenshots with transparent window corners, preserving decoded interior pixels.

### Requirements and limits

- macOS 14 or later. The downloadable application targets Apple Silicon and is ad-hoc signed, not notarized.
- Content search uses Spotlight's existing index; unsupported, unindexed or excluded content may not appear. Filename search works without Spotlight.
- ZIP browsing is read-only. Column/Gallery views, Finder Smart Folder interoperability, full ACL editing and session restoration are not yet available.

## Development history

Earlier implementation notes and historical verification counts are preserved in [Development history](docs/DEVELOPMENT_HISTORY.md). Use the [documentation index](docs/README.md) to find feature-specific verification and remaining limits.

[Unreleased]: https://github.com/zerolfx/Tursora/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/zerolfx/Tursora/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/zerolfx/Tursora/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/zerolfx/Tursora/releases/tag/v0.1.0

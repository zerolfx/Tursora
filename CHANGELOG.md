# Changelog

User-visible changes are recorded here. Add changes under Unreleased, then move them into a dated version section when publishing. GitHub release notes are generated from that version's section.

## [Unreleased]

### Added

- Software updates through Sparkle, with a manual Check for Updates command and a dedicated Updates settings page. Daily automatic checks default on and can be disabled; automatic download and installation is a separate option that defaults off.
- Signed update DMGs and a stable-release appcast carrying their signatures, published alongside release assets. The original 0.1.0 application requires one manual upgrade to gain the updater.
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

Earlier implementation notes and historical verification counts are preserved in [Development history](docs/DEVELOPMENT_HISTORY.md). Current verification and remaining limits are tracked in [Handoff](docs/HANDOFF.md).

[Unreleased]: https://github.com/zerolfx/Tursora/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/zerolfx/Tursora/releases/tag/v0.1.0

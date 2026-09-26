# Changelog

User-visible changes are recorded here. Add changes under Unreleased, then move them into a dated version section when publishing. GitHub release notes are generated from that version's section.

## [Unreleased]

### Fixed

- Renaming one file, including Undo and Redo, refuses to overwrite an existing item. Case-only renames still work.
- Moving several items to Trash keeps Undo and Put Back for the items that succeeded even when another item fails.
- Dragging or sharing a folder from a ZIP reports unreadable members instead of delivering an incomplete folder as a successful export.
- Unicode names in large ZIP listings retain characters that cross a read boundary.
- A directory that can no longer be read clears its old file rows in every view.

### Changed

- Address-bar completion runs off the main thread, reuses recent directory listings and ignores results from an editor session that has already changed.
- Browser file commands and undo are separated from archive reads and navigation. Smoke tests isolate application preferences, flush fixture stores before cleanup and wait for folder-tree work before asserting inactivity.
- Smoke verification removes duplicated status, search and archive work, groups large parameter matrices without dropping their inputs, and reports actual assertion totals separately from result lines with timings for each suite.

## [0.5.0] - 2026-09-25

### Added

- **Extracting a ZIP** now appears in **File Operations** with a real progress bar and a **Cancel** button, instead of a small spinner you could not stop. Each selected archive gets its own row; cancelling one stops the rest, and closing the window cancels the extraction just as it does a copy.
- Dragging an item out of a ZIP, or sharing it, now works whether or not it has been extracted: Finder receives the file, folder or application whole once it is extracted, and another Tursora pane copies it directly. Apps that only take file paths, such as Terminal, still need the item to be extracted first.
- Thumbnails inside a ZIP no longer need the folder to be extracted: the files on screen are read out of the archive together for their previews and then removed, and scrolling away from a page stops its thumbnails being fetched.
- Inside a ZIP, Quick Look opens straight away and shows the file as soon as it is extracted, and the column view's preview column says it is preparing instead of staying blank. A file over 64 MB is previewed only when you click **Show Preview**.
- Inside a ZIP, **Open**, **Open With**, **Quick Look** and **Copy** work on any item, including one reached through a link into a folder you have not opened. Several files opened together are extracted in one go. **Reload** (⌘R) tries again a file that could not be extracted.
- **Settings ▸ Shortcuts** gains a File View command, **Open Selection (Alternative)**, which ships with no key. Give it Return and Return opens the selection — entering a folder, launching a file — instead of renaming it, the way Windows Explorer and Dolphin behave. Clear Rename's Return first, since a key has one owner; Rename stays available from File ▸ Rename, the context menu and the slow double-click.

### Changed

- **Opening a ZIP no longer extracts it.** The archive is read and its structure shown straight away. Entering a folder in a ZIP no longer reads its files either: a file is read when you open, preview, copy, drag or share it, and small folders fetch theirs in the background while you look at them. A large archive that used to take seconds to open now lists almost immediately, and browsing one folder no longer writes the whole archive to disk. Applications and multi-file documents inside an archive are still brought in whole, so they open correctly.
- A ZIP that mixes ordinary files with password-protected or damaged ones now opens, showing the files that are intact. It used to refuse to open at all, and a damaged file is never shown with broken contents.
- **A password-protected ZIP is now refused by name** when you try to browse or extract it, instead of failing part way through with a generic message.
- A ZIP that is too large for the free space on your startup volume is refused before anything is written, and a damaged ZIP now reports what went wrong instead of appearing to be an empty archive.
- Inside a ZIP, **Kind** now reads as it will once the file is extracted — a command-line tool is a "Unix Executable File", not a "Document" — and an application shows the size of everything it holds. Date Created is the archive's own date, and Date Added and Date Last Opened show "--", since neither has happened to a file that is still in the archive.
- A ZIP holding two names your Mac treats as one, such as `Report.txt` and `report.txt`, now shows one file — the one extracting it would leave — instead of two rows for a single file.
- With **Terminal panel** turned off in Settings, the Terminal button is now gone from the toolbar instead of sitting there permanently greyed out. View → Show Terminal already hid itself on that setting; the toolbar now agrees with it. Turning the setting back on returns the button to its place, and a panel you had open is still there waiting.
- Settings ▸ Terminal no longer accepts changes while the Terminal panel is turned off, since nothing there could apply. The page still shows your saved shell, font and colours, with a line naming the option that hands it back.
- **New Folder** now opens the new folder's name for editing, as Finder does, so you can type the name straight away instead of renaming afterwards. It works in the list, icon and column views; press Escape to keep "untitled folder". If a filter is active that the new folder would not match, the filter is cleared so the folder you just made is actually on screen.

### Fixed

- **Browsing ZIPs no longer piles up temporary files until you quit.** A ZIP's temporary copy is removed about a minute after you stop browsing it. Files you opened in another app, copied, dragged or shared out get their own copy, which is kept until you quit, so the app using them keeps working. Going Back to the ZIP, or reopening its tab, opens it again from where it is — so if you have moved or deleted the ZIP since, Back reports that instead. In the Quick Look panel a folder inside a ZIP now shows as its name only.
- Temporary ZIP staging left behind by a crash is cleaned up at the next launch. It is removed only when no running copy of Tursora still holds it, so a second window or a second copy of the app is never disturbed.
- **Group by Application** inside a ZIP put every file under "No Application". Files are now grouped under the application that would open them.
- **Copying a folder out of a ZIP now copies all of it.** Copy to Other Pane, or Copy and Paste, used to bring only the subfolders you had already opened; the rest arrived as empty folders. Anything that has to be left out, such as a password-protected file, is now listed when the copy finishes.
- Copying, opening or Quick Look on an item in a ZIP no longer freezes the window while the item is extracted; it happens in the background, and a large one appears in File Operations where it can be cancelled.
- An inline rename is no longer broken by a directory listing arriving underneath it. Previously an external change landing at the wrong moment could commit a half-typed name; the edit is now carried across the refresh with what you typed still in it.

## [0.4.3] - 2026-09-17

### Fixed

- Column view no longer loses a filename when the column is too narrow for it. The name simply vanished, leaving the icon alone: a filename is one unbreakable word, the cell wrapped it onto a second line, and only the first line was drawn. Names now truncate in the middle, as they do in list view.
- **Set Tursora as Default** now says why it cannot work instead of failing with "The file couldn't be opened." macOS will not register an application running from a temporary or read-only location — which is what an app opened straight from a downloaded disk image is — so the setting explains that and asks you to move Tursora to your Applications folder, and the button is disabled until you do.

### Changed

- Buttons in Settings are button-sized again instead of stretching the full width of the pane.

## [0.4.2] - 2026-09-17

### Fixed

- Column view rows show their icons. The 0.4.1 fix for this did not work in the shipped application: the row also set an accessibility value, and on a cell owned by the column browser that writes through and replaces the styled text the icon lives in, so every row lost its icon again. The name is still read correctly by VoiceOver.

## [0.4.1] - 2026-09-16

### Added

- **Settings ▸ General ▸ Opening folders**: a button that makes Tursora the application macOS opens folders with, so `open .` in a terminal, a folder dropped on the Dock icon, and any application that asks the system to open a folder all land in Tursora. The line above it says which application holds the role today, and the button is disabled once Tursora holds it. macOS puts up its own confirmation; nothing is written to LaunchServices behind your back. Note that "Reveal in Finder" in other applications is a Finder-specific call and still opens Finder.

### Fixed

- Column view rows show a file's icon again. They had been drawing the name alone, ignoring the "Show all filename extensions" setting, and not dimming a cut file. Typing a letter to jump to a row works again, and a row now reads its own name to VoiceOver.
- Column view previews every kind of file, not only the ones it rendered itself. A selected PDF, image, video or document showed an empty last column; Quick Look's view was being handed a frame with no height.
- Going Back now returns you to where you were in the folder, not to the top of it. Opening a subfolder from halfway down a long list and coming back used to leave the scroll position wherever the restored selection happened to fall. Coming back to a folder you had filtered still shows the item you opened, rather than jumping to the top.
- Renaming in column view keeps the extension. `Return` on `photo.jpg` preselected the whole name, so typing a word replaced the extension too; it now preselects only `photo`, as the list and icon views already did.
- Cutting a file in column view dims its icon as well as its name, matching the other two views.
- Reopening the preview pane on the same file shows it again instead of a blank pane.

## [0.4.0] - 2026-09-16

### Added

- Search can now look inside files that macOS has not indexed. A new **Using** setting beside the Content field chooses between **Spotlight Index**, which is fast but only sees indexed files, and **Scan Files**, which reads the files themselves — so an external drive, a network volume or a folder excluded from indexing is searched too. Scanning skips binary files and anything over 64 MB, reads the first 1 MB of each file, stops after 20,000 files, and says in the status line what it scanned and what it skipped. The setting is remembered with a saved search; existing saved searches keep using the index.
- **View ▸ as Columns** (⌥⌘3): Finder's column view. A selected folder opens its contents in the column to the right and the chain follows your selection; a selected file is previewed in the last column, with Markdown rendered. Selecting never changes the pane's location — only opening a folder does — so Back, the path bar and the terminal keep referring to the first column's folder. Columns start at Finder's width and resize by dragging; the mode and its own zoom step are remembered per folder like the other two views.
- A preview pane docked beside the file view (**View ▸ Show Preview**, ⇧⌘P). It shows the selected item, or the current folder when nothing is selected, and stays open as you navigate. Markdown is rendered as rich text — headings, lists, block quotes, fenced code, inline emphasis and GitHub tables — following your light or dark appearance; everything else falls back to Quick Look. Drag its edge to resize between 220 and 720 pt; the pane's width and whether it was open are restored with your session. Links in a rendered document are shown but not followed, and nothing a document references is loaded. The thumbnail toggle that used to hold ⇧⌘P is now ⌃⌘P.

### Changed

- Batch rename can put the number anywhere in the name. `Name Format:` is now **Number** or **Date**, and under Number the custom text is a pattern: a run of `#` becomes the sequence number and the length of the run sets the leading zeros, so `Photo ###` gives `Photo 001`. The run can sit anywhere, not only after the name — `v## final` gives `v07 final` — and a number too wide for the run is never shortened. This replaces Name and Index and Name and Counter, which were the same rule with and without padding and are both still expressible (`name #` and `name #####`). Name and Date is unchanged. Every resulting name is still previewed before you rename.
- A tab now stops growing at a browser-like width instead of stretching to the window edge, and the new-tab button sits just after the last tab rather than at the far right of an almost empty strip. The width cap gives way when a title genuinely needs more room and the strip can spare it.
- A split tab's two folder names are separated by a hairline drawn down the height of the tab instead of a `|` character in the text. Each name now truncates on its own, so a short one is no longer shortened beside a long one.

### Fixed

- Sorting by a date, size or kind now orders folders together with files instead of keeping them in a block at the top. Finder only keeps folders on top when sorting by name, and so does Tursora now; sorting by Name is unchanged.
- A finished file operation no longer shows a full progress bar and the name of the last file it handled. The row keeps its state, its byte total and its completed and skipped counts.

## [0.3.0] - 2026-09-14

### Added

- Renaming several selected items opens Finder's Rename Finder Items sheet: Replace Text, Add Text and Format (Name and Index, Name and Counter, Name and Date), with a live preview of every new name and an inline reason whenever a name is empty, illegal or already taken. Chains, swaps and case-only renames work, nothing outside the batch is ever overwritten, and the whole batch is one undo step. Available from File ▸ Rename N Items…, the More menu and the context menu, in list and icon views, split panes and search results.
- The terminal and the file views now follow each other's folder in both directions, and bash and fish join zsh in doing it automatically. Changing directory in the shell moves the window's active pane while the terminal is visible; browsing to a folder still asks the running shell to change directory. zsh applies that at an idle prompt, bash and fish at the next prompt you draw. Nothing is ever typed into the shell, no signals are sent, and your own startup files are not modified. Both directions have checkboxes in Settings → Terminal, on by default.
- A command palette (View → Command Palette…, ⇧⌘O): fuzzy search over every application command, every sidebar favourite and the active pane's back/forward history folders. ↑/↓ move, Return runs, Esc closes; unavailable commands stay listed but dimmed and refuse to run. Commands execute exactly as they do from the menu bar, and folder rows navigate the active pane.
- Sorting adds Finder's Date Created, Date Added and Date Last Opened, in View → Sort By, the context menu and by clicking a list header. Folders still come first, files with equal dates fall back to the name, and files with no date stay at the bottom whichever direction you sort in.
- The list view gains optional Date Created, Date Added and Date Last Opened columns. Right-click the column header to show or hide any of Date Modified, Date Created, Date Last Opened, Date Added, Size and Kind; each folder remembers which columns you chose.
- Folders now show how many items they hold in the Size column ("1 item", "12 items") instead of "--". Turn on "Calculate all sizes" and each folder's total size is measured in the background and fills in as it arrives; sorting by Size follows the measured values. Off by default, remembered per folder. ZIP listings and search results show item counts only.
- The Trash is now a place you can open (sidebar, Go ▸ Trash) and browse like any folder, with "Trash" shown in the status bar. New Folder, Paste, Rename, Duplicate and Compress are off inside it, as in Finder, while Copy, Quick Look, Get Info and Delete Immediately… stay available. Put Back returns an item to exactly where Tursora trashed it from, undoably; items Tursora did not trash, or whose original folder is gone or whose name has been taken, show a dimmed Put Back that says why. File ▸ Empty Trash… asks for confirmation and then erases everything; it ships without a keyboard shortcut and can be given one in Settings ▸ Shortcuts. Without Full Disk Access the Trash shows an inline banner with Open Privacy Settings and Try Again instead of an error dialog.
- Spring-loaded folders: hold a drag over a folder and it opens after the system's usual delay, in the list, the icon grid, the sidebar's places and the folder tree (which expands the node in place). It follows the same rule as a drop, so it never springs open on a file, in a ZIP archive, on the item you are dragging or on the folder those items already live in.
- Breadcrumb segments accept drops: drag files onto any folder in the path bar to move or copy them there, with the same rule and the same undo as every other drop target. The hovered segment highlights; segments folded into the "…" menu are not targets.
- ⌘-dragging now forces a move, even to another volume — ⌥ still forces a copy. Previously a ⌘-drag was simply refused. Items inside a ZIP archive stay copy-only.

### Changed

- Internal simplification without behaviour changes: removed dead code (the unused modal conflict dialog, the never-released favourites migration, unused model accessors and the unread transfer progress callback), shared the file views' zoom-gesture and backing-scale handling, the pasteboard file-URL reader, flipped document views and Settings label builders, and routed New Folder and undo moves through `FileOperations`. Context menus inside ZIP archives now also say "Open in N New Tabs" for several folders.
- The smoke suites share one `SmokeSuite` helper for checks, polling and fixtures, and `SmokeTest.run` lists its suites as a flat, ordered step table.

### Documentation

- Removed the stale handoff pointer, corrected the per-file architecture map (misplaced rows, three unlisted files, a pasted sentence), pointed the bundle version and DMG wheel pins at the scripts that own them, replaced duplicated rule, release and site sections with links, updated the terminal shortcut text, and reduced the product-site README to build and review instructions.

### Changed

- The version the project ships is now written in one place, a `VERSION` file at the repository root. The website and the installation guide take it from there when they are built, and the README links to the latest release instead of naming a version, so a release no longer edits the number into a dozen sentences.

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

[Unreleased]: https://github.com/zerolfx/Tursora/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/zerolfx/Tursora/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/zerolfx/Tursora/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/zerolfx/Tursora/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/zerolfx/Tursora/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/zerolfx/Tursora/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/zerolfx/Tursora/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/zerolfx/Tursora/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/zerolfx/Tursora/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/zerolfx/Tursora/releases/tag/v0.1.0

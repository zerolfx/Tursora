# Tursora vs Finder — feature gaps and difficulty

Compared item by item against this machine's Finder menu nibs (`Finder.app/Contents/Resources/Base.lproj/MenuBar.nib` and `ArrangeByMenu.nib`, with the menu items extracted using `strings`).
Tags and Import from iPhone are explicitly out of scope; Recents and Shared / iCloud / AirDrop are not broken out in this table for now. System server mounts are folded into the Go menu comparison.

**Difficulty** is estimated for someone familiar with AppKit, and includes the smoke test and on-device verification:
S ≤ half a day (< 100 lines, a standard API is directly usable) · M 1–2 days (100–400 lines, a new view/controller or a model change) · L 3–5 days (400–1000 lines, a new subsystem or a change across layers) · XL > 1 week (> 1000 lines, or a dependency on something with no public API).
How the estimates were made: 7 agents, one per category, estimated every item against the Tursora source (hours, lines, files to touch, APIs), then part of the list was corrected by an adversarial review (one side arguing "harder", the other "easier"); I corrected the rest on the same scale. **Bold** = frequently used and cheap to moderate.

## File menu

| Finder | Tursora | Difficulty | Notes |
|---|---|---|---|
| **Get Info** (⌘I) / Show Inspector (⌥⌘I) / Get Summary Info (⌃⌘I) | ✅ Done | — | General / Preview are expanded by default and the rest collapsed, and an explicit choice is remembered; [evidence](../research/info-disclosures.md). Not done: Stationery pad, ACLs, changing owner/group (needs elevated privileges and has no public API → counted separately as L), Apply to enclosed items |
| **Rename (a multi-selection opens the batch rename dialog)** | ✅ Done | — | Three modes — replace text / add text / format — plus a live preview; chained renames go through temporary names in two passes; for the wording evidence and what is inferred see [batch rename](../research/finder-batch-rename.md) |
| **New Folder** (⇧⌘N), with the new folder's name opened for editing | ✅ Done | — | The folder is created, selected, scrolled into view and its name opened for editing in all three views; Escape keeps "untitled folder". Sourced from Finder's own binary — `setPendingNodesToSelect:startEditing:runNewFolderAnimation:renameOp:` and the per-view `startEditing…` entry points; see [the record](../research/finder-new-folder-rename.md) for what is certain and what is inferred |
| **Undo / Redo New Folder** (Finder strings `NF1` / `NF2`) | ❌ | S | `newFolder()` registers nothing with the window's undo manager, so ⌘Z after creating a folder undoes whatever came before it. Trashing the folder is the obvious undo action, as `registerUndoTrash` already does for Extract |
| **New Folder with Selection** (⌃⌘N) | ❌ | S | createDirectory plus the existing transfer; undo has to be combined into one group |
| **Compress** / Compress with password | Plain ZIP ✅; password ❌ | M for the password | Compress / extract keep colliding names and support undo and redo; the optional read-only ZIP browsing in the current pane is enabled by default (the browsing interaction follows Windows) |
| **Make Alias** (⌃⌘A) / Show Original (⌘R) | ❌ | M | `URL.bookmarkData(options: .suitableForBookmarkFile)` plus `writeBookmarkData`; ⌘R clashes with our Reload |
| Always Open With (⌥ with Open With) | ❌ | S | `setDefaultApplication(at:toOpen:)` (already used by Change All in Get Info); the context menu has to keep the alternate pair |
| **Show Package Contents** | ❌ | S | Right-click a .app and navigate straight into the bundle directory |
| Add to Dock | ❌ | M | The only route is writing `com.apple.dock.plist` and restarting the Dock, and the format is undocumented |
| Print | ❌ | S | `NSWorkspace.open(_:withApplicationAt:configuration:)` lets the default application print it, with no receipt |
| Share… | ✅ The system share picker in the toolbar | — | Shares the files selected in the active pane; it does not send anything itself |
| Slideshow (⌥ space) | ❌ | S | `QLPreviewPanel.enterFullScreenMode`; the arrow keys currently change the selection and would have to be intercepted |
| Customize Folder (folder color/emoji, macOS 26) | ❌ | XL | The storage format is private (possibly inside the IconServices database) and unreliable |
| Copy as Pathname (⌥⌘C) | ✅ Copy Path | S | Only the shortcut needs aligning, as the ⌥ alternate of Copy |
| New Smart Folder / Burn Folder / Burn Disc | ❌ | XL | Saved searches already exist inside the app; interchange with Finder .savedSearch files and disc burning are not supported yet |
| Eject All (⌥⌘E) | ❌ | S | `unmountAndEjectDevice` one by one, which has to run in the background; partitions on the same physical disk eject together |

## Edit menu

| Finder | Tursora | Difficulty | Notes |
|---|---|---|---|
| **Move Items Here** (⌥⌘V) | ❌ | S | transfer(.move) already exists; make it the ⌥ alternate of Paste |
| Paste Exactly / Duplicate Exactly (⌥) | ❌ | M | Preserving owner and permissions needs `NSWorkspace.requestAuthorization(to: .replaceFile)`, and the asynchronous authorization has to be joined to the existing transfer queue |
| **Deselect All** (⌥⌘A) | ❌ | S | A few lines; unavailable while the sidebar or the address bar has focus (the same as Finder) |
| Show Clipboard | ❌ | M | A window listing the URLs on the clipboard, refreshed on a timer |

## View menu

| Finder | Tursora | Difficulty | Notes |
|---|---|---|---|
| **as Columns** (⌘3) | ✅ | — | `NSBrowser` in item mode with the last column previewing a file through the preview pane's renderer; bound to ⌥⌘3 because ⌘3 is tab 3. Selecting never navigates, unlike Finder (D84). Not yet looked at in a packaged build |
| as Gallery (⌘4) | ⛔ | — | Not planned: the owner excluded gallery view on 2026-09-16, along with file and folder comparison, after the Iruka comparison round |
| **Show Preview** (⇧⌘P, the preview pane on the right) | ✅ | — | A pane docked beside the file view, following the selection and surviving navigation and a quit; Markdown is rendered rather than shown as plain text, which Quick Look does not do (D81, D83). Thumbnails moved to ⌃⌘P so the pane could take Finder's key (D82) |
| **Show View Options** (⌘J, per-folder view settings) | Per-directory persistence ✅; the full Finder-style dialog ❌ | M for the dialog | The existing mode / sorting / the zoom step of each of the three views / grouping / hidden files / previews are saved per directory; View and Settings have entry points for the policy, the default and a reset. The app uses a private path store and does not write `.DS_Store`; there is no ⌘J, no column layout and no free-placement settings |
| Clean Up / Snap to Grid / free icon placement | ❌ | L | The icon view would change from a flow grid to a free layout with per-folder coordinates persisted; a drag inside NSCollectionView is currently rejected as a file drop |
| Toolbar (⌥⌘T) / Path Bar (⌥⌘P) / Status Bar (⌘/) / Tab Bar (⇧⌘T) toggles | Sidebar only | M | Simple in itself; ⇧⌘T clashes with our "reopen closed tab" |
| **Customize Toolbar…** | ❌ | M | `allowsUserCustomization = true` plus more allowed items; the delegate currently also keeps a reference to the palette's copy, which has to change |
| Show All Tabs (the tab overview) | ❌ | M | Capturing a hidden view on macOS 14 may yield an empty bitmap, so it has to be tried first |
| Increase/Decrease Icon Size | ✅ Zoom | — | |
| Enter Full Screen | ✅ System | — | |

## Go menu

The Dock already offers three entry points — New Window / Downloads / Applications — each of which opens a new window; the standard system items are still managed by macOS. The Go menu items missing below are not treated as filled in by those Dock shortcuts, see the [Dock record](../research/dock-menu.md).

| Finder | Tursora | Difficulty | Notes |
|---|---|---|---|
| **Computer / Desktop / Documents / Downloads / Applications / Utilities / Library (⌥)** | Home only | S | ⇧⌘C clashes with Copy to Other Pane and ⇧⌘D with Split View, so those have to give way first |
| **Recent Folders ▸** (including Clear Menu) | ❌ | M | Persisted across sessions; the first Home of every new tab would also be recorded and has to be filtered out |
| Go to Folder (⇧⌘G) | ✅ Starts editing in the address bar | — | Equivalent behaviour |
| Connect to Server (⌘K) | ✅ The system NetFS | History / discovery still to do | SMB, NFS, WebDAV, legacy AFP; interoperability with a real server has not been tested |

## Window menu

| Finder | Tursora | Difficulty | Notes |
|---|---|---|---|
| Move Tab to New Window / Merge All Windows | Detach Tab ✅; Merge All Windows ❌ | M for merging | The tab context menu follows Dolphin's semantics and rebuilds one or two logical locations and the search request in a new window; history, filters, tasks and the undo stack do not move with it, and no claim is made of transferring Finder's complete state. For the evidence and the verification see the [dedicated record](../research/pane-paths-and-tab-actions.md) |
| Cycle Through Windows (⌘`) | ❌ | S | There is no public cycleWindows:, so we would cycle through orderedWindows ourselves; the system-level ⌘` hotkey may swallow the key first |

## Behaviour outside the menus

| Finder | Tursora | Difficulty | Notes |
|---|---|---|---|
| **Spring-loaded folders** | ✅ | — | `NSSpringLoadingDestination` in four places: the list, the icons, the Places sidebar and the folder tree; the delay and the switch come from the system's `com.apple.springing.*`. A breadcrumb segment is a **drop target** but does not spring open; Finder's "spring open, then roll back" is not implemented ([record](../research/drag-and-drop.md)) |
| **Finder's settings window** | ✅ General / Shortcuts / Terminal / Updates | M–L for the extras | Showing extensions, shortcuts for every application command, per-directory memory / one shared default, the terminal shell / font / colors, the terminal and ZIP options that are on by default, and the update options; the trash policy, Keep folders on top and the like are not implemented |
| Show/hide file extensions plus the warning when an extension changes | The display switch ✅; the warning ❌ | M for the warning | The global switch only changes the list, icon and column labels, and ordinary folder names stay as they are; renaming, sorting and filtering keep the real name; this is not a complete copy of Finder's per-file flag policy |
| Quick Actions (Rotate / Markup / Create PDF) | ❌ | L | Finder's registry is private and Markup has no public API; only Rotate and Create PDF could be implemented ourselves |
| Context menu ▸ Services | ❌ | S | `NSApp.servicesMenu`; one NSMenu can only have a single parent menu, so the context menu needs a copy |
| Trash view (Put Back, empty) | ✅ The user trash | M for per-volume trash | Sidebar and Go menu entry points, an ordinary list with the `Trash` status context, `Empty Trash…` in Finder's wording, and our own put-back log (Finder's put-back paths live in private `.DS_Store` records, which we do not parse). Without Full Disk Access the pane shows a banner offering a jump to Settings and a retry, rather than a modal. Per-volume trash is not implemented ([record](../research/trash.md)) |
| Double-clicking a Finder alias resolves it | Following symlinks ✅; resolving a Finder alias automatically ❌ | S | The per-directory view store gains no alias resolution; later `URL(resolvingAliasFileAt:options: .withoutMounting)` could resolve the target when opening |
| FinderSync badges (cloud sync status) | ❌ | XL | Only iCloud's ubiquity keys are public; there is no public API for the badges of Dropbox and the like |
| Chinese localization | ❌ | L | Every menu and string built in code has to be extracted; the SPM resource bundle has to be findable both when launched as a .app and as a bare binary |
| Shortcuts aligned with Finder (⌘1–4, ⌘L, ⇧⌘T, ⇧⌘P, ⌘O, ⌘I) | ⌘I and ⇧⌘P ✅ | M | ⇧⌘P now opens the preview pane as it does in Finder, which moved the thumbnail toggle to ⌃⌘P (D82). The menus are rebuilt at runtime; alternates that share a key have to stay adjacent |

## Suggested order (by cost)

1. S: Deselect All, Move Items Here, aligning Copy as Pathname, New Folder with Selection, Show Package Contents, Always Open With, Print, Slideshow, Eject All, the Go menu shortcuts, Cycle Through Windows, the Services menu, alias resolution
2. M: Make Alias / Show Original, Recent Folders, the Show Preview pane, Customize Toolbar, the bar toggles, Show All Tabs, Move Tab to New Window, the warning when an extension changes, Paste Exactly, Show Clipboard, Add to Dock, a preset of Finder's default shortcuts (each one is already configurable individually)
3. L: The Date Created / Date Added / Date Last Opened sort keys and the optional list columns with folder sizes are done ([record](../research/sort-columns-folder-sizes.md); the Version / Comments / Tags columns and persisting column widths are still not implemented). ~~Column view~~ (done, D84), Gallery view, the full preference policy, free icon placement, the trash view, Quick Actions, Chinese localization, server discovery / history / reconnect; the full Show View Options dialog is listed separately as M (per-directory persistence is implemented)
4. XL / not recommended: Customize Folder, Smart Folders, FinderSync badges

## 2026-09-12 update

- [x] The toolbar's More menu with common file operations, and the system share button.
- [x] ZIP Compress / Extract, with colliding names kept, background processing and undo/redo. Passwords and other formats are not implemented.
- [x] Copy / Move / Duplicate as separate progress tasks, supporting pause / resume / cancel part way through a large transfer, a safe Replace and undo of the items that succeeded; for the verification scope and the boundary of system calls that cannot be paused see the [dedicated record](../research/file-operation-tasks.md).
- [x] Connect to Server (⌘K) and browsing / ejecting network volumes mounted by the system; interoperability with a real server has not been tested yet.
- [x] A basic settings window, the switch for showing extensions, and a customizable shortcut for the name filter.
- [x] Per-directory view memory, one shared default, saving the current settings as the default and restoring a directory's default; both the list and the icons are saved, and the full Finder view options dialog is still not implemented. For the automated and on-device verification see the [directory view verification record](../research/computer-use-2026-09-12-directory-views.md).
- [x] The terminal panel enabled by default, and the experiment with read-only ZIP browsing in the current pane; an archive supports copying / dragging out, Quick Look and sharing — each extracting only what it needs, since listing a folder extracts nothing — but not writing back.
- Tags and Import from iPhone are product boundaries that are explicitly out of scope.

## 2026-09-12 tab bar and appearance

- [x] A neutral selection level for tabs, centred titles and a close button on hover. A tab stops at a browser-like width instead of stretching to the window edge, and the add button follows the tabs when they leave the strip part-empty (D79).
- [x] Horizontal scrolling with many tabs and a text menu of all tabs; this does not replace the thumbnail overview still listed as to do in the table above.
- [x] The system light / dark appearance with the existing layer surfaces updating dynamically; [this round's verification status](../research/tabs-and-appearance.md).

## 2026-09-13 customization and the directory tree

- [x] Shortcuts for every application command are now configurable, including menu items with no binding, Return / Space and the tab alternates; conflict hints, clearing, and resetting one at a time or all at once are supported. Text editing, selection, completion and shell control still go through the native views.
- [x] The terminal shell / monospaced font / font size / theme / custom text background color, and the toolbar toggle.
- [x] The Folders tree below Places is a Dolphin-style addition; the Finder-style favorites sidebar stays, and the two kinds of navigation are not merged into one tree.
- [x] The final 3,194-check smoke test over 95 Swift sources passed three times in a row; for the scope of the delivered app / DMG, the on-device run and the screenshot verification see the [customization integration record](../research/customization-integration.md); remote CI and releases are still handled separately.

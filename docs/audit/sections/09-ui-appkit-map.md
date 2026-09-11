## UI Inventory → AppKit Replacement Map

*All paths are relative to the repo named in the heading of each block. Dolphin = `upstream/dolphin`, KIO = `upstream/kio`.*

### 0. Architectural baseline (read this before the tables)

Three facts determine everything below, and all three were verified in source:

1. **Dolphin's file view is not a `QAbstractItemView`.** It is a bespoke `QGraphicsScene` stack: `KItemListContainer : QAbstractScrollArea` (`src/kitemviews/kitemlistcontainer.h:29`) whose viewport is a private `QGraphicsView` (`src/kitemviews/kitemlistcontainer.cpp:31,68`), containing `KItemListView : QGraphicsWidget` (`src/kitemviews/kitemlistview.h:55`) which lays out `KItemListWidget : QGraphicsWidget` items (`src/kitemviews/kitemlistwidget.h:52`). Input is centralised in `KItemListController` (`src/kitemviews/kitemlistcontroller.cpp`).
2. **The model is not a `QAbstractItemModel` either.** `KFileItemModel : KItemModelBase` (`src/kitemviews/kfileitemmodel.h:45`) and `KItemModelBase : QObject` (`src/kitemviews/kitemmodelbase.h:39`). It wraps a `KDirLister` (`src/kitemviews/kfileitemmodel.h:558`). This is the *reusable* half: it is a flat, sorted, optionally tree-expanded list with a documented role table (`src/kitemviews/kfileitemmodel.cpp:3143-3190`) — a very clean feed for an `NSCollectionView`/`NSOutlineView` data source.
3. **The menu bar is hidden by default.** `setupGUI(Save | Create | ToolBar, …)` at `src/dolphinmainwindow.cpp:214`, then `menuBar()->setVisible(false)` on first run (`src/dolphinmainwindow.cpp:224`), with `KHamburgerMenu` taking over (`src/dolphinmainwindow.cpp:242-247`, built in `updateHamburgerMenu()` `src/dolphinmainwindow.cpp:1555-1640`). macOS has no hamburger idiom and *always* shows a menu bar, so the Phase 2 shell inverts Dolphin's default.

Consequence for phasing: **Phase 2 (native shell) is cheap because the shell is thin and action-driven; Phase 3 (native views) is expensive because there is no `QAbstractItemModel`/`QAbstractItemView` seam to swap out** — the whole `src/kitemviews/` tree (≈30 files) has to be replaced, not adapted.

There is precedent in-tree for platform-specific UI definitions: Dolphin already ships a second KXmlGui file, `src/dolphinuiforphones.rc`, chosen at runtime (`src/dolphinmainwindow.cpp:213-214`). A `dolphinuiformac.rc` is therefore an upstream-sanctioned mechanism, not a hack.

---

### 1. Main window chrome & shell

| Dolphin element | Class / file (Dolphin repo) | macOS replacement | Phase | Notes / risks |
|---|---|---|---|---|
| Main window | `DolphinMainWindow : KXmlGuiWindow`, `src/dolphinmainwindow.h`, `src/dolphinmainwindow.cpp:214` | `NSWindow` + `NSWindowController`; `.titlebarAppearsTransparent` + unified toolbar | 2 | `KXmlGuiWindow` brings the toolbar-editor, session save (`Save` flag) and RC merging. Dropping it means reimplementing `KActionCollection`→`NSMenu` sync by hand. |
| Toolbar | `<ToolBar name="mainToolBar">`, `src/dolphinui.rc:109-119` (back, forward, view_settings, url_navigators, split_view, split_stash, toggle_search, hamburger_menu) | `NSToolbar` with `NSToolbarItem` / `NSToolbarItemGroup`; SF Symbols for the 8 items | 2 | `url_navigators` is a `QWidgetAction` containing a `QSplitter` of up to two navigators (`src/dolphinnavigatorswidgetaction.h:39`, doc comment lines 24-38). Maps to a single flexible `NSToolbarItem` hosting the breadcrumb; the split-aligned two-navigator layout has no `NSToolbar` analogue and should be dropped in favour of one breadcrumb per split pane (see §Split view). |
| Toolbar customisation | `KStandardAction::ConfigureToolbars` (`src/dolphinmainwindow.cpp:3025`, `:1638`) | `NSToolbar` "Customize Toolbar…" sheet (free) | 2 | Straight win: AppKit gives this for free and it is more native than `KEditToolBar`. |
| Hamburger menu | `KHamburgerMenu`, `src/dolphinmainwindow.cpp:1802`, `:1555-1640` | **Delete.** Its contents already exist in the menu bar | 2 | Keep the *action set*, discard the widget. Some actions are only reachable via hamburger (`window_color_sheme` submenu, `basic_actions`) — must be re-homed into the menu bar. |
| Show/Hide Menubar (`Ctrl+M`) | `KStandardAction::showMenubar`, `src/dolphinmainwindow.cpp:2241` | **Remove the action entirely** | 2 | macOS forbids hiding the menu bar per-app. Leaving it in the shortcut editor is a bug factory. |
| Status bar | `DolphinStatusBar : AnimatedHeightWidget`, `src/statusbar/dolphinstatusbar.h:30`; disk space via `StatusBarSpaceInfo`/`SpaceInfoObserver`; zoom slider; `QProgressBar` | Finder-style status strip at the bottom of the content view: a custom `NSView` with `NSTextField` + `NSProgressIndicator`; zoom slider → `NSSlider` in the toolbar | 2 | Three modes exist (`Small` / `FullWidth` / `Disabled`, `src/settings/dolphin_generalsettings.kcfg:142-151`); the "Small" floating variant is very un-Mac. Recommend FullWidth-only on macOS. |
| Message/inline error banner | `KMessageWidget` (`src/dolphinviewcontainer.h:512`, positioned at `src/dolphinviewcontainer.cpp:62`) | Non-modal `NSView` banner, or `NSAlert` as a sheet for errors | 2 | KMessageWidget's animated slide-in is close enough to macOS banners; keep. |
| Admin ("act as admin") bar | `Admin::Bar` (`src/dolphinviewcontainer.h:502`, `src/dolphinviewcontainer.cpp:710-714`) | Drop for Phase 2/3; macOS privilege escalation is `SMJobBless`/`AuthorizationServices`, not `kio_admin` | 4 | `act_as_admin` action (`src/dolphinui.rc:49`, `src/dolphinmainwindow.cpp:2029`) has no macOS story. Hide it. |
| View container stacking order | `LayoutStructure` `src/dolphinviewcontainer.cpp:58-68`: searchBar(0), adminBar(1), messageWidget(2), selectionModeTopBar(3), view(4), selectionModeBottomBar(5), filterBar(6), statusBar(7) | Vertical `NSStackView` inside each split pane, same ordering | 2 | This is the single most useful layout spec in the codebase — reproduce it literally. |

### 2. Menu bar: `dolphinui.rc` → `NSMenu`

`src/dolphinui.rc:4-83` defines **seven** menus by name only (`file`, `edit`, `view`, `go`, `tools`, `settings`) — note there is no `<text>` for most of them, and no `help` menu at all. **These are merge overlays onto KXmlGui's `ui_standards.rc`**, which supplies the menu titles, the `Help` menu, and the placement of the standard actions Dolphin registers but never lists in its own RC (`go_back`, `go_forward`, `go_up`, `go_home` — created at `src/dolphinmainwindow.cpp:2107-2181` but absent from the `<Menu name="go">` block, which only carries `bookmarks` and `closed_tabs`, `src/dolphinui.rc:68-71`).

**This is a trap for the port:** reading `dolphinui.rc` alone gives an incomplete menu. The effective menu is `ui_standards.rc` ⊕ `dolphinui.rc` ⊕ any `KFileItemActions` service-menu insertions. I could not read `ui_standards.rc` (it ships with KXmlGui, which is not in the local checkouts) — **open question: enumerate it from the KXmlGui source before finalising the macOS menu.**

Actions Dolphin registers that macOS wants in the **application menu**, and where they currently live:

| Action | Registered at | Current home | macOS home |
|---|---|---|---|
| `KStandardAction::AboutApp` | referenced `src/dolphinmainwindow.cpp:3092` | Help | Dolphin → About Dolphin |
| `KStandardAction::AboutKDE` | `src/dolphinmainwindow.cpp:3097` | Help | Dolphin → About KDE (keep, below About) |
| `KStandardAction::Preferences` | `src/dolphinmainwindow.cpp:2257` | Settings | Dolphin → Settings… (⌘,) |
| `KStandardAction::KeyBindings` | `src/dolphinmainwindow.cpp:2256` | Settings | Dolphin → Settings… → Shortcuts pane (macOS has no "Configure Shortcuts" idiom) |
| `KStandardAction::Quit` | `src/dolphinmainwindow.cpp:1852` | File | Dolphin → Quit Dolphin (⌘Q) |
| `KStandardAction::SwitchApplicationLanguage` | `src/dolphinmainwindow.cpp:3086` | Settings/Configure | Remove — macOS uses per-app language in System Settings |
| `KStandardAction::HelpContents`, `WhatsThis`, `ReportBug`, `Donate` | `src/dolphinmainwindow.cpp:3050,3053,3065,3074` | Help | Help menu; **drop `WhatsThis`** (no macOS analogue; the `Qt::WindowContextHelpButtonHint` at `src/dolphinmainwindow.cpp:145` is already Windows-only) |

Standard macOS items Dolphin **has no action for at all** and that must be synthesised: Services submenu, Hide/Hide Others/Show All, the entire **Window** menu (Minimize ⌘M, Zoom, Bring All to Front, window list), and Help-menu search. Note `Ctrl+M` is currently *Show Menubar* — a direct collision with macOS `⌘M` = Minimize (see §4).

**No `QAction::MenuRole` is set anywhere in the Dolphin tree** (grep for `setMenuRole`/`MenuRole` over `src/` returns nothing). That means, if Phase 2 keeps Qt widgets, Qt's Cocoa plugin will fall back to *text heuristics* to decide what migrates to the application menu — matching on words like "about", "preferences/settings/config", "quit/exit" in the (localised!) action text. That is fragile and will misfire under localisation.

**Recommendation for Phase 2: use Qt's automatic menu-bar merging, but do it deliberately, not by accident.**

- Keep `KXmlGuiWindow` + a new `src/dolphinuiformac.rc` (precedent: `dolphinuiforphones.rc`, selected at `src/dolphinmainwindow.cpp:213-214`). Qt's `QMenuBar` on macOS is already a real `NSMenu`, so you get the native bar for free, with `KActionCollection`'s enable/disable/checked state wiring intact.
- Explicitly call `setMenuRole()` on the seven actions in the table above rather than relying on heuristics. This is a ~20-line, low-risk patch.
- Synthesise the Window menu by hand (Qt does not create one).
- **Do not** hand-build `NSMenu` in Phase 2. The value of `KActionCollection` is the ~150 actions with their enable-state machine (`<State name="new_file">`/`has_selection`/`has_no_selection`, `src/dolphinui.rc:84-108`) plus dynamic sub-menus (`KNewFileMenu`, `KFileItemActions` service menus, `DolphinRecentTabsMenu`, `KBookmarkMenu` at `src/dolphinbookmarkhandler.h:45`). Re-hosting those on `NSMenu` before the shell is proven doubles Phase 2.
- **Do** build `NSMenu` natively in Phase 4, once the action model is stable, if menu-item validation (`NSMenuValidation`), Services integration, or Sharing menus become blockers.

### 3. Sidebar, panels, views, bars — full inventory

| Dolphin element | Class / file | macOS replacement | Phase | Notes / risks |
|---|---|---|---|---|
| Places sidebar | `PlacesPanel : KFilePlacesView` (`src/panels/places/placespanel.h:29`); model `KFilePlacesModel` (KIO `src/filewidgets/kfileplacesmodel.h:40`) | `NSOutlineView` in `sourceList` selection highlight, inside `NSSplitViewController` sidebar item with `NSVisualEffectView` | 2 | See §5 for the adapter. `KFilePlacesView` is a `QListView` with a delegate that fakes section headers (`kio src/filewidgets/kfileplacesview.cpp:723`), so the "sections" are *painted*, not modelled. |
| Folders panel (tree) | `FoldersPanel : Panel` with its own `KFileItemModel` (`src/panels/folders/folderspanel.h:25,102`) | `NSOutlineView` (real tree) or drop in favour of Finder-style column view (`NSBrowser`) | 3 | Low priority; macOS users rarely use a second tree next to a sidebar. Candidate for cutting. |
| Information panel | `InformationPanel`/`InformationPanelContent` (`src/panels/information/informationpanelcontent.h:42`) with `PixmapViewer` (`:156`) and `MediaWidget` (`:157`, Qt Multimedia) | `NSSplitViewController` trailing item; preview via `QLPreviewView` (inline Quick Look) + `MDItem`/`AVAsset` metadata | 3 | **Hard-gated on Baloo**: `#if HAVE_BALOO` at `src/dolphinmainwindow.cpp:2367-2382`, `HAVE_BALOO` set only when KF6Baloo + KF6BalooWidgets are found (`CMakeLists.txt:127-150`). Without Baloo the panel, its toggle action, *and its Panels-menu entry* simply do not exist. |
| Item tooltips (rich, with preview+metadata) | `ToolTipManager` (`src/views/tooltips/tooltipmanager.h:27`) + `DolphinFileMetaDataWidget` wrapping `Baloo::FileMetaDataWidget` (`src/views/tooltips/dolphinfilemetadatawidget.h:19-22`) | `NSView`-based popover, or lean on Quick Look | 3 | **Also Baloo-gated**: the source files are only compiled `if(HAVE_BALOO)` (`CMakeLists.txt:192-199`) and instantiation is `#if HAVE_BALOO` (`src/views/dolphinview.cpp:254-256, 1477-1480`). No Baloo on macOS ⇒ **zero tooltips**, silently. |
| Terminal panel | `TerminalPanel` loading the `kf6/parts/konsolepart` KParts plugin (`src/panels/terminal/terminalpanel.cpp:167-168`) | Drop; replace with "Open in Terminal.app" (`NSWorkspace openApplicationAtURL:`) | 2 | `HAVE_TERMINAL` is `TRUE` on every non-Windows platform (`CMakeLists.txt:152-157`), so it *compiles* on macOS and then fails to find the plugin at runtime, showing a "konsolePart missing" placeholder. Also uses KIOFuse over D-Bus for remote CWD sync (`terminalpanel.cpp:300-361`) — dead on macOS. |
| Panel docking / lock / drag-to-other-side | `DolphinDockWidget`, `lock_panels` `KDualAction` (`src/dolphinmainwindow.cpp:2345-2360`) | `NSSplitViewController` sidebar/inspector items — **fixed** left/right, collapsible only | 2 | Free-floating, re-dockable panels are not a macOS idiom. Drop `lock_panels` and the allowed-areas logic. UX win, not a loss. |
| Breadcrumb / location bar | `DolphinUrlNavigator : KUrlNavigator` (KIO `src/filewidgets/kurlnavigator.h`), toolbar-hosted via `DolphinNavigatorsWidgetAction` | **Custom breadcrumb view, not `NSPathControl`** | 2 | `NSPathControl` is display-oriented; `KUrlNavigator` has a scheme combo (`kurlnavigatorschemecombo_p.h`), a places selector dropdown (`kurlnavigatorplacesselector_p.h`), per-segment sibling-folder popup menus (`kurlnavigatorbutton_p.h`), drop targets per segment (`urlsDropped` signal, `kurlnavigator.h:432`), and an editable/breadcrumb toggle (`setUrlEditable`, `:191`). Re-implement as `NSView` + `NSButton` segments + `NSMenu` popups. Editable mode → swap in an `NSTextField` with an `NSPathCell`-style completion (⌘⇧G equivalent). |
| Filter bar | `FilterBar : AnimatedHeightWidget` (`src/filterbar/filterbar.h:25`) — `QLineEdit` + case-sensitivity + lock button | `NSSearchField` with a "Filter" placeholder, in a slide-down accessory bar | 2 | Dolphin has *two* separate concepts (Filter = live name filter on the loaded list; Search = KIO query). Finder has one. Keep both but label them clearly. |
| Search bar | `Search::Bar : AnimatedHeightWidget` (`src/search/bar.h:48`) with chips: `DateSelector`, `FileTypeSelector`, `MinimumRatingSelector`, `TagsSelector` (`src/search/selectors/`), state in `Search::DolphinQuery` | `NSSearchField` in the toolbar + a token/chip row using `NSTokenField` or a custom `NSView` of `NSButton` chips | 3 | Rating/Tags selectors are Baloo-backed and will be empty on macOS. `NSSearchField`'s built-in recent-searches menu is a free win. Spotlight (`NSMetadataQuery`) is the obvious macOS backend, but that is the KIO auditor's territory. |
| Selection mode (touch) | `SelectionMode::TopBar` (`src/selectionmode/topbar.h:24`), `BottomBar` with 11 `Contents` states (`src/selectionmode/bottombar.h:41-52`), toggled by `toggle_selection_mode` | **Remove on macOS** | 2 | Designed for touch/phone. macOS has no equivalent, and its `Space` binding is actively harmful (§4). |
| Tabs | `DolphinTabWidget : QTabWidget` (`src/dolphintabwidget.h:21`), `DolphinTabBar : QTabBar` with drag-detach, drop-on-tab, rename, middle-click-close (`src/dolphintabbar.h:19-42`) | **Native window tabs** (`NSWindow.tabbingMode`, `addTabbedWindow:`) | 2 | Native tabs give you tab overview, drag-out-to-window, and ⌘⇧[ / ⌘⇧] for free — and `tabDetachRequested` (`dolphintabbar.h:23`) maps 1:1. Risk: each Dolphin tab can itself be split; a native tab therefore owns a whole `NSSplitViewController`, which is fine. |
| Split view | `DolphinTabPage` with `DolphinTabPageSplitter : QSplitter` (`src/dolphintabpage.h:217,253`) holding `m_primaryViewContainer`/`m_secondaryViewContainer` (`:220-221`); `popout_split_view` detaches one side | `NSSplitViewController` with two content items; pop-out → new `NSWindow` | 2 | Finder has no split view; this is a Dolphin differentiator worth preserving. `focus_inactive_split_view` (`Ctrl+F3`) and the dimming of the inactive pane must be reproduced. |
| View modes: Icons / Compact / Details | `DolphinView::Mode` (`src/views/dolphinview.h:66-83`); actions `icons`/`compact`/`details` (`src/views/dolphinviewactionhandler.cpp:777-810`) | Icons → `NSCollectionView` (flow layout); Compact → `NSCollectionView` (vertical-flow, name-right); Details → `NSOutlineView` | 3 | Details **must** be `NSOutlineView`, not `NSTableView`: Dolphin's details view supports in-place folder expansion (`supportsItemExpanding`, `src/kitemviews/kitemlistcontroller.cpp:262-263`; roles `isExpanded`/`isExpandable`/`expandedParentsCount`, `src/kitemviews/kfileitemmodel.cpp:2174-2176`) — the same behaviour as Finder's list view disclosure triangles. |
| Column headers / column chooser | `KItemListHeader`/`KItemListHeaderWidget` (`src/kitemviews/kitemlistheader.h`, `.../private/kitemlistheaderwidget.cpp`) | `NSTableHeaderView` + header context menu | 3 | Free with `NSOutlineView`. Column set comes from the role table (`src/kitemviews/kfileitemmodel.cpp:3143-3190`). |
| Additional Information (visible columns) | `additional_info` `KActionMenu`, roles grouped Document/Image/Audio/Video/Other (`src/views/dolphinviewactionhandler.cpp:328-339`; role table `kfileitemmodel.cpp:3143-3190`) | `NSMenu` on the header + View menu submenu | 3 | ~45 roles; **everything with `requiresBaloo == true`** (rating, tags, comment, all Document/Image/Audio/Video rows, `originUrl`) is unavailable without Baloo. Non-Baloo roles that survive: `text, size, modificationtime, creationtime, accesstime, type, path, folder, extension, deletiontime, destination, permissions, owner, group`. macOS can restore most media roles via `MDItem`/`AVFoundation` in Phase 4. |
| Sort By | `sort` `KActionMenu` + `sort_by_*` exclusive group + `ascending`/`descending` + `folders_first` + `hidden_last` (`src/views/dolphinviewactionhandler.cpp:288-326`) | View → Sort By `NSMenu` + column-header click | 3 | Dolphin's direction labels are role-aware ("Z-A" vs "Largest First", `dolphinviewactionhandler.cpp:822-830`) — a nice touch worth keeping. `folders_first` defaults on; Finder does not do this — **make it a preference, default on**, to preserve Dolphin behaviour. |
| Group By | `group_by` `KActionMenu` with `group_by_none` / `group_by_same_as_sort` / per-role (`src/views/dolphinviewactionhandler.cpp:341-374`); rendering via `KItemListGroupHeader` | `NSCollectionView` section headers / `NSTableView` group rows — i.e. Finder's "Use Groups" | 3 | Semantically identical to Finder's ⌃⌘0 grouping. Direct map. |
| Zoom / icon size | `view_zoom_in/out/reset` + `ZoomWidgetAction` + statusbar `QSlider` (`src/views/dolphinviewactionhandler.cpp:255-275`, `src/views/zoomwidgetaction.h`) | `NSSlider` in toolbar/status strip; ⌘+ / ⌘- / ⌘0 | 2/3 | `Ctrl+0` reset (`dolphinviewactionhandler.cpp:263`) → ⌘0, which is standard-ish on macOS. Keep. |
| Previews (thumbnails) | `KIO::PreviewJob` driven by `KFileItemModelRolesUpdater` (`src/kitemviews/kfileitemmodelrolesupdater.cpp:17,100`), plus hover-sequence previews (`:87`) | `QLThumbnailGenerator` (Quick Look thumbnails) feeding the same role | 3 | Best-of-both: keep `KFileItemModelRolesUpdater`'s throttling/visibility logic, swap the *producer* from `PreviewJob` to `QLThumbnailGenerator`. Gets you native, correct, GPU-accelerated thumbnails for every type macOS knows. |
| Inline rename | `DolphinView::renameSelectedItems()` `src/views/dolphinview.cpp:850-895`: 1 item + `RenameInline` (default `true`, `src/settings/dolphin_generalsettings.kcfg:106-109`) ⇒ `m_view->editRole(index, "text")`; else `KIO::RenameFileDialog` | In-cell `NSTextField` editing on `NSCollectionView`/`NSOutlineView` | 3 | Also has "two-clicks renaming" (slow double-click on the label) at `src/views/dolphinview.cpp:1583-1588` — identical to Finder. Keep. Multi-item rename → batch-rename sheet. |
| Batch rename | `KIO::RenameFileDialog` (KIO widgets), invoked `src/views/dolphinview.cpp:875` | Sheet (`NSWindow` beginSheet) with the same fields | 3 | Finder's equivalent ("Rename N Items…") is a sheet. Straight port. |
| Context menus | `DolphinContextMenu : QMenu` (`src/dolphincontextmenu.h:34`); four variants: trash / trash-item / item / viewport (`:69-72`); item menu at `src/dolphincontextmenu.cpp:390-440` | `NSMenu` returned from `-menuForEvent:` | 2/3 | Structure at `dolphincontextmenu.cpp:396-438`: Cut, Copy, Copy Location, Paste, Duplicate, Rename, Add to Places, sep, Move to Trash, Delete, then Open With, service menus, VCS actions, Properties. Reordering to Finder conventions (Open, Open With, sep, Move to Trash, sep, Get Info, Rename, Duplicate, Make Alias, Quick Look…) is a Phase 4 polish item. |
| "Open With" submenu | `KFileItemActions` (`src/dolphinmainwindow.cpp:2618`), submenu found by object name `openWith_submenu` (`src/dolphincontextmenu.cpp:511-526`) | `NSWorkspace URLsForApplicationsToOpenURL:` → `NSMenu`; plus the system "Open With" via `NSMenu` Services | 2 | KIO's `.desktop`-file app database is meaningless on macOS. Must be swapped to LaunchServices, not adapted. |
| Service menus / custom actions | `KFileItemActions::addActionsTo` (`src/dolphincontextmenu.cpp:545`); shortcut registration via `ServiceMenuShortcutManager` (`src/servicemenushortcutmanager.h:26`) | macOS **Services** menu + Quick Actions (Automator/Shortcuts extensions) | 4 | Best long-term answer is to expose Dolphin's context menu to `NSSharingServicePicker` + Services, and let macOS Quick Actions replace `.desktop` service menus. |
| New File menu | `DolphinNewFileMenu : KNewFileMenu` (`src/dolphinnewfilemenu.h`, registered `src/dolphinmainwindow.cpp:1806-1810`) | `NSMenu` "New Folder / New Document from Template" | 2 | Templates come from `~/.local/share/templates` (`doc/index.docbook:1600`). On macOS use `~/Library/Application Support/Dolphin/Templates`. |
| Properties dialog | `KPropertiesDialog` (used at `src/dbusinterface.cpp:58`; action `properties` at `src/views/dolphinviewactionhandler.cpp:157-170`) | **Get Info panel**: a floating `NSPanel` (macOS Get Info is a panel, not a modal) | 3 | Big surface: permissions, ownership, mount info, Open-With default, checksums. Consider a native reimplementation over `NSURL` resource keys rather than porting `KPropertiesDialog`'s KIO plugin machinery. |
| View Properties dialog | `ViewPropertiesDialog : QDialog` (`src/settings/viewpropertiesdialog.h:31`), action `view_properties` (`src/views/dolphinviewactionhandler.cpp:391-397`) | Finder's "Show View Options" (⌘J) floating `NSPanel` | 3 | Direct analogue; `GlobalViewProps` default `true` (`src/settings/dolphin_generalsettings.kcfg:90-93`) matches Finder's "Use as Defaults" button. |
| Settings dialog | `DolphinSettingsDialog : KPageDialog` — pages Interface, View, Context Menu, Trash, (User Feedback) (`src/settings/dolphinsettingsdialog.cpp:45-104`) | `NSWindow` with `NSToolbar` in `preference` mode (classic macOS Preferences), ⌘, | 3 | KCM plugins (`src/settings/kcm/`) are for KDE System Settings — drop entirely on macOS. |
| Trash | `trash/dolphintrash.*`, "Empty Trash" (`src/dolphincontextmenu.cpp:144-152`) | `NSFileManager trashItemAtURL:`, `~/.Trash`, Finder's Empty Trash | 2 | KIO's `trash:/` worker must be replaced or bridged; that's the KIO auditor's call, but the *UI* affordance maps 1:1. |
| Version-control emblems | `VersionControlObserver` + `KVersionControlPlugin` (`src/views/versioncontrol/`) | Badge overlay in the `NSCollectionViewItem`/`NSTableCellView` | 4 | Plugin-based; no macOS blocker, just work. |
| Bookmarks menu | `DolphinBookmarkHandler : KBookmarkOwner` + `KBookmarkMenu` (`src/dolphinbookmarkhandler.h:20,45`) | `NSMenu` under Go, backed by the same XBEL file | 2 | Overlaps heavily with Places; consider merging in Phase 4. |
| Recently closed tabs | `DolphinRecentTabsMenu` (`src/dolphinrecenttabsmenu.h`, `src/dolphinmainwindow.cpp:2123`) | File → Recently Closed `NSMenu` | 2 | Trivial. |
| Disk-space usage menu | `DiskSpaceUsageMenu` (`src/statusbar/diskspaceusagemenu.h`, `src/dolphinmainwindow.cpp:2190-2194`) | Drop, or link to macOS Storage settings | 4 | Launches `filelight`; irrelevant on macOS. |

---

### 4. Keyboard shortcut conflict table

**Critical mechanic first.** Qt's `QKeySequence` on macOS maps `Qt::ControlModifier` → **⌘** and `Qt::MetaModifier` → **⌃** by default (the "Ctrl/Meta swap", disabled only by `Qt::AA_MacDontSwapCtrlAndMeta`). Every `Qt::CTRL | …` in Dolphin therefore *already becomes a Command shortcut* in a Qt build on macOS — which is mostly what you want, and is why Phase 2 gets 80 % of the shortcut story for free. It is also why the collisions below are real and not hypothetical. **This is Qt runtime behaviour, not something I could verify from the local checkouts — confirm empirically against Qt 6.11 in Phase 1.** Likewise `KStandardShortcut` defaults (Back = `Alt+Left`, Up = `Alt+Up`, Home = `Alt+Home`, Reload = `F5`, Show Hidden = `Alt+.`/`Ctrl+H`, Show Menubar = `Ctrl+M`) are cited from `doc/index.docbook:2067-2100,1959-1983,208` rather than from KF6 source, which is not checked out.

Second critical mechanic: **on Apple keyboards the key labelled "delete" is `Qt::Key_Backspace`**, and `Qt::Key_Delete` is `fn`+delete. Dolphin binds `Backspace` to *Go Back* (`src/dolphinmainwindow.cpp:2120`) and `Key_Delete` to *Move to Trash* (`src/views/dolphinviewactionhandler.cpp:118-124`). A Mac user selecting a file and pressing the delete key therefore **navigates to the parent/previous folder instead of trashing** — silent, surprising, and the file appears to vanish from view. This is the single most dangerous binding in the port.

| Dolphin binding | Evidence | Renders on macOS as | macOS / Finder meaning | Verdict |
|---|---|---|---|---|
| `Backspace` → Go Back | `dolphinmainwindow.cpp:2119-2121` | the **delete key** | Finder: nothing (⌘⌫ trashes) | **REMAP — dangerous.** Unbind Backspace entirely. |
| `Del` → Move to Trash | `dolphinviewactionhandler.cpp:118-124` | `fn`+delete | Finder: ⌘⌫ | **REMAP to ⌘⌫**; offer `fn`+delete as an alias. |
| `Shift+Del` → Delete permanently | `dolphinviewactionhandler.cpp:128-134` | ⇧`fn`⌫ | Finder: ⌘⌥⌫ | **REMAP to ⌘⌥⌫.** Keep ⇧⌫ as hidden alias. |
| `Space` → toggle Selection Mode | `dolphinmainwindow.cpp:1993`; view-side handling `kitemlistcontroller.cpp:456-471`; arbitration `dolphinmainwindow.cpp:602-613` + `dolphinview.cpp:2096-2099` | Space | **Quick Look** | **REMAP — highest-visibility conflict.** Space → Quick Look; delete Selection Mode on macOS. |
| `Return`/`Enter` → open item | `kitemlistcontroller.cpp:433-444` | Return | Finder: **rename** | **REMAP — dangerous inversion.** Return → rename, ⌘O and ⌘↓ → open. Offer Return→open as a preference for Dolphin refugees. |
| `F2` → rename | `KStandardAction::renameFile`, `dolphinviewactionhandler.cpp:109`; `doc/index.docbook:1653` | F2 (needs `fn`) | unbound | **Keep as alias**, but Return must be primary. |
| `Ctrl+M` → Show Menubar | `dolphinmainwindow.cpp:2241`; `doc/index.docbook:208` | ⌘M | **Minimize Window** | **REMOVE the action** (menu bar can't be hidden on macOS). |
| `Ctrl+S` → Split Stash | `dolphinmainwindow.cpp:2058` | ⌘S | Save | **REMAP or remove.** The action is D-Bus-gated invisible on macOS (`:2059-2061`) but the *shortcut may still be live* — verify; a dead ⌘S is confusing, a live one worse. |
| `Ctrl+I` → Show Filter Bar | `dolphinmainwindow.cpp:1937` | ⌘I | **Get Info** | **REMAP.** Filter → ⌥⌘F; ⌘I → Properties/Get Info. |
| `Ctrl+P` → Focus Places Panel | `dolphinmainwindow.cpp:2582` | ⌘P | **Print** | **REMAP** to ⌃⌘S (Finder's Show/Hide Sidebar is ⌃⌘S). |
| `Ctrl+L` / `Alt+D` → Replace Location | `dolphinmainwindow.cpp:2102` | ⌘L / ⌥D | Finder ⌘L = **Make Alias** | **REMAP to ⇧⌘G** (Go to Folder). Keep ⌘L as secondary only if Make Alias is not implemented. |
| `Ctrl+D` → Duplicate Here | `dolphinviewactionhandler.cpp:155` | ⌘D | Finder: **Duplicate** | **KEEP** — exact match. |
| `Ctrl+1/2/3` → Icons/Compact/Details | `dolphinviewactionhandler.cpp:783,794,805` | ⌘1/⌘2/⌘3 | Finder: Icons/List/Columns | **KEEP** — near-exact match (Dolphin's Compact ≈ Finder's List is the only fuzz). |
| `Alt+1..9` → Go to Tab N; `Alt+0` → Last Tab | `dolphinmainwindow.cpp:2276,2285` | ⌥1..⌥9 | macOS tabs are ⌘1..⌘9 — **which now collides with view modes** | **REMAP.** Recommend: ⌘1/2/3 stay view modes (Finder parity), tabs get ⌃⌘1..9 or drop numeric tab jumps. Flag as a genuine, unavoidable trade-off. |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` → next/prev tab | `dolphinmainwindow.cpp:2287-2300` | ⌃⇥ / ⌃⇧⇥ | macOS: ⌃⇥ is browser-tab-ish; Finder uses ⌘⇧] / ⌘⇧[ | **Offer both.** Native window tabs give ⌘⇧[/] for free. |
| `Ctrl+T` new tab, `Ctrl+Shift+T` undo close tab, `Ctrl+W` close tab, `Ctrl+N` new window, `Ctrl+Q` quit | `:1833`, `:2132`, `KStandardAction::close :1844`, `openNew :1816`, `quit :1852` | ⌘T/⌘⇧T/⌘W/⌘N/⌘Q | identical on macOS | **KEEP** — free wins. |
| `Ctrl+X/C/V/Z/A` | `:1868,1877,1885,1856,2008` | ⌘X/C/V/Z/A | identical | **KEEP.** |
| `Ctrl+Shift+A` → Invert Selection | `dolphinmainwindow.cpp:2019` | ⌘⇧A | Finder: **Deselect All** | Different but not dangerous. **Keep**, and add ⌘⇧A→Deselect All? No — pick one; recommend moving Invert to ⌃⌘A. |
| `Ctrl+F` → Search, `Ctrl+Shift+F` → preferred search tool | `KStandardAction::find :1952`; `:2202` | ⌘F / ⌘⇧F | ⌘F = Find (match) | **KEEP ⌘F.** Drop ⌘⇧F (external search tool has no macOS meaning). |
| `Ctrl+Alt+C` → Copy Location | `dolphinviewactionhandler.cpp:177` | ⌘⌥C | Finder: **⌘⌥C = Copy as Pathname** | **KEEP** — exact match, pleasingly. |
| `Alt+Return` → Properties | `dolphinviewactionhandler.cpp:169` | ⌥⏎ | Finder: **⌘I** | **REMAP to ⌘I** (freed by moving the filter bar). |
| `Alt+Left/Right` → Back/Forward | `KStandardAction::back/forward`, `dolphinmainwindow.cpp:2107-2168`; `doc/index.docbook:2078-2089` | ⌥← / ⌥→ | macOS: word-wise caret movement; Finder: ⌘[ / ⌘] | **REMAP to ⌘[ / ⌘]**, keep ⌘← /⌘→? No — those are line-start/end. Use ⌘[ / ⌘] only. |
| `Alt+Up` → Go Up | `KStandardAction::up :2175`; `doc/index.docbook:2067` | ⌥↑ | Finder: **⌘↑** | **REMAP to ⌘↑.** Add ⌘↓ = open selected (Finder). |
| `Alt+Home` → Home | `:2176`; `doc/index.docbook:2100` | ⌥⇱ | Finder: ⇧⌘H | **REMAP to ⇧⌘H.** |
| `Alt+.` / `Ctrl+H` → Show Hidden Files | `dolphinviewactionhandler.cpp:390`; `doc/index.docbook:1959-1965` | ⌥. / ⌘H | **⌘H = Hide Application** | **REMAP — dangerous.** Finder uses ⌘⇧. (period). Use that; drop ⌘H immediately. |
| `F3` split view, `Shift+F3` pop out, `Ctrl+F3` focus other view | `dolphinmainwindow.cpp:2044,2054,1925` | F3 (needs `fn`; macOS F3 = Mission Control) | conflicts with system | **REMAP.** Suggest ⌥⌘S for split, ⌥⌘→/← for focus. |
| `F4` terminal panel, `Shift+F4` open terminal, `Shift+Alt+F4` terminal here, `Ctrl+Shift+F4` focus terminal | `:2458`, `:2218`, `:2228`, `:2492` | F4 family | macOS F4 = Spotlight/Launchpad | **REMAP** (or drop with the terminal panel). |
| `F5` reload | `KStandardAction::redisplay :2067`; `doc/index.docbook:1983` | F5 | macOS F5 = keyboard backlight/dictation | **REMAP to ⌘R.** |
| `F6` editable location | `dolphinmainwindow.cpp:2091` | F6 | — | **REMAP** — fold into ⇧⌘G. |
| `F7` folders panel, `F9` places panel, `F11` information panel | `:2418`, `:2523`, `:2374` | F7/F9/F11 | **F11 = Show Desktop**, F7/F9 = media/Mission Control | **REMAP — F11 is system-claimed.** Sidebar ⌃⌘S; Inspector ⌥⌘I. |
| `F12` show previews | `dolphinviewactionhandler.cpp:281` | F12 | macOS F12 = volume/Notification Centre | **REMAP** to ⌃⌘P or fold into View Options. |
| `Shift+F5` / `Shift+F6` → copy/move to other split view | `dolphinmainwindow.cpp:1906,1918` | ⇧F5/⇧F6 | — | **REMAP** to ⌃⌘→ / ⌃⌥⌘→ or menu-only. (Note `doc/index.docbook:1793,1804` says `Ctrl+F5/F6` — the docbook is stale; the code is authoritative.) |
| `/` → Show Filter Bar (alt) | `dolphinmainwindow.cpp:1937` | `/` | Finder: `/` opens Go-to-Folder in some contexts | **Drop**; conflicts with type-ahead search (`kitemlistcontroller.cpp:472-484`). |
| `Ctrl+Shift+N` → Create Folder (`KStandardShortcut::createFolder`) | `dolphinviewactionhandler.cpp:87` | ⌘⇧N | Finder: **⌘⇧N = New Folder** | **KEEP** — exact match. |

Summary: of ~45 default bindings, **~12 are direct macOS matches and should be kept verbatim, ~8 are outright dangerous and must be remapped (Backspace, Del/Shift-Del, Space, Return, ⌘H, ⌘M, ⌘I, ⌘S), and the whole F-key block (F3–F12) needs relocation** because macOS reserves those keys for system functions and requires `fn` otherwise.

---

### 5. Places sidebar: `KFilePlacesModel` → `NSOutlineView` adapter

**Actual API shape (KIO `src/filewidgets/kfileplacesmodel.h`)**

- It is a **`QAbstractItemModel` that is really a flat list**: `parent()` unconditionally returns an invalid index (`kfileplacesmodel.cpp:646-650`) and `columnCount()` is hard-coded to 1 (`:681-686`). There is no tree.
- Grouping is a **per-row attribute, not a structure**: `GroupRole` (`kfileplacesmodel.h:72`) plus `GroupType groupType(index)` and `QModelIndexList groupIndexes(GroupType)` (`:225,232`), with `enum GroupType { PlacesType, RemoteType, RecentlySavedType, SearchForType, DevicesType, RemovableDevicesType, UnknownType, TagsType }` (`:94-103`). `KFilePlacesView` renders the headers itself in a delegate (`kfileplacesview.cpp:723 sectionHeaderHeight`, `:681`). **The section headers do not exist in the model.**
- Per-row roles you will need: `UrlRole`, `HiddenRole`, `SetupNeededRole`, `FixedDeviceRole`, `CapacityBarRecommendedRole`, `IconNameRole`, `GroupHiddenRole`, `TeardownAllowedRole`, `EjectAllowedRole`, `TeardownOverlayRecommendedRole`, `DeviceAccessibilityRole` (`kfileplacesmodel.h:66-79`), plus `DeviceAccessibility { SetupNeeded, SetupInProgress, Accessible, TeardownInProgress }` (`:112-117`).
- Device lifecycle: `isDevice()`, `deviceForIndex()` (`:200,206`), `requestSetup/requestTeardown/requestEject` (`:264-276`), ready-made `QAction*` factories `teardownActionForIndex`/`ejectActionForIndex`/`partitionActionForIndex` (`:239-258`), and the `setupDone`/`teardownDone` signals (`:458,472`).
- Mutation: `addPlace`, `editPlace`, `removePlace`, `setPlaceHidden`, `setGroupHidden`, `movePlace(int itemRow, int row)`, `hiddenCount()` (`:289-353`).
- Navigation helpers worth reusing verbatim: `closestItem(QUrl)` (`:381`) and `placeCollapsedUrl(QUrl)` (`:397`, since 6.23) — the latter gives "Documents/Important/KDE" style display strings.
- DnD: `mimeTypes()` returns exactly `{ "application/x-kfileplacesmodel-<ptr>", "text/uri-list" }` (`kfileplacesmodel.cpp:1037-1044`). `flags()` marks rows drag-enabled but **only the invalid (root) index drop-enabled** (`:1022-1035`) — i.e. drops between rows, never onto a row. `dropMimeData()` (`:1072-1156`) handles two cases: internal move (decode row int → `movePlace`) and `text/uri-list` add (each URL is `KIO::stat`'d synchronously and **rejected unless it is a directory**, `:1140-1146`).

**Where the model falls short for a Finder-grade sidebar**

| Gap | Evidence | Impact |
|---|---|---|
| No sections in the model | `parent()` returns `{}`, `kfileplacesmodel.cpp:646-650` | The `NSOutlineView` adapter must synthesise group nodes itself. |
| Sections are pre-defined, not user-creatable | `GroupType` enum, `kfileplacesmodel.h:94-103` | Cannot express Finder's Favorites / iCloud / Locations / Tags 1:1 — see mapping below. |
| `movePlace` uses **global** row indices and silently clamps to the group | `kfileplacesmodel.cpp:1308-1345`, esp. `findNearestPosition(itemRow, destRow)` at `:1340` | An `NSOutlineView` drag that *looks* like it moves an item across sections will be quietly refused. The adapter must reject cross-section drags in `validateDrop:` rather than letting the user try. |
| Devices come from Solid | `Solid::Predicate::fromString` `:457`; `Solid::DeviceNotifier` `:760-766` | Solid's macOS backend is the open question of the whole port. If Solid is stubbed, `DevicesType`/`RemovableDevicesType` are empty and `requestSetup/Teardown/Eject` are no-ops. **This is the KIO/Solid auditor's item, but it lands squarely in the sidebar UX.** |
| Default places are Linux-shaped | `:258-292` create Home, Desktop, Documents, Downloads, **Network (`remote:/`)**, **Trash (`trash:/`)**; `:350-370` Music/Pictures/Videos; `:394-428` `recentlyused:/files`, `recentlyused:/locations`, `timeline:/today`, `timeline:/yesterday` | `remote:/`, `timeline:/`, `recentlyused:/` and `tags:/` all need KIO workers that will not exist on macOS. Those rows will appear and fail on click. **Filter them out via `setSupportedSchemes()` (`kfileplacesmodel.h:434`) — the model already supports this.** |
| No iCloud / no network-share discovery | — | Must be added outside the model. |

**Proposed section mapping**

| Finder section | Source |
|---|---|
| **Favorites** | `PlacesType` rows (`groupIndexes(PlacesType)`) |
| **iCloud** | *New*, not in the model — enumerate `~/Library/Mobile Documents` via `NSFileManager ubiquityIdentityToken` and inject as synthetic rows |
| **Locations** | `DevicesType` + `RemovableDevicesType` (Solid) **plus** synthetic rows from `NSWorkspace mountedLocalVolumePaths` / `NSFileManager mountedVolumeURLs` as a Solid fallback; plus `RemoteType` for user-added sftp/smb bookmarks |
| **Tags** | `TagsType` — Baloo-backed, so **empty on macOS**. Replace with macOS Finder tags read from the `NSURLTagNamesKey` resource key. |
| **Recents / Smart** | `RecentlySavedType` + `SearchForType` — `timeline:`/`recentlyused:`/`baloosearch:` URLs; suppress unless a macOS backend exists |

**Adapter design (`DolphinPlacesDataSource`)**

- Maintain a two-level snapshot: `[SectionNode(GroupType, title)] → [PlaceRow(sourceRow, url, iconName, …)]`, rebuilt from `groupIndexes()` on `modelReset`/`rowsInserted`/`rowsMoved`/`dataChanged`/`reloaded()` (`kfileplacesmodel.h:489`). Do **not** try to proxy `QModelIndex` into `NSOutlineView` item pointers; snapshot value types are far safer across the Qt/AppKit boundary.
- `outlineView:isGroupItem:` → `YES` for `SectionNode`. Set `NSOutlineView.selectionHighlightStyle = .sourceList` and `floatsGroupRows = NO`.
- Icons: prefer SF Symbols keyed off `IconNameRole` with a lookup table (`folder-download` → `arrow.down.circle`, `drive-harddisk` → `internaldrive`, …); fall back to rendering the Breeze `QIcon` from `icon(index)` (`kfileplacesmodel.h:172`) into an `NSImage`.
- Device rows: `DeviceAccessibilityRole` drives an `NSProgressIndicator` (spinning) for `SetupInProgress`/`TeardownInProgress`; `TeardownOverlayRecommendedRole` drives the trailing ⏏ button (`isTeardownOverlayRecommended`, `:160`); `CapacityBarRecommendedRole` drives a thin capacity bar. Click on a `SetupNeeded` row must call `requestSetup(index)` and wait for `setupDone` before navigating — the same dance `PlacesPanel` does (`src/panels/places/placespanel.h:41-43`, `src/dolphinmainwindow.cpp:1780-1798`).
- Drag-reorder: `NSPasteboardTypeString`-carrying private UTI holding the *global* source row; on `acceptDrop:` call `movePlace(sourceRow, targetGlobalRow)`. In `validateDrop:` return `NSDragOperationNone` when source and destination `GroupType` differ, because `findNearestPosition` (`kfileplacesmodel.cpp:1340`) will otherwise silently no-op.
- External drops: accept `NSPasteboardTypeFileURL`, but **pre-filter to directories** yourself (`NSURLIsDirectoryKey`) instead of letting `dropMimeData` do a synchronous blocking `KIO::stat` on the main thread (`kfileplacesmodel.cpp:1128-1146`) — that stat will hang the UI on an unreachable sftp host.
- Context menu: reuse `teardownActionForIndex`/`ejectActionForIndex`/`partitionActionForIndex` where Solid works; add Finder's "Remove from Sidebar" → `removePlace`, "Rename" → `editPlace`, and Show Hidden Places → `setShowAll` (`src/dolphinmainwindow.cpp:2545-2556`).

Phase: **2** for the outline view + Favorites/Locations; **3** for capacity bars, eject affordances and iCloud; **4** for macOS Tags.

---

### 6. Drag & drop bridge

**What Dolphin does today**

- **Drag out:** `KItemListController::startDragging()` (`src/kitemviews/kitemlistcontroller.cpp:1451-1483`) asks the model for a `QMimeData` and runs `drag->exec(Qt::MoveAction | Qt::CopyAction | Qt::LinkAction, Qt::CopyAction)` (`:1479`).
- **Payload:** `KFileItemModel::createMimeData` collects `urls` and `mostLocalUrls` (via `KFileItem::mostLocalUrl`) and calls `KUrlMimeData::setUrls(urls, mostLocalUrls, data)` (`src/kitemviews/kfileitemmodel.cpp:566`). `KUrlMimeData` (KCoreAddons — *not* in the local checkouts, so I could not read it; **open question**) is the KDE convention of putting the *local* URLs in `text/uri-list` and the *real* (possibly remote) URLs in a KDE-private format, so that non-KDE apps get something usable. `KUrlMimeData::exportUrlsToPortal(data)` is then called (`kitemlistcontroller.cpp:1466`, and for clipboard at `src/views/dolphinview.cpp:933,940`) — an XDG-portal concept that is **dead code on macOS**.
- **Drop in:** `DragAndDropHelper::dropUrls()` (`src/views/draganddrophelper.cpp:37-62`) → `KIO::drop(event, destUrl, flags)`, which pops the KDE Move/Copy/Link menu. Special-case: Ark's archive-extraction drag, detected via `application/x-kde-ark-dndextract-service` + `application/x-kde-ark-dndextract-path` (`src/views/draganddrophelper.h:76-83`) and dispatched over **`QDBusConnection::sessionBus()`** (`draganddrophelper.cpp:44-49`) — **inert without a session bus; remove on macOS.**
- **Drop validation:** `supportsDropping()` accepts writable dirs, `.desktop` files, and local executables (`draganddrophelper.cpp:64-67`); `urlListMatchesUrl()` prevents dropping onto self (`:20-35`).
- Tabs and the URL navigator are also drop targets (`DolphinTabBar::dropEvent` `src/dolphintabbar.h:31`; `KUrlNavigator::urlsDropped` KIO `src/filewidgets/kurlnavigator.h:432`).

**macOS bridge specification**

| Direction | Dolphin side | macOS side |
|---|---|---|
| Dolphin → Finder/other app, **local** files | `text/uri-list` of `file://` URLs | Write `NSPasteboardTypeFileURL` (one `NSPasteboardItem` per URL) on the `NSDraggingItem`s. Trivial. |
| Dolphin → Finder/other app, **remote** (sftp/smb/…) | `text/uri-list` of `sftp://…` | **Requires `NSFilePromiseProvider`.** Finder cannot consume an `sftp://` URL. See flow below. |
| Finder/other app → Dolphin | `QMimeData` with `text/uri-list` | Read `NSPasteboardTypeFileURL` (and `NSFilesPromisePboardType`/`NSPasteboardTypeFileURL` promises via `receivePromisedFilesAtDestination:`), synthesise `KIO::CopyJob`/`MoveJob` against the destination `QUrl`. |
| Drop modifier semantics | KIO shows a Move/Copy/Link popup menu | macOS uses modifiers: plain = move within volume / copy across volumes, ⌥ = copy, ⌘ = move, ⌥⌘ = alias. **Adopt macOS semantics; drop the popup menu.** Phase 2 may keep the menu; Phase 4 must not. |
| Ark archive DnD | `application/x-kde-ark-*` + D-Bus | **Delete.** |
| Places sidebar drop | `text/uri-list`, dirs only | `NSPasteboardTypeFileURL` filtered on `NSURLIsDirectoryKey` (§5) |

**Promised-file flow for remote → Finder (the one genuinely new piece of engineering):**

1. On drag start, for each selected item where `KFileItem::isLocalFile() == false`, create an `NSFilePromiseProvider` with `fileType` = the item's UTI (derived from `KFileItem::mimetype()` via `UTType(mimeType:)`) and a `userInfo` carrying the remote `QUrl` string.
2. Implement `filePromiseProvider:fileNameForType:` → the item's basename.
3. Implement `filePromiseProvider:writePromiseToURL:completionHandler:`. Called on the queue you return from `operationQueueForFilePromiseProvider:` — **use a dedicated serial queue, never the main queue**, since KIO jobs must not block the AppKit drag session.
4. In that callback, start a `KIO::FileCopyJob` from the remote URL to the destination `NSURL`, marshalled onto the Qt main thread (KIO jobs are not thread-safe), and signal the completion handler when the job's `result` fires. Report progress through the existing `DolphinStatusBar::showProgress` path (`src/statusbar/dolphinstatusbar.h:52`).
5. Mix freely: a selection of local + remote items yields some `NSPasteboardItem`s with `NSPasteboardTypeFileURL` and some `NSFilePromiseProvider`s in the same drag session.
6. Also publish `NSPasteboardTypeURL` + `NSPasteboardTypeString` with the raw `sftp://…` text, so that URL-aware apps (browsers, terminals) get something useful.

The mirror case — **Finder promising files to Dolphin** — is handled by declaring `NSFilePromiseReceiver.readableDraggedTypes` in the destination view and calling `receivePromisedFilesAtDestination:options:operationQueue:reader:` into a temp dir, then running a `KIO::CopyJob` onward to the (possibly remote) destination.

Phase: **2** for local↔local (which covers ~95 % of usage); **3** for the promise provider; **4** for modifier-key semantics and drag-image polish (`KItemListView::createDragPixmap`, `kitemlistcontroller.cpp:1474`, must become an `NSDraggingItem` image with the macOS count badge).

---

### 7. Quick Look integration

**The conflict.** Space is claimed three ways in Dolphin today, and the arbitration is already fragile:

- `toggle_selection_mode` has default shortcut `Qt::Key_Space` (`src/dolphinmainwindow.cpp:1993`).
- `KItemListController` consumes Space for select/toggle, falling through to type-ahead search otherwise (`src/kitemviews/kitemlistcontroller.cpp:456-484`).
- `DolphinMainWindow::event()` intercepts `QEvent::ShortcutOverride` for `Key_Space` and lets the view win when `handleSpaceAsNormalKey()` says so (`src/dolphinmainwindow.cpp:602-613`), i.e. when the view lacks focus or type-ahead search is active (`src/views/dolphinview.cpp:2096-2099`).

**Recommended design.**

*Phase 2 (Qt view still embedded).* Extend the existing `ShortcutOverride` hook at `dolphinmainwindow.cpp:602-613`: when the view has focus, there is ≥1 selected item, and type-ahead search is **not** active, `accept()` the event and toggle `QLPreviewPanel`. Delete the `toggle_selection_mode` Space binding entirely. Because `KItemListContainer` is a `QAbstractScrollArea` over a `QGraphicsView` (`src/kitemviews/kitemlistcontainer.cpp:68`), the Qt widget will never see the `NSResponder` chain the way AppKit expects — so `QLPreviewPanel` **cannot** be driven by the standard `acceptsPreviewPanelControl:` responder-chain protocol while the view is a Qt widget. Instead, drive it imperatively from the `NSWindowController`:
- `QLPreviewPanel.sharedPreviewPanel()` + explicit `updateController()`, with the window controller registered as both `QLPreviewPanelDataSource` and `QLPreviewPanelDelegate`.
- `numberOfPreviewItems` / `previewItemAtIndex:` read from a snapshot of `DolphinView::selectedItems()`.
- Arrow-key navigation inside the panel: implement `previewPanel:handleEvent:` and forward to the Qt view via `QCoreApplication::sendEvent`, then call `-refreshCurrentPreviewItem`.
- Zoom-from-icon animation: `previewPanel:sourceFrameOnScreenForPreviewItem:` needs the item's rect — available via `KItemListView::itemRect(index)` (used at `kitemlistcontroller.cpp:428`), converted through `QWidget::mapToGlobal` and flipped into screen coordinates.

*Phase 3 (native views).* Once the view is an `NSCollectionView`/`NSOutlineView`, adopt the proper responder-chain protocol (`acceptsPreviewPanelControl:`, `beginPreviewPanelControl:`, `endPreviewPanelControl:`) and delete the imperative shim.

**Remote files.** `QLPreviewItem.previewItemURL` must be a `file://` URL — Quick Look generators cannot read `sftp://`. For any item where `KFileItem::isLocalFile()` is false:
1. Check `KFileItem::mostLocalUrl()` first (the same call `KFileItemModel::createMimeData` uses at `src/kitemviews/kfileitemmodel.cpp:563`) — if a KIOFuse-style local mount exists, use it directly. On macOS it almost certainly will not.
2. Otherwise stage a temp copy: `KIO::FileCopyJob` remote → `NSTemporaryDirectory()/Dolphin-QuickLook/<uuid>/<basename>` (basename preserved so Quick Look picks the right generator), show a spinner in the panel by returning a placeholder item, and call `-refreshCurrentPreviewItem` on completion.
3. **Guard on size** — refuse to stage files over a threshold (say 64 MB) and show a "Preview not available" placeholder; otherwise a Space-press on a 4 GB ISO over sftp silently starts a huge transfer.
4. Reap the temp dir on `endPreviewPanelControl:` and at app exit.

This staging machinery is the *same* machinery as the `NSFilePromiseProvider` flow in §6 — build it once as a `RemoteFileStager` service and use it for both.

**Interaction with the Information panel.** Both show a preview of the selected item. On macOS, `QLPreviewView` (the embeddable sibling of `QLPreviewPanel`) should replace `PixmapViewer` + `MediaWidget` (`src/panels/information/informationpanelcontent.h:156-157`) in the inspector, which also removes Dolphin's Qt Multimedia dependency (pulled in only for Baloo builds, `CMakeLists.txt:143-148`).

Phase: **2** for the imperative shim + local files; **3** for remote staging and the inspector `QLPreviewView`; **4** for zoom-from-icon animation.

---

### 8. Recommendations summary

1. **Phase 2, reuse Qt's macOS menu merging** — but add explicit `setMenuRole()` calls (none exist today) and hand-build the Window menu. Ship a `dolphinuiformac.rc` alongside the existing `dolphinuiforphones.rc`.
2. **Ship a macOS shortcut scheme, not the Dolphin defaults.** Eight bindings are actively dangerous on macOS; the delete-key/Backspace inversion is the worst and must be fixed before any user-facing build.
3. **Cut aggressively in Phase 2**: Terminal panel, Selection Mode, panel locking/re-docking, Show Menubar, Ark DnD, `act_as_admin`, disk-space-usage menu, KCM pages. Every one of these is D-Bus-, KParts-, or Linux-desktop-bound and none has a macOS audience.
4. **Budget Phase 3 realistically.** `src/kitemviews/` is ~30 files of custom `QGraphicsWidget` view code with no `QAbstractItemView` seam. `KFileItemModel` + `KFileItemModelRolesUpdater` are the reusable core; everything from `KItemListView` down is a rewrite.
5. **Plan for a Baloo-less build now.** Without Baloo you lose the Information panel *and* all item tooltips *and* ~30 of the ~45 detail columns — silently, via `#if HAVE_BALOO`. Decide in Phase 1 whether to stub `Baloo::FileMetaDataWidget` or to build the macOS metadata provider (`MDItem`/`AVFoundation`) as a first-class Phase 3 deliverable.
6. **Build the `RemoteFileStager` once** (temp-copy of remote KIO URLs to local files, with progress and reaping). It is the shared substrate for drag-promises, Quick Look, and "Open With".

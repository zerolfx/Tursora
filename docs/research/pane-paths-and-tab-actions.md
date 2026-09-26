# Split-pane address bars and tab actions

**Later change**: this record keeps the evidence from its own stage; the split-pane title has since been simplified at the user's request to `Left | Right`, dropping the parentheses around the inactive side, and the joining character has since been replaced by a drawn rule (D78) — `Left | Right` remains the plain form used by the Rename Tab sheet and the All Tabs menu; the tab tooltip is still built from the panes' full paths, as recorded below, and the session store still saves only a user-typed custom title. For tab appearance and its verification, see [the later record](tabs-and-appearance.md).

This stage gives every pane its own editable path and fills in the split-pane tab titles and the tab context menu. The final source has completed **1,500 smoke checks three times in a row**, a release build and signing checks, plus the hands-on verification of the packaged app described below; this document records the pinned Dolphin source, the implementation trade-offs and the actual scope of verification separately.

## Dolphin source evidence

Pinned revision: `5e457ee9e88aa6277fbf056cd5c32462c5318866`, checked out locally at `upstream/dolphin`, the same revision as [the Phase 0 pin](../audit/00-ground-truth.md). Every path below is relative to `src/` in that checkout.

| Behaviour | File and lines | Actual semantics |
|---|---|---|
| Two independent address bars | `dolphintabpage.cpp:229–239` | primary and secondary each connect to their own navigator |
| Address bars aligned with the panes | `dolphinnavigatorswidgetaction.cpp:46–52, 102–114` | creates a second navigator and divides the address-bar width according to the geometry of the two content areas |
| Address actions belong to their own pane | `dolphinviewcontainer.cpp:280–305` | a navigator's URL change is wired to the matching view; activating an address bar activates its own view; releasing focus returns it to its own file area |
| Split-pane title | `dolphintabwidget.cpp:536–560` | fixed primary / secondary order; `Left \| (Right)` when the left side is active, `(Left) \| Right` when the right side is active; the inactive side is parenthesised |
| Single-pane title | `dolphinviewcontainer.cpp:581–624` | a search uses the query title, a place can use its Places name, an ordinary local directory uses its last segment, and the root directory uses `/` |
| Custom tab name | `dolphintabwidget.cpp:125–138, 500–503` | a non-empty custom label overrides the automatic title; clearing it restores the automatic title |
| Custom name survives close and restore | `dolphintabpage.cpp:302–327, 397–399` | the custom label is written into the tab state and read back on restore |
| Tab context menu | `dolphintabbar.cpp:175–230` | the menu targets the tab index under the mouse; the seven actions are in the table below |
| New Tab target | `dolphintabwidget.cpp:420–425` | uses the URL of the right-clicked tab's active view to create a new single-pane tab; it does not duplicate both panes or the history |
| Detach Tab | `dolphintabwidget.cpp:399–417` | passes the primary URL, an optional secondary URL and `--split` to a new Dolphin window, then closes the original tab; this is not a full state transfer |
| Close and restore | `dolphintabwidget.cpp:309–325, 351–354` | closing an ordinary tab saves its state first; closing the last tab closes the window; restoring creates the tab and then loads the state |
| Tab bar visibility with a single tab | `dolphintabwidget.cpp:47` | whether it hides automatically is decided by the `alwaysShowTabBar` setting |

Links to the pinned source: [tab titles and actions](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/dolphintabwidget.cpp), [tab context menu](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/dolphintabbar.cpp), [address-bar wiring](https://invent.kde.org/system/dolphin/-/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/dolphintabpage.cpp). The line numbers were read from the local pinned checkout; an unpinned web version is not a substitute.

Menu order and limits:

| Menu item | Dolphin | Tursora |
|---|---|---|
| New Tab | the active URL of the right-clicked tab; creates and activates a single pane | ordinary and ZIP locations use the active logical URL; a search re-runs the active pane's `SearchRequest`, still as a single pane, and does not copy the old results; disabled while the active side is preparing a ZIP |
| Detach Tab | one or two URLs open in a new window, then the original tab closes | the new window rebuilds one or two logical locations, keeping the left-to-right order, the active side, the custom name and each side's search request; it does not carry over history, selection, filtering, scroll position, file tasks or the undo stack; disabled while either side is preparing a ZIP |
| Rename Tab | shown after a separator; sets the name once the user confirms | edits the custom name of the right-clicked tab; an empty name restores the automatic title; it never renames the folder |
| Close Other Tabs | shown after another separator; keeps the target tab | keeps the right-clicked tab; disabled when there is no other tab |
| Close Tabs to the Left | disabled on the leftmost tab | closes only what is to the left of the target; disabled on the leftmost tab |
| Close Tabs to the Right | disabled on the rightmost tab | closes only what is to the right of the target; disabled on the rightmost tab |
| Close Tab | closing the last page closes the window | the last page goes through the existing window-close path, including cancelling and cleaning up the original window's tasks |

## Tursora's conventions and limits

- Each `BrowserViewController` owns its own `BreadcrumbBar`, laid out above the search form and the file area. Both paths are visible at the same time and resize with the pane divider. `TabsController.addressBar` is only a computed property pointing at the currently active pane's address bar, so that existing entry points such as `⌘L` and `⇧⌘G` keep working.
- Clicking one side's path, breadcrumb or completion first activates the pane it belongs to; navigation is handed to that pane alone. The other side's path, query, filter and history do not follow. Switching pane or tab ends path editing at the location being left and dismisses the completion popup, without committing an unconfirmed path and without handing a late callback to the newly active pane.
- Automatic tab titles keep the physical left-to-right order and mark the inactive side with parentheses; a custom name overrides the whole tab. The full paths stay in the tooltip, so the location can still be identified when both sides share a name, when the title is truncated, or when a custom name is set. ZIP locations use the logical path and must not leak the temporary extraction location.
- Search titles use `Search: <name condition>`; with no name condition the title is `Search Results`, so a search is never mislabelled as its source directory. `TabPaneSnapshot` and `TabSnapshot` capture only the logical URL, the search request, the active side and the custom name, and they carry the reopen semantics of New Tab and Detach.
- **The tab bar is always shown**, including when there is only one page, so that the two-path split title and the context-menu entry point stay discoverable. This is Tursora's own default; it does not claim to reproduce all of Dolphin's display settings.
- Context-menu commands capture the actual `TabPage` identity and re-confirm on execution that it still belongs to that window, so that a reordered or closed tab cannot make a stale index act on a different page. Right-clicking by itself does not switch the current tab; after a background or bulk close, the original active page is kept as long as it is still there, and only when the active page itself is closed is an adjacent surviving page selected.
- Reopening a closed tab still preserves the whole page object, both sides' history, the split and the custom name. Detach creates a new window from the locations; it does not transfer the original `TabPage`, in-flight tasks or the undo manager to the other window. The remaining pages in the original window can keep using the original tasks, and closing the original window still cancels tasks and waits for cleanup through the existing mechanism.
- This stage does not add session restore, tab pinning, merging windows, detaching a single pane on its own, general shortcut customisation, or all of Dolphin's tab-bar preferences.

## Focus restoration and fixes

Integration checks found two paths where the active side was right but the keyboard target was wrong: when Detach restores a split whose left side is active, the keyboard focus left behind by creating the right pane has to be handed back to the left explicitly; and when the active pane is closed while its path is being edited, focus has to go to the remaining file area. Closing an inactive pane, by contrast, keeps path editing on the original active side and does not steal focus.

Testing in a real window also exposed field-editor re-entrancy: when AppKit re-acquires the window's shared `NSTextView` for a path field, it can deliver the end-of-editing notification for the previous editing session synchronously. `BreadcrumbBar.beginEditing` holds a guard while the editor is being acquired, and the end notification verifies the text-field object it actually owns; switching uses an end-editing path that does not grab focus back. `PanePathsSmokeTests` shows its own window and makes it key, and requires a real `NSTextView` to exist before checking the first responder, so that two nil references comparing equal cannot produce a false pass. These fixes and the latest editor-acquisition regression are all included in the final three consecutive runs.

## Verification status

- The check against the pinned Dolphin source is complete.
- The full smoke suite on the final source **passed 1,500 checks three times in a row**, all three runs exiting 0 with empty stderr. It covers the list and icon views, address entry and completion on both sides, editing cleanup on switch, ordinary / search / ZIP titles, background right-click targets, menu limits, bulk close, reopen, Detach and focus restoration; the same suite includes this stage's pixel and ICNS regressions for the icon assets. The logs are `/private/tmp/tursora-pane-tabs-verification/final/smoke-{1,2,3}.{out,err}`.
- The release build succeeded, and strict codesign, the Info.plist lint and the check that the bundled ICNS matches the current assets all passed. The build log is `/private/tmp/tursora-pane-tabs-verification/release-final.log`. The build still emits the pre-existing Swift warnings; success is not being described as warning-free.
- The previous stage's 1,253 checks across three features, and its screenshots, are kept as the evidence of that stage; this stage uses the new results above. Hands-on observation of the icon in the system interface is recorded separately in [the icon-edges record](app-icon-edges.md); it is not inferred from the asset checks or the browsing tests here.

## Hands-on checks on the packaged app

The following were done through real interaction with the interface:

| Scenario | Observed result |
|---|---|
| Independent left and right paths | typing the relative path `Design` on the left navigated only the left side, while the right stayed at `Delivery`; Back returned to the previous location, and the automatic tab title and the active-side marker followed |
| Path editing and completion | clicking the other pane mid-entry quietly cancelled the uncommitted path; the completion popup offering `Design` and `Design-Review` appeared as expected, and the other pane's directory did not change |
| Right-clicking a background tab | the seven items and their disabled limits were checked against the accessibility tree and verified with real clicks; the context-menu target never fell back to the current tab |
| Rename Tab | the custom name appeared on the target tab, and clearing it restored the automatic two-sided title |
| New Tab | New Tab from a background tab's context menu inherited the location of the clicked tab's active pane; `⌘T` also created tabs normally |
| Detach Tab | the new window restored both URLs and the active side; its navigation history did not inherit the original page's history. That the custom name survives Detach is covered by the automated checks |
| Narrow window and re-expansion | the window was resized from 560 wide to 1200 wide, and the address bars and tabs re-laid out with it |

Real screenshots have been updated: [split panes and independent paths](../images/features/split-panes.png), [path completion](../images/features/path-navigation.png), [tabs](../images/features/tabs.png). The screenshot tool is unavailable while an `NSMenu` is open, so verification of the tab menu relied on the accessibility tree and real clicks: **there is no screenshot of the open menu**; `tabs.png` shows the tab interface after the menu was dismissed. The search / ZIP and lifecycle limits that the automated checks cover are not additionally claimed to have been exercised by hand in this stage.

The product page was updated with the same three images and their sizes and copy. The static build passed (5 assets, 36 references); at 1280 × 720 on the desktop and 390 × 844 on a narrow screen, the icon and the new screenshots were checked, the tab and path image lightboxes displayed at the correct aspect ratio, focus returned to the triggering link after closing, and there was no horizontal overflow on the narrow screen. This stage does not re-claim the full browser fallback checks from the earlier stage. The test app and preview page used here have been quit, and the original preferences, the directory view-properties store and the shared verification lock have been restored.

## Reliability follow-up, 2026-09-26

Address completion now resolves, enumerates, filters and sorts on bounded background workers with a short-lived directory cache. Delivery validates the editor session, text, caret and location; pending Tab and Shift+Tab preserve native focus traversal when there is no match. Implementation and current automated/packaged verification are recorded in [the reliability record](reliability-2026-09-26.md).

# Drag and drop: spring-loaded folders, breadcrumb drops, ⌘ force move

This record covers how three Finder drag-and-drop behaviours landed in Tursora: **spring-loaded folders**, **breadcrumb segments as drop targets**, and **⌘-drag force move**. The shared drop rule is still `FileOperations.dropOperation(for:into:sourceMask:)`; only the ⌘ branch is new this time, and the rest of the decision is unchanged.

Related code: `app/Sources/Tursora/Model/DragAndDrop.swift`, `app/Sources/Tursora/UI/SpringLoading.swift`, `app/Sources/Tursora/UI/BreadcrumbBar.swift`, `app/Sources/Tursora/DragAndDropSmokeTests.swift`.

---

## 1. Evidence (actually read on this machine)

### 1.1 AppKit headers — `NSDragOperation` and the spring-loading protocol

Source: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSDragging.h` (Xcode Command Line Tools, macOS 26 SDK).

**Observed** (lines 25–33):

```
NSDragOperationNone    = 0,
NSDragOperationCopy    = 1,
NSDragOperationLink    = 2,
NSDragOperationGeneric = 4,
NSDragOperationPrivate = 8,
NSDragOperationMove    = 16,
NSDragOperationDelete  = 32,
```

**Observed** (lines 165–198): `NSSpringLoadingOptions` (`NSSpringLoadingDisabled` / `NSSpringLoadingEnabled` / `NSSpringLoadingContinuousActivation` / `NSSpringLoadingNoHover`, macOS 10.11+) and the `NSSpringLoadingDestination` protocol: the required methods `springLoadingActivated:draggingInfo:` and `springLoadingHighlightChanged:`, the optional `springLoadingEntered:` / `springLoadingUpdated:` / `springLoadingExited:` / `draggingEnded:`. The header's own comment on `NSSpringLoadingEnabled` says that activation happens by "Force Click release and hover timeout **depending on user preferences**" — **the timer belongs to the system; the application does not implement it**.

**An observed gap (important)**: this header does **not** document any "modifier key → mask narrowing" mapping. The only modifier-related items in the whole file are `ignoreModifierKeysForDraggingSession:` (line 159) and a deprecated `ignoreModifierKeysWhileDragging` (line 207); `draggingSourceOperationMask` (line 72) is described only as the operation mask of the drag source. Searching `NSDragging.h` and `NSPasteboard.h` for `option key`, `command key`, `control key` and `modifier` produced no description of the mapping.

**Inferred (could not be confirmed from the headers on this machine)**: that ⌥ → `.copy`, ⌃ → `.link` and ⌘ → `.generic` is AppKit runtime behaviour (the long-standing convention from Apple's *Drag and Drop Programming Topics*), and the implementation follows it. It does so by **only widening what the drag source offers** rather than guessing the narrowing logic: `.generic` is added to the source mask, the destination reads `NSDraggingInfo.draggingSourceOperationMask` back, and a mask exactly equal to `.generic` is taken to mean ⌘. If the real mapping differs on some macOS version, the result is that a ⌘ drag degrades into an ordinary drag rather than the wrong file operation — a deliberately chosen direction in which to fail. A headless run cannot produce a real modifier-key drag, so this item has **rule-level verification only, with no automated evidence from a real ⌘ drag**.

### 1.2 Spring loading in Finder

Commands and output (on this machine):

```
$ strings -a /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder | grep -i spring | sort -u
NSSpringLoadingDestination
TSpringLoadingDestinationDelegate
SpringingEnabled
SpringingDelayMilliseconds
com.apple.springing.delay
com.apple.springing.enabled
com.apple.springing.prefchanged
-[TBrowserWindowController springDragEnterWindow:]
-[TBrowserViewController springNodeDetails:globalMouse:spawnNewWindow:]
_springCloseWhenDragLeavesWindow
_springRememberedTargetPath
_springRememberedViewStyle
_springRememberedWindowWeWereBehind
_springToFrontTimer
anyWindowIsSpringing
...
```

```
$ defaults read -g com.apple.springing.enabled   → 1
$ defaults read -g com.apple.springing.delay     → 0.5
```

**Observed conclusion**: Finder itself uses `NSSpringLoadingDestination`; the switch and the delay live in the global domain as `com.apple.springing.enabled` and `com.apple.springing.delay` (enabled and 0.5 seconds on this machine). Tursora therefore **builds no timer of its own** and only declares the destination, leaving the delay and the switch to be decided uniformly by the system; Tursora's `DragAndDrop.systemSpringLoadingDelay` only reads that key, for diagnostics and for the smoke-test record.

**Observed**: symbols such as `_springRememberedTargetPath` and `_springCloseWhenDragLeavesWindow` show that Finder rolls back the windows it sprang open once the drag has left. **Tursora does not implement that rollback** (see the limits in §4).

**Wording evidence**: searching `Base.lproj/*.nib`, `en.lproj/Localizable.strings` and `LocalizableMerged.strings` for `spring` produced no hits (`strings -a .../Base.lproj/PreferencesWindow.nib | grep -i spring` returned nothing). This implementation **adds no user-visible wording, menu item or dialog at all**, so there is nothing here whose phrasing would have to match Finder's; "spring-loaded folders" in the title above is only this record's own shorthand and does not appear in the interface.

### 1.3 Finder's path bar (breadcrumbs)

```
$ strings -a /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder | grep -i pathbar | sort -u
TPathBarController
TEphemeralPathBarDisplayController
-[TPathBarController pathControlSingleClick:]
-[TPathBarController pathSelect:didSelectNode:]
ShowPathbar / ShowEphemeralPathBar / PathBarRootAtHome / SingleClickPathBarRetarget
...
```

**Observed**: Finder's path bar is built on `NSPathControl` (`pathControlSingleClick:`, `pathSelect:didSelectNode:`). Line 34 and lines 105–116 of `NSPathControl.h` document its drop support: it accepts drops when editable, and `pathControl:validateDrop:` / `pathControl:acceptDrop:` allow customisation.

**Inferred**: the default drop semantics of `NSPathControl` are "change the control's value", whereas **"dropping files on a segment moves them into that folder" is Finder's own behaviour**, which cannot be confirmed directly from the symbols above; this record was written without screen access, and no manual side-by-side observation of Finder was made. The semantics Tursora adopts are "exactly the same shared rule as the list, the grid, the sidebar, the folder tree and the tab bar, with the folder the segment points at as the target" — a choice consistent with this project's existing rules, not a claim to reproduce Finder.

---

## 2. Implemented behaviour

### 2.1 ⌘ force move

The decision order in `FileOperations.dropOperation` (only step 4 is new):

1. An empty drag → reject.
2. The target is one of the dragged items → reject.
3. `sourceMask == .copy` (⌥) → copy, **always**.
4. Dropping into the folder the items are already in → reject.
5. **`sourceMask == .generic` (⌘) → move, across volumes as well.** (new)
6. Same-volume move / cross-volume copy.

The drag source masks are centralised in `DragAndDrop.sourceMask(readOnly:local:)`: a writable local source gets `[.copy, .move, .generic]` and an external one `[.copy, .move, .link, .generic]`; a read-only source (a ZIP entry) still gets only `.copy`, so on a read-only source ⌘ and ⌃ narrow to an empty mask and the drop is rejected — archive contents can be copied out but not moved, which is unchanged.

`DragAndDrop.validationOperation(_:sourceMask:)`: AppKit narrows the mask of a ⌘ drag to `.generic`, and the validation method has to answer within that mask or the destination stops accepting; so when the rule decides `.move`, the answer given to AppKit is `.generic`. Execution is unaffected — `BrowserViewController.dropFiles` treats every operation that is not `.copy` as a move. `validateDrop` in both file views and in the folder tree now goes through this layer; `acceptDrop` still uses the shared rule directly, and what is passed to `onDropFiles` is still `.move`.

### 2.2 Spring-loaded folders

- `FileOutlineView`, `FileCollectionView` and `SidebarOutlineView` (shared by the sidebar and the folder tree) declare `NSSpringLoadingDestination` in an extension, adding no stored properties: each view finds its owning controller (`SpringLoadingHost`) through its own `dataSource` or `delegate`.
- The views **only report**: they hand the pointer location, the dragged URLs and the narrowed mask to the controller, and the controller does the navigating. **The views never touch the filesystem**, and spring loading itself moves or copies nothing.
- The decision is `DragAndDrop.canSpringLoad(into:isNavigable:isReadOnly:urls:sourceMask:)`: it springs open only where a drop would be accepted, and additionally excludes files, read-only panes, archive locations, the dragged items themselves, and the folder the dragged items are already in (⌥ drags are excluded there too — the shared rule answers `.copy` for ⌥, but that is not the navigation the user asked for).
- What each destination does: list and grid → the pane navigates into that folder; the Places sidebar → that place is selected (`onSpringLoad` is wired by `MainWindowController` to `browser.navigate`); the folder tree → **the node expands in place** and the pane does not navigate.
- The existing drop validation is entirely unchanged.
- Headless test entry points: `activateSpringLoading(atRow:urls:sourceMask:)` (list, sidebar, folder tree) and `activateSpringLoading(at:urls:sourceMask:)` (grid, by `IndexPath`) — the same path AppKit takes once its timer fires.

### 2.3 Breadcrumb drops

`BreadcrumbBar` registers `.fileURL`, and every **visible** segment is a drop target:

- `segmentIndex(at:)` only hits segment buttons that are not collapsed; segments hidden in the `…` overflow menu are **not** targets (out of scope this time).
- `dropOperation(for:atSegment:sourceMask:)` applies the shared rule to that segment's URL, and rejects archive locations and the editing state (while the path text field is open, the whole bar accepts no drops).
- `performDrop(urls:sourceMask:onSegment:)` calls `onDropFiles`, which `BrowserViewController` wires to the existing `dropFiles(_:to:op:)` — undo, `DirectoryChanges.post`, conflict handling and transfer tasks all follow the existing path.
- While hovered, the segment is highlighted (a translucent layer of `selectedContentBackgroundColor` behind it), and the highlight clears as soon as the drag leaves or ends.

---

## 3. Verification

`DragAndDropSmokeTests` (`checkPrefix = "drag and drop: "`):

- **Pure rules**: the source masks (writable / read-only, local / external, ⌘ narrowing to empty on a read-only source); the four cases of `validationOperation`; and, for `dropOperation`, same-volume move, cross-volume copy, ⌥ copy, ⌘ same-volume move, ⌘ cross-volume move, ⌘ still rejecting the items themselves and the folder they are already in, and an empty drag rejected. The cross-volume case uses a non-existent target path as a stand-in — it has no volume identifier, so `sameVolume` is false and no volume has to be mounted.
- **Pure spring rules**: no spring for a file, for the items themselves, or for the folder they are already in (with both the ordinary and the ⌥ mask); no spring for a read-only location, for the end of a drag (empty URLs), or with no target; `springLoadingOptions` agrees with `canSpringLoad`; the system delay key is readable.
- **Breadcrumbs** (in both the details and the icons view, with split panes and grouping): the last segment is the current directory and the one before it is the parent; a drop on the parent segment is a move, ⌥ is a copy, ⌘ is a move, a drop on the segment the items are already in is rejected, a drop on empty space is rejected, and an empty drag is rejected; button hit-testing; the whole bar rejecting drops in the editing state; and, after a real drop, the file really did move to the parent directory.
- **Spring-loading UI** (details and icons, with split panes and grouping): no spring on a file row or icon, no spring for a drag already in that folder, no spring at the end of a drag, no spring for an out-of-range row or index, no spring on a group header row, no spring in a read-only pane; hovering a folder springs it open once and only once, the pane navigates into it, the other side of the split does not move, and no file is moved.
- **Sidebar and folder tree**: no spring on a section header, no spring at the end of a drag, and hovering a favourite springs it open and reports that location; a folder-tree node expands in place and the pane does not navigate; neither moves any file. The favourites order is restored when the suite finishes.

The fixture directory is `$TMPDIR/tursora-drag-drop-<UUID>`, deleted after use; the user's real files and preferences are neither read nor rewritten (`favouritesOrder` is saved and then restored).

---

## 4. Limits and what was not done

- **There is no automated evidence for real ⌘/⌥/⌃ modifier-key drags**: a headless run cannot produce a real dragging session, so only the rules and the masks can be verified. The headers on this machine do not document that mapping either (§1.1).
- **Breadcrumb segments hidden in the overflow menu are not drop targets**, deliberately excluded by the scope of the task.
- **Finder's "roll back after springing open" is not implemented**: Finder remembers the window and the view from before it sprang open and restores them once the drag leaves (`_springRememberedTargetPath` and the like); Tursora stays where it sprang to.
- **Force Click activation is not verified**: `NSSpringLoadingEnabled` supports both hover and Force Click; `NSSpringLoadingContinuousActivation` was not set this time, and there is no automated verification of trackpad pressure.
- **There is no computer-use evidence (screenshots or manual side-by-side comparison)**: everything in this record comes from reading binaries, headers and `defaults` on this machine, plus the smoke tests; no visual observation was made of Finder or of the packaged Tursora.

# Workspace session restore (2026-09-13)

## Product scope

Users named the loss of split panes and multiple tabs after quitting as a key obstacle to daily use, so this round implements restore-on-launch first. The feature is a Tursora product choice; it makes no claim to copy Finder's or Dolphin's session semantics item by item.

**Reopen windows and tabs on launch** under Settings → General → Startup is on by default. A restart restores browser windows, window geometry and minimised state, sidebar width and collapse, tab order and the current tab, custom names, the one or two panes per tab, the active side and the split ratio. Mode, sorting, grouping and zoom for ordinary directories are still read from the existing per-directory view store.

A search that has already run saves its criteria and is re-run, so the results reflect the files as they are now. A ZIP saves the logical path of the original archive plus the directory inside it, and re-prepares the read-only content on restart; the already extracted temporary directory cannot be saved as a working location. When the experimental ZIP option is off, a location that can be recognised as a real archive falls back to the archive's parent directory; an offline location keeps its original path and is not guessed from the `.zip` suffix, because it may equally be an ordinary directory.

The first version does not save filter text, selection, scroll position, navigation history, closed tabs, terminal processes / panels, transfer tasks or the undo stack. Closed windows and tabs are not resurrected; if there is no browser window at quit, the next launch opens Home. A location that is invalid or not mounted keeps its path and uses the existing inline error, so it can be refreshed or navigated away from later; it is not silently replaced with Home, and servers are not mounted automatically.

## Storage and lifecycle

- `WorkspaceSessionStore` saves version 1 JSON at `~/Library/Application Support/Tursora/WorkspaceSession.json`; it writes no files into browsed directories.
- Meaningful changes are saved with a 0.4 second debounce; quitting saves the final snapshot synchronously, and only afterwards cleans up the ZIP temporary content, terminals and the undo log.
- A staging file in the same directory is created with 0600 permissions first, written and synced, then atomically renamed. On error the old file is kept; Settings shows the error and a retry action.
- At most 16 windows, 32 tabs per window and two panes per tab, with a maximum of 2 MiB per file. Reading discards invalid structures one by one and corrects the selected position. When the current workspace exceeds the window / tab capacity, the save reports an error and keeps the old file; it must not truncate silently.
- Non-local URLs, credentials, NUL paths and invalid geometry are rejected; whether a path exists is left to asynchronous browsing, so a temporary offline state is not taken for permanent deletion.
- A file that is corrupt, of an unknown version, or that fails to read keeps its original bytes; launch and quit must not overwrite it automatically. Only when the user clicks Retry Saving Workspace, or turns the restore option off and on again, is it re-saved from the current workspace.
- Turning the restore option off immediately clears the saved content and stops auto-saving; turning it back on saves the current windows and does not replace the current layout on the spot. A failed cleanup also gets an inline retry.
- When an explicit request to open a directory arrives before launch, the saved content is still restored and the explicitly requested window is brought to the front. Window positions are constrained to the visible area of the current displays, so a display that has been removed cannot leave a restored window off-screen.

## Sidebar width diagnosis

Round 4 of the diagnosis confirmed a 1000 × 640 window: the test found the real sidebar `NSSplitView`, called `setPosition(245, ofDividerAt: 0)` and laid out again, and the sidebar still went back to 160 pt, so the window was not too narrow. The earlier test's hierarchy assumption, that `sidebar.view.superview` is the split view, has also been corrected.

The SDK evidence on this machine is at `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSSplitView.h`: line 79 states that `setPosition` is constrained in the same way as a user drag; lines 83–86 state that a holding priority should be lower than `NSLayoutPriorityDragThatCannotResizeWindow` (490), and that the pane with the lower priority absorbs window size changes first. `NSSplitViewItem.h` lines 115–116 confirm that the item's property of the same name controls the width-holding priority; the default value is 250.

The sidebar was originally configured as `.defaultHigh` (750), above the drag priority. The production fix changes it to **260**, still above the content pane's default of **250** and below the drag priority of **490**; no fixed width constraint is added, so the user keeps the ability to resize and to collapse / expand. The fix passed together with the final three rounds; in the packaged app a real drag moved the sidebar from 190 to 245 points, and it was still 245 points after a restart — see the on-machine record below.

## Verification boundaries

The model and storage checks cover the JSON round trip, per-entry corruption, capacity, selection correction, permissions, atomic-publish failure and retry, unknown versions and original-byte protection. The UI / lifecycle checks cover both file views, background tabs, narrow-to-wide splits, re-running a search, re-preparing a real ZIP, invalid paths and the toggle, saving on immediate quit, and explicit launch requests.

The final 81 Swift source files **passed 2,418 smoke checks three times in a row**, each round with exit 0 and empty stderr, and with identical source hashes before and after the run. The tests corrected the sidebar's native ancestor hierarchy, a fixed window width, and location comparison for the macOS `/var` / `/private/var` equivalence; for the real sidebar priority fix, see below.

Review additionally fixed three things: after a failed ZIP navigation the saved location did not go back to the directory still on screen; clearing a search did not trigger an auto-save; and a failed cleanup after turning restore off was not retried at quit. All three gained real-path regression checks, and all of these paths passed with the final three rounds.

## Release bundle and a real restart

The debug / release builds, strict codesign and the Info.plist lint all passed. The test copy uses its own bundle identifier `com.tursora.sessionqa.s0913`, its own session file and its own per-directory view store; the product bundle identifier stays `com.tursora.Tursora`. The machine-code `__TEXT.__text` hashes of the two bundles are identical, so the whole-file difference caused by re-signing is not misrecorded as byte-for-byte identity. QA turned off Sparkle's automatic check and touched neither production preferences nor the production session file.

Two windows were built through the real interface from one demo directory: the main window holds the three tabs Daily work / Inbox / Archive, where Daily work has Design on the left in the list view and Assets on the right in the icon view and active; the sidebar was really dragged to 245 points and the two-pane ratio to 0.5738569753810082, and the second Archive window was minimised. After a normal ⌘Q and a relaunch, the tab names and order, the selected tab, the active right side, both views, the ratio, the sidebar, the window positions / sizes and the one minimised window were all restored. Switching tabs auto-saved again, and the complete JSON was identical to the snapshot from the first quit.

When the Settings → General toggle was actually turned off, the file disappeared immediately; after a normal quit the next launch opened only a single-tab window at Home, with the setting still off. Turning it back on after navigating to the demo Design saved the current single window and did not resurrect the earlier layout. All three QA processes exited normally and the verification lock was released.

Real screenshots: [the restored workspace](../images/features/workspace-restored.png), [the General startup options](../images/features/settings.png). The native capture is JPEG, converted to a true PNG with `sips` and visually re-checked, keeping the original outer edges, the system sharing indicator and the mouse position; no UI pixels were generated or retouched. The windows are 1100 × 712 and 540 × 737 respectively.

The automation covers invalid directories, ZIP re-extraction, bad files and unknown versions, cleanup failure at quit and so on; the on-machine scope this round was the local demo directory and the restart setting, and simulated offline paths or screen-geometry tests are not recorded as real measurements on an external volume / multiple displays. No new release was published.

Evidence files:

- `/private/tmp/tursora-session-verification/final-smoke-{1,2,3}.{out,err}`, `final-results.json`, `final-source-hashes.json`; 2,418 checks per round.
- `/private/tmp/tursora-session-verification/package-final.log`; the release bundle build.
- `/private/tmp/tursora-session-e2e/after-first-quit.json`, `after-restored-interaction.json`, `ui-results.json`, `bundle-evidence.json`, with the original screenshots and AX text kept in the same directory; the QA files are not committed.

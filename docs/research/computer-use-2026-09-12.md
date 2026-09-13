# Checking the new features on a real machine (2026-09-12)

Environment: macOS 26.3 (25D125), dark mode; `app/build/Tursora.app` driven through computer use. The version first checked was 0.1.0 (2), corresponding to `cba1ccb`. This record supplements the automated smoke run; it does not treat UI tree or model checks as visual verification.

Every file operation used samples created this round inside `/tmp/tursora-visual-check`: `Sample Files/Welcome.txt`, `Sample Files/Notes/Checklist.txt` and a `Sample.zip` that keeps the top-level directory. No user file was renamed or archived.

## Operations carried out

| Check | Actual result |
|---|---|
| Settings window | Text and controls in the General, Keyboard and Experimental sections are complete and do not overlap; both experimental features start off |
| Filter shortcut | Recording ⌘Q was caught by conflict validation and the app did not quit; after recording ⇧⌘F the filter field can be focused, and Reset restores ⌘F |
| File name filter | `*.zip` keeps only the ZIPs and the count is correct; Escape clears it, with no extra Filter / folder scope row |
| Hiding extensions | `Sample.zip` is shown as `Sample` and folder names are unchanged; turning the display back on updates immediately |
| Cancelling a rename | The editors in List and in Icons both contain the full `Sample.zip` with the basename selected; typing `MustNotRename` and then pressing Escape restores the original name in both, and a disk check found no wrongly renamed artefacts |
| Window layout | The sidebar and the content area share a flat boundary; the Home icon is sized in keeping with the other items; the title bar has no duplicated path; the buttons at the top left stay in place while the sidebar is collapsed / expanded |
| Favorites and grouping | The Group menu still opens after clicking Home; grouping by Kind works, and the icon view really shows the Folders / Other headings |
| Terminal | F4 shows zsh and renders it correctly; `pwd` is right; `sleep 30` can be interrupted with Ctrl-C |
| Terminal and directory switching | An uncommitted `printf terminal-input-kept` stays as it is after navigating in the browser; Restart in Current Folder starts a new session in a path containing a space, with the correct `pwd` |
| Terminal lifecycle | While a foreground command is running, Restart shows a confirmation and Cancel cancels it; hiding with F4 and reopening gives a new session; the panel disappears once the setting is disabled |
| ZIP browsing | The separate read-only window keeps the top-level `Sample Files`, Notes can be entered, Back / Up work and the buttons are disabled at the root; the note about the temporary copy at the bottom wraps in full |
| Opening a file inside a ZIP | Return opens Welcome.txt, and TextEdit shows the expected content and the path inside the app's temporary directory; the document is still readable after the ZIP browsing window is closed; the document was closed at the end of the test and was not edited |
| The More menu and sharing | Actions enable with the selection, and the menu has no file Tags or Import from iPhone; the native share popover shows the selected file's name / type and the system services, and nothing was sent |
| Compress and extract | Compress produces `Sample Files.zip`; an explicit Extract still works while the browsing experiment is on, keeping the directory of the same name and producing `Sample Files 2`; undo removes the product and redo brings it back |
| Default ZIP behaviour | With the ZIP browsing experiment turned off, an ordinary Open goes back to extracting, producing `Sample Files 3` and selecting it |
| Checking archive content | Reading the ZIP and comparing bytes on disk confirmed that the two text files come through compression / extraction unchanged |
| Server form | ⌘K opens the form; `sftp://example.invalid/test` is caught by local validation, which lists the supported protocols with no text truncated; cancelling works |
| Icon | The About window shows the abstract blue fin over one background layer, with none of the older inset square blocks |

## Problems found and fixed

After the list refreshed, the first folder would hide underneath the column headers, while AX still had the item and the disk content and item counts were correct. It was first found through Extract → Undo → Redo in List + Kind; it could then also be reproduced with Compress in an ungrouped list. Scrolling up and turning grouping off did not bring it back; opening / closing the terminal, which triggers a relayout, did.

The root cause was that scroll restoration clamped the original clip y to zero, whereas the system header means that the true top can sit at a negative y. The logical distance is now saved relative to the native top and restoration is left to `NSClipView.constrainBoundsRect`; the horizontal position is preserved as well.

A 0.1.0 (3) release package containing the fix was built and driven through computer use again: after Compress in a plain list produced `Sample Files 2.zip`, the first row was fully visible and could be selected by clicking; under Kind, Open extracted to `Sample Files 4`, and after Undo / Redo every folder and group header was fully visible, with a click on the first `Sample Files` selecting it correctly; the first row was still fully visible once grouping was turned off. Nothing relied on toggling the terminal or resizing the window to recover.

Automation gained checks for a controlled header inset, a non-zero logical position, horizontal scrolling and a shortened list; the refresh chain for archive operations also compares the actual geometry of the row against the header, the row height and the hit test of a click, rather than checking AX counts alone.

The final debug build passed, with **618 smoke checks passing three rounds in a row** (13 more than before); the logs are `/tmp/tursora-cua-fix-smoke-{1,2,3}.log`. The final release package was rebuilt and its ad-hoc signature verified.

## Wrap-up and limits

Restored after the test: showing all extensions, ⌘F, the terminal off, ZIP browsing off; the filter cleared and grouping turned off. The test document has been closed.

Not covered yet: real server authentication / mounting / reading and writing / Eject, PTY reaping when the owning browsing window is closed, and light mode and every screen size. No real server was available, so this round verified only the connection form and protocol validation. The terminal uses the user's configured local shell, and no remote connection was made.

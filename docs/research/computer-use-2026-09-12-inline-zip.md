# Packaged-app check of ZIP in the current pane and the split interface (2026-09-12)

This round drove the actually packaged `app/build/Tursora.app` through computer use. The first half used bundle build 5; after the server form was fixed, debug / release were rebuilt and that form was retested with the corrected version and its screenshot replaced. A demo project and the dark appearance were used; the record contains only the results of real operations, and never substitutes the existence of a screenshot file, the AX tree or the smoke test for a visual check. The results for the earlier standalone ZIP window stay in the [previous record](computer-use-2026-09-12.md) and are not evidence for this round's same-pane flow.

## Interface and interactions observed

| Check | Actually observed | Screenshot saved |
|---|---|---|
| Toolbar split | The split button works, and the interface shows side-by-side panes | [split-panes.png](../images/features/split-panes.png) |
| The other pane from Favorites | Open in Other Pane in the context menu creates a split, and the original pane keeps its directory | [favorites.png](../images/features/favorites.png) |
| A new tab from Favorites | Open in New Tab creates a third tab and opens the right-clicked place | Same as above; the menu screenshot by itself does not prove the navigation that followed |
| Name column in a narrow split | With the name column's minimum width changed to 180 pt, file names are readable in a narrow pane; the matching smoke check is included in the final three consecutive passes | [split-panes.png](../images/features/split-panes.png) |
| Path completion | Typing a path really does pop up the Design / DesignArchive candidates | [path-navigation.png](../images/features/path-navigation.png) |
| Name filter | `*.png` filters only the active pane; the other pane keeps its contents | [name-filter.png](../images/features/name-filter.png) |
| List / icon views and grouping | Both views and Kind grouping were driven and observed | [views-and-groups.png](../images/features/views-and-groups.png) |
| Quick Look | A text file shows its preview content | [quick-look.png](../images/features/quick-look.png) |
| System share | The Share picker really appeared; nothing was sent | [share.png](../images/features/share.png) |
| Settings shown in the example | Both experiment switches are off in the screenshot; this is not the user's original ZIP preference at the end of this round | [settings.png](../images/features/settings.png) |
| Entering and navigating a ZIP | ⌘↓ enters the ZIP root in the current pane and keeps the original root structure; double-clicking Documents enters the inner directory. Up returns to the root with Documents selected, and Up again leaves the ZIP with the original ZIP selected; Back / Forward produce no path errors | [zip-browsing.png](../images/features/zip-browsing.png) |
| ZIP read-only menu | In More, New Folder, Get Info, Rename, Duplicate, Compress, Extract, Paste and Trash are all disabled | Same as above |
| Opening a file in a ZIP | Open hands the ReleaseNotes text to TextEdit, which shows the demo content and the private temporary snapshot URL | The temporary path appears only in the external editor and is not a navigation path of the pane |
| Copying out of a ZIP and undo | ⇧⌘C copies the 167-byte file into an ordinary Delivery pane, and ⌘Z removes the copy | The result of the operation was checked; a screenshot is no substitute for the byte result |
| File conflict | Keep Both creates a numbered copy of README at 153 bytes and the existing 63-byte file is kept; ⌘Z removes the copy | [file-operations.png](../images/features/file-operations.png) |
| Compress / Extract display | The screenshots of these interfaces were saved and checked; the full compress / extract round trip of the earlier version stays in the old record | [compress-extract.png](../images/features/compress-extract.png) |
| Terminal | F4 opens zsh, and pwd / ls show the same demo project; afterwards the terminal was closed and the experiment restored to off | [terminal.png](../images/features/terminal.png) |
| The server form after the fix | A valid SMB address does not start a connection on Tab; Cancel closes the form, and reopening it is still editable with no spinner; an ftp address submitted with Return shows a protocol error, and changing it to a valid address clears the error; Escape closes | [connect-server.png](../images/features/connect-server.png), replaced with the final corrected version |

## Findings this round and how they were handled

- A new pane's delayed initial navigation could override a place explicitly chosen afterwards. The implementation now adds a `navigationGeneration == 0` condition; the regressions around windows, the sidebar and tabs passed along with the final consecutive smoke runs.
- In a narrow split the name column was squeezed by the other columns; the name column's minimum width was set to 180 pt, and build 5 was observed to show readable names. The automated geometry check passed along with the final consecutive smoke runs.
- The server address field used to fire its action when it lost focus, so clicking Cancel could start a mount as well. It is now limited to an explicit submit, and the corrected-version CUA listed in the table above was carried out: Tab / Cancel do not connect, reopening leaves the state correct, Return triggers protocol validation, editing clears the error, and Escape closes. The dedicated new regression checks passed the final three rounds; real server authentication or a successful mount was not verified this time.
- The ZIP temporary snapshot alias check once exposed a path remapping problem, which has been fixed; the matching regression is part of the final three consecutive passes, and the failing run does not count towards the passing rounds.

## Screenshot method

The target window is captured with the native `screencapture -x -o -l<windowID>`, which can also preserve the state of the relevant menu. An attempt to capture by screen rectangle with `-R` once caught a background application by mistake; the wrong image was replaced, and later captures went by window ID with their contents checked. The 11 images returned by CUA were actually JPEG and were given the `.jpg` extension that matches their real format; the two native captures of Favorites and Compress / Extract keep `.png`, and no image pixels were modified. For the rules on maintaining screenshots see [images/README.md](../images/README.md).

## Screenshots, builds and the final automation status

All 13 sets of README screenshots have been saved and checked one by one, including compress / extract, file operations, ZIP, the terminal and servers; the server screenshot has been replaced with the final corrected version. The demo images show the relevant interfaces; a menu screenshot is not stretched into evidence for a file operation or remote connection that was never performed.

The final debug build passed; release build 5, which carries the latest path remapping fix, was rebuilt and passed the strict codesign check. The final **739-check smoke test passed three times in a row**, with all three processes exiting 0 and empty stderr. The logs are `/tmp/tursora-alias-fixed-smoke.log`, `/tmp/tursora-final-smoke-2.log`, `/tmp/tursora-final-smoke-3.log`. The final test includes the name column, snapshot alias and server form regressions; the earlier alias assertion failure is resolved, and neither the old version's single pass nor the failing run counts towards these three rounds.

## Wrap-up and limits

The user preferences from before this test have been restored: show extensions = on, filter shortcut = ⌘F, terminal experiment = off, ZIP browsing experiment = on. ZIP being on is the user's own earlier choice and does not change the spec that the feature is off by default on a new install. The demo Favorite was removed and the removal checked.

Real server authentication, mounting, reading and writing, dropped connections and Eject are not verified. Process reclamation when the terminal's owning browser window is closed, the drag-out gesture from a ZIP and dedicated CUA for Quick Look / Share inside a ZIP, light mode, and the full set of screen sizes were still not covered item by item this round; the corresponding model / integration checks are no substitute for these visual or server-side verifications. For the historical terminal interrupt, Restart and turning the experiment off see the [earlier record](computer-use-2026-09-12.md).

## Tidy-up stage and the product page

The first stage was committed and pushed as `fbb6762`, and the corresponding [GitHub Build](https://github.com/zerolfx/Tursora/actions/runs/34671658320) succeeded. The tidy-up that followed only removed an unused constant in PlacesModel and dropped the always-true parameter / forwarding overload of the archive reading helper, without changing application behaviour.

After the tidy-up, the debug and release build 6 both built successfully and passed strict codesign. The **739-check smoke test passed three consecutive rounds again**, each exiting 0 with empty stderr; the logs are `/tmp/tursora-tidy-smoke-1.log`, `/tmp/tursora-tidy-smoke-2.log`, `/tmp/tursora-tidy-smoke-3.log`. These are new runs from the tidy-up stage and are not mixed with the three logs of the first stage.

[tabs.png](../images/features/tabs.png) was additionally saved and checked, at 1241 × 590, showing three tabs of the real application with Documents expanded. This image is used for the tabs feature on the product page; the interface after the tidy-up keeps its previous behaviour, which does not mean that every CUA item of the first half was redone.

The Chinese product page is limited to four features — the address bar, tabs, split panes and read-only ZIP — using screenshots of the real application. `python3 site/build.py` generated `site/dist/` successfully, containing the 5 required source assets (the icon and four screenshots) and passing 36 reference checks; the build uses only the Python 3.9+ standard library. The website verification was done separately from the application smoke test; the site is currently only previewed locally and has not been deployed.

### Product page browser checks

| Check | Actual result |
|---|---|
| Desktop layout | The page was actually viewed at 1280 × 720; the contrast of the secondary text has been raised, and the header clipping caused by jumping straight to an anchor has been fixed |
| Narrow layout | Neither 390 × 844 nor 320 × 740 overflows horizontally |
| Switching between the four features | Clicks, arrow keys and End all switch the matching tab / panel |
| Screenshot dialog | The large ZIP image opens, and Escape closes it and returns focus to the image link that triggered it |
| Plain page anchors | Going straight to `#feature-zip` selects only the ZIP tab and shows only the matching panel |
| Images and the console | No image load errors, and console warn / error are empty; a placeholder img with no src inside an unopened dialog does not count as a load failure |
| Without JavaScript | Verified by temporarily removing the HTML script tag in dist: all four panels are visible and the ZIP anchor works; the build was then rerun and the temporary QA page deleted |

No dedicated reduced-motion check is claimed to have been completed; this round's local browser results say nothing about deployment, testing on a real mobile device, or the online availability of the GitHub download links.

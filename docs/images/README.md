# README screenshots

`features/` contains 29 PNG screenshots from actual packaged-app or installer states. The README references 19 feature images in two HTML tables (12 regular features and two terminal/ZIP features), plus a DMG installation image in the download section. All 29 have transparent exterior corners and antialiased edges, with light/dark contact review covering the full inventory. The app icon and status badges are separate from that count. Do not use mockups as evidence of implemented features.

The product page reuses `path-navigation.png`, `split-panes.png`, and `zip-browsing.png`. Update these canonical files here; the site build copies them unchanged. `tabs.png` remains implementation evidence, without promoting generic tab support as a separate advantage over Finder.

## Capture and preparation workflow

Every canonical screenshot is now checked by `python3 app/tools/screenshot_alpha.py`, and the product-page build runs the same gate over the whole directory. Four corners must have transparent exterior pixels and the PNG must contain antialiased edges; opaque RGB captures fail. The checker never modifies images. It complements the preparation tool's protected-pixel check and visual review. See the [2026-09-13 audit](../research/screenshot-audit-2026-09-13.md) for the six initially opaque screenshots and the current recapture stage.

1. Build the current app and finish its smoke suite before driving the UI. Do not run computer-use checks concurrently with smoke tests.
2. Use a disposable demonstration project with clear names, a few folders, text/source files, an image, and a ZIP. Keep personal files and credentials out of the screenshots.
3. Exercise the feature through the packaged app, then capture its actual state with the available computer-use API. If an open native menu cannot be captured, record its accessibility state and real actions separately. A closed-menu image does not establish the menu's contents. Example server addresses do not establish a successful connection.
4. For a settings capture, use a fresh isolated QA app so Terminal and ZIP reflect their new enabled defaults. Keep actual captured control state in the README text and alt attributes. Exercise the terminal and ZIP through their normal entries, then close only the QA app and restore only preferences owned by the capture task.
5. Preserve the raw capture outside the canonical directory. Prepare a new PNG with [prepare-screenshots.swift](../../app/tools/prepare-screenshots.swift), inspect its comparison sheet on light and dark backgrounds, and check its pixel statistics before replacing the canonical asset. Do not overwrite the raw capture.
6. Update all references if an extension changes, verify that images render, and update the dated research record with the actual capture and verification stage.

Run from the repository root on macOS with the Swift command-line tools; all output paths must be new and their parent directory must exist:

```sh
swift app/tools/prepare-screenshots.swift /tmp/window-dark.jpg /tmp/window-dark.png \
  --describe-stats --contact-sheet /tmp/window-dark-contact.png
```

For light captures whose white window edge cannot be separated reliably from the white exterior, first verify that a prepared dark reference has the exact same window frame, crop, dimensions, and scale. Only then reuse its corner alpha:

```sh
swift app/tools/prepare-screenshots.swift /tmp/window-light.jpg /tmp/window-light.png \
  --mask-from /tmp/window-dark.png \
  --describe-stats --contact-sheet /tmp/window-light-contact.png
```

Matching dimensions alone does not establish registration. The script does not align, resize, or fit a rounded rectangle. It rejects unsuitable mattes or edge estimates, existing outputs, and aliased output/contact-sheet destinations. Compatible PNG inputs whose four corners are already transparent are copied byte-for-byte; omit `--mask-from` for these inputs.

The user explicitly authorized this deterministic processing of real screenshots. It removes connected exterior white matte and estimates a narrow antialiased edge; it does not generate UI imagery. If a colored interior badge contaminates diagonal foreground samples, the processor may try the same corner's already measured top/side edge colors, with the original contrast/residual limits and editable band unchanged. Counts are reported as `stableEdgeFallbackPixels`; unexplained or low-contrast edges still fail. Every protected pixel must match the source as decoded by macOS ImageIO, including after PNG encoding. This is not a claim to recover the original uncompressed pixels or exact alpha lost when a JPEG was flattened. See [the transparency record](../research/screenshot-transparency.md) for the algorithm, refusal cases, evidence, and GitHub rendering limits.

## Current captures and historical stages

`folders.png` shows actual manual tree navigation through the source hierarchy to the visible selected Model row, with collapsed siblings retained. `workspace-restored.png` follows a normal quit and relaunch, restoring two tabs, a split layout and the active right pane in icon view, without restoring a terminal session. Both are real 1100 × 740 captures after the tree expansion callback fix, with 813,166 and 813,158 protected pixels respectively unchanged. The whole screenshot inventory passes alpha checks, and the local website passed 1200 / 390 px browser review. The final 95 Swift sources separately passed 3,194 smoke checks three times, with unchanged hashes; app/DMG verification and exact scope are in HANDOFF. The screenshots retain their actual capture stages rather than claiming every unchanged page was recaptured from the last binary.

`terminal.png` now shows a split demonstration workspace and the selected terminal toolbar button, with actual Menlo 14 pt custom colors and consecutive `ls Source`, `export DEMO=ready` and `printenv DEMO` commands. `zip-recovery.png` shows a real invalid owned `Recovery.zip`, inline Retry / Open Enclosing Folder and the retained directory listing. These 1100 × 740 captures keep the tree hidden and are unaffected by its later callback fix; 813,151 and 813,161 protected pixels respectively are unchanged. Both exteriors pass alpha and light/dark corner review.

The new `shortcuts.png` shows the actual Shortcuts page filtered by `Show`, with `View → Show Terminal` selected and its customized F6 binding visible in both the table and recorder. It is a prepared 660 × 777 PNG with 512,458 protected pixels unchanged. Later folder-tree callback fixes do not change the four Settings pages. The default terminal shortcut remains F4; the image demonstrates customization.

The customization stage replaces `settings.png` and `updates.png`, and adds `terminal-settings.png`, using the real 660 × 777 Settings window with General / Shortcuts / Terminal / Updates tabs. General shows terminal and ZIP enabled; Updates shows automatic checks enabled and automatic installation disabled; Terminal shows the intentionally customized `/bin/zsh`, Menlo-Regular 14 pt and custom text/background colors. These three images were captured after the font-field Tab, F6 terminal-toggle and physical-directory-alias fixes; subsequent tree/selection changes do not alter these pages. All three are prepared transparent PNGs with 512,458 protected pixels each unchanged; see the [dated audit](../research/screenshot-audit-2026-09-13.md). The paragraphs below describe earlier capture stages, including the now-superseded opaque General/Updates images.

The default-feature stage replaces `settings.png` and `terminal.png`, and adds `zip-recovery.png` as research evidence. The captures show both options enabled, the terminal retaining its shell directory while the restart destination follows browsing, and a failed ZIP with Retry / Open Enclosing Folder. They followed the initial 2,557-check three-run verification; subsequent ZIP path/title fixes receive separate final verification. The corner-removal pipeline refused all three light captures because no stable outer edge was found. Native ImageIO comparison confirms that format-only JPEG-to-PNG conversion preserves every decoded RGBA pixel; the opaque exterior and system indicator are retained. See [default-feature polish](../research/default-features-polish.md) for the final stage and actual interaction boundaries.

The session-restoration stage replaced `settings.png` and added `workspace-restored.png` after 2,418 smoke checks passed three times. Native quit/relaunch checks preserved a two-window workspace, tab order, active split side, sidebar width and divider position; disabling restoration cleared the file and reopened Home. Both screenshots are actual release-app states, converted from JPEG to PNG without corner or UI edits. The source captures, automation and real-app boundaries are recorded in [workspace sessions](../research/workspace-sessions.md).

The software-update stage replaced `settings.png` with General and added `updates.png`, following 2,158 smoke checks passing three times. Both are actual 540 × 737 window captures. Their incoming bytes were JPEG despite the `.png` filenames; `sips` converted them to real PNG, and native ImageIO decoding confirmed every RGBA pixel remained identical. The standard corner-removal pipeline rejected their colored top-left fringe, so these two images retain the original opaque exterior. No screen-sharing indicator, switch state or other UI pixel was edited. Raw captures and verification are recorded in [the update research](../research/app-updates.md).

`installation.png` now shows the customization-stage DMG opened in Finder with the application, arrow and Applications link. Its 641 × 281 capture was registered through navigation in the same Finder window to an owned empty dark directory and back, with the same frame, crop and scale. The prepared dark reference supplies measured corner alpha through `--mask-from`; 179,760 protected pixels are unchanged. The white installation diagram inside the window is intentionally preserved, while the exterior is transparent. This replaces the earlier opaque image and establishes the local installer layout, not a published release, notarization or an App Store listing. Details and light/dark contact evidence are in the [dated audit](../research/screenshot-audit-2026-09-13.md).

The 2026-09-12 refresh converted or replaced 17 JPEG assets with PNGs and migrated their references. `text-preview.png`, `split-panes-light.png`, and `search-light.png` are additional evidence images. Interface labels remain English; temporary paths are demonstration locations.

This packaged-app capture stage followed 2,024 smoke checks passing three times; it does not establish the final automated result after subsequent Dock changes. Its fresh captures are `path-navigation.png`, `split-panes.png`, `tabs.png`, `name-filter.png`, `search.png`, the three additional evidence images, and `favorites.png`. The set includes actual light and dark appearances. `favorites.png` now shows the Favorites sidebar in a light split workspace with its menu closed; the current menu was checked separately through accessibility and contains no Reveal in Finder action. The focused dark filter capture failed conservative edge checks, so `name-filter.png` uses a fresh unfocused light capture. The rejected Info image was not published.

Other canonical images retain their earlier packaged-app content; converting their corners does not make them current-stage visual evidence:

- `folder-views.png` and `folder-views-unified.png` came from the independently verified directory-view stage. Its restart, policy, menu, and automated-only boundaries remain in [the directory-view record](../research/computer-use-2026-09-12-directory-views.md). The old settings capture from that stage has been replaced as described above.
- `file-operation-tasks.png` and `file-operations.png` show the earlier independently verified task controls and nonmodal conflict. Disposable 128 MiB fixtures used process-local pacing; displayed rates are not benchmarks. See [file-operation tasks](../research/file-operation-tasks.md).
- Earlier Quick Look, archive, sharing, server, terminal, view/group, and icon captures retain the scope of their dated records. Server authentication and real remote I/O are not established by their images.

The previous 1,500-check pane/tab stage and the independent search stage remain historical results in [pane and tab verification](../research/pane-paths-and-tab-actions.md) and [search verification](../research/search-verification.md). Several canonical images have since been replaced; their current contents are not the original images from those stages. [HANDOFF.md](../HANDOFF.md) remains the authority for the latest combined verification status.

Before removal of the dedicated preview row, the README tables were reviewed locally at a 1,000 px viewport: all 15 feature images loaded and transparent corners were checked on light and dark backgrounds. The final 14-image layout receives a separate static count/reference check; that is not a new browser review. The actual private GitHub README page was not visited or published as part of this check.

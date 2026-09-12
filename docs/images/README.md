# README screenshots

`features/` contains 24 PNG screenshots from actual packaged-app or installer states. The root README uses 15 feature images in two HTML tables: 11 regular features and two default-off experiments, with General and Updates sharing the settings row. An additional DMG installation image appears in the download section. The app icon and status badges are separate from that count. Do not use mockups as evidence of implemented features.

The product page reuses `path-navigation.png`, `split-panes.png`, and `zip-browsing.png`. Update these canonical files here; the site build copies them unchanged. `tabs.png` remains implementation evidence, without promoting generic tab support as a separate advantage over Finder.

## Capture and preparation workflow

1. Build the current app and finish its smoke suite before driving the UI. Do not run computer-use checks concurrently with smoke tests.
2. Use a disposable demonstration project with clear names, a few folders, text/source files, an image, and a ZIP. Keep personal files and credentials out of the screenshots.
3. Exercise the feature through the packaged app, then capture its actual state with the available computer-use API. If an open native menu cannot be captured, record its accessibility state and real actions separately. A closed-menu image does not establish the menu's contents. Example server addresses do not establish a successful connection.
4. For a staged settings capture, prefer both experiments disabled. The current `settings.png` deliberately retains the actual captured state: Terminal off, ZIP browsing on. Its README text and alt attribute state that exception; the owner's instruction to preserve actual state takes precedence over resetting the user's settings for a screenshot. Enable the relevant experiment for `terminal.png` and `zip-browsing.png`, then restore only preferences owned by the capture task.
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

The user explicitly authorized this deterministic processing of real screenshots. It removes connected exterior white matte and estimates a narrow antialiased edge; it does not generate UI imagery. Every protected pixel must match the source as decoded by macOS ImageIO, including after PNG encoding. This is not a claim to recover the original uncompressed pixels or exact alpha lost when a JPEG was flattened. See [the transparency record](../research/screenshot-transparency.md) for the algorithm, refusal cases, evidence, and GitHub rendering limits.

## Current captures and historical stages

The software-update stage replaced `settings.png` with General and added `updates.png`, following 2,158 smoke checks passing three times. Both are actual 540 × 737 window captures. Their incoming bytes were JPEG despite the `.png` filenames; `sips` converted them to real PNG, and native ImageIO decoding confirmed every RGBA pixel remained identical. The standard corner-removal pipeline rejected their colored top-left fringe, so these two images retain the original opaque exterior. No screen-sharing indicator, switch state or other UI pixel was edited. Raw captures and verification are recorded in [the update research](../research/app-updates.md).

`installation.png` shows the final DMG opened in Finder with the application, arrow and Applications link. Its JPEG capture was converted to PNG without corner processing or UI edits. It establishes the local installer layout, not a published release, notarization or an App Store listing.

The 2026-09-12 refresh converted or replaced 17 JPEG assets with PNGs and migrated their references. `text-preview.png`, `split-panes-light.png`, and `search-light.png` are additional evidence images. Interface labels remain English; temporary paths are demonstration locations.

This packaged-app capture stage followed 2,024 smoke checks passing three times; it does not establish the final automated result after subsequent Dock changes. Its fresh captures are `path-navigation.png`, `split-panes.png`, `tabs.png`, `name-filter.png`, `search.png`, the three additional evidence images, and `favorites.png`. The set includes actual light and dark appearances. `favorites.png` now shows the Favorites sidebar in a light split workspace with its menu closed; the current menu was checked separately through accessibility and contains no Reveal in Finder action. The focused dark filter capture failed conservative edge checks, so `name-filter.png` uses a fresh unfocused light capture. The rejected Info image was not published.

Other canonical images retain their earlier packaged-app content; converting their corners does not make them current-stage visual evidence:

- `folder-views.png` and `folder-views-unified.png` came from the independently verified directory-view stage. Its restart, policy, menu, and automated-only boundaries remain in [the directory-view record](../research/computer-use-2026-09-12-directory-views.md). The old settings capture from that stage has been replaced as described above.
- `file-operation-tasks.png` and `file-operations.png` show the earlier independently verified task controls and nonmodal conflict. Disposable 128 MiB fixtures used process-local pacing; displayed rates are not benchmarks. See [file-operation tasks](../research/file-operation-tasks.md).
- Earlier Quick Look, archive, sharing, server, terminal, view/group, and icon captures retain the scope of their dated records. Server authentication and real remote I/O are not established by their images.

The previous 1,500-check pane/tab stage and the independent search stage remain historical results in [pane and tab verification](../research/pane-paths-and-tab-actions.md) and [search verification](../research/search-verification.md). Several canonical images have since been replaced; their current contents are not the original images from those stages. [HANDOFF.md](../HANDOFF.md) remains the authority for the latest combined verification status.

Before removal of the dedicated preview row, the README tables were reviewed locally at a 1,000 px viewport: all 15 feature images loaded and transparent corners were checked on light and dark backgrounds. The final 14-image layout receives a separate static count/reference check; that is not a new browser review. The actual private GitHub README page was not visited or published as part of this check.

# README and website screenshot rounded-corner audit (2026-09-13)

The user asked that every screenshot be transparent outside the native window's rounded corners, with no white or other background color left behind, and explicitly authorized deterministic alpha processing of the screenshots. The interior of the real interface must not be modified because of this; screenshots of new features must be retaken from the final packaged app after real use.

## 0.2.1 downloaded release build: four README images retaken over pointers

A read-only inspection of the real images for the remaining 25 older canonical files found seven obvious mouse arrows / glows; four of them are used in the README, the other three only in historical research. From the downloaded and fully verified pristine 0.2.1 release app, the main task created the isolated QA identity `com.tursora.releaseqa021.s0913`, used the app hands-on, and retook `/private/tmp/tursora-0.2.1-qa-u1_phjba/screenshots/{folders,share,terminal-settings,updates}.jpg`. That identity exists only for isolated verification and must not be written down as the release build's identity; the release byte and signature checks are maintained separately in the [0.2.1 record](terminal-navigation-0.2.1.md).

Folders / Share are both 1100 × 740 with the sidebar 300 pt wide: the left pane shows the Seabreeze demo directory and the right pane shows Model from the public Tursora repository, and no other project name appears within the screenshot. Folders has Model selected; Share really opens the system share menu for `FileItem.swift`, without picking any external send target. Terminal Settings / Updates are both 660 × 777: the first shows System Login Shell, System Monospaced 12 pt and Follow Appearance, the second shows automatic checking on and automatic installation off. The initial cached frame for Terminal Settings was not used; the version captured separately and written last is the one kept.

Each raw image was inspected before processing and showed no mouse pointer or hover tooltip; the unmodified `prepare-screenshots.swift` then ran four times, each exiting 0 with an empty stderr. No UI was modified, no threshold lowered and no mouse pixels erased. The raw images, the old canonical files, the processed PNGs, the stats, the light / dark comparison sheets, the hashes and the full alpha results are stored in `/private/tmp/tursora-021-released-screenshots-i9q9qs45/`.

| Canonical | Corner pixels changed | Protected pixels / RGBA bytes unchanged | Fully transparent / semi-transparent | Measured edge-color fallbacks | PNG SHA-256 |
|---|---:|---:|---:|---:|---|
| `folders.png` | 847 | 813,153 / 3,252,612 | 519 / 328 | 0 | `dc0966a610febd20fb85a12d9cb5facb2456237e03b8faa2f8ae5df7c3dfd2cb` |
| `share.png` | 847 | 813,153 / 3,252,612 | 519 / 328 | 0 | `4a185525175a148332c8695a24ccb6c9608ea50307771c81778cdae2862e2e13` |
| `terminal-settings.png` | 362 | 512,458 / 2,049,832 | 176 / 186 | 6 | `6be8e60517b3377e95221ac251d5401768310ff0744908b7f526238058b2b911` |
| `updates.png` | 362 | 512,458 / 2,049,832 | 176 / 186 | 6 | `7ad0cbc1d81fdd7553d0da7c8caed6d737aea11aead9ed6128377e75e2a9cdb6` |

The full light and dark checkerboards and the 4× corner comparisons were all checked by eye, with no white fringe left behind; the protected region is byte-for-byte identical after PNG encoding, and the purple system markers and the native controls are untouched. Only these four files were replaced in the canonical directory, byte-identical to the staged PNGs that were reviewed; the other 25 images in this follow-up keep their hashes, and all 29 pass the alpha gate.

The README's 20 distinct screenshots and the site's four images show no further obvious mouse pointer / hover traces; this is a visual re-review of the real images, not a guarantee from automatic per-pixel cursor detection. **No claim is made that all 29 are pointer-free**: `app-icon-edges.png`, `text-preview.png` and `views-and-groups.png` keep the real pointers from the 2026-09-12 historical research, and neither the current README nor the product page references them. The earlier seven findings and their location images are in `/private/tmp/tursora-cursor-review-r4nysli7/review.json`; the problem in the four public marketing images is resolved by this retake, while the other three are left alone rather than retouching historical evidence. The static list of marketing references and the statistics for the new images are in this round's `verification.json`; the live rendering, deployment and in-app update checks are recorded separately by the main task.

## 0.2.1 final interface: four canonical images formally replaced

The main task captured `/private/tmp/tursora-0.2.1-qa-u1_phjba/screenshots/{terminal,split-panes,path-navigation,zip-browsing}.jpg` from the final 0.2.1 release app, all four at 1100 × 740; before the capture, the same 102 Swift files had completed 3 × 3,435 smoke checks, and the exact verification and interaction scope is in the [0.2.1 record](terminal-navigation-0.2.1.md). Each real raw image was inspected before processing and showed no mouse pointer or hover tooltip; Terminal uses the version the main task wrote last, with the text selection cleared and the real shell cursor kept.

Terminal shows the default dark appearance, System Monospaced 12 pt, the single-row title / Restart / Hide actions, and the real pwd / ls output inside Source. The split-pane image has the Seabreeze list on the left and the Source icon view on the right; the path image shows the Design Archive completion; the ZIP image has the read-only contents of Delivery.zip on the left and the Source icon view on the right. None of the four has Folders expanded; the bottom keeps only the file context and zoom, showing no terminal status, animation, elapsed time or available capacity.

The raw copies, the old canonical files, the processed PNGs, the per-image stats, the light / dark comparison sheets and the complete verification JSON are all stored in `/private/tmp/tursora-021-screenshots-ouuu25vr/`. The unmodified `prepare-screenshots.swift` was used, with the temporary module cache and the output both inside this round's directory; the four runs each exited 0 with an empty stderr. No threshold was lowered, no generic corner radius fitted and no interface interior modified, and every protected pixel was checked again after PNG encoding.

| Canonical | Corner pixels changed | Protected pixels / RGBA bytes unchanged | Fully transparent / semi-transparent | Measured edge-color fallbacks | PNG SHA-256 |
|---|---:|---:|---:|---:|---|
| `terminal.png` | 850 | 813,150 / 3,252,600 | 518 / 332 | 0 | `f6276b992c149cecec723c2c0450df36244b69ba696b21bd7767bd0ea9042e70` |
| `split-panes.png` | 837 | 813,163 / 3,252,652 | 519 / 318 | 0 | `e8c56d538b662ea701f12a9978ba2b6428d6682e681d04a88582838b3c9698d0` |
| `path-navigation.png` | 837 | 813,163 / 3,252,652 | 519 / 318 | 0 | `cbf111015f6ce7899bd92b32b5368bea6a8533343fbccfab609a09ab7652305c` |
| `zip-browsing.png` | 837 | 813,163 / 3,252,652 | 519 / 318 | 0 | `82968cd19725609803ed95fc9207bc4db999de1af7ff15a9225f319adfbbbc86` |

Each raw image, the full light and dark checkerboard composites and the 4× corner views were inspected, with no white fringe left behind; the purple system markers, the text, the controls and the real outline are all preserved. Only these four canonical images were replaced, byte-for-byte identical to the staged PNGs that were inspected; the other 25 keep their hashes, and all 29 in the directory pass `screenshot_alpha.py`. The per-image raw / PNG hashes and the protected-region statistics are in `verification.json`, and the full alpha results are in `canonical-alpha.json`. The site build, the browser check and the actual deployment are recorded separately by the main task; this round's image processing does not stand in for those steps.

The main task additionally verified hands-on that the same shell PID 68154 survives hiding and unhiding, that navigation waits during a 30-second foreground sleep, that following runs from Seabreeze to Source once the prompt is safe again, and that cancelling the quit confirmation for a hidden task keeps the task. A screenshot only records the last visible interface, and the pwd text inside it cannot on its own prove any of the above. The 0.2.0 status bar, the early manual Restart and the older screenshot statistics below all keep their original historical scope; for the current Terminal and the three main workflow images, the four above are authoritative.

## 0.2.0 installation page static check (before the new terminal screenshots were swapped in)

After the 0.2.0 installation entry point was moved to the front, `python3 site/build.py` passes: **5 assets, 39 references, about 1,629 KiB, and all 29 canonical PNGs pass the alpha gate**. The new site asset reuses the already verified `installation.png`; the five distributed assets are byte-for-byte identical to their sources, and no canonical image was added or re-encoded.

An independent static parse confirms: both "安装指南" links, in the navigation and in the hero, are in-page `#installation` links, and the single target exists alongside the legacy `#download` compatibility anchor; both "免费下载" links still point at the real latest release, with no hardcoded link to an unreleased 0.2.0 asset; the Homebrew code block keeps its two real command lines. The README's installation section sits before Features / the first table, and all 20 distinct screenshot references are present. Both the page and the README keep the true stage wording: 0.2.0 in preparation, 0.1.0 released.

The evidence (asset SHAs, the full alpha listing and the links) is `/private/tmp/tursora-installation-site-static-wu6hgft4/checks.json`; `git diff --check` passes. No browser or app was driven this time and no smoke run was made, so this cannot be used to claim that the anchor's actual scrolling, the narrow-screen wrapping / image viewer, or the new terminal status have been tested hands-on. At the time of this static check the new General / Terminal raw screenshots had not yet been supplied; the replacement stage that followed is in the next section.

The main task then completed a separate hands-on browser check: at 1200 × 850, clicking "安装指南" in the navigation changed the URL fragment to `#installation`, put the top of the installation section 100 px from the viewport top, and the page width was 1200; at 390 × 844, clicking "安装指南" in the hero jumped to the same target, with a page width of 390 and no horizontal overflow. A real narrow-screen screenshot confirms that the four-step DMG instructions and the Homebrew commands are readable; the tap URL wraps visually, but `pre.textContent` still preserves the two original commands exactly.

The installation image's lightbox was really opened on both desktop and narrow screens, and the native transparent fringe against the narrow screen's dark overlay was confirmed by eye; Escape returned focus to the original installation image link in both cases (AX label: `查看 DMG 安装窗口完整截图`). Only the desktop navigation link and the narrow-screen hero button were actually clicked; the other same-target conclusions come from the static parse above, and this was not extended into full keyboard, no-JavaScript or in-app interaction testing. The main task has reset the viewport and closed its own tabs, and stopping the server is handled separately by the main task.

## 0.2.0 session retention and status bar screenshots formally replaced

The main task supplied `/private/tmp/tursora-terminal-session-qa/screenshots/settings.jpg` and `terminal.jpg`, a real 660 × 777 General window and a real 1100 × 740 terminal window respectively. Separate raw copies were saved first, then processed deterministically with the unmodified `prepare-screenshots.swift`, without any arbitrary geometric mask or edits to the interface interior. The default module cache for the first Swift compile was not writable; after switching to a cache inside this round's temporary directory, both runs exited 0; neither the toolchain nor the app source was changed.

General really has the terminal and ZIP enabled and states that collapsing or disabling the panel still keeps the session; the original purple system markers are fully preserved. Terminal shows the directory tree, the split panes, the custom colors, `Terminal · 1 task` in the bottom right, and the actually printed Shell PID `55113` / Background PID `55145`. The main task reports that this capture came after hiding, disabling, re-enabling and restoring the session; the order of operations and the liveness checks are described separately in the [session lifecycle record](terminal-session-lifecycle.md), and the text in a screenshot alone cannot assert that task detection or cleanup passed. `quit-hidden.jpg` is separate evidence of the quit interaction and was not added to the canonical set.

| Canonical | Corner pixels changed | Protected pixels / RGBA bytes unchanged | Fully transparent / semi-transparent | Measured edge-color fallbacks | PNG SHA-256 |
|---|---:|---:|---:|---:|---|
| `settings.png` | 362 | 512,458 / 2,049,832 | 176 / 186 | 6 | `7922bbc6461fd836d9823fcc4ae4e7af0eee4d7123e90a9f52fad1338b91352d` |
| `terminal.png` | 849 | 813,151 / 3,252,604 | 519 / 330 | 0 | `49cbc1faa7f19edced3b9cd738dbd6db3db974813eb1c6d3a6f214422df6f402` |

The raw images, the whole light and dark checkerboards and the 4× corner details were each inspected, no white background remained at the edges, and the original interiors and window outlines are preserved. The processor re-decoded its own encoded output to check the protected region, and `protectedBytesEqual` was true in both cases. Two canonical files were replaced, the copies being byte-identical to the staged PNGs; the SHAs of the other 27 images are all unchanged. The README alt text and image listing have been updated to what is actually visible.

All the evidence is stored in `/private/tmp/tursora-lifecycle-screenshots-qapzdqgt/`: `sources.json` holds the raw images' provenance and SHAs, `*.raw.jpg` / `*.png` / `*-stats.json` / `*-contact.png` are the processing chain, `*.previous.png` keeps the previous stage's images, and `before-inventory.json` / `replacement-inventory.json` record the replacement scope. This section reports the screenshot check only; the final app source, the three smoke runs and the release verification are recorded separately by the main task.

After the replacement, a separate full `screenshot_alpha.py --json` check reports **29 passing, 0 errors**; the listing is `alpha-audit.json` in the same directory. `site/build.py` passes again with 5 assets, 39 references and 1,629 KiB, and every site asset's SHA matches the pre-replacement check; the logs are `site-build.out` / `site-build.err`, with an empty stderr. General / Terminal are not copied separately by the site, but they are still covered by its full canonical check gate. `git diff --check` passes; this step did not re-run the browser or the app.

## Initial inventory

`docs/images/features/` initially held 26 real PNGs. Decoding each with native ImageIO to check alpha, 20 already have fully transparent corners with semi-transparent antialiasing, and 6 are fully opaque. The site's three screenshots reuse the transparent canonical PNGs, so at the start of this round there was no separate site copy and no CSS white-background problem.

| Initial state | Files |
|---|---|
| Needs fixing; used in the README installation section | `installation.png`, 640 × 280 |
| Needs retaking with the new Settings; used in the README | `settings.png`, `updates.png`, 540 × 737 |
| Needs retaking; used in the README | `terminal.png`, `workspace-restored.png`, 1100 × 712 |
| Needs retaking; used in a research record | `zip-recovery.png`, 1100 × 712 |
| Already transparent; shared by the site and the README | `path-navigation.png`, `split-panes.png`, `zip-browsing.png` |
| Already transparent; other canonical screenshots | `app-icon-edges.png`, `compress-extract.png`, `connect-server.png`, `favorites.png`, `file-operation-tasks.png`, `file-operations.png`, `folder-views-unified.png`, `folder-views.png`, `name-filter.png`, `quick-look.png`, `search-light.png`, `search.png`, `share.png`, `split-panes-light.png`, `tabs.png`, `text-preview.png`, `views-and-groups.png` |

The original statistics are stored in `/private/tmp/tursora-distribution-qa/initial-alpha.jsonl`. The original script rejected all six opaque images: the installation image and Updates have a colored system indicator edge at the top left whose local color residual exceeds the threshold; the other four lack a dark boundary that would reliably separate them from a white background. This round did not lower the old processor's safety thresholds, and did not fit an arbitrary rounded rectangle over them.

## Preventing white-background screenshots from creeping back in

A new [screenshot_alpha.py](../../app/tools/screenshot_alpha.py) uses only the Python standard library and runs both on macOS and on the Pages Linux runner. It validates the real PNG signature, the chunk CRCs, the 8-bit RGBA non-interlaced format, the decompressed size and the PNG row filters; it reports each image's SHA-256, dimensions, corner alpha, and the counts of fully transparent and semi-transparent pixels. The four corners must be alpha 0, and a semi-transparent edge must be present. It only checks; it never changes a pixel.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 app/tools/screenshot_alpha.py --json
python3 site/build.py
```

With no path argument it checks the whole of `docs/images/features/`, rather than sampling only the few images the README or the site currently use. `site/build.py` runs the same check before copying assets; the Pages workflow's trigger paths cover every canonical image and the check script. So a future change that only updates a research screenshot or a README screenshot still triggers the verification. A PNG passing the check still needs a human to confirm the real native outline and how it looks against light and dark backgrounds; a few transparent corners cannot on their own prove that every edge is correct.

## Verification stages in this round

- For the initial 20 transparent PNGs, the Python statistics match native ImageIO item by item on corner alpha and on the fully transparent and semi-transparent pixel counts; all 6 opaque images are rejected by the new checker.
- 4 screenshot-checker tests pass, covering a real existing image, a known RGBA edge, rejection of RGB / fake PNGs, and CRC / truncation / decoded-size errors.
- (Superseded by the 0.2.1 retake sections above) Retaking the real windows after the new features were merged, making them transparent and running the final full check continue in the integration stage; this initial inventory does not establish that those screenshots, not yet taken at the time, were complete. The final result must add the actual raw / processed provenance, the pixel-protection statistics and the scope of the light / dark visual review.

This is a screenshot and site-build check; it cannot replace the app smoke run, and historical screenshots cannot be claimed as hands-on evidence for the interactions added in this round.

## A conservative fallback for dark edges

The fallback added to `prepare-screenshots.swift` only takes effect when the original diagonal protected sample cannot satisfy the residual: it tries the top-edge or side-edge color already measured at the current corner, and still requires a foreground mean < 205, a contrast sum of squares > 7,500, a residual ≤ 22 and a valid alpha. It does not widen the white connected region or the narrow candidate boundary, and does not modify any interior region; the statistics gain `stableEdgeFallbackPixels`. An edge that color still cannot explain keeps failing, and a light outline still requires native alpha or a verified, registered dark reference.

The regression uses clearly labelled synthetic test images, never product screenshots: a purple interior next to a dark rounded corner made the old version reject with a residual of 63.2 while the new version passes; unexplainable colored edges and light edges are still rejected. Three macOS native tool tests pass, and all Python tool tests now come to 83 passing.

The diagnostic output for the old `updates.png` used only 5 fallback candidates and changed 360 corner pixels; 397,620 protected pixels / 1,590,480 RGBA bytes are identical to the source image. `updates-improved-contact.png` was checked by eye on the light and dark checkerboards and the 4× corner views, with the purple system markers unmodified; these diagnostic files are in `/private/tmp/tursora-distribution-qa/`. The canonical Updates has not been replaced with the old frame, and the new Settings pages are still to be retaken from the final release build. The installation image's top corners pass, but its bottom white content boundary is still rejected, so nothing was written out or replaced.

## First-round provisional verification of the new windows (not the final screenshots)

The main task supplied `/private/tmp/tursora-customization-qa/screenshots/settings.jpg` and `terminal.jpg`, which were first copied as separate raws and then processed into `/private/tmp/tursora-distribution-qa/provisional-customization/`. At this stage Settings is 660 × 777 and the terminal main window is 1100 × 740, both real dark windows. Settings changed 362 corner pixels with 512,458 protected pixels identical and 6 measured edge-color fallback candidates; Terminal changed 850 corner pixels with 813,150 protected pixels identical and no fallback. Both pass the cross-platform alpha gate and the visual review on the light / dark checkerboards and the 4× corners, with the real controls, text and purple system markers preserved.

These two staged images did not replace the canonical ones. Fixes for the font-size Tab commit and for following system directory aliases come later, and the main task will re-verify against the final build and retake the images; these raw / contact / stats files only record that the processor was viable in the first round. The installation image is waiting for a precisely registered dark reference from the same Finder window, rather than inferring the geometry underneath the white content.

## The three Settings pages formally replaced

The main task's real screenshots from 2026-09-13 10:17–10:19 (Asia/Shanghai) come from an app build that already had the font-size Tab commit, the F6 terminal toggle and the system physical paths fixed. The tree async / selection and programmatic shortcut re-selection fixes still under way afterwards do not change how these three pages look; the final combined verification is recorded separately.

The source files `/private/tmp/tursora-customization-qa/screenshots/{settings,terminal-settings,updates}.jpg` were copied to `/private/tmp/tursora-distribution-qa/canonical-settings-20260913/` as separate `*.raw.jpg` files; the same directory keeps the output PNGs, the per-image `*-stats.json`, the light / dark `*-contact.png` and this stage's full `alpha-audit.json`. The canonical `settings.png` / `updates.png` were each updated and `terminal-settings.png` was added, byte-for-byte identical to the staged output after copying.

All three are 660 × 777 and each changed only 362 corner pixels; 512,458 protected pixels / 2,049,832 RGBA bytes match the original decode, with 176 alpha-0 pixels and 186 semi-transparent pixels, and 6 same-corner measured edge-color fallback candidates. The raw screenshots, the light and dark checkerboards and the magnified corners were inspected, and the real system markers, focus, controls and sample previews are all preserved.

- General: the terminal and ZIP are both enabled.
- Terminal: really shows Custom Shell `/bin/zsh`, Menlo-Regular 14 pt, Custom text `#E6E6E6` / background `#14202B`; this is a hands-on demonstration of a configuration the user can choose, not a screenshot of the defaults.
- Updates: automatic checking on, automatic installation off. The main task later set the isolated QA profile's automatic checking back to off; the image faithfully keeps the toggle state at the moment of capture.

At this stage there are 27 canonical images, 23 of which pass the alpha gate; the old `installation.png`, `terminal.png`, `workspace-restored.png` and `zip-recovery.png` are still opaque and await a retake by the main task. The new `folders.png` / `shortcuts.png` are also being captured, for an expected final count of 29. A full site build should therefore still fail at this point, and replacing the three pages does not count as finishing all the screenshots.

## Installation window: formally replaced after registration in the same Finder window

At 2026-09-13 10:25 (Asia/Shanghai) the main task opened its own Finder window on the read-only mount of the `app/dist` DMG built in this round, hid the toolbar, sized the window to 641 × 281 so that both icons and the arrow are fully visible, and captured `installation.jpg`. Then, in the **same Finder browser window**, it showed the toolbar, used Go to Folder to navigate to an empty directory of its own, hid the toolbar again and captured `installation-dark-reference.jpg`; it then showed the toolbar once more, went Back to the installer volume, hid the toolbar and retook the original image, confirming the same 641 × 281 frame. The registration rests on this real same-window round trip and on the unchanged crop, size and scale, not on an inference drawn from two images merely sharing a size. This procedure did not install the app and did not modify the DMG.

The two raws are stored separately in `/private/tmp/tursora-distribution-qa/canonical-installation-20260913/`. The real dark reference was made transparent first, then the raw installation image was processed with `--mask-from installation-reference.png`; the same directory keeps both stats files, the light / dark checkerboard and 4× corner contact sheets, and the full alpha audit. The dark reference used 5 same-corner edge-color fallback candidates; the final installation image changed only 361 corner pixels, with 179,760 protected pixels / 719,040 RGBA bytes exactly matching the original decode, and 174 fully transparent and 187 semi-transparent pixels. The white inside the installation image is the real DMG artwork background and is fully preserved; the purple system markers, the icons, the arrow and the text are unmodified.

The raw image, the reference image and the two light / dark contact sheets were inspected corner by corner; the canonical `installation.png` is byte-identical to the staged output, with SHA-256 `4525fe6cfb3d147a288cbf540254ce454b16fa50834ca84dd9a73d4550b330d4`. There are still 27 canonical images at this stage, 24 of which pass; the remaining old `terminal.png`, `workspace-restored.png` and `zip-recovery.png`, plus the new Folders / Shortcuts images, await a retake. This image evidences the current local installation layout and the transparent fringe; it does not establish that a new release has been published or notarized.

## Full visual re-review of the 20 retained transparent images

All 20 already-transparent PNGs in the initial table went through the processor's `unchanged-transparent-png` path, producing byte-identical staged copies and contact sheets, without re-encoding or modifying the canonical files themselves. The evidence is stored in `/private/tmp/tursora-distribution-qa/retained-transparent-20260913/`, with a PNG, stats and a light / dark contact sheet for each image. Every raw image, the whole light checkerboard and dark checkerboard and the 4× corner details were inspected one by one, covering the README, the site's three shared images, and the images used only in research; no white rectangular background or other opaque backing was found outside the rounded corners, and the real light interiors and system markers are untouched.

This re-review completes this round's visual coverage of the transparent fringe on the older images; it does not count the old UI content as hands-on testing of this round's new shortcuts, terminal settings or directory tree. The final total is still to be recounted once the remaining real new images are added.

## The Shortcuts page formally added

The real `shortcuts.jpg` captured by the main task at 2026-09-13 10:37:25 (Asia/Shanghai) was copied to `/private/tmp/tursora-distribution-qa/canonical-shortcuts-20260913/shortcuts.raw.jpg`. The filter term on screen is `Show`, `View → Show Terminal` is selected and shows the custom F6; the record button reads F6 as well, and Clear / Reset / Reset All along with the note on the native input scope are fully visible. The directory-tree AppKit callback fix that followed does not change the interiors of the four Settings pages.

Processing added the canonical `shortcuts.png` at 660 × 777; it changed only 362 corner pixels, with 512,458 protected pixels / 2,049,832 RGBA bytes identical, 176 fully transparent and 186 semi-transparent pixels, and 6 same-corner edge-color fallback candidates. The raw image, the light / dark contact sheets and the magnified corners were all inspected; the stats, the contact sheets and the alpha audit are kept in the same staging directory. The SHA-256 is `e7e24f47d186e05a943ac121d0021d6371f5a28aa1f5aabc11b6f682c67276f7`. 25 of the current 28 canonical images pass; the three remaining old opaque images and one new Folders image still await a retake, and the final three app verification runs are recorded separately.

## Terminal and ZIP failure screens formally replaced

The main task supplied `terminal.jpg` from 2026-09-13 10:38:53 and `zip-recovery.jpg` from 10:39:23 (Asia/Shanghai), both real 1100 × 740 dark app windows. Both hide the directory tree, and the only later fix — the tree's AppKit expansion callback — does not change these interiors. The terminal is a hands-on demonstration of Menlo 14 pt, the custom text / background colors, the selected toolbar button, and `ls Source`, `export DEMO=ready` and `printenv DEMO` returning `ready`; the ZIP image uses an invalid `Recovery.zip` of our own, really showing Retry / Open Enclosing Folder while keeping the original directory contents.

| Canonical | Corner pixels changed | Protected pixels / RGBA bytes unchanged | Fully transparent / semi-transparent | SHA-256 |
|---|---:|---:|---:|---|
| `terminal.png` | 849 | 813,151 / 3,252,604 | 519 / 330 | `0a15e8ff2063a7d5260e861209d99f3511993a0d25e6025e0a84d90ccbe384a0` |
| `zip-recovery.png` | 839 | 813,161 / 3,252,644 | 519 / 320 | `3c8a22ac9d3dc671ce81f76b533f41606cf7b92b39ba702bae27199e175b750d` |

Neither image needed an edge-color fallback; the raw images, the whole light / dark composites and the magnified corners were inspected, and the canonical files are byte-identical to the staged output. The separate raw / PNG / stats / contact files are stored in `/private/tmp/tursora-distribution-qa/canonical-terminal-20260913/` and `canonical-zip-recovery-20260913/` respectively. The latter's full audit covers 28 images with 27 passing, leaving only the old `workspace-restored.png` opaque; the new `folders.png` likewise awaits a retake from the final build. The site gate should still reject the old workspace image, and this stage must not be misrecorded as a full build passing.

## The last two images and a full pass

`workspace-restored.jpg` (10:43:22) and `folders.jpg` (10:44:23, Asia/Shanghai) from 2026-09-13 come from the real app build after the `shouldExpand` AppKit callback was fixed. The workspace image followed a normal quit and reopen, restoring two panes, two tabs and the active icon view on the right, with no terminal restored. The Folders image was produced by really expanding and navigating by hand along Home → Tursora → app → Sources → Tursora → Model; the selected Model row is fully visible, sibling nodes stay collapsed, and no Loading loop appeared. The final smoke run for the later shortcut-boundary and test-bridge fixes is recorded separately and cannot be replaced by these two images.

| Canonical | Size | Corner pixels changed | Protected pixels / RGBA bytes unchanged | Fully transparent / semi-transparent | SHA-256 |
|---|---|---:|---:|---:|---|
| `folders.png` | 1100 × 740 | 834 | 813,166 / 3,252,664 | 520 / 314 | `0689f743770c231f1cc012cff1066bf991b9125e54d833f3287fc31e408e9079` |
| `workspace-restored.png` | 1100 × 740 | 842 | 813,158 / 3,252,632 | 518 / 324 | `65dd671a03d3bd848d04ad812bab7c7344aebcd8b6eaa0c95c3574416aa6ae44` |

The separate raws, outputs, stats and light / dark contact sheets are stored in `/private/tmp/tursora-distribution-qa/canonical-final-two-20260913/`. Neither image needed an edge-color fallback, the raw images, the whole light / dark composites and the magnified corners were all inspected, and the canonical files are byte-identical to the output. The README alt text now describes the real Model tree and the restored state with two tabs and the icon view on the right.

**This round's screenshots are complete: all 29 canonical images pass the alpha gate, 0 errors.** The initial 20 keep their bytes unchanged; all six formerly opaque images were replaced with real new captures; and three images were added — Shortcuts, Terminal Settings and Folders. All 29 are covered by the visual re-review of the whole light / dark composites and the corners, and every newly processed image had its interior protected pixels verified one by one. The full JSON listing, with each image's dimensions, alpha counts and SHA-256, is stored at `/private/tmp/tursora-distribution-qa/final-alpha-audit.json`.

A full `site/build.py` build passes: 4 canonical assets, 36 references, about 1,560 KiB, checking all 29 images again. The site's three real screenshots are byte-identical to their sources; the build logs are `/private/tmp/tursora-distribution-qa/site-build-final.{out,err}`. The desktop / narrow-screen browser checks were done separately by the main task; publishing the site and the final app smoke run are not part of what this screenshot check concludes.

## Local site browser re-check

The main task checked this round's `site/dist` in a separate in-app browser tab, with `127.0.0.1:8093` serving the build directory only. On both the 1200 × 850 desktop and the 390 × 844 narrow screen, the free-and-open-source hero, MIT, download, first-launch and Homebrew sections are visible; the page width and `scrollWidth` are 1200 / 390 respectively, with no horizontal overflow. Switching to the ZIP tab works; at 390 px the screenshot viewer opens, the transparent screenshot has a clean fringe over the dark overlay, and after Escape closes it focus returns to the original link whose aria-label is `查看ZIP浏览完整截图`.

Every **visible** image loaded; lazy images in workflows that start out hidden are not counted as load failures, and no claim is made here that all hidden images were downloaded on initial load. The real browser PNGs are stored at `/private/tmp/tursora-customization-qa/screenshots/site-desktop.png` and `site-narrow.png`, recording the actual layout of the download section; both were also viewed by the documentation task. The main task restored the viewport and closed its own tabs, and the temporary server session 1525 exited normally via KeyboardInterrupt (exit 0). This check did not publish the site, did not visit or modify the GitHub README online, and does not replace the app's narrow-window layout testing or the final three smoke runs.

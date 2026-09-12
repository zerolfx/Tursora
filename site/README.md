# Tursora product page

A Chinese, dependency-free static product page. Product screenshots come from the packaged app; no UI mockups, remote fonts, analytics, CDN libraries, or build-time network requests are used.

The page presents three workflows: path navigation, split panes with independent paths, and optional ZIP browsing. App tabs remain supported but are not promoted as a standalone advantage over Finder.

## Build and preview

Run from the repository root with Python 3.9 or later:

```sh
python3 site/build.py
python3 -m http.server 8080 --directory site/dist
```

Open `http://localhost:8080`. Stop the preview server with Control-C. The build is self-contained and uses relative paths, so it can be hosted below a URL prefix or opened from `site/dist/index.html` directly.

`build.py` recreates only `site/dist/` and refuses to replace it if it is a symlink. It copies `index.html`, `styles.css`, `main.js`, and one copy of each canonical asset into `dist/assets/`. The existing repository `dist/` ignore rule excludes generated output. Do not commit or deploy that output automatically.

Canonical assets:

- `app/Resources/AppIcon.png`
- `docs/images/features/path-navigation.png`
- `docs/images/features/split-panes.png` (also used in the hero)
- `docs/images/features/zip-browsing.png`

All four canonical assets are required. The screenshots and icon are never modified by the build; the split screenshot is shared between the hero and its workflow panel rather than copied twice. The technical tab screenshot remains in `docs/images/features/` but is not included in the product-page build.

## Screenshot pipeline

Canonical feature screenshots are PNGs prepared from real app captures. The user authorized deterministic removal of the white exterior around native window corners with `app/tools/prepare-screenshots.swift`; no UI imagery is generated. Preparation happens before the site build, and all protected pixels must match the raw capture as decoded by macOS ImageIO. JPEG edge alpha is estimated, not recovered original metadata. Keep the raw captures and comparison sheets outside `docs/images/features/`, review them on light and dark backgrounds, then update the canonical assets and rebuild. See [the capture commands](../docs/images/README.md#capture-and-preparation-workflow) and [the transparency evidence](../docs/research/screenshot-transparency.md).

Use `--mask-from` only for a visually verified capture pair with exactly matching window geometry, crop, dimensions, and scale; the tool cannot establish registration from equal dimensions. Unsuitable captures are refused. Existing outputs and symlink aliases that collide with the input or comparison image are refused as well. Do not weaken these checks to make a promotional image pass.

The screenshot links, images, and image viewer have transparent backgrounds. Their containers constrain overflow and retain display corner rounding; the viewer heading is a separate block. These CSS rules do not alter screenshot pixels or add a dark theme to the product page. Canonical images may come from different verified app stages: the path and split captures are current, while ZIP retains its earlier verified packaged-app content. The [image inventory](../docs/images/README.md#current-captures-and-historical-stages) records those boundaries.

## Validation and browser review

The build checks local HTML and CSS references, fragment targets, duplicate IDs, image alt attributes, and the three workflow panels. External links must be HTTPS links to GitHub; embedded external dependencies are rejected. It does not check live GitHub authentication, build availability, or artifact retention.

Browser checks:

1. Review at desktop and narrow mobile widths. Text and screenshots must not overflow.
2. Use Tab to focus the workflow selector. Left/Right arrows wrap, Home/End select the ends, and Space/Enter select a workflow. Exactly one panel and selected tab should be active.
3. Open each screenshot, close with Escape or the close button, and verify focus returns to its link. Native modified-click gestures still open image links normally.
4. Disable JavaScript: all three workflows remain visible, the selector links jump to their sections, and screenshots open as ordinary image links.
5. Check reduced-motion settings, keyboard focus rings, and direct fragment links such as `#feature-zip`.

Maintain truthful copy: macOS 14+, current downloadable builds for Apple Silicon, ad-hoc signing without notarization, an English application UI, and no tab restoration after quitting. Both experiments default off. ZIP browsing is read-only, opened files are temporary copies retained until app quit, and edits do not write back. The page links to Build runs and source without claiming a published release, App Store listing, or completed Finder parity.

The 2026-09-12 PNG refresh passed the static build: four canonical assets, 33 local references, approximately 1,559 KiB. Local browser review covered desktop image-viewer opening/closing and focus restoration, plus a 390 px viewport with no page overflow. These checks preceded removal of the separate preview mention; earlier keyboard, no-JavaScript, and other checks retain their historical scope. The site was not deployed, and the actual private GitHub README page was not visited. Local README review and GitHub's public image-rendering evidence are recorded in [screenshot transparency](../docs/research/screenshot-transparency.md).

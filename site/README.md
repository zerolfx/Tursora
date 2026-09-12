# Tursora product page

A Chinese, dependency-free static product page. Product screenshots come from the packaged app; no UI mockups, remote fonts, analytics, CDN libraries, or build-time network requests are used.

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
- `docs/images/features/path-navigation.jpg`
- `docs/images/features/tabs.jpg`
- `docs/images/features/split-panes.jpg` (also used in the hero)
- `docs/images/features/zip-browsing.jpg`

All five canonical assets are required. The screenshots and icon are never modified by the build; the split screenshot is shared between the hero and its workflow panel rather than copied twice.

## Validation and browser review

The build checks local HTML and CSS references, fragment targets, duplicate IDs, image alt attributes, and the four workflow panels. External links must be HTTPS links to GitHub; embedded external dependencies are rejected. It does not check live GitHub authentication, build availability, or artifact retention.

Browser checks:

1. Review at desktop and narrow mobile widths. Text and screenshots must not overflow.
2. Use Tab to focus the workflow selector. Left/Right arrows wrap, Home/End select the ends, and Space/Enter select a workflow. Exactly one panel and selected tab should be active.
3. Open each screenshot, close with Escape or the close button, and verify focus returns to its link. Native modified-click gestures still open image links normally.
4. Disable JavaScript: all four workflows remain visible, the selector links jump to their sections, and screenshots open as ordinary image links.
5. Check reduced-motion settings, keyboard focus rings, and direct fragment links such as `#feature-zip`.

Maintain truthful copy: macOS 14+, current downloadable builds for Apple Silicon, ad-hoc signing without notarization, an English application UI, and no tab restoration after quitting. Both experiments default off. ZIP browsing is read-only, opened files are temporary copies retained until app quit, and edits do not write back. The page links to Build runs and source without claiming a published release, App Store listing, or completed Finder parity.

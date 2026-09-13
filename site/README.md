# Tursora product page

A Chinese, dependency-free static product page. Product screenshots come from the packaged app; no UI mockups, remote fonts, analytics, CDN libraries, or build-time network requests are used.

The page presents three workflows: path navigation, split panes with independent paths, and ZIP browsing, enabled by default. App tabs remain supported but are not promoted as a standalone advantage over Finder.

The hero and download area identify Tursora as free and open source under the project's [MIT license](../LICENSE). The download area links to the repository's Homebrew instructions; the custom tap is defined in `Casks/tursora.rb` and requires publication to `main` before the documented public tap command can discover it. See [Homebrew verification](../docs/research/homebrew.md).

The 2026-09-13 customization-stage build passes with four canonical assets, 36 references and approximately 1,560 KiB. All 29 screenshots in the canonical directory pass the build's alpha gate; all have separate light/dark contact review, and the three site screenshots are copied byte-for-byte. Local browser checks passed at 1200 × 850 and 390 × 844 with no horizontal overflow: free/open-source, MIT and download instructions were visible, the ZIP tab and narrow image viewer worked, and Escape restored the originating link's focus. Visible images loaded; initially hidden lazy images were excluded from that initial-load assertion. The owned tab and loopback server were closed. Exact evidence is in the [screenshot audit](../docs/research/screenshot-audit-2026-09-13.md); these checks do not establish deployment, a live GitHub README review or application smoke results.

## Build and preview

Run from the repository root with Python 3.9 or later:

```sh
python3 site/build.py
python3 -m http.server 8080 --directory site/dist
```

Open `http://localhost:8080`. Stop the preview server with Control-C. The build is self-contained and uses relative paths, so it can be hosted below a URL prefix or opened from `site/dist/index.html` directly.

`build.py` recreates only `site/dist/` and refuses to replace it if it is a symlink. It copies `index.html`, `styles.css`, `main.js`, and one copy of each canonical asset into `dist/assets/`. The existing repository `dist/` ignore rule excludes generated output. Do not commit that output; the Pages workflow builds it from the checked-out source.

## GitHub Pages

The product page is configured for `https://zerolfx.github.io/Tursora/`. In the repository's **Settings → Pages**, use **GitHub Actions** as the publishing source. [`.github/workflows/pages.yml`](../.github/workflows/pages.yml) builds and validates `site/dist/` on pull requests that change the site or its canonical assets. Pushes of those changes to `main` also publish it through GitHub's official Pages artifact and deployment actions. **Actions → Pages → Run workflow** can redeploy `main` without a source change. Other branches and pull requests never deploy.

Only the deployment job receives `pages: write` and `id-token: write`. It uses the `github-pages` environment; restrict that environment to `main` in repository settings. The workflow deploys `site/dist/`, never the repository root or documentation tree. All asset links remain relative so `/Tursora/` works without a build-time URL rewrite. Local builds need no credentials or network access.

The download CTA uses the public [latest stable release](https://github.com/zerolfx/Tursora/releases/latest), so subsequent stable releases do not require a site edit. On 2026-09-12 the GitHub API reported public visibility and `v0.1.0` as the latest stable release, with `Tursora-0.1.0-macOS-arm64.zip` and `SHA256SUMS.txt`. Publishing a release does not itself require rebuilding this static page. Deployment evidence and the boundary between configuration and live verification are recorded in [the Pages research record](../docs/research/github-pages.md).

The next application release switches to a direct DMG with a Tursora → Applications drag-install window. The current page explicitly distinguishes that prepared, unpublished format from the released 0.1.0 ZIP. After the first DMG release is published, remove the transitional copy and retain the latest-release CTA and checksum guidance. ZIP browsing remains an independent application feature.

The download section also gives a short first-launch route through System Settings → Privacy & Security → Open Anyway and links to the [README's First launch section](../README.md#first-launch). Keep the trusted-source condition and ad-hoc / not-notarized status visible. The README holds the detailed Apple guidance, checksum prerequisite and optional targeted quarantine command; the site needs no terminal instructions or broader external-link allowlist. These are documented instructions, not evidence of a Gatekeeper first-launch test.

Canonical assets:

- `app/Resources/AppIcon.png`
- `docs/images/features/path-navigation.png`
- `docs/images/features/split-panes.png` (also used in the hero)
- `docs/images/features/zip-browsing.png`

All four canonical assets are required. The screenshots and icon are never modified by the build; the split screenshot is shared between the hero and its workflow panel rather than copied twice. The technical tab screenshot remains in `docs/images/features/` but is not included in the product-page build.

Before copying assets, the build validates **every** PNG in `docs/images/features/` with the standard-library `app/tools/screenshot_alpha.py` checker, including README/research images not exported by this site. Non-PNG bytes, missing RGBA, opaque corners or absent antialiasing fail the build. The Pages trigger covers that whole directory and the checker, so a later screenshot refresh cannot silently restore an opaque matte. This verifies file transparency, not the authenticity of window shape or unchanged UI interiors; those still require the preparation statistics and visual review below.

## Screenshot pipeline

Canonical feature screenshots are PNGs prepared from real app captures. The user authorized deterministic removal of the white exterior around native window corners with `app/tools/prepare-screenshots.swift`; no UI imagery is generated. Preparation happens before the site build, and all protected pixels must match the raw capture as decoded by macOS ImageIO. JPEG edge alpha is estimated, not recovered original metadata. Keep the raw captures and comparison sheets outside `docs/images/features/`, review them on light and dark backgrounds, then update the canonical assets and rebuild. See [the capture commands](../docs/images/README.md#capture-and-preparation-workflow) and [the transparency evidence](../docs/research/screenshot-transparency.md).

Use `--mask-from` only for a visually verified capture pair with exactly matching window geometry, crop, dimensions, and scale; the tool cannot establish registration from equal dimensions. Unsuitable captures are refused. Existing outputs and symlink aliases that collide with the input or comparison image are refused as well. Do not weaken these checks to make a promotional image pass.

The conservative measured-edge fallback documented in the [2026-09-13 audit](../docs/research/screenshot-audit-2026-09-13.md) can handle colored system badges near a neutral dark frame without changing those badges. It does not relax geometric, contrast or residual checks.

The screenshot links, images, and image viewer have transparent backgrounds. Their containers constrain overflow and retain display corner rounding; the viewer heading is a separate block. These CSS rules do not alter screenshot pixels or add a dark theme to the product page. Canonical images may come from different verified app stages: the path and split captures are current, while ZIP retains its earlier verified packaged-app content. The [image inventory](../docs/images/README.md#current-captures-and-historical-stages) records those boundaries.

## Validation and browser review

The build checks local HTML and CSS references, fragment targets, duplicate IDs, image alt attributes, and the three workflow panels. External links must be HTTPS links to GitHub; embedded external dependencies are rejected. It does not check live GitHub authentication, build availability, or artifact retention.

Browser checks:

1. Review at desktop and narrow mobile widths. Text and screenshots must not overflow.
2. Use Tab to focus the workflow selector. Left/Right arrows wrap, Home/End select the ends, and Space/Enter select a workflow. Exactly one panel and selected tab should be active.
3. Open each screenshot, close with Escape or the close button, and verify focus returns to its link. Native modified-click gestures still open image links normally.
4. Disable JavaScript: all three workflows remain visible, the selector links jump to their sections, and screenshots open as ordinary image links.
5. Check reduced-motion settings, keyboard focus rings, and direct fragment links such as `#feature-zip`.

Maintain truthful copy: macOS 14+, current downloadable builds for Apple Silicon, ad-hoc signing without notarization, and an English application UI. Workspace restoration is implemented for the next release and enabled by default; windows, tabs, split positions and layout return, while history, filters, selection, terminal sessions and transfers do not. Implementation, pending checks and eventual release status belong in the [workspace record](../docs/research/workspace-sessions.md); existing screenshots do not prove restart behavior. Terminal access and ZIP browsing default on, while saved opt-outs are preserved. F4 opens and starts the shell; startup itself does not. ZIP browsing is read-only, opened files are temporary copies retained until app quit, and edits do not write back. The primary download links to the latest stable GitHub Release, with DMG drag-install/checksum guidance and a clear 0.1.0 ZIP migration note until the first DMG is released. Public downloads need no GitHub account. Neither the DMG format nor Sparkle's update signature implies Apple notarization; the page does not claim an App Store listing or completed Finder parity.

After the 0.1.0 publication update, the final local page was checked again: the download CTA targets Releases, the separate preview promotion is absent, all three workflow tabs remain present, and the page has no horizontal overflow.

The 2026-09-12 PNG refresh passed the static build: four canonical assets, 33 local references, approximately 1,559 KiB. Local browser review covered desktop image-viewer opening/closing and focus restoration, plus a 390 px viewport with no page overflow. These checks preceded removal of the separate preview mention; earlier keyboard, no-JavaScript, and other checks retain their historical scope. At that stage the site was not deployed, and the then-private GitHub README page was not visited. Local README review and GitHub's public image-rendering evidence are recorded in [screenshot transparency](../docs/research/screenshot-transparency.md).

The 2026-09-13 first-launch copy passed the static build with four assets, 34 references and approximately 1,560 KiB. The changed download section was reviewed in the browser at 1722 px and 390 px, including an original-size crop of the narrow layout. All four steps and the styled First launch link were legible; page width matched the viewport in both cases, and the link targeted the README's `#first-launch` section. This pass did not repeat the unchanged workflow/viewer interactions or the app smoke suite. The viewport override, preview tab and loopback server were cleared afterward.

The 2026-09-13 default-feature copy passed the static build with four assets and 34 references. Browser review covered the changed Terminal / ZIP section at 1200 px and 390 px, with page width equal to the viewport, plus the ZIP workflow’s default-enabled badge, original screenshot and settings link. The temporary viewport, preview tab and loopback server were cleared. Unchanged viewer and keyboard interactions were not repeated.

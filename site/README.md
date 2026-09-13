# Tursora product page

A Chinese, dependency-free static product page. Product screenshots come from the packaged app; no UI mockups, remote fonts, analytics, CDN libraries, or build-time network requests are used.

The page presents three workflows: path navigation, split panes with independent paths, and ZIP browsing, enabled by default. App tabs remain supported but are not promoted as a standalone advantage over Finder.

The hero and download area identify Tursora as free and open source under the project's [MIT license](../LICENSE). Both the prominent navigation link and hero's **安装指南** button jump to `#installation`; they do not initiate a download. Separate **免费下载** links point to the actual latest stable GitHub Release. The installation section gives four DMG steps, the actual installer image, first-launch guidance and copyable Homebrew commands. `#download` remains as a compatibility anchor. The custom tap is defined in `Casks/tursora.rb` and tracks the published 0.2.0 DMG with a pinned SHA-256. The guide requires the full-URL tap command to succeed before the separate install command. A missing `zerolfx/homebrew-tursora` remote indicates Homebrew used its default tap address. Keep the source code block at exactly two command lines; CSS may wrap the URL visually without introducing another command. A concise `untrusted tap` note links to README troubleshooting, whose explicit trust command applies only to the Tursora cask. See [Homebrew verification](../docs/research/homebrew.md).

The current 0.2.0 installation revision adds `installation.png` as the fifth copied asset; the canonical screenshot directory still contains 29 images. The new build passes with five assets, 39 references, approximately 1,629 KiB and all 29 alpha checks; all copied assets match the source bytes. Root browser verification at 1200 × 850 clicked the navigation's **安装指南**, reached `#installation` with the section at 100 px from the top and no page overflow. At 390 × 844, clicking the hero's **安装指南** reached the same target with page width 390 px; the four DMG steps and visually wrapped Homebrew URL remained readable, while the actual code text kept exactly two command lines. Both desktop and narrow installer dialogs opened and returned focus to the originating image link on Escape; the narrow dialog also received visual inspection of its transparent exterior against the dark overlay. Only desktop navigation and narrow hero links were actually clicked; the shared target of both links is additionally covered by static parsing. The viewport was reset and the owned tab closed. These checks preceded publication and used truthful prepared/unpublished wording. After 0.2.0 was released, the cask follow-up changed the installation text to the published DMG; its build and deployment checks are recorded separately below.

The post-publication 0.2.0 copy passed a new static build: five assets, 39 references, approximately 1,629 KiB and all 29 screenshot alpha checks. Both installation anchors still target `#installation`, both download CTAs remain `releases/latest`, and the Homebrew code preserves its exact two command lines. All five assets are byte-identical to the browser-reviewed version; README still places installation before its feature tables and references 20 existing distinct screenshots. Evidence is `/private/tmp/tursora-homebrew-0.2.0-i_9y61y8/site-static.json` and `site-build.{out,err}`. This pass did not drive a browser or the app; the follow-up's deployment and live HTTP checks remain separate from the successful pre-release [main Pages run](https://github.com/zerolfx/Tursora/actions/runs/34739716315). Consult [Pages runs](https://github.com/zerolfx/Tursora/actions/workflows/pages.yml) and the corresponding PR's exact-commit evidence for its publication result.

The 2026-09-13 customization-stage build passes with four canonical assets, 36 references and approximately 1,560 KiB. All 29 screenshots in the canonical directory pass the build's alpha gate; all have separate light/dark contact review, and the three site screenshots are copied byte-for-byte. Local browser checks passed at 1200 × 850 and 390 × 844 with no horizontal overflow: free/open-source, MIT and download instructions were visible, the ZIP tab and narrow image viewer worked, and Escape restored the originating link's focus. Visible images loaded; initially hidden lazy images were excluded from that initial-load assertion. The owned tab and loopback server were closed. Exact evidence is in the [screenshot audit](../docs/research/screenshot-audit-2026-09-13.md); these checks do not establish deployment, a live GitHub README review or application smoke results.

The subsequent installation-troubleshooting revision keeps those two default commands, explicitly requires the full-URL tap step to succeed first, and links an `untrusted tap` message to README's single-cask trust instructions. Current product copy no longer offers a 0.1.0 migration path; dated release and screenshot evidence remains historical. The static build passes with five assets, 40 references, approximately 1,629 KiB and all 29 alpha checks. The two source command lines and both installation anchors are unchanged, the troubleshooting target exists, and 77 local Markdown targets pass. Evidence is `/private/tmp/tursora-tap-instructions-o5lykmq1/static-verification.json` and `site-build.{out,err}`. This check did not operate Homebrew or the browser; isolated tap/trust reproduction is recorded by the main task.

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

The published 0.2.0 release provides a direct DMG with a Tursora → Applications drag-install window. The page retains the latest-release CTA and checksum guidance. ZIP browsing remains an independent application feature. Release bytes, signature checks and production-feed verification boundaries are in [the release record](../docs/research/release-0.2.0.md).

The installation section also gives a short first-launch route through System Settings → Privacy & Security → Open Anyway and links to the [README's First launch section](../README.md#first-launch). Keep the trusted-source condition and ad-hoc / not-notarized status visible. The README holds the detailed Apple guidance, checksum prerequisite and optional targeted quarantine command; the site's terminal commands are limited to normal Homebrew installation and need no broader external-link allowlist. These are documented instructions, not evidence of a Gatekeeper first-launch test.

Canonical assets:

- `app/Resources/AppIcon.png`
- `docs/images/features/path-navigation.png`
- `docs/images/features/split-panes.png` (also used in the hero)
- `docs/images/features/zip-browsing.png`
- `docs/images/features/installation.png`

All five canonical assets are required. The screenshots and icon are never modified by the build; the split screenshot is shared between the hero and its workflow panel rather than copied twice. The technical tab screenshot remains in `docs/images/features/` but is not included in the product-page build.

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
6. Activate both **安装指南** links and open `#installation` directly. Verify the page jumps to the guide without opening a download, the four DMG steps and Homebrew commands remain legible at 390 px, and copied commands preserve their actual two lines. Check the additional installer image viewer and Escape focus return.

Maintain truthful copy: macOS 14+, current downloadable builds for Apple Silicon, ad-hoc signing without notarization, and an English application UI. Workspace restoration is available in 0.2.0 and enabled by default; windows, tabs, split positions and layout return, while history, filters, selection, terminal sessions and transfers do not. Implementation, verification and release status belong in the [workspace record](../docs/research/workspace-sessions.md); existing screenshots do not prove restart behavior. Terminal access and ZIP browsing default on, while saved opt-outs are preserved. F4 opens and starts the shell; startup itself does not. ZIP browsing is read-only, opened files are temporary copies retained until app quit, and edits do not write back. The primary download links to the latest stable GitHub Release, with current DMG drag-install/checksum guidance. Public downloads need no GitHub account. Neither the DMG format nor Sparkle's update signature implies Apple notarization; the page does not claim an App Store listing or completed Finder parity.

After the 0.1.0 publication update, the final local page was checked again: the download CTA targets Releases, the separate preview promotion is absent, all three workflow tabs remain present, and the page has no horizontal overflow.

The 2026-09-12 PNG refresh passed the static build: four canonical assets, 33 local references, approximately 1,559 KiB. Local browser review covered desktop image-viewer opening/closing and focus restoration, plus a 390 px viewport with no page overflow. These checks preceded removal of the separate preview mention; earlier keyboard, no-JavaScript, and other checks retain their historical scope. At that stage the site was not deployed, and the then-private GitHub README page was not visited. Local README review and GitHub's public image-rendering evidence are recorded in [screenshot transparency](../docs/research/screenshot-transparency.md).

The 2026-09-13 first-launch copy passed the static build with four assets, 34 references and approximately 1,560 KiB. The changed download section was reviewed in the browser at 1722 px and 390 px, including an original-size crop of the narrow layout. All four steps and the styled First launch link were legible; page width matched the viewport in both cases, and the link targeted the README's `#first-launch` section. This pass did not repeat the unchanged workflow/viewer interactions or the app smoke suite. The viewport override, preview tab and loopback server were cleared afterward.

The 2026-09-13 default-feature copy passed the static build with four assets and 34 references. Browser review covered the changed Terminal / ZIP section at 1200 px and 390 px, with page width equal to the viewport, plus the ZIP workflow’s default-enabled badge, original screenshot and settings link. The temporary viewport, preview tab and loopback server were cleared. Unchanged viewer and keyboard interactions were not repeated.

# Tursora product page

A bilingual, dependency-free static product site. `index.html` is English and is the default at `/Tursora/`; `zh.html` is Chinese. Visible **English / 中文** links use ordinary navigation and work without JavaScript or language detection. Both pages share the same styles, interaction script and canonical images. Product screenshots come from the packaged app; no UI mockups, remote fonts, analytics, CDN libraries, or build-time network requests are used.
Current state: [0.2.1 is published](https://github.com/zerolfx/Tursora/releases/tag/v0.2.1); both pages and the shared installation guide name its DMG, and the cask tracks it with a pinned SHA-256. The final 0.2.1 build passed with two languages, five canonical assets, 90 references and all 29 screenshot alpha checks; browser review at 1200 × 850 and 390 × 844 in both languages covered language links, installation anchors, ZIP tabs, localized image viewers and Escape focus restoration without horizontal overflow, and commit `c95f4d5` passed [Pages deployment](https://github.com/zerolfx/Tursora/actions/runs/34748295179). Dated evidence for that and for earlier revisions lives in [the 0.2.1 record](../docs/research/terminal-navigation-0.2.1.md), [the Pages record](../docs/research/github-pages.md), [the Homebrew record](../docs/research/homebrew.md) and [the screenshot audit](../docs/research/screenshot-audit-2026-09-13.md); this file only describes how the site is built and reviewed.

The page presents three workflows: path navigation, split panes with independent paths, and ZIP browsing, enabled by default. App tabs remain supported but are not promoted as a standalone advantage over Finder.

The product copy follows the repository About description: a free, open-source native macOS file manager and an alternative to Finder. Titles, section headings, metadata, image descriptions, viewer labels and accessibility names are translated. The English hero says **Free, open-source macOS file manager**, and Chinese says **免费开源的 macOS 文件管理器**. The Finder gap note remains visible. Both pages retain the same section IDs, full installation steps, three Homebrew commands and agent prompt. `install.md` remains the shared English agent guide. The README's Chinese installation link targets `/Tursora/zh.html#installation`. Keep both pages in sync when a feature or release changes. Current download and feature descriptions target published 0.2.1. Directory synchronization waits for foreground execution or unfinished input, not background or stopped jobs at a safe shell prompt. Changing the shell directory does not change a child process's working directory.

The hero and download area identify Tursora as free and open source under the project's [MIT license](../LICENSE). Both the prominent navigation link and hero's **Install guide / 安装指南** button jump to `#installation`; they do not initiate a download. Separate **Free download / 免费下载** links point to the actual latest stable GitHub Release. The installation section gives four DMG steps, the actual installer image, first-launch guidance and copyable Homebrew commands. `#download` remains as a compatibility anchor. The custom tap is defined in `Casks/tursora.rb` and tracks the published 0.2.1 DMG with a pinned SHA-256. The guide requires three commands in order: the full-URL tap, explicit trust for the Tursora cask only, then the fully qualified install. The maintainer requested the trust step in the main flow; it is not merely an error fallback. A missing `zerolfx/homebrew-tursora` remote indicates Homebrew used its default tap address. Keep the source code block at exactly three command lines; CSS may wrap the URL visually without introducing another command. Homebrew can also auto-trust fully qualified installs, so the explicit step does not imply that every two-command installation fails. See [Homebrew verification](../docs/research/homebrew.md).

The documented commands are:

```sh
brew tap zerolfx/tursora https://github.com/zerolfx/Tursora
brew trust --cask zerolfx/tursora/tursora
brew install --cask zerolfx/tursora/tursora
```

## Build and preview

Run from the repository root with Python 3.9 or later:

```sh
python3 site/build.py
python3 -m http.server 8080 --directory site/dist
```

Open `http://localhost:8080` for English or `http://localhost:8080/zh.html` for Chinese. Stop the preview server with Control-C. The build is self-contained and uses relative paths, so it can be hosted below a URL prefix or opened from `site/dist/index.html` directly.

`build.py` recreates only `site/dist/` and refuses to replace it if it is a symlink. It copies `index.html`, `zh.html`, `styles.css`, `main.js`, and the plain Markdown `install.md` into `dist/`, plus one copy of each canonical asset into `dist/assets/`. The existing repository `dist/` ignore rule excludes generated output. Do not commit that output; the Pages workflow builds it from the checked-out source.

## GitHub Pages

The product page is configured for `https://zerolfx.github.io/Tursora/`. In the repository's **Settings → Pages**, use **GitHub Actions** as the publishing source. [`.github/workflows/pages.yml`](../.github/workflows/pages.yml) builds and validates `site/dist/` on pull requests that change the site or its canonical assets. Pushes of those changes to `main` also publish it through GitHub's official Pages artifact and deployment actions. **Actions → Pages → Run workflow** can redeploy `main` without a source change. Other branches and pull requests never deploy.

Only the deployment job receives `pages: write` and `id-token: write`. It uses the `github-pages` environment; restrict that environment to `main` in repository settings. The workflow deploys `site/dist/`, never the repository root or documentation tree. All asset links remain relative so `/Tursora/` works without a build-time URL rewrite. Local builds need no credentials or network access.

The download CTA uses the public [latest stable release](https://github.com/zerolfx/Tursora/releases/latest), so subsequent stable releases do not require a site edit. Publishing a release does not itself require rebuilding this static page. Deployment evidence and the boundary between configuration and live verification are recorded in [the Pages research record](../docs/research/github-pages.md).

The published 0.2.1 release provides a direct DMG with a Tursora → Applications drag-install window. The page retains the latest-release CTA and checksum guidance. ZIP browsing remains an independent application feature. The earlier 0.2.0 byte, signature and production-feed checks remain in their historical [release record](../docs/research/release-0.2.0.md); they do not substitute for verification of a later release.

The installation section supports `/Applications`, `~/Applications`, or another writable folder. It displays `xattr -dr com.apple.quarantine` with a quoted sample app path and explains how to drag the actual installed app into Terminal to supply its path. The command applies to a trusted, checksum-verified copy outside the DMG; ownership/write permissions and organization restrictions are separate. The [README's First launch section](../README.md#first-launch) retains graphical approval as an option. Homebrew's `--appdir` changes only the app destination, not permissions on Homebrew itself.

The README and page include ready-to-paste prompts pointing to `https://zerolfx.github.io/Tursora/install.md`. The build copies `site/install.md` verbatim; the local link is validated and works under the `/Tursora/` subpath. This is an actionable Markdown guide for an agent with access to the user's Mac. It covers environment/destination selection, existing apps, Homebrew or verified DMG installation and the selected copy's first launch. These are documented instructions, not proof of Gatekeeper approval on a separate standard-account or managed Mac.

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

The screenshot links, images, and image viewer have transparent backgrounds. Their containers constrain overflow and retain display corner rounding; the viewer heading is a separate block. These CSS rules do not alter screenshot pixels or add a dark theme to the product page. The path, split and ZIP screenshots were refreshed from the verified 0.2.1 app; other canonical images can retain their own verified historical stage. The [image inventory](../docs/images/README.md#current-captures-and-historical-stages) records those boundaries.

## Validation and browser review

The build checks both pages' HTML/CSS references, local and cross-page fragment targets, duplicate IDs, image alt attributes, localized viewer titles and three workflow panels per language. It requires English at `index.html`, Chinese at `zh.html`, alternate-language metadata and two ordinary language links with matching labels and `aria-current`. Both pages must preserve identical section IDs. English content is checked for untranslated Chinese, with the explicitly marked Chinese language link allowed. External links must be HTTPS links to GitHub; embedded external dependencies are rejected. The shared script takes its viewer fallback from each page's `data-viewer-title`, with no hardcoded Chinese label. These checks do not establish live deployment or layout quality.

Browser checks:

1. Review both languages at desktop and narrow mobile widths. English must be the default at the root. Follow the visible **English / 中文** links in both directions and confirm the selected language indicator, page title, headings and accessibility labels. Text and screenshots must not overflow.
2. Use Tab to focus the workflow selector. Left/Right arrows wrap, Home/End select the ends, and Space/Enter select a workflow. Exactly one panel and selected tab should be active.
3. Open each screenshot, close with Escape or the close button, and verify focus returns to its link. Native modified-click gestures still open image links normally.
4. Disable JavaScript: language links still navigate to the complete static pages, all three workflows remain visible, the selector links jump to their sections, and screenshots open as ordinary image links.
5. Check reduced-motion settings, keyboard focus rings, and direct fragment links such as `#feature-zip`.
6. Activate the navigation and hero **Install guide / 安装指南** links in each language and open `#installation` directly. Verify the page jumps to the guide without opening a download, the four DMG steps and Homebrew commands remain legible at 390 px, and copied commands preserve their actual three lines, in tap / single-cask trust / install order. Check the installer image viewer's translated heading/close label and Escape focus return. Verify that first-launch instructions and agent prompts remain legible and that the common `install.md` serves the complete English guide.

Maintain truthful copy: macOS 14+, current downloadable builds for Apple Silicon, ad-hoc signing without notarization, and an English application UI. Workspace restoration is enabled by default; windows, tabs, split positions and layout return, while history, filters, selection, terminal sessions and transfers do not. Implementation, verification and release status belong in the [workspace record](../docs/research/workspace-sessions.md); existing screenshots do not prove restart behavior. Terminal access and ZIP browsing default on, while saved opt-outs are preserved. F4 opens and starts the shell; startup itself does not. ZIP browsing is read-only, opened files are temporary copies retained until app quit, and edits do not write back. The primary download links to the latest stable GitHub Release, with current DMG drag-install/checksum guidance. Public downloads need no GitHub account. Neither the DMG format nor Sparkle's update signature implies Apple notarization; the page does not claim an App Store listing or completed Finder parity.

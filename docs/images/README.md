# README screenshots

`features/` contains actual packaged-app screenshots, one for each feature group in the root README. Keep each image focused on the control or result described immediately above it. Do not use mockups as evidence of implemented features.

The product page reuses this collection. Its additional `tabs.jpg` shows three tabs, including a custom split-tab title. Update the canonical images here; the site build copies the required files into its output.

## Refresh workflow

1. Build the current app and finish the smoke suite before driving the UI. Do not run computer-use checks concurrently with smoke tests.
2. Use a disposable demonstration project with clear names, a few folders, text/source files, an image, and a ZIP. Keep personal files and credentials out of the screenshots.
3. Exercise each feature through the app, then capture its actual state. Menus and dialogs should show the relevant action; examples of server addresses are demonstrations, not successful connection evidence.
4. Keep `settings.jpg` showing both experiments disabled. Enable the relevant experiment for `terminal.jpg` and `zip-browsing.jpg`, then restore the user's original preferences.
5. Preserve screenshot filenames when replacing them so README links remain stable. Verify every image exists and renders, and update the dated computer-use record with what was actually checked.

The current set is captured in macOS dark appearance. Interface labels are English. Temporary test paths may appear in the address bar; they are demonstration locations.

`folder-views.jpg`, `folder-views-unified.jpg`, and `settings.jpg` were captured from the final directory-view-properties release bundle on 2026-09-12. The [verification record](../research/computer-use-2026-09-12-directory-views.md) distinguishes directory restoration after restart, unified-policy layout, menu actions, and automated-only boundaries.

Current computer-use app captures are JPEG files; some historical menu-window captures are PNG files. Keep the extension consistent with the actual image format. Use the available computer-use screenshot API. If an open native menu cannot be captured, record the accessibility state and actual action separately; do not imply a closed-menu image shows the menu.

The file-operation task change adds `file-operation-tasks.jpg` and refreshes `file-operations.jpg` from the final signed app: independent paused/running copies and the nonmodal move conflict. The disposable 128 MiB fixtures use process-local pacing to make controls observable; the displayed rates are not benchmarks. Exact automated and computer-use evidence is in [file-operation-tasks.md](../research/file-operation-tasks.md).

`features/search.jpg` shows independent recursive queries in list and icon panes with original locations. Its conditions, restart checks and native Spotlight limits are recorded in [search verification](../research/search-verification.md).

These feature captures come from their independently verified release bundles. They do not establish visual verification of the combined three-feature build; the current merge stage and later captures are tracked in [the integration record](../research/pr-integration-2026-09-12.md).

The pane-path and tab-action change refreshes `split-panes.jpg`, `path-navigation.jpg`, and `tabs.jpg` from the final release bundle after 1,500 checks passed three times. The first two show separate pane paths and owner-local completion; `tabs.jpg` shows the tab bar with its context menu closed. Native menu actions were verified through accessibility and real clicks because open-menu screenshots were unavailable. `app-icon-edges.jpg` shows the packaged app icon loaded in the actual icon view. See [pane and tab verification](../research/pane-paths-and-tab-actions.md) and [icon verification](../research/app-icon-edges.md).

# README screenshots

`features/` contains actual packaged-app screenshots, one for each feature group in the root README. Keep each image focused on the control or result described immediately above it. Do not use mockups as evidence of implemented features.

The product page reuses this collection. Its additional `tabs.jpg` shows three independent tabs and an expanded directory tree. Update the canonical images here; the site build copies the required files into its output.

## Refresh workflow

1. Build the current app and finish the smoke suite before driving the UI. Do not run computer-use checks concurrently with smoke tests.
2. Use a disposable demonstration project with clear names, a few folders, text/source files, an image, and a ZIP. Keep personal files and credentials out of the screenshots.
3. Exercise each feature through the app, then capture its actual state. Menus and dialogs should show the relevant action; examples of server addresses are demonstrations, not successful connection evidence.
4. Keep `settings.jpg` showing both experiments disabled. Enable the relevant experiment for `terminal.jpg` and `zip-browsing.jpg`, then restore the user's original preferences.
5. Preserve screenshot filenames when replacing them so README links remain stable. Verify every image exists and renders, and update the dated computer-use record with what was actually checked.

The current set is captured in macOS dark appearance. Interface labels are English. Temporary test paths may appear in the address bar; they are demonstration locations.

`folder-views.jpg`, `folder-views-unified.jpg`, and `settings.jpg` were captured from the final directory-view-properties release bundle on 2026-09-12. The [verification record](../research/computer-use-2026-09-12-directory-views.md) distinguishes directory restoration after restart, unified-policy layout, menu actions, and automated-only boundaries.

Computer-use captures are JPEG files; native menu-window captures are PNG files. Keep the extension consistent with the actual image format. Capture expanded menus by window ID (`screencapture -x -o -l<window-id>`) when authorized; full-screen regions can include other apps behind a background-controlled window.

# README screenshots

`features/` contains actual packaged-app screenshots, one for each feature group in the root README. Keep each image focused on the control or result described immediately above it. Do not use mockups as evidence of implemented features.

## Refresh workflow

1. Build the current app and finish the smoke suite before driving the UI. Do not run computer-use checks concurrently with smoke tests.
2. Use a disposable demonstration project with clear names, a few folders, text/source files, an image, and a ZIP. Keep personal files and credentials out of the screenshots.
3. Exercise each feature through the app, then capture its actual state. Menus and dialogs should show the relevant action; examples of server addresses are demonstrations, not successful connection evidence.
4. Keep `settings.jpg` showing both experiments disabled. Enable the relevant experiment for `terminal.jpg` and `zip-browsing.jpg`, then restore the user's original preferences.
5. Preserve screenshot filenames when replacing them so README links remain stable. Verify every image exists and renders, and update the dated computer-use record with what was actually checked.

The current set is captured in macOS dark appearance. Interface labels are English. Temporary test paths may appear in the address bar; they are demonstration locations.

Computer-use captures are JPEG files; native menu-window captures are PNG files. Keep the extension consistent with the actual image format. Capture expanded menus by window ID (`screencapture -x -o -l<window-id>`) when authorized; full-screen regions can include other apps behind a background-controlled window.

The file-operation task change adds `file-operation-tasks.jpg` and refreshes `file-operations.jpg` from the final signed app: independent paused/running copies and the nonmodal move conflict. The disposable 128 MiB fixtures use process-local pacing to make controls observable; the displayed rates are not benchmarks. Exact automated and computer-use evidence is in [file-operation-tasks.md](../research/file-operation-tasks.md).

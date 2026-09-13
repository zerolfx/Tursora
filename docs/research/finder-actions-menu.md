# Finder actions and share menu comparison (2026-09-12)

Finder resources on the current system:

```bash
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
```

Strings verified directly in the output: New Folder, Open, Get Info, Rename, Duplicate, Copy, Paste, Move to Trash, Share. The icon resource next to Share is named `square.and.arrow.up` and its action is `cmdShare:`. For the icons of the other existing actions, see [the original menu icon record](finder-menu-icons.md).

Tursora's More menu in the toolbar gathers the file operations that are implemented and validates them against the active pane's selection; this is an arrangement that suits the current feature scope, and it does not claim to reproduce every item or the ordering of Finder's More menu. The three-dot button uses `ellipsis.circle` (an icon choice, not confirmed from the Finder nib). Share uses `NSSharingServicePickerToolbarItem` and supplies the selected URLs from the active pane; it is disabled when there is no selection. The tests only verify the objects passed in and the enabled state, and send no files.

Product boundaries the user stated explicitly: no Tags functionality of any kind, and no Import from iPhone. The old Tags group and the reading of file tags have been removed; existing user tags on disk are not modified. The third-party services listed by the system share picker are determined by the system and the installed applications.

# Filtering and search in Dolphin (2026-09-12)

> This is a historical record from before search was implemented separately; for the implementation that followed on 2026-09-12 and its current limits, see the [search research](search.md).

Checked directly against `upstream/dolphin`, commit `5e457ee9e88aa6277fbf056cd5c32462c5318866`, which matches the project's Phase 0 pin.

- `src/filterbar/filterbar.cpp:26–96`: the filter bar holds a lock that keeps the filter across directories, a text field, a case button, the Plain Text / Glob Pattern / Regular Expression modes and a close button. `clearIfUnlocked()` clears an unlocked filter on navigation.
- `src/search/bar.cpp:63–117`: search is a separate interface, with saved searches, a Filter criteria menu and Here / Everywhere scope buttons. The tooltip of `setSearchPath` states explicitly that Here includes subdirectories.
- `src/search/popup.cpp:73–112,208–239,307–314`: choosing file name / content and the search backend, plus file type, modification time, rating and tags; which criteria are available depends on the backend.

Tursora currently implements only name substrings within the current directory plus the `*` / `?` wildcards, ignoring case, saved per pane and cleared on navigation. The old `Filter: [current directory]` row was merely a placeholder that could not be clicked, could neither switch scope nor add criteria, and has now been removed. The toolbar says `Filter by Name` explicitly, and the status bar at the bottom shows the number of matches; genuine recursive search, criteria selection and advanced filtering are still listed as gaps.

Official source: [FilterBar](https://github.com/KDE/dolphin/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/filterbar/filterbar.cpp), [Search::Bar](https://github.com/KDE/dolphin/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/bar.cpp), [Search::Popup](https://github.com/KDE/dolphin/blob/5e457ee9e88aa6277fbf056cd5c32462c5318866/src/search/popup.cpp).

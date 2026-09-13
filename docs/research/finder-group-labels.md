# Finder group labels — from Finder's own string tables

Finder has no source, but its localization string tables are on this machine:
`/System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings`
(and the `.loctable` files in the same directory). The keys used for grouping all carry a `GROUP_` / `GV` prefix. Extracts (macOS 26.5):

## Dates (shared by the four date keys)

| Key | Value |
|---|---|
| `GROUP_TODAY` | Today |
| `GROUP_YESTERDAY` | Yesterday |
| `GROUP_PREVIOUS7DAYS` | Previous ^0 Days |
| `GROUP_PREVIOUS30DAYS` | Previous ^0 Days |
| `GROUP_EARLIER` | Earlier (its use is still to be confirmed; we use month names/years for older dates) |
| `GROUP_FUTURE` | **No Date** (future timestamps fall into this group, not into Today) |

## Kind

`GROUP_APPLICATIONS` Applications · `GROUP_DOCUMENTS` Documents · `GROUP_DIRECTORIES` Folders · `GROUP_IMAGES` Images · `GROUP_MOVIES` Movies · `GROUP_MUSIC` Music · `GROUP_PDF` PDF Documents · `GROUP_PRESENTATIONS` Presentations · `GROUP_SPREADSHEETS` Spreadsheets · `GROUP_TEXT` Text · `GROUP_SOURCE` Source code · `GROUP_HTML` HTML · `GROUP_APPLESCRIPT` AppleScript · `GROUP_FONTS` Fonts · `GROUP_CONTACT` Contacts · `GROUP_EMAIL` Mail Messages · `GROUP_BOOKMARKS` Webpages · `GROUP_FAXES` Faxes · `GROUP_EVENT_TODO` Events & To Do Items · `GROUP_RSS_ARTICLES` News Articles · `GROUP_SYSTEM_PREFS` System Settings · `GROUP_OTHER_DOCUMENTS` Other Documents · `GROUP_OTHER` Other

Key points: **there is no Archives / Disk Images group** (archives go to Other); plain text is **Text**; code is **Source code**. This set of categories matches Spotlight's classic kind grouping. The order of the groups cannot be read out of the string table; we sort by name and do not put Folders first.

## Sizes

| Key | Value |
|---|---|
| `GV10` | Under ^0 |
| `GV11` | From ^0 to ^1 |
| `SP24`/`SP25`/`SP26`/`SP28` | GB / MB / KB / bytes |

The bucket boundaries cannot be read out of the string table; from the format they are inferred to be decimal orders of magnitude: Under 1 KB, From 1 KB to 10 KB, From 10 KB to 100 KB, From 100 KB to 1 MB, … (base 1000, matching the sizes Finder displays).

## Tags / other

`GV12` No Tags · `GV7` Other · `GV6` Show Less · `GV_ALL_V1` Show All (^0)

## Not found in the string table (still inferred)

- The label for "no default application" in the Application grouping (we use "No Application").
- The ordering of the kind groups.
- Date Last Opened uses the file access time as an approximation of Spotlight's last-used.

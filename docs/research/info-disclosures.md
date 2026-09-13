# Get Info section disclosure state (2026-09-12)

The user asked for Get Info's initial disclosure state to match Finder on this machine, so that nothing opens fully expanded the first time. What is recorded here is the Finder state observed on this machine, not Apple's factory default; Finder remembers section choices, and this machine already carries a history of preferences.

## Finder evidence

Running `strings` over `/System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/InfoWindow*.nib` confirms the English labels of the seven sections and their `value: expanded` / `expanded` controller bindings. Those nib strings establish the labels and the bindings; on their own they do not prove what the initial disclosure value is when no preference exists.

`strings` on the Finder executable maps the following nibs to preference identifiers:

| Nib | Section label | Finder identifier | State in the `Feedback.md` Info accessibility tree | Tursora key |
|---|---|---|---|---|
| `InfoWindowGeneralView.nib` | `General:` | `General` | 1, expanded | `general` |
| `InfoWindowMoreInfoView.nib` | `More Info:` | `MetaData` | 0, collapsed | `moreInfo` |
| `InfoWindowNameView.nib` | `Name & Extension:` | `Name` | 0, collapsed | `name` |
| `InfoWindowCommentsView.nib` | `Comments:` | `Comments` | 0, collapsed | `comments` |
| `InfoWindowOpenWithView.nib` | `Open with:` | `OpenWith` | 0, collapsed | `openWith` |
| `InfoWindowPreviewView.nib` | `Preview:` | `Preview` | 1, expanded | `preview` |
| `InfoWindowPermissionsView.nib` | `Sharing & Permissions:` | `Privileges` | 0, collapsed | `sharing` |

The root task read those seven accessibility states from the real Finder UI. During the resource check, `defaults read com.apple.finder FXInfoPanesExpanded` returned `Comments = 0; MetaData = 0; Name = 0;`; that contains values the user saved and cannot be called a factory-default dictionary. `InfoDisplayOptions.plist` only holds display values per file kind and gives no disclosure preference for those seven sections.

Tursora adopts this reproducible local baseline: **General and Preview expanded, every other section collapsed**. The Inspector and the Summary apply the same policy to the sections they share by name; the Summary has only General. Any future section not listed here defaults to collapsed.

## Migrating old preferences and remembering choices

The old implementation returned `true` for every section with no stored value and wrote `InfoSection.<key>` immediately on each initialization. An existing `true` therefore cannot distinguish a deliberate expansion by the user from an automatic save by the program; simply keeping every old `true` would leave an installed application expanding everything as before.

The new implementation reads in this order:

1. When the new key `InfoSection.ExplicitExpanded.v2.<key>` holds a Bool, that value is respected in full.
2. With no new key, when the old key `InfoSection.<key>` is `false`, the old collapsed choice is kept.
3. When the old key is missing or `true`, the observed baseline is used.

The new key is written only when the disclosure state is explicitly set or toggled; building a section or opening a new window produces no preference. Old keys are neither deleted nor overwritten. Info, the Inspector and the Summary share the preference for sections of the same name, and a newly opened or rebuilt window reads the most recent choice; other windows already open are not forced to collapse in step.

This is a deliberate compatibility trade-off: **a section the user deliberately expanded in an old version but saved only as an old `true` also falls back to the new baseline**, because the old format gives nothing to tell the two apart. Once the user deliberately expands it again, now or later, it is saved explicitly under the new key and is no longer subject to the migration rule. It cannot be claimed that every historical manual expansion survives intact.

## Verification status

In the screenshot stage, before the Dock work and the later input-method changes, the full smoke test on the combined sources **passed three times in a row, 2,024 checks each**, all three with exit 0 and empty stderr; that is the total for a combined suite that includes the Info disclosure regressions. The final results of the later Dock / input-method stage are in the [Dock research record](dock-menu.md).

`InfoDisclosureSmokeTests.swift` uses an isolated UserDefaults suite and temporary files, covering the default value, an old automatic `true`, an old `false`, the precedence of a new explicit `true` / `false`, initialization writing no preference, reopening after expanding and after collapsing, section construction in the real Info / Inspector / Summary, and memory across windows. The corresponding fixtures in the main smoke test now use the new explicit keys, isolating both the old and the new keys when the tests start and restoring them at the end, so that existing choices cannot affect the results and the tests cannot rewrite the user's preferences.

Finder's actual state has the accessibility evidence above. Tursora's release bundle for that screenshot stage built successfully, with the log at `/private/tmp/tursora-tabs-appearance-verification/release-final.log`; the root task confirmed that the strict codesign, the Info.plist lint and the in-bundle icon consistency check passed. Opening `Brief.md Info` for real, the native accessibility tree confirmed General and Preview expanded and More Info, Name & Extension, Comments, Open with and Sharing & Permissions collapsed, with a fragment of that Markdown file's text visible in the window.

Remembering the choice across a reopen after a manual toggle has not been verified separately on a real machine; the evidence is limited to the automated tests above. The original dark Info screenshot was rejected by the transparency tool over residuals in the corner estimate, so no PNG was published; this section relies on the actual accessibility state rather than substituting another image, see the [rejection case](screenshot-transparency.md#assets-and-verification-in-this-round). All of the above is native observation of the 2,024-check stage release bundle; the final verification after the Dock / input-method changes is recorded separately.

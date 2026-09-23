# Lazy ZIP browsing: what bsdtar actually does

Browsing a ZIP stages the whole archive before a single row appears. This record holds the measurements
behind replacing that with a listing plus on-demand materialization, and the traps found along the way.

Measured on macOS 26 (`Darwin 25.3.0`), `bsdtar 3.5.3 - libarchive 3.7.4`, 2026-09-22. Every command was
run under the app's own environment — `env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8` — and the app's own
flag set, because both change the answers.

## The shape of the win, and where it stops

| Archive | entries | `tar -tvf` (list) | one entry | full extract |
|---|---|---|---|---|
| SDK `usr/include` zipped | 4,128 | 0.049 s | 0.043 s | 0.566 s |
| synthetic | 1,000 | 0.035 s | 0.034 s | 0.140 s |
| synthetic | 10,000 | 0.073 s | 0.062 s | 0.948 s |
| synthetic | 50,000 | 0.256 s | 0.198 s | 5.873 s |

Two facts decide the design:

1. **Per-invocation cost is linear in the archive's total entry count and independent of where the member
   sits.** On the 50,000-entry archive the first member costs 0.197 s and the last 0.199 s — bsdtar
   seeks through the central directory, so every invocation pays one central-directory parse.
2. **Batching is nearly free.** On the same archive, via `-T`: 1 member 0.197 s, 10 → 0.211 s,
   100 → 0.300 s, 1,000 → 1.186 s. About 1 ms per extra member on top of the parse floor.

Together those give the crossover: **about twelve entries** on a realistic archive
((0.566 − 0.049) / 0.043). Opening a dozen files one at a time already costs more total tool time than
staging the whole archive once. So materializing **per directory** — one invocation for a directory's
direct children — keeps both the time win and the disk win, while true per-entry materialization keeps
only the disk win and starts losing time as soon as the user opens things.

### End to end, on a 10,000-entry archive

Re-measured after the change landed, on a 100-directory × 100-file archive (1.2 MB compressed,
39 MB expanded), under the app's own flags:

| operation | time | written |
|---|---|---|
| list the whole archive (`tar -tvf`) | **0.091 s** | nothing |
| materialize one directory (100 files) | **0.165 s** | 400 KB |
| extract the whole archive — what opening used to cost | **2.251 s** | 39 MB |

Opening therefore costs the listing plus the directory skeleton — about 0.1 s against 2.25 s — and
browsing one folder writes 400 KB instead of 39 MB. The gap widens with archive size, because the full
extraction is linear in total content while the listing is linear only in entry count.

## Encryption: the listing lies, and the failure leaves debris

```
$ zip -q -P hunter2 enc.zip src/s.txt
$ python3 -c "d=open('enc.zip','rb').read(); print(d[:4].hex(), '0x%04x' % int.from_bytes(d[6:8],'little'))"
504b0304 0x0009

$ tar -tvf enc.zip --passphrase $(uuidgen); echo "rc=$?"
-rw-r--r--  0 501    0          20 Sep 22 23:02 src/s.txt
rc=0

$ tar -x -f enc.zip -C out … --passphrase $(uuidgen); echo "rc=$?"
src/s.txt: Incorrect passphrase: Unknown error: -1
tar: Error exit delayed from previous errors.
rc=1

$ ls -l out/src/s.txt && xxd out/src/s.txt
-rw-r--r--@ 1 zerol  wheel  20 Sep 22 23:02 out/src/s.txt
00000000: 0000 0000 0000 0000 0000 0000 0000 0000  ................
00000010: 0000 0000                                ....
```

The listing **succeeds**, with the right name and the right size. The extraction then fails and leaves a
correctly-sized, entirely zero-filled file at the correct path. `FileItem.readableContentURL` tested only
`fileExists`, so that file would be handed to Quick Look, `NSWorkspace`, drag-out and Copy as if it were
the real thing. (It is now `publishedContentURL`, which reads the entry's state instead — D97.)

Two consequences, both now implemented (D91):

- The archive is refused up front, from **bit 0 of the local header's general-purpose flag** — an 8-byte
  read, before any temporary directory exists. An empty ZIP starts `50 4b 05 06` and carries no such
  header, so it is skipped rather than misread.
- **Success is tar's exit status, never `fileExists`.** This rule has to survive into anything that
  materializes lazily.

## Path defences survive being split across invocations

This is what makes per-directory materialization safe at all: libarchive re-checks the on-disk path
components at write time, so protection is not a property of extracting the archive in one go.

```
# invocation 1 — the escaping symlink alone
$ tar -x -f evil.zip -C out … -- link ; echo "rc=$?"
link/outside.txt: Cannot extract through symlink link/outside.txt: Undefined error: 0
rc=1
$ ls -l out/
lrwxr-xr-x  link -> …/scratchpad/sym

# invocation 2 — a SEPARATE process, through the symlink that is already on disk
$ tar -x -f evil.zip -C out … -- 'link/outside.txt' ; echo "rc=$?"
link/outside.txt: Cannot extract through symlink link/outside.txt: Undefined error: 0
rc=1

$ cat sentinel.txt
PROTECTED
```

The refusal is identical in the second process, and the sentinel outside the root is untouched.

Note also that member `link` prefix-matched `link/outside.txt` in invocation 1. That over-match is what
`-n` (`--no-recursion`) exists to prevent — but `-n` is correct only for a **leaf file**: on a directory
it returns `Not found in archive` for any directory the ZIP never stored explicitly, which is most of
them.

## Corrections to earlier assessments

Two claims recorded in `docs/ROADMAP.md` as reasons to defer this feature are **false**, and were struck
when this record was written:

- **"bsdtar mangles CJK entry names."** It does not. `sub/中文文件.txt` lists byte-identically to the
  source bytes. (`unzip -Z1` is the one that mangles them.)
- **"There is no literal-match option, so per-entry extraction is impossible."** There is.
  `tar -x -f t.zip -C out 'star*.txt'` takes three files; `tar -x -f t.zip -C out 'star\*.txt'` takes
  exactly one. Escaping `*`, `?`, `[`, `]` and `\` is mandatory, and over-escaping is harmless.

A third claim, that `--mac-metadata` costs resource forks, is also false — measured, single-member
extraction **with** the flag restores `com.apple.ResourceFork` and `com.apple.metadata:*`, and without it
neither survives. The flag stays.

## What shipped

**Mount, not expand.** Opening an archive reads its table of contents, creates a directory skeleton and
writes its symbolic links. No file's bytes are read. A directory's own files arrive in one batch when
that directory is listed, and an application bundle or multi-file document is brought in whole.

The batch lives in `entries(in:)` rather than in its caller. That is deliberate: `entries(in:)` reads
the disk, and the disk is only correct after materialization, so leaving the two apart means every
caller has to remember. The first caller that forgot was found immediately by an existing check — the
session-level entry test, which drives `entries(in:)` directly rather than through the provider.

**Symbolic links at mount, not lazily.** `entries(in:)` derives `canAccess` from `validatedURL` on the
real link, so an escaping link that is not yet on disk is indistinguishable from a safe one. Writing
them at mount keeps the existing inertness guarantees exactly as they were.

**`-n` for a leaf, never for a directory.** A member that names a leaf otherwise prefix-matches deeper
entries: member `clash` also tries `clash/inside.txt` and reports an error. But with `-n`, a directory
the ZIP never stored explicitly is "Not found in archive" — which is most directories. So the two kinds
go in two invocations, and `-q` is never used at all: it stops at the first match per pattern and
silently truncates a subtree.

**Path rewrites are reproduced, not assumed.** Measured against bsdtar: `/etc/evil.txt` extracts to
`etc/evil.txt`, `C:/win.txt` to `win.txt`, `./dotslash.txt` to `dotslash.txt`. The tree performs the
same rewrites so a listed row resolves to the path extraction will actually write. A row that cannot be
addressed at all — a `..` component, or a name the listing had to escape — is listed and inert.

One behaviour change falls out of that and is worth stating plainly: an archive containing a `..` entry
**used to refuse to open at all**, because the whole-archive extraction exited non-zero. Now it opens and
every other entry browses normally. The refused entry itself is not shown: a directory's listing reads
the disk, and bsdtar never writes that entry there. (An earlier draft of this record said the row was
"visible and inert"; that was never true of this stage, and no check asserted it.)

## Dates and counts (Stage 3)

Stage 1 shipped two regressions, caught before merge. The directory skeleton is made with `mkdir`, so a
folder inside an archive showed when the archive was opened rather than its recorded date:

| | folder `Old` | folder `Old/Sub` | file `Old/g.txt` |
|---|---|---|---|
| full extraction (before) | 2020-01-01 | 2020-01-01 | 2020-01-01 |
| lazy mount, Stage 1 | **when opened** | **when opened** | 2020-01-01 |

And an unentered folder read "0 items", because `FolderSizes` counts from disk and the folder was only
its skeleton.

Dates now come from the central directory. The field that matters is not the one usually documented:

```
$ python3 -c "…print extra-field ids for each central-directory record…" old.zip
  Old/          dos=(2020, 1, 1, 12, 0, 0)  extra=['0x5855']
  Old/Sub/      dos=(2020, 1, 1, 12, 0, 0)  extra=['0x5855']
  Old/Sub/f.txt dos=(2020, 1, 1, 12, 0, 0)  extra=['0x5855']
```

`ditto` — and so Finder's Compress — writes `0x5855` (Info-ZIP Unix: atime, then mtime), not the
`0x5455` extended timestamp that Info-ZIP's `zip` writes. A reader that knew only `0x5455` would fall
back to two-second DOS time for every Finder-made archive. The reader follows libarchive's precedence
exactly (DOS first, then `0x5455` / `0x5855` / `0x000d` overriding, NTFS not read), and the suite checks
the result against the extractor rather than trusting the reasoning: for a Finder-made archive with
entries dated 2010 and 2020, every entry's central-directory date equals the date a full extraction
writes to disk.

Counts now come from the tree, filtered as the listing is. Both regression checks were run against the
unfixed code first and failed there — the folder date read as the open time, the count as "0 items" —
so they are known to guard what they claim to.

## Mixed encryption, and the package shell

The Stage 2 design pass found that D91's pre-flight — which reads only the **first** local header — let
through an archive that starts plain and holds an encrypted member later. Built with Info-ZIP's own
`zip`, one member at a time:

```
d/a.txt    flag=0x0000
d/b.txt    flag=0x0009
d/c.txt    flag=0x0000
first local header flags: 0x0000        ← the pre-flight passes

$ tar -x -n -f mixed.zip -C out … -T {d/a.txt, d/b.txt, d/c.txt}
d/b.txt: Incorrect passphrase: Unknown error: -1
tar: Error exit delayed from previous errors.

out/d/a.txt: 706c61696e206f6e65          "plain one"
out/d/b.txt: 000000000000                six zero bytes, listed as readable
out/d/c.txt: 706c61696e207468726565      "plain three"
```

The batch's non-zero exit was swallowed, and the listing read the disk. The fix reads bit 0 of every
central-directory record, not just the first local header, and never asks for an encrypted member
(D94). The check was run against the unfixed code first and failed there with the six zero bytes.

A package containing an encrypted member is extracted whole with that member passed as `--exclude`,
which works on either side of `-T` and leaves nothing behind (measured).

Separately, package status is decided per path by extension, so the skeleton used to create
`Demo.app/Contents` — and with it the package's empty shell — before the package was extracted. A
node now knows it is inside a package and is left out of both the skeleton and the mount-time links.

## Staging, attribution and publication (Stage 2 core)

Three measurements decided the shape of the core.

A CRC-corrupt member is written to disk **with the corrupt bytes**; the only sign is on stderr:

```
x d/a.txt
x d/bad.txt: ZIP bad CRC: 0xbde39420 should be 0x5ca44334: Unknown error: -1
x d/c.txt
tar: d/nope\*.txt: Not found in archive
tar: Error exit delayed from previous errors.

on disk:  d/a.txt[good one]  d/bad.txt[�orrupt me]  d/c.txt[good three]
```

So bsdtar never writes into the tree being browsed any more; it writes into staging, and a member is
published only on a clean `x name` line. The same log also shows the "Not found" line repeating the
**escaped** spelling it was given, which is why attribution matches it that way.

Extracting into empty staging bypasses bsdtar's own symlink defence, and a plain rename then follows
the link:

```
renamex_np(staging/link/x.txt, root/link/x.txt, RENAME_EXCL)                    rc=0      outside/: x.txt
renamex_np(…,                                 RENAME_EXCL|RENAME_NOFOLLOW_ANY) ELOOP     outside/: (empty)
```

And bsdtar's option order is load-bearing: `… big --exclude 'big/*/*'` reads `--exclude` as a second
pattern and extracts the whole subtree, package included; `--exclude 'big/*/*' -- big` takes exactly
the direct files.

One thing only running the suite revealed: `RENAME_NOFOLLOW_ANY` applies to **both** paths. Staging
lives under `$TMPDIR`, which is under `/var`, itself a symbolic link, so publication failed with ELOOP
on every member until the staging side was put through `realpath(3)` as the destination already was.

For a Finder-made archive, `-v` names only real entries (no `__MACOSX` lines) and a custom extended
attribute survives both a selection and a leaf extraction. A selection also announces the selected
folder's own record (`x F/`), which attribution counts as a known name.

## Session lifecycle

`clonefile(2)` of the archive into the session's storage succeeds whenever the ZIP and `$TMPDIR` share
a device — an ordinary Mac, measured — and the clone carries `com.apple.quarantine` over, so the clone
is the only file a session ever reads. Renaming the original after opening is checked to change
nothing. With cloning forced to fail, replacing the original is checked to be refused as
`sourceChanged`, to leave no member failed for good, and to make the holding workspace mount the new
archive and read its new contents.

Closing and quitting are checked with a runner that holds a batch in flight: a session closed mid-run
keeps its storage until the child stops, then removes it and completes once, and a quit does not
complete until then.

## Rows from the table of contents

A row has to exist before its bytes do and must not change when they arrive, so every field of an
archive row now comes from the tree (D97). Measured on this Mac, APFS, case-insensitive:

**Two spellings of one name.** An archive holding `c/A.txt` ("upper") then `c/a.txt` ("lower"),
extracted whole, leaves one file named `a.txt` holding "lower": the later entry wins the name and the
bytes. `D/one.txt` then `d/two.txt` leaves one folder, `D`, holding both: a folder keeps the first
spelling it was created with. The tree does the same, keyed by the folded path.

**How APFS folds.** Creating one name and testing for the other:

| Pair | APFS collides | `lowercased()` equal | `folding(.caseInsensitive)` equal |
|---|---|---|---|
| `ß` / `ss`, `ß` / `SS` | yes | no | yes |
| `ẞ` / `ß`, `Σ` / `σ`, `Å` / `å`, `Ǆ` / `ǅ`, `K` / Kelvin sign | yes | yes | yes |
| `σ` / `ς`, `ﬁ` / `fi` | yes | no | yes |
| `ı` / `I`, `İ` / `i` | no | no | no |

So the tree folds with `folding(options: .caseInsensitive, locale: nil)`, with a `lowercased()` fast
path for ASCII, and only when the storage volume reports `volumeSupportsCaseSensitiveNames == false`.

**Unicode normalization needs no code.** An archive holding `café.txt` in NFC then in NFD lists
*both* as NFD (`63 61 66 65 cc 81`): libarchive converts every name to NFD on macOS. An NFC pattern in
`-T` is "Not found in archive"; the NFD pattern extracts both entries. Swift compares and hashes
strings by canonical equivalence, so the two forms are one tree key, and a central-directory record
stored in NFC still joins onto the NFD listing name.

**bsdtar's matching is case-sensitive; the volume is not.** `-T` with `c/a.txt` takes only that
entry, and with `c/A.txt` only that one. A directory include `D` takes `D/one.txt` and not
`d/two.txt`. `--exclude c/A.txt` leaves `c/a.txt` extracted. Hence two rules: a member whose own
spelling differs from its row's path is always asked for by name, and an earlier spelling a later one
replaced is excluded from its folder's selection by name. The exclusion is only recorded for a
spelling bsdtar tells apart — it treats a leading `./` or `/` and repeated separators as the same
name, so excluding `./a.txt` would take `a.txt` with it. A package member spelled with the package's
other case (`demo.app/x` beside `Demo.app/…`) is named in the package's run, and the package arrives
whole.

**Creation dates.** bsdtar sets each item's modification date, and on APFS setting it earlier than
the item's birth moves the birth back with it: after extraction a file and a folder both have
`birth == mtime ==` the archive's date. So Date Created on a row is the archive's date, as it will be
on the extracted copy. Date Added and Date Last Opened have not happened to an entry that is only in
the archive, and show "--".

**Kind.** In an ordinary folder a symbolic link reads as Kind "Alias", type `public.symlink`, with the
link's own size; a folder is "Folder"; an extensionless file is "Document" (`public.data`), or
"Unix Executable File" (`public.unix-executable`) with its execute bit set; `X.app` is "Application"
and `X.rtfd` "Rich Text Document with Attachments" even as empty directories. `UTType`'s own
descriptions differ — "folder", "symbolic link", "Unix executable", "data" — so they are only the
fallback. LaunchServices decides a Kind from the extension, folder-ness and the execute bit, not from
the contents, so an empty probe file of the same shape answers exactly as the extracted item. Probes
are made at mount under `storage/.tursora-kind-probes`, for at most 256 shapes, most common first, and
deleted once read. `NSString.pathExtension` gives a dotfile such as `.hidden` no extension, so its
probe is an extensionless file, as the extracted dotfile is.

**Links.** A link row is resolved through the tree the way the kernel resolves it on disk: each link's
target is read from the link bsdtar wrote at mount, `..` after a link climbs from where the link
leads, an absolute target or `..` above the root escapes, and more than 32 links (`MAXSYMLINKS`) is a
loop. A link row shows the shape, size and readability of where it leads, with its own date and Kind,
so a link into a folder not yet entered can be entered, and one that escapes, dangles or loops is
shown unavailable.

**Readable URLs.** `readableContentURL` became `publishedContentURL`: the entry's state must be
`published` — never `fileExists`, which says nothing about whether the bytes are sound — and
containment is checked again at the point of use. A folder qualifies once nothing below it is left to
bring (everything extractable published or failed); that walk of the tree is kept until any entry's
state changes, so menu validation does not repeat it.

Coverage: pure tree checks for folding, normalization, the link table (including a 33-hop chain and a
hop through a package) and listed children; a materializer check that the folded pair publishes one
file with the later bytes and that a folder's other-case member and a package's other-case member
arrive; the type catalog, including the 256-probe limit; and, in `ArchiveWorkspaceSmokeTests` with
nothing extracted on listing, rows for a `.txt`, an extensionless file, an executable, a dotfile,
`.app`, `.rtfd`, `.framework`, `.xcodeproj` and a folder compared field by field with a full
extraction of the same ZIP, links into unentered folders, and a walk proving no file was written.

## Open, Copy and copying out

Stage 1 got an entry's bytes through `readableURL(for:)`, which on a miss extracted the entry's whole
directory synchronously on the caller's thread — the main thread for ⌘C, Copy to Other Pane and a
drop — and handed out a folder's skeleton, so a folder copied out of an archive arrived with only the
subfolders that had been visited filled (D98).

Checked in `ArchiveOpenSmokeTests`, in the list, icon and column views, with a second tab and a split
pane open, grouping on and a filter applied, and the workspace set to extract nothing on listing — so
every byte these checks see was brought by the action under test:

- Menu, context-menu, palette and toolbar enabling, and the address bar resolving a folder never
  visited, leave the counter of archive-tool runs where it was and extract nothing.
- Open With lists applications for a `.txt` and an `.rtfd` before either exists on disk.
- Opening three files not yet extracted, twice in the same turn, launches each once with its real
  bytes, from one run of the tool.
- Quick Look of a file not yet extracted brings it and then shows it.
- ⌘C of a package not yet extracted clears the pasteboard at once and then holds the whole package; a
  ⌘C still being prepared does not overwrite a string copied after it.
- Copy to Other Pane on a folder gives a byte-identical tree, including a folder never visited and an
  application bundle — the Stage 1 partial-copy bug.
- A copy held at the archive tool (a gate in the runner) is preparing and offers no Pause; cancelling
  it leaves the destination empty.
- A CRC-damaged member that fails on Open turns unavailable in the pane without being opened, and
  Reload (⌘R) forgets the failure so it can be tried again.

What is not covered: the File Operations row for a request estimated above a second or 128 MiB is
decided by the measured cost model but not exercised, since the suite's fixtures stay under 50 MB; and
no computer-use pass has been made.

## Status

Stage 0 (the pre-flight refusals above, the throwing listing seam, the free-space guard and the
lock-based launch sweep) and the lazy mount are both implemented. Coverage: pure tree rules in
`ArchiveSmokeTests`; the invariant that mounting writes no regular file anywhere under the root, and
that listing one directory leaves a deeper one alone, in `ArchiveWorkspaceSmokeTests`; and the pane
path in all three views — with a split pane and a second tab open and with a filter and grouping
active, plus the bundle and `..` cases — in `LazyArchiveSmokeTests`.

Stage 2 is in progress: the staging and publication core, the private clone with drain-on-close, and
rows built from the table of contents are implemented and covered as described in their sections.
Open, Open With, Quick Look, Copy and copying out bring what they need first (above). Still missing:
listing still extracts a folder's own files, so a single directory holding tens of thousands of files,
or one very large member, still pays for the whole directory on entry; and drag, Share, the preview
column and thumbnails still need an entry's bytes on disk already.

No computer-use pass on the packaged app has been made for any of this, so no claim is made about how
opening a large archive actually feels.

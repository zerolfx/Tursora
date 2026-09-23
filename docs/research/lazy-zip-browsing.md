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
correctly-sized, entirely zero-filled file at the correct path. `FileItem.readableContentURL` tests only
`fileExists`, so that file would be handed to Quick Look, `NSWorkspace`, drag-out and Copy as if it were
the real thing.

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

## Status

Stage 0 (the pre-flight refusals above, the throwing listing seam, the free-space guard and the
lock-based launch sweep) and the lazy mount are both implemented. Coverage: pure tree rules in
`ArchiveSmokeTests`; the invariant that mounting writes no regular file anywhere under the root, and
that listing one directory leaves a deeper one alone, in `ArchiveWorkspaceSmokeTests`; and the pane
path in all three views — with a split pane and a second tab open and with a filter and grouping
active, plus the bundle and `..` cases — in `LazyArchiveSmokeTests`.

Still missing: a single directory holding tens of thousands of files, or one very large member, still
pays for the whole directory on entry. That is Stage 2, true per-entry deferral.

No computer-use pass on the packaged app has been made for any of this, so no claim is made about how
opening a large archive actually feels.

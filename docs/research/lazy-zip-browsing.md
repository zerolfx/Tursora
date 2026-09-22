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

## Status

Stage 0 (the pre-flight refusals above, the throwing listing seam, the free-space guard and the
lock-based launch sweep) is implemented and covered in `ArchiveSmokeTests`. The lazy mount itself is the
next stage; until it lands, browsing still stages the whole archive.

No computer-use pass on the packaged app has been made for any of this.

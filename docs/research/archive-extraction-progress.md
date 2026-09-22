# Extraction progress: what bsdtar actually reports

Right-click **Extract** showed a 16 pt spinner and could not be cancelled at all — `FileOperations.extract`
never passed the `cancellation` that `runArchiveTool` already accepted. This record holds the
measurements the replacement is built on, taken on macOS 26 (`Darwin 25.3.0`) on 2026-09-22, and the
two traps that would otherwise have shipped a broken progress bar.

Every command below was run under the app's own environment, `env -i PATH=/usr/bin:/bin
LANG=en_US.UTF-8`, because that is what `runArchiveTool` pins and `LANG` is what fixes the date column
count the listing parser depends on.

## The verbose stream goes to stderr, which is already a regular file

```
$ tar -x -v -f out.zip -C ex --no-same-owner --no-same-permissions --mac-metadata \
      --no-acls --no-fflags --passphrase zzz 2>&1 1>/dev/null
x big.bin
x link.bin
x sub/
x sub/中文文件.txt
x sub/with space.txt
x a.bin
```

`runArchiveTool` already sends stderr to a regular file in the workspace, with a comment saying why: a
regular file cannot fill and deadlock `waitUntilExit()`, which a pipe can. Polling that file introduces
no pipe, so the property is preserved rather than traded away. The poll loop always falls through to
`waitUntilExit()`, so the child is reaped whichever way the run ends.

## The listing total is exact

```
$ tar -tvf out.zip | awk '{print $5}' | paste -sd+ - | bc
307210
$ find ex -type f -print0 | xargs -0 stat -f%z | paste -sd+ - | bc
307210
```

Byte for byte. This is the whole reason no ZIP parser of our own is used: bsdtar's listing agrees with
bsdtar's extraction by construction, including its `__MACOSX` AppleDouble folding. An independent
parser would have to reproduce that folding exactly, and any disagreement produces a bar that never
reaches 100%.

Flags accepted in `-t` mode were checked rather than assumed: `--passphrase` **is** accepted (so an
encrypted archive fails instead of opening `/dev/tty`), `--mac-metadata` is **not**.

## An entry is announced when it is opened, not when it is finished

So the credited figure is every announced entry except the last, plus however much of the last one is
on disk right now. That size is read through `FileManager.attributesOfItem`, never
`URL.resourceValues`, which is cached for the rest of the run-loop pass — the reported size would
simply stop moving (AGENTS.md rule 5, `docs/DEVELOPMENT.md` § AppKit pitfalls).

## Trap 1 — a symbolic link's listing line is not its extraction line

```
$ tar -tvf out.zip
-rw-r--r--  0 501    0      307200 Sep 22 19:42 big.bin
lrwxr-xr-x  0 0      0           0 Sep 22 19:42 link.bin -> a.bin
drwxr-xr-x  0 501    0           0 Sep 22 19:42 sub/
-rw-r--r--  0 501    0           5 Sep 22 19:42 sub/中文文件.txt
-rw-r--r--  0 501    0           1 Sep 22 19:42 sub/with space.txt
-rw-r--r--  0 501    0           4 Sep 22 19:42 a.bin

$ tar -x -v ... 2>&1 1>/dev/null | grep link
x link.bin
```

The listing says `link.bin -> a.bin`; the extraction says `x link.bin`. A parser that takes "everything
after the eighth field" as the name never matches the stream, and under a rule of "an unrecognised name
means the total is unknown" **every archive containing a symbolic link falls back to an indeterminate
spinner** — every zipped `.app`, framework or `node_modules` tree, and this repository's own archive
fixture (`ArchiveSmokeTests.swift`, the `shortcut` link).

The suffix is therefore stripped only when the mode character is `l`, never on a ` -> ` substring:
`a -> b.txt` is a legal filename, and stripping its suffix would stop *it* ever matching the stream.
Both cases are pure checks in `ArchiveSmokeTests`.

Names with spaces and non-ASCII names are byte-exact in both streams, which is why the split stops at
eight fields and the name is taken whole.

## Trap 2 — an error line also begins with `x `

```
$ tar -x -v -f evil.zip -C ev ... 2>&1 1>/dev/null
x ../../outside.txt: Path contains '..': Unknown error: -1
x ok.txt
tar: Error exit delayed from previous errors.
```

The traversal refusal — the thing the user most needs to be told — is reported on a line starting
`x `. Filtering progress with a naive `^x ` would delete exactly that message and leave the user with
a failure and no reason. `ArchiveExtractionProgress.errorDetail(from:knownEntries:)` drops only lines
whose whole text is `"x " + a known entry name`, and a pure check pins it.

## What Archive Utility does

Finder hands ZIP expansion to `/System/Library/CoreServices/Applications/Archive Utility.app`. Its own
resources show a progress view with Cancel and Skip: `Base.lproj/ProgressView.nib` contains
`NSProgressIndicator`, `_progressProgressIndicator`, `_progressMessageTextField`,
`_progressInformationTextField`, `_progressCancelButton`, `_progressSkipButton`, `doProgressCancel:`
and `doProgressSkip:`. So macOS's own extractor does show progress and does offer a cancel.

**Inferred**, and marked as such: whether Archive Utility's indicator is determinate or indeterminate.
The nib names an `NSProgressIndicator` but not its style, and no computer-use observation of Archive
Utility was made.

## Why no Pause

`NSTask.h` annotates both `interrupt` and `terminate` with `// Not always possible.`, and `suspend` /
`resume` return a `BOOL` that would have to be checked and handled. More decisively, a paused
extraction holds its whole `.tursora-archive-<uuid>` staging tree open inside the user's own folder for
as long as it is paused. Extraction ships with determinate progress and Cancel, and the spec says so.

## What the figure means

Uncompressed bytes **written**, not archive bytes **read**. A row's rate and estimate are therefore not
comparable with a copy's, and progress is entry-granular: one very large member inside an archive
advances in a single step once it completes. `docs/SPEC.md` § 14 states this so a reader is not left to
infer it from the bar.

## Verification

Pure checks in `ArchiveSmokeTests` cover the listing parser (file, directory, symlink-with-arrow,
file-named-with-an-arrow, spaces, non-ASCII, a non-entry line) and the progress accounting (files-only
totals, announced-means-in-progress, clamping, monotonicity, an unknown entry dropping the total, an
unusable listing giving no total rather than zero, and the error filter keeping a traversal refusal).
End-to-end checks in the same suite run a real extraction with progress over the fixture that contains
a symbolic link and assert the total stays determinate, plus a cancelled run that publishes nothing and
leaves no staging directory.

`ExtractTaskSmokeTests` covers the pane path in list, icon and column views, each with a split pane and
a second tab open and with a name filter and grouping active: the task exists, its total is
determinate, it completes with its bytes accounted for, its row is titled Extract rather than Copy, the
contents are published beside the archive, the undo group is named Extract, no staging directory is
left behind, and the other pane and tab are untouched. Cancellation is driven through the task and
asserted to leave nothing behind, and a headless run is asserted to open no task window (AGENTS.md
rule 2).

Three consecutive green smoke runs. No computer-use pass on the packaged app has been made for this
change, so no claim is made about how the row looks while an extraction is actually running.

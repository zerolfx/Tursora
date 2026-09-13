# Compress and extract, compared with Finder (2026-09-12)

On a real machine: macOS 26.3 (25D125). The scope is ordinary ZIP compression and extraction; passwords, Apple Archive, CPIO and split archives are not part of this implementation.

## Evidence from Finder's own resources on this machine

Extraction commands:

```sh
strings /System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings
plutil -convert json -o - /System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/Localizable.strings
```

`MenuBar.nib` has `Compress` → `cmdArchive:`; there is also a separate password-protected compression command, which is not implemented here.

`LocalizableMerged.strings`:

| Key | English value |
| --- | --- |
| `N168_V1` | `Compress` |
| `N168_V2` | `Compress “^1”` |
| `N168_V3` | `Compress ^0 Items` |
| `AR40` | `Archive` |
| `CO2` | `Zip archive` |
| `CO3` | `Apple Archive` |
| `CO4` | `CPIO archive` |
| `CO5` | `CPGZ archive` |

Apple's [guide to compressing and uncompressing](https://support.apple.com/en-ie/guide/mac-help/mchlp2528/mac) describes right-click compression, `.zip` appended to a single item's name, `Archive.zip` for several items, and double-clicking a ZIP to uncompress it. Tursora's explicit `Extract` menu exists to make the operation discoverable inside the app; no corresponding menu wording was extracted from the Finder resources above, so it is not claimed to be a Finder menu of the same name.

## Evidence from the system tools, and implementation limits

The examples in `man ditto` on this machine explicitly use `-c -k --sequesterRsrc --keepParent` to match Finder's compression. Tursora first copies the selected items into an exclusive working directory and then runs `-c -k --rsrc --sequesterRsrc` on the contents of that working directory, so the root of the ZIP contains the selected items directly, with no extra layer of temporary directory around them.

`/usr/bin/tar --version` on this machine: `bsdtar 3.5.3 - libarchive 3.7.4`. The `SECURITY` and `-P` sections of `man bsdtar` state that by default it strips the leading slash from absolute paths, rejects entries containing `..`, and refuses to write into another directory through an intermediate symbolic link. The implementation does not use `-P` or `-U`, which would turn those protections off. The extraction root is always brand new; on failure the whole working tree is discarded and no partial result is merged into a user directory.

`--no-same-owner`, `--no-same-permissions`, `--no-acls` and `--no-fflags` restrict the restoration of ownership and permissions; `--mac-metadata` preserves the AppleDouble resource fork in a ZIP. A comparison on a real machine confirmed that passing `--xattrs` alone does not restore the resource fork — `--mac-metadata` is required. A round trip has been verified with a file that carries both a resource fork and the execute permission. The quarantine on a downloaded ZIP is also propagated to the extracted products, and walking the tree and setting attributes do not follow symbolic links.

Standard input set to `/dev/null` is **not enough** to prevent a password prompt: the tool may open `/dev/tty`. [libarchive's `tar/read.c`](https://raw.githubusercontent.com/libarchive/libarchive/master/tar/read.c) does not install the interactive callback when `--passphrase` is supplied. The implementation passes a random value so that an encrypted archive fails without a prompt; there is no password entry and no password storage.

The result is published only after the tool finishes successfully. A single root item lands directly in the target directory; several root items go into a folder named after the archive. Collisions increment by the numeric-suffix rule used for existing items; `renamex_np(RENAME_EXCL)` provides both atomic publication and non-overwriting, including for concurrent requests and dangling symbolic links. This publication / collision policy is a deliberate Tursora choice; Finder boundaries that have not been measured case by case are not treated as evidence.

## Automated verification

`ArchiveSmokeTests.run(completion:)` contributes 31 separate model checks to the main smoke suite: round trips for a single item/several items/a folder, spaces/Unicode/a leading hyphen, an existing file/directory/dangling link of the same name, concurrent publication, relative symbolic links, resource forks, the execute permission, quarantine, failures on a corrupt/encrypted/empty archive, escapes through a parent path and through a symbolic link, and cleanup after an error with the original files preserved. Every success and failure callback additionally asserts that it runs on the main thread. The UI path is covered by the main smoke suite.

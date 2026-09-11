# Phase 0 — Source Audit

| Document | What it is |
|---|---|
| **[PHASE-0-REPORT.md](PHASE-0-REPORT.md)** | **The deliverable.** All ten required outputs: architecture overview, dependency graph, compatibility matrix, build blockers, required code changes, files to modify, proposed macOS architecture, Phase 1 plan, risks, effort. |
| [00-ground-truth.md](00-ground-truth.md) | Ten findings verified first-hand against the pinned checkouts, with the upstream commit pins. |
| **[VERIFICATION.md](VERIFICATION.md)** | Adversarial re-check of all 61 blocker/major claims. Blockers drop 14 → 4; three claims refuted outright, one citation found fabricated. |
| [sections/](sections/) | Raw output of the twelve parallel audits — dense, evidence-heavy appendices. |

## Appendices

| # | Section | Covers |
|---|---|---|
| 01 | [Dependency graph](sections/01-dependency-graph.md) | full KF6 closure, build waves, Homebrew coverage, build-strategy comparison |
| 02 | [CMake / build system](sections/02-cmake-build-system.md) | platform gates, install layout, app bundle, data-path resolution |
| 03 | [D-Bus](sections/03-dbus.md) | every D-Bus touchpoint in Dolphin and KIO; de-Bus strategy |
| 04 | [Solid / devices](sections/04-solid-devices.md) | IOKit backend gaps, DiskArbitration replacement design |
| 05 | [Baloo / search](sections/05-baloo-search.md) | KFileMetaData, HAVE_BALOO fallout, Spotlight plan |
| 06 | [POSIX / filesystem](sections/06-posix-filesystem.md) | APFS case-insensitivity, NFD/NFC, trash, KDirWatch, xattr |
| 07 | [KIO core](sections/07-kio-core.md) | worker launching, auth, TLS, listing performance |
| 08 | [Core decoupling](sections/08-core-decoupling.md) | component inventory, `libDolphinCore` boundary, bridge API |
| 09 | [UI → AppKit map](sections/09-ui-appkit-map.md) | element-by-element replacement map, shortcut conflicts, DnD |
| 10 | [Qt ↔ AppKit embedding](sections/10-qt-appkit-embedding.md) | event loop, view embedding, responder chain, Obj-C++ conventions |
| 11 | [Core decoupling — second opinion](sections/11-core-decoupling-second-opinion.md) | independent re-audit of the same question; corroborates §08 and identifies the nine-signal model→view contract |
| 12 | [Remote workers](sections/12-remote-workers.md) | every kio-extras gate, sftp/smb deep-dive, thumbnails, network-transparency sites |

Plus **[VERIFICATION.md](VERIFICATION.md)** — the adversarial re-check of all 61 blocker/major
claims, the author's re-verification, and what it says about audit reliability.

## How to read the evidence

Citations are `repo:path:line` against the pins in [00-ground-truth.md](00-ground-truth.md).
Findings the author confirmed or corrected first-hand are marked **✔ verified** / **✎ corrected**;
everything else is single-source audit output and should be re-checked before it drives a
significant decision.

## Headline conclusions

1. **Viable.** KDE already builds Dolphin for macOS via Craft, explicitly without D-Bus, and KIO's
   no-D-Bus path is a maintained configuration spanning 28 files.
2. **The cost is in what de-D-Busing removes** — credential prompting, credential caching, job
   progress, remote-dir refresh, TLS exception storage, and the only search backend.
3. **Phase 3 is architecturally safe.** `KFileItemModel` and `KFileItemModelRolesUpdater` are pure
   `QObject`s with a four-line total QtWidgets contact surface; the render half has zero references
   back to the model.
4. **The riskiest unknown is the split responder chain** (§9 R1). Spike it in week 1 of Phase 2.

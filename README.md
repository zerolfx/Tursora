# Tursora

A native macOS file manager (Swift + AppKit) that brings the parts of KDE Dolphin that Finder lacks — a real address bar with sibling-directory jumps, tabs with independent history, a split view, zoom levels, a filter bar — while keeping Finder's look, labels and dialogs. Local filesystem only in v1; no KDE stack underneath.

## What it does

| Area | Highlights |
|---|---|
| Address bar | Breadcrumb with `›` menus of sibling folders, `⌘L` editing with inline completion and a candidate list, folds from the left when narrow |
| Tabs | `⌘T` / `⌘W` / `⌘⇧T`, `⌃Tab`, `⌘1…9`, drag to reorder, per-tab history / selection / scroll / sort / filter / grouping, drop files on a tab, drag a tab into the content area to split |
| Split view | 1–2 panes per tab like Dolphin, `⌘⇧D`, `⌥⇥`, copy / move to the other pane, open in the other pane |
| Views | List (`NSOutlineView`, folders expand in place) and icons (`NSCollectionView`); Dolphin's zoom ladders via ⌘-scroll, pinch, `⌘+`/`⌘-`, a status-bar slider; Quick Look thumbnails as previews |
| Files | Copy / cut / paste, duplicate, rename (Finder's delayed click-to-rename), trash, delete, drag & drop with Finder's rules, Quick Look, undo / redo per operation, Finder-style conflict dialog with Keep Both / Skip / Replace / Merge and Apply to all |
| Finder parity | Use Groups / Group By with Finder's own group names, toolbar search field with a scope bar, Get Info / Inspector / Summary Info windows with Finder's sections, Finder's menu icons |
| Sidebar | Favourites (add, remove, reorder, reset), volumes with eject, history menus on the back / forward buttons, mouse side buttons and trackpad swipes |
| Live | Panes refresh on outside changes (FSEvents) and keep selection and scroll position |

Everything is built in code: no Xcode project, no nibs. Requires the Command Line Tools with Swift 6.3 or newer; runs on macOS 14 or newer (developed on macOS 26).

## Build, run, test

```bash
cd app && tools/make-app.sh && open "build/Tursora.app"      # release bundle
```

```bash
cd app && swift build && TURSORA_SMOKE_TEST=1 .build/debug/Tursora   # in-app self check (389 checks)
```

More in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Documentation

Start at [docs/README.md](docs/README.md). Picking the project up: [docs/HANDOFF.md](docs/HANDOFF.md). Rules for coding agents: [AGENTS.md](AGENTS.md).

| | |
|---|---|
| [docs/SPEC.md](docs/SPEC.md) | What each feature does and which of Dolphin / Finder it follows (中文) |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Why (中文) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the code is organised, data flows, notifications, persistence, threading |
| [docs/SHORTCUTS.md](docs/SHORTCUTS.md) | Every shortcut, menu item, gesture and drag rule |
| [docs/ROADMAP.md](docs/ROADMAP.md), [docs/gaps/](docs/gaps/) | What is missing versus Finder and Dolphin, with difficulty estimates (中文) |
| [docs/research/](docs/research/) | Evidence extracted from Finder's own resources (group labels, menu icons, Info window labels) |
| [docs/audit/](docs/audit/) | The 2026-08 audit of porting Dolphin / KIO, and why it was not done |
| [CHANGELOG.md](CHANGELOG.md) | History |

## Layout

```
app/                Swift package: Sources/Tursora/{Model,UI}, SmokeTest.swift, tools/make-app.sh
docs/               specs, decisions, architecture, development guide, gaps, research, audit
upstream/           read-only KDE checkouts used by the audit and for Dolphin's semantics (git-ignored)
```

## Background

This repo began as a port of KDE Dolphin to macOS. The Phase 0 audit ([docs/audit/PHASE-0-REPORT.md](docs/audit/PHASE-0-REPORT.md)) concluded the port was viable but that, for the basic feature set, the KDE / KIO stack was almost entirely cost: listing, copying, trash, Quick Look, thumbnails, search and tags are free on macOS, and Dolphin's real differentiators are UI behaviours. So the research was kept and the app rebuilt natively. It was called Otter File Manager until 2026-09-11.

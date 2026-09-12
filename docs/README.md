# Documentation index

| Read this when… | Document | Language |
|---|---|---|
| you are picking the project up | [HANDOFF.md](HANDOFF.md) — state, what is verified and what is not, next steps | 中文 |
| you need the intended behaviour of a feature | [SPEC.md](SPEC.md) — v1 spec, each section marked "对标 Dolphin / Finder" | 中文 |
| you wonder why something is the way it is | [DECISIONS.md](DECISIONS.md) — decision log D0–D48 | 中文 |
| you are changing code | [ARCHITECTURE.md](ARCHITECTURE.md) — object graph, per-file map, data flows, notifications, persistence, threading | English |
| you are building, testing or releasing | [DEVELOPMENT.md](DEVELOPMENT.md) — toolchain, smoke test, conventions, AppKit pitfalls, release checklist | English |
| you are editing or previewing the Chinese product page | [site/README.md](../site/README.md) — three workflows, canonical screenshots, Python static build and browser checks; [architecture](ARCHITECTURE.md#product-page) | English |
| you need a key binding or menu item | [SHORTCUTS.md](SHORTCUTS.md) — every shortcut, menu, gesture and drag rule | English |
| you are choosing what to do next | [ROADMAP.md](ROADMAP.md), then [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md) and [gaps/GAP-vs-DOLPHIN.md](gaps/GAP-vs-DOLPHIN.md) with difficulty estimates | 中文 |
| you are changing file-operation tasks or their lifecycle | [research/file-operation-tasks.md](research/file-operation-tasks.md) — Dolphin routing evidence, transfer boundaries, adversarial review and verification | 中文 |
| you are checking the three feature PRs together | [research/pr-integration-2026-09-12.md](research/pr-integration-2026-09-12.md) — merge stages, cross-feature fixes and validation status | 中文 |
| you are changing split-pane paths, tab titles or tab context actions | [research/pane-paths-and-tab-actions.md](research/pane-paths-and-tab-actions.md) — pinned Dolphin semantics, target ownership, fresh-window detach and current verification; [SPEC.md §2–4](SPEC.md#2-地址栏对标-dolphin核心差异化) | 中文 |
| you are changing Get Info section defaults | [research/info-disclosures.md](research/info-disclosures.md) — local Finder evidence and explicit-choice migration | 中文 |
| you are changing Dock shortcuts | [research/dock-menu.md](research/dock-menu.md) — fixed destinations, explicit action targets and Finder label evidence | 中文 |
| you are preparing README or site screenshots | [images/README.md](images/README.md), [research/screenshot-transparency.md](research/screenshot-transparency.md) — deterministic alpha preparation and pixel verification | English / 中文 |
| you are preparing a versioned release, drag-install DMG or future Apple signing | [RELEASING.md](RELEASING.md), [../CHANGELOG.md](../CHANGELOG.md); older implementation entries are in [DEVELOPMENT_HISTORY.md](DEVELOPMENT_HISTORY.md) | English |
| you are changing software updates, release signing or update settings | [research/app-updates.md](research/app-updates.md) — Sparkle driver, stored choices, release feed, key readiness and verification; [SPEC.md §20](SPEC.md#20-软件更新sparkle-原生更新流程) | 中文 |
| you are configuring or deploying GitHub Pages | [research/github-pages.md](research/github-pages.md) — public repository evidence, workflow, subpath checks and deployment status; [site/README.md](../site/README.md) | 中文 / English |
| you are changing text icon previews | [research/text-thumbnails.md](research/text-thumbnails.md) — readable excerpts, Finder / Dolphin evidence and stale request checks | 中文 |
| you are changing tab appearance or Light/Dark adaptation | [research/tabs-and-appearance.md](research/tabs-and-appearance.md) — Apple references, adaptive layers, overflow and verification | 中文 |
| you are changing the application icon or its export | [research/app-icon-edges.md](research/app-icon-edges.md) — original artwork, explicit alpha silhouette, legacy ICNS boundary and verification | 中文 |
| you are changing recursive / saved search | [research/search-input-reference.md](research/search-input-reference.md), [research/search.md](research/search.md), [research/search-verification.md](research/search-verification.md), [SPEC.md §19](SPEC.md#19-搜索dolphin-语义macos-后端) | 中文 |
| you are matching Finder and need the evidence | [research/finder-group-labels.md](research/finder-group-labels.md), [research/finder-menu-icons.md](research/finder-menu-icons.md) | 中文 |
| you are changing settings, shortcuts or experimental panels | [research/settings-and-shortcuts.md](research/settings-and-shortcuts.md), [research/dolphin-terminal.md](research/dolphin-terminal.md), [SPEC.md §16–18](SPEC.md#16-设置与过滤快捷键) | 中文 |
| you are changing per-directory view memory, defaults or storage identity | [research/directory-view-properties.md](research/directory-view-properties.md) — pinned Dolphin evidence and Tursora's application-owned path library; [SPEC.md §5](SPEC.md#5-视图模式缩放与预览对标-dolphin) | 中文 |
| you are changing startup, quit or workspace restoration | [research/workspace-sessions.md](research/workspace-sessions.md) — window/tab/pane snapshot scope, storage errors, settings and verification stages; [SPEC.md §22](SPEC.md#22-工作区会话恢复工作连续性) | 中文 |
| you are checking native archive and server behavior | [research/finder-archives.md](research/finder-archives.md), [research/archive-browsing.md](research/archive-browsing.md) (in-pane ZIP behavior and verification boundaries), [research/finder-server-connections.md](research/finder-server-connections.md) | 中文 |
| you need the latest packaged-app visual checks | [research/computer-use-2026-09-12-inline-zip.md](research/computer-use-2026-09-12-inline-zip.md) — dated observations and scope; current verification status is maintained in [HANDOFF.md](HANDOFF.md). [Earlier record](research/computer-use-2026-09-12.md) includes the previous standalone ZIP window | 中文 |
| you want to know why Dolphin was not ported | [audit/PHASE-0-REPORT.md](audit/PHASE-0-REPORT.md) and the rest of [audit/](audit/) (2026-08, historical) | English |

Repo root: [../README.md](../README.md) (overview), [../AGENTS.md](../AGENTS.md) (rules for coding agents), [../CHANGELOG.md](../CHANGELOG.md).

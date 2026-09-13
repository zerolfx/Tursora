# Documentation index

Start with the behavior, architecture or workflow document for your task, then use the relevant research record for revision-specific verification and remaining gaps. Historical test results apply only to their recorded source and scope.

| Read this when… | Document | Language |
|---|---|---|
| you need the intended behaviour of a feature | [SPEC.md](SPEC.md) — v1 spec, each section marked "对标 Dolphin / Finder" | 中文 |
| you wonder why something is the way it is | [DECISIONS.md](DECISIONS.md) — decision log D0–D61 | 中文 |
| you are changing code | [ARCHITECTURE.md](ARCHITECTURE.md) — object graph, per-file map, data flows, notifications, persistence, threading | English |
| you are building, testing or releasing | [DEVELOPMENT.md](DEVELOPMENT.md) — toolchain, smoke test, conventions, AppKit pitfalls, release checklist | English |
| you are editing or previewing the bilingual product site | [site/README.md](../site/README.md) — English default, Chinese page, shared workflows/screenshots, Python static build and browser checks; [architecture](ARCHITECTURE.md#product-page) | English |
| you need a key binding or menu item | [SHORTCUTS.md](SHORTCUTS.md) — every shortcut, menu, gesture and drag rule | English |
| you are choosing what to do next | [ROADMAP.md](ROADMAP.md), then [gaps/GAP-vs-FINDER.md](gaps/GAP-vs-FINDER.md) and [gaps/GAP-vs-DOLPHIN.md](gaps/GAP-vs-DOLPHIN.md) with difficulty estimates | 中文 |
| you are changing file-operation tasks or their lifecycle | [research/file-operation-tasks.md](research/file-operation-tasks.md) — Dolphin routing evidence, transfer boundaries, adversarial review and verification | 中文 |
| you are checking the three feature PRs together | [research/pr-integration-2026-09-12.md](research/pr-integration-2026-09-12.md) — merge stages, cross-feature fixes and validation status | 中文 |
| you are checking the customization, folder-tree and distribution changes together | [research/customization-integration.md](research/customization-integration.md) — combined smoke, isolated packaged-app evidence and current verification stage | 中文 |
| you are changing split-pane paths, tab titles or tab context actions | [research/pane-paths-and-tab-actions.md](research/pane-paths-and-tab-actions.md) — pinned Dolphin semantics, target ownership, fresh-window detach and current verification; [SPEC.md §2–4](SPEC.md#2-地址栏对标-dolphin核心差异化) | 中文 |
| you are changing Get Info section defaults | [research/info-disclosures.md](research/info-disclosures.md) — local Finder evidence and explicit-choice migration | 中文 |
| you are changing Dock shortcuts | [research/dock-menu.md](research/dock-menu.md) — fixed destinations, explicit action targets and Finder label evidence | 中文 |
| you are preparing README or site screenshots | [images/README.md](images/README.md), [research/screenshot-transparency.md](research/screenshot-transparency.md) — deterministic alpha preparation and pixel verification | English / 中文 |
| you are preparing a versioned release, drag-install DMG or future Apple signing | [RELEASING.md](RELEASING.md), [../CHANGELOG.md](../CHANGELOG.md); older implementation entries are in [DEVELOPMENT_HISTORY.md](DEVELOPMENT_HISTORY.md) | English |
| you are checking the published 0.2.0 assets and verification scope | [research/release-0.2.0.md](research/release-0.2.0.md) — exact tag/build, downloaded bytes, signatures and production-feed boundaries | 中文 |
| you are checking the current 0.2.1 release | [research/release-0.2.1.md](research/release-0.2.1.md) — exact commit/build, public assets, signatures, app launch and production-feed check | 中文 |
| you are changing software updates, release signing or update settings | [research/app-updates.md](research/app-updates.md) — Sparkle driver, stored choices, release feed, key readiness and verification; [SPEC.md §20](SPEC.md#20-软件更新sparkle-原生更新流程) | 中文 |
| you are configuring or deploying GitHub Pages | [research/github-pages.md](research/github-pages.md) — public repository evidence, workflow, subpath checks and deployment status; [site/README.md](../site/README.md) | 中文 / English |
| you are changing text icon previews | [research/text-thumbnails.md](research/text-thumbnails.md) — readable excerpts, Finder / Dolphin evidence and stale request checks | 中文 |
| you are changing tab appearance or Light/Dark adaptation | [research/tabs-and-appearance.md](research/tabs-and-appearance.md) — Apple references, adaptive layers, overflow and verification | 中文 |
| you are changing the application icon or its export | [research/app-icon-edges.md](research/app-icon-edges.md) — original artwork, explicit alpha silhouette, legacy ICNS boundary and verification | 中文 |
| you are changing recursive / saved search | [research/search-input-reference.md](research/search-input-reference.md), [research/search.md](research/search.md), [research/search-verification.md](research/search-verification.md), [SPEC.md §19](SPEC.md#19-搜索dolphin-语义macos-后端); history: [research/dolphin-filter-search.md](research/dolphin-filter-search.md) | 中文 |
| you are matching Finder and need the evidence | [research/finder-group-labels.md](research/finder-group-labels.md), [research/finder-menu-icons.md](research/finder-menu-icons.md), [research/finder-actions-menu.md](research/finder-actions-menu.md) | 中文 |
| you are changing defaults, ZIP cancellation/recovery or terminal status | [research/default-features-polish.md](research/default-features-polish.md) — default migration, shared preparation cancellation, startup recovery and terminal state | 中文 |
| you are customizing application commands or input focus | [research/custom-shortcuts.md](research/custom-shortcuts.md), [SHORTCUTS.md](SHORTCUTS.md) — command catalog, validation, migration and native input protection | 中文 / English |
| you are changing terminal settings or comparing Rascal | [research/terminal-customization.md](research/terminal-customization.md) — real PTY, shell validation, live appearance and source comparison | 中文 |
| you are changing terminal hiding, job detection or quit/close/restart confirmation | [research/terminal-session-lifecycle.md](research/terminal-session-lifecycle.md) — retained per-window PTY, cancellation order, process ownership and verification | 中文 |
| you are changing batch rename, two-way terminal sync or the command palette | [research/finder-batch-rename.md](research/finder-batch-rename.md), [research/terminal-shell-sync.md](research/terminal-shell-sync.md), [research/command-palette.md](research/command-palette.md) — Finder 取证、推断部分、边界与验证阶段 | 中文 |
| you are changing sort keys, list columns or folder sizes | [research/sort-columns-folder-sizes.md](research/sort-columns-folder-sizes.md) — Finder nib/字符串取证、推断清单、后台计算与取消边界 | 中文 |
| you are changing drag and drop, spring-loaded folders or breadcrumb drops | [research/drag-and-drop.md](research/drag-and-drop.md) — AppKit 头文件与 Finder 取证、⌘ 掩码的推断边界、未实现的回滚 | 中文 |
| you are changing the Trash, Put Back or Empty Trash | [research/trash.md](research/trash.md) — Finder 取证、自建 put-back 日志、路径规范化、命令边界与验证 | 中文 |
| you are changing terminal directory following, the compact header or footer simplification | [research/terminal-navigation-0.2.1.md](research/terminal-navigation-0.2.1.md) — zsh integration, input preservation, removal of terminal footer/capacity and current verification | 中文 |
| you are evaluating a Ghostty backend | [research/ghostty-embedding.md](research/ghostty-embedding.md) — current official VT/internal APIs, licensing and a follow-up comparison plan | 中文 |
| you are changing the folder tree or Places/Folders layout | [research/folder-tree.md](research/folder-tree.md) — pinned Dolphin evidence, lazy model, active-pane ownership and saved options | 中文 |
| you are installing with an agent or choosing a writable app location | [../site/install.md](../site/install.md) — public installation guide, destination selection, release verification and per-app first launch | English |
| you are updating the Homebrew cask or checking signing requirements | [research/homebrew.md](research/homebrew.md), [../Casks/tursora.rb](../Casks/tursora.rb) — three-step tap / single-cask trust / install flow, verified release generation and isolated installation | 中文 / Ruby |
| you are auditing all README/site screenshot transparency | [research/screenshot-audit-2026-09-13.md](research/screenshot-audit-2026-09-13.md) — initial inventory, PNG build gate and recapture stage | 中文 |
| you are changing settings, shortcuts or terminal/ZIP behavior | [research/settings-and-shortcuts.md](research/settings-and-shortcuts.md), [research/dolphin-terminal.md](research/dolphin-terminal.md), [SPEC.md §16–18](SPEC.md#16-设置与自定义快捷键) | 中文 |
| you are changing per-directory view memory, defaults or storage identity | [research/directory-view-properties.md](research/directory-view-properties.md) — pinned Dolphin evidence and Tursora's application-owned path library; verification: [research/computer-use-2026-09-12-directory-views.md](research/computer-use-2026-09-12-directory-views.md); [SPEC.md §5](SPEC.md#5-视图模式缩放与预览对标-dolphin) | 中文 |
| you are changing startup, quit or workspace restoration | [research/workspace-sessions.md](research/workspace-sessions.md) — window/tab/pane snapshot scope, storage errors, settings and verification stages; [SPEC.md §22](SPEC.md#22-工作区会话恢复工作连续性) | 中文 |
| you are checking native archive and server behavior | [research/finder-archives.md](research/finder-archives.md), [research/archive-browsing.md](research/archive-browsing.md) (in-pane ZIP behavior and verification boundaries), [research/finder-server-connections.md](research/finder-server-connections.md) | 中文 |
| you need historical packaged-app ZIP visual checks | [research/computer-use-2026-09-12-inline-zip.md](research/computer-use-2026-09-12-inline-zip.md) — dated observations and scope. [Earlier record](research/computer-use-2026-09-12.md) includes the previous standalone ZIP window; later feature stages have their own research records above | 中文 |
| you want to know why Dolphin was not ported | [audit/PHASE-0-REPORT.md](audit/PHASE-0-REPORT.md) and the rest of [audit/](audit/) (2026-08, historical) | English |

Repo root: [../README.md](../README.md) (overview), [../AGENTS.md](../AGENTS.md) (rules for coding agents), [../CHANGELOG.md](../CHANGELOG.md).

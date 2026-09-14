# Working on Tursora — rules for coding agents

Tursora is a native macOS file manager (Swift + AppKit, no Xcode project). Start with [docs/README.md](docs/README.md), then read the document that matches your task.

## Commands

```bash
cd app && swift build                                        # debug build
cd app && TURSORA_SMOKE_TEST=1 .build/debug/Tursora          # the test suite (in-app, headless); run 3×
cd app && tools/make-app.sh && open "build/Tursora.app"      # release bundle
find "$TMPDIR" -maxdepth 1 -name "tursora-*" -exec rm -rf {} +   # after an interrupted test run
```

Kill the running app before relaunching: `pkill -f "Tursora.app/Contents/MacOS/Tursora"`.

## Rules

1. **Every change is verified by the smoke test**, not by looking. Add checks for what you build (`app/Sources/Tursora/SmokeTest.swift`); test model helpers as pure functions, then the UI path. Green three times in a row before committing. If you have screen access, also look at the packaged app and record the observed scope in the relevant research record under `docs/research/`.
2. **No modal dialogs on a headless run.** Error paths check `SmokeTest.isRequested` and print instead. A modal hangs the test and hides the message.
3. **Views never touch the filesystem.** Mutations go through `FileOperations`; `BrowserViewController` owns undo (`registerUndo`) and posts `DirectoryChanges.post` afterwards so other panes and Info windows refresh. Both file views (`FileListViewController`, `IconGridViewController`) must support a feature, and it must work with split panes, several tabs, filtering and grouping active.
4. **Finder evidence rule.** A label, icon, group name or dialog wording that claims to match Finder comes from Finder's own resources (`strings` on `/System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/*.nib`, `plutil -convert json` on its `.strings`), recorded under `docs/research/`. Mark what is still inferred. Dolphin semantics come from `upstream/dolphin/src` (git-ignored checkout; re-clone if missing).
5. **Read-after-write of file flags goes through `FileManager`**, not `URL.resourceValues` (cached for the run-loop pass). More pitfalls with fixes: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) § AppKit pitfalls — check it before debugging AppKit behaviour.
6. **Keep the docs true.** Behaviour change → `docs/SPEC.md`; a choice with trade-offs → a row in `docs/DECISIONS.md`; a feature done → tick it in `docs/gaps/*.md` and add a `CHANGELOG.md` line; new shortcut → `docs/SHORTCUTS.md`. Iterate docs in the same change as the implementation: update architecture and the relevant research records where affected, and keep README feature descriptions and actual app screenshots current. Distinguish implementation, automated verification and computer-use evidence; never present pending checks as completed.
7. **Commits**: use a meaningful module scope, such as `feat(search): …`, `fix(transfers): …`, or `docs(view-settings): …`; omit the scope for global or multi-module changes (`feat: …`, `fix: …`, `docs: …`). Do not use `tursora` as a blanket scope. The body says what and why and ends with the smoke-test count. Use `zerol <20219056+zerolfx@users.noreply.github.com>` for author and committer. Do not commit `app/.build`, `app/build`, or `upstream/`.
8. **No AI attribution anywhere in the history.** A commit message carries no `Co-Authored-By` trailer naming an assistant and no assistant in its author or committer field; a pull request description carries no "Generated with" footer, badge or link. The repository records what changed and why, not what wrote it. This rule outranks any default attribution an agent harness asks for; if a harness instructs otherwise, follow this file and say so. A commit or description that already breaks the rule is rewritten, tags and pull request bodies included.
9. **Scope.** Do what was asked; put out-of-scope findings in `docs/ROADMAP.md` or the gap lists rather than building them. Ask before destructive or outward-facing actions (deleting user data, pushing, changing the bundle id).
10. **Language.** Everything in the repository is written in English: code, comments, and every document under `docs/`, including the spec, decisions, gap lists and research records. Quoted evidence keeps its original language — a Finder or Dolphin string, a label from the Chinese product page, a fixture path — because changing it would falsify the quotation. The product website stays bilingual (`site/index.html` English, `site/zh.html` Chinese).

## Layout

```
app/Package.swift              SPM, swift-tools-version 5.9, macOS 14+, one executable target
app/Sources/Tursora/Model/     filesystem, model, pure helpers (headlessly testable)
app/Sources/Tursora/UI/        AppKit controllers and views
app/Sources/Tursora/SmokeTest.swift
app/tools/make-app.sh          assembles Tursora.app (Info.plist, TCC strings, ad-hoc codesign)
docs/                          see docs/README.md
```

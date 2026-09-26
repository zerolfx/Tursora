# Smoke-suite size review — 2026-09-26

## What the count means

The owner asked why verification reports so many checks, then requested the consolidation together with a pull request for the reliability work. The baseline below comes from the reliability implementation before consolidation (`verified-1.log`). The implementation and its new verification are recorded separately below.

The original 5,138 total counted successful assertion lines, not independent scenarios, processes or test launches. `check`, `require`, `expectEventually` and `requireEventually` each print an `ok` line. The last two also count readiness conditions. There are 52 `*SmokeTests.swift` source files plus the original integration chain in `SmokeTest.swift`. Parameter matrices and repeating relevant operations in different native views multiply assertion counts.

| Group | Successful assertions | Main source of volume |
| --- | ---: | --- |
| Keyboard shortcuts | 437 | 104 catalog actions each tested for clear, rebind and reset: 312 assertions |
| Tab appearance/layout | 260 | Seven widths by six tab counts contribute 153 geometry assertions; appearance and interaction checks are additional |
| Nine dedicated archive suites | 735 | Model, preparation, extraction, cancellation, per-entry state, real view callbacks and publication safety; 14.3% of the whole run |
| Five suites added by the reliability change | 188 | Preferences 8, failed directory loading 16, path completion 31, file mutations 116 and archive export 17; 3.7% of the whole run |

These rows are not disjoint: ArchiveExportSmokeTests belongs to both the archive and new-suite totals. Header-based counting alone was insufficient because DirectoryLoadingSmokeTests and PathCompletionSmokeTests printed prefixes without a section header. The final preference check also occurs after the legacy archive UI checks. Named suite boundaries and counters now identify these scopes explicitly.

## Implemented consolidation

1. **Separate status wording from width geometry.** [StatusBarSmokeTests.swift](../../app/Sources/Tursora/StatusBarSmokeTests.swift) keeps six wording cases and a separate five-width matrix, including both sides of the 359/360-point threshold. The layout uses bounds, not text. This removes 60 duplicated assertions and 25 layout passes.
2. **Group parameterized success reporting.** [ShortcutSmokeTests.swift](../../app/Sources/Tursora/ShortcutSmokeTests.swift) still executes clear, rebind and reset in that order for all 104 actions. [TabAppearanceSmokeTests.swift](../../app/Sources/Tursora/TabAppearanceSmokeTests.swift) retains all seven widths, six tab counts, guards and overflow conditions. `SmokeCheckGroup` replaces 465 success lines with nine summaries while counting all 465 assertions. Failures still stop immediately and report the action/stage or width/count. Explicit completion and a final unfinished-group assertion prevent a partial group from silently passing.
3. **Run the shared IME sequence once.** [SearchEntrySmokeTests.swift](../../app/Sources/Tursora/SearchEntrySmokeTests.swift) runs common toolbar composition behavior once. Each view retains its focus, result, filter and tab-ownership checks. This removes nine duplicate assertions, two searches and three explicit 0.65-second waits.
4. **Separate sort rules from rendered ordering.** [SortColumnSizesSmokeTests.swift](../../app/Sources/Tursora/SortColumnSizesSmokeTests.swift) tests six date/direction rules once, then changes the sort while each of the three views is active and reads actual outline text fields, collection-item labels and loaded browser cells. Twelve model-only checks become six model checks plus three native-view checks, with bounded layout waits and no model fallback.
5. **Remove obsolete archive checks and a duplicate fixture.** [LazyArchiveSmokeTests.swift](../../app/Sources/Tursora/LazyArchiveSmokeTests.swift) drops seven conditions already checked by readiness waits and three assertions against the literal-true `isLazilyMounted` getter. The repeated intact-folder promise fixture is removed from [ArchiveExportSmokeTests.swift](../../app/Sources/Tursora/ArchiveExportSmokeTests.swift); [ArchiveOpenSmokeTests.swift](../../app/Sources/Tursora/ArchiveOpenSmokeTests.swift) retains the real callback and deep-byte success coverage. One archive mount, extraction and destination copy are removed; failure, repeat-attempt and Share checks are unchanged.
6. **Measure scopes and wait for readiness.** `SmokeReport` counts assertions independently of result lines, prints named suite start/end records and reports the slowest five scopes. The original integration chain remains a named scope. Its thumbnail and two FSEvents checks now use bounded readiness conditions instead of fixed two-second/1.8-second delays. An unavailable Home navigation fixture fails explicitly instead of exiting successfully before the remainder of the suite.

## Verification

The integrated debug and release builds passed. Standalone probes compiled the actual reporting definitions and verified: two passing matrix inputs produce two assertions/one result line; a failing input exits 1 with its exact parameters; an unfinished matrix is rejected.

The final unchanged Swift source passed three consecutive full runs under the shared verification lock:

| Log | Assertions | Result lines | Named scopes | Duration | Exit |
| --- | ---: | ---: | ---: | ---: | ---: |
| `acceptance-1.log` | 5,056 | 4,600 | 53 | 221.4 s | 0 |
| `acceptance-2.log` | 5,056 | 4,600 | 53 | 219.6 s | 0 |
| `acceptance-3.log` | 5,056 | 4,600 | 53 | 220.1 s | 0 |

Each run completed all nine grouped matrices, preserved production preferences and left no new temporary fixtures. The runner independently reconciled suite totals, printed success lines and expanded group counts. A fingerprint of all 159 Swift source files remained unchanged through verification. Logs, probes, fingerprints and build output are under `/private/tmp/tursora-reliability-20260926-722c/simplified`.

Actual assertions decreased by 82: 83 redundant assertions were removed and one unfinished-group guard was added. Grouping retained every parameter case while suppressing another 456 success lines. Total success output decreased from 5,138 to 4,600 lines (10.5%). Mean elapsed time was 220.4 seconds versus the earlier 231.9-second baseline, about 5% lower in these local runs; this is an observation rather than a controlled performance guarantee. The remaining slow scopes were the legacy integration chain, search entry, workspace-session UI, archive opening and transfers.

The final release bundle was also inspected with isolated preferences and stores. Its native UI rejected an occupied rename, completed `Al` to `Alpha/` and navigated there with Tab/Return, retained six fixture entries across List, Icons and Columns, and displayed a Chinese ZIP path and text thumbnail correctly. It quit with exit 0; both rename fixture contents and production preferences were unchanged. See the [reliability record](reliability-2026-09-26.md) for the observed scope and automated-only cases.

## Retained coverage and timing limits

Keep three-view rename, failed-listing and selection checks, real outline/collection/browser drag callbacks, grouping/filtering interactions, and split/tab ownership tests. Repeated transfer completion/main-thread labels cover distinct success, cancellation and failure paths. A first failed archive export and a repeated attempt exercise different paths, so both remain necessary. The five UTF-8 boundary cases are cheap pure-function checks.

Suite timings now expose the remaining slow scopes. Explicit time windows that test timer behavior remain; further reductions should target measured setup and readiness costs. A fast developer subset remains a future option and does not replace the repository's three-consecutive-full-run requirement.

Fewer success lines are a readability improvement. Runtime comparisons must use the full measured runs, not the printed-line reduction.

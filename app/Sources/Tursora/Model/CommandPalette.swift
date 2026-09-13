import Foundation

/// Fuzzy subsequence matching for the command palette.
///
/// Pure and deterministic: no AppKit, window or filesystem state, so the smoke
/// suite can rank strings directly before any panel exists. A candidate matches
/// when every query character appears in order; the score rewards a prefix hit,
/// a word-boundary hit and consecutive runs, and charges a flat penalty for
/// each break in the run plus a small penalty for how late the first hit is.
enum FuzzyMatcher {

    struct Match: Equatable {
        /// Higher is better. Scores are only comparable within one query.
        let score: Int
        /// Character offsets in the candidate that the query matched, ascending.
        let matchedOffsets: [Int]
    }

    // Weights are chosen so a prefix hit always outranks the same run found
    // later: the prefix bonus exceeds the boundary bonus by more than the
    // largest leading penalty, so "New Folder" beats "Show New" for "new".
    private static let baseScore = 1
    private static let prefixBonus = 16
    private static let boundaryBonus = 8
    private static let consecutiveBonus = 6
    private static let gapPenalty = 3
    private static let maximumLeadingPenalty = 6
    private static let separators: Set<Character> = [" ", "-", "_", "/", ".", ":", ",", "'", "(", ")", "…", "→", "\u{2192}"]

    /// `nil` when `candidate` does not contain `query` as a subsequence.
    /// Whitespace in the query is ignored, so "new f" and "newf" behave alike;
    /// an empty query matches everything with score 0.
    static func match(_ query: String, in candidate: String) -> Match? {
        let needle = query.lowercased().filter { !$0.isWhitespace }.map { String($0) }
        guard !needle.isEmpty else { return Match(score: 0, matchedOffsets: []) }
        let haystack = Array(candidate)
        guard needle.count <= haystack.count else { return nil }
        let lowered = haystack.map { String($0).lowercased() }

        let impossible = Int.min / 4
        var scores = [[Int]](repeating: [Int](repeating: impossible, count: haystack.count), count: needle.count)
        var parents = [[Int]](repeating: [Int](repeating: -1, count: haystack.count), count: needle.count)

        func bonus(at index: Int) -> Int {
            if index == 0 { return baseScore + prefixBonus }
            let previous = haystack[index - 1]
            let boundary = separators.contains(previous)
                || (haystack[index].isUppercase && !previous.isUppercase)
                || (haystack[index].isNumber && !previous.isNumber)
            return baseScore + (boundary ? boundaryBonus : 0)
        }

        for column in 0..<haystack.count where lowered[column] == needle[0] {
            scores[0][column] = bonus(at: column) - min(column, maximumLeadingPenalty)
        }
        for row in 1..<needle.count {
            // Running best of the previous row keeps the sweep linear: the gap
            // penalty is flat, so only the best earlier predecessor matters.
            var bestEarlier = impossible
            var bestEarlierColumn = -1
            for column in 1..<haystack.count {
                if scores[row - 1][column - 1] > bestEarlier {
                    bestEarlier = scores[row - 1][column - 1]
                    bestEarlierColumn = column - 1
                }
                guard lowered[column] == needle[row] else { continue }
                let consecutive = scores[row - 1][column - 1]
                var best = impossible
                var parent = -1
                if bestEarlier > impossible {
                    best = bestEarlier - gapPenalty
                    parent = bestEarlierColumn
                }
                if consecutive > impossible, consecutive + consecutiveBonus > best {
                    best = consecutive + consecutiveBonus
                    parent = column - 1
                }
                guard best > impossible else { continue }
                scores[row][column] = best + bonus(at: column)
                parents[row][column] = parent
            }
        }

        var bestColumn = -1
        var bestScore = impossible
        for column in 0..<haystack.count where scores[needle.count - 1][column] > bestScore {
            bestScore = scores[needle.count - 1][column]
            bestColumn = column
        }
        guard bestColumn >= 0, bestScore > impossible else { return nil }
        var offsets = [Int]()
        var row = needle.count - 1
        var column = bestColumn
        while row >= 0, column >= 0 {
            offsets.append(column)
            let parent = parents[row][column]
            row -= 1
            column = parent
        }
        return Match(score: bestScore, matchedOffsets: offsets.reversed())
    }
}

/// One row of the command palette: an application command, a sidebar
/// favourite, or a folder from the active pane's back/forward history.
struct PaletteEntry: Equatable {
    enum Kind: Int, Comparable {
        case command, favourite, recent
        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The shortcut-catalog ID for a command, or "favourite:"/"recent:" plus a path.
    let id: String
    let title: String
    let category: String
    /// The command's current shortcut ("⇧⌘N"), empty when it has none.
    let shortcut: String
    /// The destination for a folder row; `nil` for commands.
    let url: URL?
    let kind: Kind
}

struct PaletteMatch: Equatable {
    let entry: PaletteEntry
    let score: Int
    let matchedOffsets: [Int]
}

/// Builds and ranks the palette's rows. Pure: callers pass the catalog, the
/// user's current bindings, the favourites and the history folders.
enum CommandPalette {
    /// The catalog ID of the palette's own menu command (View → Command Palette…).
    static let commandID = "menu.showCommandPalette"
    /// Matches `PlacesModel`'s first section title.
    static let favouriteCategory = "Favourites"
    /// Finder's own MenuBar.nib wording for its history list.
    static let recentCategory = "Recent Folders"

    static func favouriteID(for url: URL) -> String { "favourite:" + url.standardizedFileURL.path }
    static func recentID(for url: URL) -> String { "recent:" + url.standardizedFileURL.path }

    /// "Recent: ~/Pictures" — the home folder is abbreviated the way a path
    /// field shows it, so long home paths stay readable in the list.
    static func recentTitle(for url: URL) -> String {
        "Recent: " + (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    static func entries(actions: [ShortcutAction],
                        bindings: [String: AppPreferences.Shortcut],
                        favourites: [PlacesModel.Place],
                        recentFolders: [URL],
                        excluding excluded: Set<String> = [commandID]) -> [PaletteEntry] {
        var result: [PaletteEntry] = []
        var seen = Set<String>()
        for action in actions where !excluded.contains(action.id) {
            guard seen.insert(action.id).inserted else { continue }
            result.append(PaletteEntry(id: action.id, title: action.title, category: action.category,
                                       shortcut: bindings[action.id]?.displayString ?? "",
                                       url: nil, kind: .command))
        }
        for place in favourites {
            let id = favouriteID(for: place.url)
            guard !excluded.contains(id), seen.insert(id).inserted else { continue }
            result.append(PaletteEntry(id: id, title: "Go to \(place.name)", category: favouriteCategory,
                                       shortcut: "", url: place.url, kind: .favourite))
        }
        for url in recentFolders {
            let id = recentID(for: url)
            guard !excluded.contains(id), seen.insert(id).inserted else { continue }
            result.append(PaletteEntry(id: id, title: recentTitle(for: url), category: recentCategory,
                                       shortcut: "", url: url, kind: .recent))
        }
        return result
    }

    /// Ranked rows for `query`: score first, then category, then title, so the
    /// order never depends on how the entries happened to be built.
    static func filter(_ entries: [PaletteEntry], query: String) -> [PaletteMatch] {
        var matches: [PaletteMatch] = []
        matches.reserveCapacity(entries.count)
        for entry in entries {
            guard let match = FuzzyMatcher.match(query, in: entry.title) else { continue }
            matches.append(PaletteMatch(entry: entry, score: match.score, matchedOffsets: match.matchedOffsets))
        }
        return matches.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.entry.category != right.entry.category { return left.entry.category < right.entry.category }
            if left.entry.title != right.entry.title { return left.entry.title < right.entry.title }
            return left.entry.id < right.entry.id
        }
    }
}

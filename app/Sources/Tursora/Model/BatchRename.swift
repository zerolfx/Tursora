import Foundation

/// Finder's "Rename Finder Items" rules, as pure functions: given the items and
/// one mode, produce the new name for every item and say why a plan cannot be
/// applied. Nothing here touches the filesystem — the caller passes the sibling
/// names in and applies the plan through `FileOperations.renameBatch`.
///
/// Labels come from Finder's own BulkRenameWindow.nib and LocalizableMerged
/// strings; see docs/research/finder-batch-rename.md for the extraction.
enum BatchRename {

    /// Finder's "Where:" popup: the text (or the number) goes after or before
    /// the name. The extension is never part of "the name".
    enum Position: String, CaseIterable, Equatable {
        case afterName, beforeName
        /// Finder BulkRenameWindow.nib: "after name" / "before name".
        var title: String { self == .afterName ? "after name" : "before name" }
    }

    /// Finder's "Name Format:" popup.
    enum FormatKind: String, CaseIterable, Equatable {
        case nameAndIndex, nameAndCounter, nameAndDate
        /// Finder BulkRenameWindow.nib: "Name and Index" / "Name and Counter" / "Name and Date".
        var title: String {
            switch self {
            case .nameAndIndex: return "Name and Index"
            case .nameAndCounter: return "Name and Counter"
            case .nameAndDate: return "Name and Date"
            }
        }
    }

    /// Finder's mode popup (LocalizableMerged BR5 / BR3 / BR1), in that order.
    enum Mode: Equatable {
        case replace(find: String, replacement: String)
        case add(text: String, position: Position)
        case format(kind: FormatKind, custom: String, start: Int, position: Position)

        var title: String {
            switch self {
            case .replace: return "Replace Text"
            case .add: return "Add Text"
            case .format: return "Format"
            }
        }
        static let titles = ["Replace Text", "Add Text", "Format"]
    }

    /// One item in the batch. `directory` groups collisions: a search result
    /// batch renames items that live in different folders.
    struct Entry: Equatable {
        let directory: URL
        let name: String
        /// Used by "Name and Date"; injected so tests are deterministic.
        let date: Date

        init(url: URL, date: Date = Date()) {
            self.directory = url.deletingLastPathComponent().standardizedFileURL
            self.name = url.lastPathComponent
            self.date = date
        }

        init(directory: URL, name: String, date: Date = Date()) {
            self.directory = directory.standardizedFileURL
            self.name = name
            self.date = date
        }

        /// Key for per-directory grouping of siblings and duplicates.
        var directoryKey: String { directory.path }
    }

    /// Finder never renames the extension in Add Text / Format: the base name is
    /// everything before the last dot, and a leading dot belongs to the base
    /// (".profile" has no extension).
    static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."),
              dot != name.startIndex,
              dot != name.index(before: name.endIndex) else { return (name, "") }
        return (String(name[name.startIndex..<dot]), String(name[name.index(after: dot)...]))
    }

    static func joined(base: String, ext: String) -> String {
        ext.isEmpty ? base : base + "." + ext
    }

    /// Finder's date stamp for "Name and Date": "2026-09-13 at 14.02.03".
    /// Colons are illegal in a file name, so the time uses dots.
    static func dateStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    /// Left-pads a counter to `width` digits without ever truncating it.
    static func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }

    /// The new name for every entry, in order. Extensions survive every mode
    /// except Replace Text, which — like Finder — rewrites the whole name.
    static func plan(_ entries: [Entry], mode: Mode) -> [String] {
        var names = entries.enumerated().map { newName(for: $0.element, offset: $0.offset, mode: mode) }
        if case .format(.nameAndDate, _, _, _) = mode { disambiguate(&names, entries: entries) }
        return names
    }

    /// Convenience for pure tests: plan by name alone, all in one directory.
    static func plan(names: [String], mode: Mode, dates: [Date] = []) -> [String] {
        let root = URL(fileURLWithPath: "/")
        let entries = names.enumerated().map {
            Entry(directory: root, name: $0.element,
                  date: dates.indices.contains($0.offset) ? dates[$0.offset] : Date())
        }
        return plan(entries, mode: mode)
    }

    private static func newName(for entry: Entry, offset: Int, mode: Mode) -> String {
        switch mode {
        case .replace(let find, let replacement):
            guard !find.isEmpty else { return entry.name }
            return entry.name.replacingOccurrences(of: find, with: replacement)
        case .add(let text, let position):
            guard !text.isEmpty else { return entry.name }
            let (base, ext) = split(entry.name)
            return joined(base: position == .afterName ? base + text : text + base, ext: ext)
        case .format(let kind, let custom, let start, let position):
            let (_, ext) = split(entry.name)
            let token: String
            switch kind {
            case .nameAndIndex: token = String(start + offset)
            case .nameAndCounter: token = padded(start + offset, width: 5)
            case .nameAndDate: token = dateStamp(entry.date)
            }
            let base: String
            if custom.isEmpty { base = token }
            else { base = position == .afterName ? custom + " " + token : token + " " + custom }
            return joined(base: base, ext: ext)
        }
    }

    /// Two items stamped in the same second would otherwise get the same name.
    /// Inferred behaviour (Finder's own tie-breaking is not documented): the
    /// later item gets " 2", " 3", … appended to its base name.
    private static func disambiguate(_ names: inout [String], entries: [Entry]) {
        var used: [String: Set<String>] = [:]
        for index in names.indices {
            let key = entries[index].directoryKey
            let (base, ext) = split(names[index])
            var candidate = names[index]
            var suffix = 2
            while used[key, default: []].contains(candidate.lowercased()) {
                candidate = joined(base: "\(base) \(suffix)", ext: ext)
                suffix += 1
            }
            used[key, default: []].insert(candidate.lowercased())
            names[index] = candidate
        }
    }

    // MARK: - Validation

    /// Why a plan cannot be applied. The wording is Finder's: RN31 for a name
    /// the system refuses, RN17 for a name already in use.
    struct Problem: Equatable {
        enum Kind { case empty, invalid, taken }
        let kind: Kind
        /// Index of the offending item in the batch.
        let index: Int
        let name: String

        var message: String {
            switch kind {
            case .empty: return "The name can’t be empty."
            case .invalid: return "The name “\(name)” can’t be used."
            case .taken: return "The name “\(name)” is already taken. Please choose a different name."
            }
        }
    }

    /// A file name may contain neither "/" (the path separator) nor ":" (the
    /// legacy separator Finder still refuses).
    static let invalidCharacters = CharacterSet(charactersIn: "/:")

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && name.rangeOfCharacter(from: invalidCharacters) == nil
    }

    /// The first reason the plan cannot be applied, or nil.
    ///
    /// `siblings` maps a directory path to the names that directory already
    /// holds (hidden ones included). Names the batch itself frees do not count
    /// as collisions, so a chain (a→b while b→c), a swap and a case-only rename
    /// are all allowed. Comparison folds case unless the volume is case
    /// sensitive.
    static func validate(_ newNames: [String], for entries: [Entry],
                         siblings: [String: Set<String>] = [:],
                         caseSensitive: Bool = false) -> Problem? {
        guard newNames.count == entries.count else { return nil }
        func fold(_ value: String) -> String { caseSensitive ? value : value.lowercased() }

        var leaving: [String: Set<String>] = [:]
        for entry in entries { leaving[entry.directoryKey, default: []].insert(fold(entry.name)) }
        var occupied: [String: Set<String>] = [:]
        for (key, names) in siblings {
            occupied[key] = Set(names.map(fold)).subtracting(leaving[key] ?? [])
        }

        for (index, name) in newNames.enumerated() {
            let entry = entries[index]
            let key = entry.directoryKey
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                return Problem(kind: .empty, index: index, name: name)
            }
            guard isValidName(name) else { return Problem(kind: .invalid, index: index, name: name) }
            if occupied[key, default: []].contains(fold(name)) {
                return Problem(kind: .taken, index: index, name: name)
            }
            occupied[key, default: []].insert(fold(name))
        }
        return nil
    }

    /// Finder's File-menu wording for a multi-selection (LocalizableMerged
    /// ME22_V3 "Rename ^0 Items…"); one item keeps the plain "Rename".
    static func menuTitle(count: Int) -> String {
        count > 1 ? "Rename \(count) Items…" : "Rename"
    }

    /// Finder's window label (BulkRenameWindow.nib).
    static let sheetTitle = "Rename Finder Items:"
}

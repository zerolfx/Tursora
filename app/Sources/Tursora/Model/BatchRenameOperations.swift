import Foundation

/// Applying a batch rename. Kept apart from the single-item rename because a
/// batch can contain chains (a→b while b→c) and swaps: every item first moves
/// to a unique temporary name, so no intermediate state can collide, and a
/// failure rolls the whole batch back.
extension FileOperations {

    /// One requested rename. `newName` is a file name, never a path.
    struct RenameRequest: Equatable {
        let url: URL
        let newName: String
        init(url: URL, newName: String) { self.url = url; self.newName = newName }
    }

    /// The names a directory already holds, hidden files included. Returns an
    /// empty set for an unreadable directory — the rename itself still reports
    /// the real error.
    static func siblingNames(in directory: URL) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return Set(names)
    }

    /// Sibling names for every directory the entries live in.
    static func siblingNames(forEntries entries: [BatchRename.Entry]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for entry in entries where result[entry.directoryKey] == nil {
            result[entry.directoryKey] = siblingNames(in: entry.directory)
        }
        return result
    }

    /// Renames every request in one pass-through-temporaries, so chains and
    /// swaps inside the batch never collide. Items whose name does not change
    /// are skipped. Returns the (from, to) pairs actually renamed, in request
    /// order — what undo replays.
    ///
    /// Throws before touching anything if a name is unusable, and rolls back
    /// every completed move if one fails (a final name occupied by an item
    /// outside the batch, a permission error, …).
    @discardableResult
    static func renameBatch(_ requests: [RenameRequest]) throws -> [(from: URL, to: URL)] {
        for request in requests where !BatchRename.isValidName(request.newName) {
            throw CocoaError(.fileWriteInvalidFileName,
                             userInfo: [NSFilePathErrorKey: request.url.deletingLastPathComponent()
                                            .appendingPathComponent(request.newName, isDirectory: false).path])
        }
        let work = requests.filter { $0.url.lastPathComponent != $0.newName }
        guard !work.isEmpty else { return [] }

        let manager = FileManager.default
        // (source, temporary, final) for each item, plus what has been done so
        // far so a failure can be undone in reverse.
        var staged: [(original: URL, temporary: URL, final: URL)] = []
        var completed: [(from: URL, to: URL)] = []

        func rollBack() {
            for move in completed.reversed() { try? manager.moveItem(at: move.to, to: move.from) }
        }

        do {
            for request in work {
                let directory = request.url.deletingLastPathComponent()
                let temporary = directory.appendingPathComponent(".tursora-rename-" + UUID().uuidString)
                try manager.moveItem(at: request.url, to: temporary)
                completed.append((from: request.url, to: temporary))
                staged.append((original: request.url, temporary: temporary,
                               final: directory.appendingPathComponent(request.newName)))
            }
            var pairs: [(from: URL, to: URL)] = []
            for item in staged {
                // moveItem refuses to overwrite, which is what we want for a
                // sibling outside the batch; the name is free for every item
                // inside it, so a case-only rename also lands here.
                try manager.moveItem(at: item.temporary, to: item.final)
                completed.append((from: item.temporary, to: item.final))
                pairs.append((from: item.original, to: item.final))
            }
            return pairs
        } catch {
            rollBack()
            throw error
        }
    }

    /// Undo/redo replay: rename back, in reverse order, through the same
    /// two-pass scheme.
    static func reverseRenameBatch(_ pairs: [(from: URL, to: URL)]) throws -> [(from: URL, to: URL)] {
        try renameBatch(pairs.reversed().map { RenameRequest(url: $0.to, newName: $0.from.lastPathComponent) })
    }
}

extension DirectoryChanges {
    /// A batch carries one rename mapping per item, so every pane and Info
    /// window can follow its own item to its new name.
    static func postRenames(_ pairs: [(from: URL, to: URL)]) {
        guard !pairs.isEmpty else { return }
        let directories = affected(sources: pairs.map(\.from) + pairs.map(\.to))
        for pair in pairs { post(directories, renamed: pair) }
    }
}

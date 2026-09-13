import Foundation

/// Tursora's own put-back journal.
///
/// macOS keeps Finder's put-back paths in a private `.DS_Store` record that is
/// not a documented format, so this type records the (original, trashed) pairs
/// `FileOperations.trash` returns and answers "where did this come from?" from
/// its own file. Items trashed by Finder, the shell or another app therefore
/// have no origin here, and their Put Back is disabled with a reason rather
/// than guessed at — nothing parses `.DS_Store`.
///
/// The file is JSON in Application Support/Tursora, written atomically on a
/// serial queue. `fileURL` is injectable so checks never touch the real one.
final class TrashOrigins {

    struct Entry: Codable, Equatable {
        var trashedPath: String
        var originalPath: String
        var date: Date
    }

    /// Why Put Back is or is not available for one trashed item.
    enum PutBack: Equatable {
        /// The original parent is there and the name is free.
        case available(URL)
        /// Trashed outside Tursora (or the entry was pruned).
        case unknownOrigin
        /// The folder it came from no longer exists.
        case missingParent(URL)
        /// Something else already occupies the original path.
        case nameTaken(URL)

        var isAvailable: Bool { if case .available = self { return true }; return false }
        var destination: URL? { if case .available(let url) = self { return url }; return nil }

        /// Shown as the disabled row's tooltip. Wording is Tursora's own.
        var reason: String? {
            switch self {
            case .available: return nil
            case .unknownOrigin:
                return "Tursora doesn’t know where this item came from. Only items Tursora moved to the Trash can be put back."
            case .missingParent(let parent):
                return "The folder “\(parent.lastPathComponent)” it came from no longer exists."
            case .nameTaken(let url):
                return "An item named “\(url.lastPathComponent)” is already in the folder it came from."
            }
        }
    }

    /// Decides Put Back from facts alone, so the rule is testable without a
    /// filesystem. `origin` nil means no journal entry.
    static func putBack(origin: URL?, parentExists: Bool, destinationOccupied: Bool) -> PutBack {
        guard let origin else { return .unknownOrigin }
        let parent = origin.deletingLastPathComponent()
        if !parentExists { return .missingParent(parent) }
        if destinationOccupied { return .nameTaken(origin) }
        return .available(origin)
    }

    // MARK: - Storage

    private struct Document: Codable {
        var version = 1
        var entries: [Entry] = []
    }

    /// Old entries are dropped once the journal grows past this; put-back is a
    /// short-lived affordance and the file must not grow without bound.
    static let entryLimit = 5000

    static let didChange = Notification.Name("Tursora.trashOriginsChanged")

    static let shared: TrashOrigins = {
        let manager = FileManager.default
        if SmokeTest.isRequested {
            let root = manager.temporaryDirectory.appendingPathComponent(
                "tursora-trash-origins-smoke-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true)
            return TrashOrigins(fileURL: root.appendingPathComponent("TrashOrigins.json"))
        }
        if let path = ProcessInfo.processInfo.environment["TURSORA_UI_TEST_TRASH_ORIGINS_FILE"],
           path.hasPrefix("/"), !path.contains("\0") {
            return TrashOrigins(fileURL: URL(fileURLWithPath: path))
        }
        let root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tursora", isDirectory: true)
        return TrashOrigins(fileURL: root.appendingPathComponent("TrashOrigins.json"))
    }()

    let fileURL: URL
    private let queue = DispatchQueue(label: "com.tursora.trash-origins", qos: .utility)
    private var storedEntries: [String: Entry] = [:]
    private var writeError: Error?

    init(fileURL: URL) {
        self.fileURL = fileURL
        // A read is never a mutation: an unreadable or future-format file is
        // left alone until an actual trash operation rewrites it.
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1 else { return }
        for entry in document.entries { storedEntries[entry.trashedPath] = entry }
    }

    var lastWriteError: Error? { queue.sync { writeError } }

    /// Every entry, newest first.
    var entries: [Entry] { queue.sync { storedEntries.values.sorted { $0.date > $1.date } } }
    var count: Int { queue.sync { storedEntries.count } }

    // MARK: - Recording

    /// Records what `FileOperations.trash` returned. Re-trashing to the same
    /// path replaces the older entry.
    func record(_ pairs: [(original: URL, trashed: URL)], date: Date = Date()) {
        guard !pairs.isEmpty else { return }
        mutate { entries in
            for pair in pairs {
                let key = TrashLocation.canonicalPath(pair.trashed)
                entries[key] = Entry(trashedPath: key,
                                     originalPath: TrashLocation.canonicalPath(pair.original),
                                     date: date)
            }
            if entries.count > Self.entryLimit {
                let keep = entries.values.sorted { $0.date > $1.date }.prefix(Self.entryLimit)
                entries = Dictionary(keep.map { ($0.trashedPath, $0) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    /// Where a trashed item came from, or nil when Tursora never trashed it.
    func origin(ofTrashed url: URL) -> URL? {
        let key = TrashLocation.canonicalPath(url)
        guard let entry = queue.sync(execute: { storedEntries[key] }) else { return nil }
        return URL(fileURLWithPath: entry.originalPath)
    }

    /// Drops the entries for items that were restored or erased.
    func forget(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let keys = urls.map(TrashLocation.canonicalPath)
        mutate { entries in for key in keys { entries.removeValue(forKey: key) } }
    }

    /// Drops every entry below `root` (Empty Trash).
    func forgetAll(under root: URL) {
        let prefix = TrashLocation.canonicalPath(root) + "/"
        mutate { entries in
            entries = entries.filter { !$0.key.hasPrefix(prefix) && $0.key != String(prefix.dropLast()) }
        }
    }

    /// Drops entries below `root` whose trashed item is gone — emptied from
    /// Finder, restored by a drag, or erased by another tool. Returns how many
    /// entries went, so a caller can skip the notification when nothing moved.
    @discardableResult
    func pruneMissing(under root: URL, exists: (URL) -> Bool = { FileOperations.itemExists($0) }) -> Int {
        let prefix = TrashLocation.canonicalPath(root) + "/"
        let candidates = queue.sync { storedEntries.keys.filter { $0.hasPrefix(prefix) } }
        let gone = candidates.filter { !exists(URL(fileURLWithPath: $0)) }
        guard !gone.isEmpty else { return 0 }
        mutate { entries in for key in gone { entries.removeValue(forKey: key) } }
        return gone.count
    }

    /// The Put Back verdict for one trashed item, read through FileManager
    /// (never cached `URL.resourceValues`).
    func putBack(for trashed: URL) -> PutBack {
        guard let origin = origin(ofTrashed: trashed) else { return .unknownOrigin }
        let parent = origin.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        return Self.putBack(origin: origin, parentExists: parentExists,
                            destinationOccupied: FileOperations.itemExists(origin))
    }

    // MARK: - Private

    private func mutate(_ body: (inout [String: Entry]) -> Void) {
        queue.sync {
            body(&storedEntries)
            write()
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Called on `queue`.
    private func write() {
        do {
            let document = Document(entries: storedEntries.values.sorted { $0.trashedPath < $1.trashedPath })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            writeError = nil
        } catch {
            writeError = error
        }
    }
}

import Foundation
import UniformTypeIdentifiers

enum SearchScope: String, Codable, CaseIterable {
    case currentFolder, home
}

enum SearchKind: String, Codable, CaseIterable {
    case any, folder, document, image, audio, video, pdf

    var title: String {
        switch self {
        case .any: return "Any Type"
        case .folder: return "Folders"
        case .document: return "Documents"
        case .image: return "Images"
        case .audio: return "Audio"
        case .video: return "Video"
        case .pdf: return "PDF"
        }
    }

    var contentTypes: [UTType] {
        switch self {
        case .any: return []
        case .folder: return [.folder]
        case .document: return [.text, .pdf, .compositeContent, .spreadsheet, .presentation]
        case .image: return [.image]
        case .audio: return [.audio]
        case .video: return [.movie]
        case .pdf: return [.pdf]
        }
    }

    func matches(_ item: FileItem) -> Bool {
        if self == .any { return true }
        if self == .folder { return item.isNavigable }
        guard !item.isNavigable, let type = item.contentType else { return false }
        return contentTypes.contains { type.conforms(to: $0) }
    }
}

/// Where a content search looks. Spotlight is fast but only sees what it has
/// indexed, and it cannot tell "this folder is not indexed" from "nothing
/// matched" — both come back as zero results. Scanning reads the files itself,
/// so it works on an external drive, a network volume or a folder excluded from
/// indexing, at the cost of doing the reading. Dolphin exposes the same choice
/// as "Search using: File Indexing / Simple search" (D85).
enum ContentSource: String, Codable, CaseIterable {
    case index, disk

    var title: String {
        switch self {
        case .index: return "Spotlight Index"
        case .disk: return "Scan Files"
        }
    }
}

/// Conditions, never results, are persisted. A saved Home search follows the
/// current user's home; a saved folder search keeps its original absolute URL.
struct SearchRequest: Codable, Equatable {
    var rootURL: URL
    var scope: SearchScope = .currentFolder
    var name: String = ""
    var content: String = ""
    /// Only consulted when `content` is non-empty.
    var contentSource: ContentSource = .index
    var kind: SearchKind = .any
    /// Inclusive lower bound and exclusive upper bound.
    var modifiedAfter: Date?
    var modifiedBefore: Date?

    var effectiveRootURL: URL {
        (scope == .home ? FileManager.default.homeDirectoryForCurrentUser : rootURL).standardizedFileURL
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedContent: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }
    var usesSpotlight: Bool { !trimmedContent.isEmpty && contentSource == .index }
    /// A content search that reads the files rather than asking the index.
    var scansContent: Bool { !trimmedContent.isEmpty && contentSource == .disk }

    static let contentLimitMessage = "Content uses Spotlight: only indexed, supported files. Missing results may be unindexed or excluded."
    static let scanLimitMessage = "Scanning reads text files directly, so unindexed folders are searched; binary files and anything past \(ContentScanner.maximumBytes / 1024) KB per file are not."

    /// Synthesized decoding does NOT fall back to a property's default when the
    /// key is absent — it throws — and `SavedSearchStore` decodes the whole
    /// array with `try?`, so one new field would have silently emptied every
    /// saved search a user had. Decode each key on its own instead.
    private enum CodingKeys: String, CodingKey {
        case rootURL, scope, name, content, contentSource, kind, modifiedAfter, modifiedBefore
    }

    init(rootURL: URL, scope: SearchScope = .currentFolder, name: String = "", content: String = "",
         contentSource: ContentSource = .index, kind: SearchKind = .any,
         modifiedAfter: Date? = nil, modifiedBefore: Date? = nil) {
        self.rootURL = rootURL
        self.scope = scope
        self.name = name
        self.content = content
        self.contentSource = contentSource
        self.kind = kind
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rootURL = try values.decode(URL.self, forKey: .rootURL)
        scope = (try? values.decode(SearchScope.self, forKey: .scope)) ?? .currentFolder
        name = (try? values.decode(String.self, forKey: .name)) ?? ""
        content = (try? values.decode(String.self, forKey: .content)) ?? ""
        contentSource = (try? values.decode(ContentSource.self, forKey: .contentSource)) ?? .index
        kind = (try? values.decode(SearchKind.self, forKey: .kind)) ?? .any
        modifiedAfter = try? values.decode(Date.self, forKey: .modifiedAfter)
        modifiedBefore = try? values.decode(Date.self, forKey: .modifiedBefore)
    }

    var validationError: String? {
        guard rootURL.isFileURL else { return "Choose a local or mounted folder to search." }
        if let modifiedAfter, let modifiedBefore, modifiedAfter >= modifiedBefore {
            return "The end date must be later than the start date."
        }
        return nil
    }

    /// Pure matching for disk metadata and deterministic injected backends.
    func matchesMetadata(_ item: FileItem) -> Bool {
        guard Self.contains(item.name, text: trimmedName), kind.matches(item) else { return false }
        if let modifiedAfter {
            guard let date = item.modificationDate, date >= modifiedAfter else { return false }
        }
        if let modifiedBefore {
            guard let date = item.modificationDate, date < modifiedBefore else { return false }
        }
        return true
    }

    func matches(_ item: FileItem, contentText: String?) -> Bool {
        guard matchesMetadata(item) else { return false }
        return trimmedContent.isEmpty || contentText.map { Self.contains($0, text: trimmedContent) } == true
    }

    private static func contains(_ value: String, text: String) -> Bool {
        text.isEmpty || value.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Bind user strings as predicate values; no text is interpreted as query
    /// syntax. Disk metadata is checked again after Spotlight returns a URL.
    var metadataPredicate: NSPredicate {
        var conditions: [NSPredicate] = []
        if !trimmedName.isEmpty {
            conditions.append(NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemFSName", trimmedName))
        }
        if !trimmedContent.isEmpty {
            conditions.append(NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", trimmedContent))
        }
        if kind != .any {
            let types = kind.contentTypes.map {
                NSPredicate(format: "%K == %@", "kMDItemContentTypeTree", $0.identifier)
            }
            // Spotlight rejects a compound predicate with only one child,
            // even though Foundation's ordinary evaluator accepts it.
            if types.count == 1 { conditions.append(types[0]) }
            else if !types.isEmpty { conditions.append(NSCompoundPredicate(orPredicateWithSubpredicates: types)) }
        }
        if let modifiedAfter {
            conditions.append(NSPredicate(format: "%K >= %@", "kMDItemFSContentChangeDate", modifiedAfter as NSDate))
        }
        if let modifiedBefore {
            conditions.append(NSPredicate(format: "%K < %@", "kMDItemFSContentChangeDate", modifiedBefore as NSDate))
        }
        // NSMetadataQuery also rejects TRUEPREDICATE. Use a supported match-all
        // filename comparison when constructing an unrestricted native query.
        if conditions.isEmpty { return NSPredicate(format: "%K LIKE %@", "kMDItemFSName", "*") }
        if conditions.count == 1 { return conditions[0] }
        return NSCompoundPredicate(andPredicateWithSubpredicates: conditions)
    }
}

struct SavedSearch: Codable, Equatable {
    let id: UUID
    var name: String
    var request: SearchRequest
}

/// The shared defaults are read on access so independent panes never keep a
/// stale list of saved conditions. Deleting a condition does no filesystem I/O.
final class SavedSearchStore {
    static let shared = SavedSearchStore()
    static let didChange = Notification.Name("tursoraSavedSearchesChanged")
    private let defaults: UserDefaults
    private let key = "savedSearches.v1"

    init(defaults: UserDefaults = AppDefaults.shared) { self.defaults = defaults }

    var items: [SavedSearch] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return [] }
        return items
    }

    @discardableResult
    func save(name: String, request: SearchRequest) -> SavedSearch {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedSearch(id: UUID(), name: title.isEmpty ? "Saved Search" : title, request: request)
        write(items + [saved])
        return saved
    }

    func delete(id: UUID) { write(items.filter { $0.id != id }) }

    private func write(_ items: [SavedSearch]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

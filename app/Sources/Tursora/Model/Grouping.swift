import AppKit
import UniformTypeIdentifiers

/// Finder's View ▸ Group By keys, in Finder's menu order.
enum GroupKey: String, CaseIterable {
    case none, name, kind, application, dateLastOpened, dateAdded, dateModified, dateCreated, size, tags

    var title: String {
        switch self {
        case .none: return "None"
        case .name: return "Name"
        case .kind: return "Kind"
        case .application: return "Application"
        case .dateLastOpened: return "Date Last Opened"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .size: return "Size"
        case .tags: return "Tags"
        }
    }
}

/// One section of a grouped listing. A class so NSOutlineView can use it as
/// a (non-selectable, always expanded) group row.
final class GroupNode {
    let title: String
    fileprivate(set) var nodes: [FileNode]
    /// Sort position of the group among its siblings (lower first).
    fileprivate let order: Int
    init(title: String, order: Int, nodes: [FileNode] = []) {
        self.title = title; self.order = order; self.nodes = nodes
    }
}

/// Finder's grouping rules, as pure functions over already-sorted nodes so
/// the order inside each group is the user's sort order.
enum Grouping {

    static func split(_ nodes: [FileNode], by key: GroupKey, now: Date = Date()) -> [GroupNode] {
        guard key != .none else { return [GroupNode(title: "", order: 0, nodes: nodes)] }
        var groups: [String: GroupNode] = [:]
        var ordered: [GroupNode] = []
        for n in nodes {
            let (title, order) = bucket(n.item, key: key, now: now)
            if let g = groups[title] {
                g.nodes.append(n)
            } else {
                let g = GroupNode(title: title, order: order)
                g.nodes.append(n)
                groups[title] = g
                ordered.append(g)
            }
        }
        return ordered.sorted { a, b in
            a.order != b.order ? a.order < b.order : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// The group an item belongs to and where that group sorts.
    static func bucket(_ item: FileItem, key: GroupKey, now: Date = Date()) -> (title: String, order: Int) {
        switch key {
        case .none: return ("", 0)
        case .name: return nameBucket(item.name)
        case .kind: return kindBucket(item)
        case .application: return applicationBucket(item)
        case .dateModified: return dateBucket(item.modificationDate, now: now)
        case .dateCreated: return dateBucket(item.creationDate, now: now)
        case .dateAdded: return dateBucket(item.addedDate, now: now)
        case .dateLastOpened: return dateBucket(item.accessDate, now: now)
        case .size: return sizeBucket(item)
        case .tags: return tagBucket(item)
        }
    }

    // MARK: Name — first letter; digits and symbols under "#", last

    static func nameBucket(_ name: String) -> (title: String, order: Int) {
        guard let first = name.unicodeScalars.first else { return ("#", 1) }
        let s = String(first).uppercased()
        return CharacterSet.letters.contains(first) ? (s, 0) : ("#", 1)
    }

    // MARK: Kind — Finder's categories (its own GROUP_* strings), sorted by name

    static func kindBucket(_ item: FileItem) -> (title: String, order: Int) {
        if item.isNavigable { return ("Folders", 0) }              // GROUP_DIRECTORIES
        guard let t = item.contentType else { return ("Other", 0) }
        let category: String
        if t.conforms(to: .application) { category = "Applications" }                 // GROUP_APPLICATIONS
        else if t.conforms(to: .pdf) { category = "PDF Documents" }                   // GROUP_PDF
        else if t.conforms(to: .image) { category = "Images" }                        // GROUP_IMAGES
        else if t.conforms(to: .movie) || t.conforms(to: .video) { category = "Movies" }  // GROUP_MOVIES
        else if t.conforms(to: .audio) { category = "Music" }                         // GROUP_MUSIC
        else if t.conforms(to: .presentation) { category = "Presentations" }          // GROUP_PRESENTATIONS
        else if t.conforms(to: .spreadsheet) { category = "Spreadsheets" }            // GROUP_SPREADSHEETS
        else if t.conforms(to: .html) { category = "HTML" }                           // GROUP_HTML
        else if t.conforms(to: .appleScript) || t.conforms(to: .osaScript) { category = "AppleScript" }   // GROUP_APPLESCRIPT
        else if t.conforms(to: .font) { category = "Fonts" }                          // GROUP_FONTS
        else if t.conforms(to: .vCard) { category = "Contacts" }                      // GROUP_CONTACT
        else if t.conforms(to: .emailMessage) { category = "Mail Messages" }          // GROUP_EMAIL
        else if t.conforms(to: .internetLocation) || t.conforms(to: .urlBookmarkData) { category = "Webpages" }  // GROUP_BOOKMARKS
        else if t.conforms(to: .sourceCode) || t.conforms(to: .script) || t.conforms(to: .shellScript)
                    || t.conforms(to: .json) || t.conforms(to: .propertyList) || t.conforms(to: .xml) { category = "Source code" }  // GROUP_SOURCE
        else if t.conforms(to: .plainText) { category = "Text" }                      // GROUP_TEXT
        else if t.conforms(to: .rtf) || t.conforms(to: .rtfd) || t.conforms(to: .flatRTFD)
                    || t.identifier.contains("word") || t.identifier.contains("pages") || t.identifier.contains("opendocument.text") { category = "Documents" }  // GROUP_DOCUMENTS
        else if t.conforms(to: .content) { category = "Other Documents" }   // GROUP_OTHER_DOCUMENTS: document-like content we could not classify
        // Plain data — archives, disk images, unknown binaries — is "Other" (Finder has no Archives group).
        else { category = "Other" }                                                   // GROUP_OTHER
        return (category, 0)      // Finder orders kind groups by name; Folders is not pinned
    }

    // MARK: Application — the app that would open it; folders belong to Finder

    static func applicationBucket(_ item: FileItem) -> (title: String, order: Int) {
        if item.isNavigable { return ("Finder", 0) }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: item.url) else { return ("No Application", 2) }
        return (FileManager.default.displayName(atPath: app.path), 1)
    }

    // MARK: Dates — Today / Yesterday / Previous 7 Days / Previous 30 Days / month / year, newest first

    static func dateBucket(_ date: Date?, now: Date = Date()) -> (title: String, order: Int) {
        guard let date else { return ("No Date", 100_000) }
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        // Finder's GROUP_FUTURE string is "No Date": a timestamp from the future is not trusted.
        if date >= cal.date(byAdding: .day, value: 1, to: startOfToday)! { return ("No Date", 100_000) }
        if date >= startOfToday { return ("Today", 0) }
        if date >= cal.date(byAdding: .day, value: -1, to: startOfToday)! { return ("Yesterday", 1) }
        if date >= cal.date(byAdding: .day, value: -7, to: startOfToday)! { return ("Previous 7 Days", 2) }
        if date >= cal.date(byAdding: .day, value: -30, to: startOfToday)! { return ("Previous 30 Days", 3) }
        let y = cal.component(.year, from: date), m = cal.component(.month, from: date)
        let thisYear = cal.component(.year, from: now)
        if y == thisYear {
            // Months of this year, most recent first: order 10 + (12 - month)
            return (cal.monthSymbols[m - 1], 10 + (12 - m))
        }
        // Earlier years, most recent first.
        return (String(y), 1000 + (thisYear - y))
    }

    // MARK: Size — Folders first, then decades of bytes, largest first
    // Labels follow Finder's own strings: "Under ^0" (GV10) and "From ^0 to ^1" (GV11).

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file            // Finder's 1000-based KB/MB/GB
        f.allowsNonnumericFormatting = false
        f.zeroPadsFractionDigits = false
        return f
    }()

    static func sizeBucket(_ item: FileItem) -> (title: String, order: Int) {
        if item.isNavigable { return ("Folders", 0) }
        var lower: Int64 = 1_000                     // the first decade is "Under 1 KB"
        if item.size < lower { return ("Under \(sizeFormatter.string(fromByteCount: lower))", 100) }
        var decade = 1
        while item.size >= lower * 10 { lower *= 10; decade += 1 }
        let upper = lower * 10
        return ("From \(sizeFormatter.string(fromByteCount: lower)) to \(sizeFormatter.string(fromByteCount: upper))", 100 - decade)
    }

    // MARK: Tags — first tag alphabetically; untagged last

    static func tagBucket(_ item: FileItem) -> (title: String, order: Int) {
        guard let tag = item.tags.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).first else {
            return ("No Tags", 1)
        }
        return (tag, 0)
    }
}

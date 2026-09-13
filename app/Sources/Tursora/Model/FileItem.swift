import AppKit
import UniformTypeIdentifiers

/// One entry in a directory listing. Resource values are read once, at load
/// time, so sorting and drawing never touch the filesystem.
struct FileItem {
    let url: URL
    /// Physical snapshot used only for reads; navigation always keeps `url`.
    let contentURL: URL
    let canAccess: Bool
    private let archiveSession: ArchiveBrowsingSession?
    var isArchiveEntry: Bool { archiveSession != nil }
    let name: String
    let isDirectory: Bool
    /// .app / .rtfd and friends: directories on disk, but the user thinks of
    /// them as files. Finder treats them as files; so do we.
    let isPackage: Bool
    let isHidden: Bool
    let isSymlink: Bool
    let size: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let accessDate: Date?
    let addedDate: Date?
    let contentType: UTType?

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey,
        .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        .creationDateKey, .contentAccessDateKey, .addedToDirectoryDateKey,
        .contentTypeKey, .localizedTypeDescriptionKey,
    ]

    private let localizedType: String?

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        self.url = url
        self.contentURL = url
        self.canAccess = true
        self.archiveSession = nil
        self.name = v.name ?? url.lastPathComponent
        self.isDirectory = v.isDirectory ?? false
        self.isPackage = v.isPackage ?? false
        self.isHidden = v.isHidden ?? false
        self.isSymlink = v.isSymbolicLink ?? false
        self.size = Int64(v.fileSize ?? 0)
        self.modificationDate = v.contentModificationDate
        self.creationDate = v.creationDate
        self.accessDate = v.contentAccessDate
        self.addedDate = v.addedToDirectoryDate
        self.contentType = v.contentType
        self.localizedType = v.localizedTypeDescription
    }

    init(archiveEntry entry: ArchiveBrowsingSession.Entry, logicalURL: URL, session: ArchiveBrowsingSession) {
        url = logicalURL
        contentURL = entry.url
        archiveSession = session
        let safeURL = entry.canAccess ? (try? session.validatedURL(entry.url)) : nil
        let values = safeURL.flatMap { try? $0.resourceValues(forKeys: Set(Self.resourceKeys)) }
        canAccess = entry.canAccess && values != nil
        name = entry.name
        isDirectory = entry.isDirectory
        isPackage = entry.isPackage
        isHidden = values?.isHidden ?? entry.name.hasPrefix(".")
        isSymlink = entry.isSymbolicLink
        size = entry.size
        modificationDate = values?.contentModificationDate
        creationDate = values?.creationDate
        accessDate = values?.contentAccessDate
        addedDate = values?.addedToDirectoryDate
        contentType = values?.contentType
        localizedType = values?.localizedTypeDescription
    }

    /// True when a double-click should navigate into it rather than open it.
    var isNavigable: Bool { isDirectory && !isPackage && canAccess }

    /// A presentation preference only; identity, filtering and rename retain the full name.
    var displayName: String {
        guard !AppPreferences.showFileExtensions, !isNavigable else { return name }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    /// Rechecks containment at the point of use, including after external edits
    /// replace a formerly safe snapshot entry with an escaping symlink.
    var readableContentURL: URL? {
        guard canAccess else { return nil }
        guard let archiveSession else { return contentURL }
        guard let safe = try? archiveSession.validatedURL(contentURL),
              FileManager.default.fileExists(atPath: safe.path) else { return nil }
        return safe
    }


    /// The Finder icon at a given point size. Copied, because NSWorkspace may
    /// hand back a shared instance and we mutate the size.
    func icon(size: CGFloat) -> NSImage {
        // A symlink may have been replaced since listing; validate again before
        // NSWorkspace has any opportunity to inspect a snapshot target.
        let source = readableContentURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .item)
        let img = (source.copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: size, height: size)
        return img
    }

    var kindDescription: String {
        if let localizedType { return localizedType }
        return isNavigable ? "Folder" : (contentType?.localizedDescription ?? "Document")
    }

    var displaySize: String {
        if isNavigable { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var displayDate: String { Self.displayDate(modificationDate) }

    /// Medium date and short time, or "--" — shared by every date column.
    static func displayDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        return dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

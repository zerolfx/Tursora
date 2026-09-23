import AppKit
import UniformTypeIdentifiers

/// One entry in a directory listing. Resource values are read once, at load
/// time, so sorting and drawing never touch the filesystem.
struct FileItem {
    let url: URL
    /// Physical snapshot used only for reads; navigation always keeps `url`.
    let contentURL: URL
    /// Whether the item can be read at all. For an archive entry this is a
    /// property of the entry, not of the disk: false only for a link that
    /// leads nowhere readable and for an entry whose extraction failed.
    let canAccess: Bool
    private let archiveSession: ArchiveBrowsingSession?
    /// The tree path whose bytes an archive entry reads (a link's target for a
    /// link); nil for anything else.
    private let archivePath: String?
    var isArchiveEntry: Bool { archiveSession != nil }
    /// A lazily mounted archive directory's item count, from its tree. Nil for
    /// anything else, which is counted from disk as before.
    var archiveChildCount: Int? { isNavigable ? archiveSession?.listedChildCount(of: contentURL) : nil }
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
        self.archivePath = nil
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

    /// Every field from the table of contents: an entry's bytes may not be
    /// extracted yet, and a row must not change when they arrive (D97).
    init(archiveEntry entry: ArchiveBrowsingSession.Entry, logicalURL: URL, session: ArchiveBrowsingSession) {
        url = logicalURL
        contentURL = entry.url
        archiveSession = session
        archivePath = entry.contentPath
        canAccess = entry.canAccess
        name = entry.name
        isDirectory = entry.isDirectory
        isPackage = entry.isPackage
        // bsdtar restores no hidden flag here (`--no-fflags`), so a dot name is
        // the whole rule, as it is for the extracted file.
        isHidden = entry.name.hasPrefix(".")
        isSymlink = entry.isSymbolicLink
        size = entry.size
        // The archive's own date. On disk, a directory's date is only when its
        // skeleton was created, which is when the user opened the archive.
        modificationDate = entry.modificationDate
        // bsdtar sets the modification date, and on APFS setting it earlier
        // than a file's birth moves the birth back with it, so an extracted
        // copy's creation date is the archive's date too (measured).
        creationDate = entry.modificationDate
        // Neither has happened to an entry that is only in the archive.
        accessDate = nil
        addedDate = nil
        contentType = entry.contentType
        localizedType = entry.kind
    }

    /// True when a double-click should navigate into it rather than open it.
    var isNavigable: Bool { isDirectory && !isPackage && canAccess }

    /// A presentation preference only; identity, filtering and rename retain the full name.
    var displayName: String {
        guard !AppPreferences.showFileExtensions, !isNavigable else { return name }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    /// Where this item's bytes can be read right now, or nil. For an archive
    /// entry that is only once they are published — judged from the entry's
    /// state, never from the disk — and after containment is checked again at
    /// the point of use, in case a link was replaced since listing. A folder
    /// counts once its whole subtree is here, so it is never handed to a copy
    /// half-filled.
    var publishedContentURL: URL? {
        guard canAccess else { return nil }
        guard let archiveSession else { return contentURL }
        guard let archivePath, archiveSession.isPublished(archivePath) else { return nil }
        return try? archiveSession.validatedURL(contentURL)
    }

    /// The icon as NSWorkspace hands it back, at its own size.
    var iconImage: NSImage {
        guard isArchiveEntry else { return NSWorkspace.shared.icon(forFile: contentURL.path) }
        guard canAccess else { return NSWorkspace.shared.icon(for: .item) }
        // A published file or package shows its own icon — an app its real
        // one. Anything else shows its type's, which is what it will look
        // like; a folder is always a folder, so it is never asked to prove its
        // whole subtree is here just to be drawn.
        if !isNavigable, let published = publishedContentURL {
            return NSWorkspace.shared.icon(forFile: published.path)
        }
        return NSWorkspace.shared.icon(for: isNavigable ? .folder : (contentType ?? .data))
    }

    /// The Finder icon at a given point size. Copied, because NSWorkspace may
    /// hand back a shared instance and we mutate the size.
    func icon(size: CGFloat) -> NSImage {
        let img = (iconImage.copy() as? NSImage) ?? NSImage()
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

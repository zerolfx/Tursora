import AppKit
import UniformTypeIdentifiers

/// One entry in a directory listing. Resource values are read once, at load
/// time, so sorting and drawing never touch the filesystem.
struct FileItem {
    let url: URL
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

    /// True when a double-click should navigate into it rather than open it.
    var isNavigable: Bool { isDirectory && !isPackage }

    /// A presentation preference only; identity, filtering and rename retain the full name.
    var displayName: String {
        guard !AppPreferences.showFileExtensions, !isNavigable else { return name }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    var icon: NSImage { icon(size: 16) }

    /// The Finder icon at a given point size. Copied, because NSWorkspace may
    /// hand back a shared instance and we mutate the size.
    func icon(size: CGFloat) -> NSImage {
        let img = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSImage()
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

    var displayDate: String {
        guard let modificationDate else { return "--" }
        return Self.dateFormatter.string(from: modificationDate)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

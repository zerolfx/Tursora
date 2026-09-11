import AppKit
import CoreServices
import UniformTypeIdentifiers

/// The facts behind Finder's Get Info window, computed away from the UI so
/// they can be checked headlessly. Labels and wording follow Finder's own
/// (InfoWindow*.nib in Finder.app).
enum FileInfo {

    // MARK: - Where / dates

    /// Finder's "Where:" line — display names from the volume down to the
    /// parent folder, "▸"-separated ("Macintosh HD ▸ Users ▸ me").
    static func whereString(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let parts = FileManager.default.componentsToDisplay(forPath: parent)
            ?? parent.split(separator: "/").map(String.init)
        return parts.joined(separator: " ▸ ")
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    static func dateString(_ date: Date?) -> String {
        date.map(dateFormatter.string(from:)) ?? "--"
    }

    // MARK: - Size

    struct Size: Equatable {
        /// Logical bytes (data + resource forks), what Finder prints in parentheses.
        var bytes: Int64 = 0
        /// Allocated bytes, what Finder calls "on disk".
        var onDisk: Int64 = 0
        /// Entries inside a folder (everything, hidden included), or the
        /// number of selected items for a summary.
        var items = 0
        var isFolder = false
        var finished = false
    }

    static func shortBytes(_ n: Int64) -> String {
        n == 0 ? "Zero bytes" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func longBytes(_ n: Int64) -> String {
        n == 0 ? "Zero bytes" : "\(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)) bytes"
    }

    /// "6,148 bytes (8 KB on disk)" for a file,
    /// "8 KB on disk (6,148 bytes) for 2 items" for a folder or a summary.
    static func sizeString(_ s: Size) -> String {
        guard s.finished else { return "Calculating size…" }
        if s.isFolder {
            return "\(shortBytes(s.onDisk)) on disk (\(longBytes(s.bytes))) for \(s.items) item\(s.items == 1 ? "" : "s")"
        }
        return "\(longBytes(s.bytes)) (\(shortBytes(s.onDisk)) on disk)"
    }

    /// The short form for the window header ("8 KB", "--" while counting).
    static func headerSizeString(_ s: Size) -> String {
        s.finished ? shortBytes(s.onDisk) : "--"
    }

    final class SizeCalculation {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
        fileprivate init() {}
    }

    /// Adds up the items on a background queue. `update` runs on the main
    /// thread a few times a second while counting and once more when done.
    /// `countingChildren` makes `items` the number of entries inside the
    /// folders (Get Info); otherwise it is the number of urls (Summary Info).
    @discardableResult
    static func computeSize(of urls: [URL], countingChildren: Bool,
                            update: @escaping (Size) -> Void) -> SizeCalculation {
        let calc = SizeCalculation()
        let keys: Set<URLResourceKey> = [.totalFileSizeKey, .totalFileAllocatedSizeKey]
        DispatchQueue.global(qos: .userInitiated).async {
            var total = Size()
            total.isFolder = countingChildren ? urls.contains(where: isRealDirectory) : true
            var lastReport = Date()
            func add(_ url: URL) {
                guard let v = try? url.resourceValues(forKeys: keys) else { return }
                total.bytes += Int64(v.totalFileSize ?? 0)
                total.onDisk += Int64(v.totalFileAllocatedSize ?? 0)
            }
            for url in urls {
                if calc.isCancelled { return }
                if !countingChildren { total.items += 1 }
                if isRealDirectory(url) {
                    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) else { continue }
                    for case let child as URL in e {
                        if calc.isCancelled { return }
                        if countingChildren { total.items += 1 }
                        add(child)
                        if Date().timeIntervalSince(lastReport) > 0.25 {
                            lastReport = Date()
                            let snapshot = total
                            DispatchQueue.main.async { if !calc.isCancelled { update(snapshot) } }
                        }
                    }
                } else {
                    add(url)
                }
            }
            total.finished = true
            let final = total
            DispatchQueue.main.async { if !calc.isCancelled { update(final) } }
        }
        return calc
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true
    }

    // MARK: - Flags (General section checkboxes, Name & Extension)

    // FileManager, not URL resource values: those are cached for the rest of
    // the run-loop pass, so a read right after a write would be stale.

    static func isLocked(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.immutable] as? Bool) ?? false
    }

    static func setLocked(_ locked: Bool, _ url: URL) throws {
        try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: url.path)
    }

    static func hasHiddenExtension(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.extensionHidden] as? Bool) ?? false
    }

    static func setHiddenExtension(_ hidden: Bool, _ url: URL) throws {
        try FileManager.default.setAttributes([.extensionHidden: hidden], ofItemAtPath: url.path)
    }

    // MARK: - Comments (Finder stores them in this xattr; Spotlight indexes it)

    static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    static func comment(for url: URL) -> String {
        let path = url.path
        let length = getxattr(path, commentAttribute, nil, 0, 0, 0)
        if length > 0 {
            var data = Data(count: length)
            let got = data.withUnsafeMutableBytes { getxattr(path, commentAttribute, $0.baseAddress, length, 0, 0) }
            if got == length, let s = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? String {
                return s
            }
        }
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
           let s = MDItemCopyAttribute(item, kMDItemFinderComment) as? String {
            return s
        }
        return ""
    }

    static func setComment(_ text: String, for url: URL) throws {
        let path = url.path
        if text.isEmpty {
            if removexattr(path, commentAttribute, 0) != 0, errno != ENOATTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0)
        let rc = data.withUnsafeBytes { setxattr(path, commentAttribute, $0.baseAddress, data.count, 0, 0) }
        if rc != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    // MARK: - More Info (Spotlight)

    /// Finder's "More Info" rows: whatever Spotlight knows that is worth a
    /// line, in Finder's order and wording.
    static func moreInfo(for url: URL) -> [(String, String)] {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return [] }
        func attr(_ key: CFString) -> Any? { MDItemCopyAttribute(item, key) }
        func list(_ key: CFString) -> String? {
            guard let a = attr(key) as? [String], !a.isEmpty else { return nil }
            return a.joined(separator: ", ")
        }
        var rows: [(String, String)] = []
        if let w = attr(kMDItemPixelWidth) as? Int, let h = attr(kMDItemPixelHeight) as? Int {
            rows.append(("Dimensions", "\(w) × \(h)"))
        }
        if let cs = attr(kMDItemColorSpace) as? String { rows.append(("Color space", cs)) }
        if let alpha = attr(kMDItemHasAlphaChannel) as? Bool { rows.append(("Alpha channel", alpha ? "Yes" : "No")) }
        if let d = attr(kMDItemDurationSeconds) as? Double {
            let total = Int(d.rounded())
            rows.append(("Duration", total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                                                   : String(format: "%d:%02d", total / 60, total % 60)))
        }
        if let codecs = list(kMDItemCodecs) { rows.append(("Codecs", codecs)) }
        if let ch = attr(kMDItemAudioChannelCount) as? Int { rows.append(("Audio channels", "\(ch)")) }
        if let sr = attr(kMDItemAudioSampleRate) as? Double { rows.append(("Sample rate", "\(Int(sr)) Hz")) }
        if let t = attr(kMDItemTitle) as? String { rows.append(("Title", t)) }
        if let a = list(kMDItemAuthors) { rows.append(("Authors", a)) }
        if let p = attr(kMDItemNumberOfPages) as? Int { rows.append(("Page count", "\(p)")) }
        if let c = attr(kMDItemCreator) as? String { rows.append(("Content creator", c)) }
        if let e = list(kMDItemEncodingApplications) { rows.append(("Encoding applications", e)) }
        if let from = list(kMDItemWhereFroms) { rows.append(("Where from", from)) }
        if let d = attr(kMDItemLastUsedDate) as? Date { rows.append(("Last opened", dateString(d))) }
        return rows
    }

    // MARK: - Packages, volumes, links

    /// "Version:" and "Copyright:" for application bundles.
    static func bundleInfo(for url: URL) -> [(String, String)] {
        guard (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true,
              let info = Bundle(url: url)?.infoDictionary else { return [] }
        var rows: [(String, String)] = []
        if let v = info["CFBundleShortVersionString"] as? String {
            let build = info["CFBundleVersion"] as? String
            rows.append(("Version", build != nil && build != v ? "\(v) (\(build!))" : v))
        }
        if let c = info["NSHumanReadableCopyright"] as? String, !c.isEmpty { rows.append(("Copyright", c)) }
        return rows
    }

    /// Capacity / Available / Used / Format when the item is a mount point.
    static func volumeInfo(for url: URL) -> [(String, String)] {
        guard let v = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]),
              v.isVolume == true else { return [] }
        var rows: [(String, String)] = []
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        rows.append(("Capacity", "\(shortBytes(total)) (\(longBytes(total)))"))
        rows.append(("Available", "\(shortBytes(available)) (\(longBytes(available)))"))
        rows.append(("Used", "\(shortBytes(total - available)) (\(longBytes(total - available)))"))
        if let f = v.volumeLocalizedFormatDescription { rows.append(("Format", f)) }
        return rows
    }

    /// Finder's "Original:" for symlinks and alias files.
    static func original(of url: URL) -> String? {
        let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        if v?.isSymbolicLink == true, let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()).standardizedFileURL.path
        }
        if v?.isAliasFile == true, let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) {
            return target.path
        }
        return nil
    }

    // MARK: - Open with

    /// The default application first, the rest by name.
    static func applications(toOpen url: URL) -> (default: URL?, others: [URL]) {
        let def = NSWorkspace.shared.urlForApplication(toOpen: url)
        var all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let def { all.removeAll { $0.standardizedFileURL == def.standardizedFileURL } }
        let fm = FileManager.default
        all.sort { fm.displayName(atPath: $0.path).localizedCaseInsensitiveCompare(fm.displayName(atPath: $1.path)) == .orderedAscending }
        return (def, all)
    }

    // MARK: - Sharing & Permissions (POSIX classes, Finder's four privileges)

    enum Privilege: String, CaseIterable {
        case readWrite = "Read & Write"
        case readOnly = "Read only"
        case writeOnly = "Write only (Drop Box)"
        case noAccess = "No Access"
    }

    /// Bit offset of each class in the mode.
    enum Who: Int, CaseIterable {
        case owner = 6, group = 3, everyone = 0
    }

    struct Permissions {
        var mode: Int
        var ownerName: String
        var groupName: String
        var ownerID: uid_t
        var isFolder: Bool
        var isOwnedByMe: Bool { ownerID == getuid() }
        func privilege(_ who: Who) -> Privilege { FileInfo.privilege(mode: mode, who: who) }
    }

    static func permissions(of url: URL) -> Permissions? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let uid = (a[.ownerAccountID] as? Int) ?? -1
        return Permissions(mode: (a[.posixPermissions] as? Int) ?? 0,
                           ownerName: (a[.ownerAccountName] as? String) ?? "\(uid)",
                           groupName: (a[.groupOwnerAccountName] as? String) ?? "",
                           ownerID: uid_t(truncatingIfNeeded: uid),
                           isFolder: (a[.type] as? FileAttributeType) == .typeDirectory)
    }

    static func privilege(mode: Int, who: Who) -> Privilege {
        let bits = (mode >> who.rawValue) & 0o7
        switch (bits & 4 != 0, bits & 2 != 0) {
        case (true, true): return .readWrite
        case (true, false): return .readOnly
        case (false, true): return .writeOnly
        case (false, false): return .noAccess
        }
    }

    /// The mode after choosing a privilege for one class. Folders need the
    /// execute bit to be entered, so there it follows read/write; a file's
    /// execute bit is left alone.
    static func mode(_ mode: Int, setting p: Privilege, for who: Who, isFolder: Bool) -> Int {
        let old = (mode >> who.rawValue) & 0o7
        let r = p == .readWrite || p == .readOnly
        let w = p == .readWrite || p == .writeOnly
        let x = isFolder ? ((r || w) ? 1 : 0) : (old & 1)
        let bits = (r ? 4 : 0) | (w ? 2 : 0) | x
        return (mode & ~(0o7 << who.rawValue)) | (bits << who.rawValue)
    }

    static func setMode(_ mode: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// "fxlin (Me)", "staff", "everyone" — the three rows' names.
    static func displayName(for who: Who, _ p: Permissions) -> String {
        switch who {
        case .owner: return p.isOwnedByMe ? "\(p.ownerName) (Me)" : p.ownerName
        case .group: return p.groupName
        case .everyone: return "everyone"
        }
    }

    /// The line above the table.
    static func accessSummary(for url: URL) -> String {
        let fm = FileManager.default
        switch (fm.isReadableFile(atPath: url.path), fm.isWritableFile(atPath: url.path)) {
        case (true, true): return "You can read and write"
        case (true, false): return "You can only read"
        case (false, true): return "You can only write"
        case (false, false): return "You have no access"
        }
    }

    // MARK: - Following renames

    static func fileID(of url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// The entry in `url`'s folder that has this inode — the item under its
    /// new name after a rename made outside the app.
    static func sibling(of url: URL, withFileID id: UInt64) -> URL? {
        let parent = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return nil }
        for name in names {
            let candidate = parent.appendingPathComponent(name)
            if fileID(of: candidate) == id { return candidate }
        }
        return nil
    }

    // MARK: - Kind

    static func kind(of url: URL) -> String {
        FileItem(url: url)?.kindDescription ?? "Document"
    }

    /// Summary Info's "Kind:" — "2 documents, 1 folder".
    static func summaryKind(for urls: [URL]) -> String {
        var folders = 0, documents = 0, applications = 0
        for url in urls {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
            if v?.isDirectory == true && v?.isPackage != true { folders += 1 }
            else if v?.contentType?.conforms(to: .application) == true { applications += 1 }
            else { documents += 1 }
        }
        var parts: [String] = []
        if documents > 0 { parts.append("\(documents) document\(documents == 1 ? "" : "s")") }
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        if applications > 0 { parts.append("\(applications) application\(applications == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

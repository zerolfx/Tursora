import Foundation
import Darwin

/// Where the Trash is, and what counts as being inside it.
///
/// The user's trash comes from `FileManager.url(for: .trashDirectory, …)`;
/// a volume's own trash from the same call with `appropriateFor:` set to a URL
/// on that volume. Browsing and emptying only ever use the *user's* trash —
/// per-volume trashes are out of scope (see docs/research/trash.md).
///
/// `userTrashOverride` is the injection point: smoke suites point it at a
/// fixture directory so no check lists, moves into, or empties the real
/// `~/.Trash`. Everything else in the app asks this type, never FileManager.
enum TrashLocation {

    /// Test hook. Set to a fixture directory for the duration of a check and
    /// restore it afterwards; `nil` means the real user trash.
    static var userTrashOverride: URL?

    /// Finder's name for the place (Localizable N39 / PW30).
    static let placeName = "Trash"
    static let symbolName = "trash"
    /// Status-bar context, alongside the archive pane's "ZIP · Read-only".
    static let statusContext = "Trash"

    // MARK: - Resolution

    /// `~/.Trash`, or the injected fixture. `create` is passed straight through
    /// to FileManager; browsing never creates anything.
    static func userTrash(create: Bool = false) -> URL? {
        if let userTrashOverride { return userTrashOverride.standardizedFileURL }
        return try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: create)
            .standardizedFileURL
    }

    /// The same location as a plain path, without asking `FileManager` to look
    /// the directory up. `url(for: .trashDirectory, …)` reaches the protected
    /// item and makes macOS evaluate Full Disk Access, which deactivates the
    /// application while the system decides — the sidebar must not pay that
    /// price on every rebuild. Listing the folder still reports a denial
    /// through the pane's banner.
    static func userTrashPath() -> URL {
        if let userTrashOverride { return userTrashOverride.standardizedFileURL }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL
    }

    /// The trash that serves the volume `url` lives on (`/Volumes/X/.Trashes/501`
    /// for a secondary volume, `~/.Trash` for the boot volume). Provided for
    /// completeness; nothing in the UI browses or empties it yet.
    static func volumeTrash(containing url: URL) -> URL? {
        if userTrashOverride != nil { return userTrash() }
        return try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                            appropriateFor: url, create: false)
            .standardizedFileURL
    }

    /// Trash roots this build recognises. One entry today.
    static func knownRoots() -> [URL] { userTrash().map { [$0] } ?? [] }

    // MARK: - Membership (pure)

    /// One comparable spelling of a path: `.`/`..` removed and every symlink
    /// resolved, with no trailing slash — `/tmp/x` and `/private/tmp/x` become
    /// the same string.
    ///
    /// `URL.resolvingSymlinksInPath()` is not enough: Foundation deliberately
    /// leaves `/tmp`, `/var` and `/etc` alone (it normalises the other way,
    /// stripping `/private`), and it only rewrites components that exist.
    /// `realpath(3)` on the deepest existing ancestor answers both, so an
    /// item's journal key is the same before and after it is moved away.
    static func canonicalPath(_ url: URL) -> String {
        var suffix: [String] = []
        var probe = url.standardizedFileURL.path
        while true {
            if let real = realPath(probe) {
                return trimmed(suffix.reduce(real) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 })
            }
            let parent = (probe as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == probe || suffix.count >= 64 { break }
            suffix.insert((probe as NSString).lastPathComponent, at: 0)
            probe = parent
        }
        return trimmed(url.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Is `url` one of `roots` itself?
    static func isTrashDirectory(_ url: URL, roots: [URL]) -> Bool {
        let path = canonicalPath(url)
        return roots.contains { canonicalPath($0) == path }
    }

    /// The root of `roots` that contains `url` (the root itself counts), else nil.
    /// A sibling whose name merely starts with a root's path never matches.
    static func trashRoot(containing url: URL, roots: [URL]) -> URL? {
        let path = canonicalPath(url)
        return roots.first { root in
            let rootPath = canonicalPath(root)
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    static func isTrashDirectory(_ url: URL) -> Bool { isTrashDirectory(url, roots: knownRoots()) }
    static func trashRoot(containing url: URL) -> URL? { trashRoot(containing: url, roots: knownRoots()) }
    static func isInTrash(_ url: URL) -> Bool { trashRoot(containing: url) != nil }

    /// Top-level entries of a trash directory, including hidden ones but never
    /// `.` / `..`. Throws the listing error so callers can show the banner.
    static func topLevelItems(in trash: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil,
                                                    options: [])
    }

    // MARK: - Access

    /// A listing that failed because the process lacks Full Disk Access, rather
    /// than because the folder is missing. Cocoa wraps the POSIX code, so both
    /// domains are inspected.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EPERM) || nsError.code == Int(EACCES)
        }
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError { return true }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                return isPermissionDenied(underlying)
            }
        }
        return false
    }

    /// Privacy & Security ▸ Full Disk Access.
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    // MARK: - Wording

    /// Finder's File menu row when the warning is enabled (Localizable A3).
    static let emptyTrashMenuTitle = "Empty Trash…"
    /// Finder's confirmation (Localizable A15 / A16).
    static let emptyTrashMessageText = "Are you sure you want to permanently erase the items in the Trash?"
    static let emptyTrashInformativeText = "You can’t undo this action."
    /// Finder's button (Localizable N157) and the contextual row (N153.1).
    static let emptyTrashButtonTitle = "Empty Trash"
    static let putBackTitle = "Put Back"
}

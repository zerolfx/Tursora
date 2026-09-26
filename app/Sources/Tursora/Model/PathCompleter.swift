import Foundation

/// Path resolution and completion for the address bar's edit mode.
/// Blocking filesystem helpers plus pure prefix matching. Interactive callers
/// use PathCompletionService so resolution and listing happen off the main queue.
enum PathCompleter {

    /// Expand `~`, resolve relative input against `cwd`, and require an
    /// existing directory. Returns nil when the text does not name one.
    static func resolveDirectory(_ text: String, cwd: URL, home: URL, workspace: ArchiveWorkspace = .shared) -> URL? {
        guard let url = candidateURL(text, cwd: cwd, home: home) else { return nil }
        if AppPreferences.experimentalZIPBrowsingEnabled || workspace.session(for: url) != nil,
           let archive = workspace.archiveURL(containing: url) {
            if workspace.session(for: url) == nil {
                return archive.path == url.path ? archive : nil
            }
            // From the table of contents alone: this runs on every keystroke
            // and on every drag update over the tab bar, so it must never
            // extract anything.
            guard workspace.isNavigableFolder(url) else { return nil }
            return workspace.logicalURL(for: url)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return url
    }

    /// Address submission may name an unprepared ZIP child. The browser must
    /// prepare the archive and validate that candidate before navigating.
    static func resolveNavigationLocation(_ text: String, cwd: URL, home: URL, workspace: ArchiveWorkspace = .shared) -> URL? {
        if let directory = resolveDirectory(text, cwd: cwd, home: home, workspace: workspace) { return directory }
        guard AppPreferences.experimentalZIPBrowsingEnabled,
              let candidate = candidateURL(text, cwd: cwd, home: home),
              workspace.session(for: candidate) == nil,
              workspace.archiveURL(containing: candidate) != nil else { return nil }
        return candidate
    }

    private static func candidateURL(_ text: String, cwd: URL, home: URL) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded: String
        if trimmed == "~" {
            expanded = home.path
        } else if trimmed.hasPrefix("~/") {
            expanded = home.path + trimmed.dropFirst(1)
        } else if trimmed.hasPrefix("/") {
            expanded = trimmed
        } else if let fileURL = URL(string: trimmed), fileURL.isFileURL {
            expanded = fileURL.path
        } else {
            expanded = cwd.appendingPathComponent(trimmed).path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// Directory-name completions for the last path component of `text`.
    /// Returned strings replace that component and end in "/" so the next
    /// completion round starts inside the chosen folder.
    static func completions(for text: String, cwd: URL, home: URL, includeHidden: Bool = false, workspace: ArchiveWorkspace = .shared) -> [String] {
        let (dirText, partial) = splitLastComponent(text)
        let entries = directoryEntries(for: DirectoryQuery(directoryText: dirText, cwd: cwd, home: home), workspace: workspace)
        return completions(in: entries, partial: partial, includeHidden: includeHidden)
    }

    /// The directory, rather than the prefix being typed, is the cache key.
    /// Resolving it is deliberately deferred to the worker as mounted volumes
    /// and symlink targets can block even before enumeration starts.
    struct DirectoryQuery: Hashable {
        let directoryText: String
        let cwd: URL
        let home: URL
    }

    struct DirectoryEntry {
        let name: String
        let isHidden: Bool
    }

    static func directoryEntries(for query: DirectoryQuery, workspace: ArchiveWorkspace = .shared) -> [DirectoryEntry] {
        let dir: URL
        if query.directoryText.isEmpty {
            dir = query.cwd
        } else {
            guard let resolved = resolveDirectory(query.directoryText, cwd: query.cwd, home: query.home, workspace: workspace) else { return [] }
            dir = resolved
        }
        if workspace.session(for: dir) != nil {
            let provider = ArchiveFileProvider(base: LocalFileProvider(), workspace: workspace)
            guard let items = try? provider.listDirectory(dir) else { return [] }
            return items.filter(\.isNavigable).map { DirectoryEntry(name: $0.name, isHidden: $0.isHidden) }
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey],
            options: []) else { return [] }
        return entries.compactMap { url -> DirectoryEntry? in
            guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey]),
                  v.isDirectory == true, v.isPackage != true else { return nil }
            return DirectoryEntry(name: url.lastPathComponent, isHidden: v.isHidden == true)
        }
    }

    static func completions(in entries: [DirectoryEntry], partial: String, includeHidden: Bool = false) -> [String] {
        let wantHidden = includeHidden || partial.hasPrefix(".")
        let prefix = partial.lowercased()
        return entries.filter {
            (wantHidden || !$0.isHidden) && (prefix.isEmpty || $0.name.lowercased().hasPrefix(prefix))
        }.map { $0.name + "/" }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// "~/Work/Do" → ("~/Work/", "Do");  "Do" → ("", "Do");  "/" → ("/", "")
    static func splitLastComponent(_ text: String) -> (dir: String, partial: String) {
        guard let slash = text.lastIndex(of: "/") else { return ("", text) }
        return (String(text[...slash]), String(text[text.index(after: slash)...]))
    }
}

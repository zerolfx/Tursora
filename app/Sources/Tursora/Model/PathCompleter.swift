import Foundation

/// Path resolution and completion for the address bar's edit mode.
/// Pure functions, so they are testable without a window.
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
        let dir: URL
        if dirText.isEmpty {
            dir = cwd
        } else {
            guard let resolved = resolveDirectory(dirText, cwd: cwd, home: home, workspace: workspace) else { return [] }
            dir = resolved
        }
        if workspace.session(for: dir) != nil {
            let provider = ArchiveFileProvider(base: LocalFileProvider(), workspace: workspace)
            guard let items = try? provider.listDirectory(dir) else { return [] }
            let wantHidden = includeHidden || partial.hasPrefix(".")
            return items.filter {
                $0.isNavigable && (wantHidden || !$0.isHidden)
                    && (partial.isEmpty || $0.name.lowercased().hasPrefix(partial.lowercased()))
            }.map { $0.name + "/" }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey],
            options: []) else { return [] }
        let wantHidden = includeHidden || partial.hasPrefix(".")
        return entries.compactMap { url -> String? in
            guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey]),
                  v.isDirectory == true, v.isPackage != true else { return nil }
            if v.isHidden == true, !wantHidden { return nil }
            let name = url.lastPathComponent
            guard partial.isEmpty || name.lowercased().hasPrefix(partial.lowercased()) else { return nil }
            return name + "/"
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// "~/Work/Do" → ("~/Work/", "Do");  "Do" → ("", "Do");  "/" → ("/", "")
    static func splitLastComponent(_ text: String) -> (dir: String, partial: String) {
        guard let slash = text.lastIndex(of: "/") else { return ("", text) }
        return (String(text[...slash]), String(text[text.index(after: slash)...]))
    }
}

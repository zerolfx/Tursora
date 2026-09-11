import Foundation

/// Path resolution and completion for the address bar's edit mode.
/// Pure functions, so they are testable without a window.
enum PathCompleter {

    /// Expand `~`, resolve relative input against `cwd`, and require an
    /// existing directory. Returns nil when the text does not name one.
    static func resolveDirectory(_ text: String, cwd: URL, home: URL) -> URL? {
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
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    /// Directory-name completions for the last path component of `text`.
    /// Returned strings replace that component and end in "/" so the next
    /// completion round starts inside the chosen folder.
    static func completions(for text: String, cwd: URL, home: URL, includeHidden: Bool = false) -> [String] {
        let (dirText, partial) = splitLastComponent(text)
        let dir: URL
        if dirText.isEmpty {
            dir = cwd
        } else {
            guard let resolved = resolveDirectory(dirText, cwd: cwd, home: home) else { return [] }
            dir = resolved
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

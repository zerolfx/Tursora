import Foundation
import UniformTypeIdentifiers

/// The content type and Kind string an archive row shows, asked of the system
/// rather than guessed from the extension.
///
/// A row is built from the table of contents, before its bytes exist, so
/// there is no file to ask. What decides a Kind is the name's extension,
/// whether it is a folder, and — for a file — whether it is executable;
/// LaunchServices does not look inside a file for this. An empty probe file
/// of the same shape therefore answers exactly as the extracted file would:
/// "Unix Executable File" for an extensionless command-line tool, not the
/// "Document" `UTType(filenameExtension:)` alone suggests, and "Application"
/// for `.app` (D97). Probes are made once at mount, off the main thread, for at
/// most `maximumProbes` distinct shapes, and deleted after reading; the rest
/// fall back to `UTType`.
final class ArchiveTypeCatalog {
    struct Description: Equatable {
        let contentType: UTType?
        let kind: String?
    }

    struct Key: Hashable {
        enum Shape: Hashable { case file(executable: Bool), directory, symbolicLink }
        let pathExtension: String
        let shape: Shape
    }

    /// Enough for any real archive's variety of types; the most common shapes
    /// are probed first, so the fallback only ever serves the long tail.
    static let maximumProbes = 256
    /// A longer extension would make the probe's name too long to create; it
    /// is no extension a type is registered for anyway.
    private static let maximumExtensionLength = 64

    private let table: [Key: Description]

    /// How many shapes were probed, for the suite.
    var probedCount: Int { table.count }

    init(table: [Key: Description] = [:]) { self.table = table }

    static func key(for node: ArchiveTree.Node) -> Key {
        switch node.kind {
        case .symbolicLink:
            // A link reads as a link, whatever it is called — as it does in
            // an ordinary folder (measured: "Alias", `public.symlink`).
            return Key(pathExtension: "", shape: .symbolicLink)
        case .directory:
            return Key(pathExtension: (node.name as NSString).pathExtension.lowercased(), shape: .directory)
        case .file:
            return Key(pathExtension: (node.name as NSString).pathExtension.lowercased(),
                       shape: .file(executable: node.isExecutable))
        }
    }

    func describe(_ node: ArchiveTree.Node) -> Description {
        let key = Self.key(for: node)
        return table[key] ?? Self.fallback(for: key)
    }

    /// `UTType`'s own answer, used past the probe limit or when a probe could
    /// not be made. Right for the common cases; the probes exist for the rest.
    static func fallback(for key: Key) -> Description {
        let type: UTType
        switch key.shape {
        case .symbolicLink:
            type = .symbolicLink
        case .directory:
            type = key.pathExtension.isEmpty ? .folder
                : UTType(filenameExtension: key.pathExtension, conformingTo: .directory) ?? .folder
        case .file(let executable):
            type = key.pathExtension.isEmpty ? (executable ? .unixExecutable : .data)
                : UTType(filenameExtension: key.pathExtension, conformingTo: .data) ?? .data
        }
        return Description(contentType: type, kind: type.localizedDescription)
    }

    /// Probes the tree's most common shapes in `directory`, which it creates
    /// and removes again. Blocks; runs at mount, off the main thread.
    static func probing(_ tree: ArchiveTree, in directory: URL, limit: Int = maximumProbes) -> ArchiveTypeCatalog {
        var counts: [Key: Int] = [:]
        tree.forEachNode { node in
            guard node.isExtractable, !node.insidePackage else { return }
            counts[key(for: node), default: 0] += 1
        }
        let keys = counts.filter { $0.key.pathExtension.utf8.count <= maximumExtensionLength }
            .sorted { $0.value != $1.value ? $0.value > $1.value
                      : ($0.key.pathExtension, "\($0.key.shape)") < ($1.key.pathExtension, "\($1.key.shape)") }
            .prefix(limit).map(\.key)
        guard !keys.isEmpty else { return ArchiveTypeCatalog() }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return ArchiveTypeCatalog() }
        defer { try? fm.removeItem(at: directory) }
        var table: [Key: Description] = [:]
        for (index, key) in keys.enumerated() {
            let name = "probe\(index)" + (key.pathExtension.isEmpty ? "" : "." + key.pathExtension)
            let path = directory.appendingPathComponent(name).path
            let made: Bool
            switch key.shape {
            case .directory:
                made = (try? fm.createDirectory(atPath: path, withIntermediateDirectories: false)) != nil
            case .file(let executable):
                made = fm.createFile(atPath: path, contents: nil,
                                     attributes: [.posixPermissions: executable ? 0o700 : 0o600])
            case .symbolicLink:
                made = (try? fm.createSymbolicLink(atPath: path, withDestinationPath: "probe-target")) != nil
            }
            guard made else { continue }
            // A fresh URL for each read: resource values are cached per URL
            // object for the run-loop pass (AGENTS.md rule 5).
            guard let values = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.contentTypeKey, .localizedTypeDescriptionKey]) else { continue }
            table[key] = Description(contentType: values.contentType, kind: values.localizedTypeDescription)
        }
        return ArchiveTypeCatalog(table: table)
    }
}

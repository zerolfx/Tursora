import Foundation

/// How one member is spelled in each place bsdtar mentions it. Attribution has
/// to recognise all of them: a success or a member error names the entry as the
/// archive spells it (less any leading `/` or drive letter), while "Not found"
/// repeats the **escaped** pattern it was given.
struct ArchiveMemberSpelling: Hashable {
    /// Where it lands under the root: the tree's path, and the verdict's key.
    let path: String
    /// The archive's own spelling.
    let raw: String
    /// As handed to bsdtar in a member list or on the command line.
    let escaped: String
}

/// The pure half of running bsdtar: the argument list, and what a run's log
/// says about each member. Measured, not assumed — see
/// docs/research/lazy-zip-browsing.md.
enum ArchiveTool {
    /// Selecting a directory's direct files in one run: include the directory,
    /// exclude everything two levels below it, and exclude any child that must
    /// never be asked for. The archive root has no include at all; an empty
    /// include is refused ("pattern is empty"), and `*/*` alone selects the
    /// top-level files.
    struct DirectorySelection: Equatable {
        var include: String?
        var excludes: [String]
    }

    /// Order is load-bearing and was measured: bsdtar stops reading options at
    /// the first positional pattern, so a pattern followed by `--exclude` makes
    /// `--exclude` itself a pattern — and the include then pulls the directory's
    /// **whole subtree**, packages and all. Options first, then every exclude,
    /// then the member list, then `--`, then the includes. `-v` is always on:
    /// the log is how members are told apart (D95).
    static func extractionArguments(source: URL, output: URL, noRecursion: Bool,
                                    memberList: URL? = nil, excludes: [String] = [],
                                    includes: [String] = [], passphrase: String = UUID().uuidString) -> [String] {
        var arguments = ["-x", "-v"]
        // `-n` for a leaf: without it `clash` also tries `clash/inside.txt`.
        // Never for a directory or package — an unrecorded directory is then
        // "Not found in archive". Never `-q`: it stops at the first match.
        if noRecursion { arguments.append("-n") }
        arguments += ["-f", source.path, "-C", output.path,
                      "--no-same-owner", "--no-same-permissions", "--mac-metadata", "--no-acls", "--no-fflags",
                      // A passphrase disables the interactive prompt, so an
                      // encrypted member fails instead of opening /dev/tty.
                      "--passphrase", passphrase]
        for exclude in excludes { arguments += ["--exclude", exclude] }
        if let memberList { arguments += ["-T", memberList.path] }
        if !includes.isEmpty { arguments += ["--"] + includes }
        return arguments
    }

    /// The selection that takes exactly a directory's direct files.
    static func directSelection(of escapedDirectory: String?, excluding extra: [String] = []) -> DirectorySelection {
        guard let directory = escapedDirectory, !directory.isEmpty else {
            return DirectorySelection(include: nil, excludes: ["*/*"] + extra)
        }
        return DirectorySelection(include: directory, excludes: [directory + "/*/*"] + extra)
    }
}

/// What one run's log says about each member it could have written.
struct ArchiveToolVerdict: Equatable {
    /// Announced, with no error on the same line.
    var extracted: Set<String> = []
    /// A member error, with bsdtar's own reason.
    var failed: [String: String] = [:]
    /// Asked for by name and absent from the archive.
    var notFound: Set<String> = []
    /// Lines that could not be tied to any member. One of these means the
    /// verdict cannot be trusted for the batch as a whole.
    var unrecognized: [String] = []
    /// The archive itself could not be read: no member verdict means anything.
    var sourceFailure: String?

    var isTrustworthy: Bool { unrecognized.isEmpty && sourceFailure == nil }

    /// Lines bsdtar writes that are about the run, not a member.
    private static let benign: [String] = [
        "tar: Removing leading '/' from member names",
        "tar: Removing leading drive letter from member names",
        "tar: Error exit delayed from previous errors.",
    ]

    /// `members` is every entry this run may write. `packages` are the paths
    /// extracted whole: a line about anything inside one is about the package,
    /// which succeeds or fails as a unit.
    static func attribute(log: String, members: [ArchiveMemberSpelling],
                          packages: [String] = []) -> ArchiveToolVerdict {
        var verdict = ArchiveToolVerdict()
        // Every spelling that can appear in an `x` line, mapped to the path.
        var announced: [String: String] = [:]
        var escapedToPath: [String: String] = [:]
        for member in members {
            for spelling in [member.raw, member.path, strippedPrefix(member.raw)] where !spelling.isEmpty {
                announced[trimSlash(spelling)] = member.path
            }
            escapedToPath[member.escaped] = member.path
            escapedToPath[member.raw] = member.path
        }
        // Longest first, so a name containing ": " is not cut at a shorter key.
        let keys = announced.keys.sorted { $0.count > $1.count }
        let packageSet = Set(packages)

        func exactOwner(_ name: String) -> String? { announced[trimSlash(name)] }
        func packageOwner(_ name: String) -> String? {
            packageSet.first { name == $0 || name.hasPrefix($0 + "/") }
        }

        for rawLine in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if benign.contains(line) { continue }
            if line.hasPrefix("tar: Error opening archive") { verdict.sourceFailure = line; continue }
            if line.hasPrefix("tar: "), line.hasSuffix(": Not found in archive") {
                let name = String(line.dropFirst(5).dropLast(": Not found in archive".count))
                if let path = escapedToPath[name] ?? exactOwner(name) { verdict.notFound.insert(path) }
                else { verdict.unrecognized.append(line) }
                continue
            }
            guard line.hasPrefix("x ") else { verdict.unrecognized.append(line); continue }
            let rest = String(line.dropFirst(2))
            // 1. Exactly a known name: a clean announcement.
            if let path = exactOwner(rest) {
                if verdict.failed[path] == nil { verdict.extracted.insert(path) }
                continue
            }
            // 2. A known name followed by ": reason" — the longest name wins, so
            //    a name that itself contains ": " is not cut short.
            if let key = keys.first(where: { rest.hasPrefix($0 + ": ") || rest.hasPrefix($0 + "/: ") }) {
                let path = announced[key]!
                verdict.failed[path] = String(rest.dropFirst(key.count).drop { $0 == "/" || $0 == ":" || $0 == " " })
                verdict.extracted.remove(path)
                continue
            }
            // 3. Inside a package but not a name the caller supplied. Only a
            //    bare name is a success; anything after it is taken as a
            //    failure, because publishing a corrupt app is worse than not
            //    publishing a sound one. Callers pass every descendant's
            //    spelling so that this conservative path is rarely reached.
            if let package = packageOwner(rest) {
                if let separator = rest.range(of: ": ", range: rest.index(rest.startIndex, offsetBy: package.count)..<rest.endIndex) {
                    verdict.failed[package] = String(rest[separator.upperBound...])
                    verdict.extracted.remove(package)
                } else if verdict.failed[package] == nil {
                    verdict.extracted.insert(package)
                }
                continue
            }
            verdict.unrecognized.append(line)
        }
        // A package with a failed descendant is failed even if the package's
        // own directory record was announced cleanly.
        for (path, _) in verdict.failed { verdict.extracted.remove(path) }
        return verdict
    }

    private static func trimSlash(_ name: String) -> String {
        name.hasSuffix("/") ? String(name.dropLast()) : name
    }

    /// bsdtar removes a leading `/` and a drive letter before it reports.
    private static func strippedPrefix(_ raw: String) -> String {
        var text = raw
        let characters = Array(text)
        if characters.count >= 2, characters[1] == ":", characters[0].isLetter { text = String(characters.dropFirst(2)) }
        while text.hasPrefix("/") { text.removeFirst() }
        return text
    }
}

import Foundation
import Darwin

/// Reads a file and says whether it contains a piece of text.
///
/// This is the half of content search that does not ask Spotlight. It exists
/// because the index cannot report "this folder is not indexed" — an unindexed
/// external drive and a folder with no matches both come back as zero results
/// (D85). Scanning reads the bytes instead, so it works anywhere, and pays for
/// it in time.
///
/// Every read is bounded and every file is opened defensively, because a
/// search walks whatever the user points it at: a FIFO that would block
/// forever on open, a device node, a 40 GB disk image, a file being rewritten
/// underneath. The primitives are the ones `TextThumbnailRenderer` already
/// uses for the same reasons; this is the tree-wide version of them.
///
/// A pure function of a file's bytes, so it is checked without a file view and
/// mostly without the filesystem.
enum ContentScanner {

    /// How much of one file is read. A match further in is missed; the search
    /// says so rather than implying it read everything.
    static let maximumBytes = 1_048_576          // 1 MB

    /// A file is skipped outright past this size: a match inside a disk image
    /// or a video container is not what "search file contents" means, and
    /// reading the first megabyte of thousands of them is pure cost.
    static let maximumFileSize: off_t = 64 * 1_048_576

    enum Outcome: Equatable {
        case match
        case noMatch
        /// Read, but only the leading `maximumBytes`; a later match is unseen.
        case truncated(matched: Bool)
        /// Not text, too large, unreadable, or not a regular file.
        case skipped(Reason)

        enum Reason: String, Equatable {
            case binary, tooLarge, unreadable, notRegular, empty, notDownloaded
        }
    }

    /// Decides from the bytes alone, so it can be checked without a file.
    ///
    /// A NUL byte in the leading bytes is the standard "this is binary" test
    /// and is what `grep` uses. UTF-16 text is full of them, so a byte-order
    /// mark is honoured first — otherwise every UTF-16 document would be
    /// called binary and silently skipped.
    static func looksBinary(_ data: Data) -> Bool {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { return false }
        return data.prefix(8_000).contains(0)
    }

    /// The needle in the haystack, matched the way the rest of search matches:
    /// case- and diacritic-insensitive, literal — never interpreted as a
    /// pattern, so a user's `.` or `*` finds a dot or a star.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Scans `data` as text. Separate from the file handling so the decision
    /// logic is checkable from a literal.
    static func scan(_ data: Data, for needle: String, wasTruncated: Bool) -> Outcome {
        guard !data.isEmpty else { return .skipped(.empty) }
        guard !looksBinary(data) else { return .skipped(.binary) }
        // `TextThumbnailRenderer.decode` is deliberately strict — it refuses
        // anything that is not clean UTF-8 or BOM UTF-16, and refuses control
        // characters outright — because a thumbnail of doubtful bytes is worse
        // than none. A search must not lose a result for that reason: a note
        // saved as Windows-1252 and an ANSI-coloured build log are both text a
        // user expects to find. Decoding leniently keeps every ASCII byte, so
        // the NUL test above stays the one rule for "not text".
        let text = TextThumbnailRenderer.decode(data, isTruncated: wasTruncated)
            ?? String(decoding: data, as: UTF8.self)
        let matched = contains(text, needle)
        return wasTruncated ? .truncated(matched: matched) : (matched ? .match : .noMatch)
    }

    /// Reads `url` far enough to answer, defensively.
    ///
    /// Opening non-blocking and checking `fstat` before reading is what keeps a
    /// FIFO from hanging the search forever and a device node from being read
    /// at all; `O_NONBLOCK` alone is not enough, because the fd must also be
    /// proven to be a regular file before the first `read`.
    static func scanFile(at url: URL, for needle: String) -> Outcome {
        guard url.isFileURL else { return .skipped(.unreadable) }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { return .skipped(.unreadable) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return .skipped(.unreadable) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return .skipped(.notRegular) }
        guard metadata.st_size > 0 else { return .skipped(.empty) }
        guard metadata.st_size <= maximumFileSize else { return .skipped(.tooLarge) }
        // A cloud placeholder — iCloud's "Optimize Mac Storage", Dropbox Smart
        // Sync, OneDrive Files On-Demand — has real metadata and no bytes on
        // disk, and `read` materialises it: the whole file, over the network,
        // while the walk waits. Searching a folder is not permission to
        // download it, so these are counted and passed over.
        guard metadata.st_flags & UInt32(SF_DATALESS) == 0 else { return .skipped(.notDownloaded) }

        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { return .skipped(.unreadable) }
        let data = Data(bytes.prefix(count))
        return scan(data, for: needle, wasTruncated: metadata.st_size > off_t(count))
    }

    /// Running totals a search reports when it ends, so the user is told what
    /// was not looked at rather than left to assume it was.
    struct Tally: Equatable {
        var scanned = 0
        var matched = 0
        var truncated = 0
        var binary = 0
        var notDownloaded = 0
        var tooLarge = 0
        var unreadable = 0

        mutating func record(_ outcome: Outcome) {
            scanned += 1
            switch outcome {
            case .match: matched += 1
            case .noMatch: break
            case .truncated(let matched):
                truncated += 1
                if matched { self.matched += 1 }
            case .skipped(let reason):
                switch reason {
                case .binary: binary += 1
                case .notDownloaded: notDownloaded += 1
                case .tooLarge: tooLarge += 1
                case .unreadable, .notRegular: unreadable += 1
                case .empty: break
                }
            }
        }

        /// Only the parts that happened, so an ordinary search says nothing
        /// alarming and an unusual one explains itself.
        var summary: String {
            var parts: [String] = []
            if binary > 0 { parts.append("\(binary) binary file\(binary == 1 ? "" : "s") skipped") }
            if tooLarge > 0 { parts.append("\(tooLarge) over \(maximumFileSize / 1_048_576) MB skipped") }
            if notDownloaded > 0 {
                parts.append("\(notDownloaded) not downloaded from the cloud")
            }
            if truncated > 0 {
                parts.append("\(truncated) read only to \(maximumBytes / 1024) KB")
            }
            if unreadable > 0 { parts.append("\(unreadable) unreadable") }
            return parts.isEmpty ? "" : parts.joined(separator: ", ") + "."
        }
    }
}

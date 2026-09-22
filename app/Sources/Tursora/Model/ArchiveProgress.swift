import Foundation

/// Turns bsdtar's verbose extraction stream into determinate progress.
///
/// Two facts shape this, both measured rather than assumed (see
/// docs/research/archive-extraction-progress.md):
///
/// 1. `tar -x -v` announces an entry when it **opens** it, not when it finishes
///    it. So the bytes credited are every announced entry except the last, plus
///    however much of the last one is on disk right now.
/// 2. An error line also begins with `x ` —
///    `x ../../outside.txt: Path contains '..': Unknown error: -1` — so the
///    progress lines can only be filtered out by matching a whole known name.
struct ArchiveExtractionProgress {
    private let entries: [ArchiveEntrySummary]
    private let sizes: [String: Int64]
    private var cursor = 0
    private(set) var totalBytes: Int64?
    private(set) var currentEntry: ArchiveEntrySummary?
    /// Bytes of entries already announced and therefore finished.
    private var settledBytes: Int64 = 0

    init(entries: [ArchiveEntrySummary]) {
        self.entries = entries
        var sizes: [String: Int64] = [:]
        for entry in entries where entry.countsTowardBytes { sizes[entry.name] = entry.uncompressedSize }
        self.sizes = sizes
        // An empty or unparsable listing means no total, never a total of zero:
        // a zero total would show a bar sitting at 100% from the first moment.
        let total = entries.filter(\.countsTowardBytes).reduce(Int64(0)) { $0 + $1.uncompressedSize }
        totalBytes = entries.isEmpty ? nil : total
    }

    var knownNames: Set<String> { Set(entries.map(\.name)) }

    /// A whole line of the tool's stderr. Returns the entry it announced, or
    /// nil if the line is not a progress line at all.
    @discardableResult
    mutating func consume(verboseLine line: String) -> ArchiveEntrySummary? {
        guard line.hasPrefix("x ") else { return nil }
        let name = String(line.dropFirst(2))
        guard let entry = take(named: name) else {
            // Something is being written that the listing never mentioned, so
            // the total cannot be trusted. Fall back to indeterminate rather
            // than report a percentage that will overshoot.
            totalBytes = nil
            currentEntry = nil
            return nil
        }
        if let previous = currentEntry, previous.countsTowardBytes {
            settledBytes += previous.uncompressedSize
        }
        currentEntry = entry
        return entry
    }

    /// Duplicate names inside one archive are legal, so entries are consumed in
    /// listing order — which is the order bsdtar writes them — and only fall
    /// back to a search when the stream and the listing disagree.
    private mutating func take(named name: String) -> ArchiveEntrySummary? {
        if cursor < entries.count, entries[cursor].name == name {
            defer { cursor += 1 }
            return entries[cursor]
        }
        if let ahead = entries[cursor...].firstIndex(where: { $0.name == name }) {
            cursor = ahead + 1
            return entries[ahead]
        }
        guard sizes[name] != nil || entries.contains(where: { $0.name == name }) else { return nil }
        return entries.first { $0.name == name }
    }

    /// `currentFileSize` is what the entry being written measures on disk now.
    /// The result is clamped and monotonic: a growing file must never push the
    /// bar past the entry's own size, nor past the total.
    func completedBytes(currentFileSize: Int64 = 0) -> Int64 {
        var bytes = settledBytes
        if let current = currentEntry, current.countsTowardBytes {
            bytes += min(max(currentFileSize, 0), current.uncompressedSize)
        }
        guard let totalBytes else { return max(bytes, 0) }
        return min(max(bytes, 0), totalBytes)
    }

    /// The path the entry being written occupies, relative to the output root.
    func currentEntryURL(in root: URL) -> URL? {
        currentEntry.map { root.appendingPathComponent($0.name) }
    }

    /// What the tool actually complained about, with its progress lines removed.
    /// Only lines that are exactly `"x " + a known name` are dropped, because a
    /// traversal refusal is reported on a line that also starts with `x `.
    static func errorDetail(from log: String, knownEntries: Set<String>) -> String? {
        let kept = log.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let text = String(line)
            guard text.hasPrefix("x ") else { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
            return !knownEntries.contains(String(text.dropFirst(2)))
        }
        let detail = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? nil : detail
    }
}

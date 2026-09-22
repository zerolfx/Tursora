import Foundation

/// Per-entry modification dates, read from a ZIP's central directory.
///
/// Used **only** to join dates onto an `ArchiveTree` by normalized path, and
/// never as the listing itself: the listing has to agree with what bsdtar will
/// extract, and bsdtar's own `tar -tvf` does by construction (D90, D92). A miss
/// here is harmless — the row simply has no date — which is what makes a
/// hand-written reader acceptable for this and not for that.
///
/// It has to agree with the extractor too, or a date shown before an entry is
/// materialized would change the moment it is. So precedence mirrors
/// libarchive's: the DOS date and time first, in local time, then any Unix
/// timestamp extra field overrides it — `0x5455` (Info-ZIP extended timestamp),
/// `0x5855` (Info-ZIP Unix, which `ditto` and therefore Finder's Compress write)
/// and `0x000d` (PKWARE Unix). NTFS `0x000a` is deliberately not read, because
/// libarchive does not read it either.
///
/// `tar -tvf`'s own date column cannot substitute: it shows hours and minutes
/// only within ±182 days of now and the year alone outside that, and it always
/// drops the seconds (measured). See docs/research/lazy-zip-browsing.md.
enum ZIPCentralDirectory {
    /// A central directory larger than this is not read at all. At the measured
    /// ~80 bytes a record, it is several hundred thousand entries.
    static let maximumDirectoryBytes = 64 * 1024 * 1024
    /// The end record is 22 bytes plus a comment of at most 65,535.
    private static let endRecordSearchBytes = 22 + 65_535

    /// Dates keyed by the same normalized path `ArchiveTree` uses. Never throws:
    /// an unreadable or malformed archive yields whatever was parsed before the
    /// problem, or nothing.
    static func modificationDates(of archive: URL, timeZone: TimeZone = .current) -> [String: Date] {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return [:] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 22 else { return [:] }
        guard let location = centralDirectoryLocation(handle: handle, fileSize: size) else { return [:] }
        guard location.size <= UInt64(maximumDirectoryBytes),
              location.offset + location.size <= size else { return [:] }
        try? handle.seek(toOffset: location.offset)
        guard let directory = try? handle.read(upToCount: Int(location.size)),
              directory.count == Int(location.size) else { return [:] }
        return parse(directory, timeZone: timeZone)
    }

    /// Pure: parse central directory records already in memory.
    static func parse(_ data: Data, timeZone: TimeZone = .current) -> [String: Date] {
        let bytes = [UInt8](data)
        var dates: [String: Date] = [:]
        var position = 0
        while position + 46 <= bytes.count, u32(bytes, position) == 0x02014b50 {
            let dosTimeField = u16(bytes, position + 12)
            let dosDateField = u16(bytes, position + 14)
            let nameLength = Int(u16(bytes, position + 28))
            let extraLength = Int(u16(bytes, position + 30))
            let commentLength = Int(u16(bytes, position + 32))
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= bytes.count else { break }
            defer { position = next }

            // Bit 11 declares UTF-8; an archive that does not set it but whose
            // name is still valid UTF-8 is read the same way bsdtar reads it.
            // Anything else is a harmless miss rather than a guessed decoding.
            guard let name = String(bytes: bytes[nameStart..<extraStart], encoding: .utf8),
                  let normalized = ArchiveTree.normalize(name) else { continue }
            let key = normalized.components.joined(separator: "/")

            var date = Self.dosDate(dosDateField, time: dosTimeField, timeZone: timeZone)
            if let unix = unixModificationTime(bytes, from: extraStart, length: extraLength) {
                date = Date(timeIntervalSince1970: TimeInterval(unix))
            }
            // Last wins, matching both the tree and what extraction yields.
            if let date { dates[key] = date }
        }
        return dates
    }

    // MARK: - Locating the directory

    private struct Location { let offset: UInt64; let size: UInt64 }

    private static func centralDirectoryLocation(handle: FileHandle, fileSize: UInt64) -> Location? {
        let tailLength = min(fileSize, UInt64(endRecordSearchBytes))
        let tailStart = fileSize - tailLength
        try? handle.seek(toOffset: tailStart)
        guard let tailData = try? handle.read(upToCount: Int(tailLength)) else { return nil }
        let tail = [UInt8](tailData)
        // Search backwards, and require the declared comment to end exactly at
        // the end of the file, so a signature inside a comment is not taken.
        var index = tail.count - 22
        while index >= 0 {
            if u32(tail, index) == 0x06054b50,
               index + 22 + Int(u16(tail, index + 20)) == tail.count {
                let entries = u16(tail, index + 10)
                let size = u32(tail, index + 12)
                let offset = u32(tail, index + 16)
                if entries == 0xFFFF || size == 0xFFFFFFFF || offset == 0xFFFFFFFF {
                    return zip64Location(handle: handle, endRecordAt: tailStart + UInt64(index))
                }
                return Location(offset: UInt64(offset), size: UInt64(size))
            }
            index -= 1
        }
        return nil
    }

    /// The ZIP64 locator sits in the 20 bytes immediately before the end record
    /// and points at the ZIP64 end record, which holds 64-bit offset and size.
    private static func zip64Location(handle: FileHandle, endRecordAt endRecord: UInt64) -> Location? {
        guard endRecord >= 20 else { return nil }
        try? handle.seek(toOffset: endRecord - 20)
        guard let locatorData = try? handle.read(upToCount: 20), locatorData.count == 20 else { return nil }
        let locator = [UInt8](locatorData)
        guard u32(locator, 0) == 0x07064b50 else { return nil }
        let recordOffset = u64(locator, 8)
        try? handle.seek(toOffset: recordOffset)
        guard let recordData = try? handle.read(upToCount: 56), recordData.count == 56 else { return nil }
        let record = [UInt8](recordData)
        guard u32(record, 0) == 0x06064b50 else { return nil }
        return Location(offset: u64(record, 48), size: u64(record, 40))
    }

    // MARK: - Timestamps

    /// DOS date and time are local time with two-second resolution, and
    /// libarchive interprets them in the local time zone.
    static func dosDate(_ date: UInt16, time: UInt16, timeZone: TimeZone) -> Date? {
        var components = DateComponents()
        components.year = Int(date >> 9) + 1980
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int(time >> 11)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        guard (1...12).contains(components.month!), (1...31).contains(components.day!) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    /// The Unix modification time from whichever extra field carries one, in
    /// libarchive's order of processing: a later field overrides an earlier one.
    static func unixModificationTime(_ bytes: [UInt8], from start: Int, length: Int) -> Int64? {
        var result: Int64?
        var position = start
        let end = start + length
        while position + 4 <= end {
            let id = u16(bytes, position)
            let size = Int(u16(bytes, position + 2))
            let data = position + 4
            guard data + size <= end else { break }
            switch id {
            case 0x5455 where size >= 5 && bytes[data] & 0x01 != 0:
                // Extended timestamp: a flags byte, then mtime when bit 0 is set.
                result = Int64(Int32(bitPattern: u32(bytes, data + 1)))
            case 0x5855 where size >= 8:
                // Info-ZIP Unix (type 1): atime, then mtime.
                result = Int64(Int32(bitPattern: u32(bytes, data + 4)))
            case 0x000d where size >= 8:
                // PKWARE Unix: atime, then mtime.
                result = Int64(Int32(bitPattern: u32(bytes, data + 4)))
            default:
                break
            }
            position = data + size
        }
        return result
    }

    // MARK: - Little-endian readers, bounds-checked by their callers

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 2 <= b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        guard i + 8 <= b.count else { return 0 }
        return UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32
    }
}

import Foundation

/// Durable presentation only. Filters, selection, scroll offsets and navigation
/// history belong to the pane and must never be copied into this value.
struct DirectoryViewProperties: Codable, Equatable {
    var viewMode: ViewMode = .details
    var detailsZoomIndex = ZoomLevel.defaultIndex(for: .details)
    var iconsZoomIndex = ZoomLevel.defaultIndex(for: .icons)
    var sortKey: DirectoryModel.SortKey = .name
    var ascending = true
    var groupKey: GroupKey = .none
    var lastGroupKey: GroupKey = .kind
    var showHidden = false
    var showPreviews = true

    init() {}

    /// Migrate existing preferences once, when the application library is absent.
    /// Restoring directory properties never writes back to these legacy keys.
    static var legacyDefaults: Self {
        var result = Self()
        result.viewMode = ViewPreferences.viewMode
        result.detailsZoomIndex = ViewPreferences.zoomIndex(for: .details)
        result.iconsZoomIndex = ViewPreferences.zoomIndex(for: .icons)
        result.groupKey = ViewPreferences.groupKey
        result.lastGroupKey = ViewPreferences.lastGroupKey
        result.showPreviews = ViewPreferences.showPreviews
        return result.normalized
    }

    func zoomIndex(for mode: ViewMode) -> Int {
        ZoomLevel.clamp(mode == .details ? detailsZoomIndex : iconsZoomIndex, for: mode)
    }

    mutating func setZoomIndex(_ index: Int, for mode: ViewMode) {
        if mode == .details { detailsZoomIndex = ZoomLevel.clamp(index, for: mode) }
        else { iconsZoomIndex = ZoomLevel.clamp(index, for: mode) }
    }

    fileprivate var normalized: Self {
        var result = self
        result.detailsZoomIndex = zoomIndex(for: .details)
        result.iconsZoomIndex = zoomIndex(for: .icons)
        if result.lastGroupKey == .none { result.lastGroupKey = .kind }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case viewMode, detailsZoomIndex, iconsZoomIndex, sortKey, ascending
        case groupKey, lastGroupKey, showHidden, showPreviews
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try? values.decode(String.self, forKey: .viewMode),
           let value = ViewMode(rawValue: raw) { viewMode = value }
        if let value = try? values.decode(Int.self, forKey: .detailsZoomIndex) {
            setZoomIndex(value, for: .details)
        }
        if let value = try? values.decode(Int.self, forKey: .iconsZoomIndex) {
            setZoomIndex(value, for: .icons)
        }
        if let raw = try? values.decode(String.self, forKey: .sortKey),
           let value = DirectoryModel.SortKey(rawValue: raw) { sortKey = value }
        if let value = try? values.decode(Bool.self, forKey: .ascending) { ascending = value }
        if let raw = try? values.decode(String.self, forKey: .groupKey),
           let value = GroupKey(rawValue: raw) { groupKey = value }
        if let raw = try? values.decode(String.self, forKey: .lastGroupKey),
           let value = GroupKey(rawValue: raw), value != .none { lastGroupKey = value }
        if let value = try? values.decode(Bool.self, forKey: .showHidden) { showHidden = value }
        if let value = try? values.decode(Bool.self, forKey: .showPreviews) { showPreviews = value }
    }

    func encode(to encoder: Encoder) throws {
        let value = normalized
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(value.viewMode.rawValue, forKey: .viewMode)
        try values.encode(value.detailsZoomIndex, forKey: .detailsZoomIndex)
        try values.encode(value.iconsZoomIndex, forKey: .iconsZoomIndex)
        try values.encode(value.sortKey.rawValue, forKey: .sortKey)
        try values.encode(value.ascending, forKey: .ascending)
        try values.encode(value.groupKey.rawValue, forKey: .groupKey)
        try values.encode(value.lastGroupKey.rawValue, forKey: .lastGroupKey)
        try values.encode(value.showHidden, forKey: .showHidden)
        try values.encode(value.showPreviews, forKey: .showPreviews)
    }
}

/// Application-owned storage: browsing read-only folders never creates sidecars
/// or xattrs in them. All state and disk writes share one serial queue, so a
/// delayed older snapshot cannot overwrite a newer navigation's settings.
final class DirectoryViewPropertiesStore {
    enum Policy: String, Codable { case perDirectory, unified }

    static let didChange = Notification.Name("Tursora.directoryViewPropertiesChanged")

    static let shared: DirectoryViewPropertiesStore = {
        let manager = FileManager.default
        if SmokeTest.isRequested {
            let root = manager.temporaryDirectory.appendingPathComponent(
                "tursora-view-properties-smoke-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true)
            return DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("DirectoryViewProperties.json"))
        }
        let root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tursora", isDirectory: true)
        return DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("DirectoryViewProperties.json"),
                                            initialDefaults: .legacyDefaults)
    }()

    let fileURL: URL
    private let queue = DispatchQueue(label: "com.tursora.directory-view-properties", qos: .utility)
    private var storedDefaults: DirectoryViewProperties
    private var storedPolicy: Policy = .perDirectory
    private var directories: [String: DirectoryViewProperties] = [:]
    private var dirty = false
    private var writeGeneration: UInt64 = 0
    private var writeError: Error?

    var defaultProperties: DirectoryViewProperties { queue.sync { storedDefaults } }
    var policy: Policy { queue.sync { storedPolicy } }
    var lastWriteError: Error? { queue.sync { writeError } }

    init(fileURL: URL, initialDefaults: DirectoryViewProperties = .init()) {
        self.fileURL = fileURL
        storedDefaults = initialDefaults.normalized
        // A read is never a mutation. In particular, retain unreadable, corrupt,
        // old and future-format files until an explicit effective user change.
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1 else { return }
        storedDefaults = document.defaultProperties ?? storedDefaults
        storedPolicy = document.policy
        directories = document.directories
    }

    /// Callers must mark ZIP/search logical pages virtual. Never pass their
    /// backing extraction or indexing directory as an ordinary location.
    /// Symlinks share the resolved path's settings; Finder aliases share them
    /// only after navigation resolves their target. Renames/moves do not follow
    /// inode identity, and a replacement mount at the same path reuses records.
    static func directoryKey(for url: URL, isVirtual: Bool = false) -> String? {
        guard !isVirtual, url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.path.hasPrefix("/"), !url.path.contains("\0") else { return nil }
        // Rebuild from the decoded path to strip query, fragment and directory
        // URL hints. Root stays '/', while other keys have no trailing slash.
        return URL(fileURLWithPath: url.path).standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    func properties(forKey key: String?) -> DirectoryViewProperties {
        queue.sync {
            guard storedPolicy == .perDirectory, let key else { return storedDefaults }
            return directories[key] ?? storedDefaults
        }
    }

    /// Ordinary directory edits intentionally do not notify other panes. The
    /// last edit wins for the next entry; already-open panes stay independent.
    func save(_ properties: DirectoryViewProperties, forKey key: String) {
        let notifyDefault: Bool = queue.sync {
            let value = properties.normalized
            if storedPolicy == .unified {
                guard value != storedDefaults else { return false }
                storedDefaults = value
                scheduleWrite()
                return true
            }
            guard directories[key] != value else { return false }
            directories[key] = value
            scheduleWrite()
            return false
        }
        if notifyDefault { notify(reason: "default") }
    }

    func setDefault(_ properties: DirectoryViewProperties) {
        let changed = queue.sync {
            let value = properties.normalized
            guard value != storedDefaults else { return false }
            storedDefaults = value
            scheduleWrite()
            return true
        }
        if changed { notify(reason: "default") }
    }

    func reset(key: String) {
        let changed = queue.sync {
            guard directories.removeValue(forKey: key) != nil else { return false }
            scheduleWrite()
            return true
        }
        if changed { notify(reason: "reset", key: key) }
    }

    func setPolicy(_ policy: Policy) {
        let changed = queue.sync {
            guard policy != storedPolicy else { return false }
            storedPolicy = policy
            scheduleWrite()
            return true
        }
        if changed { notify(reason: "policy") }
    }

    /// Reports a stored record even while unified policy temporarily ignores it.
    func hasOverride(forKey key: String) -> Bool { queue.sync { directories[key] != nil } }

    /// A persistence barrier for application termination and restart tests.
    /// Failed writes keep dirty state, so a later flush can retry safely.
    func flush() throws {
        try queue.sync {
            writeGeneration &+= 1
            try writeIfNeeded()
        }
    }

    private func scheduleWrite() {
        dirty = true
        writeGeneration &+= 1
        let generation = writeGeneration
        queue.asyncAfter(deadline: .now() + 0.15) { [self] in
            guard generation == writeGeneration else { return }
            try? writeIfNeeded()
        }
    }

    private func writeIfNeeded() throws {
        guard dirty else { return }
        do {
            let document = Document(defaultProperties: storedDefaults, policy: storedPolicy, directories: directories)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            dirty = false
            let recovered = writeError != nil
            writeError = nil
            if recovered { DispatchQueue.main.async { self.notify(reason: "writeStatus") } }
        } catch {
            writeError = error
            DispatchQueue.main.async { self.notify(reason: "writeStatus") }
            throw error
        }
    }

    private func notify(reason: String, key: String? = nil) {
        var info: [String: Any] = ["reason": reason]
        if let key { info["key"] = key }
        // Post outside the state queue; observers are free to query the store
        // or restore panes without recursive queue.sync or write-back loops.
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: info)
    }

    private struct Document: Codable {
        let version: Int
        let defaultProperties: DirectoryViewProperties?
        let policy: Policy
        let directories: [String: DirectoryViewProperties]

        init(defaultProperties: DirectoryViewProperties, policy: Policy,
             directories: [String: DirectoryViewProperties]) {
            version = 1
            self.defaultProperties = defaultProperties
            self.policy = policy
            self.directories = directories
        }

        private enum CodingKeys: String, CodingKey { case version, defaultProperties, policy, directories }
        private struct DirectoryKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            defaultProperties = try? values.decode(DirectoryViewProperties.self, forKey: .defaultProperties)
            policy = (try? values.decode(Policy.self, forKey: .policy)) ?? .perDirectory
            var records: [String: DirectoryViewProperties] = [:]
            if let entries = try? values.nestedContainer(keyedBy: DirectoryKey.self, forKey: .directories) {
                for key in entries.allKeys {
                    if let value = try? entries.decode(DirectoryViewProperties.self, forKey: key) {
                        records[key.stringValue] = value
                    }
                }
            }
            directories = records
        }
    }
}

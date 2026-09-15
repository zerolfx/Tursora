import Foundation
import Darwin

/// Durable navigation only. Tasks, history, selections and view filters belong
/// to the live workspace and are deliberately absent from this document.
struct WorkspaceSessionState: Codable, Equatable {
    static let currentVersion = 1
    static let maximumWindows = 16
    static let maximumTabsPerWindow = 32

    var version: Int = currentVersion
    var windows: [WorkspaceWindowState] = []
    var activeWindowIndex: Int = 0

    func sanitized() -> Self {
        let kept = workspaceEntries(windows.map(Optional.some), selected: activeWindowIndex,
                                    limit: Self.maximumWindows) { $0.sanitized() }
        return Self(version: version, windows: kept.values, activeWindowIndex: kept.selected)
    }

    private enum CodingKeys: String, CodingKey { case version, windows, activeWindowIndex }

    init(version: Int = currentVersion, windows: [WorkspaceWindowState] = [], activeWindowIndex: Int = 0) {
        self.version = version
        self.windows = windows
        self.activeWindowIndex = activeWindowIndex
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        let entries = try values.decode([LossyDecoded<WorkspaceWindowState>].self, forKey: .windows)
        let kept = workspaceEntries(entries.map(\.value),
                                    selected: (try? values.decode(Int.self, forKey: .activeWindowIndex)) ?? 0,
                                    limit: Self.maximumWindows) { $0.sanitized() }
        guard entries.isEmpty || !kept.values.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .windows, in: values,
                                                  debugDescription: "No valid workspace windows remain.")
        }
        windows = kept.values
        activeWindowIndex = kept.selected
    }
}

struct WorkspaceWindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var sanitized: Self? {
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0,
              abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { return nil }
        // Screen placement and the app's actual minimum size are applied by
        // the window controller, after the current displays are known.
        return Self(x: x, y: y, width: min(width, 16_384), height: min(height, 16_384))
    }
}

struct WorkspaceWindowState: Codable, Equatable {
    var tabs: [WorkspaceTabState]
    var selectedTabIndex: Int = 0
    var frame: WorkspaceWindowFrame?
    var sidebarWidth: Double = 190
    var sidebarCollapsed: Bool = false
    var isMiniaturized: Bool = false
    var foldersVisible: Bool = false
    var foldersFraction: Double = 0.45
    var foldersShowHidden: Bool = false
    var foldersLimitToHome: Bool = true
    var previewVisible: Bool = false
    var previewWidth: Double = 360

    init(tabs: [WorkspaceTabState], selectedTabIndex: Int = 0, frame: WorkspaceWindowFrame? = nil,
         sidebarWidth: Double = 190, sidebarCollapsed: Bool = false, isMiniaturized: Bool = false,
         foldersVisible: Bool = false, foldersFraction: Double = 0.45,
         foldersShowHidden: Bool = false, foldersLimitToHome: Bool = true,
         previewVisible: Bool = false, previewWidth: Double = 360) {
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.frame = frame
        self.sidebarWidth = sidebarWidth
        self.sidebarCollapsed = sidebarCollapsed
        self.isMiniaturized = isMiniaturized
        self.foldersVisible = foldersVisible
        self.foldersFraction = foldersFraction
        self.foldersShowHidden = foldersShowHidden
        self.foldersLimitToHome = foldersLimitToHome
        self.previewVisible = previewVisible
        self.previewWidth = previewWidth
    }

    func sanitized() -> Self? {
        let kept = workspaceEntries(tabs.map(Optional.some), selected: selectedTabIndex,
                                    limit: WorkspaceSessionState.maximumTabsPerWindow) { $0.sanitized() }
        guard !kept.values.isEmpty else { return nil }
        return Self(tabs: kept.values, selectedTabIndex: kept.selected, frame: frame?.sanitized,
                    sidebarWidth: sidebarWidth.isFinite ? min(600, max(100, sidebarWidth)) : 190,
                    sidebarCollapsed: sidebarCollapsed, isMiniaturized: isMiniaturized,
                    foldersVisible: foldersVisible,
                    foldersFraction: foldersFraction.isFinite ? min(0.8, max(0.2, foldersFraction)) : 0.45,
                    foldersShowHidden: foldersShowHidden, foldersLimitToHome: foldersLimitToHome,
                    previewVisible: previewVisible,
                    previewWidth: previewWidth.isFinite ? min(720, max(220, previewWidth)) : 360)
    }

    private enum CodingKeys: String, CodingKey {
        case tabs, selectedTabIndex, frame, sidebarWidth, sidebarCollapsed, isMiniaturized
        case foldersVisible, foldersFraction, foldersShowHidden, foldersLimitToHome
        case previewVisible, previewWidth
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try values.decode([LossyDecoded<WorkspaceTabState>].self, forKey: .tabs)
        let kept = workspaceEntries(entries.map(\.value),
                                    selected: (try? values.decode(Int.self, forKey: .selectedTabIndex)) ?? 0,
                                    limit: WorkspaceSessionState.maximumTabsPerWindow) { $0.sanitized() }
        tabs = kept.values
        selectedTabIndex = kept.selected
        frame = (try? values.decode(WorkspaceWindowFrame.self, forKey: .frame))?.sanitized
        let width = (try? values.decode(Double.self, forKey: .sidebarWidth)) ?? 190
        sidebarWidth = width.isFinite ? min(600, max(100, width)) : 190
        sidebarCollapsed = (try? values.decode(Bool.self, forKey: .sidebarCollapsed)) ?? false
        isMiniaturized = (try? values.decode(Bool.self, forKey: .isMiniaturized)) ?? false
        foldersVisible = (try? values.decode(Bool.self, forKey: .foldersVisible)) ?? false
        let fraction = (try? values.decode(Double.self, forKey: .foldersFraction)) ?? 0.45
        foldersFraction = fraction.isFinite ? min(0.8, max(0.2, fraction)) : 0.45
        foldersShowHidden = (try? values.decode(Bool.self, forKey: .foldersShowHidden)) ?? false
        foldersLimitToHome = (try? values.decode(Bool.self, forKey: .foldersLimitToHome)) ?? true
        previewVisible = (try? values.decode(Bool.self, forKey: .previewVisible)) ?? false
        let preview = (try? values.decode(Double.self, forKey: .previewWidth)) ?? 360
        previewWidth = preview.isFinite ? min(720, max(220, preview)) : 360
    }
}

struct WorkspaceTabState: Codable, Equatable {
    var panes: [WorkspacePaneState]
    var activePaneIndex: Int = 0
    var customTitle: String?
    var splitFraction: Double = 0.5

    init(panes: [WorkspacePaneState], activePaneIndex: Int = 0,
         customTitle: String? = nil, splitFraction: Double = 0.5) {
        self.panes = panes
        self.activePaneIndex = activePaneIndex
        self.customTitle = customTitle
        self.splitFraction = splitFraction
    }

    func sanitized() -> Self? {
        let kept = workspaceEntries(panes.map(Optional.some), selected: activePaneIndex, limit: 2) { $0.sanitized() }
        guard !kept.values.isEmpty else { return nil }
        return Self(panes: kept.values, activePaneIndex: kept.selected,
                    customTitle: Self.title(customTitle),
                    splitFraction: splitFraction.isFinite ? min(0.99, max(0.01, splitFraction)) : 0.5)
    }

    private static func title(_ title: String?) -> String? {
        guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(512))
    }

    private enum CodingKeys: String, CodingKey { case panes, activePaneIndex, customTitle, splitFraction }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try values.decode([LossyDecoded<WorkspacePaneState>].self, forKey: .panes)
        let kept = workspaceEntries(entries.map(\.value),
                                    selected: (try? values.decode(Int.self, forKey: .activePaneIndex)) ?? 0,
                                    limit: 2) { $0.sanitized() }
        panes = kept.values
        activePaneIndex = kept.selected
        customTitle = Self.title(try? values.decode(String.self, forKey: .customTitle))
        let fraction = (try? values.decode(Double.self, forKey: .splitFraction)) ?? 0.5
        splitFraction = fraction.isFinite ? min(0.99, max(0.01, fraction)) : 0.5
    }
}

struct WorkspacePaneState: Codable, Equatable {
    var url: URL
    var search: SearchRequest?

    init(url: URL, search: SearchRequest? = nil) {
        self.url = url
        self.search = search
    }

    func sanitized() -> Self? {
        guard let url = Self.localURL(url) else { return nil }
        var request = search
        if var search = request {
            if let root = Self.localURL(search.rootURL), search.name.count <= 8_192,
               search.content.count <= 8_192,
               search.modifiedAfter?.timeIntervalSinceReferenceDate.isFinite != false,
               search.modifiedBefore?.timeIntervalSinceReferenceDate.isFinite != false {
                search.rootURL = root
                request = search.validationError == nil ? search : nil
            } else { request = nil }
        }
        return Self(url: url, search: request)
    }

    /// Validate syntax only: an absent volume, an inaccessible folder and a
    /// logical ZIP member must survive until asynchronous navigation handles it.
    /// Rebuilding a URL strips decorations but never resolves symlinks.
    static func localURL(_ url: URL) -> URL? {
        guard url.baseURL == nil, url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 32_768 else { return nil }
        return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath).standardizedFileURL
    }

    private enum CodingKeys: String, CodingKey { case url, search }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(URL.self, forKey: .url)
        search = try? values.decode(SearchRequest.self, forKey: .search)
    }
}

enum WorkspaceSessionLoadResult: Equatable {
    case missing
    case loaded(WorkspaceSessionState)
    case unsupported(version: Int)
    case corrupt
    case readError(String)
}

/// Small, synchronous snapshots. The application owns capture/debouncing so a
/// final save on quit cannot be overtaken by an older queued write. A read or
/// flush without an explicit save never repairs or replaces the user's file.
final class WorkspaceSessionStore {
    static let maximumFileSize = 2 * 1_024 * 1_024
    static let didChange = Notification.Name("Tursora.workspaceSessionChanged")
    static let shared: WorkspaceSessionStore = {
        if SmokeTest.isRequested { return WorkspaceSessionStore(fileURL: nil) }
        if let path = ProcessInfo.processInfo.environment["TURSORA_UI_TEST_SESSION_FILE"],
           path.hasPrefix("/"), !path.contains("\0") {
            return WorkspaceSessionStore(fileURL: URL(fileURLWithPath: path))
        }
        return WorkspaceSessionStore()
    }()
    static var productionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tursora", isDirectory: true)
            .appendingPathComponent("WorkspaceSession.json")
    }

    let fileURL: URL?
    private(set) var lastError: String? {
        didSet {
            guard lastError != oldValue else { return }
            if Thread.isMainThread { NotificationCenter.default.post(name: Self.didChange, object: self) }
            else {
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
            }
        }
    }
    private var memoryState: WorkspaceSessionState?
    private var pendingState: WorkspaceSessionState?
    private var pendingClear = false

    init(fileURL: URL? = WorkspaceSessionStore.productionURL) { self.fileURL = fileURL }

    func load() -> WorkspaceSessionLoadResult {
        guard let fileURL else {
            return recordLoad(memoryState.map(WorkspaceSessionLoadResult.loaded) ?? .missing)
        }
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return recordLoad(.readError("The workspace session is not a regular file."))
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var bytes = Data()
            while bytes.count <= Self.maximumFileSize {
                guard let chunk = try handle.read(upToCount: min(65_536, Self.maximumFileSize + 1 - bytes.count)),
                      !chunk.isEmpty else { break }
                bytes.append(chunk)
            }
            guard bytes.count <= Self.maximumFileSize else { return recordLoad(.corrupt) }
            data = bytes
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code) {
                return recordLoad(.missing)
            }
            return recordLoad(.readError(error.localizedDescription))
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Version.self, from: data) else { return recordLoad(.corrupt) }
        guard header.version == WorkspaceSessionState.currentVersion else {
            return recordLoad(.unsupported(version: header.version))
        }
        guard let state = try? decoder.decode(WorkspaceSessionState.self, from: data) else { return recordLoad(.corrupt) }
        return recordLoad(.loaded(state))
    }

    private func recordLoad(_ result: WorkspaceSessionLoadResult) -> WorkspaceSessionLoadResult {
        switch result {
        case .missing, .loaded: lastError = nil
        case .unsupported: lastError = "This workspace session was saved by an unsupported app version."
        case .corrupt: lastError = "The saved workspace session could not be read."
        case .readError(let message): lastError = message
        }
        return result
    }

    @discardableResult
    func save(_ state: WorkspaceSessionState) -> Bool {
        // The latest explicit request supersedes an earlier failed mutation,
        // including when it cannot be saved. A later flush must never publish
        // the old workspace after rejecting the user's newer one.
        pendingState = nil
        pendingClear = false
        guard state.version == WorkspaceSessionState.currentVersion else {
            lastError = "Cannot save an unsupported workspace session version."
            return false
        }
        guard state.windows.count <= WorkspaceSessionState.maximumWindows else {
            lastError = "The workspace has more than \(WorkspaceSessionState.maximumWindows) windows. Close some windows to resume saving the workspace."
            return false
        }
        guard state.windows.allSatisfy({ $0.tabs.count <= WorkspaceSessionState.maximumTabsPerWindow }) else {
            lastError = "A window has more than \(WorkspaceSessionState.maximumTabsPerWindow) tabs. Close some tabs to resume saving the workspace."
            return false
        }
        pendingState = state.sanitized()
        return flush()
    }

    @discardableResult
    func clear() -> Bool {
        pendingState = nil
        pendingClear = true
        return flush()
    }

    /// Failed mutations remain pending, allowing a later explicit retry.
    @discardableResult
    func flush() -> Bool {
        guard pendingState != nil || pendingClear else { return true }
        do {
            if let fileURL {
                if pendingClear {
                    // Unlink only the owned file. A directory in its place is
                    // an error, never permission to recursively delete it.
                    let result = fileURL.path.withCString { Darwin.unlink($0) }
                    if result != 0 && errno != ENOENT { throw Self.posixError() }
                } else if let pendingState {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(pendingState)
                    guard data.count <= Self.maximumFileSize else {
                        throw NSError(domain: "Tursora.WorkspaceSession", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "The workspace session is too large to save."])
                    }
                    try Self.writeAtomically(data, to: fileURL)
                }
            } else { memoryState = pendingClear ? nil : pendingState }
            pendingState = nil
            pendingClear = false
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private struct Version: Decodable { var version: Int }

    private static func writeAtomically(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".workspace-session-\(UUID().uuidString).tmp")
        // Open with the final permissions before writing any potentially
        // private path or search text; chmod after publication is too late.
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? manager.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// Decodes to nil instead of failing, so one malformed entry in a saved
/// array or dictionary drops only itself (workspace and directory-view files).
struct LossyDecoded<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Keep the original selection when earlier siblings are malformed. If its
/// own entry is missing, prefer the next surviving sibling, then the last one.
private func workspaceEntries<Value>(_ entries: [Value?], selected: Int, limit: Int,
                                     sanitize: (Value) -> Value?) -> (values: [Value], selected: Int) {
    var kept: [Value] = []
    var originalIndexes: [Int] = []
    for (index, entry) in entries.enumerated() {
        if let entry, let value = sanitize(entry) {
            kept.append(value)
            originalIndexes.append(index)
            if kept.count == limit { break }
        }
    }
    let target = originalIndexes.firstIndex { $0 >= selected } ?? max(0, kept.count - 1)
    return (kept, target)
}

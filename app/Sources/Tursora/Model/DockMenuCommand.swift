import Foundation

/// Fixed destinations remain independent of the active window or selection.
enum DockMenuCommand: CaseIterable {
    case newWindow, downloads, applications

    var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .downloads: return "Downloads"
        case .applications: return "Applications"
        }
    }

    func destination(in directories: DockMenuDirectories) -> URL? {
        switch self {
        case .newWindow: return directories.home
        case .downloads: return directories.downloads
        case .applications: return directories.applications
        }
    }
}

struct DockMenuDirectories {
    let home: URL
    let downloads: URL?
    let applications: URL?

    static func system(home: URL, fileManager: FileManager = .default) -> Self {
        Self(home: home,
             downloads: fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
             applications: fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first)
    }
}

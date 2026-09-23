import Foundation
import Quartz

/// What Quick Look is handed for a ZIP entry whose bytes are still on their
/// way: its name, and no file yet. The data source hands over the file itself
/// once it is here and tells the panel to refresh the item on show (D99), so
/// the panel opens at once instead of waiting for the archive tool.
final class ArchivePendingPreviewItem: NSObject, QLPreviewItem {
    /// Where the entry is in the pane, for the zoom animation's source frame.
    let logicalURL: URL
    private let title: String

    init(logicalURL: URL, title: String) {
        self.logicalURL = logicalURL
        self.title = title
    }

    var previewItemURL: URL! { nil }
    var previewItemTitle: String! { title }
}

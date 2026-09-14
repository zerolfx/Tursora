import Foundation

/// A tab's displayed name. A split tab keeps its two folder names apart so the
/// strip can draw a real divider between them rather than spelling one with a
/// "|" character, which truncated like text and read as part of a name (D78).
///
/// `plain` is the single-string form, still joined with "|". It is what the
/// Rename Tab sheet shows and what the All Tabs overflow menu lists, and it is
/// the fallback tooltip when a caller supplies none. It is NOT the tab tooltip
/// the app actually shows — `TabPage.tabToolTip` builds that from the two panes'
/// full paths — and NOT what the session store saves, which keeps only a
/// user-typed custom title.
struct TabTitle: Equatable {
    static let plainSeparator = " | "

    let left: String
    let right: String?

    init(left: String, right: String? = nil) {
        self.left = left
        self.right = right
    }

    /// A name that is not split, such as one the user typed.
    init(_ plain: String) { self.init(left: plain, right: nil) }

    var isSplit: Bool { right != nil }

    var plain: String { right.map { left + Self.plainSeparator + $0 } ?? left }

    /// VoiceOver reads a drawn divider as nothing at all, so the two names are
    /// joined by a comma rather than by the character the strip no longer draws.
    var accessibilityLabel: String { right.map { left + ", " + $0 } ?? left }
}

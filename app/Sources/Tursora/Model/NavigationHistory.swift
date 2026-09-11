import Foundation

/// Back/forward history for one tab, modelled on Dolphin's KCoreUrlNavigator:
/// a linear list plus an index, where navigating from the middle truncates the
/// forward entries. Each entry carries an opaque view state so returning to a
/// directory restores the previous selection.
final class NavigationHistory {

    struct Entry {
        var url: URL
        var selectedName: String?
        var scrollOffset: CGFloat = 0
    }

    private(set) var entries: [Entry] = []
    private(set) var index: Int = -1

    var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    var currentURL: URL? { current?.url }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// Push a new location. A repeat of the current URL is ignored so that
    /// reloading does not pollute history.
    func push(_ url: URL) {
        if let current, current.url.standardizedFileURL == url.standardizedFileURL { return }
        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(Entry(url: url))
        index = entries.count - 1
        trim()
    }

    @discardableResult func goBack() -> URL? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index].url
    }

    @discardableResult func goForward() -> URL? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index].url
    }

    /// Jump directly to a history slot — backs the toolbar button's long-press menu.
    @discardableResult func go(to slot: Int) -> URL? {
        guard entries.indices.contains(slot) else { return nil }
        index = slot
        return entries[slot].url
    }

    func recordViewState(selectedName: String?, scrollOffset: CGFloat) {
        guard entries.indices.contains(index) else { return }
        entries[index].selectedName = selectedName
        entries[index].scrollOffset = scrollOffset
    }

    /// Entries behind the current one, nearest first.
    func backEntries(limit: Int = 12) -> [(slot: Int, entry: Entry)] {
        guard index > 0 else { return [] }
        return stride(from: index - 1, through: max(0, index - limit), by: -1)
            .map { ($0, entries[$0]) }
    }

    /// Entries ahead of the current one, nearest first.
    func forwardEntries(limit: Int = 12) -> [(slot: Int, entry: Entry)] {
        guard index < entries.count - 1 else { return [] }
        return stride(from: index + 1, through: min(entries.count - 1, index + limit), by: 1)
            .map { ($0, entries[$0]) }
    }

    private func trim(max: Int = 100) {
        guard entries.count > max else { return }
        let drop = entries.count - max
        entries.removeFirst(drop)
        index -= drop
    }
}

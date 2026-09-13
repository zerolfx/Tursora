import AppKit

/// Optional list columns and folder sizes: the header's right-click menu, the
/// list-side plumbing that shows and hides columns, and the browser/window
/// commands that carry "Calculate all sizes".
///
/// Kept beside `FileListViewController` rather than inside it so the column
/// set, its persistence and its menu stay one readable unit.
extension FileListViewController {

    /// Every column the header menu offers, in table order.
    static var optionalColumns: [Column] { Column.allCases.filter(\.isOptional) }

    /// Apply a persisted column set. Unknown identifiers are dropped, so a
    /// file written by a newer version never hides a column we do have.
    func setVisibleColumns(_ identifiers: [String]) {
        let known = Set(Self.optionalColumns.map(\.rawValue))
        let wanted = Set(identifiers).intersection(known)
        guard wanted != visibleColumns else { return }
        visibleColumns = wanted
        applyColumnVisibility()
    }

    /// Show or hide one optional column and report the change for persistence.
    func setColumn(_ column: Column, visible: Bool) {
        guard column.isOptional else { return }
        let changed = visible ? visibleColumns.insert(column.rawValue).inserted
                              : visibleColumns.remove(column.rawValue) != nil
        guard changed else { return }
        applyColumnVisibility()
        onColumnsChanged?()
    }

    func isColumnVisible(_ column: Column) -> Bool {
        column.isOptional ? visibleColumns.contains(column.rawValue) : true
    }

    /// Push the current set onto the table. Safe before `loadView`: the view
    /// calls this again once its columns exist.
    func applyColumnVisibility() {
        guard isViewLoaded else { return }
        for column in Self.optionalColumns {
            tableView.tableColumn(withIdentifier: column.id)?.isHidden = !visibleColumns.contains(column.rawValue)
        }
    }

    /// A recursive walk makes sense for an ordinary folder listing only.
    var canCalculateFolderSizes: Bool {
        !model.isSearchResults && model.folderSizes.allowsRecursiveSizes
    }

    func setCalculatesAllSizes(_ on: Bool) {
        guard model.folderSizes.calculatesAllSizes != on else { return }
        model.folderSizes.calculatesAllSizes = on
        reloadData()
        onColumnsChanged?()
    }
}

/// The list header's context menu, rebuilt on every open so its checkmarks
/// reflect the pane it belongs to. Finder puts the same two things here: the
/// optional columns and "Calculate all sizes".
final class ListColumnHeaderMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private weak var list: FileListViewController?

    init(list: FileListViewController) {
        self.list = list
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    /// Exposed so a headless test can drive the menu the way a right-click does.
    func rebuild() {
        menu.removeAllItems()
        guard let list else { return }
        for column in FileListViewController.optionalColumns {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = list.isColumnVisible(column) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let sizes = NSMenuItem(title: "Calculate all sizes",
                               action: #selector(toggleCalculateAllSizes(_:)), keyEquivalent: "")
        sizes.target = self
        sizes.state = list.model.folderSizes.calculatesAllSizes ? .on : .off
        sizes.isEnabled = list.canCalculateFolderSizes
        menu.addItem(sizes)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let list, let raw = sender.representedObject as? String,
              let column = FileListViewController.Column(rawValue: raw) else { return }
        list.setColumn(column, visible: !list.isColumnVisible(column))
    }

    @objc private func toggleCalculateAllSizes(_ sender: NSMenuItem) {
        guard let list, list.canCalculateFolderSizes else { return }
        list.setCalculatesAllSizes(!list.model.folderSizes.calculatesAllSizes)
    }
}

extension BrowserViewController {
    /// "Calculate all sizes" applies to an ordinary folder listing, never to a
    /// ZIP's extracted contents or a search result set.
    var canCalculateFolderSizes: Bool {
        canPersistViewProperties && fileList.canCalculateFolderSizes
    }

    /// Persist the column set and the size option like any other view setting.
    func observeListColumns() {
        fileList.onColumnsChanged = { [weak self] in self?.persistViewProperties() }
    }

    func toggleCalculateAllSizes() {
        guard canCalculateFolderSizes else { return }
        fileList.setCalculatesAllSizes(!model.folderSizes.calculatesAllSizes)
    }
}

extension MainWindowController {
    @objc func toggleCalculateAllSizes(_ sender: Any?) { browser.toggleCalculateAllSizes() }
}

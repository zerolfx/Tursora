import AppKit

/// The batch-rename entry points of a browsing pane: presenting Finder's sheet
/// for a multi-selection, applying its plan through FileOperations, and undoing
/// the whole batch as one group.
extension BrowserViewController {

    /// Finder's File-menu wording, singular for one item.
    static func batchRenameTitle(count: Int) -> String { BatchRename.menuTitle(count: count) }

    /// Items a batch rename may touch: real files, never archive entries.
    func batchRenameTargets(_ items: [FileItem]) -> [FileItem] {
        guard canModifySelectedItems else { return [] }
        return items.filter { !$0.isArchiveEntry && $0.canAccess }
    }

    var canBatchRenameSelection: Bool { batchRenameTargets(fileView.selectedItems).count > 1 }

    /// Presents the sheet on the pane's own window. Renames are addressed by
    /// URL, so search results in different folders work like a plain listing.
    @discardableResult
    func presentBatchRename(for items: [FileItem]) -> BatchRenameSheetController? {
        let targets = batchRenameTargets(items)
        guard targets.count > 1, let window = view.window else { return nil }
        let sheetTargets = targets.map {
            BatchRenameSheetController.Target(url: $0.url, name: $0.name,
                                              date: $0.modificationDate ?? $0.creationDate ?? Date())
        }
        let entries = sheetTargets.map { BatchRename.Entry(url: $0.url, date: $0.date) }
        let siblings = FileOperations.siblingNames(forEntries: entries)
        return BatchRenameSheetController.present(targets: sheetTargets, siblings: siblings, in: window) { [weak self] plan in
            self?.applyBatchRename(plan)
        }
    }

    /// The sheet this pane is showing, if any.
    var batchRenameSheet: BatchRenameSheetController? {
        view.window.flatMap { BatchRenameSheetController.presented(in: $0) }
    }

    func applyBatchRename(_ plan: [FileOperations.RenameRequest]) {
        guard canModifySelectedItems, !plan.isEmpty else { return }
        do {
            let pairs = try FileOperations.renameBatch(plan)
            guard !pairs.isEmpty else { return }
            if SmokeTest.isRequested {
                for pair in pairs { print("   renamed \(pair.from.lastPathComponent) → \(pair.to.lastPathComponent)") }
            }
            registerUndoBatchRename(pairs)
            reloadSelectingURLs(selectionAfter(plan, pairs: pairs))
            DirectoryChanges.postRenames(pairs)
        } catch {
            report(error, context: "batch rename")
            reload()
        }
    }

    /// Everything that was in the batch stays selected: renamed items at their
    /// new URL, unchanged ones where they are.
    private func selectionAfter(_ plan: [FileOperations.RenameRequest], pairs: [(from: URL, to: URL)]) -> [URL] {
        var moved: [String: URL] = [:]
        for pair in pairs { moved[pair.from.standardizedFileURL.path] = pair.to }
        return plan.map { moved[$0.url.standardizedFileURL.path] ?? $0.url }
    }

    /// One undo group for the whole batch: undo renames every item back (in
    /// reverse order, through the same two-pass helper, so chains, swaps and
    /// case-only renames replay), and registers the redo.
    func registerUndoBatchRename(_ pairs: [(from: URL, to: URL)], actionName: String = "Rename") {
        guard !pairs.isEmpty else { return }
        registerUndo(actionName: actionName) { me, _ in
            do {
                let replayed = try FileOperations.reverseRenameBatch(pairs)
                me.registerUndoBatchRename(replayed, actionName: actionName)
                me.reloadSelectingURLs(replayed.map(\.to))
                DirectoryChanges.postRenames(replayed)
            } catch {
                me.report(error, context: "undo batch rename")
                me.reload()
            }
        }
    }
}

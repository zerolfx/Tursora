import AppKit

extension BrowserViewController {
    /// File commands must not replace selection while typing a path/name or
    /// using the sidebar. Context-menu actions capture their own targets.
    var hasFileViewFocus: Bool {
        guard !fileView.isRenaming, let responder = view.window?.firstResponder,
              !(responder is NSTextView), !(responder is NSTextField) else { return false }
        return responder === focusView || ((responder as? NSView)?.isDescendant(of: focusView) ?? false)
    }

    @objc func deselectAllFiles(_ sender: Any?) {
        guard hasFileViewFocus else { return }
        fileView.deselectAllItems()
    }

    @objc func invertFileSelection(_ sender: Any?) {
        guard hasFileViewFocus else { return }
        let selected = Set(selectedURLs.map(\.standardizedFileURL))
        let complement = fileView.selectionScopeItems.filter { !selected.contains($0.url.standardizedFileURL) }.map(\.url)
        if complement.isEmpty { fileView.deselectAllItems() }
        else { fileView.select(urls: complement) }
    }

    var canCreateFolderWithSelection: Bool {
        canModifyCurrentLocation && !fileView.selectedItems.isEmpty
            && fileView.selectedItems.allSatisfy { !$0.isArchiveEntry && $0.canAccess }
    }

    @objc func newFolderWithSelection(_ sender: Any?) {
        guard hasFileViewFocus, canCreateFolderWithSelection else { return }
        createFolder(containing: selectedURLs)
    }

    func createFolder(containing urls: [URL]) {
        guard canModifyCurrentLocation, let parent = currentURL, !urls.isEmpty,
              !urls.contains(where: isArchiveContent) else { return }
        do {
            let folder = try FileOperations.createFolder(in: parent)
            transfer(urls, to: folder, kind: .move, actionName: "New Folder with Selection",
                     createdDirectoryForUndo: folder) { [weak self] in
                guard let self, self.currentURL?.standardizedFileURL == parent.standardizedFileURL else { return }
                self.selectAndRenameCreatedFolder(folder)
            }
            DirectoryChanges.post([parent])
        } catch { report(error, context: "new folder with selection") }
    }

    var canShowPackageContents: Bool {
        !isPreparingArchive && !isBrowsingTrash && !isBrowsingArchive
            && fileView.selectedItems.count == 1
            && fileView.selectedItems[0].isPackage && fileView.selectedItems[0].isDirectory
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard hasFileViewFocus, canShowPackageContents, let item = fileView.selectedItems.first else { return }
        navigate(to: item.url)
    }
}

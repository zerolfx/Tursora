import AppKit

/// Filesystem commands, transfer completion and their undo registrations.
/// The pane keeps navigation and listing state; all mutations use FileOperations.
extension BrowserViewController {
    var selectedURLs: [URL] { fileView.selectedItems.map(\.url) }
    private var undo: UndoManager? { view.window?.undoManager }

    // MARK: - File operations

    /// Creates "untitled folder" (or "untitled folder 2", …), selects it and
    /// opens its name for editing once the listing settles — Finder's
    /// behaviour (`setPendingNodesToSelect:startEditing:runNewFolderAnimation:`,
    /// see docs/research/finder-new-folder-rename.md).
    @discardableResult
    func newFolder() -> URL? {
        guard canModifyCurrentLocation, let currentURL else { return nil }
        let url: URL
        do {
            url = try FileOperations.createFolder(in: currentURL)
        } catch {
            report(error, context: "new folder")
            return nil
        }
        registerUndoTrash([url], actionName: "New Folder")
        selectAndRenameCreatedFolder(url)
        DirectoryChanges.post([currentURL])
        return url
    }

    // Edit menu — reached via the responder chain when the list has focus.

    @objc func copy(_ sender: Any?) {
        if isBrowsingArchive { copyArchiveItems(fileView.selectedItems); return }
        putOnPasteboard(selectedURLs, cut: false)
    }
    @objc func cut(_ sender: Any?) { putOnPasteboard(selectedURLs, cut: true) }

    func putOnPasteboard(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty, !isPreparingArchive else { return }
        if cut && (!canModifySelectedItems || isBrowsingTrash || urls.contains(where: isArchiveContent)) { return }
        guard !urls.contains(where: isArchiveContent) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        Self.cutState = cut ? (pb.changeCount, urls) : nil
        setCutMarkers(cut ? Set(urls) : [])
    }

    /// Copy inside an archive. What is already extracted is written at once;
    /// otherwise the pasteboard is claimed now — so the previous Copy cannot
    /// be pasted by mistake while this one is prepared — and written when the
    /// bytes are here, unless something else has been copied meanwhile (D98).
    func copyArchiveItems(_ items: [FileItem]) {
        let readable = items.filter(\.canAccess)
        guard !readable.isEmpty, !isPreparingArchive else { return }
        let pb = NSPasteboard.general
        Self.cutState = nil
        setCutMarkers([])
        let ready = readable.map(\.publishedContentURL)
        // A paste may be read by Finder long after this pane has moved on, so
        // the pasteboard holds hand-off copies (D103).
        if !ready.contains(nil) {
            pb.clearContents()
            let handed = ready.compactMap { $0 }.compactMap(handOff)
            if handed.count < ready.count { reportHandOffFailure() }
            pb.writeObjects(handed as [NSURL])
            return
        }
        let claimed = pb.clearContents()
        requestArchiveBytes(readable.map(\.url), title: Self.readingTitle(readable.map(\.name), from: archiveSourceURL)) { [weak self] result in
            guard pb.changeCount == claimed, !result.urls.isEmpty else { return }
            let handed = result.urls.compactMap { self?.handOff($0) }
            if handed.count < result.urls.count { self?.reportHandOffFailure() }
            pb.writeObjects(handed as [NSURL])
        }
    }

    func setCutMarkers(_ urls: Set<URL>) {
        fileList.cutURLs = urls
        if viewMode == .icons { iconGrid.cutURLs = urls }
        if viewMode == .columns { columnView.cutURLs = urls }
    }

    @objc func paste(_ sender: Any?) {
        pasteFiles(forceMove: false)
    }

    @objc func moveItemsHere(_ sender: Any?) {
        guard hasFileViewFocus else { return }
        pasteFiles(forceMove: true)
    }

    private func pasteFiles(forceMove: Bool) {
        guard canModifyCurrentLocation, let dest = currentURL else { return }
        let pb = NSPasteboard.general
        let urls = pb.fileURLs
        guard !urls.isEmpty else { return }
        let pasteboardGeneration = pb.changeCount
        let isCut = forceMove || Self.cutState?.changeCount == pb.changeCount
        guard !isCut || !urls.contains(where: isArchiveContent) else { return }
        transfer(urls, to: dest, kind: isCut ? .move : .copy) { [weak self] in
            // A later Copy/Cut belongs to a different operation.
            if isCut && pb.changeCount == pasteboardGeneration {
                Self.cutState = nil; pb.clearContents(); self?.setCutMarkers([])
            }
        }
    }

    @objc func duplicate(_ sender: Any?) {
        guard canModifySelectedItems, !isBrowsingTrash, let destination = currentURL else { return }
        transfer(selectedURLs, to: destination, kind: .copy, actionName: "Duplicate", duplicateInPlace: true)
    }

    @objc func moveToTrash(_ sender: Any?) { trash(selectedURLs) }

    func trash(_ urls: [URL]) {
        guard canModifySelectedItems, !isBrowsingTrash, !urls.isEmpty,
              !urls.contains(where: isArchiveContent) else { return }
        // Dolphin selects the next item after deleting; Finder selects nothing. Dolphin wins here.
        let nextURL = fileView.itemAfterSelection()?.url
        let result = FileOperations.trash(urls)
        recordTrash(result, actionName: "Move to Trash")
        reloadSelectingURLs(nextURL.map { [$0] } ?? [])
        FileOperations.report(result.failures, in: view.window)
    }

    @objc func deletePermanently(_ sender: Any?) {
        guard canModifySelectedItems else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Are you sure you want to delete “\(urls[0].lastPathComponent)”?"
            : "Are you sure you want to delete the \(urls.count) selected items?"
        alert.informativeText = "This item will be deleted immediately. You can’t undo this action."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if SmokeTest.isRequested { print("ERROR delete: confirmation unavailable during smoke test"); return }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try FileOperations.delete(urls) } catch { report(error, context: "delete") }
        reload()
        DirectoryChanges.post(DirectoryChanges.affected(sources: urls))
    }

    @objc func renameSelection(_ sender: Any?) {
        guard canModifySelectedItems, !isBrowsingTrash else { return }
        // Finder: several items go to the batch sheet, one is edited in place.
        if fileView.selectedItems.count > 1 { presentBatchRename(for: fileView.selectedItems); return }
        renameSelectionInline(sender)
    }

    /// The Return / click-to-rename path: never opens the batch sheet.
    @objc func renameSelectionInline(_ sender: Any?) {
        guard canModifySelectedItems, !isBrowsingTrash else { return }
        guard let item = fileView.selectedItems.first, fileView.selectedItems.count == 1 else { return }
        fileView.beginRename(item: item)
    }

    static func compressionTitle(for urls: [URL]) -> String {
        urls.count == 1 ? "Compress “\(urls[0].lastPathComponent)”" : urls.isEmpty ? "Compress" : "Compress \(urls.count) Items"
    }
    var compressionTitle: String { Self.compressionTitle(for: selectedURLs) }
    var canExtractSelection: Bool {
        canModifyCurrentLocation && !fileView.selectedItems.isEmpty && fileView.selectedItems.allSatisfy { !$0.isDirectory && FileOperations.canExtractArchive($0.url) }
    }

    @objc func compressSelection(_ sender: Any?) {
        compress(selectedURLs)
    }

    @objc func extractSelection(_ sender: Any?) {
        guard canExtractSelection else { return }
        extract(selectedURLs)
    }

    func compress(_ urls: [URL], completion: (() -> Void)? = nil) {
        guard canModifyCurrentLocation, !urls.isEmpty, let destination = currentURL else { completion?(); return }
        let window = view.window
        let capturedUndo = window?.undoManager
        let task = TransferTask(sources: urls, destination: destination, kind: .compress)
        lastCompressionTask = task
        TransferTasksWindowController.shared.track(task, ownerWindow: window)
        var options = compressionOptions
        options.staging = transferOptions
        statusBar.beginBusy()
        FileOperations.compress(urls: urls, to: destination, task: task, options: options) { [self] result in
            switch result {
            case .success(let url):
                if let capturedUndo { self.registerUndoTrash([url], actionName: "Compress", undo: capturedUndo) }
                if self.currentURL?.standardizedFileURL == destination.standardizedFileURL {
                    self.model.reload { [weak self] in self?.fileView.select(urls: [url]) }
                }
                DirectoryChanges.post([destination])
            case .failure(ArchiveBrowsingSession.SessionError.cancelled), .failure(TransferError.cancelled): break
            case .failure(let error): self.report(error, context: "compress")
            }
            self.statusBar.endBusy()
            completion?()
        }
    }

    /// Each archive gets its own File Operations row with real progress and a
    /// Cancel, and the batch keeps one "Extract" undo group and one directory
    /// broadcast (D90). Archives are still extracted one at a time: several
    /// bsdtar processes writing into the same folder would contend for it and
    /// make each one's progress meaningless.
    func extract(_ archives: [URL], completion: (() -> Void)? = nil) {
        guard canModifyCurrentLocation, !archives.isEmpty else { completion?(); return }
        let startingURL = currentURL
        let window = view.window
        // Captured up front, as `transfer` does: a batch that is still running
        // when its tab closes must still register what it already created.
        let capturedUndo = window?.undoManager
        statusBar.beginBusy()
        var created: [URL] = []
        var failures: [FileOperations.Failure] = []
        let tasks = TransferTasksWindowController.shared

        func finish() {
            self.statusBar.endBusy()
            if let capturedUndo, !created.isEmpty {
                self.registerUndoTrash(created, actionName: "Extract", undo: capturedUndo)
            }
            if self.currentURL == startingURL {
                self.model.reload { [weak self] in self?.fileView.select(urls: created) }
            }
            else { self.reload() }
            DirectoryChanges.post(DirectoryChanges.affected(sources: created))
            FileOperations.report(failures, in: window)
            completion?()
        }

        func next(_ index: Int) {
            guard index < archives.count else { finish(); return }
            let archive = archives[index]
            let destination = archive.deletingLastPathComponent()
            let task = TransferTask(sources: [archive], destination: destination, kind: .extract)
            lastExtractionTask = task
            tasks.track(task, ownerWindow: window, destinationDescription: destination.lastPathComponent)
            task.setPhase(.running, item: archive, detail: "Reading \(archive.lastPathComponent)…")
            FileOperations.extract(
                archive: archive, to: destination, listing: archiveListing,
                onProgress: { bytes, total, entry in
                    DispatchQueue.main.async {
                        if task.snapshot.totalBytes != total { task.setTotal(total) }
                        task.setCompleted(bytes)
                        task.setPhase(.running, item: archive, detail: entry.map { "Extracting \($0)" } ?? "Extracting…")
                    }
                },
                isCancelled: { task.isCancellationRequested },
                pollInterval: self.archiveProgressPollInterval
            ) { result in
                var outcome = FileOperations.TransferResult()
                switch result {
                case .success(let url):
                    created.append(url)
                    outcome.created = [url]
                case .failure(let error):
                    if case FileOperations.ArchiveError.cancelled = error { outcome.cancelled = true }
                    else {
                        failures.append(.init(url: archive, error: error))
                        outcome.failures = [.init(url: archive, error: error)]
                    }
                }
                task.finished(outcome)
                // Cancelling one archive cancels the batch: the alternative is
                // the next ZIP starting the instant the user pressed Cancel.
                if outcome.cancelled { finish() } else { next(index + 1) }
            }
        }
        next(0)
    }

    private func finishArchive(_ result: Result<URL, Error>, destination: URL, actionName: String) {
        switch result {
        case .success(let url):
            registerUndoTrash([url], actionName: actionName)
            if currentURL?.standardizedFileURL == destination.standardizedFileURL {
                model.reload { [weak self] in self?.fileView.select(urls: [url]) }
            }
            DirectoryChanges.post([destination])
        case .failure(let error): report(error, context: actionName.lowercased())
        }
    }

    @objc func quickLook(_ sender: Any?) { toggleQuickLook() }

    func rename(_ item: FileItem, to name: String) {
        guard canModifySelectedItems, !isBrowsingTrash, !item.isArchiveEntry else { return }
        do {
            let newURL = try FileOperations.rename(item.url, to: name)
            registerUndoRename(from: newURL, to: item.name, actionName: "Rename")
            reloadSelectingURLs([newURL])
            DirectoryChanges.post(DirectoryChanges.affected(sources: [item.url]), renamed: (from: item.url, to: newURL))
        } catch {
            report(error, context: "rename")
            reload()
        }
    }

    /// Drop or sidebar-drop: op is .copy or .move.
    func dropFiles(_ urls: [URL], to destination: URL, op: NSDragOperation) {
        guard !ArchiveWorkspace.shared.containsArchiveLocation(destination) else { return }
        transfer(urls, to: destination, kind: op == .copy ? .copy : .move)
    }

    func transfer(_ urls: [URL], to destination: URL, kind: FileOperations.Kind,
                          actionName: String? = nil, duplicateInPlace: Bool = false,
                          createdDirectoryForUndo: URL? = nil,
                          then: (() -> Void)? = nil) {
        guard !ArchiveWorkspace.shared.containsArchiveLocation(destination), !urls.isEmpty else { return }
        if kind == .move && urls.contains(where: isArchiveContent) { return }
        // An archive entry is handed over as where its bytes will be, and the
        // transfer itself brings them first, on its own worker (D98).
        let archiveSources = urls.filter(isArchiveContent)
        let urls = urls.compactMap { isArchiveContent($0) ? try? ArchiveWorkspace.shared.physicalURL(for: $0) : $0 }
        guard !urls.isEmpty else { return }
        statusBar.beginBusy()
        let window = view.window
        let capturedUndo = window?.undoManager
        let name = actionName ?? (kind == .copy ? "Copy" : "Move")
        var options = transferOptions
        options.duplicateInPlace = duplicateInPlace
        // The transfer reads from the ZIP's private copy until it ends (D103).
        let lease = archiveSources.isEmpty ? nil : ArchiveWorkspace.shared.lease(archiveSources)
        if !archiveSources.isEmpty {
            let archiveName = ArchiveWorkspace.shared.archiveURL(containing: archiveSources[0])?.lastPathComponent ?? "the ZIP"
            let prepareArchiveSources = options.prepareSources
            options.prepareSources = { task in
                var failures = try prepareArchiveSources?(task) ?? []
                // No checkpoint of the task's own runs while the archive tool
                // does, so Pause is off for exactly this wait.
                task.setPausable(false)
                task.setPhase(.preparing, detail: "Reading from “\(archiveName)”…")
                defer { task.setPausable(true) }
                let cancellation = ArchivePreparationCancellation()
                task.onCancel { cancellation.cancel() }
                do {
                    failures += try ArchiveWorkspace.shared.materializeBlocking(archiveSources, cancellation: cancellation).failures
                } catch ArchiveBrowsingSession.SessionError.cancelled {
                    throw TransferError.cancelled
                }
                try task.checkpoint()
                return failures
            }
        }
        let task = TransferTask(sources: urls, destination: destination, kind: kind)
        lastTransferTask = task
        let tasks = TransferTasksWindowController.shared
        tasks.track(task, ownerWindow: window,
                    title: duplicateInPlace ? "Duplicate \(task.sources.count) item\(task.sources.count == 1 ? "" : "s")" : nil,
                    destinationDescription: duplicateInPlace ? "Beside each original" : nil)
        FileOperations.transfer(urls, to: destination, kind: kind,
            conflict: { _ in .init(resolution: .cancel) }, task: task, options: options,
            asyncConflict: { conflict, reply in tasks.resolveConflict(for: task, conflict: conflict, reply: reply) }
        ) { [self] result in
            // Retain this pane and its original undo manager through completion,
            // even if the originating tab was closed or another pane is active.
            lease?.release()
            self.statusBar.endBusy()
            var journal = result.journal
            if let folder = createdDirectoryForUndo {
                do { journal = try FileOperations.journalIncludingCreatedDirectory(folder, after: journal) }
                catch { self.report(error, context: "record new folder undo") }
            }
            if let journal, let capturedUndo {
                self.registerTransferUndo(journal, undo: capturedUndo, actionName: name)
            }
            let created = result.created + result.moved.map(\.to)
            if self.isSearching || destination.standardizedFileURL == self.currentURL?.standardizedFileURL {
                self.reloadSelectingURLs(created)
            } else {
                self.reload()
            }
            then?()
            // The source folder is usually another pane, tab or window: tell it.
            DirectoryChanges.post(DirectoryChanges.affected(sources: urls, destination: destination)
                                  + (result.journal?.affectedDirectories ?? []))
            if SmokeTest.isRequested { FileOperations.report(result.failures, in: window) }
        }
    }

    private func registerTransferUndo(_ journal: TransferJournal, undo: UndoManager, actionName: String) {
        registerUndo(on: undo, actionName: actionName) { me, undo in
            do {
                let inverse = try FileOperations.replay(journal)
                me.registerTransferUndo(inverse, undo: undo, actionName: actionName)
                me.reload()
                DirectoryChanges.post(journal.affectedDirectories)
            } catch {
                if let reporter = me.transferReplayErrorReporter { reporter(error) }
                else { me.report(error, context: "undo \(actionName.lowercased())") }
            }
        }
    }

    // Undo — registered on the window's undo manager so Edit ▸ Undo just works.

    /// Every file operation becomes its own undo group. Registrations arrive
    /// from async completions, and NSUndoManager's automatic per-event group
    /// can still be open from an earlier operation — observed in testing: a
    /// Copy and a later Move landed in one group and were undone together,
    /// which trashed the file the Move had just restored. So: close any stale
    /// automatic group (undo() itself does the same), then group explicitly.
    /// Registers `body` as the undo of one operation on `manager` (default: the
    /// window's undo manager); `body` receives the pane and that manager.
    func registerUndo(on manager: UndoManager? = nil, actionName: String,
                              _ body: @escaping (BrowserViewController, UndoManager) -> Void) {
        guard let undo = manager ?? self.undo else { return }
        if !undo.isUndoing, !undo.isRedoing {
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { [weak undo] me in
            guard let undo else { return }
            body(me, undo)
        }
        undo.setActionName(actionName)
        undo.endUndoGrouping()
        // With groupsByEvent on, NSUndoManager wraps a top-level group of ours
        // in an event group that stays open until the run loop turns. Close it
        // now so the operation is complete and self-contained immediately.
        if !undo.isUndoing, !undo.isRedoing {
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
        if SmokeTest.isRequested { print("   [undo] \(actionName) registered (undoing=\(undo.isUndoing), top=\(undo.undoActionName), level=\(undo.groupingLevel))") }
    }

    private func registerUndoMove(_ pairs: [(from: URL, to: URL)], actionName: String,
                                  on manager: UndoManager? = nil, returningToTrash: Bool = false) {
        guard !pairs.isEmpty else { return }
        registerUndo(on: manager, actionName: actionName) { me, undo in
            var reversed: [(from: URL, to: URL)] = []
            for (from, to) in pairs {
                do {
                    try FileOperations.moveItem(at: to, to: from)
                    if returningToTrash { TrashOrigins.shared.record([(original: to, trashed: from)]) }
                    else { TrashOrigins.shared.forget([to]) }
                    reversed.append((from: to, to: from))
                }
                catch { me.report(error, context: "undo move \(to.path) → \(from.path)") }
            }
            me.registerUndoMove(reversed, actionName: actionName, on: undo, returningToTrash: !returningToTrash)
            me.reloadSelectingURLs(reversed.map(\.to))
            DirectoryChanges.post(pairs.flatMap { [$0.from.deletingLastPathComponent(), $0.to.deletingLastPathComponent()] })
        }
    }

    /// Register successful items before reporting any failures. The same path
    /// serves Move to Trash and undoing outputs from compression/extraction.
    private func recordTrash(_ result: FileOperations.TrashResult, actionName: String, undo: UndoManager? = nil) {
        let pairs = result.moved
        TrashOrigins.shared.record(pairs)
        if SmokeTest.isRequested { for pair in pairs { print("   trashed \(pair.original.lastPathComponent) → \(pair.trashed.path)") } }
        registerUndoMove(pairs.map { (from: $0.original, to: $0.trashed) }, actionName: actionName, on: undo)
        DirectoryChanges.post(pairs.flatMap { [$0.original.deletingLastPathComponent(), $0.trashed.deletingLastPathComponent()] })
    }

    private func registerUndoTrash(_ urls: [URL], actionName: String, undo: UndoManager? = nil) {
        guard !urls.isEmpty else { return }
        registerUndo(on: undo, actionName: actionName) { me, manager in
            let result = FileOperations.trash(urls)
            me.recordTrash(result, actionName: actionName, undo: manager)
            me.reload()
            FileOperations.report(result.failures, in: me.view.window)
        }
    }

    private func registerUndoRename(from url: URL, to oldName: String, actionName: String,
                                    on manager: UndoManager? = nil) {
        registerUndo(on: manager, actionName: actionName) { me, undo in
            do {
                let newName = url.lastPathComponent
                let back = try FileOperations.rename(url, to: oldName)
                me.registerUndoRename(from: back, to: newName, actionName: actionName, on: undo)
                me.reloadSelectingURLs([back])
                DirectoryChanges.post(DirectoryChanges.affected(sources: [url, back]), renamed: (from: url, to: back))
            } catch { me.report(error, context: "undo rename"); me.reload() }
        }
    }

}

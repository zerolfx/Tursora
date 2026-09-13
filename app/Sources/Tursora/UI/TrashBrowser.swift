import AppKit

/// Browsing the Trash: the pane's trash-specific state, the access banner,
/// Put Back and Empty Trash. The Trash is an ordinary directory listing — both
/// file views, tabs, split panes, filtering and grouping work unchanged — with
/// Finder's restrictions on what may be created or transformed inside it.
extension BrowserViewController {

    // MARK: - Where we are

    /// True while this pane shows the user's trash or a folder inside it.
    var isBrowsingTrash: Bool {
        guard !isSearching, !isBrowsingArchive, let currentURL else { return false }
        return TrashLocation.isInTrash(currentURL)
    }

    /// Status-bar context, like the archive pane's "ZIP · Read-only".
    var trashStatus: String? { isBrowsingTrash ? TrashLocation.statusContext : nil }

    /// The root this pane's trash location belongs to (the pane may be in a
    /// subfolder of it).
    var currentTrashRoot: URL? { currentURL.flatMap { TrashLocation.trashRoot(containing: $0) } }

    func goTrash() {
        guard let trash = TrashLocation.userTrash() else {
            report(CocoaError(.fileNoSuchFile), context: "trash")
            return
        }
        navigate(to: trash)
    }

    // MARK: - The access banner

    /// Called from `DirectoryModel.onError`. A refused listing gets a banner
    /// with Open Privacy Settings / Try Again instead of the centred error
    /// text; everything else keeps the existing behaviour.
    func handleListingFailure(_ error: Error) {
        guard TrashLocation.isPermissionDenied(error), let url = currentURL else { return }
        let notice = locationNotice ?? LocationNotice()
        locationNotice = notice
        notice.settingsButton.target = self
        notice.settingsButton.action = #selector(openPrivacySettings(_:))
        notice.retryButton.target = self
        notice.retryButton.action = #selector(retryListing(_:))
        notice.showAccessDenied(url, error: error)
        mountNotice(notice)
        if SmokeTest.isRequested {
            print("   [notice] \(notice.messageLabel.stringValue) — \(error.localizedDescription)")
        }
        updateStatus()
    }

    @objc func openPrivacySettings(_ sender: Any?) {
        if SmokeTest.isRequested {
            print("   [notice] would open \(TrashLocation.privacySettingsURL.absoluteString)")
            return
        }
        NSWorkspace.shared.open(TrashLocation.privacySettingsURL)
    }

    @objc func retryListing(_ sender: Any?) {
        guard let url = locationNotice?.url ?? currentURL else { return }
        dismissLocationNotice()
        navigate(to: url)
    }

    func dismissLocationNotice() {
        guard let notice = locationNotice else { return }
        clearNotice(notice)
        locationNotice = nil
    }

    // MARK: - Put Back

    /// Finder's contextual row (Localizable N153.1). Enabled only for items
    /// whose origin Tursora recorded, whose original parent still exists, and
    /// where nothing has taken the name back.
    func putBackVerdicts(for urls: [URL]) -> [(url: URL, verdict: TrashOrigins.PutBack)] {
        urls.map { ($0, TrashOrigins.shared.putBack(for: $0)) }
    }

    /// Enabled when at least one of the targets can go back; the tooltip
    /// explains the first blocked one otherwise.
    func putBackEnablement(for urls: [URL]) -> (enabled: Bool, tooltip: String?) {
        guard isBrowsingTrash, !urls.isEmpty else { return (false, nil) }
        let verdicts = putBackVerdicts(for: urls)
        if verdicts.contains(where: { $0.verdict.isAvailable }) { return (true, nil) }
        return (false, verdicts.first?.verdict.reason)
    }

    @objc func putBackSelection(_ sender: Any?) { putBack(fileView.selectedItems.map(\.url)) }

    func putBack(_ urls: [URL]) {
        guard isBrowsingTrash, !urls.isEmpty else { return }
        var moved: [(trashed: URL, origin: URL)] = []
        var failures: [FileOperations.Failure] = []
        var blocked: [(url: URL, verdict: TrashOrigins.PutBack)] = []
        for (url, verdict) in putBackVerdicts(for: urls) {
            guard let destination = verdict.destination else { blocked.append((url, verdict)); continue }
            do {
                try FileOperations.moveItem(at: url, to: destination)
                moved.append((trashed: url, origin: destination))
            } catch {
                failures.append(.init(url: url, error: error))
            }
        }
        if SmokeTest.isRequested {
            for pair in moved { print("   put back \(pair.trashed.lastPathComponent) → \(pair.origin.path)") }
            for item in blocked { print("   put back refused \(item.url.lastPathComponent): \(item.verdict.reason ?? "")") }
        }
        guard !moved.isEmpty || !failures.isEmpty else { return }
        TrashOrigins.shared.forget(moved.map(\.trashed))
        registerPutBackUndo(moved, returningToTrash: true, actionName: TrashLocation.putBackTitle)
        reloadSelectingURLs([])
        DirectoryChanges.post(affectedDirectories(moved))
        FileOperations.report(failures, in: view.window)
    }

    private func affectedDirectories(_ pairs: [(trashed: URL, origin: URL)]) -> [URL] {
        pairs.flatMap { [$0.trashed.deletingLastPathComponent(), $0.origin.deletingLastPathComponent()] }
    }

    /// Undo of Put Back moves the item back to the exact path it had in the
    /// Trash and restores its journal entry; redo repeats the restore. It never
    /// re-trashes through `FileOperations.trash`, which would send a fixture
    /// item to the real `~/.Trash` during a check.
    private func registerPutBackUndo(_ pairs: [(trashed: URL, origin: URL)],
                                     returningToTrash: Bool, actionName: String) {
        guard !pairs.isEmpty else { return }
        registerUndo(actionName: actionName) { me, _ in
            var done: [(trashed: URL, origin: URL)] = []
            for pair in pairs {
                let source = returningToTrash ? pair.origin : pair.trashed
                let destination = returningToTrash ? pair.trashed : pair.origin
                do {
                    try FileOperations.moveItem(at: source, to: destination)
                    if returningToTrash {
                        TrashOrigins.shared.record([(original: pair.origin, trashed: pair.trashed)])
                    } else {
                        TrashOrigins.shared.forget([pair.trashed])
                    }
                    done.append(pair)
                } catch {
                    me.report(error, context: "undo put back")
                }
            }
            me.registerPutBackUndo(done, returningToTrash: !returningToTrash, actionName: actionName)
            me.reloadSelectingURLs(returningToTrash ? done.map(\.trashed) : [])
            DirectoryChanges.post(me.affectedDirectories(pairs))
        }
    }

    // MARK: - Empty Trash

    /// Finder dims the row when the Trash is empty; an unreadable Trash keeps
    /// it enabled so the failure is reported rather than hidden.
    var canEmptyTrash: Bool {
        guard let trash = TrashLocation.userTrash() else { return false }
        guard let items = try? TrashLocation.topLevelItems(in: trash) else { return true }
        return !items.isEmpty
    }

    /// Injected by checks so a headless run never opens the modal. Returning
    /// false is Cancel.
    static var emptyTrashConfirmation: ((BrowserViewController) -> Bool)?

    func confirmEmptyTrash() -> Bool {
        if SmokeTest.isRequested {
            print("   [alert] \(TrashLocation.emptyTrashMessageText) \(TrashLocation.emptyTrashInformativeText)")
        }
        if let hook = Self.emptyTrashConfirmation { return hook(self) }
        if SmokeTest.isRequested { return true }
        let alert = NSAlert()
        alert.messageText = TrashLocation.emptyTrashMessageText
        alert.informativeText = TrashLocation.emptyTrashInformativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: TrashLocation.emptyTrashButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func emptyTrash(_ sender: Any?) { emptyTrash(completion: nil) }

    /// Removes every top-level item of the user's trash on a background queue.
    /// Per-volume trashes are untouched. Not undoable, like Finder.
    func emptyTrash(completion: (() -> Void)?) {
        guard let trash = TrashLocation.userTrash() else { completion?(); return }
        guard confirmEmptyTrash() else { completion?(); return }
        let items: [URL]
        do {
            items = try TrashLocation.topLevelItems(in: trash)
        } catch {
            handleListingFailure(error)
            FileOperations.report([.init(url: trash, error: error)], in: view.window)
            completion?()
            return
        }
        guard !items.isEmpty else { completion?(); return }
        statusBar.beginBusy()
        let window = view.window
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [FileOperations.Failure] = []
            for item in items {
                do { try FileManager.default.removeItem(at: item) }
                catch { failures.append(.init(url: item, error: error)) }
            }
            DispatchQueue.main.async { [weak self] in
                TrashOrigins.shared.forgetAll(under: trash)
                guard let self else { completion?(); return }
                self.statusBar.endBusy()
                if SmokeTest.isRequested {
                    print("   emptied trash: \(items.count - failures.count) of \(items.count) removed")
                }
                self.reload()
                DirectoryChanges.post([trash])
                FileOperations.report(failures, in: window)
                completion?()
            }
        }
    }
}

/// Go ▸ Trash. Navigation menu rows are validated by the window controller;
/// this one is always available, so its default validation applies.
extension MainWindowController {
    @objc func goTrash(_ sender: Any?) { browser.goTrash() }
}

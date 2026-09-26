import AppKit

/// Pane-owned archive reads: batching, cancellation, progress and hand-off.
/// Navigation stays in the pane; external export completeness lives in ArchiveExport.
extension BrowserViewController {
    /// A file handed to something Tursora cannot watch — another application,
    /// Finder pasting it, the Quick Look panel — goes as a copy outside the
    /// ZIP's private copy, which is let go once no pane shows the ZIP (D103).
    func handOff(_ url: URL) -> URL? {
        guard isArchiveContent(url) else { return url }
        return ArchiveHandoffStore.shared.handOff(url, logical: ArchiveWorkspace.shared.logicalURL(for: url))
    }

    func reportHandOffFailure() {
        showArchiveError(ArchiveBrowsingSession.SessionError.notExtracted("A copy for another application could not be made."))
    }

    func isArchiveContent(_ url: URL) -> Bool {
        guard let session = ArchiveWorkspace.shared.session(for: url) else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL != session.archiveURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Fetches the small files of the ZIP folder now on screen, in the
    /// background, so opening, previewing or copying one of them rarely waits.
    /// Owned by the pane: navigating away or closing it cancels the fetch.
    func startArchivePrefetch(for url: URL) {
        guard isBrowsingArchive, currentURL?.standardizedFileURL == url.standardizedFileURL else { return }
        prefetchRequest?.cancel()
        prefetchRequest = ArchiveWorkspace.shared.prefetch(url)
    }

    /// Stops every archive extraction this pane asked for. A transfer owns its
    /// own, and is not stopped here.
    func cancelArchiveRequests() {
        prefetchRequest?.cancel()
        prefetchRequest = nil
        let requests = archiveRequests.values
        archiveRequests.removeAll()
        quickLookRequest?.token.cancel()
        quickLookRequest = nil
        pendingArchiveOpens.removeAll()
        archiveOpensInFlight.removeAll()
        requests.forEach { $0.cancel() }
    }

    /// Opens asked for in one main-queue pass go out as one request, so three
    /// selected files cost one run of the archive tool, and an entry already
    /// on its way is not asked for twice (D98).
    func enqueueArchiveOpen(_ location: URL) {
        guard !archiveOpensInFlight.contains(location), !pendingArchiveOpens.contains(location) else { return }
        pendingArchiveOpens.append(location)
        guard pendingArchiveOpens.count == 1 else { return }
        DispatchQueue.main.async { [weak self] in self?.flushArchiveOpens() }
    }

    private func flushArchiveOpens() {
        let batch = pendingArchiveOpens
        pendingArchiveOpens.removeAll()
        guard !batch.isEmpty else { return }
        archiveOpensInFlight.formUnion(batch)
        requestArchiveBytes(batch, title: Self.readingTitle(batch.map(\.lastPathComponent), from: archiveSourceURL),
                            finally: { [weak self] in self?.archiveOpensInFlight.subtract(batch) }) { [weak self] result in
            guard let self else { return }
            for url in result.urls {
                guard let handed = self.handOff(url) else { self.reportHandOffFailure(); continue }
                if !self.archiveFileOpener(handed) { self.showArchiveError(ArchiveBrowsingSession.SessionError.unavailableItem) }
            }
        }
    }

    /// Runs `body` with the readable URLs of the items that can be read.
    /// Anything outside an archive, or already extracted, is handed over at
    /// once, in this turn; otherwise the entries are extracted first.
    func withPublishedURLs(_ items: [FileItem], title: String, _ body: @escaping ([URL]) -> Void) {
        let readable = items.filter(\.canAccess)
        let ready = readable.map(\.publishedContentURL)
        guard ready.contains(nil) else { body(ready.compactMap { $0 }); return }
        requestArchiveBytes(readable.map(\.url), title: title) { body($0.urls) }
    }

    /// Extracts entries of a mounted archive off the main thread, with the
    /// pane busy meanwhile and, for a request estimated at more than a second
    /// or 128 MiB, a row in File Operations that can cancel it. Closing the
    /// pane cancels it too. `completion` runs on the main thread unless the
    /// request was cancelled; a failure is reported here, and `finally` runs
    /// either way.
    func requestArchiveBytes(_ locations: [URL], title: String, finally: (() -> Void)? = nil,
                                     completion: @escaping (ArchiveMaterializationResult) -> Void) {
        let workspace = ArchiveWorkspace.shared
        var row: TransferTask?
        if workspace.estimate(for: locations).warrantsProgressRow, let archive = workspace.archiveURL(containing: locations[0]) {
            let task = TransferTask(sources: locations, destination: archive, kind: .extract)
            task.setPhase(.running, detail: "Reading from “\(archive.lastPathComponent)”…")
            TransferTasksWindowController.shared.track(task, ownerWindow: view.window, title: title,
                                                       destinationDescription: "From “\(archive.lastPathComponent)”")
            row = task
        }
        let id = UUID()
        statusBar.beginBusy()
        let token = workspace.materialize(locations) { [weak self] result in
            var summary = FileOperations.TransferResult()
            if case .failure(ArchiveBrowsingSession.SessionError.cancelled) = result { summary.cancelled = true }
            if case .failure(let error) = result, !summary.cancelled { summary.failures = [.init(url: locations[0], error: error)] }
            if case .success(let brought) = result { summary.failures = brought.failures }
            row?.finished(summary)
            finally?()
            guard let self else { return }
            self.statusBar.endBusy()
            self.archiveRequests[id] = nil
            switch result {
            case .success(let brought):
                completion(brought)
                if let failure = brought.failures.first { self.showArchiveError(failure.error) }
            case .failure(let error):
                if !summary.cancelled { self.showArchiveError(error) }
            }
        }
        archiveRequests[id] = token
        row?.onCancel { token.cancel() }
    }

    /// "Reading “notes.txt” from “A.zip”", or a count for several.
    static func readingTitle(_ names: [String], from archive: URL?) -> String {
        let what = names.count == 1 ? "“\(names[0])”" : "\(names.count) items"
        return "Reading \(what)" + (archive.map { " from “\($0.lastPathComponent)”" } ?? "")
    }
}

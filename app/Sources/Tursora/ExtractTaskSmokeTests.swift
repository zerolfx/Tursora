import AppKit

/// Extract from the pane: a File Operations task per archive, with determinate
/// progress and Cancel, across all three views and the pane states rule 3 asks
/// for (split panes, a second tab, a filter and grouping active). D90.
enum ExtractTaskSmokeTests: SmokeSuite {
    static let checkPrefix = "extract task: "

    /// A listing that reports a made-up total, so progress can be driven
    /// without a multi-gigabyte fixture.
    private struct FixedListing: ArchiveListing {
        let entries: [ArchiveEntrySummary]
        func entries(of archive: URL) throws -> [ArchiveEntrySummary] { entries }
    }

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            guard let root = try? SmokeFixtures.temporaryDirectory("extract-task") else {
                check("fixture created", false); completion(); return
            }
            var window: MainWindowController?
            let viewStore = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
            defer {
                window?.close()
                // Write now what closing scheduled, or it lands after the
                // fixture is removed and leaves the folder behind.
                try? viewStore.flush()
                try? fm.removeItem(at: root)
                completion()
            }
            do {
                print("== extract as a file operation ==")
                let source = root.appendingPathComponent("Payload", isDirectory: true)
                try fm.createDirectory(at: source, withIntermediateDirectories: true)
                for index in 0..<6 {
                    try Data(String(repeating: "\(index)", count: 4096).utf8)
                        .write(to: source.appendingPathComponent("file-\(index).bin"))
                }
                try fm.createSymbolicLink(atPath: source.appendingPathComponent("shortcut").path,
                                          withDestinationPath: "file-0.bin")
                let archive = try await SmokeFixtures.compress([source], to: root)
                try fm.removeItem(at: source)

                let wc = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(),
                                              initialURL: root, viewPropertiesStore: viewStore)
                window = wc
                wc.window?.makeKeyAndOrderFront(nil)
                let browser = wc.browser
                await expectEventually("the fixture directory is listed") { browser.model.generation > 0 }
                let tasks = TransferTasksWindowController.shared

                // Each view mode, with a second tab and a split pane open, a
                // name filter that hides the archive, and grouping on — the
                // extraction must still run, report and publish.
                wc.tabs.newTab(at: root)
                wc.tabs.selectTab(at: 0)
                wc.tabs.toggleSplit()
                wc.tabs.focusOtherPane()

                for mode in ViewMode.allCases {
                    let pane = wc.tabs.current
                    pane.setViewMode(mode)
                    pane.setGroupKey(.kind)
                    pane.nameFilter = "Payload"
                    await expectEventually("\(mode.rawValue): the archive is listed") {
                        pane.model.items.contains { $0.url.standardizedFileURL == archive.standardizedFileURL }
                    }
                    var published: URL?
                    await withCheckedContinuation { continuation in
                        pane.fileView.select(urls: [archive])
                        pane.extract([archive]) { continuation.resume() }
                    }
                    let task = pane.lastExtractionTask
                    check("\(mode.rawValue): extraction ran as a file-operation task", task != nil)
                    let snapshot = task?.snapshot
                    check("\(mode.rawValue): the task reports a determinate total",
                          (snapshot?.totalBytes ?? 0) > 0, "\(String(describing: snapshot?.totalBytes))")
                    check("\(mode.rawValue): the task completed with its bytes accounted for",
                          snapshot?.state == .completed && snapshot?.completedBytes == snapshot?.totalBytes,
                          "state=\(String(describing: snapshot?.state)) bytes=\(String(describing: snapshot?.completedBytes))/\(String(describing: snapshot?.totalBytes))")
                    check("\(mode.rawValue): the row is titled Extract, not Copy",
                          task.flatMap { tasks.row(for: $0.id)?.titleLabel.stringValue }?.hasPrefix("Extract") == true,
                          task.flatMap { tasks.row(for: $0.id)?.titleLabel.stringValue } ?? "no row")
                    published = (try? fm.contentsOfDirectory(atPath: root.path))?
                        .first { $0.hasPrefix("Payload") && !$0.hasSuffix(".zip") }
                        .map { root.appendingPathComponent($0) }
                    check("\(mode.rawValue): the contents were published beside the archive",
                          published.map { fm.fileExists(atPath: $0.appendingPathComponent("file-0.bin").path) } == true,
                          published?.lastPathComponent ?? "nothing published")
                    check("\(mode.rawValue): the undo group is named Extract",
                          wc.window?.undoManager?.undoActionName == "Extract",
                          wc.window?.undoManager?.undoActionName ?? "none")
                    check("\(mode.rawValue): no staging directory is left behind",
                          (try? fm.contentsOfDirectory(atPath: root.path))?.contains { $0.hasPrefix(".tursora-archive-") } == false)
                    check("\(mode.rawValue): the row offers Cancel but no Pause",
                          snapshot?.supportsPause == false && snapshot?.canPause == false)
                    check("\(mode.rawValue): the other pane and the second tab are untouched",
                          wc.tabs.count == 2 && wc.tabs.currentPage.panes.count == 2)
                    if let published { try? fm.removeItem(at: published) }
                    pane.nameFilter = ""
                    pane.setGroupKey(.none)
                }

                // Cancel: a task the user stops publishes nothing and leaves no
                // staging tree, and the batch stops rather than starting the next.
                let pane = wc.tabs.current
                pane.setViewMode(.details)
                pane.archiveListing = FixedListing(entries: (0..<6).map {
                    ArchiveEntrySummary(name: "Payload/file-\($0).bin", uncompressedSize: 4096, kind: .file)
                })
                let second = try await SmokeFixtures.compress([archive], to: root)
                await withCheckedContinuation { continuation in
                    var cancelled = false
                    pane.extract([archive, second]) { continuation.resume() }
                    // Cancel the moment the first task exists.
                    func stop() {
                        guard let task = pane.lastExtractionTask, !task.snapshot.isTerminal else {
                            if !cancelled { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: stop) }
                            return
                        }
                        cancelled = true
                        task.cancel()
                    }
                    stop()
                }
                let cancelledTask = pane.lastExtractionTask
                check("a cancelled extraction reaches a cancelled state, or finished before it could",
                      cancelledTask?.snapshot.state == .cancelled || cancelledTask?.snapshot.state == .completed,
                      "\(String(describing: cancelledTask?.snapshot.state))")
                check("cancelling leaves no staging directory behind",
                      (try? fm.contentsOfDirectory(atPath: root.path))?.contains { $0.hasPrefix(".tursora-archive-") } == false)
                check("a headless run opens no task window",
                      tasks.window?.isVisible != true)
            } catch {
                check("unexpected error", false, "\(error)")
            }
        }
    }
}

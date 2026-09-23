import AppKit

/// Browsing a ZIP that was never extracted, through the real pane: all three
/// views, with a split pane and a second tab open and with a filter and
/// grouping active, plus the two entry shapes the tree has to get right — an
/// application bundle, which must arrive whole, and an entry that can be
/// listed but never extracted (D92).
enum LazyArchiveSmokeTests: SmokeSuite {
    static let checkPrefix = "lazy zip: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            guard let root = try? SmokeFixtures.temporaryDirectory("lazy-zip") else {
                check("fixture created", false); completion(); return
            }
            let zipKey = "experimentalZIPBrowsingEnabled"
            let oldFlag = UserDefaults.standard.object(forKey: zipKey)
            var window: MainWindowController?
            var openedArchives: [URL] = []
            defer {
                window?.close()
                if let oldFlag { UserDefaults.standard.set(oldFlag, forKey: zipKey) }
                else { UserDefaults.standard.removeObject(forKey: zipKey) }
                // Close this suite's own sessions rather than calling
                // shutdownAll, which latches a process-wide shutting-down flag
                // that is never reset and would leave every later suite unable
                // to prepare an archive at all.
                openedArchives.forEach { ArchiveWorkspace.shared.session(for: $0)?.close() }
                try? fm.removeItem(at: root)
                completion()
            }
            do {
                print("== lazy ZIP browsing ==")
                UserDefaults.standard.removeObject(forKey: zipKey)
                check("ZIP browsing is on by default", AppPreferences.experimentalZIPBrowsingEnabled)

                // A tree with a package, a nested directory and plain files.
                let payload = root.appendingPathComponent("Payload", isDirectory: true)
                let inner = payload.appendingPathComponent("Inner", isDirectory: true)
                let bundle = payload.appendingPathComponent("Demo.app/Contents/MacOS", isDirectory: true)
                try fm.createDirectory(at: inner, withIntermediateDirectories: true)
                try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
                try Data("top".utf8).write(to: payload.appendingPathComponent("top.txt"))
                try Data("deep".utf8).write(to: inner.appendingPathComponent("deep.txt"))
                try Data("plist".utf8).write(to: payload.appendingPathComponent("Demo.app/Contents/Info.plist"))
                try Data("binary".utf8).write(to: bundle.appendingPathComponent("Demo"))
                // Dated after the files are written: adding an entry to a
                // directory bumps its own date.
                let recorded = Date(timeIntervalSince1970: 1_577_880_000)   // 2020-01-01T12:00:00Z
                for url in [inner.appendingPathComponent("deep.txt"), payload.appendingPathComponent("top.txt"), inner, payload] {
                    try fm.setAttributes([.modificationDate: recorded], ofItemAtPath: url.path)
                }
                let source = try await SmokeFixtures.compress([payload], to: root)
                try fm.removeItem(at: payload)

                let viewStore = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
                let wc = MainWindowController(provider: ArchiveFileProvider(base: LocalFileProvider(),
                                                                           workspace: ArchiveWorkspace.shared),
                                              places: PlacesModel(), initialURL: root,
                                              viewPropertiesStore: viewStore)
                window = wc
                wc.window?.makeKeyAndOrderFront(nil)
                let browser = wc.browser
                await expectEventually("the fixture directory is listed") { browser.model.generation > 0 }

                // A second tab and a split pane stay open throughout.
                wc.tabs.newTab(at: root)
                wc.tabs.selectTab(at: 0)
                wc.tabs.toggleSplit()
                wc.tabs.focusOtherPane()

                for mode in ViewMode.allCases {
                    // One archive per mode: a session is keyed by the archive's
                    // path and outlives a view change, so sharing one would let
                    // the first mode's materialization satisfy the next mode's
                    // "not yet staged" assertion.
                    let archive = root.appendingPathComponent("Payload-\(mode.rawValue).zip")
                    try fm.copyItem(at: source, to: archive)
                    openedArchives.append(archive)
                    let logicalPayload = archive.appendingPathComponent("Payload")
                    let logicalInner = logicalPayload.appendingPathComponent("Inner")
                    let pane = wc.tabs.current
                    pane.setViewMode(mode)
                    pane.navigate(to: archive)
                    // currentURL changes before the listing does, so the wait
                    // has to be on the rows or it passes on the old directory's.
                    await expectEventually("\(mode.rawValue): the archive opens without being extracted") {
                        pane.currentURL?.standardizedFileURL == archive.standardizedFileURL
                            && !pane.isPreparingArchive && pane.model.items.map(\.name) == ["Payload"]
                    }
                    guard let session = ArchiveWorkspace.shared.session(for: archive) else {
                        check("\(mode.rawValue): a session exists", false); return
                    }
                    check("\(mode.rawValue): the session is lazily mounted", session.isLazilyMounted)
                    check("\(mode.rawValue): the archive root lists its contents",
                          pane.model.items.map(\.name) == ["Payload"], "\(pane.model.items.map(\.name))")
                    // The regression Stage 3 fixes: a directory's date was the
                    // moment its skeleton was created, i.e. when the archive was
                    // opened, instead of the date the archive records for it.
                    let payloadDate = pane.model.items.first?.modificationDate
                    check("\(mode.rawValue): a folder inside a ZIP shows the archive's date for it, not when it was opened",
                          payloadDate.map { abs($0.timeIntervalSince(recorded)) < 1 } == true,
                          "\(String(describing: payloadDate))")

                    pane.navigate(to: logicalPayload)
                    await expectEventually("\(mode.rawValue): entering a directory inside the ZIP") {
                        pane.currentURL?.standardizedFileURL == logicalPayload.standardizedFileURL
                            && Set(pane.model.items.map(\.name)).isSuperset(of: ["top.txt", "Inner", "Demo.app"])
                    }
                    let names = Set(pane.model.items.map(\.name))
                    check("\(mode.rawValue): the directory lists its files, its subfolder and the bundle",
                          names.isSuperset(of: ["top.txt", "Inner", "Demo.app"]), "\(names.sorted())")

                    // A bundle must be whole or the app it represents is broken.
                    let physicalBundle = session.rootURL.appendingPathComponent("Payload/Demo.app")
                    check("\(mode.rawValue): a bundle is materialized whole, not as an empty shell",
                          fm.fileExists(atPath: physicalBundle.appendingPathComponent("Contents/Info.plist").path)
                          && fm.fileExists(atPath: physicalBundle.appendingPathComponent("Contents/MacOS/Demo").path))
                    check("\(mode.rawValue): a bundle reads as one item, not a folder to walk into",
                          pane.model.items.first { $0.name == "Demo.app" }?.isNavigable == false)

                    // The other regression: an unentered folder is only its
                    // skeleton on disk, so counting it from disk said 0 items.
                    if let innerItem = pane.model.items.first(where: { $0.name == "Inner" }) {
                        await expectEventually("\(mode.rawValue): an unentered folder in a ZIP counts its real contents",
                                               detail: { pane.model.folderSizes.displaySize(for: innerItem) }) {
                            pane.model.folderSizes.displaySize(for: innerItem) == "1 item"
                        }
                        check("\(mode.rawValue): an unentered folder keeps the archive's date too",
                              abs((innerItem.modificationDate ?? .distantPast).timeIntervalSince(recorded)) < 1,
                              "\(String(describing: innerItem.modificationDate))")
                    } else {
                        check("\(mode.rawValue): the Inner folder is listed", false)
                    }

                    // A file's bytes are there because its directory was listed.
                    let top = pane.model.items.first { $0.name == "top.txt" }
                    check("\(mode.rawValue): a listed file has readable bytes",
                          top?.publishedContentURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "top")
                    // …and a deeper directory's are still absent.
                    check("\(mode.rawValue): a directory not yet entered is still unstaged",
                          !fm.fileExists(atPath: session.rootURL.appendingPathComponent("Payload/Inner/deep.txt").path))

                    // Filtering and grouping are the pane's, over the same rows.
                    pane.setGroupKey(.kind)
                    pane.nameFilter = "top"
                    await expectEventually("\(mode.rawValue): the filter narrows the ZIP listing") {
                        pane.model.items.map(\.name) == ["top.txt"]
                    }
                    pane.nameFilter = ""
                    pane.setGroupKey(.none)

                    pane.navigate(to: logicalInner)
                    await expectEventually("\(mode.rawValue): entering the deeper directory") {
                        pane.currentURL?.standardizedFileURL == logicalInner.standardizedFileURL
                            && pane.model.items.map(\.name) == ["deep.txt"]
                    }
                    check("\(mode.rawValue): the deeper directory's file arrives on entry",
                          pane.model.items.first?.publishedContentURL
                            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "deep")
                    check("\(mode.rawValue): the other pane and the second tab are untouched",
                          wc.tabs.count == 2 && wc.tabs.currentPage.panes.count == 2)

                    pane.navigate(to: root)
                    await expectEventually("\(mode.rawValue): leaving the archive") {
                        pane.currentURL?.standardizedFileURL == root.standardizedFileURL
                    }
                }

                // An entry that can be listed but never extracted stays visible
                // and inert, rather than making the whole archive unopenable.
                let hostile = root.appendingPathComponent("hostile.zip")
                try SmokeFixtures.zipWithParentTraversal().write(to: hostile)
                openedArchives.append(hostile)
                let pane = wc.tabs.current
                pane.setViewMode(.details)
                pane.navigate(to: hostile)
                await expectEventually("an archive containing a .. entry still opens") {
                    pane.currentURL?.standardizedFileURL == hostile.standardizedFileURL
                        && !pane.isPreparingArchive
                        && pane.model.items.contains { $0.name == "safe.txt" }
                }
                check("its ordinary entries are browsable",
                      pane.model.items.contains { $0.name == "safe.txt" }, "\(pane.model.items.map(\.name))")
                check("nothing was written outside the archive's own storage",
                      !fm.fileExists(atPath: root.appendingPathComponent("escape.txt").path))
            } catch {
                check("unexpected error", false, "\(error)")
            }
        }
    }
}

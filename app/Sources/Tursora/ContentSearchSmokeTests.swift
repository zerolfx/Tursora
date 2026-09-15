import AppKit

/// Content search that reads files instead of asking the index.
///
/// `ContentScanner` is a pure function of bytes, so most of this runs without
/// touching the filesystem at all; the file-level checks then cover the things
/// bytes cannot express — a FIFO that would block on open, a device node, a
/// file larger than the cap — and the backend checks drive a real search.
enum ContentSearchSmokeTests: SmokeSuite {
    static var checkPrefix: String { "content search: " }

    static func run(_ completion: @escaping () -> Void) {
        print("== content search ==")
        matching()
        binaryDetection()
        tallies()
        savedSearchCompatibility()
        Task { @MainActor in
            await fileLevel()
            await backend()
            panel()
            completion()
        }
    }

    // MARK: - Pure

    private static func matching() {
        check("a literal match is found", ContentScanner.scan(Data("hello world".utf8), for: "world", wasTruncated: false) == .match)
        check("a miss is a miss", ContentScanner.scan(Data("hello".utf8), for: "world", wasTruncated: false) == .noMatch)
        check("matching ignores case", ContentScanner.scan(Data("Hello".utf8), for: "hello", wasTruncated: false) == .match)
        check("matching ignores diacritics", ContentScanner.scan(Data("café".utf8), for: "cafe", wasTruncated: false) == .match)
        // The needle is text the user typed, never a pattern: a dot must find a
        // dot, not any character, or a search for "1.2" would match "192".
        check("the needle is literal, not a pattern",
              ContentScanner.contains("192", "1.2") == false && ContentScanner.contains("1.2", "1.2"))
        check("a star finds a star", ContentScanner.contains("a*b", "*") && !ContentScanner.contains("ab", "*"))
        check("an empty needle matches anything", ContentScanner.contains("anything", ""))
        check("an empty file is skipped", ContentScanner.scan(Data(), for: "x", wasTruncated: false) == .skipped(.empty))

        // The thumbnail decoder refuses anything that is not clean UTF-8 or BOM
        // UTF-16, and refuses control characters outright. That is right for a
        // thumbnail and wrong for a search: these are files a user expects to
        // find, and before the lenient fallback each was a silent miss reported
        // as "unreadable", which reads like a permissions problem.
        let windows1252 = Data([0x62, 0x75, 0x64, 0x67, 0x65, 0x74, 0x20, 0xe9])   // "budget " + é in CP1252
        check("a note saved in a legacy encoding is still searched",
              ContentScanner.scan(windows1252, for: "budget", wasTruncated: false) == .match,
              "\(ContentScanner.scan(windows1252, for: "budget", wasTruncated: false))")
        let ansi = Data("\u{1B}[31merror\u{1B}[0m: failed".utf8)
        check("an ANSI-coloured log is still searched",
              ContentScanner.scan(ansi, for: "error", wasTruncated: false) == .match,
              "\(ContentScanner.scan(ansi, for: "error", wasTruncated: false))")
        let formFeed = Data("chapter one\u{0C}chapter two".utf8)
        check("a form feed does not disqualify a text file",
              ContentScanner.scan(formFeed, for: "chapter two", wasTruncated: false) == .match)
        check("but a NUL still means binary",
              ContentScanner.scan(Data([0x00] + Array("budget".utf8)), for: "budget", wasTruncated: false)
                  == .skipped(.binary))
    }

    private static func binaryDetection() {
        check("a NUL byte means binary", ContentScanner.looksBinary(Data([0x68, 0x00, 0x69])))
        check("plain text is not binary", !ContentScanner.looksBinary(Data("just text".utf8)))
        // UTF-16 is full of NUL bytes; without honouring the BOM every UTF-16
        // document would be called binary and skipped without a word.
        var utf16 = Data([0xff, 0xfe])
        utf16.append(contentsOf: Array("hi".utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        check("a UTF-16 byte-order mark is not binary", !ContentScanner.looksBinary(utf16))
        check("and its text is searchable",
              ContentScanner.scan(utf16, for: "hi", wasTruncated: false) == .match,
              "\(ContentScanner.scan(utf16, for: "hi", wasTruncated: false))")
        // A NUL far past the sample window does not condemn the file.
        var late = Data(repeating: 0x61, count: 9_000)
        late.append(0)
        check("a NUL past the sampled prefix does not mark text binary", !ContentScanner.looksBinary(late))
    }

    private static func tallies() {
        var tally = ContentScanner.Tally()
        tally.record(.match)
        tally.record(.noMatch)
        tally.record(.truncated(matched: true))
        tally.record(.truncated(matched: false))
        tally.record(.skipped(.binary))
        tally.record(.skipped(.tooLarge))
        check("a tally counts every outcome",
              tally.scanned == 6 && tally.matched == 2 && tally.truncated == 2
                  && tally.binary == 1 && tally.tooLarge == 1,
              "\(tally)")
        var cloud = ContentScanner.Tally()
        cloud.record(.skipped(.notDownloaded))
        check("a cloud placeholder has its own count, not the unreadable bucket",
              cloud.notDownloaded == 1 && cloud.unreadable == 0)
        check("and the summary says it was not downloaded",
              cloud.summary.contains("not downloaded"), cloud.summary)
        check("the summary names what was not searched",
              tally.summary.contains("binary") && tally.summary.contains("MB")
                  && tally.summary.contains("KB"), tally.summary)
        check("an ordinary search says nothing alarming", ContentScanner.Tally().summary.isEmpty)
        var onlyMatches = ContentScanner.Tally()
        onlyMatches.record(.match); onlyMatches.record(.noMatch)
        check("and a clean scan has no summary either", onlyMatches.summary.isEmpty, onlyMatches.summary)
    }

    /// Synthesized decoding throws for an absent key rather than using the
    /// property's default, and the store decodes the whole array with `try?` —
    /// so before the custom decoder, one new field emptied every saved search.
    private static func savedSearchCompatibility() {
        let legacy = Data(#"""
        [{"id":"5E1A0E2E-0000-4000-8000-000000000001","name":"Old","request":{"rootURL":"file:///tmp/","scope":"currentFolder","name":"report","content":"budget","kind":"any"}}]
        """#.utf8)
        let saved = try? JSONDecoder().decode([SavedSearch].self, from: legacy)
        check("a search saved before the setting existed still decodes", saved?.count == 1, "\(saved?.count ?? -1)")
        check("its conditions survive", saved?.first?.request.trimmedContent == "budget"
              && saved?.first?.request.trimmedName == "report")
        check("and it keeps using the index, as it did", saved?.first?.request.contentSource == .index)

        var request = SearchRequest(rootURL: URL(fileURLWithPath: "/tmp"), content: "x", contentSource: .disk)
        guard let data = try? JSONEncoder().encode(request),
              let back = try? JSONDecoder().decode(SearchRequest.self, from: data) else {
            check("a request round-trips", false); return
        }
        check("the setting survives a round trip", back.contentSource == .disk)
        check("scanning and Spotlight are mutually exclusive",
              request.scansContent && !request.usesSpotlight)
        request.contentSource = .index
        check("and the index path is the other one", request.usesSpotlight && !request.scansContent)
        request.content = "   "
        check("blank content uses neither", !request.usesSpotlight && !request.scansContent)
    }

    // MARK: - Files

    @MainActor
    private static func fileLevel() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tursora-content-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let text = root.appendingPathComponent("notes.txt")
        try? "the needle is here".write(to: text, atomically: true, encoding: .utf8)
        check("a text file matches", ContentScanner.scanFile(at: text, for: "needle") == .match)
        check("and reports a miss", ContentScanner.scanFile(at: text, for: "absent") == .noMatch)

        // A package is a directory; opening one as a file fails, and before the
        // guard the failure was reported to the user as an unreadable item.
        let package = root.appendingPathComponent("Thing.app")
        try? fm.createDirectory(at: package, withIntermediateDirectories: true)
        check("a package is not a regular file", ContentScanner.scanFile(at: package, for: "x") == .skipped(.notRegular))

        let binary = root.appendingPathComponent("blob.bin")
        try? Data([0x00, 0x01, 0x02] + Array("needle".utf8)).write(to: binary)
        check("a binary file is skipped, not searched",
              ContentScanner.scanFile(at: binary, for: "needle") == .skipped(.binary))

        // Opening a FIFO blocks until a writer arrives. Without the nonblocking
        // open and the fstat guard, one of these in a searched tree would hang
        // the search for good.
        let fifo = root.appendingPathComponent("pipe")
        mkfifo(fifo.path, 0o600)
        check("a FIFO is skipped rather than blocking the search",
              ContentScanner.scanFile(at: fifo, for: "needle") == .skipped(.notRegular),
              "\(ContentScanner.scanFile(at: fifo, for: "needle"))")

        check("a missing file is unreadable, not a crash",
              ContentScanner.scanFile(at: root.appendingPathComponent("gone"), for: "x") == .skipped(.unreadable))
        check("a directory is not a regular file",
              ContentScanner.scanFile(at: root, for: "x") == .skipped(.notRegular))

        let empty = root.appendingPathComponent("empty.txt")
        try? Data().write(to: empty)
        check("an empty file is skipped", ContentScanner.scanFile(at: empty, for: "x") == .skipped(.empty))

        // Past the per-file cap the answer must say so, not claim a clean miss.
        let long = root.appendingPathComponent("long.txt")
        let filler = String(repeating: "a", count: ContentScanner.maximumBytes + 4096)
        try? (filler + "needle").write(to: long, atomically: true, encoding: .utf8)
        let outcome = ContentScanner.scanFile(at: long, for: "needle")
        check("a match past the read cap is reported as truncated, not as a miss",
              outcome == .truncated(matched: false), "\(outcome)")
        check("a match inside the cap is still found in a long file",
              ContentScanner.scanFile(at: long, for: "aaaa") == .truncated(matched: true))
    }

    // MARK: - Panel

    /// The setting is only meaningful with text to look for, and it has to
    /// survive the round trip through the panel that assembles the request.
    @MainActor
    private static func panel() {
        let controller = SearchPanelController()
        _ = controller.view
        check("the panel offers both sources, in order",
              controller.contentSourcePopup.itemTitles == ContentSource.allCases.map(\.title),
              "\(controller.contentSourcePopup.itemTitles)")
        controller.contentField.stringValue = ""
        controller.syncContentSourceAvailability()
        check("with no text to find, the setting is disabled", !controller.contentSourcePopup.isEnabled)
        controller.contentField.stringValue = "   "
        controller.syncContentSourceAvailability()
        check("and blank text does not enable it either", !controller.contentSourcePopup.isEnabled)
        controller.contentField.stringValue = "needle"
        controller.syncContentSourceAvailability()
        check("text enables it", controller.contentSourcePopup.isEnabled)
        check("its tooltip explains the index's limit while the index is chosen",
              controller.contentSourcePopup.toolTip?.contains("indexed") == true,
              controller.contentSourcePopup.toolTip ?? "nil")
        controller.contentSourcePopup.selectItem(at: ContentSource.allCases.firstIndex(of: .disk)!)
        controller.syncContentSourceAvailability()
        check("and explains the cost once scanning is chosen",
              controller.contentSourcePopup.toolTip?.contains("not indexed") == true,
              controller.contentSourcePopup.toolTip ?? "nil")
        check("the field's own tooltip follows the choice",
              controller.contentField.toolTip == controller.contentSourcePopup.toolTip)
    }

    // MARK: - Backend

    @MainActor
    private static func backend() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tursora-contentsearch-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(at: root.appendingPathComponent("deep"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try? "alpha beta".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "gamma".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try? "beta again".write(to: root.appendingPathComponent("deep/c.txt"), atomically: true, encoding: .utf8)
        try? Data([0x00] + Array("beta".utf8)).write(to: root.appendingPathComponent("deep/d.bin"))

        func search(_ request: SearchRequest) async -> (items: [FileItem], message: String) {
            await withCheckedContinuation { continuation in
                var found: [FileItem] = []
                var resumed = false
                let backend = LocalSearchBackend()
                _ = backend.start(request) { event in
                    switch event {
                    case .batch(let items): found += items
                    case .finished(let message), .failed(let message):
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(returning: (found, message))
                    }
                }
            }
        }

        var request = SearchRequest(rootURL: root, content: "beta", contentSource: .disk)
        let (items, message) = await search(request)
        let names = Set(items.map(\.name))
        check("scanning finds the word in files at every depth",
              names == ["a.txt", "c.txt"], "\(names.sorted())")
        check("a binary file holding the word is not a result", !names.contains("d.bin"))
        check("a package is neither scanned nor reported unreadable",
              !message.contains("unreadable"), message)
        check("the message says what was scanned and what was skipped",
              message.contains("Scanned") && message.contains("binary"), message)

        request.content = "nowhere"
        let (none, emptyMessage) = await search(request)
        check("a word in no file returns nothing", none.isEmpty, "\(none.map(\.name))")
        check("and still reports the scan honestly", emptyMessage.contains("Scanned"), emptyMessage)

        // A name condition narrows the set before any file is opened.
        request.content = "beta"
        request.name = "c"
        let (narrowed, _) = await search(request)
        check("a name condition narrows what gets read",
              narrowed.map(\.name) == ["c.txt"], "\(narrowed.map(\.name))")

        // Cancelling must stop it: a scan reads bytes, so one that ignores
        // cancellation keeps a closed tab's search hitting the disk.
        request.name = ""
        var delivered = 0
        let token = LocalSearchBackend().start(request) { event in
            if case .batch = event { delivered += 1 }
            if case .finished = event { delivered += 1 }
        }
        token.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("a cancelled scan publishes nothing", delivered == 0, "\(delivered)")
    }
}

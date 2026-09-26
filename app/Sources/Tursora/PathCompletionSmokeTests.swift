import AppKit

enum PathCompletionSmokeTests: SmokeSuite {
    static var checkPrefix: String { "path completion: " }

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            await serviceBehaviour()
            do { try await editorBehaviour() }
            catch { fail("editor fixture", error.localizedDescription) }
            completion()
        }
    }

    private final class Probe {
        private let lock = NSLock()
        private var queries: [String] = []
        private var allBackground = true
        private var transformations = 0
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return queries }
        var ranOffMain: Bool { lock.lock(); defer { lock.unlock() }; return allBackground }
        var matchCount: Int { lock.lock(); defer { lock.unlock() }; return transformations }
        func load(_ query: PathCompleter.DirectoryQuery) -> [PathCompleter.DirectoryEntry] {
            lock.lock()
            queries.append(query.directoryText)
            allBackground = allBackground && !Thread.isMainThread
            lock.unlock()
            return ["Alpha", "Alternative", "Beta", ".Hidden"].map {
                PathCompleter.DirectoryEntry(name: $0, isHidden: $0.hasPrefix("."))
            }
        }
        func match(_ entries: [PathCompleter.DirectoryEntry], partial: String) -> [String] {
            lock.lock()
            transformations += 1
            allBackground = allBackground && !Thread.isMainThread
            lock.unlock()
            return PathCompleter.completions(in: entries, partial: partial)
        }
    }

    @MainActor private static func serviceBehaviour() async {
        let root = URL(fileURLWithPath: "/completion-fixture", isDirectory: true)
        let probe = Probe()
        var clock: TimeInterval = 0
        let service = PathCompletionService(debounce: 0.03, cacheLifetime: 1, cacheLimit: 2,
                                            now: { clock }, loader: probe.load, matcher: probe.match)
        var results: [[String]] = []
        service.request(for: "old/A", cwd: root, home: root) { _ in fail("superseded debounce delivered") }
        service.request(for: "new/Al", cwd: root, home: root) { results.append($0) }
        await waitUntil("debounced request finishes") { results.count == 1 }
        check("typing supersedes queued enumeration", probe.paths == ["new/"])
        check("resolution, filtering and localized sorting run off main", probe.ranOffMain && probe.matchCount == 1)
        check("matching retains case-insensitive sorted directory names", results[0] == ["Alpha/", "Alternative/"])
        service.request(for: "new/Be", cwd: root, home: root) { results.append($0) }
        check("even a cache hit does not call back reentrantly", results.count == 1)
        await waitUntil("cached prefix finishes") { results.count == 2 }
        check("another prefix reuses its directory snapshot", probe.paths == ["new/"] && results[1] == ["Beta/"])
        check("cached candidates also filter and sort off main", probe.ranOffMain && probe.matchCount == 2)
        service.request(for: "new/.", cwd: root, home: root) { results.append($0) }
        await waitUntil("hidden prefix finishes") { results.count == 3 }
        check("a dot prefix reveals hidden folders from the same snapshot", results[2] == [".Hidden/"] && probe.paths.count == 1)
        clock = 2
        service.request(for: "new/A", cwd: root, home: root) { results.append($0) }
        await waitUntil("expired snapshot refreshes") { results.count == 4 }
        check("expired cache entries are listed again", probe.paths.count == 2)
        for directory in ["second/", "third/", "new/"] {
            let expected = results.count + 1
            service.request(for: directory + "A", cwd: root, home: root) { results.append($0) }
            await waitUntil("bounded cache request") { results.count == expected }
        }
        check("least-recent directory falls out of the bounded cache",
              probe.paths == ["new/", "new/", "second/", "third/", "new/"])

        let gate = WorkerGate()
        let cancelledProbe = Probe()
        let concurrent = PathCompletionService(debounce: 0, loader: { query in
            if query.directoryText == "slow/" { gate.arriveAndWait() }
            return cancelledProbe.load(query)
        })
        defer { gate.release(); concurrent.cancel(); service.cancel() }
        var staleDelivered = false
        var current: [String]?
        concurrent.request(for: "slow/A", cwd: root, home: root) { _ in staleDelivered = true }
        await waitUntil("slow worker starts") { gate.arrived }
        concurrent.request(for: "fast/B", cwd: root, home: root) { current = $0 }
        await waitUntil("new directory completes while old worker is blocked") { current != nil }
        check("a blocked directory does not prevent a newer result", current == ["Beta/"])
        gate.release()
        await waitUntil("old worker exits") { cancelledProbe.paths.contains("slow/") }
        await drainMainQueue()
        check("in-flight stale enumeration never delivers", !staleDelivered)
    }

    /// Intentionally delivers even cancelled callbacks: both the service and
    /// the editor must reject stale work, including a reused field editor.
    private final class ControlledProvider: PathCompletionProviding {
        private(set) var callbacks: [([String]) -> Void] = []
        func request(for text: String, cwd: URL, home: URL, completion: @escaping ([String]) -> Void) {
            callbacks.append(completion)
        }
        func cancel() {}
        func deliver(_ index: Int, _ candidates: [String]) { callbacks[index](candidates) }
    }

    @MainActor private static func type(_ text: String, in bar: BreadcrumbBar) {
        guard let editor = bar.textField.currentEditor() as? NSTextView else { fail("has a native field editor") }
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        bar.textChanged()
    }

    @MainActor private static func editorBehaviour() async throws {
        let root = try SmokeFixtures.temporaryDirectory("path-completion")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Alpha", "Alternative", "Beta"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let bar = BreadcrumbBar(frame: NSRect(x: 0, y: 60, width: 640, height: BreadcrumbBar.height))
        let controlled = ControlledProvider()
        bar.completionProvider = controlled
        bar.homeURL = root
        bar.url = root
        window.contentView?.addSubview(bar)
        window.makeKeyAndOrderFront(nil)
        bar.beginEditing()
        type("Al", in: bar)
        type("Bet", in: bar)
        controlled.deliver(0, ["Alpha/"])
        check("a stale prefix cannot overwrite newer typing", bar.textField.stringValue == "Bet" && !bar.completion.isVisible)
        controlled.deliver(1, ["Beta/"])
        check("current result fills only the selected suffix",
              bar.textField.stringValue == "Beta/" && bar.typedText == "Bet" && bar.inlineCompletion == "a/")
        type("B", in: bar)
        controlled.deliver(2, ["Beta/"])
        check("deleting does not refill inline", bar.textField.stringValue == "B" && bar.inlineCompletion == nil)
        type("Al", in: bar)
        let editor = bar.textField.currentEditor() as! NSTextView
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        controlled.deliver(3, ["Alpha/"])
        check("moving the caret rejects an otherwise current result", editor.string == "Al" && !bar.completion.isVisible)

        type("Al", in: bar)
        bar.endEditing(returnFocus: false)
        bar.beginEditing()
        type("Al", in: bar)
        controlled.deliver(4, ["Alternative/"])
        check("reopening an identical draft rejects the old edit session", bar.textField.stringValue == "Al" && !bar.completion.isVisible)
        controlled.deliver(5, ["Alpha/", "Alternative/"])
        check("the reopened editor receives its own result", bar.inlineCompletion == "pha/")

        type("Bet", in: bar)
        check("Tab is consumed while its lookup is pending", bar.acceptCompletion())
        controlled.deliver(6, ["Beta/"])
        check("pending Tab accepts the folder without leaving focus",
              bar.textField.stringValue == "Beta/" && bar.inlineCompletion == nil && bar.isEditing)
        controlled.deliver(7, [])
        check("accepted folder requests its children", !bar.isCompletingPath && !bar.completion.isVisible)

        type("Al", in: bar)
        _ = bar.control(bar.textField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        controlled.deliver(8, ["Alpha/"])
        check("Escape withdraws a pending popup", bar.isEditing && !bar.completion.isVisible && bar.textField.stringValue == "Al")
        type("Al", in: bar)
        bar.url = root.appendingPathComponent("Beta")
        controlled.deliver(9, ["Alpha/"])
        check("a changed browsing context invalidates completion", !bar.completion.isVisible && bar.textField.stringValue == "Al")
        bar.url = root

        var navigated: URL?
        bar.onNavigate = { navigated = $0 }
        type("A", in: bar)
        controlled.deliver(10, ["Alpha/", "Alternative/"])
        _ = bar.control(bar.textField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        check("Down selects the first candidate", bar.completion.selectedCandidate == "Alpha/")
        _ = bar.control(bar.textField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check("Return accepts the selected directory and navigates",
              navigated?.lastPathComponent == "Alpha" && !bar.isEditing && !bar.completion.isVisible)
        controlled.deliver(11, ["Late/"])
        check("navigation rejects the pending child popup", !bar.completion.isVisible && !bar.isEditing)

        bar.beginEditing()
        type("Beta/", in: bar)
        _ = bar.control(bar.textField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check("Return on a complete directory does not wait for or enter its first child",
              navigated?.lastPathComponent == "Beta" && !bar.isEditing)
        controlled.deliver(12, ["Child/"])
        check("the completed path rejects its cancelled child lookup", !bar.completion.isVisible)

        // Native key-loop direction must survive waiting for a lookup that
        // ultimately offers no completion. Text fields are focusable even
        // when the user's Full Keyboard Access preference excludes buttons.
        let before = NSTextField(frame: NSRect(x: 10, y: 15, width: 200, height: 22))
        let after = NSTextField(frame: NSRect(x: 320, y: 15, width: 200, height: 22))
        window.contentView?.addSubview(before)
        window.contentView?.addSubview(after)
        before.nextKeyView = bar.textField
        bar.textField.nextKeyView = after
        after.nextKeyView = before
        for backward in [false, true] {
            bar.beginEditing()
            let callback = controlled.callbacks.count
            type("Missing", in: bar)
            let command = backward ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:))
            check("pending \(backward ? "Backtab" : "Tab") waits for its candidate lookup",
                  bar.control(bar.textField, textView: editor, doCommandBy: command))
            controlled.deliver(callback, [])
            let expected = backward ? before : after
            let focused = !bar.isEditing && expected.currentEditor() != nil && window.firstResponder === expected.currentEditor()
            check("empty \(backward ? "Backtab" : "Tab") result preserves native focus direction",
                  focused, focused ? "" : "editing=\(bar.isEditing), key=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder)), addressEditor=\(bar.textField.currentEditor() != nil), beforeEditor=\(before.currentEditor() != nil), afterEditor=\(after.currentEditor() != nil)")
        }
    }
}

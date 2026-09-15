import AppKit

/// The docked preview pane, driven through the real window controller so the
/// split item, the selection path and the session round trip are all exercised
/// rather than described.
enum PreviewPaneSmokeTests: SmokeSuite {
    static var checkPrefix: String { "preview pane: " }

    static func run(_ completion: @escaping () -> Void) {
        print("== preview pane ==")
        textKitVersion()
        markdownDetection()
        Task { @MainActor in
            await paneLifecycle()
            sessionRoundTrip()
            completion()
        }
    }

    /// A Markdown table needs `NSTextTableBlock`, which TextKit 2 ignores in
    /// silence — the cells stack, no error is raised, and the text still reads
    /// correctly in a log, so nothing else in this suite would catch it.
    private static func textKitVersion() {
        let view = MarkdownTextView()
        check("the Markdown view is on TextKit 1, which tables require",
              view.isUsingLegacyLayoutForTesting)
        view.textStorage?.setAttributedString(
            MarkdownRenderer.render("| A | B |\n|---|---|\n| 1 | 2 |\n"))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let used = view.layoutManager?.usedRect(for: view.textContainer!) ?? .zero
        check("a table lays out wider than a single stacked column",
              used.width > 120, "\(used.width)")
    }

    private static func markdownDetection() {
        check("common Markdown extensions are recognised",
              ["a.md", "b.markdown", "c.mdown", "d.mkd", "e.mdwn"]
                  .allSatisfy { PreviewPanelController.isMarkdown(URL(fileURLWithPath: "/tmp/\($0)")) })
        check("other documents are not treated as Markdown",
              !["a.txt", "b.pdf", "c.png", "d"].contains {
                  PreviewPanelController.isMarkdown(URL(fileURLWithPath: "/tmp/\($0)")) })
        check("the extension match ignores case",
              PreviewPanelController.isMarkdown(URL(fileURLWithPath: "/tmp/README.MD")))
    }

    @MainActor
    private static func paneLifecycle() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tursora-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.md")
        try? "# Heading\n\nbody text here\n".write(to: note, atomically: true, encoding: .utf8)
        let plain = root.appendingPathComponent("plain.txt")
        try? "not markdown".write(to: plain, atomically: true, encoding: .utf8)

        let provider = SmokeFixtures.EmptyProvider()
        let viewFile = root.appendingPathComponent("views.json")
        let controller = MainWindowController(provider: provider, places: PlacesModel(), initialURL: root,
                                              viewPropertiesStore: DirectoryViewPropertiesStore(fileURL: viewFile))
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 1200, height: 700))
        controller.window?.makeKeyAndOrderFront(nil)
        await expectEventually("fixture loaded") { controller.browser.model.generation > 0 }

        check("the pane starts hidden", !controller.isPreviewVisible)
        controller.togglePreviewPane(nil)
        check("toggling shows the pane", controller.isPreviewVisible && controller.previewPanel != nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        check("the pane has a usable width",
              (controller.previewPanel?.view.bounds.width ?? 0) >= 220,
              "\(controller.previewPanel?.view.bounds.width ?? -1)")

        // The file view is empty of a selection, so the pane shows the folder.
        controller.previewPanel?.show(note)
        check("a Markdown file renders as text, not through Quick Look",
              controller.previewPanel?.isShowingMarkdown == true
                  && controller.previewPanel?.isQuickLookVisibleForTesting != true)
        check("the rendered text is the document, with separators",
              (controller.previewPanel?.renderedTextForTesting ?? "").contains("Heading")
                  && (controller.previewPanel?.renderedTextForTesting ?? "").contains("\n"),
              (controller.previewPanel?.renderedTextForTesting ?? "").debugDescription)
        check("the pane titles itself with the file name",
              controller.previewPanel?.titleForTesting == "note.md",
              controller.previewPanel?.titleForTesting ?? "nil")

        controller.previewPanel?.show(plain)
        check("a non-Markdown file falls back to Quick Look",
              controller.previewPanel?.isShowingMarkdown == false)

        controller.previewPanel?.show(nil)
        check("no selection shows the empty state",
              controller.previewPanel?.isEmptyStateVisibleForTesting == true)

        let width = controller.previewPanel?.view.bounds.width ?? 0
        controller.hidePreviewPane()
        check("hiding removes the split item but keeps the controller",
              !controller.isPreviewVisible && controller.previewPanel != nil)
        controller.togglePreviewPane(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        check("reopening restores roughly the width it was closed at",
              abs((controller.previewPanel?.view.bounds.width ?? 0) - width) < 40,
              "was \(width), now \(controller.previewPanel?.view.bounds.width ?? -1)")

        // The sidebar is addressed by index elsewhere, so the pane must be
        // appended rather than inserted or that lookup silently shifts.
        check("the pane is appended, leaving the sidebar first",
              controller.isSidebarFirstSplitItemForTesting)
    }

    /// A pane that does not survive a quit is not a pane that "stays open".
    private static func sessionRoundTrip() {
        let state = WorkspaceWindowState(tabs: [WorkspaceTabState(panes: [
            WorkspacePaneState(url: URL(fileURLWithPath: NSHomeDirectory()))])],
            previewVisible: true, previewWidth: 412)
        guard let data = try? JSONEncoder().encode(state),
              let back = try? JSONDecoder().decode(WorkspaceWindowState.self, from: data) else {
            check("window state round-trips", false); return
        }
        check("the pane's visibility survives a session round trip", back.previewVisible)
        check("the pane's width survives a session round trip", back.previewWidth == 412, "\(back.previewWidth)")

        // An older session file has neither key; it must decode, not fail.
        let legacy = Data("""
        {"tabs":[{"panes":[{"url":"file:///tmp/"}]}],"selectedTabIndex":0}
        """.utf8)
        let old = try? JSONDecoder().decode(WorkspaceWindowState.self, from: legacy)
        check("a session saved before the pane existed still decodes", old != nil)
        check("and defaults to hidden", old?.previewVisible == false)

        let absurd = WorkspaceWindowState(tabs: state.tabs, previewVisible: true, previewWidth: 99_999)
        check("an absurd stored width is clamped",
              (absurd.sanitized()?.previewWidth ?? 0) <= 720, "\(absurd.sanitized()?.previewWidth ?? -1)")
    }
}

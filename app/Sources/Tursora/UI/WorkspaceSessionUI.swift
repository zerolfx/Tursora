import AppKit

extension WorkspacePaneState {
    /// A real directory named .zip remains a directory. When an offline path
    /// cannot be identified as an archive, preserve it for the inline error.
    var workspaceRestorationURL: URL {
        let workspace = ArchiveWorkspace.shared
        let logical = workspace.logicalURL(for: url)
        if !AppPreferences.experimentalZIPBrowsingEnabled,
           let archive = workspace.archiveURL(containing: logical) {
            return archive.deletingLastPathComponent()
        }
        return logical
    }

    func restoreWorkspacePane(in pane: BrowserViewController) {
        let destination = workspaceRestorationURL
        // Cancel deferred initial navigation before starting a result model.
        pane.navigate(to: destination)
        if destination.standardizedFileURL == url.standardizedFileURL, let search {
            pane.startSearch(search)
        }
        if destination.standardizedFileURL == url.standardizedFileURL, let viewState {
            pane.pendingWorkspaceView = (destination, search != nil, viewState.sanitized())
        }
    }
}

extension TabPage {
    var workspaceTabState: WorkspaceTabState {
        WorkspaceTabState(panes: panes.map(\.workspacePaneState), activePaneIndex: activeIndex,
                          customTitle: customTitle, splitFraction: workspaceSplitFraction)
    }

    func restoreWorkspaceTab(_ state: WorkspaceTabState) {
        guard let first = state.panes.first else { return }
        first.restoreWorkspacePane(in: panes[0])
        if state.panes.count > 1 {
            let right = split(with: state.panes[1].workspaceRestorationURL)
            state.panes[1].restoreWorkspacePane(in: right)
        }
        customTitle = state.customTitle
        setWorkspaceSplitFraction(state.splitFraction)
        if panes.indices.contains(state.activePaneIndex) { activate(panes[state.activePaneIndex]) }
    }
}

/// Window frames are screen coordinates, including the title bar. Reconnect a
/// saved desktop to today's displays without depending on screen identities.
enum WorkspaceWindowGeometry {
    static func constrainedFrame(_ proposed: NSRect, visibleFrames: [NSRect],
                                 minimumSize: NSSize = NSSize(width: 560, height: 360)) -> NSRect {
        let screens = visibleFrames.filter {
            $0.width.isFinite && $0.height.isFinite && $0.minX.isFinite && $0.minY.isFinite
                && $0.width > 0 && $0.height > 0
        }
        let finite = proposed.minX.isFinite && proposed.minY.isFinite
            && proposed.width.isFinite && proposed.height.isFinite && proposed.width > 0 && proposed.height > 0
        guard !screens.isEmpty else {
            return finite ? proposed : NSRect(origin: .zero, size: minimumSize)
        }
        let source = finite ? proposed : NSRect(origin: screens[0].origin, size: minimumSize)
        let screen = screens.max { a, b in
            let aa = intersectionArea(source, a), ba = intersectionArea(source, b)
            if aa != ba { return aa < ba }
            return distanceSquared(source, a) > distanceSquared(source, b)
        } ?? screens[0]
        let width = min(screen.width, max(minimumSize.width, source.width))
        let height = min(screen.height, max(minimumSize.height, source.height))
        return NSRect(x: min(screen.maxX - width, max(screen.minX, source.minX)),
                      y: min(screen.maxY - height, max(screen.minY, source.minY)),
                      width: width, height: height)
    }

    private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func distanceSquared(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let dx = a.midX - b.midX, dy = a.midY - b.midY
        return dx * dx + dy * dy
    }
}

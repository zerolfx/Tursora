import AppKit

/// The Finder drag behaviours that sit beside `FileOperations.dropOperation`:
/// which hovered target may spring open, how a ⌘-drag's narrowed mask is
/// reported back to AppKit, and which drag-source masks the file views offer.
///
/// Everything here is a pure function of its arguments (plus the archive
/// registry, which answers whether a location is a read-only ZIP snapshot), so
/// a headless run can check the rules without driving AppKit's own timers.
enum DragAndDrop {

    // MARK: - Drag-source masks

    /// What a file view offers while it is the drag source.
    ///
    /// AppKit narrows this mask by the modifier the user holds, and the
    /// destination sees only the narrowed value in
    /// `NSDraggingInfo.draggingSourceOperationMask`: ⌥ leaves `.copy`, ⌃
    /// leaves `.link` and ⌘ leaves `.generic`. `.generic` is therefore part of
    /// the offer so a ⌘-drag narrows to something rather than to nothing;
    /// without it a ⌘-drag ends with an empty mask and every destination
    /// refuses the drop.
    ///
    /// Read-only sources (archive entries) still offer `.copy` alone: their
    /// contents may be copied out but never moved, so ⌘ and ⌃ correctly
    /// narrow to nothing there.
    static func sourceMask(readOnly: Bool, local: Bool) -> NSDragOperation {
        if readOnly { return .copy }
        return local ? [.copy, .move, .generic] : [.copy, .move, .link, .generic]
    }

    /// AppKit hands a ⌘-drag's destination the narrowed mask `.generic`. A
    /// validation method must answer inside that mask or the destination stops
    /// accepting the drag, so report `.generic` where the shared rule decided
    /// on a move. `BrowserViewController.dropFiles` treats every operation
    /// that is not `.copy` as a move, so the work performed is unchanged.
    static func validationOperation(_ operation: NSDragOperation, sourceMask: NSDragOperation) -> NSDragOperation {
        (sourceMask == .generic && operation == .move) ? .generic : operation
    }

    /// Convenience for a drop destination: the shared rule, reported inside
    /// the mask AppKit narrowed to.
    static func validationOperation(for urls: [URL], into destination: URL,
                                    sourceMask: NSDragOperation) -> NSDragOperation {
        validationOperation(FileOperations.dropOperation(for: urls, into: destination, sourceMask: sourceMask),
                            sourceMask: sourceMask)
    }

    // MARK: - Spring-loaded folders

    /// Finder's own spring-loading switches live in the global domain as
    /// `com.apple.springing.enabled` and `com.apple.springing.delay`; AppKit
    /// reads them itself and runs the hover timer for every
    /// `NSSpringLoadingDestination`. Tursora never re-implements the timer, so
    /// this is only read for diagnostics and for the smoke test's record of
    /// where the delay comes from.
    static var systemSpringLoadingEnabled: Bool {
        UserDefaults.standard.object(forKey: "com.apple.springing.enabled") as? Bool ?? true
    }

    /// The machine's spring-loading hover delay in seconds, or nil when the
    /// user has never chosen one (AppKit then uses its own default).
    static var systemSpringLoadingDelay: TimeInterval? {
        UserDefaults.standard.object(forKey: "com.apple.springing.delay") as? TimeInterval
    }

    /// Whether hovering `destination` with `urls` may spring that target open.
    ///
    /// Spring loading follows the drop rule: a target springs open exactly
    /// where a drop would be accepted. On top of that it never fires on a
    /// file, on a read-only pane, inside an archive, on a dragged item itself,
    /// or on the folder the dragged items already live in — those are either
    /// impossible destinations or navigation the user did not ask for. The
    /// `sourceMask` is included so a ⌥-drag (which the drop rule answers with
    /// `.copy` even inside the items' own folder) does not spring open there.
    static func canSpringLoad(into destination: URL?, isNavigable: Bool, isReadOnly: Bool,
                              urls: [URL], sourceMask: NSDragOperation) -> Bool {
        guard let destination, isNavigable, !isReadOnly, !urls.isEmpty else { return false }
        let target = destination.standardizedFileURL
        if urls.contains(where: { $0.standardizedFileURL == target }) { return false }
        if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == target }) { return false }
        if ArchiveWorkspace.shared.containsArchiveLocation(destination) { return false }
        return !FileOperations.dropOperation(for: urls, into: destination, sourceMask: sourceMask).isEmpty
    }

    /// `NSSpringLoadingOptions` for a hovered target: enabled where
    /// `canSpringLoad` holds, disabled everywhere else. Hover activation stays
    /// on, so the behaviour matches Finder for users without Force Touch.
    static func springLoadingOptions(into destination: URL?, isNavigable: Bool, isReadOnly: Bool,
                                     urls: [URL], sourceMask: NSDragOperation) -> NSSpringLoadingOptions {
        canSpringLoad(into: destination, isNavigable: isNavigable, isReadOnly: isReadOnly,
                      urls: urls, sourceMask: sourceMask) ? .enabled : .disabled
    }
}

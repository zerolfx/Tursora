import AppKit

/// A toolbar-style button that fires its action on click and shows a menu on
/// long-press or right-click — the back/forward history buttons. Tracks the
/// mouse itself so the two gestures cannot both fire.
final class LongPressMenuButton: NSButton {

    var menuProvider: (() -> NSMenu?)?
    var longPressDelay: TimeInterval = 0.35

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isHighlighted = true
        let deadline = Date(timeIntervalSinceNow: longPressDelay)
        var showMenu = false
        var fire = false
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                            until: deadline, inMode: .eventTracking, dequeue: true) else {
                showMenu = true; break       // held past the delay
            }
            if e.type == .leftMouseUp {
                fire = bounds.contains(convert(e.locationInWindow, from: nil))
                break
            }
        }
        isHighlighted = false
        if showMenu { popMenu() } else if fire, let action { _ = sendAction(action, to: target) }
    }

    override func rightMouseDown(with event: NSEvent) { popMenu() }

    private func popMenu() {
        guard let menu = menuProvider?(), !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

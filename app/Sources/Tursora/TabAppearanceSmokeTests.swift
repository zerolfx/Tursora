import AppKit

/// Checks readable geometry, overflow routing, and adaptive tab rendering.
enum TabAppearanceSmokeTests: SmokeSuite {
    static let checkPrefix = "tab appearance: "
    static func run() {
        print("== tab layout and appearance ==")
        geometry()
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 720, height: TabBarView.height))
        let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        defer { window.close() }
        let titles = ["Design | Delivery", "A long folder name with a recognizable ending", "Research"]
        bar.reload(titles: titles, selected: 1, toolTips: ["/Design\n/Delivery", "/Long", "/Research"])
        bar.layoutSubtreeIfNeeded()
        for index in titles.indices {
            let frame = bar.tabFrameForTesting(index)
            let label = bar.titleFrameForTesting(index)
            let close = bar.closeFrameForTesting(index)
            check("title \(index) reserves symmetrical space", abs(label.midX - frame.midX) < 1)
            check("close \(index) has usable target", close.width >= 20 && close.height >= 20)
            check("hit test \(index)", bar.tabIndex(at: NSPoint(x: frame.midX, y: frame.midY)) == index)
        }
        let titleBeforeHover = bar.titleFrameForTesting(0)
        bar.setHoveredTabForTesting(0)
        check("hover reveals close without moving title", bar.isCloseVisibleForTesting(0) && bar.titleFrameForTesting(0) == titleBeforeHover)
        bar.setHoveredTabForTesting(nil)
        check("leaving a background tab hides close", !bar.isCloseVisibleForTesting(0))
        check("full split tooltip retained", bar.toolTips[0] == "/Design\n/Delivery")

        let many = (0..<20).map { "Folder \($0)" }
        bar.frame.size.width = 400
        bar.reload(titles: many, selected: 19)
        bar.layoutSubtreeIfNeeded()
        let layout = bar.layoutForTesting
        let selected = bar.tabFrameForTesting(19)
        check("overflow reveals last selected tab", layout.isOverflowing && layout.viewportFrame.contains(selected))
        check("scrolled selection hit test uses viewport coordinates", bar.tabIndex(at: NSPoint(x: selected.midX, y: selected.midY)) == 19)
        check("add button cannot resolve to an offscreen tab", bar.tabIndex(at: NSPoint(x: layout.addButtonFrame.midX, y: layout.addButtonFrame.midY)) == nil)
        let menu = bar.overflowMenuForTesting()
        check("overflow menu includes every title", menu.items.map(\.title) == many)
        check("overflow menu marks current page", menu.items.enumerated().filter { $0.element.state == .on }.map(\.offset) == [19])
        var chosen: Int?
        bar.onSelect = { chosen = $0 }
        let menuItem = menu.items[2]
        if let action = menuItem.action { NSApp.sendAction(action, to: menuItem.target, from: menuItem) }
        check("overflow menu routes clicked tab", chosen == 2)
        bar.reload(titles: many, selected: 0)
        bar.layoutSubtreeIfNeeded()
        check("switching back reveals first page", bar.layoutForTesting.viewportFrame.contains(bar.tabFrameForTesting(0)))
        bar.scrollForTesting(to: 500)
        let offset = bar.scrollOffsetForTesting
        bar.reload(titles: many, selected: 0)
        bar.layoutSubtreeIfNeeded()
        check("unrelated reload preserves user scroll", abs(bar.scrollOffsetForTesting - offset) < 1)
        chosen = nil
        if let action = menuItem.action { NSApp.sendAction(action, to: menuItem.target, from: menuItem) }
        check("stale overflow menu never selects another page", chosen == nil)
        let currentItem = bar.overflowMenuForTesting().items[0]
        if let action = currentItem.action { NSApp.sendAction(action, to: currentItem.target, from: currentItem) }
        bar.layoutSubtreeIfNeeded()
        check("choosing current tab reveals it after manual scrolling", bar.layoutForTesting.viewportFrame.contains(bar.tabFrameForTesting(0)))
        mouseInteractions(bar, window: window, titles: many)
        bar.reload(titles: titles, selected: 1)
        bar.frame.size.width = 720
        bar.layoutSubtreeIfNeeded()
        check("closing overflow restores visible geometry", !bar.layoutForTesting.isOverflowing && abs(bar.scrollOffsetForTesting) < 1)

        var fills: [CGFloat] = []
        for appearanceName: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua] {
            let appearance = NSAppearance(named: appearanceName)!
            window.appearance = appearance
            bar.needsDisplay = true
            bar.displayIfNeeded()
            for active in [true, false] {
                let colors = bar.resolvedColorsForTesting(appearance: appearance, active: active)
                check("\(appearanceName.rawValue) active=\(active) selected text is readable", contrast(colors.text, colors.selected) >= 4.5)
                check("\(appearanceName.rawValue) active=\(active) inactive text is readable", contrast(colors.secondaryText, colors.rail) >= 3)
                check("\(appearanceName.rawValue) active=\(active) selection has a distinct surface", abs(luminance(colors.selected) - luminance(colors.rail)) > 0.015)
            }
            let color = bar.resolvedColorsForTesting(appearance: appearance, active: true).background
            fills.append(luminance(color))
            if let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                bar.cacheDisplay(in: bar.bounds, to: bitmap)
                check("\(appearanceName.rawValue) produces rendered content", bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                let edge = bitmap.colorAt(x: 1, y: bitmap.pixelsHigh / 2)!
                check("\(appearanceName.rawValue) redraws the actual strip background", abs(luminance(edge) - luminance(color)) < 0.025)
            } else { check("\(appearanceName.rawValue) produces a bitmap", false) }
            let actualLabel = bar.actualRenderedTitleColorForTesting(1)!
            let expectedLabel = bar.resolvedColorsForTesting(appearance: appearance, active: window.isKeyWindow).text
            check("\(appearanceName.rawValue) refreshes the existing label", abs(luminance(actualLabel) - luminance(expectedLabel)) < 0.001)
        }
        check("light and dark produce different surfaces", fills[0] - fills[1] > 0.4)
        check("switching back restores original palette", abs(fills[0] - fills[4]) < 0.001)
    }

    private static func mouseInteractions(_ bar: TabBarView, window: NSWindow, titles: [String]) {
        bar.reload(titles: titles, selected: 19)
        bar.layoutSubtreeIfNeeded()
        let frame = bar.tabFrameForTesting(18)
        let start = NSPoint(x: frame.midX, y: frame.midY)
        var target = bar.hitTest(start)
        while let view = target, view !== bar, view.accessibilityRole() != .radioButton { target = view.superview }
        guard let target, target !== bar else { check("scrolled tab has an actionable hit target", false); return }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: bar.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var selected: Int?, dropped: Int?, moved: (Int, Int)?
        bar.onSelect = { selected = $0 }
        bar.onDropOutside = { index, _ in dropped = index }
        bar.onMove = { moved = ($0, $1) }
        target.mouseDown(with: event(.leftMouseDown, start))
        check("mouse down preserves the split drop destination", selected == nil)
        let below = NSPoint(x: start.x, y: -20)
        target.mouseDragged(with: event(.leftMouseDragged, below))
        target.mouseUp(with: event(.leftMouseUp, below))
        check("vertical drag from scrolled tab reports original identity", dropped == 18 && selected == nil)
        target.mouseDown(with: event(.leftMouseDown, start))
        target.mouseUp(with: event(.leftMouseUp, start))
        check("ordinary tab click still selects on release", selected == 18)
        selected = nil
        target.mouseDown(with: event(.leftMouseDown, start))
        let to = NSPoint(x: start.x - bar.tabWidth, y: start.y)
        target.mouseDragged(with: event(.leftMouseDragged, to))
        target.mouseUp(with: event(.leftMouseUp, to))
        check("reorder after scroll reports model indices", moved?.0 == 18 && moved?.1 == 17 && selected == nil)
        bar.reload(titles: titles, selected: 19)
        bar.layoutSubtreeIfNeeded()
        target.mouseDown(with: event(.leftMouseDown, start))
        target.mouseDragged(with: event(.leftMouseDragged, to))
        moved = nil
        bar.reload(titles: ["Survivor"], selected: 0)
        target.mouseUp(with: event(.leftMouseUp, to))
        check("model reload cancels an in-flight reorder safely", moved == nil && bar.titles == ["Survivor"])
    }

    private static func geometry() {
        for width: CGFloat in [0, 50, 240, 400, 720, 1200, 1800] {
            for count in [0, 1, 2, 3, 8, 40] {
                let layout = TabStripLayout(width: width, height: TabBarView.height, tabCount: count)
                check("\(width)/\(count) finite nonnegative geometry", layout.tabWidth.isFinite && layout.tabWidth >= 0 && layout.viewportFrame.width >= 0 && layout.contentWidth >= 0)
                guard width >= 240, count > 0 else { continue }
                check("\(width)/\(count) new tab remains outside viewport", layout.viewportFrame.maxX <= layout.addButtonFrame.minX)
                check("\(width)/\(count) titles remain readable", layout.tabWidth >= 120)
                let frames = (0..<count).map { layout.frameForTab($0) }
                check("\(width)/\(count) tab slots never overlap", zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.01 })
                check("\(width)/\(count) document contains last tab", frames.last!.maxX <= layout.contentWidth + 0.01)
                if let overflow = layout.overflowButtonFrame {
                    check("\(width)/\(count) overflow controls never overlap", overflow.minX >= layout.viewportFrame.maxX && overflow.maxX <= layout.addButtonFrame.minX)
                }
            }
        }
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return -1 }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let foreground = a.usingColorSpace(.sRGB), let background = b.usingColorSpace(.sRGB) else { return 0 }
        let alpha = foreground.alphaComponent
        let rendered = NSColor(srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
                               green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
                               blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha), alpha: 1)
        let x = luminance(rendered), y = luminance(background)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

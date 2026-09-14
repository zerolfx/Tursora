import AppKit

/// Checks readable geometry, overflow routing, and adaptive tab rendering.
enum TabAppearanceSmokeTests: SmokeSuite {
    static let checkPrefix = "tab appearance: "
    static func run() {
        print("== tab layout and appearance ==")
        geometry()
        softWidthCap()
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
        splitTitleDivider(bar, window: window)
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

    /// A tab stops growing well before the window edge, but the cap yields to a
    /// title that needs the room, and New Tab follows the tabs it adds to (D79).
    private static func softWidthCap() {
        let height = TabBarView.height
        let lone = TabStripLayout(width: 1600, height: height, tabCount: 1)
        check("a lone tab stops at the preferred width instead of filling the strip",
              lone.tabWidth == TabStripLayout.preferredTabWidth, "\(lone.tabWidth)")
        check("New Tab follows a lone tab instead of sitting at the trailing edge",
              lone.addButtonFollowsTabs
                  && abs(lone.addButtonFrame.minX - (lone.viewportFrame.maxX + TabStripLayout.controlGap)) < 0.01,
              "add=\(lone.addButtonFrame.minX) viewport=\(lone.viewportFrame.maxX)")
        check("New Tab nowhere near the trailing edge of a mostly empty strip",
              lone.addButtonFrame.maxX < 1600 / 3, "\(lone.addButtonFrame.maxX)")
        check("a short title never shrinks a tab below the preferred width",
              TabStripLayout(width: 1600, height: height, tabCount: 1, naturalTabWidth: 60).tabWidth
                  == TabStripLayout.preferredTabWidth)
        let long = TabStripLayout(width: 1600, height: height, tabCount: 1, naturalTabWidth: 360)
        check("a long title passes the preferred width when the strip has the room",
              long.tabWidth == 360, "\(long.tabWidth)")
        check("no title grows a tab past the ceiling",
              TabStripLayout(width: 1600, height: height, tabCount: 1, naturalTabWidth: 5000).tabWidth
                  == TabStripLayout.maximumTabWidth)
        let pair = TabStripLayout(width: 1600, height: height, tabCount: 2, naturalTabWidth: 300)
        check("every tab keeps one width, so a drag hit test stays uniform",
              pair.tabWidth == 300 && pair.frameForTab(1).minX - pair.frameForTab(0).minX == pair.tabWidth)
        let crowded = TabStripLayout(width: 900, height: height, tabCount: 5, naturalTabWidth: 400)
        check("a crowded strip shares its room equally rather than honouring the title",
              crowded.tabWidth < TabStripLayout.preferredTabWidth, "\(crowded.tabWidth)")
        check("tabs that fill the strip leave New Tab at the trailing edge",
              !crowded.addButtonFollowsTabs
                  && abs(crowded.addButtonFrame.maxX - (900 - TabStripLayout.horizontalInset)) < 0.01)
        let packed = TabStripLayout(width: 400, height: height, tabCount: 20)
        check("an overflowing strip keeps New Tab beside the overflow control",
              packed.isOverflowing && !packed.addButtonFollowsTabs
                  && packed.addButtonFrame.minX > packed.overflowButtonFrame!.minX)
    }

    /// A split name is divided by a drawn rule that runs the height of the tab,
    /// not by a "|" character sitting on the text baseline (D78).
    private static func splitTitleDivider(_ bar: TabBarView, window: NSWindow) {
        bar.frame.size.width = 720
        let split = TabTitle(left: "Design", right: "Delivery")
        bar.reload(titles: [split, TabTitle("Research")], selected: 0)
        bar.layoutSubtreeIfNeeded()
        check("a plain tab draws no rule", bar.titleDividerFrameForTesting(1) == nil)
        check("a plain tab has no trailing name", bar.trailingTitleFrameForTesting(1) == nil)
        guard let rule = bar.titleDividerFrameForTesting(0),
              let trailing = bar.trailingTitleFrameForTesting(0) else {
            check("a split tab draws a rule between its two names", false, "no rule or trailing label")
            return
        }
        let leading = bar.titleFrameForTesting(0), tab = bar.tabFrameForTesting(0)
        check("a split tab draws a rule between its two names",
              leading.maxX <= rule.minX + 0.01 && rule.maxX <= trailing.minX + 0.01,
              "\(leading) \(rule) \(trailing)")
        check("the rule runs the height of the tab rather than the height of the text",
              rule.height >= tab.height - 1.01 && rule.minY <= tab.minY + 0.51 && rule.height > leading.height,
              "rule=\(rule) tab=\(tab) text=\(leading)")
        check("the rule is a hairline", rule.width == TabBarView.titleDividerWidth)
        check("the rule keeps air on both sides",
              abs(rule.minX - leading.maxX - TabBarView.titleDividerGap) < 0.01
                  && abs(trailing.minX - rule.maxX - TabBarView.titleDividerGap) < 0.01)
        check("both names are visible and never overlap",
              leading.width > 0 && trailing.width > 0 && leading.maxX <= trailing.minX)
        check("the pair sits centred in the tab",
              abs((leading.minX + trailing.maxX) / 2 - tab.midX) < 1,
              "\(leading.minX) \(trailing.maxX) \(tab.midX)")
        check("no name carries the separator character",
              !bar.tabTitles[0].left.contains("|") && !(bar.tabTitles[0].right?.contains("|") ?? false))
        check("the plain form still joins for tooltips and renaming", bar.titles[0] == "Design | Delivery")
        // The owner chose the plain rule over dimming the inactive side, so
        // neither half may be rendered as the quieter one (D78).
        bar.reload(titles: [split, TabTitle(left: "Notes", right: "Drafts")], selected: 0)
        bar.layoutSubtreeIfNeeded()
        check("both halves of a split name render in the same colour",
              bar.actualRenderedTitleColorForTesting(0) == bar.trailingRenderedTitleColorForTesting(0)
                  && bar.actualRenderedTitleColorForTesting(1) == bar.trailingRenderedTitleColorForTesting(1))
        check("a background split tab dims both halves together, not one of them",
              bar.actualRenderedTitleColorForTesting(1) != bar.actualRenderedTitleColorForTesting(0))
        check("a background split tab still draws its rule", bar.titleDividerFrameForTesting(1) != nil)
        check("the divider is quieter on a background tab than on the selected one",
              bar.titleDividerColorsForTesting(appearance: NSAppearance(named: .aqua)!, active: true)
                  .selected.alphaComponent
                  > bar.titleDividerColorsForTesting(appearance: NSAppearance(named: .aqua)!, active: true)
                      .inactive.alphaComponent)

        // Two long names share the room; a short one keeps all it needs.
        let wide = String(repeating: "Wide ", count: 20), narrow = "Doc"
        bar.reload(titles: [TabTitle(left: wide, right: wide)], selected: 0)
        bar.layoutSubtreeIfNeeded()
        if let both = bar.trailingTitleFrameForTesting(0) {
            check("two long names are truncated to the same width",
                  abs(bar.titleFrameForTesting(0).width - both.width) < 1,
                  "\(bar.titleFrameForTesting(0).width) \(both.width)")
        } else { check("two long names are truncated to the same width", false, "no trailing label") }
        bar.reload(titles: [TabTitle(left: narrow, right: wide)], selected: 0)
        bar.layoutSubtreeIfNeeded()
        let short = bar.titleFrameForTesting(0)
        check("a short name is not truncated beside a long one",
              short.width < bar.tabFrameForTesting(0).width / 3 && short.width > 0, "\(short.width)")
        if let rest = bar.trailingTitleFrameForTesting(0) {
            check("the long name takes the room the short one leaves", rest.width > short.width * 2)
        } else { check("the long name takes the room the short one leaves", false, "no trailing label") }
        // A name must render whole when the tab has room for it. NSTextField
        // insets its text inside its cell, so a label framed at the raw glyph
        // width truncates with an ellipsis even in a half-empty tab — the exact
        // failure D78 exists to remove. The cell reports that itself.
        bar.reload(titles: [TabTitle(left: "Documents", right: "Downloads")], selected: 0)
        bar.layoutSubtreeIfNeeded()
        check("neither half of a split name is truncated when the tab has room",
              bar.isTitleFullyShownForTesting(0) == true && bar.isTrailingTitleFullyShownForTesting(0) == true,
              "tab=\(bar.tabWidth) leading=\(bar.titleFrameForTesting(0).width) trailing=\(String(describing: bar.trailingTitleFrameForTesting(0)?.width))")
        bar.reload(titles: [TabTitle("Documents")], selected: 0)
        bar.layoutSubtreeIfNeeded()
        check("a plain name is not truncated either", bar.isTitleFullyShownForTesting(0) == true)

        // The strip must do its own measuring. Every check above this point
        // survives `naturalTabWidth` returning 0, because a fair share binds
        // below the preferred width in those fixtures. This one does not: at one
        // tab in a 720 pt strip the share is 672, so the measurement decides.
        bar.reload(titles: [TabTitle("Doc")], selected: 0)
        bar.layoutSubtreeIfNeeded()
        check("a short title settles a lone tab at the preferred width",
              bar.tabWidth == TabStripLayout.preferredTabWidth, "\(bar.tabWidth)")
        bar.reload(titles: [TabTitle(left: wide, right: wide)], selected: 0)
        bar.layoutSubtreeIfNeeded()
        let measured = bar.tabWidth
        check("the strip measures a long title and grows the tab past the preferred width",
              measured > TabStripLayout.preferredTabWidth && measured <= TabStripLayout.maximumTabWidth,
              "\(measured)")
        // And the measurement must count the divider, not just the two names.
        let pair = ("Quarterly Planning", "Delivery Review")
        bar.reload(titles: [TabTitle(left: pair.0, right: pair.1)], selected: 0)
        bar.layoutSubtreeIfNeeded()
        let splitWidth = bar.tabWidth
        bar.reload(titles: [TabTitle(pair.0)], selected: 0)
        bar.layoutSubtreeIfNeeded()
        check("a split tab is wider than the same tab unsplit", splitWidth > bar.tabWidth,
              "split=\(splitWidth) plain=\(bar.tabWidth)")
        _ = window
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

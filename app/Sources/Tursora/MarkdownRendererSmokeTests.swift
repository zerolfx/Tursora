import AppKit

/// `MarkdownRenderer` is a pure function, so it is checked here without a text
/// view: source in, attributed string out. The checks that matter are the ones
/// the parser does NOT give us for free — block separators, fonts, list
/// markers, table geometry — because `AttributedString(markdown:)` emits
/// semantics only and a styling pass that quietly stops working would still
/// produce a string that reads correctly in a log.
enum MarkdownRendererSmokeTests: SmokeSuite {
    static var checkPrefix: String { "markdown: " }

    static func run() {
        print("== markdown rendering ==")
        separators()
        headings()
        inlineTraits()
        lists()
        inlineSurvivesBlockStyle()
        codeAndQuote()
        tables()
        hazards()
    }

    /// The headline defect the parser hands you: without a styling pass,
    /// "# Head\n\npara" comes back as "Headpara" on one line.
    private static func separators() {
        let out = MarkdownRenderer.render("# Head\n\npara\n\n- a\n- b\n")
        check("blocks are separated, which the parser does not do",
              out.string.contains("\n"), out.string.debugDescription)
        check("a heading does not run into the paragraph below it",
              !out.string.contains("Headpara"), out.string.debugDescription)
        let plain = try? AttributedString(markdown: "# Head\n\npara", options: .init(interpretedSyntax: .full))
        check("the raw parser really does omit separators, so the pass is load-bearing",
              plain.map { !String($0.characters).contains("\n") } ?? false)
    }

    private static func headings() {
        let theme = MarkdownRenderer.Theme.default
        let out = MarkdownRenderer.render("# One\n\n###### Six\n\nbody\n")
        func size(of needle: String) -> CGFloat? {
            let range = (out.string as NSString).range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return (out.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?.pointSize
        }
        check("a level 1 heading is the largest size", size(of: "One") == theme.headingSizes[0], "\(String(describing: size(of: "One")))")
        check("a level 6 heading is the smallest", size(of: "Six") == theme.headingSizes[5], "\(String(describing: size(of: "Six")))")
        check("body text is body size", size(of: "body") == theme.bodySize, "\(String(describing: size(of: "body")))")
        check("headings outrank body", (size(of: "One") ?? 0) > (size(of: "body") ?? 0))
    }

    private static func inlineTraits() {
        let out = MarkdownRenderer.render("plain **bold** *italic* `code` ~~gone~~\n")
        func font(_ needle: String) -> NSFont? {
            let range = (out.string as NSString).range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return out.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }
        let manager = NSFontManager.shared
        check("bold is bold", font("bold").map { manager.traits(of: $0).contains(.boldFontMask) } ?? false)
        check("italic is italic", font("italic").map { manager.traits(of: $0).contains(.italicFontMask) } ?? false)
        check("inline code is monospaced",
              font("code").map { $0.fontName != NSFont.systemFont(ofSize: 13).fontName } ?? false,
              font("code")?.fontName ?? "nil")
        let range = (out.string as NSString).range(of: "gone")
        check("strikethrough is marked", range.location != NSNotFound
              && out.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) != nil)
        check("plain text carries no traits",
              font("plain").map { !manager.traits(of: $0).contains(.boldFontMask) } ?? false)
    }

    private static func lists() {
        let bullets = MarkdownRenderer.render("- alpha\n- beta\n")
        check("an unordered item gets a bullet the parser never emitted",
              bullets.string.contains("•"), bullets.string.debugDescription)
        let numbers = MarkdownRenderer.render("1. first\n2. second\n")
        check("an ordered list numbers from its own ordinals",
              numbers.string.contains("1.") && numbers.string.contains("2."), numbers.string.debugDescription)
        let range = (bullets.string as NSString).range(of: "alpha")
        let style = bullets.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        check("a list item is indented", (style?.headIndent ?? 0) > 0, "\(style?.headIndent ?? -1)")

        // Nesting is where a marker goes wrong quietly. `components` runs
        // innermost first, so taking the last `.listItem` gives a sub-item its
        // parent's number, and searching the whole stack for `.orderedList`
        // numbers a bullet that merely sits under a numbered step. Both shapes
        // are ordinary in a README, so both are pinned here.
        let nested = MarkdownRenderer.render("1. Install\n2. Configure\n   1. Open\n   2. Edit\n   3. Save\n")
        check("a nested ordered list counts from its own level",
              nested.string.contains("1.\tOpen") && nested.string.contains("2.\tEdit")
                  && nested.string.contains("3.\tSave"), nested.string.debugDescription)
        let mixed = MarkdownRenderer.render("1. Clone the repo\n   - over HTTPS\n   - over SSH\n")
        check("bullets under a numbered step stay bullets",
              mixed.string.components(separatedBy: "•").count == 3, mixed.string.debugDescription)
        check("and the numbered step keeps its own number",
              mixed.string.contains("1.\tClone"), mixed.string.debugDescription)
        let deeper = MarkdownRenderer.render("- outer\n  - inner\n")
        let innerRange = (deeper.string as NSString).range(of: "inner")
        let outerRange = (deeper.string as NSString).range(of: "outer")
        let innerIndent = (deeper.attribute(.paragraphStyle, at: innerRange.location, effectiveRange: nil)
            as? NSParagraphStyle)?.headIndent ?? 0
        let outerIndent = (deeper.attribute(.paragraphStyle, at: outerRange.location, effectiveRange: nil)
            as? NSParagraphStyle)?.headIndent ?? 0
        check("a deeper level indents further", innerIndent > outerIndent, "\(outerIndent) -> \(innerIndent)")

        // One item, two blocks: the marker belongs to the first only.
        let multi = MarkdownRenderer.render("- para one\n\n  para two\n")
        check("a list item made of several blocks is marked once",
              multi.string.components(separatedBy: "•").count == 2, multi.string.debugDescription)
    }

    /// Block styling used to be applied over the whole block after the inline
    /// work, which erased it: inline code in a heading lost its monospace, and
    /// a link in a block quote lost its colour.
    private static func inlineSurvivesBlockStyle() {
        let heading = MarkdownRenderer.render("### Use the `--verbose` flag\n")
        let theme = MarkdownRenderer.Theme.default
        func font(_ s: NSAttributedString, _ needle: String) -> NSFont? {
            let r = (s.string as NSString).range(of: needle)
            guard r.location != NSNotFound else { return nil }
            return s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        }
        let code = font(heading, "--verbose")
        let words = font(heading, "Use")
        check("inline code inside a heading keeps a monospaced face",
              code?.fontName != words?.fontName, "\(code?.fontName ?? "nil") vs \(words?.fontName ?? "nil")")
        check("and keeps the heading's size rather than shrinking to body",
              code?.pointSize == theme.headingSizes[2], "\(code?.pointSize ?? -1)")

        let quoted = MarkdownRenderer.render("> see [the docs](https://example.invalid)\n")
        let r = (quoted.string as NSString).range(of: "the docs")
        check("a link inside a block quote keeps the link colour",
              quoted.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor == .linkColor,
              "\(String(describing: quoted.attribute(.foregroundColor, at: r.location, effectiveRange: nil)))")
        let plainRange = (quoted.string as NSString).range(of: "see")
        check("but the quote's own text stays secondary",
              quoted.attribute(.foregroundColor, at: plainRange.location, effectiveRange: nil) as? NSColor
                  == .secondaryLabelColor)

        let emphasised = MarkdownRenderer.render("## *Why* it matters\n")
        check("emphasis inside a heading survives",
              font(emphasised, "Why").map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false)
        check("and the heading size still applies to it",
              font(emphasised, "Why")?.pointSize == theme.headingSizes[1],
              "\(font(emphasised, "Why")?.pointSize ?? -1)")
    }

    private static func codeAndQuote() {
        let out = MarkdownRenderer.render("```swift\nlet x = 1\nlet y = 2\n```\n")
        check("a fenced block keeps its own newlines",
              out.string.contains("let x = 1\nlet y = 2"), out.string.debugDescription)
        let range = (out.string as NSString).range(of: "let x")
        let font = out.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        check("a fenced block is monospaced",
              font?.fontName != NSFont.systemFont(ofSize: 13).fontName, font?.fontName ?? "nil")
        let quote = MarkdownRenderer.render("> quoted\n")
        let qRange = (quote.string as NSString).range(of: "quoted")
        let qStyle = quote.attribute(.paragraphStyle, at: qRange.location, effectiveRange: nil) as? NSParagraphStyle
        check("a block quote is indented", (qStyle?.headIndent ?? 0) > 0, "\(qStyle?.headIndent ?? -1)")

        // Every line of a fenced block is its own paragraph to TextKit, so
        // block spacing would open a gap between each line of the sample.
        let codeStyle = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        check("a fenced block has no spacing between its lines",
              codeStyle?.paragraphSpacing == 0, "\(codeStyle?.paragraphSpacing ?? -1)")
    }

    /// Tables need `NSTextTableBlock`, which only takes effect under TextKit 1.
    /// The blocks are built here; `MarkdownPreviewView` pins the TextKit 1 side.
    private static func tables() {
        let out = MarkdownRenderer.render("| A | B |\n|:--|--:|\n| 1 | 2 |\n")
        var blocks: [NSTextTableBlock] = []
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            blocks.append(contentsOf: ((value as? NSParagraphStyle)?.textBlocks ?? []).compactMap { $0 as? NSTextTableBlock })
        }
        check("every cell becomes a table block", blocks.count == 4, "\(blocks.count)")
        check("the table has the parsed column count",
              blocks.first?.table.numberOfColumns == 2, "\(blocks.first?.table.numberOfColumns ?? -1)")
        check("all four cells share one table",
              Set(blocks.map { ObjectIdentifier($0.table) }).count == 1)
        let coordinates = Set(blocks.map { "\($0.startingRow),\($0.startingColumn)" })
        check("cells land on distinct row/column coordinates",
              coordinates == ["0,0", "0,1", "1,0", "1,1"], "\(coordinates.sorted())")
        // Two tables with only a blank line between them produce no block in
        // between, so a run-based reset merges them into one NSTextTable and
        // they overlap on screen.
        let twice = MarkdownRenderer.render("| A | B |\n|---|---|\n| 1 | 2 |\n\n| C | D |\n|---|---|\n| 3 | 4 |\n")
        var tables: Set<ObjectIdentifier> = []
        twice.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: twice.length)) { value, _, _ in
            for block in ((value as? NSParagraphStyle)?.textBlocks ?? []) {
                if let cell = block as? NSTextTableBlock { tables.insert(ObjectIdentifier(cell.table)) }
            }
        }
        check("two adjacent tables stay two tables", tables.count == 2, "\(tables.count)")

        let cellA = (out.string as NSString).range(of: "A")
        let alignment = (out.attribute(.paragraphStyle, at: cellA.location, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        check("a left-aligned column is left aligned", alignment == .left, "\(String(describing: alignment))")
        let cellB = (out.string as NSString).range(of: "B")
        let right = (out.attribute(.paragraphStyle, at: cellB.location, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        check("a right-aligned column is right aligned", right == .right, "\(String(describing: right))")
    }

    /// The cases that crash or mis-style a naive styling pass.
    private static func hazards() {
        // Raw block HTML arrives with NO presentation intent. A pass that force
        // unwraps it crashes on any README containing a <div> or <img>.
        let html = MarkdownRenderer.render("para\n\n<div>raw</div>\n\nafter\n")
        check("raw block HTML does not crash the pass and keeps its text",
              html.string.contains("raw"), html.string.debugDescription)
        check("raw HTML is not glued onto the previous paragraph",
              !html.string.contains("para<div"), html.string.debugDescription)

        check("empty input yields empty output", MarkdownRenderer.render("").length == 0)
        check("plain text with no markup survives", MarkdownRenderer.render("just words").string.contains("just words"))

        // A link's target is resolved but nothing is opened here; the view
        // decides. What matters is that the attribute exists to decide on.
        let linked = MarkdownRenderer.render("[text](./other.md)", baseURL: URL(fileURLWithPath: "/tmp/"))
        let range = (linked.string as NSString).range(of: "text")
        check("a relative link resolves against the base URL",
              (linked.attribute(.link, at: range.location, effectiveRange: nil) as? URL)?.path == "/tmp/other.md",
              "\(String(describing: linked.attribute(.link, at: range.location, effectiveRange: nil)))")

        // An oversized document is truncated rather than laid out whole.
        let huge = String(repeating: "word ", count: MarkdownRenderer.maxSourceCharacters)
        check("an oversized document is bounded",
              MarkdownRenderer.render(huge).length <= MarkdownRenderer.maxSourceCharacters,
              "\(MarkdownRenderer.render(huge).length)")
    }
}

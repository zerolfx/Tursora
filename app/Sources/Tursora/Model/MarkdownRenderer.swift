import AppKit

/// Turns Markdown into something readable.
///
/// `AttributedString(markdown:)` parses CommonMark plus GitHub's table,
/// strikethrough and autolink extensions, but it produces **semantics only**:
/// no newlines between blocks, no fonts, no paragraph styles, no colour.
/// `# Head\n\npara\n\n- a\n- b` comes back as the single run-set
/// `"Headparaab"`. Everything that makes it look like a document — the block
/// separators, the heading sizes, list markers, indents, code face and table
/// geometry — is synthesised here.
///
/// This is deliberately a pure function of its input so it can be checked
/// headlessly, without a text view: `render` in, attributed string out.
/// Colours are the dynamic system ones, so the result follows the user's
/// light or dark appearance rather than being a slab of paper (D81).
enum MarkdownRenderer {

    /// Sizes and spacing, in points. Grouped so a check can vary one value
    /// without rebuilding the whole style by hand.
    struct Theme {
        var bodySize: CGFloat = 13
        var codeSize: CGFloat = 12
        /// Heading point sizes for levels 1...6; deeper levels reuse the last.
        var headingSizes: [CGFloat] = [24, 19, 16, 14, 13, 13]
        var paragraphSpacing: CGFloat = 10
        var headingSpacingBefore: CGFloat = 14
        var listIndent: CGFloat = 22
        var quoteIndent: CGFloat = 16
        var cellPadding: CGFloat = 4

        static let `default` = Theme()
    }

    /// The largest source we will lay out. A preview pane is not an editor,
    /// and TextKit 1 with tables gets slow long before this.
    static let maxSourceCharacters = 512_000

    /// Markdown source to styled text. `baseURL` only resolves relative link
    /// targets so the view can decide what to do with them; nothing is loaded
    /// from it here.
    static func render(_ source: String, baseURL: URL? = nil, theme: Theme = .default) -> NSAttributedString {
        let bounded = source.count > maxSourceCharacters
            ? String(source.prefix(maxSourceCharacters)) : source
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        // A parse failure still yields something: the source as plain text
        // beats an empty pane with no explanation.
        guard let parsed = try? AttributedString(markdown: bounded, options: options, baseURL: baseURL) else {
            return NSAttributedString(string: bounded, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: theme.codeSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        }
        return style(parsed, theme: theme)
    }

    // MARK: - Block walk

    /// One contiguous block of the document, with the intent stack that
    /// produced it. Runs are accumulated before styling because a block's
    /// paragraph style depends on the whole stack, not on one run.
    private struct Block {
        var kinds: [PresentationIntent.Kind] = []
        var identity: Int = 0
        var pieces: [(text: String, inline: InlinePresentationIntent?, link: URL?)] = []
        /// The enclosing list item, so a item made of several blocks — a
        /// paragraph then a code sample, say — is marked once rather than on
        /// every block it contains.
        var listItemIdentity: Int?
        var wantsMarker = false
        /// Identity of the enclosing table intent. Two tables separated only by
        /// a blank line would otherwise share one `NSTextTable` and overlap.
        var tableIdentity: Int?
    }

    private static func style(_ parsed: AttributedString, theme: Theme) -> NSAttributedString {
        var blocks: [Block] = []
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }
            // Raw HTML arrives with no presentation intent at all. Treating a
            // nil intent as "same block as before" would glue a <div> onto the
            // previous paragraph, so it gets a block of its own.
            let components = run.presentationIntent?.components ?? []
            let identity = run.presentationIntent?.components.first?.identity ?? -1
            let kinds = components.map(\.kind)
            if var last = blocks.last, last.identity == identity, identity != -1 {
                last.pieces.append((text, run.inlinePresentationIntent, run.link))
                blocks[blocks.count - 1] = last
            } else {
                var block = Block(kinds: kinds, identity: identity,
                                  pieces: [(text, run.inlinePresentationIntent, run.link)])
                block.listItemIdentity = components.first(where: {
                    if case .listItem = $0.kind { return true }
                    return false
                })?.identity
                block.wantsMarker = block.listItemIdentity != nil
                    && block.listItemIdentity != blocks.last?.listItemIdentity
                block.tableIdentity = components.first(where: {
                    if case .table = $0.kind { return true }
                    return false
                })?.identity
                blocks.append(block)
            }
        }
        return assemble(blocks, theme: theme)
    }

    private static func assemble(_ blocks: [Block], theme: Theme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var table: NSTextTable?
        var tableColumns = 0
        var tableIdentity: Int?

        for block in blocks {
            let isCell = block.kinds.contains { if case .tableCell = $0 { return true }; return false }
            // A run of cells ends at the first non-cell block, but two tables
            // separated only by a blank line produce no block between them —
            // so the table's own identity is what tells them apart.
            if !isCell || block.tableIdentity != tableIdentity {
                table = nil
                tableIdentity = isCell ? block.tableIdentity : nil
            }

            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            let start = out.length
            out.append(inlineText(block, theme: theme))

            if isCell {
                if table == nil {
                    table = NSTextTable()
                    tableColumns = block.kinds.compactMap {
                        if case .table(let columns) = $0 { return columns.count }
                        return nil
                    }.first ?? 1
                    table?.numberOfColumns = tableColumns
                }
                applyCell(block, table: table, columns: tableColumns, theme: theme,
                          to: out, range: NSRange(location: start, length: out.length - start))
            } else {
                applyBlock(block, theme: theme, to: out,
                           range: NSRange(location: start, length: out.length - start))
            }
        }
        return out
    }

    // MARK: - Inline

    /// The block's own face and colour, which inline traits then build on.
    /// Applying these afterwards as a blanket attribute would erase the inline
    /// work: `### Use the `--verbose` flag` would lose its monospace, and a
    /// link inside a block quote would lose its link colour.
    private static func baseAttributes(_ block: Block, theme: Theme) -> (font: NSFont, colour: NSColor) {
        var size = theme.bodySize
        var weight: NSFont.Weight = .regular
        var colour = NSColor.labelColor
        var monospaced = false
        for kind in block.kinds {
            switch kind {
            case .header(let level):
                size = theme.headingSizes[max(0, min(level, theme.headingSizes.count) - 1)]
                weight = .semibold
            case .codeBlock:
                size = theme.codeSize
                monospaced = true
            case .blockQuote:
                colour = .secondaryLabelColor
            case .thematicBreak:
                colour = .tertiaryLabelColor
            default:
                break
            }
        }
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return (font, colour)
    }

    private static func inlineText(_ block: Block, theme: Theme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base = baseAttributes(block, theme: theme)
        for piece in block.pieces {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: base.colour]
            let intent = piece.inline ?? []
            // Inline code keeps the block's size so it does not shrink inside a
            // heading, but takes the monospaced face.
            var font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: base.font.pointSize, weight: .regular)
                : base.font
            var traits: NSFontTraitMask = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            if !traits.isEmpty {
                font = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
            attributes[.font] = font
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if intent.contains(.code) {
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.25)
            }
            if let link = piece.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: piece.text, attributes: attributes))
        }
        return out
    }

    // MARK: - Block styling

    private static func applyBlock(_ block: Block, theme: Theme,
                                   to out: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = theme.paragraphSpacing

        var depth = 0
        for kind in block.kinds {
            switch kind {
            case .header:
                style.paragraphSpacingBefore = theme.headingSpacingBefore
            case .codeBlock:
                style.firstLineHeadIndent = theme.quoteIndent
                style.headIndent = theme.quoteIndent
                // A fenced block keeps its own newlines, so TextKit sees every
                // line as a paragraph. Block spacing here would open a gap
                // between each line of the sample.
                style.paragraphSpacing = 0
                out.addAttribute(.backgroundColor,
                                 value: NSColor.quaternaryLabelColor.withAlphaComponent(0.18), range: range)
            case .blockQuote:
                style.firstLineHeadIndent = theme.quoteIndent
                style.headIndent = theme.quoteIndent
            case .unorderedList, .orderedList:
                depth += 1
            default:
                break
            }
        }

        // Every block inside a list item is indented; only the first carries
        // the marker, so an item made of a paragraph and then a code sample
        // lines up without being bulleted twice.
        if block.listItemIdentity != nil {
            let indent = theme.listIndent * CGFloat(max(1, depth))
            style.headIndent = indent
            style.firstLineHeadIndent = block.wantsMarker ? indent - theme.listIndent : indent
            style.paragraphSpacing = theme.paragraphSpacing / 2
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            if block.wantsMarker, let marker = listMarker(block) {
                out.insert(NSAttributedString(string: marker + "\t", attributes: [
                    .font: NSFont.systemFont(ofSize: theme.bodySize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]), at: range.location)
            }
        }

        let markerLength = (block.wantsMarker ? listMarker(block) : nil).map { $0.count + 1 } ?? 0
        let full = NSRange(location: range.location, length: range.length + markerLength)
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(
            location: full.location, length: min(full.length, out.length - full.location)))
    }

    /// `- ` for a bullet, `1. ` for an ordered item. Nil when the block is not
    /// a list item, which is also how the caller knows not to indent.
    /// `- ` for a bullet, `1. ` for an ordered item. Nil when the block is not
    /// a list item, which is also how the caller knows not to indent.
    ///
    /// `components` runs **innermost first**, and both halves of the answer
    /// have to come from the same level. Taking the last `.listItem` gives a
    /// nested item its parent's number, and looking for `.orderedList`
    /// anywhere in the ancestry numbers a bullet that merely sits under a
    /// numbered step — which is one of the commonest shapes in a README.
    private static func listMarker(_ block: Block) -> String? {
        guard let item = block.kinds.firstIndex(where: {
            if case .listItem = $0 { return true }
            return false
        }), case .listItem(let ordinal) = block.kinds[item] else { return nil }
        // The list this item belongs to is the first list intent *outside* it.
        for kind in block.kinds[(item + 1)...] {
            if case .orderedList = kind { return "\(ordinal)." }
            if case .unorderedList = kind { return "•" }
        }
        return nil
    }

    // MARK: - Tables

    /// Tables are laid out with `NSTextTableBlock`, which **only works under
    /// TextKit 1**. Under TextKit 2 the blocks are ignored and the cells stack
    /// with no columns — silently, with no error. The view that displays this
    /// must opt into TextKit 1; `MarkdownTextView` does, and a check pins it.
    private static func applyCell(_ block: Block, table: NSTextTable?, columns: Int,
                                  theme: Theme, to out: NSMutableAttributedString, range: NSRange) {
        guard let table, range.length > 0 else { return }
        var column = 0
        var row = 0
        var isHeader = false
        for kind in block.kinds {
            switch kind {
            case .tableCell(let index): column = index
            case .tableRow(let index): row = index
            case .tableHeaderRow: isHeader = true
            default: break
            }
        }
        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                    startingColumn: column, columnSpan: 1)
        cell.setBorderColor(.separatorColor)
        cell.setWidth(1, type: .absoluteValueType, for: .border)
        cell.setWidth(theme.cellPadding, type: .absoluteValueType, for: .padding)

        let style = NSMutableParagraphStyle()
        style.textBlocks = [cell]
        for kind in block.kinds {
            if case .table(let columns) = kind, column < columns.count {
                switch columns[column].alignment {
                case .left: style.alignment = .left
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                @unknown default: style.alignment = .natural
                }
            }
        }
        out.addAttribute(.paragraphStyle, value: style, range: range)
        if isHeader {
            out.addAttribute(.font, value: NSFont.systemFont(ofSize: theme.bodySize, weight: .semibold),
                             range: range)
        }
    }
}

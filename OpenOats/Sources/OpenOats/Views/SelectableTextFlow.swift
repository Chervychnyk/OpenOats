import AppKit
import SwiftUI

// MARK: - Selectable Text Flow

/// Renders an attributed string in a single non-editable `NSTextView`, so a
/// selection can span the whole content (drag across lines, Cmd+A, Cmd+C).
/// SwiftUI's per-`Text` `.textSelection(.enabled)` cannot select across views,
/// which limited transcript and notes selection to one paragraph at a time.
struct SelectableTextFlow: NSViewRepresentable {
    let attributedText: NSAttributedString
    /// Called when a link in the text is clicked, with the link URL and the
    /// bounding rect of the link run in the view's coordinate space. Return
    /// true if handled; returning false falls back to the system behavior.
    /// When nil, all links use the system behavior (open URL).
    var onLinkClick: ((URL, CGRect) -> Bool)? = nil
    /// When set, the text is only replaced when this key changes. Needed for
    /// text tables: `NSTextTableBlock` compares by identity, so a rebuilt but
    /// identical string never `isEqual` the stored one.
    var contentKey: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        // Links carry their own styling in the attributed string; just show a hand cursor.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        context.coordinator.onLinkClick = onLinkClick
        guard let storage = nsView.textStorage else { return }
        if let contentKey {
            guard contentKey != context.coordinator.contentKey else { return }
            context.coordinator.contentKey = contentKey
        } else {
            guard !storage.isEqual(to: attributedText) else { return }
        }

        let previousSelection = nsView.selectedRanges
        storage.setAttributedString(attributedText)

        // Keep the selection alive across live-transcript updates (text appends
        // at the end, so absolute offsets stay valid).
        let length = attributedText.length
        let restored = previousSelection.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.location <= length else { return nil }
            return NSValue(range: NSRange(
                location: range.location,
                length: min(range.length, length - range.location)
            ))
        }
        if !restored.isEmpty {
            nsView.selectedRanges = restored
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let layoutManager = nsView.layoutManager,
              let container = nsView.textContainer else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLinkClick: ((URL, CGRect) -> Bool)?
        var contentKey: String?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let onLinkClick else { return false }
            let url: URL?
            if let linkURL = link as? URL {
                url = linkURL
            } else if let linkString = link as? String {
                url = URL(string: linkString)
            } else {
                url = nil
            }
            guard let url else { return false }

            var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
            if let layoutManager = textView.layoutManager,
               let container = textView.textContainer,
               let storage = textView.textStorage,
               charIndex < storage.length {
                var linkRange = NSRange(location: charIndex, length: 1)
                _ = storage.attribute(
                    .link,
                    at: charIndex,
                    longestEffectiveRange: &linkRange,
                    in: NSRange(location: 0, length: storage.length)
                )
                let glyphRange = layoutManager.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil)
                rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                rect.origin.x += textView.textContainerOrigin.x
                rect.origin.y += textView.textContainerOrigin.y
            }
            return onLinkClick(url, rect)
        }
    }
}

// MARK: - Transcript Flow Builder

/// Builds the transcript as one attributed string whose column layout mirrors
/// the previous per-row HStack: optional right-aligned timestamp column, then a
/// right-aligned speaker column, then the utterance text with hanging indent.
enum TranscriptFlow {
    static let renameLinkScheme = "openoats-rename"

    struct Line {
        var timestamp: String?      // nil hides the timestamp for this row
        var speakerLabel: String
        var speakerColor: NSColor
        var renameKey: String?      // non-nil makes the speaker label a rename link
        var text: String
        var textIsSecondary: Bool = false
    }

    static func renameURL(forKey key: String) -> URL? {
        URL(string: "\(renameLinkScheme)://speaker/\(key)")
    }

    static func renameKey(from url: URL) -> String? {
        guard url.scheme == renameLinkScheme else { return nil }
        return url.lastPathComponent
    }

    static func speakerColumnWidth(forLabels labels: [String]) -> CGFloat {
        let font = speakerFont()
        return labels.reduce(CGFloat(36)) { widest, label in
            max(widest, ceil((label as NSString).size(withAttributes: [.font: font]).width))
        }
    }

    static func attributed(
        lines: [Line],
        showsTimestampColumn: Bool,
        timestampColumnWidth: CGFloat = 34
    ) -> NSAttributedString {
        let timestampFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let speakerFont = speakerFont()

        let timestampWidth = timestampColumnWidth
        let speakerWidth = speakerColumnWidth(forLabels: lines.map(\.speakerLabel))
        let speakerRightEdge = showsTimestampColumn ? timestampWidth + 6 + speakerWidth : speakerWidth
        let textStart = speakerRightEdge + (showsTimestampColumn ? 6 : 8)

        let paragraph = NSMutableParagraphStyle()
        var tabs: [NSTextTab] = []
        if showsTimestampColumn {
            tabs.append(NSTextTab(textAlignment: .right, location: timestampWidth))
        }
        tabs.append(NSTextTab(textAlignment: .right, location: speakerRightEdge))
        tabs.append(NSTextTab(textAlignment: .left, location: textStart))
        paragraph.tabStops = tabs
        paragraph.headIndent = textStart
        paragraph.paragraphSpacing = 8
        paragraph.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont,
                    .paragraphStyle: paragraph,
                ]))
            }

            let timestampField = showsTimestampColumn ? "\t\(line.timestamp ?? "")\t" : "\t"
            result.append(NSAttributedString(string: timestampField, attributes: [
                .font: timestampFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph,
            ]))

            var speakerAttributes: [NSAttributedString.Key: Any] = [
                .font: speakerFont,
                .foregroundColor: line.speakerColor,
                .paragraphStyle: paragraph,
            ]
            if let key = line.renameKey, let url = renameURL(forKey: key) {
                speakerAttributes[.link] = url
                speakerAttributes[.toolTip] = "Rename speaker"
            }
            result.append(NSAttributedString(string: line.speakerLabel, attributes: speakerAttributes))

            result.append(NSAttributedString(string: "\t\(line.text)", attributes: [
                .font: bodyFont,
                .foregroundColor: line.textIsSecondary ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        return result
    }

    private static func speakerFont() -> NSFont {
        NSFont.systemFont(ofSize: 11, weight: .semibold)
    }
}

// MARK: - Markdown Flow Builder

/// Converts note markdown pieces into attributed strings for a single
/// selectable flow, matching the previous per-block `Text` styling.
enum MarkdownTextFlow {
    /// Blank-line separator between blocks: a newline ends the previous
    /// paragraph, then an empty paragraph with a fixed line height provides the
    /// vertical gap (copies out as a plain blank line).
    static func blockSeparator(gap: CGFloat = 12) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
        ])
        let gapStyle = NSMutableParagraphStyle()
        gapStyle.minimumLineHeight = gap
        gapStyle.maximumLineHeight = gap
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 2),
            .paragraphStyle: gapStyle,
        ]))
        return result
    }

    static func heading(_ text: String, level: Int) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = level == 1 ? 4 : 2
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: level == 1 ? 18 : 15, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }

    /// Renders one markdown paragraph: pipe tables and `*`/`-`/`1.` list items
    /// get block layout, everything else goes through `inlineMarkdown`.
    static func block(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var plainLines: [String] = []
        var tableLines: [String] = []

        func append(_ piece: NSAttributedString) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(piece)
        }
        func flushPlain() {
            guard !plainLines.isEmpty else { return }
            append(inlineMarkdown(plainLines.joined(separator: "\n")))
            plainLines.removeAll()
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            append(table(tableLines))
            tableLines.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                flushPlain()
                tableLines.append(line)
            } else if let item = listItem(line) {
                flushPlain()
                flushTable()
                append(item)
            } else {
                flushTable()
                plainLines.append(line)
            }
        }
        flushPlain()
        flushTable()
        return result
    }

    private static func listItem(_ line: String) -> NSAttributedString? {
        guard let match = line.firstMatch(of: /^(\s*)([*+-]|\d+[.)])\s+(.*)$/) else { return nil }
        let step: CGFloat = 18
        let indent = CGFloat(match.1.count / 2) * step
        let marker = match.2.first?.isNumber == true ? String(match.2) : "•"

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.firstLineHeadIndent = indent
        style.headIndent = indent + step
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + step)]

        let result = NSMutableAttributedString(string: "\(marker)\t", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        result.append(inlineMarkdown(String(match.3)))
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func table(_ lines: [String]) -> NSAttributedString {
        let rows = lines
            .map(tableCells)
            .filter { cells in !cells.allSatisfy { $0.wholeMatch(of: /:?-+:?/) != nil } }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return inlineMarkdown(lines.joined(separator: "\n")) }

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)

        let result = NSMutableAttributedString()
        for (rowIndex, cells) in rows.enumerated() {
            for column in 0..<columns {
                let cellBlock = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1
                )
                cellBlock.setWidth(0.5, type: .absoluteValueType, for: .border)
                cellBlock.setBorderColor(.separatorColor)
                cellBlock.setWidth(6, type: .absoluteValueType, for: .padding)
                if rowIndex == 0 {
                    cellBlock.backgroundColor = .quaternaryLabelColor
                }

                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                style.textBlocks = [cellBlock]

                // An empty last cell would have no characters to carry its table block, so it gets a space.
                let text = column < cells.count && !cells[column].isEmpty ? cells[column] : " "
                let cell = NSMutableAttributedString(attributedString: inlineMarkdown(text))
                if rowIndex == 0 {
                    cell.applyFontTraits(.boldFontMask, range: NSRange(location: 0, length: cell.length))
                }
                // Each cell is its own paragraph; the last one's newline comes from the caller's separator.
                if rowIndex < rows.count - 1 || column < columns - 1 {
                    cell.append(NSAttributedString(string: "\n"))
                }
                cell.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cell.length))
                result.append(cell)
            }
        }
        return result
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func inlineMarkdown(_ text: String) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 13)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping

        let parsed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var font = baseFont
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(
                        font.fontDescriptor.symbolicTraits.union(traits)
                    )
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attributes[.font] = font
            result.append(NSAttributedString(string: String(parsed.characters[run.range]), attributes: attributes))
        }
        return result
    }
}

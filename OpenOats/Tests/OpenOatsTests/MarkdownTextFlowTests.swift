import AppKit
import XCTest
@testable import OpenOatsKit

final class MarkdownTextFlowTests: XCTestCase {
    func testBlockRendersPipeTableAsTextTableCells() {
        let rendered = MarkdownTextFlow.block("""
        | Question | Topic |
        | :--- | :--- |
        | What is **DI**? | Patterns |
        """)

        XCTAssertEqual(rendered.string, "Question\nTopic\nWhat is DI?\nPatterns")
        let blocks = textBlocks(in: rendered)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks.map(\.startingRow), [0, 0, 1, 1])
        XCTAssertEqual(blocks.map(\.startingColumn), [0, 1, 0, 1])
        XCTAssertTrue(blocks.allSatisfy { $0.table === blocks[0].table })
    }

    func testBlockPadsShortTableRows() {
        let rendered = MarkdownTextFlow.block("| A | B |\n| only |")

        XCTAssertEqual(textBlocks(in: rendered).count, 4)
    }

    func testBlockRendersBulletAndNumberedListMarkers() {
        let rendered = MarkdownTextFlow.block("Intro\n* **Pros:** fast\n- second\n2. third")

        XCTAssertEqual(rendered.string, "Intro\n•\tPros: fast\n•\tsecond\n2.\tthird")
        let style = rendered.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, 18)
    }

    func testBlockKeepsPlainParagraphsAndBoldLines() {
        let rendered = MarkdownTextFlow.block("**Level: Weak Middle**\nnext line")

        XCTAssertEqual(rendered.string, "Level: Weak Middle\nnext line")
        XCTAssertTrue(textBlocks(in: rendered).isEmpty)
    }

    func testBlockBoldsHeaderCellsThatAlreadyContainEmphasis() {
        let rendered = MarkdownTextFlow.block("| **Question** | What is **DI** |\n| --- | --- |\n| a | b |")

        XCTAssertEqual(rendered.string, "Question\nWhat is DI\na\nb")
        let headerFont = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(headerFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let bodyFont = rendered.attribute(.font, at: rendered.length - 1, effectiveRange: nil) as? NSFont
        XCTAssertFalse(bodyFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testBlockIndentsNestedListItems() {
        let rendered = MarkdownTextFlow.block("- top\n  - nested")

        let nestedStart = (rendered.string as NSString).range(of: "•\tnested").location
        let style = rendered.attribute(.paragraphStyle, at: nestedStart, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.firstLineHeadIndent, 18)
        XCTAssertEqual(style?.headIndent, 36)
    }

    func testBlockKeepsTextAroundATableInOrder() {
        let rendered = MarkdownTextFlow.block("Before\n| A |\n| x |\nAfter")

        XCTAssertEqual(rendered.string, "Before\nA\nx\nAfter")
        XCTAssertEqual(textBlocks(in: rendered).count, 2)
    }

    private func textBlocks(in string: NSAttributedString) -> [NSTextTableBlock] {
        var blocks: [NSTextTableBlock] = []
        string.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
               !blocks.contains(where: { $0 === block }) {
                blocks.append(block)
            }
        }
        return blocks
    }
}

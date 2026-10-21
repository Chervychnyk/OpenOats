import XCTest
@testable import OpenOatsKit

final class LiveTranscriptCleanerTests: XCTestCase {
    func testRejectsChatReplyInsteadOfCleanup() {
        XCTAssertNil(LiveTranscriptCleaner.acceptedCleanup(
            original: "Хорошо, хорошо, это самое, раз, два.",
            response: "Пожалуйста, пришлите текст выступления, который нужно обработать. Как только вы его отправите, я очищу его от слов-паразитов."
        ))
    }

    func testAcceptsCleanupAndStripsEchoedTags() {
        XCTAssertEqual(
            LiveTranscriptCleaner.acceptedCleanup(
                original: "ну это самое мы задеплоили вчера ну и все",
                response: "<transcript>\nМы задеплоили вчера, и все.\n</transcript>"
            ),
            "Мы задеплоили вчера, и все."
        )
    }

    func testRejectsEmptyResponse() {
        XCTAssertNil(LiveTranscriptCleaner.acceptedCleanup(original: "раз два три четыре пять", response: "  "))
    }
}

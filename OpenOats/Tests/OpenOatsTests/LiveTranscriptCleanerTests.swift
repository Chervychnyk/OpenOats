import XCTest
@testable import OpenOatsKit

final class LiveTranscriptCleanerTests: XCTestCase {
    func testRejectsChatReplyInsteadOfCleanup() {
        XCTAssertNil(LiveTranscriptCleaner.acceptedCleanup(
            original: "Okay, okay, so, one, two.",
            response: "Please send the speech text you want processed. As soon as you send it, I will remove the filler words."
        ))
    }

    func testAcceptsCleanupAndStripsEchoedTags() {
        XCTAssertEqual(
            LiveTranscriptCleaner.acceptedCleanup(
                original: "um so we deployed it yesterday and like that is it",
                response: "<transcript>\nWe deployed it yesterday, and that is it.\n</transcript>"
            ),
            "We deployed it yesterday, and that is it."
        )
    }

    func testRejectsEmptyResponse() {
        XCTAssertNil(LiveTranscriptCleaner.acceptedCleanup(original: "one two three four five", response: "  "))
    }
}

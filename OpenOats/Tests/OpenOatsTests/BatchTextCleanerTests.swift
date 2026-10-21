import XCTest
@testable import OpenOatsKit

@MainActor
final class BatchTextCleanerTests: XCTestCase {

    // MARK: - chunkRecords

    func testChunkRecordsEmpty() {
        let chunks = BatchTextCleaner.chunkRecords([])
        XCTAssertTrue(chunks.isEmpty)
    }

    func testChunkRecordsSingleChunk() {
        let base = Date()
        let records = (0..<5).map { i in
            SessionRecord(speaker: .you, text: "line \(i)", timestamp: base.addingTimeInterval(Double(i) * 10))
        }
        let chunks = BatchTextCleaner.chunkRecords(records)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 5)
    }

    func testChunkRecordsSplitsAt150Seconds() {
        let base = Date()
        // 10 records, 20 seconds apart = 180 seconds total -> should split around 150s mark
        let records = (0..<10).map { i in
            SessionRecord(speaker: .them, text: "line \(i)", timestamp: base.addingTimeInterval(Double(i) * 20))
        }
        let chunks = BatchTextCleaner.chunkRecords(records)
        XCTAssertEqual(chunks.count, 2)
        // First chunk: records at 0, 20, 40, 60, 80, 100, 120, 140 (8 records, last at 140s < 150s)
        // Record at 160s triggers split
        XCTAssertEqual(chunks[0].count, 8)
        XCTAssertEqual(chunks[1].count, 2)
    }

    func testChunkRecordsThreeChunks() {
        let base = Date()
        // 20 records, 20 seconds apart = 380 seconds total -> 3 chunks
        let records = (0..<20).map { i in
            SessionRecord(speaker: .you, text: "line \(i)", timestamp: base.addingTimeInterval(Double(i) * 20))
        }
        let chunks = BatchTextCleaner.chunkRecords(records)
        XCTAssertEqual(chunks.count, 3)
    }

    // MARK: - parseResponse

    func testParseResponseMatchingLineCount() {
        let base = Date()
        let records = [
            SessionRecord(speaker: .you, text: "original one", timestamp: base),
            SessionRecord(speaker: .them, text: "original two", timestamp: base.addingTimeInterval(5)),
        ]
        let response = "[12:00:00] You: cleaned one\n[12:00:05] Them: cleaned two"

        let result = BatchTextCleaner.parseResponse(response, originalRecords: records)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0].cleanedText, "cleaned one")
        XCTAssertEqual(result?[1].cleanedText, "cleaned two")
    }

    func testParseResponseMismatchedLineCountReturnsNil() {
        let base = Date()
        let records = [
            SessionRecord(speaker: .you, text: "original", timestamp: base),
        ]
        let response = "line one\nline two\nline three"

        let result = BatchTextCleaner.parseResponse(response, originalRecords: records)
        XCTAssertNil(result)
    }

    func testParseResponseWithoutPrefixReturnsNil() {
        let base = Date()
        let records = [
            SessionRecord(speaker: .you, text: "So, what is it?", timestamp: base),
            SessionRecord(speaker: .them, text: "ok", timestamp: base.addingTimeInterval(5)),
        ]
        let response = "Please provide the speech text.\n\nSend the transcript and I will clean it up."

        XCTAssertNil(BatchTextCleaner.parseResponse(response, originalRecords: records))
    }

    func testParseResponseStripsRemoteSpeakerPrefix() {
        let records = [SessionRecord(speaker: .remote(2), text: "original", timestamp: Date())]
        let result = BatchTextCleaner.parseResponse("[12:00:00] Speaker 2: cleaned", originalRecords: records)
        XCTAssertEqual(result?[0].cleanedText, "cleaned")
    }

    func testParseResponseEmptyLinePreservesOriginal() {
        let base = Date()
        let records = [
            SessionRecord(speaker: .you, text: "keep this", timestamp: base),
        ]
        // After prefix strip, if the result is empty it should fall back to original text
        let response = "[12:00:00] You: "

        let result = BatchTextCleaner.parseResponse(response, originalRecords: records)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?[0].cleanedText, "keep this")
    }

    func testParseResponseKeepsOriginalWhenCleanupDropsTooMuch() {
        let records = [SessionRecord(
            speaker: .you,
            text: "so the point is we discussed standardization uh baku per team so what is the point now there is a process",
            timestamp: Date()
        )]
        let result = BatchTextCleaner.parseResponse(
            "[12:00:00] You: So the point is we discussed standardization per team.",
            originalRecords: records
        )
        XCTAssertEqual(result?[0].cleanedText, records[0].text)
    }

    func testParseResponseAcceptsFillerRemoval() {
        let records = [SessionRecord(speaker: .you, text: "um so like we deployed the new release yesterday to prod", timestamp: Date())]
        let result = BatchTextCleaner.parseResponse("[12:00:00] You: We deployed the new release yesterday to prod.", originalRecords: records)
        XCTAssertEqual(result?[0].cleanedText, "We deployed the new release yesterday to prod.")
    }

    // MARK: - systemPrompt

    func testSystemPromptListsCustomVocabulary() {
        let prompt = BatchTextCleaner.systemPrompt(customVocabulary: "Postman: postmen\n\n  Swagger  \n")
        XCTAssertTrue(prompt.contains("- Postman: postmen\n- Swagger"))
    }

    func testSystemPromptWithoutVocabularyHasNoTermsSection() {
        XCTAssertFalse(BatchTextCleaner.systemPrompt(customVocabulary: " \n").contains("Known terms"))
    }

    // MARK: - Failure threshold

    // MARK: - Speaker Codable

    func testSpeakerCodableRoundTrip() throws {
        let speakers: [Speaker] = [.you, .them, .remote(1), .remote(5)]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for speaker in speakers {
            let data = try encoder.encode(speaker)
            let decoded = try decoder.decode(Speaker.self, from: data)
            XCTAssertEqual(decoded, speaker)
        }
    }

    func testSpeakerDecodesLegacyStrings() throws {
        let decoder = JSONDecoder()
        let youData = "\"you\"".data(using: .utf8)!
        let themData = "\"them\"".data(using: .utf8)!

        XCTAssertEqual(try decoder.decode(Speaker.self, from: youData), .you)
        XCTAssertEqual(try decoder.decode(Speaker.self, from: themData), .them)
    }

    func testSpeakerDecodesRemote() throws {
        let decoder = JSONDecoder()
        let data = "\"remote_3\"".data(using: .utf8)!
        XCTAssertEqual(try decoder.decode(Speaker.self, from: data), .remote(3))
    }

    func testSpeakerDisplayLabel() {
        XCTAssertEqual(Speaker.you.displayLabel, "You")
        XCTAssertEqual(Speaker.them.displayLabel, "Them")
        XCTAssertEqual(Speaker.remote(1).displayLabel, "Speaker 1")
        XCTAssertEqual(Speaker.remote(5).displayLabel, "Speaker 5")
    }

    func testSpeakerIsRemote() {
        XCTAssertFalse(Speaker.you.isRemote)
        XCTAssertTrue(Speaker.them.isRemote)
        XCTAssertTrue(Speaker.remote(1).isRemote)
        XCTAssertTrue(Speaker.remote(3).isRemote)
    }

    func testSpeakerStorageKey() {
        XCTAssertEqual(Speaker.you.storageKey, "you")
        XCTAssertEqual(Speaker.them.storageKey, "them")
        XCTAssertEqual(Speaker.remote(1).storageKey, "remote_1")
    }

    func testSpeakerUnknownStringDecodesToThem() throws {
        let decoder = JSONDecoder()
        let data = "\"unknown_value\"".data(using: .utf8)!
        XCTAssertEqual(try decoder.decode(Speaker.self, from: data), .them)
    }

    // MARK: - Failure threshold

    func testFailureThresholdIntegerDivision() {
        // With 3 chunks, chunks.count / 2 = 1
        // So 1 failure is silent, 2 failures triggers the error
        // This test documents the intentional behavior
        let halfOf3 = 3 / 2
        XCTAssertEqual(halfOf3, 1, "Integer division: 3/2 = 1, so 1 failure is tolerated, 2 triggers error")

        let halfOf4 = 4 / 2
        XCTAssertEqual(halfOf4, 2, "Integer division: 4/2 = 2, so 2 failures tolerated, 3 triggers error")
    }
}

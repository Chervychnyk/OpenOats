import XCTest
@testable import OpenOatsKit

final class LLMTraceLogTests: XCTestCase {
    func testAppendWritesOneJSONLinePerTraceIntoDailyFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-traces-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = LLMTraceLog(directory: directory)

        await log.append(makeTrace(response: "first"))
        await log.append(makeTrace(response: "second"))

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let lines = try String(contentsOf: files[0], encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { try decoder.decode(LLMTrace.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded.map(\.response), ["first", "second"])
        XCTAssertEqual(decoded[0].messages.map(\.role), ["system", "user"])
    }

    private func makeTrace(response: String) -> LLMTrace {
        LLMTrace(
            id: UUID(),
            engine: "sidecast",
            startedAt: Date(),
            provider: "openRouter",
            model: "test/model",
            maxTokens: 200,
            temperature: 0.7,
            webSearch: false,
            triggerKind: nil,
            messages: [.init(role: "system", content: "sys"), .init(role: "user", content: "usr")],
            response: response,
            firstTokenMs: nil,
            totalMs: 420,
            outcome: "completed",
            error: nil,
            shown: [response]
        )
    }
}

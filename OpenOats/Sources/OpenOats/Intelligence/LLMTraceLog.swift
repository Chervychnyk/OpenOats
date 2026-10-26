import Foundation

/// One live LLM call, recorded so it can be replayed against other models or prompts
/// (see tools/suggestion-evals).
struct LLMTrace: Codable, Sendable {
    let id: UUID
    let engine: String
    let startedAt: Date
    let provider: String
    let model: String
    let maxTokens: Int
    let temperature: Double?
    let webSearch: Bool
    let triggerKind: String?
    let messages: [OpenRouterClient.Message]
    let response: String
    let firstTokenMs: Int?
    let totalMs: Int
    /// completed, superseded, failed or parse_error.
    let outcome: String
    let error: String?
    /// What reached the UI after the engine's own filtering.
    let shown: [String]
}

/// Appends traces as JSONL, one file per day, under Application Support/OpenOats/llm-traces.
actor LLMTraceLog {
    static let shared = LLMTraceLog()

    private let directory: URL
    private let encoder: JSONEncoder
    private let dayFormatter: DateFormatter

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenOats", isDirectory: true)
            .appendingPathComponent("llm-traces", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
    }

    func append(_ trace: LLMTrace) {
        let url = directory.appendingPathComponent("\(dayFormatter.string(from: trace.startedAt)).jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var line = try encoder.encode(trace)
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                // Prompts hold transcript text, so keep the file owner-only like session files.
                FileManager.default.createFile(atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600])
            }
        } catch {
            Log.suggestionEngine.error("Failed to write LLM trace: \(error, privacy: .public)")
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}

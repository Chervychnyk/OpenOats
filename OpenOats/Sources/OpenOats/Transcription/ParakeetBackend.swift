import FluidAudio
import Foundation

/// Transcription backend for Parakeet-TDT models (v2 English-only, v3 multilingual).
/// @unchecked Sendable: asrManager is written once in prepare() before any transcribe() calls.
final class ParakeetBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName: String
    private let version: AsrModelVersion
    private let customVocabularyText: String
    private var asrManager: AsrManager?
    private var vocabularyBoosting: VocabularyBoostingSession?

    init(version: AsrModelVersion, customVocabulary: String = "") {
        self.version = version
        self.customVocabularyText = customVocabulary
        switch version {
        case .v2: self.displayName = "Parakeet TDT v2"
        case .ultra: self.displayName = "Parakeet Ultra"
        default: self.displayName = "Parakeet TDT v3"
        }
    }

    func checkStatus() -> BackendStatus {
        let exists = AsrModels.modelsExist(
            at: OpenOatsLocalModelStore.parakeetDirectory(for: version),
            version: version
        )
        return exists ? .ready : .needsDownload(prompt: "Transcription requires a one-time model download.")
    }

    func clearModelCache() {
        OpenOatsLocalModelStore.clearParakeetCache(for: version)
    }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let models: AsrModels
        let modelsDirectory = OpenOatsLocalModelStore.parakeetDirectory(for: version)
        if AsrModels.modelsExist(at: modelsDirectory, version: version) {
            onStatus("Initializing \(displayName)...")
            models = try await AsrModels.load(from: modelsDirectory, version: version)
        } else {
            onStatus("Downloading \(displayName)...")
            models = try await AsrModels.downloadAndLoad(to: modelsDirectory, version: version) { progress in
                onProgress(progress.fractionCompleted)
            }
            onStatus("Initializing \(displayName)...")
        }
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.asrManager = asr
        self.vocabularyBoosting = await Self.makeVocabularyBoosting(customVocabularyText, onStatus: onStatus)
    }

    /// Boosting is best-effort: a failed CTC model download or bad vocabulary must not block transcription.
    private static func makeVocabularyBoosting(
        _ text: String,
        onStatus: @Sendable (String) -> Void
    ) async -> VocabularyBoostingSession? {
        let vocab = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vocab.isEmpty else { return nil }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openoats-custom-vocabulary-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            onStatus("Loading custom vocabulary...")
            try vocab.write(to: tempURL, atomically: true, encoding: .utf8)
            let (context, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: tempURL.path)
            guard !context.terms.isEmpty else { return nil }
            return try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels)
        } catch {
            Log.transcription.error("Custom vocabulary disabled: \(error, privacy: .public)")
            return nil
        }
    }

    func transcribe(_ samples: [Float], locale: Locale, previousContext: String? = nil) async throws -> String {
        guard let asrManager else {
            throw TranscriptionBackendError.notPrepared
        }
        // Fresh state per segment, as the old transcribe(samples) reset it after each call.
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(samples, decoderState: &decoderState)
        var text = result.text
        if let vocabularyBoosting,
           let rescored = await vocabularyBoosting.rescore(
               text: text,
               tokenTimings: result.tokenTimings ?? [],
               audioSamples: samples
           ) {
            text = rescored.text
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

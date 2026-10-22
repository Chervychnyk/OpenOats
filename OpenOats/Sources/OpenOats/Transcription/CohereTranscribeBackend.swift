import FluidAudio
import Foundation

/// Local Cohere Transcribe 03-2026 (2B encoder-decoder, 14 languages) running the FluidAudio CoreML q8 port.
/// @unchecked Sendable: models is written once in prepare() before any transcribe() calls.
final class CohereTranscribeBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Cohere Transcribe"
    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?

    /// ModelHub.download appends the repo folder (cohere-transcribe/q8) to the base directory.
    static func modelDirectory(baseDirectory: URL = OpenOatsLocalModelStore.defaultBaseDirectory()) -> URL {
        baseDirectory.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
    }

    static func modelsExist(at directory: URL) -> Bool {
        ModelNames.CohereTranscribe.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Falls back to English for languages the model does not support.
    static func language(for locale: Locale) -> CohereAsrConfig.Language {
        locale.language.languageCode.flatMap { CohereAsrConfig.Language(rawValue: $0.identifier) } ?? .english
    }

    func checkStatus() -> BackendStatus {
        Self.modelsExist(at: Self.modelDirectory())
            ? .ready
            : .needsDownload(prompt: TranscriptionModel.cohereTranscribe.downloadPrompt)
    }

    func clearModelCache() {
        try? FileManager.default.removeItem(at: Self.modelDirectory())
    }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = Self.modelDirectory()
        if !Self.modelsExist(at: directory) {
            onStatus("Downloading \(displayName)...")
            try await ModelHub.download(.cohereTranscribeCoreml, to: OpenOatsLocalModelStore.defaultBaseDirectory()) {
                onProgress($0.fractionCompleted)
            }
        }
        onStatus("Initializing \(displayName)...")
        models = try await CoherePipeline.loadModels(encoderDir: directory, decoderDir: directory, vocabDir: directory)
    }

    func transcribe(_ samples: [Float], locale: Locale, previousContext: String? = nil) async throws -> String {
        guard let models else {
            throw TranscriptionBackendError.notPrepared
        }
        let result = try await pipeline.transcribeLong(audio: samples, models: models, language: Self.language(for: locale))
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

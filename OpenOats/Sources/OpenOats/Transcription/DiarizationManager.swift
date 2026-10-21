import FluidAudio
import Foundation

/// Manages LS-EEND speaker diarization for system audio.
/// Wraps the FluidAudio LSEENDDiarizer and provides speaker attribution
/// for transcribed segments by querying the diarizer timeline.
actor DiarizationManager {
    private nonisolated(unsafe) let diarizer = LSEENDDiarizer()
    private var isInitialized = false
    /// Set by `diarizeOffline`; replaces the LS-EEND timeline for batch attribution.
    private var offlineSegments: [Int: [SpeakerSpan]]?

    struct SpeakerSpan: Equatable {
        let start: Float
        let end: Float
    }

    /// Load the LS-EEND model for the given variant. Must be called before feedAudio/dominantSpeaker.
    func load(variant: LSEENDVariant = .dihard3) async throws {
        Log.diarization.info("Loading LS-EEND model (variant: \(variant.description, privacy: .public))")
        try await diarizer.initialize(variant: variant)
        isInitialized = true
        Log.diarization.info("LS-EEND model loaded")
    }

    /// Feed audio samples to the diarizer. Samples should be at 16kHz mono Float32.
    /// Uses addAudio + process for streaming (does not reset state between calls).
    func feedAudio(_ samples: [Float]) throws {
        guard isInitialized else { return }
        try diarizer.addAudio(samples, sourceSampleRate: 16000)
        _ = try diarizer.process()
    }

    /// Diarize a whole recording with FluidAudio's offline pipeline (pyannote segmentation + VBx clustering).
    /// LS-EEND is a streaming model and merged distinct remote voices into one on real meetings.
    func diarizeOffline(_ samples: [Float]) async throws {
        let manager = OfflineDiarizerManager()
        manager.initialize(models: try await OfflineDiarizerModels.load())
        let result = try await manager.process(audio: samples)
        offlineSegments = Self.indexedSpans(
            result.segments.map { (id: $0.speakerId, span: SpeakerSpan(start: $0.startTimeSeconds, end: $0.endTimeSeconds)) }
        )
    }

    /// Numbers speakers by first appearance, so whoever speaks first stays `.them`.
    nonisolated static func indexedSpans(_ segments: [(id: String, span: SpeakerSpan)]) -> [Int: [SpeakerSpan]] {
        var indexByID: [String: Int] = [:]
        var spans: [Int: [SpeakerSpan]] = [:]
        for segment in segments.sorted(by: { $0.span.start < $1.span.start }) {
            let index = indexByID[segment.id] ?? indexByID.count
            indexByID[segment.id] = index
            spans[index, default: []].append(segment.span)
        }
        return spans
    }

    private var spansBySpeaker: [Int: [SpeakerSpan]] {
        if let offlineSegments { return offlineSegments }
        return diarizer.timeline.speakers.mapValues { speaker in
            (speaker.finalizedSegments + speaker.tentativeSegments).map { SpeakerSpan(start: $0.startTime, end: $0.endTime) }
        }
    }

    /// Returns the dominant speaker for a given time range in seconds.
    /// Queries the DiarizerTimeline and finds which speaker has the most
    /// speech frames overlapping [startTime, endTime].
    func dominantSpeaker(from startTime: TimeInterval, to endTime: TimeInterval) -> Speaker {
        let speakers = spansBySpeaker

        guard !speakers.isEmpty else { return .them }

        var bestSpeaker: Int = 0
        var bestOverlap: Float = 0

        let queryStart = Float(startTime)
        let queryEnd = Float(endTime)

        for (index, spans) in speakers {
            var overlap: Float = 0

            for segment in spans {
                let overlapStart = max(segment.start, queryStart)
                let overlapEnd = min(segment.end, queryEnd)
                if overlapEnd > overlapStart {
                    overlap += overlapEnd - overlapStart
                }
            }

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = index
            }
        }

        guard bestOverlap > 0 else { return .them }

        return Self.speaker(forDiarizerIndex: bestSpeaker)
    }

    /// Maps a diarizer cluster index to a stable `Speaker` label.
    ///
    /// The first cluster stays `.them`, so a session with one remote voice still
    /// reads "Them" rather than "Speaker 1". Later clusters continue that numbering
    /// — "Them" is speaker 1, so cluster 1 is "Speaker 2".
    ///
    /// The mapping deliberately depends only on the index, never on how many
    /// clusters exist *so far*. `dominantSpeaker` runs live, once per utterance,
    /// while the diarizer is still discovering speakers, so a "only one speaker
    /// known yet, call it .them" rule labels one voice `.them` early and
    /// `.remote(1)` from the moment a second voice appears. Nothing revisits the
    /// earlier utterances, so a single participant ends up split across two labels.
    nonisolated static func speaker(forDiarizerIndex index: Int) -> Speaker {
        index <= 0 ? .them : .remote(index + 1)
    }

    /// Returns diarized speaker runs overlapping the given range.
    /// These runs can be used to split a longer speech segment into
    /// smaller speaker-consistent chunks.
    func speakerRuns(from startTime: TimeInterval, to endTime: TimeInterval) -> [BatchTranscriptionSegmentLayout.SpeakerRun] {
        let speakers = spansBySpeaker

        guard !speakers.isEmpty else { return [] }

        let queryStart = Float(startTime)
        let queryEnd = Float(endTime)
        let activeSpeakers = speakers.filter { !$0.value.isEmpty }

        // One voice owns the whole range; label it the same way dominantSpeaker would.
        if activeSpeakers.count <= 1 {
            return [
                BatchTranscriptionSegmentLayout.SpeakerRun(
                    startTime: startTime,
                    endTime: endTime,
                    speaker: Self.speaker(forDiarizerIndex: activeSpeakers.first?.key ?? 0)
                )
            ]
        }

        var runs: [BatchTranscriptionSegmentLayout.SpeakerRun] = []

        for (index, spans) in speakers {
            let mappedSpeaker = Self.speaker(forDiarizerIndex: index)
            for segment in spans {
                let overlapStart = max(segment.start, queryStart)
                let overlapEnd = min(segment.end, queryEnd)
                guard overlapEnd > overlapStart else { continue }
                runs.append(
                    BatchTranscriptionSegmentLayout.SpeakerRun(
                        startTime: TimeInterval(overlapStart),
                        endTime: TimeInterval(overlapEnd),
                        speaker: mappedSpeaker
                    )
                )
            }
        }

        return runs
    }

    /// Finalize the diarization session (flush tentative segments).
    func finalize() {
        guard isInitialized else { return }
        do {
            try diarizer.finalizeSession()
        } catch {
            Log.diarization.error("Failed to finalize LS-EEND session: \(error, privacy: .public)")
        }
    }

    /// Reset the diarizer state for a new session.
    func reset() {
        guard isInitialized else { return }
        diarizer.reset()
    }
}

extension DiarizationVariant {
    /// FluidAudio 0.17's LSEENDVariant has no raw value.
    var lseendVariant: LSEENDVariant {
        switch self {
        case .ami: .ami
        case .callhome: .callhome
        case .dihard3: .dihard3
        }
    }
}

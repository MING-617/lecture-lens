import Foundation
import AVFoundation

@main enum Tests {
    static func main() {
        Task { @MainActor in
            do { try await run(); exit(0) } catch { print("FAIL", error); exit(1) }
        }
        dispatchMain()
    }
    @MainActor static func run() async throws {
        let model = URL(fileURLWithPath: CommandLine.arguments[1]), input = URL(fileURLWithPath: CommandLine.arguments[2]), directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let voice = try VoiceActivity(model: model.appendingPathComponent("silero_vad.onnx"))
        var detectedNoise = 0, seed: UInt32 = 17
        for _ in 0..<320 {
            let noise = (0..<512).map { _ -> Float in seed = seed &* 1664525 &+ 1013904223; return (Float(seed >> 8) / Float(0xFFFFFF) - 0.5) * 0.2 }
            if voice.accept(noise) { detectedNoise += 1 }
        }
        assert(detectedNoise < 4, "stationary synthetic noise must not be treated as sustained speech")
        for _ in 0..<100 { assert(!voice.accept(Array(repeating: 0, count: 512)), "silence must remain non-speech") }
        let archive = try TranscriptArchive(directory: directory)
        let session = SpeechSession(); session.modelDirectory = model
        var final: RecognitionEvent?, voiceFrames = 0, errors: [String] = []
        var tracker = StreamingLatencyTracker()
        session.onResult = { event in archive.accept(event); _ = tracker.accept(event); if event.isFinal { final = event } }
        session.onVoice = { if $0 { voiceFrames += 1 } }
        session.onError = { errors.append($0.localizedDescription) }
        try await session.streamFile(url: input, contextualTerms: [])
        await session.finish()
        assert(final != nil && final!.words.count == 68, "finish must drain all result callbacks, including the final word")
        try await archive.finish(reason: "pipeline test")
        let saved = try String(contentsOf: archive.url, encoding: .utf8)
        assert(saved.contains("This is a classroom") && saved.contains("terminology test"))
        assert(voiceFrames > 50 && errors.isEmpty && tracker.overLimit == 0)
        let exported = directory.appendingPathComponent("export.txt")
        try await archive.export(to: exported)
        assert(tryData(exported) == tryData(archive.url), "export must copy the full saved document")
        print("PASS: real VAD rejects noise and silence; detects speech; production stream recognizes 68 words; FIFO stop drains final callback; full archive and export match; max delay", tracker.maximum)
    }
    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }
}

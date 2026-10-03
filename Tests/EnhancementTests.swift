import Foundation
import AVFoundation

@main enum EnhancementTests {
    @MainActor static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        for name in ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt", "silero_vad.onnx"] {
            try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent(name), withDestinationURL: source.appendingPathComponent(name))
        }
        let vocabulary = temporary.appendingPathComponent("bpe.vocab")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        for state in 0..<3 {
            if state == 1 {
                // A syntactically plausible but model-incompatible vocabulary
                // must also be rejected before native SentencePiece parsing.
                try Data((0..<200).map { "wrong\($0)\t-1.0\n" }.joined().utf8).write(to: vocabulary)
            } else if state == 2 {
                try FileManager.default.removeItem(at: vocabulary)
                try FileManager.default.copyItem(at: source.appendingPathComponent("bpe.vocab"), to: vocabulary)
            }
            let session = SpeechSession(); session.modelDirectory = temporary
            var enabled: Bool?, notice: String?
            session.onEnhancement = { active, reason in enabled = active; notice = reason }
            try await session.prepare(inputFormat: format, contextualTerms: ["foreign key", "NumPy", "Custom Widget"])
            assert(enabled == (state == 2))
            assert((notice != nil) == (state != 2), "fallback must be visible, not silently ignored")
            await session.cancel()
        }
        print("PASS: missing and incompatible hotword vocabulary safely use ordinary recognition with a visible notice; valid vocabulary enables native enhancement")
    }
}

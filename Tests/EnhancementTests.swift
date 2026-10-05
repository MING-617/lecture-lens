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
        let runtime = temporary.appendingPathComponent("cpu-runtime.conf")
        for state in 0..<6 {
            if state == 1 { try Data("SessionConfig.not-valid\n".utf8).write(to: runtime) }
            if state == 2 {
                try Data("SessionConfig.session.intra_op.allow_spinning=0\nSessionConfig.session.inter_op.allow_spinning=0\n".utf8).write(to: runtime)
            }
            if state == 3 { try Data("SessionConfig.session.intra_op.allow_spinning=0\nSessionConfig.session.inter_op.allow_spinning=0\nLectureLensWorkerQoS=background\n".utf8).write(to: runtime) }
            if state == 4 { try Data("SessionConfig.session.intra_op.allow_spinning=0\nSessionConfig.session.inter_op.allow_spinning=0\nLectureLensWorkerQoS=invalid\n".utf8).write(to: runtime) }
            if state == 5 { try Data("SessionConfig.session.intra_op.allow_spinning=0\nSessionConfig.session.inter_op.allow_spinning=0\nLectureLensWorkerQoS=utility\n".utf8).write(to: runtime) }
            let session = SpeechSession(); session.modelDirectory = temporary
            var enabled = false
            session.onEnhancement = { active, _ in enabled = active }
            try await session.prepare(inputFormat: format, contextualTerms: ["foreign key", "NumPy"])
            assert(enabled, "optional CPU configuration must never disable hotword recognition")
            assert((StreamingDecoder.cpuProvider(model: temporary.path) == "cpu") == (state != 2 && state != 3 && state != 5))
            await session.cancel()
        }
        print("PASS: missing/malformed optional CPU config safely falls back; both legacy sleep and background helper settings initialize; invalid helper QoS falls back; all retain hotword recognition")
        let cancelled = SpeechSession(); cancelled.modelDirectory = source
        var initialized = false, audioCallbacks = 0
        cancelled.onEnhancement = { _, _ in initialized = true }
        cancelled.onLevel = { _, _, _ in audioCallbacks += 1 }
        let preparing = Task { try await cancelled.prepare(inputFormat: format, contextualTerms: ["foreign key"]) }
        preparing.cancel()
        do { try await preparing.value; assertionFailure("cancelled startup must not install a worker") }
        catch is CancellationError { }
        await cancelled.cancel()
        assert(initialized && audioCallbacks == 0, "native background initialization must finish safely without starting cancelled audio")
        print("PASS: cancelled background initialization releases the native worker without starting audio")
    }
}

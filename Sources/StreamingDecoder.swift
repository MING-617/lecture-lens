import Foundation
import AVFoundation

final class StreamingDecoder {
    let recognizer: OpaquePointer
    let stream: OpaquePointer
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var parser = StreamingWords()
    let enhanced: Bool
    init(model: String, contextualTerms: [String] = [], paths: Int = 2, score: Float = 1,
         threads: Int = 2, provider: String = "cpu") throws {
        var pool: [UnsafeMutablePointer<CChar>] = []
        var retained = false
        defer { if !retained { for p in pool { free(p) } } }
        func c(_ text: String) -> UnsafePointer<CChar> { let p = strdup(text)!; pool.append(p); return UnsafePointer(p) }
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16000; config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(model + "/encoder.int8.onnx")
        config.model_config.transducer.decoder = c(model + "/decoder.int8.onnx")
        config.model_config.transducer.joiner = c(model + "/joiner.int8.onnx")
        config.model_config.tokens = c(model + "/tokens.txt")
        config.model_config.num_threads = Int32(threads == 1 ? 1 : 2)
        let cpu = Self.cpuProvider(model: model)
        // Core ML is an experimental benchmark route, not an acceleration
        // guarantee: unsupported operators may still run on the CPU.
        config.model_config.provider = c(provider == "coreml" ? "coreml" + cpu.dropFirst(3) : cpu)
        let phrases = RecognitionVocabulary.phrases(contextualTerms)
        let vocabulary = model + "/bpe.vocab"
        enhanced = !phrases.isEmpty && Self.validVocabulary(vocabulary, tokens: model + "/tokens.txt")
        config.decoding_method = c(enhanced ? "modified_beam_search" : "greedy_search")
        config.max_active_paths = Int32(paths == 4 ? 4 : 2)
        if enhanced {
            config.model_config.modeling_unit = c("bpe"); config.model_config.bpe_vocab = c(vocabulary)
            let variants = Set(phrases.flatMap { [$0, $0.lowercased()] }).sorted()
            let hotwords = variants.joined(separator: "\n")
            config.hotwords_buf = c(hotwords); config.hotwords_buf_size = Int32(hotwords.utf8.count)
            config.hotwords_score = score.isFinite && score >= 0 && score <= 2 ? score : 1
        }
        config.enable_endpoint = 0; config.rule1_min_trailing_silence = 2.4
        config.rule2_min_trailing_silence = 0.8; config.rule3_min_utterance_length = 20
        guard let r = SherpaOnnxCreateOnlineRecognizer(&config) else { throw NSError(domain: "model", code: 1) }
        recognizer = r
        guard let s = SherpaOnnxCreateOnlineStream(r) else { SherpaOnnxDestroyOnlineRecognizer(r); throw NSError(domain: "stream", code: 1) }
        stream = s; strings = pool; retained = true
    }
    static func cpuProvider(model: String) -> String {
        let path = model + "/cpu-runtime.conf"
        let expected = "SessionConfig.session.intra_op.allow_spinning=0\nSessionConfig.session.inter_op.allow_spinning=0\n"
        // The native provider parser terminates on a malformed config file.
        // Optional power settings must be validated before entering it.
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8), contents == expected else { return "cpu" }
        return "cpu:" + path
    }
    private static func validVocabulary(_ path: String, tokens: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let table = try? String(contentsOfFile: tokens, encoding: .utf8) else { return false }
        // This vocabulary is derived from the pinned model's token table.
        // Validate the exact derivation before entering native code: a damaged
        // optional vocabulary must fall back rather than abort the process.
        let lines = table.split(separator: "\n")
        guard lines.count > 100, lines.count < 100000 else { return false }
        var expected = ""
        for line in lines {
            guard let space = line.lastIndex(of: " "), Int(line[line.index(after: space)...]) != nil else { return false }
            expected += line[..<space] + "\t-1.0\n"
        }
        return text == expected
    }
    deinit { SherpaOnnxDestroyOnlineStream(stream); SherpaOnnxDestroyOnlineRecognizer(recognizer); for p in strings { free(p) } }
    @discardableResult func feed(_ samples: [Float]) -> Bool {
        samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count)) }
        var decoded = false
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 { SherpaOnnxDecodeOnlineStream(recognizer, stream); decoded = true }
        return decoded
    }
    func result() -> (String, [WordStamp], Int) {
        guard let raw = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { return ("", [], 0) }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(raw) }
        let r = raw.pointee
        let text = String(cString: r.text)
        var pieces: [TokenPiece] = []
        if let tokens = r.tokens_arr, let times = r.timestamps {
            pieces.reserveCapacity(Int(r.count))
            for i in 0..<Int(r.count) {
                guard let token = tokens[i] else { continue }
                pieces.append(TokenPiece(text: String(cString: token), time: Double(times[i])))
            }
        }
        let (words, changed) = parser.accept(pieces)
        return (text, words, changed)
    }
    func finish() {
        feed(Array(repeating: 0, count: 16000))
        SherpaOnnxOnlineStreamInputFinished(stream)
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 { SherpaOnnxDecodeOnlineStream(recognizer, stream) }
    }
}

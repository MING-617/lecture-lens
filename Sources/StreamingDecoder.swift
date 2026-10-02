import Foundation
import AVFoundation

final class StreamingDecoder {
    let recognizer: OpaquePointer
    let stream: OpaquePointer
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var processedTokens = 0
    private var completedWords: [WordStamp] = []
    private var currentWord = ""
    private var wordStart = 0.0
    private var wordEnd = 0.0
    init(model: String) throws {
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
        config.model_config.num_threads = 2; config.model_config.provider = c("cpu")
        config.decoding_method = c("greedy_search"); config.max_active_paths = 4
        config.enable_endpoint = 0; config.rule1_min_trailing_silence = 2.4
        config.rule2_min_trailing_silence = 0.8; config.rule3_min_utterance_length = 20
        guard let r = SherpaOnnxCreateOnlineRecognizer(&config) else { throw NSError(domain: "model", code: 1) }
        recognizer = r
        guard let s = SherpaOnnxCreateOnlineStream(r) else { SherpaOnnxDestroyOnlineRecognizer(r); throw NSError(domain: "stream", code: 1) }
        stream = s; strings = pool; retained = true
    }
    deinit { SherpaOnnxDestroyOnlineStream(stream); SherpaOnnxDestroyOnlineRecognizer(recognizer); for p in strings { free(p) } }
    @discardableResult func feed(_ samples: [Float]) -> Bool {
        samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count)) }
        var decoded = false
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 { SherpaOnnxDecodeOnlineStream(recognizer, stream); decoded = true }
        return decoded
    }
    func result() -> (String, [WordStamp], Double) {
        guard let raw = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { return ("", [], 0) }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(raw) }
        let r = raw.pointee
        let text = String(cString: r.text)
        // Endpoint resets are disabled, so native timestamps remain relative
        // to the one stream. Process only new tokens, not two hours of JSON.
        let offset = 0.0
        if let tokens = r.tokens_arr, let times = r.timestamps {
            for i in processedTokens..<Int(r.count) {
                guard let token = tokens[i] else { continue }
                let piece = String(cString: token).replacingOccurrences(of: "▁", with: " ")
                let time = offset + Double(times[i])
                if piece.first?.isWhitespace == true && !currentWord.isEmpty {
                    completedWords.append(WordStamp(text: currentWord, start: wordStart, end: wordEnd)); currentWord = ""
                }
                if currentWord.isEmpty { wordStart = time; wordEnd = time + 0.08 }
                currentWord += piece.trimmingCharacters(in: .whitespaces)
                // A full stop emitted during later silence does not move the
                // spoken word's estimated end to that punctuation timestamp.
                if piece.contains(where: { $0.isLetter || $0.isNumber }) { wordEnd = time + 0.08 }
            }
            processedTokens = Int(r.count)
        }
        var words = completedWords
        if !currentWord.isEmpty { words.append(WordStamp(text: currentWord, start: wordStart, end: wordEnd)) }
        return (text, words, offset)
    }
    func finish() {
        feed(Array(repeating: 0, count: 16000))
        SherpaOnnxOnlineStreamInputFinished(stream)
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 { SherpaOnnxDecodeOnlineStream(recognizer, stream) }
    }
}

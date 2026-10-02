import Foundation

/// Speech detection is used for health messages only. Audio is always passed
/// intact to the English recognizer, including quiet words and pauses.
final class VoiceActivity {
    private let detector: OpaquePointer
    private let modelPath: UnsafeMutablePointer<CChar>
    private let provider: UnsafeMutablePointer<CChar>
    init(model: URL) throws {
        modelPath = strdup(model.path)!
        provider = strdup("cpu")!
        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.model = UnsafePointer(modelPath)
        config.silero_vad.threshold = 0.5
        config.silero_vad.min_silence_duration = 0.35
        config.silero_vad.min_speech_duration = 0.15
        config.silero_vad.max_speech_duration = 30
        config.silero_vad.window_size = 512
        config.sample_rate = 16000; config.num_threads = 1
        config.provider = UnsafePointer(provider)
        guard let detector = SherpaOnnxCreateVoiceActivityDetector(&config, 35) else {
            free(modelPath); free(provider); throw SessionError.unavailable
        }
        self.detector = detector
    }
    deinit { SherpaOnnxDestroyVoiceActivityDetector(detector); free(modelPath); free(provider) }
    func accept(_ samples: [Float]) -> Bool {
        samples.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, $0.baseAddress, Int32($0.count)) }
        let detected = SherpaOnnxVoiceActivityDetectorDetected(detector) != 0
        SherpaOnnxVoiceActivityDetectorClear(detector)
        return detected
    }
}

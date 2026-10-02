import Foundation

enum Benchmark {
    struct Report: Codable {
        let version: String
        let engine: String
        let input: String
        let measurement: String
        let events: [RecognitionEvent]
        let sampleCount: Int
        let maximumSeconds: Double
        let p50Seconds: Double
        let p95Seconds: Double
        let overTwoSeconds: Int
        let overThreeSeconds: Int
        let durationSeconds: Double
        let maximumQueueWaitSeconds: Double
        let maximumProcessingSeconds: Double
        let transcript: String
        let errors: [String]
    }
    @MainActor static func run(arguments: [String]) async -> Int32 {
        func option(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }; return arguments[i + 1]
        }
        guard let input = option("--input"), let output = option("--report") else {
            print("Usage: LectureLens --benchmark --input OWN_AUDIO --report OUTPUT.json [--model DIRECTORY]"); return 2
        }
        let session = SpeechSession()
        if let model = option("--model") { session.modelDirectory = URL(fileURLWithPath: model) }
        var events: [RecognitionEvent] = [], errors: [String] = []
        var tracker = StreamingLatencyTracker()
        var queueWait = 0.0, processing = 0.0
        session.onResult = { event in events.append(event); _ = tracker.accept(event) }
        session.onError = { errors.append($0.localizedDescription) }
        session.onStatus = { print($0) }
        session.onPerformance = { wait, time in queueWait = max(queueWait, wait); processing = max(processing, time) }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            try await session.streamFile(url: URL(fileURLWithPath: input), localeID: "en", contextualTerms: [])
            await session.finish()
        } catch { errors.append(error.localizedDescription); await session.cancel() }
        let samples = tracker.samples.sorted()
        func percentile(_ p: Double) -> Double { samples.isEmpty ? 0 : samples[min(samples.count - 1, Int(Double(samples.count - 1) * p))] }
        let report = Report(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                            engine: "Nemotron English 0.6B 560ms int8 / sherpa-onnx 1.13.8 / CPU 2 threads / greedy causal decoding", input: input,
                            measurement: "Native subword emission timestamp + 80ms (approximate word end) to first full spelling in provisional text, counted once its next word arrives. No waiting for final paragraph correction. All samples, including >3s, remain uncapped. Token timestamps are estimates, not independent ground truth. Includes real-time pacing, conversion, worker queue, decoding and main-thread result dispatch. Excludes room acoustics, omitted words and compositor paint. Full events preserved for audit.",
                            events: events, sampleCount: samples.count, maximumSeconds: tracker.maximum,
                            p50Seconds: percentile(0.5), p95Seconds: percentile(0.95), overTwoSeconds: tracker.overTwo, overThreeSeconds: tracker.overLimit,
                            durationSeconds: ProcessInfo.processInfo.systemUptime - start, maximumQueueWaitSeconds: queueWait, maximumProcessingSeconds: processing,
                            transcript: events.last?.text ?? "", errors: errors)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
        } catch { print("REPORT ERROR", error); return 2 }
        print(String(format: "samples=%d p50=%.3fs p95=%.3fs max=%.3fs over3=%d queueMax=%.3fs processMax=%.3fs", samples.count, percentile(0.5), percentile(0.95), tracker.maximum, tracker.overLimit, queueWait, processing))
        print("TRANSCRIPT", report.transcript)
        return errors.isEmpty && !samples.isEmpty ? 0 : 1
    }
}

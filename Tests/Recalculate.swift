import Foundation

/// Audit existing captured result events using the app's current latency logic.
@main struct Recalculate {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { print("Usage: recalculate original.json audited.json"); exit(2) }
        struct File: Decodable { let events: [RecognitionEvent] }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let original = try JSONDecoder().decode(File.self, from: data)
        var tracker = LatencyTracker()
        for event in original.events { _ = tracker.accept(event) }
        var report = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let samples = tracker.samples.sorted()
        func percentile(_ p: Double) -> Double { samples.isEmpty ? 0 : samples[min(samples.count - 1, Int(Double(samples.count - 1) * p))] }
        report["sampleCount"] = samples.count
        report["maximumSeconds"] = tracker.maximum
        report["p50Seconds"] = percentile(0.5)
        report["p95Seconds"] = percentile(0.95)
        report["overTwoSeconds"] = tracker.overLimit
        report["recalculatedFromCapturedEvents"] = true
        report["measurement"] = "Final word audio end to first appearance in provisional text, retrospectively aligned using the app's LCS algorithm. Normalize case, punctuation, and zero-to-ten numeral formatting (two/2). Includes realtime pacing, conversion and result dispatch. Excludes microphone/room/compositor, missed words and ambiguous repeated-word matching. Original captured events retained. Not a guarantee of classroom maximum latency."
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print(String(format: "samples=%d p50=%.3f p95=%.3f max=%.3f over2=%d", samples.count, percentile(0.5), percentile(0.95), tracker.maximum, tracker.overLimit))
    }
}

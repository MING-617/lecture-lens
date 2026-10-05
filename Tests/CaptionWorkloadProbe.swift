import Foundation
import CryptoKit
import Combine

/// Isolate result handling from inference, fixture creation, JSON and rendering.
/// Compare binaries built with the old/new Core.swift; timings are not watts.
final class PublishedCaptionState: ObservableObject {
    @Published var history = CaptionHistory()
#if ORIGINAL_TRACKER
    @Published var tracker = StreamingLatencyTracker()
#else
    var tracker = StreamingLatencyTracker()
#endif
}

@main enum CaptionWorkloadProbe {
    struct EventReport: Decodable { let events: [RecognitionEvent] }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func summary(_ tracker: StreamingLatencyTracker) -> [String: Any] {
        ["sampleCount": tracker.sampleCount, "maximum": tracker.maximum, "firstMaximum": tracker.firstDisplayMaximum,
         "correctionMaximum": tracker.correctionMaximum, "corrections": tracker.corrections,
         "overThree": tracker.overLimit, "overTwo": tracker.overTwo,
         "samplesSHA256": digest(tracker.samples.map { String($0) }.joined(separator: ","))]
    }
    static func main() throws {
        var rows: [[String: Any]] = []
        for wordCount in [360, 3600, 14400, 57600] {
            var words = (0..<wordCount).map { WordStamp(text: "word\($0)", start: Double($0) / 2, end: Double($0) / 2 + 0.08) }
            let state = PublishedCaptionState()
            let initial = RecognitionEvent(received: Double(wordCount) / 2 + 1, start: 0, end: Double(wordCount) / 2, text: "", isFinal: false, words: words)
            state.history.acceptStreaming(initial); _ = state.tracker.accept(initial)
            var historySeconds = 0.0, trackerSeconds = 0.0
            let updates = 1200
            for i in 0..<updates {
                let index = wordCount - 2, old = words[index]
                words[index] = WordStamp(text: "variant\(i)", start: old.start, end: old.end)
                var event = RecognitionEvent(received: initial.received + Double(i) * 0.5, start: 0, end: initial.end, text: "", isFinal: i % 23 == 0, words: words)
                event.changedFromWord = index
                let began = ProcessInfo.processInfo.systemUptime
                state.history.acceptStreaming(event)
                let middle = ProcessInfo.processInfo.systemUptime
                _ = state.tracker.accept(event)
                let ended = ProcessInfo.processInfo.systemUptime
                historySeconds += middle - began; trackerSeconds += ended - middle
            }
            rows.append(["retainedWords":wordCount, "updates":updates, "historySeconds":historySeconds, "trackerSeconds":trackerSeconds,
                         "captionSHA256":digest(state.history.captions.map { "\($0.id)|\($0.start)|\($0.end)|\($0.isFinal)|\($0.text)" }.joined(separator: "\n")),
                         "latency":summary(state.tracker)])
        }
        var replays: [[String: Any]] = []
        for path in CommandLine.arguments.dropFirst() {
            let events = try JSONDecoder().decode(EventReport.self, from: Data(contentsOf: URL(fileURLWithPath:path))).events
            var history = CaptionHistory(), tracker = StreamingLatencyTracker(), checksum = SHA256()
            for event in events {
                history.acceptStreaming(event); _ = tracker.accept(event)
                for line in history.captions {
                    checksum.update(data: Data("\(line.id)|\(line.start)|\(line.end)|\(line.isFinal)|\(line.text)\n".utf8))
                }
                checksum.update(data: Data("end-event\n".utf8))
            }
            replays.append(["fixture":URL(fileURLWithPath:path).lastPathComponent, "events":events.count,
                            "allCaptionStatesSHA256":checksum.finalize().map { String(format:"%02x",$0) }.joined(), "latency":summary(tracker)])
        }
        let output: [String:Any] = ["method":"1,200 tail revisions at each retained-word count; timings isolate history and latency handling, excluding fixture copies, inference and rendering. Counts correspond to 2 words/second; not real-time two/eight-hour tests. Replays hash every complete caption state, plus all latency counters and the retained sample sequence.", "workloads":rows, "replays":replays]
        print(String(decoding:try JSONSerialization.data(withJSONObject:output, options:[.sortedKeys,.prettyPrinted]), as:UTF8.self))
    }
}

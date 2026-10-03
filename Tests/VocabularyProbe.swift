import Foundation
import AVFoundation

/// Fast parameter selection only. Latency here uses simulated 100ms audio
/// delivery plus the measured chunk processing time, not microphone latency.
@main enum VocabularyProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let model = args[1], input = args[2], output = args[3]
        let pack = try JSONDecoder().decode(CoursePack.self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: input))
        precondition(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let audio = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let paths = Int(args[5])!, score = Float(args[6])!
        let terms = paths == 0 ? [] : pack.terms.map(\.english)
        let decoder = try StreamingDecoder(model: model, contextualTerms: terms, paths: paths, score: score)
        var tracker = StreamingLatencyTracker(), events: [RecognitionEvent] = [], processingMax = 0.0
        var last = "", origin = ProcessInfo.processInfo.systemUptime
        for i in stride(from: 0, to: audio.count, by: 1600) {
            let end = min(i + 1600, audio.count), start = ProcessInfo.processInfo.systemUptime
            let decoded = decoder.feed(Array(audio[i..<end]))
            let processing = ProcessInfo.processInfo.systemUptime - start
            processingMax = max(processingMax, processing)
            if decoded {
                let (text, words, changed) = decoder.result()
                if text != last {
                    var e = RecognitionEvent(received: Double(end)/16000 + processing, start: 0, end: Double(end)/16000, text: text, isFinal: false, words: words)
                    e.changedFromWord = changed; _ = tracker.accept(e); events.append(e); last = text
                }
            }
        }
        decoder.finish()
        let (text, words, changed) = decoder.result()
        var e = RecognitionEvent(received: Double(audio.count)/16000 + 1, start: 0, end: Double(audio.count)/16000, text: text, isFinal: true, words: words)
        e.changedFromWord = changed; _ = tracker.accept(e); events.append(e)
        let data: [String: Any] = ["paths":paths, "score":score, "enhanced":decoder.enhanced, "transcript":text, "maximumSeconds":tracker.maximum,
            "correctionMaximumSeconds":tracker.correctionMaximum,"overThree":tracker.overLimit,"processingMaximumSeconds":processingMax,
            "computeSeconds":ProcessInfo.processInfo.systemUptime-origin,"durationSeconds":Double(audio.count)/16000,
            "measurement":"Fast simulated audio timing for tuning, excluding queue, microphone and UI; full production-paced validation is separate.",
            "events":try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))]
        try JSONSerialization.data(withJSONObject: data, options:[.sortedKeys]).write(to: URL(fileURLWithPath: output))
        print("PROBE", paths, score, "max",tracker.maximum,"over3",tracker.overLimit,"compute",ProcessInfo.processInfo.systemUptime-origin)
    }
}

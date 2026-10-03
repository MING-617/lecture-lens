import Foundation
import Darwin

func residentMB() -> Double {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : -1
}
func footprintMB() -> (current: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? (Double(info.phys_footprint) / 1048576, Double(info.ledger_phys_footprint_peak) / 1048576) : (-1, -1)
}
@main enum Probe {
    static func main() {
        Task { @MainActor in
            do { try await run() } catch { print("FAIL", error); exit(1) }
            exit(0)
        }
        dispatchMain()
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        let model = URL(fileURLWithPath: args[1]), input = URL(fileURLWithPath: args[2]), seconds = Double(args[3])!, directory = URL(fileURLWithPath: args[4])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = try TranscriptArchive(directory: directory)
        let session = SpeechSession(); session.modelDirectory = model; session.enhancementScore = 0.5
        var enhanced = false
        session.onEnhancement = { active, _ in enhanced = active }
        let pack = try JSONDecoder().decode(CoursePack.self, from: Data(contentsOf: model.deletingLastPathComponent().appendingPathComponent("coursepack.json")))
        var tracker = StreamingLatencyTracker(), history = CaptionHistory(), latest: RecognitionEvent?
        var errors: [String] = [], checkpoints: [[String: Double]] = []
        var queueMax = 0.0, processingMax = 0.0, nextCheckpoint = 60.0, speechBlocks = 0
        let start = ProcessInfo.processInfo.systemUptime
        session.onError = { errors.append($0.localizedDescription) }
        archive.onError = { error in print("SAVE ERROR", error.localizedDescription) }
        session.onVoice = { if $0 { speechBlocks += 1 } }
        session.onPerformance = { queueMax = max(queueMax, $0); processingMax = max(processingMax, $1) }
        session.onResult = { event in
            _ = tracker.accept(event); history.acceptStreaming(event); archive.accept(event); latest = event
            _ = AutomaticTerms.detect(in: history.captions.suffix(2).map(\.text).joined(separator: " "), context: history.captions.suffix(6).map(\.text).joined(separator: " "), terms: pack.terms, known: [])
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if elapsed >= nextCheckpoint {
                let footprint = footprintMB()
                let row = ["elapsedSeconds":elapsed, "recognizedWords":Double(event.words.count), "residentMB":residentMB(), "physicalFootprintMB":footprint.current, "peakPhysicalFootprintMB":footprint.peak, "maximumSeconds":tracker.maximum, "firstDisplayMaximumSeconds":tracker.firstDisplayMaximum, "correctionMaximumSeconds":tracker.correctionMaximum, "corrections":Double(tracker.corrections), "overThree":Double(tracker.overLimit), "queueMaximum":queueMax, "processingMaximum":processingMax]
                checkpoints.append(row); nextCheckpoint += 60
                print(String(format: "PROGRESS %.0fs words=%d rss=%.1fMB max=%.3fs over3=%d processMax=%.3fs", elapsed, event.words.count, row["residentMB"]!, tracker.maximum, tracker.overLimit, processingMax)); fflush(stdout)
                let progress: [String: Any] = ["status":"running", "targetSeconds":seconds, "checkpoints":checkpoints, "archive":archive.url.path]
                try? JSONSerialization.data(withJSONObject: progress, options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("progress.json"), options:.atomic)
            }
        }
        try await session.streamFile(url: input, localeID: "en", contextualTerms: pack.terms.map(\.english), repetitions: 10000, maximumDuration: seconds)
        await session.finish(); try await archive.finish(reason: "test completed")
        let exported = directory.appendingPathComponent("export.txt")
        try await archive.export(to: exported)
        let original = try Data(contentsOf: archive.url), copied = try Data(contentsOf: exported)
        assert(original == copied, "export must exactly match the revised archive")
        let saved = String(decoding: original, as: UTF8.self)
        let body = saved.components(separatedBy: "\n\n")[1]
        let text = body.replacingOccurrences(of: "(?m)^\\[[0-9]+:[0-9]+\\] ", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let finalText = (latest?.words ?? []).map(\.text).joined(separator: " ")
        assert(text == finalText, "all final words, including revisions, must be saved exactly once")
        assert(enhanced && ProcessInfo.processInfo.systemUptime - start >= seconds)
        let samples = tracker.samples.sorted()
        let report: [String: Any] = ["status":"completed", "targetSeconds":seconds, "elapsedSeconds":ProcessInfo.processInfo.systemUptime-start, "sampleCount":tracker.sampleCount, "recognizedWords":latest?.words.count ?? 0, "maximumSeconds":tracker.maximum, "firstDisplayMaximumSeconds":tracker.firstDisplayMaximum, "correctionMaximumSeconds":tracker.correctionMaximum, "corrections":Double(tracker.corrections), "p95Recent10000Seconds":samples.isEmpty ? 0 : samples[Int(Double(samples.count-1)*0.95)], "overThreeSeconds":tracker.overLimit, "maximumQueueWaitSeconds":queueMax, "maximumProcessingSeconds":processingMax, "residentMB":residentMB(), "screenLines":history.captions.count, "speechBlocks":speechBlocks, "archive":archive.url.path, "errors":errors, "checkpoints":checkpoints, "finalWords":try JSONSerialization.jsonObject(with: JSONEncoder().encode(latest?.words ?? [])), "measurement":"Same production converter, native continuous decoder, VAD, main-queue callbacks, caption history, latency tracker and transcript writer. Owned synthesized audio repeated at real-time pace without resets. Estimated token timings; no microphone or real classroom. Recent percentile uses last 10000 samples; max and timeout counts cover whole session."]
        var verified = report
        let footprint = footprintMB()
        verified["physicalFootprintMB"] = footprint.current; verified["peakPhysicalFootprintMB"] = footprint.peak
        verified["enhancementActive"] = enhanced; verified["archiveMatchesFinalWords"] = text == finalText
        verified["exportMatchesArchive"] = original == copied
        try JSONSerialization.data(withJSONObject: verified, options:[.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("report.json"), options:.atomic)
        print("COMPLETED",seconds,"words",latest?.words.count ?? 0,"max",tracker.maximum,"over3",tracker.overLimit,"errors",errors)
        if !errors.isEmpty || tracker.overLimit > 0 { exit(1) }
    }
}

import Foundation
import AVFoundation

final class FailureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class AudioCount: @unchecked Sendable {
    private let lock = NSLock()
    private var end = 0.0
    func accept(_ value: Double) { lock.withLock { end = value } }
    var seconds: Double { lock.withLock { end } }
}

@main struct AudioQueueTests {
    static func main() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        memset(buffer.floatChannelData![0], 0, 1600 * MemoryLayout<Float>.size)
        for terms in [[], ["foreign key", "NumPy", "Scrum"]] as [[String]] {
        let failures = FailureCount()
        let feeder = try AudioFeeder(input: format, model: URL(fileURLWithPath: CommandLine.arguments[1]), onLevel: { _,_,_ in }, onResult: { _ in }, onError: { _ in failures.add() }, onPerformance: { _,_ in }, contextualTerms: terms, score: 0.5)
        assert(feeder.enhanced == !terms.isEmpty)
        let started = ProcessInfo.processInfo.systemUptime
        // Attempt to enqueue 20 seconds of input without real-time pacing.
        // It must reject excess work once, rather than build a 20-second delay.
        for _ in 0..<200 { feeder.submit(buffer, at: ProcessInfo.processInfo.systemUptime) }
        await feeder.finish(cancel: true)
        assert(failures.value == 1, "overload must be reported exactly once")
        assert(ProcessInfo.processInfo.systemUptime - started < 3, "bounded queue must drain quickly rather than replay 20 seconds")
        }
        print("PASS: both ordinary and enhanced workers reject a 20-second burst, report once, and drain within three seconds")
        let failures = FailureCount(), audio = AudioCount()
        let recovering = try AudioFeeder(input: format, model: URL(fileURLWithPath: CommandLine.arguments[1]),
                                        onLevel: { _, end, _ in audio.accept(end) }, onResult: { _ in },
                                        onError: { _ in failures.add() }, onPerformance: { _,_ in },
                                        contextualTerms: ["foreign key", "NumPy"], score: 0.5)
        let entered = DispatchSemaphore(value: 0)
        // Force a brief real interruption; continue delivering input at its
        // normal rate. The old one-second cap discarded the tail here.
        recovering.queue.async { entered.signal(); Thread.sleep(forTimeInterval: 1.1) }
        entered.wait()
        let origin = ProcessInfo.processInfo.systemUptime
        for i in 0..<12 {
            let deadline = origin + Double(i + 1) * 0.1
            let wait = deadline - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            recovering.submit(buffer, at: deadline - 0.1)
        }
        await recovering.finish()
        assert(failures.value == 0 && abs(audio.seconds - 1.2) < 0.001,
               "brief scheduling contention must preserve every input frame")
        assert(ProcessInfo.processInfo.systemUptime - origin < 3,
               "recovering a brief pause must not accumulate a long delayed session")
        print("PASS: a forced 1.1-second interruption recovers all 1.2 seconds of paced input without omission or overflow; completes under three seconds")
    }
}

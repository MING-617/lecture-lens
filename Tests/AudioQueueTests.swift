import Foundation
import AVFoundation

final class FailureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@main struct AudioQueueTests {
    static func main() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        memset(buffer.floatChannelData![0], 0, 1600 * MemoryLayout<Float>.size)
        let failures = FailureCount()
        let feeder = try AudioFeeder(input: format, model: URL(fileURLWithPath: CommandLine.arguments[1]), onLevel: { _,_,_ in }, onResult: { _ in }, onError: { _ in failures.add() }, onPerformance: { _,_ in })
        let started = ProcessInfo.processInfo.systemUptime
        // Attempt to enqueue 20 seconds of input without real-time pacing.
        // It must reject excess work once, rather than build a 20-second delay.
        for _ in 0..<200 { feeder.submit(buffer, at: ProcessInfo.processInfo.systemUptime) }
        await feeder.finish(cancel: true)
        assert(failures.value == 1, "overload must be reported exactly once")
        assert(ProcessInfo.processInfo.systemUptime - started < 3, "bounded queue must drain quickly rather than replay 20 seconds")
        print("PASS: actual streaming worker rejects a 20-second burst, reports once, and drains within three seconds")
    }
}

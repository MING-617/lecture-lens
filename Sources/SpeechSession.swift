import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    static func recommended() -> AudioDeviceID {
        for device in list() {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &transport) == noErr, transport == kAudioDeviceTransportTypeBuiltIn { return device.id }
        }
        return 0
    }
    static func list() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { id in
            var input = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &input, 0, nil, &inputSize) == noErr, inputSize > 0 else { return nil }
            var property = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?, nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &nameSize, &name) == noErr, let name else { return nil }
            return InputDevice(id: id, name: name.takeRetainedValue() as String)
        }
    }
}

enum SessionError: LocalizedError {
    case unavailable, format, microphone, device, queueOverflow, interrupted, conversion(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "缺少内置识别模型，请重新安装完整的软件包。"
        case .format: return "无法建立识别所需的音频格式。"
        case .microphone: return "未获得麦克风权限。请在系统设置 → 隐私与安全性 → 麦克风中允许 Lecture Lens。"
        case .device: return "无法使用所选麦克风。请切换为系统默认麦克风。"
        case .queueOverflow: return "音频处理未跟上，已停止以避免积压旧字幕。请关闭占用 CPU 的程序后重新开始。"
        case .interrupted: return "麦克风输入已中断或设备配置改变。本次字幕会保留，请检查麦克风后重新开始。"
        case .conversion(let message): return "音频转换失败：\(message)"
        }
    }
}

/// Strength, speech and timing for the audio processed since the last update.
/// Batched to a few per second: one main-thread wakeup instead of three per buffer.
struct AudioUpdate: Sendable {
    var level = 0.0
    var end = 0.0
    var origin = 0.0
    var speech = false
    var queueWait = 0.0
    var processing = 0.0
}

// submit() fills this private copy before handing it to the serial worker.
// Neither the callback's original buffer nor the queued copy is mutated later.
private struct OwnedAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}

extension AVAudioPCMBuffer {
    /// A private copy: capture callbacks reuse their buffers.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<source.count {
            if let src = source[i].mData, let dst = target[i].mData { memcpy(dst, src, Int(source[i].mDataByteSize)) }
        }
        return copy
    }
}

final class AudioFeeder: @unchecked Sendable {
    let queue: DispatchQueue
    private let schedulingClass: DispatchQoS.QoSClass
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let decoder: StreamingDecoder
    private let voice: VoiceActivity
    private let lock = NSLock()
    private var originValue: Double?
    private var pendingSeconds = 0.0
    // Audio recorded while the model loaded; allowed on top of the live limit.
    private var backlogSeconds = 0.0
    private var gain = InputGain()
    private var accepting = true
    private var cancelled = false
    private var overflowReported = false
    private var samples: Int64 = 0
    private var lastText = ""
    private var lastTextUptime = -Double.infinity
    private var pendingChange: Int?
    private var update: AudioUpdate?
    private var reportedEnd = 0.0
    let onAudio: @Sendable (AudioUpdate) -> Void
    let onResult: @Sendable (RecognitionEvent) -> Void
    let onError: @Sendable (Error) -> Void
    var enhanced: Bool { decoder.enhanced }

    init(input: AVAudioFormat, model: URL, onAudio: @escaping @Sendable (AudioUpdate) -> Void,
         onResult: @escaping @Sendable (RecognitionEvent) -> Void, onError: @escaping @Sendable (Error) -> Void,
         contextualTerms: [String] = [], paths: Int = 2, score: Float = 1,
         threads: Int = 2, provider: String = "cpu", qos: DispatchQoS.QoSClass = .background) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: format) else { throw SessionError.format }
        self.converter = converter; self.format = format
        self.schedulingClass = qos
        self.queue = DispatchQueue(label: "com.ming.lecturelens.streaming", qos: DispatchQoS(qosClass: qos, relativePriority: 0))
        self.decoder = try StreamingDecoder(model: model.path, contextualTerms: contextualTerms, paths: paths, score: score, threads: threads, provider: provider)
        self.voice = try VoiceActivity(model: model.appendingPathComponent("silero_vad.onnx"))
        self.onAudio = onAudio; self.onResult = onResult; self.onError = onError
    }
    func submit(_ buffer: AVAudioPCMBuffer, at uptime: Double) { schedule(buffer, at: uptime, backlog: false) }
    /// Audio captured while the model was loading, oldest first. It is
    /// processed ahead of live audio at a higher priority to catch up, and
    /// does not count toward the live backlog limit.
    func preload(_ buffers: [(buffer: AVAudioPCMBuffer, uptime: Double)]) {
        for item in buffers { schedule(item.buffer, at: item.uptime, backlog: true) }
    }
    private func schedule(_ buffer: AVAudioPCMBuffer, at uptime: Double, backlog: Bool) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if backlog { backlogSeconds += duration }
        // Absorb a brief scheduling interruption without abandoning words.
        // The live backlog remains bounded below the three-second caption
        // budget, plus whatever startup audio is still being caught up.
        else if pendingSeconds + duration > 1.5 + backlogSeconds {
            accepting = false
            let report = !overflowReported; overflowReported = true
            lock.unlock(); if report { onError(SessionError.queueOverflow) }; return
        } else { pendingSeconds += duration }
        lock.unlock()
        guard let copy = buffer.copied() else { release(duration, backlog: backlog); return }
        let owned = OwnedAudioBuffer(value: copy)
        enqueue(catchUp: backlog) { [self] in
            let copy = owned.value
            defer { release(duration, backlog: backlog) }
            guard !lock.withLock({ cancelled }) else { return }
            if originValue == nil { originValue = uptime }
            let origin = originValue!
            let started = ProcessInfo.processInfo.systemUptime
            let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * format.sampleRate / copy.format.sampleRate) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var provided = false, error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if provided { inputStatus.pointee = .noDataNow; return nil }
                provided = true; inputStatus.pointee = .haveData; return owned.value
            }
            guard status != .error else { onError(SessionError.conversion(error?.localizedDescription ?? "unknown")); return }
            guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
            var values = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            samples += Int64(output.frameLength)
            let end = Double(samples) / 16000
            // The strength bar shows the microphone as it is; recognition and
            // speech detection hear quiet, distant speech boosted.
            let rms = sqrt(values.reduce(0.0) { $0 + Double($1 * $1) } / Double(values.count))
            gain.process(&values)
            // Speech detection only feeds the status line. While captions are
            // still changing, the teacher is evidently speaking; run the
            // detector again once text has been quiet for a second.
            let speech = started - lastTextUptime < 1 || voice.accept(values)
            if decoder.feed(values) { publish(final: false, origin: origin, end: end) }
            var next = update ?? AudioUpdate()
            next.level = rms; next.end = end; next.origin = origin; next.speech = next.speech || speech
            next.queueWait = max(next.queueWait, started - uptime, 0)
            next.processing = max(next.processing, ProcessInfo.processInfo.systemUptime - started)
            update = next
            if end >= reportedEnd + 0.25 { flushUpdate() }
        }
    }
    private func flushUpdate() {
        guard let update else { return }
        self.update = nil; reportedEnd = update.end; onAudio(update)
    }
    private func enqueue(catchUp: Bool = false, _ work: @escaping @Sendable () -> Void) {
        if schedulingClass == .userInitiated { queue.async(execute: work) }
        else {
            // Audio callbacks and UI callers must not promote inference work
            // back to performance priority. The bounded queue still reports
            // overload instead of accumulating delayed lecture audio.
            let qos = schedulingClass == .background && (catchUp || lock.withLock({ pendingSeconds + backlogSeconds >= 0.5 }))
                ? DispatchQoS.QoSClass.utility : schedulingClass
            queue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0), flags: .enforceQoS, execute: work)
        }
    }
    private func release(_ duration: Double, backlog: Bool) {
        lock.withLock {
            if backlog { backlogSeconds = max(0, backlogSeconds - duration) } else { pendingSeconds = max(0, pendingSeconds - duration) }
        }
    }
    private func publish(final: Bool, origin: Double, end: Double) {
        let (text, words, changed) = decoder.result()
        // Reading a result advances the parser even if only token timings
        // changed. Preserve that earliest revision for the next delivered
        // event, so saved timestamps and the on-screen words stay aligned.
        guard final || text != lastText else {
            pendingChange = min(pendingChange ?? changed, changed); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        lastTextUptime = now
        var event = RecognitionEvent(received: now - origin, start: 0, end: end, text: text, isFinal: final, words: words)
        event.producedUptime = now
        event.changedFromWord = min(pendingChange ?? changed, changed)
        pendingChange = nil
        lastText = text; onResult(event)
    }
    func finish(cancel: Bool = false) async {
        lock.withLock { accepting = false; cancelled = cancel }
        await withCheckedContinuation { continuation in
            enqueue { [self] in
                if !cancel, let origin = originValue {
                    decoder.finish(); publish(final: true, origin: origin, end: Double(samples) / 16000); flushUpdate()
                }
                continuation.resume()
            }
        }
    }
}

/// Microphone audio captured while the model loads. Once the worker exists it
/// receives the held audio first, in order, then every later buffer directly,
/// so the first words of a lecture are not lost to model loading.
final class StartupAudio: @unchecked Sendable {
    static let limit = 6.0
    private let lock = NSLock()
    private var held: [(buffer: AVAudioPCMBuffer, uptime: Double)] = []
    private var heldSeconds = 0.0
    private var feeder: AudioFeeder?

    func accept(_ buffer: AVAudioPCMBuffer, at uptime: Double) {
        lock.lock()
        if let feeder { lock.unlock(); feeder.submit(buffer, at: uptime); return }
        defer { lock.unlock() }
        guard let copy = buffer.copied() else { return }
        held.append((copy, uptime)); heldSeconds += Double(copy.frameLength) / copy.format.sampleRate
        // An unusually slow start keeps only the most recent seconds.
        while heldSeconds > Self.limit, let first = held.first {
            heldSeconds -= Double(first.buffer.frameLength) / first.buffer.format.sampleRate; held.removeFirst()
        }
    }
    func attach(_ worker: AudioFeeder) {
        lock.withLock { worker.preload(held); held = []; heldSeconds = 0; feeder = worker }
    }
}

@MainActor class SpeechSession {
    private var engine: AVAudioEngine?
    private var feeder: AudioFeeder?
    private var configObserver: NSObjectProtocol?
    private var capturing = false
    private var tapInstalled = false
    var modelDirectory: URL?
    var onResult: ((RecognitionEvent) -> Void)?
    var onLevel: ((Double, Double, Double) -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?
    var onPerformance: ((Double, Double) -> Void)?
    var onVoice: ((Bool) -> Void)?
    var onEnhancement: ((Bool, String?) -> Void)?
    var enhancementPaths = 2
    var enhancementScore: Float = 1
    // Two threads on the energy-conscious queue passed paced comparisons.
    // Keep input intact and retain the same bounded backlog protection.
    var inferenceThreads = 2
    var inferenceProvider = "cpu"
    var inferenceQoS: DispatchQoS.QoSClass = .background

    func prepare(inputFormat: AVAudioFormat, contextualTerms: [String] = []) async throws {
        guard let model = modelDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("StreamingEnglish"),
              ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt", "silero_vad.onnx"].allSatisfy({ FileManager.default.fileExists(atPath: model.appendingPathComponent($0).path) }) else { throw SessionError.unavailable }
        onStatus?("正在载入本地流式英文识别，已开始收音…")
        let result: @Sendable (RecognitionEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                var delivered = event
                if let produced = event.producedUptime {
                    delivered.receivedAtMainQueue(event.received + ProcessInfo.processInfo.systemUptime - produced)
                }
                self?.onResult?(delivered)
            }
        }
        let audio: @Sendable (AudioUpdate) -> Void = { [weak self] update in
            DispatchQueue.main.async {
                guard let self else { return }
                self.onLevel?(update.level, update.end, update.origin); self.onVoice?(update.speech)
                self.onPerformance?(update.queueWait, update.processing)
            }
        }
        let failure: @Sendable (Error) -> Void = { [weak self] error in DispatchQueue.main.async { self?.onError?(error) } }
        let paths = enhancementPaths, score = enhancementScore
        let threads = inferenceThreads, provider = inferenceProvider, qos = inferenceQoS
        let initialize: @Sendable () throws -> (AudioFeeder, String?) = {
            do {
                let worker = try AudioFeeder(input: inputFormat, model: model, onAudio: audio, onResult: result, onError: failure, contextualTerms: contextualTerms, paths: paths, score: score, threads: threads, provider: provider, qos: qos)
                return (worker, Optional<String>.none)
            } catch {
                guard !contextualTerms.isEmpty else { throw error }
                let normal = try AudioFeeder(input: inputFormat, model: model, onAudio: audio, onResult: result, onError: failure, threads: threads, provider: provider, qos: qos)
                return (normal, Optional("专业词增强初始化失败，正在使用普通英文识别。"))
            }
        }
        let worker: AudioFeeder, fallback: String?
        if qos == .userInitiated {
            (worker, fallback) = try await Task.detached(priority: .userInitiated, operation: initialize).value
        } else {
            // A high-priority task awaiting a detached task can escalate it.
            // Create native model workers on the requested GCD queue instead.
            (worker, fallback) = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: qos).async(qos: DispatchQoS(qosClass: qos, relativePriority: 0), flags: .enforceQoS) {
                    do { continuation.resume(returning: try initialize()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
        onEnhancement?(worker.enhanced, fallback ?? (!contextualTerms.isEmpty && !worker.enhanced ? "专业词增强未能启用，正在使用普通英文识别。" : nil))
        try Task.checkCancellation(); feeder = worker
    }
    func startMicrophone(device: AudioDeviceID, contextualTerms: [String]) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw SessionError.microphone }; try Task.checkCancellation()
        let engine = AVAudioEngine(); self.engine = engine
        let input = engine.inputNode
        if device != 0, let unit = input.audioUnit {
            var deviceID = device
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw SessionError.device }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw SessionError.device }
        // Listen before the model is ready; loading takes a few seconds and
        // the teacher may already be speaking.
        let startup = StartupAudio()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            let uptime = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / format.sampleRate
            startup.accept(buffer, at: uptime)
        }
        tapInstalled = true
        engine.prepare(); try engine.start(); capturing = true
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self, self.capturing { self.onError?(SessionError.interrupted) } }
        }
        try await prepare(inputFormat: format, contextualTerms: contextualTerms); try Task.checkCancellation()
        guard let feeder else { throw SessionError.format }
        startup.attach(feeder)
    }
    func streamFile(url: URL, contextualTerms: [String], repetitions: Int = 1, maximumDuration: Double? = nil) async throws {
        let file = try AVAudioFile(forReading: url)
        try await prepare(inputFormat: file.processingFormat, contextualTerms: contextualTerms); guard let feeder else { throw SessionError.format }
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        let clock = ProcessInfo.processInfo.systemUptime
        var offset = 0.0
        for _ in 0..<repetitions {
            file.framePosition = 0
            while file.framePosition < file.length {
                if let maximumDuration, offset >= maximumDuration - 0.0001 { return }
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw SessionError.format }
                let available = maximumDuration.map { max(1, Int(($0 - offset) * file.processingFormat.sampleRate)) } ?? Int(frames)
                try file.read(into: buffer, frameCount: min(frames, AVAudioFrameCount(available)))
                let duration = Double(buffer.frameLength) / file.processingFormat.sampleRate
                let wait = clock + offset + duration - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                feeder.submit(buffer, at: clock + offset); offset += duration
            }
        }
    }
    private func endCapture() {
        capturing = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }; configObserver = nil
        if let engine { if tapInstalled { engine.inputNode.removeTap(onBus: 0) }; engine.stop() }
        tapInstalled = false; engine = nil
    }
    func haltCapture() { endCapture() }
    func finish() async {
        endCapture(); await feeder?.finish(); feeder = nil; await drainCallbacks()
    }
    func cancel() async {
        endCapture(); await feeder?.finish(cancel: true); feeder = nil; await drainCallbacks()
    }
    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}

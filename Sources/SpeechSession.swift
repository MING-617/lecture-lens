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

// submit() fills this private copy before handing it to the serial worker.
// Neither the callback's original buffer nor the queued copy is mutated later.
private struct OwnedAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
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
    private var accepting = true
    private var cancelled = false
    private var overflowReported = false
    private var samples: Int64 = 0
    private var lastText = ""
    private var pendingChange: Int?
    let onLevel: @Sendable (Double, Double, Double) -> Void
    let onResult: @Sendable (RecognitionEvent) -> Void
    let onError: @Sendable (Error) -> Void
    let onPerformance: @Sendable (Double, Double) -> Void
    let onVoice: @Sendable (Bool) -> Void
    var enhanced: Bool { decoder.enhanced }

    init(input: AVAudioFormat, model: URL, onLevel: @escaping @Sendable (Double, Double, Double) -> Void,
         onResult: @escaping @Sendable (RecognitionEvent) -> Void, onError: @escaping @Sendable (Error) -> Void,
         onPerformance: @escaping @Sendable (Double, Double) -> Void, onVoice: @escaping @Sendable (Bool) -> Void = { _ in },
         contextualTerms: [String] = [], paths: Int = 2, score: Float = 1,
         threads: Int = 2, provider: String = "cpu", qos: DispatchQoS.QoSClass = .background) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: format) else { throw SessionError.format }
        self.converter = converter; self.format = format
        self.schedulingClass = qos
        self.queue = DispatchQueue(label: "com.ming.lecturelens.streaming", qos: DispatchQoS(qosClass: qos, relativePriority: 0))
        self.decoder = try StreamingDecoder(model: model.path, contextualTerms: contextualTerms, paths: paths, score: score, threads: threads, provider: provider)
        self.voice = try VoiceActivity(model: model.appendingPathComponent("silero_vad.onnx"))
        self.onLevel = onLevel; self.onResult = onResult; self.onError = onError; self.onPerformance = onPerformance; self.onVoice = onVoice
    }
    func submit(_ buffer: AVAudioPCMBuffer, at uptime: Double) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.lock()
        guard accepting else { lock.unlock(); return }
        // Absorb a brief scheduling interruption without abandoning words.
        // The backlog remains bounded below the three-second caption budget.
        guard pendingSeconds + duration <= 1.5 else {
            accepting = false
            let report = !overflowReported; overflowReported = true
            lock.unlock(); if report { onError(SessionError.queueOverflow) }; return
        }
        pendingSeconds += duration; lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { release(duration); return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<source.count {
            if let src = source[i].mData, let dst = target[i].mData { memcpy(dst, src, Int(source[i].mDataByteSize)) }
        }
        let owned = OwnedAudioBuffer(value: copy)
        enqueue { [self] in
            let copy = owned.value
            defer { release(duration) }
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
            let values = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            samples += Int64(output.frameLength)
            let end = Double(samples) / 16000
            let rms = sqrt(values.reduce(0.0) { $0 + Double($1 * $1) } / Double(values.count))
            onLevel(rms, end, origin); onVoice(voice.accept(values))
            if decoder.feed(values) { publish(final: false, origin: origin, end: end) }
            onPerformance(max(0, started - uptime), ProcessInfo.processInfo.systemUptime - started)
        }
    }
    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        if schedulingClass == .userInitiated { queue.async(execute: work) }
        else {
            // Audio callbacks and UI callers must not promote inference work
            // back to performance priority. The bounded queue still reports
            // overload instead of accumulating delayed lecture audio.
            let qos = schedulingClass == .background && lock.withLock({ pendingSeconds >= 0.5 })
                ? DispatchQoS.QoSClass.utility : schedulingClass
            queue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0), flags: .enforceQoS, execute: work)
        }
    }
    private func release(_ duration: Double) { lock.lock(); pendingSeconds = max(0, pendingSeconds - duration); lock.unlock() }
    private func publish(final: Bool, origin: Double, end: Double) {
        let (text, words, changed) = decoder.result()
        // Reading a result advances the parser even if only token timings
        // changed. Preserve that earliest revision for the next delivered
        // event, so saved timestamps and the on-screen words stay aligned.
        guard final || text != lastText else {
            pendingChange = min(pendingChange ?? changed, changed); return
        }
        let now = ProcessInfo.processInfo.systemUptime
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
                if !cancel, let origin = originValue { decoder.finish(); publish(final: true, origin: origin, end: Double(samples) / 16000) }
                continuation.resume()
            }
        }
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
        onStatus?("正在载入本地流式英文识别…")
        let result: @Sendable (RecognitionEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                var delivered = event
                if let produced = event.producedUptime {
                    delivered.receivedAtMainQueue(event.received + ProcessInfo.processInfo.systemUptime - produced)
                }
                self?.onResult?(delivered)
            }
        }
        let level: @Sendable (Double, Double, Double) -> Void = { [weak self] rms, end, origin in DispatchQueue.main.async { self?.onLevel?(rms, end, origin) } }
        let failure: @Sendable (Error) -> Void = { [weak self] error in DispatchQueue.main.async { self?.onError?(error) } }
        let performance: @Sendable (Double, Double) -> Void = { [weak self] wait, decode in DispatchQueue.main.async { self?.onPerformance?(wait, decode) } }
        let speech: @Sendable (Bool) -> Void = { [weak self] detected in DispatchQueue.main.async { self?.onVoice?(detected) } }
        let paths = enhancementPaths, score = enhancementScore
        let threads = inferenceThreads, provider = inferenceProvider, qos = inferenceQoS
        let initialize: @Sendable () throws -> (AudioFeeder, String?) = {
            do {
                let worker = try AudioFeeder(input: inputFormat, model: model, onLevel: level, onResult: result, onError: failure, onPerformance: performance, onVoice: speech, contextualTerms: contextualTerms, paths: paths, score: score, threads: threads, provider: provider, qos: qos)
                return (worker, Optional<String>.none)
            } catch {
                guard !contextualTerms.isEmpty else { throw error }
                let normal = try AudioFeeder(input: inputFormat, model: model, onLevel: level, onResult: result, onError: failure, onPerformance: performance, onVoice: speech, threads: threads, provider: provider, qos: qos)
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
    func startMicrophone(device: AudioDeviceID, localeID: String, contextualTerms: [String]) async throws {
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
        try await prepare(inputFormat: format, contextualTerms: contextualTerms); try Task.checkCancellation(); guard let feeder else { throw SessionError.format }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            let uptime = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / format.sampleRate
            feeder.submit(buffer, at: uptime)
        }
        tapInstalled = true
        engine.prepare(); try engine.start(); capturing = true
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self, self.capturing { self.onError?(SessionError.interrupted) } }
        }
    }
    func streamFile(url: URL, localeID: String, contextualTerms: [String], repetitions: Int = 1, maximumDuration: Double? = nil) async throws {
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

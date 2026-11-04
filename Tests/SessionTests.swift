import Foundation

@MainActor final class MockSession: SpeechSession {
    var halted = false
    var finished = false
    var cancelled = false
    var last: RecognitionEvent?
    var vocabulary: [String] = []
    override func startMicrophone(device: UInt32, contextualTerms: [String]) async throws {
        vocabulary = contextualTerms
        onEnhancement?(!contextualTerms.isEmpty, nil)
    }
    override func haltCapture() { halted = true }
    override func finish() async {
        finished = true
        if let e = last { onResult?(RecognitionEvent(received: e.received, start: e.start, end: e.end, text: e.text, isFinal: true, words: e.words)) }
    }
    override func cancel() async { cancelled = true }
    func emit(_ e: RecognitionEvent) { last = e; onResult?(e) }
}
@main enum Tests {
    static func main() async throws { try await run() }
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        assertionFailure("state transition timed out")
    }
    @MainActor static func run() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var mocks: [MockSession] = []
        let preferences = directory.appendingPathComponent("preferences.json")
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        // A transcript left behind by an unexpected exit is moved on the next start.
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let orphan = staging.appendingPathComponent("orphan.txt")
        try Data("Lecture Lens · English captions\n\nunfinished words ".utf8).write(to: orphan)
        let model = AppModel(transcriptDirectory: directory, stagingDirectory: staging, preferenceURL: preferences, makeSession: { let s = MockSession(); mocks.append(s); return s })
        model.terms = [Term(english: "foreign key", chinese: "外键", explanation: "", course: "5076"), Term(english: "Custom Widget", chinese: "自备术语", explanation: "", course: "General")]
        model.known = Set(model.terms.map(\.id)); model.chineseHints = false
        model.fontSize = 36; model.floatWindow = true; model.device = 0
        assert(!model.keepsDisplayAwake)
        model.start(); try await waitUntil { model.running }
        assert(model.keepsDisplayAwake, "a running session keeps the display awake")
        model.keepScreenOn = false
        assert(!model.keepsDisplayAwake && model.preventsAppNap, "turning the screen option off mid-session lets the display sleep but keeps recognition unthrottled")
        model.keepScreenOn = true; assert(model.keepsDisplayAwake, "turning it back on applies at once")
        let first = mocks[0], stagedURL = model.savedURL!
        let recovered = try String(contentsOf: directory.appendingPathComponent("orphan.txt"), encoding: .utf8)
        assert(recovered.contains("unfinished words") && recovered.contains("recovered on next launch") && !FileManager.default.fileExists(atPath: orphan.path))
        assert(stagedURL.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL, "recording writes to the local staging folder")
        assert(first.vocabulary == ["Custom Widget", "foreign key"] && model.enhancementActive, "known words and disabled Chinese hints must still boost English recognition")
        model.setEnhancement(false); assert(model.enhanceTerms, "cannot change the decoder mid-session")
        let words = (0..<4001).map { WordStamp(text: "word\($0)", start: Double($0), end: Double($0)+0.1) }
        let e = RecognitionEvent(received: 4001.2, start: 0, end: 4001, text: "", isFinal: false, words: words)
        first.emit(e)
        assert(model.history.captions.count == 300)
        model.requestStop(); assert(model.showStopConfirmation && model.running && !first.halted)
        model.cancelStop(); assert(!model.showStopConfirmation && model.running && !first.halted)
        model.showHelp = true
        model.requestStop(after: .quit)
        assert(!model.showHelp && !model.showStopConfirmation && model.running)
        model.presentPendingStop(); assert(model.showStopConfirmation)
        model.cancelStop()
        model.requestStop(); model.confirmStop(); assert(first.halted && model.stopping && !model.running)
        try await waitUntil { !model.stopping }
        assert(first.finished && !model.hasActiveSession && model.status.contains("已停止"))
        assert(!model.keepsDisplayAwake && !model.preventsAppNap, "stopping releases the display and App Nap")
        model.keepScreenOn = false; assert(!model.preventsAppNap, "the option alone holds nothing without a session")
        let firstURL = model.savedURL!
        assert(firstURL == directory.appendingPathComponent(stagedURL.lastPathComponent) && !FileManager.default.fileExists(atPath: stagedURL.path),
               "the finished transcript moves once into the transcript folder")
        let saved = try String(contentsOf: firstURL, encoding: .utf8)
        assert(saved.contains("word0 ") && saved.contains("word4000 "), "archive must include both early words outside the UI and the final unfinished word")
        let count = saved.components(separatedBy: "word").count-1
        assert(count == 4001, "repeated partial hypotheses must not duplicate saved words")
        let before = model.history.captions
        first.emit(e); assert(model.history.captions == before, "late callbacks after stop must be ignored")
        model.setEnhancement(false)
        let restored = AppModel(transcriptDirectory: directory, preferenceURL: preferences)
        assert(!restored.enhanceTerms, "enhancement setting survives restart")
        assert(restored.fontSize == 36 && restored.floatWindow && !restored.chineseHints && restored.device == 0 && !restored.keepScreenOn,
               "font size, pinning, Chinese hints, the screen option and the chosen microphone survive restart")
        model.keepScreenOn = true
        model.start(); try await waitUntil { model.running }
        assert(model.savedURL != firstURL && model.history.captions.isEmpty)
        first.emit(e); assert(model.history.captions.isEmpty, "an old session cannot contaminate a new session")
        let stillSaved = try String(contentsOf: firstURL, encoding: .utf8); assert(stillSaved == saved)
        let second = mocks[1]
        assert(second.vocabulary.isEmpty && !model.enhancementActive)
        model.toggleCompact(); assert(model.compact && model.running && model.savedURL != firstURL)
        model.toggleCompact(); assert(!model.compact && model.running)
        second.emit(RecognitionEvent(received: 1, start: 0, end: 1, text: "hello", isFinal: false, words: [WordStamp(text: "hello", start: 0.2, end: 0.4)]))
        second.onRecovery?("麦克风设备发生变化，已自动恢复收音。")
        assert(model.running && model.notice?.contains("自动恢复") == true && model.error == nil, "a recovered input keeps the session running")
        model.interrupt("device disconnected"); try await waitUntil { !model.stopping }
        assert(second.halted && second.cancelled && !model.showStopConfirmation && model.error == "device disconnected")
        let secondSaved = try String(contentsOf: model.savedURL!, encoding: .utf8)
        assert(secondSaved.contains("hello") && secondSaved.contains("device disconnected"))
        assert(secondSaved.contains("自动恢复收音：[00:00]"), "the transcript records when the input was reopened")
        // Starting cannot proceed if the transcript path cannot be created.
        let invalid = directory.appendingPathComponent("not-a-folder")
        try Data("existing file".utf8).write(to: invalid)
        let blockedSession = MockSession()
        let blocked = AppModel(transcriptDirectory: invalid, stagingDirectory: staging, preferenceURL: preferences, makeSession: { blockedSession })
        blocked.start(); try await waitUntil { !blocked.preparing }
        assert(!blocked.running && blocked.error != nil && blocked.savedURL == nil)
        assert(!blocked.keepsDisplayAwake, "a failed start releases the display")
        let legacy = directory.appendingPathComponent("legacy-preferences.json")
        try Data("{\"terms\":[],\"known\":[],\"version\":4}".utf8).write(to: legacy)
        let legacyModel = AppModel(transcriptDirectory: directory, preferenceURL: legacy)
        assert(legacyModel.enhanceTerms && legacyModel.fontSize == 30 && legacyModel.chineseHints && !legacyModel.floatWindow && legacyModel.keepScreenOn,
               "legacy preferences default to enhancement enabled and the original display settings")
        print("PASS: all English terms boost recognition independently of Chinese/known settings; setting is immutable while active and persists; display settings and microphone persist; the display stays awake only while a session runs and the option can change mid-session; layout changes share session; old preferences remain readable")
        print("PASS: cancel leaves capture active; confirmed stop halts capture and finalizes all 4001 words; restart preserves files; old callbacks isolated; device interruption saves; a reopened input keeps the session and is noted in the transcript; save-path failure prevents unsafe start; staged recording moves into the transcript folder when finished; orphaned staging files are recovered")
    }
}

import Foundation

@MainActor final class MockSession: SpeechSession {
    var halted = false
    var finished = false
    var cancelled = false
    var last: RecognitionEvent?
    var vocabulary: [String] = []
    override func startMicrophone(device: UInt32, localeID: String, contextualTerms: [String]) async throws {
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
        let model = AppModel(transcriptDirectory: directory, preferenceURL: preferences, makeSession: { let s = MockSession(); mocks.append(s); return s })
        model.terms = [Term(english: "foreign key", chinese: "外键", explanation: "", course: "5076"), Term(english: "Custom Widget", chinese: "自备术语", explanation: "", course: "General")]
        model.known = Set(model.terms.map(\.id)); model.chineseHints = false
        model.start(); try await waitUntil { model.running }
        let first = mocks[0], firstURL = model.savedURL!
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
        let saved = try String(contentsOf: firstURL, encoding: .utf8)
        assert(saved.contains("word0 ") && saved.contains("word4000 "), "archive must include both early words outside the UI and the final unfinished word")
        let count = saved.components(separatedBy: "word").count-1
        assert(count == 4001, "repeated partial hypotheses must not duplicate saved words")
        let before = model.history.captions
        first.emit(e); assert(model.history.captions == before, "late callbacks after stop must be ignored")
        model.setEnhancement(false)
        let restored = AppModel(transcriptDirectory: directory, preferenceURL: preferences)
        assert(!restored.enhanceTerms, "enhancement setting survives restart")
        model.start(); try await waitUntil { model.running }
        assert(model.savedURL != firstURL && model.history.captions.isEmpty)
        first.emit(e); assert(model.history.captions.isEmpty, "an old session cannot contaminate a new session")
        let stillSaved = try String(contentsOf: firstURL, encoding: .utf8); assert(stillSaved == saved)
        let second = mocks[1]
        assert(second.vocabulary.isEmpty && !model.enhancementActive)
        model.toggleCompact(); assert(model.compact && model.running && model.savedURL != firstURL)
        model.toggleCompact(); assert(!model.compact && model.running)
        second.emit(RecognitionEvent(received: 1, start: 0, end: 1, text: "hello", isFinal: false, words: [WordStamp(text: "hello", start: 0.2, end: 0.4)]))
        model.interrupt("device disconnected"); try await waitUntil { !model.stopping }
        assert(second.halted && second.cancelled && !model.showStopConfirmation && model.error == "device disconnected")
        let secondSaved = try String(contentsOf: model.savedURL!, encoding: .utf8)
        assert(secondSaved.contains("hello") && secondSaved.contains("device disconnected"))
        // Starting cannot proceed if the transcript path cannot be created.
        let invalid = directory.appendingPathComponent("not-a-folder")
        try Data("existing file".utf8).write(to: invalid)
        let blockedSession = MockSession()
        let blocked = AppModel(transcriptDirectory: invalid, preferenceURL: preferences, makeSession: { blockedSession })
        blocked.start(); try await waitUntil { !blocked.preparing }
        assert(!blocked.running && blocked.error != nil && blocked.savedURL == nil)
        let legacy = directory.appendingPathComponent("legacy-preferences.json")
        try Data("{\"terms\":[],\"known\":[],\"version\":4}".utf8).write(to: legacy)
        assert(AppModel(transcriptDirectory: directory, preferenceURL: legacy).enhanceTerms, "legacy preferences default to enhancement enabled")
        print("PASS: all English terms boost recognition independently of Chinese/known settings; setting is immutable while active and persists; layout changes share session; old preferences remain readable")
        print("PASS: cancel leaves capture active; confirmed stop halts capture and finalizes all 4001 words; restart preserves files; old callbacks isolated; device interruption saves; save-path failure prevents unsafe start")
    }
}

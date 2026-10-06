import Foundation

@main enum RevisionTests {
    static func main() async throws {
        var parser = StreamingWords()
        let tokens = [TokenPiece(text: "▁foreign", time: 0.2), TokenPiece(text: "▁gee", time: 0.8), TokenPiece(text: "▁table", time: 1.4)]
        var (words, changed) = parser.accept(tokens)
        assert(words.map(\.text) == ["foreign", "gee", "table"] && changed == 0)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let archive = try TranscriptArchive(directory: folder)
        func event(_ words: [WordStamp], _ changed: Int, _ at: Double, final: Bool = false) -> RecognitionEvent {
            var e = RecognitionEvent(received: at, start: 0, end: 2, text: words.map(\.text).joined(separator: " "), isFinal: final, words: words)
            e.changedFromWord = changed; return e
        }
        var tracker = StreamingLatencyTracker()
        var history = CaptionHistory()
        let initial = event(words, changed, 2)
        archive.accept(initial); history.acceptStreaming(initial); _ = tracker.accept(initial)
        (words, changed) = parser.accept([tokens[0], TokenPiece(text: "▁key", time: 0.8), tokens[2]])
        assert(changed == 1 && words.map(\.text) == ["foreign", "key", "table"])
        let revised = event(words, changed, 8)
        archive.accept(revised); history.acceptStreaming(revised); _ = tracker.accept(revised)
        assert(tracker.correctionMaximum > 7 && tracker.maximum > 7 && tracker.overLimit == 1)
        (words, changed) = parser.accept([TokenPiece(text: "▁key", time: 0.8), tokens[2]])
        archive.accept(event(words, changed, 8.2)); history.acceptStreaming(event(words, changed, 8.2))
        (words, changed) = parser.accept([TokenPiece(text: "▁primary", time: 0.2), TokenPiece(text: "▁key", time: 0.8), tokens[2], TokenPiece(text: ".", time: 12)])
        assert(words.last?.end == 1.48, "late punctuation must not move the spoken word end")
        let final = event(words, changed, 12, final: true)
        archive.accept(final); history.acceptStreaming(final)
        try await archive.finish(reason: "revision test")
        let text = try String(contentsOf: archive.url, encoding: .utf8)
        assert(text.contains("primary key table.") && !text.contains("foreign") && !text.contains("gee"))
        assert(history.captions.map(\.text).joined(separator: " ") == "primary key table.")
        let exported = folder.appendingPathComponent("export.txt")
        try await archive.export(to: exported)
        let exportedData = try Data(contentsOf: exported), savedData = try Data(contentsOf: archive.url)
        assert(exportedData == savedData)
        (words, changed) = parser.accept([]); assert(words.isEmpty && changed == 0)
        history.acceptStreaming(event(words, changed, 13)); assert(history.captions.isEmpty)
        let legacy = Data(#"{"received":1,"start":0,"end":1,"text":"hello","isFinal":true,"words":[{"text":"hello","start":0,"end":1}]}"#.utf8)
        let oldEvent = try JSONDecoder().decode(RecognitionEvent.self, from: legacy)
        assert(oldEvent.changedFromWord == nil)
        var punctuation = StreamingWords()
        let (spoken, _) = punctuation.accept([TokenPiece(text: "▁hello", time: 1), TokenPiece(text: "▁", time: 8), TokenPiece(text: ".", time: 8), TokenPiece(text: "▁world", time: 9)])
        assert(spoken.map(\.text) == ["hello.", "world"] && spoken[0].end == 1.08, "standalone punctuation must attach to a spoken word and never create a zero-time phantom word")
        var realignment = StreamingLatencyTracker()
        _ = realignment.accept(event([WordStamp(text: "hello", start: 0.2, end: 0.5)], 0, 1, final: true))
        _ = realignment.accept(event([WordStamp(text: "hello.", start: 0.1, end: 0.4)], 0, 20, final: true))
        assert(realignment.overLimit == 0 && realignment.sampleCount == 1, "equivalent spelling and timestamps must preserve the first appearance")
        var boundary = StreamingWords()
        _ = boundary.accept([TokenPiece(text: "▁this", time: 0.1), TokenPiece(text: "▁super", time: 0.4), TokenPiece(text: "▁key", time: 0.7), TokenPiece(text: "▁works", time: 1)])
        let (joined, joinStart) = boundary.accept([TokenPiece(text: "▁this", time: 0.1), TokenPiece(text: "▁super", time: 0.4), TokenPiece(text: "key", time: 0.7), TokenPiece(text: "▁works", time: 1)])
        assert(joined.map(\.text) == ["this", "superkey", "works"] && joinStart == 1)
        let (split, splitStart) = boundary.accept([TokenPiece(text: "▁this", time: 0.1), TokenPiece(text: "▁super", time: 0.4), TokenPiece(text: "▁key", time: 0.7), TokenPiece(text: "▁works", time: 1)])
        assert(split.map(\.text) == ["this", "super", "key", "works"] && splitStart == 1)
        // Removing an unchanged suffix can leave the earliest changed index
        // past the new unfinished word. This must not create a reversed range.
        var rollbackParser = StreamingWords(), rollbackTracker = StreamingLatencyTracker()
        let four = ["one", "two", "three", "four"].enumerated().map { TokenPiece(text: "▁" + $0.element, time: Double($0.offset) * 0.3) }
        let (beforeRollback, _) = rollbackParser.accept(four)
        _ = rollbackTracker.accept(event(beforeRollback, 0, 1.2))
        let (afterRollback, rollbackStart) = rollbackParser.accept(Array(four.prefix(2)))
        assert(rollbackStart == 2 && afterRollback.count == 2)
        _ = rollbackTracker.accept(event(afterRollback, rollbackStart, 1.3))
        assert(rollbackTracker.sampleCount == 3, "a suffix retraction preserves measured samples without remeasuring an unfinished word")
        _ = rollbackTracker.accept(event([], 0, 1.4))
        _ = rollbackTracker.accept(event(afterRollback, 0, 8, final: true))
        assert(rollbackTracker.overLimit == 2, "retracted words reappearing late must get new appearance times")
        // Tail-only parsing must equal full re-parsing whenever the tokens
        // before the offset are final, including punctuation that attaches to
        // a final word and continuations that merge across the boundary.
        var full = StreamingWords(), tail = StreamingWords(), seed: UInt64 = 617
        func random(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(limit))
        }
        let vocabulary = ["▁the", "▁super", "key", "▁table", ",", ".", "▁", "s", "▁data", "base", "▁2", "▁"]
        var stream: [TokenPiece] = [], stable = 0, clock = 0.0
        for step in 0..<3000 {
            // Revise or retract only the unstable suffix, then append.
            let unstable = stream.count - stable
            if unstable > 0, random(3) == 0 { stream.removeLast(random(unstable + 1)) }
            if unstable > 0, random(4) == 0, !stream.isEmpty, stream.count > stable {
                let i = stable + random(stream.count - stable)
                stream[i] = TokenPiece(text: vocabulary[random(vocabulary.count)], time: stream[i].time + 0.01)
            }
            for _ in 0..<random(4) { clock += 0.08; stream.append(TokenPiece(text: vocabulary[random(vocabulary.count)], time: clock)) }
            let offset = min(tail.tokenCount, stable)
            let expected = full.accept(stream), actual = tail.accept(Array(stream[offset...]), from: offset)
            assert(expected.0 == actual.0 && expected.1 == actual.1, "tail parsing differs at step \(step)")
            assert(tail.text == actual.0.map(\.text).joined(separator: " "), "incremental text differs at step \(step)")
            if random(2) == 0 { stable = max(stable, stream.count - random(6)) }
            stable = min(stable, stream.count)
        }
        assert(RecognitionVocabulary.phrases([" SQL ", "sql", "bad:9", "bad/phrase", "foreign key", "C++"]) == ["C++", "foreign key", "SQL"])
        print("PASS: native token replacement, deletion, insertion and empty rollback; 3,000 tail-only parses equal full re-parsing; late punctuation; corrected archive/export/history; uncapped revision delay; legacy events and hotword grammar")
    }
}

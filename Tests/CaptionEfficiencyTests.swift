import Foundation

@main enum CaptionEfficiencyTests {
    static func rebuilt(_ event: RecognitionEvent) -> [Caption] {
        let total = (event.words.count + 11) / 12
        return (max(0, total - 300)..<total).map { group in
            let words = event.words[(group * 12)..<min(group * 12 + 12, event.words.count)]
            return Caption(start: words.first!.start, end: words.last!.end,
                           text: words.map(\.text).joined(separator: " "),
                           isFinal: event.isFinal || group < total - 1,
                           stableID: "stream-\(event.start)-\(group)")
        }
    }
    static func main() {
        var history = CaptionHistory(), previous: [WordStamp] = []
        var seed: UInt64 = 617, serial = 0
        func random(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        func word() -> WordStamp {
            serial += 1
            return WordStamp(text: "word\(serial)", start: Double(serial) / 3, end: Double(serial) / 3 + 0.08)
        }
        var words = (0..<6000).map { _ in word() }
        for step in 0..<1200 {
            var start = 0.0
            switch step % 13 {
            case 0: words.append(contentsOf: (0..<random(25) + 1).map { _ in word() })
            case 1, 2:
                if !words.isEmpty { words[random(words.count)] = word() }
            case 3:
                if !words.isEmpty { words.removeSubrange(random(words.count)..<words.count) }
            case 4: words.insert(contentsOf: (0..<12).map { _ in word() }, at: random(words.count + 1))
            case 5:
                if !words.isEmpty {
                    let i = random(words.count), old = words[i]
                    words[i] = WordStamp(text: old.text + ".", start: old.start - 0.01, end: old.end)
                }
            case 6: words.append(contentsOf: (0..<3700).map { _ in word() })
            case 7: start = 100 // Different stream identity must invalidate cached lines.
            case 8: history.clear()
            case 9: history.accept(Caption(start: -1, end: 0, text: "legacy", isFinal: true))
            case 10: words = Array(words.prefix((words.count / 24) * 12)) // Exact line-boundary rollback.
            case 11: words = []
            default: words.append(word())
            }
            var common = 0
            while common < min(words.count, previous.count), words[common] == previous[common] { common += 1 }
            var event = RecognitionEvent(received: Double(step), start: start, end: Double(step), text: "", isFinal: step % 5 == 0, words: words)
            // Old events without revision metadata still take the complete path.
            if step % 9 != 0 { event.changedFromWord = common }
            history.acceptStreaming(event)
            assert(history.captions == rebuilt(event), "incremental captions differ at mutation \(step)")
            assert(history.captions.count <= 300)
            previous = words
        }
        print("PASS: 1,200 independent full-rebuild comparisons: appends, arbitrary revisions, inserts, deletions, rollback across 300-line cap, timestamp/punctuation changes, finalization, empty results, stream changes and legacy events")
    }
}

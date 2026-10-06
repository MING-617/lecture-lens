import Foundation

@main struct CoreTests {
    static func main() {
        // Demonstration terms, kept here as a small fixture for glossary matching.
        let demo = [
            Term(english: "race condition", chinese: "竞态条件", explanation: "", course: "Systems"),
            Term(english: "deadlock", chinese: "死锁", explanation: "", course: "Systems"),
            Term(english: "primary key", chinese: "主键", explanation: "", course: "Database"),
            Term(english: "transaction", chinese: "事务", explanation: "", course: "Database")
        ]
        let matches = Glossary.matches(in: "A DEADLOCK is unlike deadlocked code. Compare race condition.", terms: demo, known: [])
        assert(matches.map(\.english) == ["race condition", "deadlock"], "longer phrases sort first; whole words only")
        assert(Glossary.matches(in: "race conditions and primary keys", terms: demo, known: []).count == 2, "common plurals must match term hints")
        assert(Glossary.matches(in: "deadlocked", terms: demo, known: []).isEmpty, "substring matches must not produce false terms")
        assert(Glossary.matches(in: "deadlock", terms: demo, known: ["deadlock"]).isEmpty, "mastered terms must stay hidden")
        let packURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let pack = try! JSONDecoder().decode(CoursePack.self, from: Data(contentsOf: packURL))
        assert(pack.courses.count == 6 && pack.terms.count == 321)
        assert(Set(pack.terms.map(\.id)).count == pack.terms.count)
        assert(pack.terms.allSatisfy { !$0.source!.isEmpty && !($0.references ?? []).isEmpty })
        let databases = "5076"
        let found = Glossary.matches(in: "Entities have attributes and relationships.", terms: pack.terms, known: [])
        assert(Set(found.map(\.english)).isSuperset(of: ["entity", "attribute", "relationship"]), "entity/ies plural must work")
        assert(!Glossary.matches(in: "primary keys", terms: pack.terms, known: [databases.lowercased() + "|primary key"]).contains { $0.course == databases && $0.english == "primary key" })
        let hardwareWord = Term(english: "word", chinese: "机器字", explanation: "", course: "hardware")
        let englishWord = Term(english: "word", chinese: "单词", explanation: "", course: "English")
        assert(hardwareWord.id != englishWord.id, "same spelling must preserve distinct course meanings")
        let legacy = try! JSONDecoder().decode(Term.self, from: Data(#"{"english":"custom","chinese":"自定义","explanation":"","course":"My course"}"#.utf8))
        assert(legacy.source == nil, "old custom preferences must decode without source")
        assert(Glossary.matches(in: "user defined data types", terms: pack.terms, known: []).contains { $0.english == "user-defined data type" }, "ASR space/hyphen variation must match")
        func hints(_ text: String, context: String? = nil, known: Set<String> = []) -> [Term] {
            AutomaticTerms.detect(in: text, context: context ?? text, terms: pack.terms, known: known)
        }
        assert(hints("A sentinel value tells a Python loop when to stop.").contains { $0.english == "sentinel value" })
        assert(hints("A Gatherer keeps a total. A Stepper changes regularly.").contains { $0.english == "Stepper" })
        assert(hints("Scrum uses a sprint backlog and user stories.").contains { $0.course == "5059" && $0.english == "sprint backlog" })
        assert(hints("A SQL database stores each tuple in a relation.").contains { $0.english == "tuple" && $0.course == "5076" })
        assert(hints("Python uses an immutable tuple.").contains { $0.english == "tuple" && $0.course == "4039" })
        assert(!hints("A tuple is convenient.").contains { $0.english == "tuple" }, "ambiguous words must wait for context")
        assert(!hints("Welcome to this class. That is a word we use. Try it with me.").contains { ["class", "word", "try", "with"].contains($0.english.lowercased()) }, "ordinary English must not produce technical guesses")
        assert(!hints("In this Python class we will study later.").contains { $0.english == "class" })
        assert(!hints("The CPU discussion is a bit more complicated.").contains { $0.english == "bit" })
        assert(hints("The CPU processes a word of thirty two bits.").contains { $0.english == "word" && $0.chinese == "机器字" })
        assert(hints("My dissertation needs an abstract and references.").contains { $0.english == "abstract" && $0.course == "5018P" })
        assert(!hints("UML is an abstract view of the software.").contains { $0.english == "abstract" }, "abstract adjective must not mean dissertation summary")
        assert(hints("IaaS means infrastructure as a service.").filter { $0.chinese == "基础设施即服务" }.count == 1, "same-meaning aliases must produce one hint")
        let latest = hints("A sentinel value stops a loop. Later we discuss shadow IT and zero trust.")
        assert(latest.first?.english == "zero trust", "newly spoken terms must come first")
        let learned = pack.terms.filter { $0.chinese == "基础设施即服务" }.map(\.id)
        assert(hints("IaaS means infrastructure as a service.", known: Set(learned)).isEmpty)
        let time = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { _ = hints("SQL databases use candidate keys and foreign keys. A tuple is one row of a relation.") }
        print(String(format: "Automatic detection: %.2f ms per sample (100 runs, %d entries)", (ProcessInfo.processInfo.systemUptime - time) * 10, pack.terms.count))
        var streaming = StreamingLatencyTracker()
        _ = streaming.accept(RecognitionEvent(received: 0.8, start: 0, end: 0.7, text: "hello", isFinal: false, words: [WordStamp(text: "hello", start: 0.2, end: 0.6)]))
        _ = streaming.accept(RecognitionEvent(received: 1.2, start: 0, end: 1.1, text: "hello world", isFinal: false, words: [WordStamp(text: "hello", start: 0.2, end: 0.6), WordStamp(text: "world", start: 0.8, end: 1)]))
        _ = streaming.accept(RecognitionEvent(received: 16, start: 0, end: 1.1, text: "hello world", isFinal: true, words: [WordStamp(text: "hello", start: 0.2, end: 0.6), WordStamp(text: "world", start: 0.8, end: 1)]))
        assert(streaming.samples.count == 2 && abs(streaming.maximum - 0.2) < 0.001, "streaming word samples must not await paragraph finalization")
        var lateStreaming = StreamingLatencyTracker()
        _ = lateStreaming.accept(RecognitionEvent(received: 1.2, start: 0, end: 1.1, text: "foreign gee", isFinal: false, words: [WordStamp(text: "foreign", start: 0.2, end: 0.6), WordStamp(text: "gee", start: 0.8, end: 1)]))
        _ = lateStreaming.accept(RecognitionEvent(received: 16, start: 0, end: 1.1, text: "foreign key", isFinal: true, words: [WordStamp(text: "foreign", start: 0.2, end: 0.6), WordStamp(text: "key", start: 0.8, end: 1)]))
        assert(lateStreaming.maximum == 15 && lateStreaming.overLimit == 1, "real late spellings must stay visible as uncapped >3s samples")
        var longSession = StreamingLatencyTracker()
        let lateWord = WordStamp(text: "late", start: 0, end: 1)
        _ = longSession.accept(RecognitionEvent(received: 5, start: 0, end: 1, text: "late", isFinal: true, words: [lateWord]))
        let recentWords = (0..<10001).map { _ in WordStamp(text: "recent", start: 19, end: 20) }
        _ = longSession.accept(RecognitionEvent(received: 21, start: 0, end: 20, text: "", isFinal: true, words: [lateWord] + recentWords))
        assert(longSession.samples.count == 10000 && longSession.maximum == 4 && longSession.overLimit == 1 && longSession.overTwo == 1, "bounded sample storage must preserve whole-session maxima and timeout counts")
        var lines = CaptionHistory()
        let words = (0..<30).map { WordStamp(text: "word\($0)", start: Double($0) / 3, end: Double($0 + 1) / 3) }
        lines.acceptStreaming(RecognitionEvent(received: 11, start: 0, end: 10, text: "", isFinal: false, words: words))
        assert(lines.captions.count == 3 && lines.captions[0].isFinal && !lines.captions[2].isFinal)
        let firstID = lines.captions[0].id
        lines.acceptStreaming(RecognitionEvent(received: 12, start: 0, end: 11, text: "", isFinal: false, words: words + [WordStamp(text: "more", start: 10, end: 11)]))
        assert(lines.captions[0].id == firstID && lines.captions[0].text.hasPrefix("word0 word1"), "appending live words must preserve earlier short subtitle lines")
        let manyWords = (0..<4000).map { WordStamp(text: "x", start: Double($0), end: Double($0 + 1)) }
        lines.acceptStreaming(RecognitionEvent(received: 4001, start: 0, end: 4000, text: "", isFinal: false, words: manyWords))
        assert(lines.captions.count == 300 && Set(lines.captions.map(\.id)).count == 300, "long continuous speech must retain a bounded set of unique short lines")
        var health = CaptureHealth()
        for t in 1...10 { health.audio(speech: false, at: Double(t)) }
        assert(health.state(at: 10) == .waiting, "non-speech noise must not claim a speech-recognition stall")
        for t in 11...15 { health.audio(speech: true, at: Double(t)) }
        assert(health.state(at: 15) == .noText)
        health.text(at: 15); assert(health.state(at: 15.1) == .speaking)
        health.audio(speech: false, at: 16); assert(health.state(at: 16) == .waiting)
        assert(health.state(at: 19.1) == .interrupted, "missing audio buffers must be distinguished from a teacher pausing")
        print("PASS: glossary boundaries/plurals/known, automatic hints, streaming first-display latency and limit warning, bounded caption lines, capture health")
    }
}

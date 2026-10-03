import Foundation

struct Caption: Identifiable, Equatable {
    var id: String { stableID ?? String(format: "%.3f", start) }
    let start: Double
    let end: Double
    let text: String
    let isFinal: Bool
    var stableID: String? = nil
}

/// Replace overlapping provisional results instead of appending every hypothesis.
struct CaptionHistory {
    private(set) var captions: [Caption] = []
    mutating func accept(_ caption: Caption) {
        guard !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        captions.removeAll { old in
            let overlaps = old.start < caption.end - 0.005 && caption.start < old.end - 0.005
            return old.id == caption.id || (!old.isFinal && overlaps)
        }
        captions.append(caption)
        captions.sort { $0.start < $1.start }
        // A bounded in-memory history keeps a long lecture from growing without limit.
        if captions.count > 300 { captions.removeFirst(captions.count - 300) }
    }
    mutating func clear() { captions = [] }
    mutating func acceptStreaming(_ event: RecognitionEvent) {
        guard !event.words.isEmpty else { captions = []; return }
        let count = 12, total = (event.words.count + count - 1) / count
        var lines: [Caption] = []
        for group in max(0, total - 300)..<total {
            let begin = group * count, end = min(begin + count, event.words.count)
            let words = event.words[begin..<end]
            lines.append(Caption(start: words.first!.start, end: words.last!.end,
                                 text: words.map(\.text).joined(separator: " "), isFinal: event.isFinal || group < total - 1,
                                 stableID: "stream-\(event.start)-\(group)"))
        }
        captions = lines
    }
}

struct Term: Codable, Identifiable, Equatable {
    var id: String { course.lowercased() + "|" + english.lowercased() }
    var english: String
    var chinese: String
    var explanation: String
    var course: String
    var source: String? = nil
    var references: [TermReference]? = nil
}

struct TermReference: Codable, Equatable {
    var file: String
    var page: Int
    var path: String
    var relative: String
    var sha256: String
    var format: String
}

struct CourseInfo: Codable, Identifiable {
    var id: String
    var title: String
    var scope: String
    var source: String
}

struct CoursePack: Codable {
    var version: Int
    var verifiedOn: String
    var courses: [CourseInfo]
    var terms: [Term]
}

enum Glossary {
    static let defaults: [Term] = [
        Term(english: "race condition", chinese: "竞态条件", explanation: "结果取决于并发操作的执行时序。", course: "Systems"),
        Term(english: "deadlock", chinese: "死锁", explanation: "任务互相等待对方释放资源，无法继续。", course: "Systems"),
        Term(english: "concurrency", chinese: "并发", explanation: "多个任务在重叠的时间段内推进。", course: "Systems"),
        Term(english: "concurrent", chinese: "并发的", explanation: "描述在重叠时间段内推进的操作。", course: "Systems"),
        Term(english: "mutual exclusion", chinese: "互斥", explanation: "同一时刻只允许一个任务访问共享资源。", course: "Systems"),
        Term(english: "critical section", chinese: "临界区", explanation: "访问共享资源、需要协调的代码片段。", course: "Systems"),
        Term(english: "semaphore", chinese: "信号量", explanation: "用于协调任务访问资源的同步机制。", course: "Systems"),
        Term(english: "latency", chinese: "延迟", explanation: "从发起操作到获得响应的时间。", course: "Systems"),
        Term(english: "throughput", chinese: "吞吐量", explanation: "单位时间内完成的工作量。", course: "Systems"),
        Term(english: "packet", chinese: "数据包", explanation: "网络中传输的数据单元。", course: "Systems"),
        Term(english: "encapsulation", chinese: "封装", explanation: "将数据与相关行为组织在一起并隐藏内部实现。", course: "Programming"),
        Term(english: "polymorphism", chinese: "多态", explanation: "相同接口可以具有不同的具体实现。", course: "Programming"),
        Term(english: "inheritance", chinese: "继承", explanation: "类型复用或扩展其他类型的行为。", course: "Programming"),
        Term(english: "recursion", chinese: "递归", explanation: "通过调用自身解决更小的子问题。", course: "Programming"),
        Term(english: "time complexity", chinese: "时间复杂度", explanation: "输入规模增长时，算法运行成本的增长方式。", course: "Programming"),
        Term(english: "data structure", chinese: "数据结构", explanation: "组织和存储数据的方式。", course: "Programming"),
        Term(english: "primary key", chinese: "主键", explanation: "唯一标识表中每一条记录的键。", course: "Database"),
        Term(english: "foreign key", chinese: "外键", explanation: "引用另一张表的键，用于建立关联。", course: "Database"),
        Term(english: "normalisation", chinese: "规范化", explanation: "组织关系表以减少冗余和更新异常。", course: "Database"),
        Term(english: "normalization", chinese: "规范化", explanation: "组织关系表以减少冗余和更新异常。", course: "Database"),
        Term(english: "transaction", chinese: "事务", explanation: "作为一个整体执行的一组数据库操作。", course: "Database"),
        Term(english: "atomicity", chinese: "原子性", explanation: "事务的操作全部完成，或全部不生效。", course: "Database"),
        Term(english: "eventual consistency", chinese: "最终一致性", explanation: "停止更新后，各副本经过一段时间最终趋于一致。", course: "Database"),
        Term(english: "functional dependency", chinese: "函数依赖", explanation: "一组属性的值决定另一组属性的值。", course: "Database"),
        Term(english: "regression", chinese: "回归分析", explanation: "用于研究变量之间关系的统计方法；此处为数据分析语境。", course: "Database"),
        Term(english: "requirements", chinese: "需求", explanation: "系统应满足的功能或约束。", course: "Software Engineering"),
        Term(english: "stakeholder", chinese: "利益相关者", explanation: "受系统影响、或能够影响系统的人或组织。", course: "Software Engineering"),
        Term(english: "cohesion", chinese: "内聚性", explanation: "模块内部各部分围绕同一职责的紧密程度。", course: "Software Engineering"),
        Term(english: "coupling", chinese: "耦合", explanation: "模块之间相互依赖的程度。", course: "Software Engineering"),
        Term(english: "trade-off", chinese: "权衡", explanation: "改善一个方面可能需要牺牲另一个方面。", course: "General"),
        Term(english: "trade off", chinese: "权衡", explanation: "改善一个方面可能需要牺牲另一个方面。", course: "General"),
        Term(english: "whereas", chinese: "而／相比之下", explanation: "连接两个存在对比的情况。", course: "General"),
        Term(english: "provided that", chinese: "前提是", explanation: "引出一个成立所需的条件。", course: "General")
    ]

    private static var patterns: [String: NSRegularExpression] = [:]
    private static let patternLock = NSLock()

    static func regex(_ english: String) -> NSRegularExpression {
        patternLock.lock(); defer { patternLock.unlock() }
        let key = english.lowercased()
        if let cached = patterns[key] { return cached }
        var parts = english.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-‐‑–—"))).filter { !$0.isEmpty }
        if parts.isEmpty { return try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: english), options: .caseInsensitive) }
        let last = parts.removeLast()
        var escaped = parts.map(NSRegularExpression.escapedPattern(for:))
        if last.lowercased().range(of: "[bcdfghjklmnpqrstvwxyz]y$", options: .regularExpression) != nil {
            escaped.append(NSRegularExpression.escapedPattern(for: String(last.dropLast())) + "(?:y|ies)")
        } else {
            escaped.append(NSRegularExpression.escapedPattern(for: last) + (last.lowercased().hasSuffix("s") ? "" : "(?:s|es)?"))
        }
        let regex = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_-])" + escaped.joined(separator: "[\\s‐‑–—-]+") + "(?![\\p{L}\\p{N}_-])", options: .caseInsensitive)
        if patterns.count > 2048 { patterns.removeAll(keepingCapacity: true) }
        patterns[key] = regex
        return regex
    }

    static func range(_ english: String, in text: String) -> NSRange? {
        regex(english).matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).last?.range
    }

    static func matches(in text: String, terms: [Term], course: String, known: Set<String>) -> [Term] {
        terms.filter { term in
            !known.contains(term.id) && !known.contains(term.english.lowercased()) &&
            (course == "All" || term.course == course || term.course == "General") && range(term.english, in: text) != nil
        }.sorted { $0.english.count > $1.english.count }
    }
}

/// Local, source-limited vocabulary detection. Context cues resolve conflicts;
/// common English words require nearby technical evidence before being hinted.
enum AutomaticTerms {
    private static let anchors: [String: [(String, Double)]] = [
        "4039": [("Python", 6), ("NumPy", 6), ("Stepper", 7), ("Gatherer", 7), ("sentinel value", 6), ("f-string", 6), ("readline", 5), ("dictionary", 3), ("while loop", 3), ("for loop", 3), ("variable", 1)],
        "4043": [("Sigma16", 8), ("Sigma 16", 8), ("assembly language", 7), ("opcode", 6), ("program counter", 6), ("register", 4), ("ALU", 6), ("CPU", 5), ("binary", 3), ("bus", 2), ("word size", 5), ("page table", 5), ("interrupt", 4), ("operating system", 5)],
        "5018P": [("dissertation", 8), ("viva", 8), ("supervisor", 6), ("project scope", 4), ("literature review", 6), ("deliverable", 3), ("MVP", 4), ("project", 1)],
        "5059": [("Scrum", 8), ("sprint", 5), ("user story", 6), ("Kanban", 8), ("agile", 3), ("coupling", 6), ("cohesion", 6), ("UML", 4), ("class diagram", 5), ("design pattern", 5), ("refactoring", 6), ("inheritance", 3), ("polymorphism", 5), ("Java", 4), ("JUnit", 6)],
        "5076": [("relational", 5), ("database", 2), ("DBMS", 4), ("SQL", 5), ("entity", 2), ("tuple", 2), ("primary key", 6), ("foreign key", 6), ("superkey", 7), ("referential integrity", 7), ("schema", 3), ("attribute", 1)],
        "5077": [("IaaS", 7), ("PaaS", 7), ("SaaS", 6), ("zero trust", 8), ("shadow IT", 8), ("legacy system", 4), ("enterprise architecture", 7), ("public cloud", 5), ("private cloud", 5), ("cloud bursting", 8), ("attack", 2), ("audit log", 4), ("perimeter", 4)]
    ]
    private static let common: Set<String> = ["class", "object", "word", "state", "pattern", "process", "thread", "function", "value", "key", "reference", "scope", "comment", "file", "range", "import", "set", "try", "with", "split", "strip", "instance", "method", "static", "address", "page", "bus", "memory", "digital", "binary", "signed", "unsigned", "fetch", "decode", "execute", "label", "branch", "jump", "client", "server", "constraint", "conceptual", "relationship", "relation", "attribute", "entity", "domain", "abstract", "boundary", "strategy", "command", "factory", "observer", "composite", "interface", "component", "dependency", "visibility", "increment", "iteration", "requirement", "evaluation", "citation", "repository", "commit"]

    private static func scores(_ text: String) -> [(String, Double)] {
        anchors.map { course, cues in
            (course, cues.reduce(0) { $0 + (Glossary.range($1.0, in: text) == nil ? 0 : $1.1) })
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }
    private static func best(_ scores: [(String, Double)]) -> String? {
        guard let first = scores.first, first.1 >= 5, first.1 - (scores.dropFirst().first?.1 ?? 0) >= 2 else { return nil }
        return first.0
    }
    static func detect(in visible: String, context: String, terms: [Term], known: Set<String>) -> [Term] {
        let globalScores = scores(String(context.suffix(1400)))
        let source = visible as NSString
        let matches = Glossary.matches(in: visible, terms: terms, course: "All", known: known)
        let groups = Dictionary(grouping: matches, by: { $0.english.lowercased().replacingOccurrences(of: "-", with: " ") })
        var chosen: [(Term, NSRange)] = []
        for group in groups.values {
            guard let first = group.first, let range = Glossary.range(first.english, in: visible) else { continue }
            let start = max(0, range.location - 150), end = min(source.length, NSMaxRange(range) + 150)
            let near = source.substring(with: NSRange(location: start, length: end - start))
            let localScores = scores(near)
            let inferred = best(localScores) ?? best(globalScores)
            let meanings = Set(group.map(\.chinese))
            let term: Term
            if let inferred, let scoped = group.first(where: { $0.course == inferred }) { term = scoped }
            else if meanings.count == 1 { term = first }
            else { continue }
            let key = term.english.lowercased()
            if common.contains(key) {
                guard (localScores.first(where: { $0.0 == term.course })?.1 ?? 0) >= 5 ||
                        (inferred == term.course && (globalScores.first(where: { $0.0 == term.course })?.1 ?? 0) >= 8) else { continue }
            }
            let lower = near.lowercased()
            let after = source.substring(from: NSMaxRange(range)).lowercased()
            if key == "class" && after.range(of: "^\\s+(?:we|you|i|today|tomorrow|students|will|is over)\\b", options: .regularExpression) != nil { continue }
            if key == "word" && lower.range(of: "bits?|bytes?|cpu|register|word size|machine", options: .regularExpression) == nil { continue }
            if key == "bit" && after.range(of: "^\\s+(?:more|less|of|harder|easier|better|different|like|about)\\b", options: .regularExpression) != nil { continue }
            if key == "key" && after.range(of: "^\\s+(?:point|idea|thing|difference|part|concept|way|question|factor)s?\\b", options: .regularExpression) != nil { continue }
            if key == "abstract" && lower.range(of: "summary|title|dissertation|paper|thesis|acknowledg|table of contents", options: .regularExpression) == nil { continue }
            if key == "page" && lower.range(of: "memory|mmu|virtual|paging|frame|page fault", options: .regularExpression) == nil { continue }
            if key == "bus" && lower.range(of: "bits?|wires?|cpu|computer|register|hardware|parallel", options: .regularExpression) == nil { continue }
            if key == "try" || key == "with" { continue }
            chosen.append((term, range))
        }
        // A longer phrase consumes its component word: candidate key beats key.
        chosen = chosen.filter { item in
            !chosen.contains { other in other.1.length > item.1.length && other.1.location <= item.1.location && NSMaxRange(other.1) >= NSMaxRange(item.1) }
        }.sorted { NSMaxRange($0.1) == NSMaxRange($1.1) ? $0.1.length > $1.1.length : NSMaxRange($0.1) > NSMaxRange($1.1) }
        var meanings: Set<String> = []
        return Array(chosen.map(\.0).filter { meanings.insert($0.chinese).inserted }.prefix(4))
    }
}

struct WordStamp: Codable, Equatable {
    let text: String
    let start: Double
    let end: Double
}

struct RecognitionEvent: Codable {
    var received: Double
    let start: Double
    let end: Double
    let text: String
    let isFinal: Bool
    let words: [WordStamp]
    var producedUptime: Double? = nil
    // The earliest word affected by a native hypothesis revision. Optional
    // so reports produced by older versions continue to decode.
    var changedFromWord: Int? = nil
    mutating func receivedAtMainQueue(_ value: Double) { received = value; producedUptime = nil }
}

struct TokenPiece: Equatable { let text: String; let time: Double }

/// Beam search can replace or remove earlier tokens. Rebuild only the word
/// containing the first changed token and its suffix, including punctuation.
struct StreamingWords {
    private var tokens: [TokenPiece] = []
    private var words: [WordStamp] = []
    private var starts: [Int] = []
    mutating func accept(_ next: [TokenPiece]) -> ([WordStamp], Int) {
        var common = 0
        while common < min(tokens.count, next.count), tokens[common] == next[common] { common += 1 }
        if common == tokens.count && common == next.count { return (words, words.count) }
        var changed = starts.lastIndex(where: { $0 <= common }) ?? 0
        // A revised token may REMOVE a word boundary: "super key" becomes
        // "superkey". Include the preceding word when the old word's first
        // token now starts with a continuation, rather than retaining a stale
        // split in the display and archive.
        if changed > 0, starts[changed] == common, common < next.count,
           !next[common].text.hasPrefix("▁"), next[common].text.first?.isWhitespace != true {
            changed -= 1
        }
        let begin = starts.isEmpty ? 0 : starts[changed]
        words = Array(words.prefix(changed)); starts = Array(starts.prefix(changed))
        var text = "", start = 0.0, end = 0.0, tokenStart = begin
        func append() {
            if !text.isEmpty { words.append(WordStamp(text: text, start: start, end: end)); starts.append(tokenStart) }
        }
        for i in begin..<next.count {
            let piece = next[i].text.replacingOccurrences(of: "▁", with: " ")
            // NeMo can emit a standalone space-prefixed comma retrospectively.
            // It is punctuation, not a new spoken word with a delivery delay.
            if !piece.contains(where: { $0.isLetter || $0.isNumber }), !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                let punctuation = piece.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { text += punctuation }
                else if let last = words.last {
                    words[words.count - 1] = WordStamp(text: last.text + punctuation, start: last.start, end: last.end)
                    changed = min(changed, words.count - 1)
                }
                continue
            }
            if piece.first?.isWhitespace == true && !text.isEmpty { append(); text = "" }
            if text.isEmpty { start = next[i].time; end = start + 0.08; tokenStart = i }
            text += piece.trimmingCharacters(in: .whitespaces)
            if piece.contains(where: { $0.isLetter || $0.isNumber }) { end = next[i].time + 0.08 }
        }
        append(); tokens = next
        return (words, changed)
    }
}

enum RecognitionVocabulary {
    static func phrases(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let text = value.replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            // Do not allow native hotword grammar or control characters into
            // a phrase. Invalid imported entries still remain in the glossary.
            guard !text.isEmpty, text.count <= 120, text.split(separator: " ").count <= 12,
                  text.contains(where: { $0.isLetter || $0.isNumber }),
                  text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " '-.+#".contains($0)) }),
                  seen.insert(text.lowercased()).inserted else { return nil }
            return text
        }.sorted { $0.lowercased() < $1.lowercased() }
    }
}

/// The causal decoder emits token timings with partial text. Measure a word
/// when its next word arrives, retaining when its full spelling first appeared.
/// No waiting for a paragraph's final correction; no clipping large samples.
struct StreamingLatencyTracker {
    private(set) var samples: [Double] = []
    private(set) var maximum = 0.0
    private(set) var overLimit = 0
    private(set) var overTwo = 0
    private(set) var sampleCount = 0
    private(set) var firstDisplayMaximum = 0.0
    private(set) var correctionMaximum = 0.0
    private(set) var corrections = 0
    private struct Seen {
        var id: Int
        var word: WordStamp
        var spelling: String
        var firstSeen: Double
        var spellingSeen: Double
        var sampled: String?
        var revised = false
    }
    private var previous: [Seen] = []
    private var nextID = 0
    mutating func accept(_ event: RecognitionEvent) -> Double? {
        let complete = event.isFinal ? event.words.count : max(0, event.words.count - 1)
        var unchanged = min(event.changedFromWord ?? 0, min(previous.count, event.words.count))
        if event.changedFromWord == nil {
            while unchanged < min(previous.count, event.words.count), previous[unchanged].word == event.words[unchanged] { unchanged += 1 }
        }
        var next = Array(previous.prefix(unchanged))
        var oldByTime: [Int: [Seen]] = [:]
        for old in previous.dropFirst(unchanged) { oldByTime[Int((old.word.start * 1000).rounded()), default: []].append(old) }
        var used: Set<Int> = []
        for (offset, word) in event.words.dropFirst(unchanged).enumerated() {
            let key = Int((word.start * 1000).rounded()), text = LatencyTracker.tokens(word.text).joined(separator: " ")
            var seen: Seen
            let index = unchanged + offset
            // Equivalent beam paths can realign timestamps long after the
            // identical word was visible. Preserve its spelling's appearance;
            // timestamp realignment is not a new word or a text correction.
            if index < previous.count, previous[index].spelling == text, !used.contains(previous[index].id) {
                seen = previous[index]
            } else if let candidate = oldByTime[key]?.first(where: { !used.contains($0.id) }) {
                seen = candidate
                if seen.spelling != text { seen.spelling = text; seen.spellingSeen = event.received; seen.revised = true }
            } else { seen = Seen(id: nextID, word: word, spelling: text, firstSeen: event.received, spellingSeen: event.received); nextID += 1 }
            used.insert(seen.id); seen.word = word
            next.append(seen)
        }
        var added: [Double] = []
        // Only the changed tail plus the previously unfinished last word can
        // need a sample. Revisions never erase already measured slow results.
        let sampleStart = min(complete, max(0, min(unchanged, previous.count - 1)))
        for i in sampleStart..<complete {
            guard next[i].sampled != next[i].spelling else { continue }
            let lag = max(0, next[i].spellingSeen - next[i].word.end)
            firstDisplayMaximum = max(firstDisplayMaximum, next[i].firstSeen - next[i].word.end)
            if next[i].revised { correctionMaximum = max(correctionMaximum, lag); corrections += 1 }
            next[i].sampled = next[i].spelling; added.append(lag)
        }
        previous = next
        for lag in added {
            sampleCount += 1
            maximum = max(maximum, lag)
            if lag > 3 { overLimit += 1 }
            if lag > 2 { overTwo += 1 }
        }
        samples.append(contentsOf: added)
        if samples.count > 10000 { samples.removeFirst(samples.count - 10000) }
        return added.max()
    }
}

struct CaptureHealth {
    enum State: Equatable { case waiting, speaking, noText, interrupted }
    private var lastBuffer = 0.0
    private var speechBegan: Double?
    private var lastSpeech = 0.0
    private var lastText = 0.0
    mutating func audio(speech: Bool, at now: Double) {
        lastBuffer = now
        if speech {
            if speechBegan == nil { speechBegan = now }
            lastSpeech = now
        } else if now - lastSpeech > 0.5 { speechBegan = nil }
    }
    mutating func text(at now: Double) { lastText = now }
    func state(at now: Double) -> State {
        if lastBuffer > 0, now - lastBuffer > 3 { return .interrupted }
        if let speechBegan, now - lastSpeech < 0.6 {
            return now - max(speechBegan, lastText) > 3 ? .noText : .speaking
        }
        return .waiting
    }
}

struct LatencyTracker {
    private(set) var samples: [Double] = []
    private var pending: [RecognitionEvent] = []
    private var finalized: Set<String> = []

    static func tokens(_ text: String) -> [String] {
        let pattern = "[\\p{L}\\p{N}]+(?:['’][\\p{L}]+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text.lowercased() as NSString
        let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
        return regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)).map {
            let token = source.substring(with: $0.range)
            // "two" -> "2" is formatting, not a late recognition correction.
            return numbers[token] ?? token
        }
    }

    /// Volatile results often attach ONE audio range to the entire sentence, not
    /// word timings. Align their text to the final word timings retrospectively.
    /// Never treat finalization time as the word's first visible time.
    mutating func accept(_ event: RecognitionEvent) -> Double? {
        pending.append(event)
        if pending.count > 2000 { pending.removeFirst(1000) }
        guard event.isFinal else { return nil }
        let key = String(format: "%.3f:%.3f", event.start, event.end)
        guard finalized.insert(key).inserted else { return nil }
        let words = event.words.flatMap { word in Self.tokens(word.text).map { (token: $0, end: word.end) } }
        guard !words.isEmpty else { return nil }
        let target = words.map(\.token)
        var firstSeen = Array(repeating: event.received, count: words.count)
        // The recognizer may move a segment's start when discarding initial
        // silence. Match overlapping audio, then restrict each token by time.
        for hypothesis in pending where hypothesis.start < event.end && hypothesis.end > event.start && hypothesis.received <= event.received {
            let source = Self.tokens(hypothesis.text)
            let n = target.count, m = source.count
            guard m > 0, n <= 400, m <= 400 else { continue }
            var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lengths[i][j] = target[i] == source[j] ? 1 + lengths[i + 1][j + 1] : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < n && j < m {
                if target[i] == source[j] {
                    if words[i].end > hypothesis.start - 0.08 && words[i].end <= hypothesis.end + 0.08 {
                        firstSeen[i] = min(firstSeen[i], hypothesis.received)
                    }
                    i += 1; j += 1
                }
                else if lengths[i + 1][j] >= lengths[i][j + 1] { i += 1 }
                else { j += 1 }
            }
        }
        let measurements = zip(words, firstSeen).map { max(0, $0.1 - $0.0.end) }
        samples.append(contentsOf: measurements)
        if samples.count > 10000 { samples.removeFirst(samples.count - 10000) }
        pending.removeAll { $0.start < event.end - 0.005 }
        return measurements.max()
    }
    var maximum: Double { samples.max() ?? 0 }
    var overLimit: Int { samples.filter { $0 > 2 }.count }
}

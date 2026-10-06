import Foundation

struct Caption: Identifiable, Equatable {
    let id: String
    let start: Double
    let end: Double
    let text: String
    let isFinal: Bool
}

/// Short on-screen lines of 12 words, rebuilt only from the revised suffix.
/// A bounded in-memory history keeps a long lecture from growing without limit.
struct CaptionHistory {
    private(set) var captions: [Caption] = []
    private var streamStart: Double?
    private var firstStreamGroup = 0
    mutating func clear() { captions = []; streamStart = nil; firstStreamGroup = 0 }
    mutating func acceptStreaming(_ event: RecognitionEvent) {
        guard !event.words.isEmpty else { clear(); return }
        let count = 12, total = (event.words.count + count - 1) / count
        let first = max(0, total - 300)
        var keep = 0
        if streamStart == event.start, first >= firstStreamGroup,
           let changed = event.changedFromWord, changed >= 0, changed <= event.words.count {
            let dropped = min(captions.count, first - firstStreamGroup)
            if dropped > 0 { captions.removeFirst(dropped) }
            // The previous last line may become complete even if its words
            // didn't change. Rebuild it as well as the revised suffix.
            keep = max(0, min(changed / count - first, min(captions.count - 1, total - first - 1)))
        }
        if keep < captions.count { captions.removeSubrange(keep...) }
        for group in (first + keep)..<total {
            let begin = group * count, end = min(begin + count, event.words.count)
            let words = event.words[begin..<end]
            captions.append(Caption(id: "stream-\(event.start)-\(group)", start: words.first!.start, end: words.last!.end,
                                    text: words.map(\.text).joined(separator: " "), isFinal: event.isFinal || group < total - 1))
        }
        streamStart = event.start; firstStreamGroup = first
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

    static func matches(in text: String, terms: [Term], known: Set<String>) -> [Term] {
        terms.filter { term in
            !known.contains(term.id) && !known.contains(term.english.lowercased()) && range(term.english, in: text) != nil
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
        let matches = Glossary.matches(in: visible, terms: terms, known: known)
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
/// Callers may pass only the tokens from `offset` onward when every earlier
/// token is known to be final, so each update costs the revisable tail only.
struct StreamingWords {
    private var tokens: [TokenPiece] = []
    private(set) var words: [WordStamp] = []
    private var starts: [Int] = []
    // The words joined by single spaces, maintained with the same suffix edits.
    private var textBytes: [UInt8] = []
    private var textEnds: [Int] = []
    var text: String { String(decoding: textBytes, as: UTF8.self) }
    var tokenCount: Int { tokens.count }

    mutating func accept(_ next: [TokenPiece], from offset: Int = 0) -> ([WordStamp], Int) {
        precondition(offset >= 0 && offset <= tokens.count, "unchanged prefix must already be known")
        let total = offset + next.count
        func piece(_ i: Int) -> TokenPiece { i < offset ? tokens[i] : next[i - offset] }
        var common = offset
        while common < min(tokens.count, total), tokens[common] == next[common - offset] { common += 1 }
        if common == tokens.count && common == total { return (words, words.count) }
        var changed = starts.lastIndex(where: { $0 <= common }) ?? 0
        // A revised token may REMOVE a word boundary: "super key" becomes
        // "superkey". Include the preceding word when the old word's first
        // token now starts with a continuation, rather than retaining a stale
        // split in the display and archive.
        if changed > 0, starts[changed] == common, common < total,
           !piece(common).text.hasPrefix("▁"), piece(common).text.first?.isWhitespace != true {
            changed -= 1
        }
        let begin = starts.isEmpty ? 0 : starts[changed]
        words.removeSubrange(changed...); starts.removeSubrange(changed...)
        var text = "", start = 0.0, end = 0.0, tokenStart = begin
        func append() {
            if !text.isEmpty { words.append(WordStamp(text: text, start: start, end: end)); starts.append(tokenStart) }
        }
        for i in begin..<total {
            let token = piece(i)
            let fragment = token.text.replacingOccurrences(of: "▁", with: " ")
            // NeMo can emit a standalone space-prefixed comma retrospectively.
            // It is punctuation, not a new spoken word with a delivery delay.
            if !fragment.contains(where: { $0.isLetter || $0.isNumber }), !fragment.trimmingCharacters(in: .whitespaces).isEmpty {
                let punctuation = fragment.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { text += punctuation }
                else if let last = words.last {
                    words[words.count - 1] = WordStamp(text: last.text + punctuation, start: last.start, end: last.end)
                    changed = min(changed, words.count - 1)
                }
                continue
            }
            if fragment.first?.isWhitespace == true && !text.isEmpty { append(); text = "" }
            if text.isEmpty { start = token.time; end = start + 0.08; tokenStart = i }
            text += fragment.trimmingCharacters(in: .whitespaces)
            if fragment.contains(where: { $0.isLetter || $0.isNumber }) { end = token.time + 0.08 }
        }
        append()
        tokens.removeSubrange(offset...); tokens.append(contentsOf: next)
        let kept = min(changed, textEnds.count)
        textBytes.removeSubrange((kept == 0 ? 0 : textEnds[kept - 1])...); textEnds.removeSubrange(kept...)
        for word in words[kept...] {
            if !textBytes.isEmpty { textBytes.append(0x20) }
            textBytes.append(contentsOf: word.text.utf8); textEnds.append(textBytes.count)
        }
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
        var tail: [Seen] = []
        tail.reserveCapacity(event.words.count - unchanged)
        var oldByTime: [Int: [Seen]] = [:]
        for old in previous.dropFirst(unchanged) { oldByTime[Int((old.word.start * 1000).rounded()), default: []].append(old) }
        var used: Set<Int> = []
        for (offset, word) in event.words.dropFirst(unchanged).enumerated() {
            let key = Int((word.start * 1000).rounded()), text = LexicalTokens.of(word.text).joined(separator: " ")
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
            tail.append(seen)
        }
        let previousCount = previous.count
        // Reconcile using the old suffix first, then replace only that suffix.
        // Keeping the unchanged prefix avoids copying every old measurement
        // on each new word during a long lecture.
        previous.replaceSubrange(unchanged..., with: tail)
        var added: [Double] = []
        // Only the changed tail plus the previously unfinished last word can
        // need a sample. Revisions never erase already measured slow results.
        let sampleStart = min(complete, max(0, min(unchanged, previousCount - 1)))
        for i in sampleStart..<complete {
            guard previous[i].sampled != previous[i].spelling else { continue }
            let lag = max(0, previous[i].spellingSeen - previous[i].word.end)
            firstDisplayMaximum = max(firstDisplayMaximum, previous[i].firstSeen - previous[i].word.end)
            if previous[i].revised { correctionMaximum = max(correctionMaximum, lag); corrections += 1 }
            previous[i].sampled = previous[i].spelling; added.append(lag)
        }
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

enum LexicalTokens {
    private static let wordPattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}]+)?")
    private static let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]

    static func of(_ text: String) -> [String] {
        let source = text.lowercased() as NSString
        return wordPattern.matches(in: source as String, range: NSRange(location: 0, length: source.length)).map {
            let token = source.substring(with: $0.range)
            // "two" -> "2" is formatting, not a late recognition correction.
            return numbers[token] ?? token
        }
    }
}

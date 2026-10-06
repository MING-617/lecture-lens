import Foundation

/// Append complete words to a local document independently of the 300-line UI.
/// The final unfinished word is committed when the session finishes.
final class TranscriptArchive: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.ming.lecturelens.transcript", qos: .utility)
    private let handle: FileHandle
    private var committed: [WordStamp] = []
    private var offsets: [UInt64] = []
    private var failed: Error?
    private var closed = false
    private var lastSync = ProcessInfo.processInfo.systemUptime
    var onError: (@Sendable (Error) -> Void)?

    init(directory: URL, date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd HH-mm-ss"
        url = directory.appendingPathComponent("\(format.string(from: date))-\(UUID().uuidString.prefix(6)).txt")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        let title = "Lecture Lens · English captions\nStarted: \(ISO8601DateFormatter().string(from: date))\nAutomatic transcription may contain errors. No audio is stored.\n\n"
        try handle.write(contentsOf: Data(title.utf8))
        try handle.synchronize()
    }
    deinit { try? handle.close() }

    // Called serially by the main actor; only file operations run on the queue.
    func accept(_ event: RecognitionEvent) {
        let complete = event.isFinal ? event.words.count : max(0, event.words.count - 1)
        queue.async { [self] in
            guard !closed, failed == nil else { return }
            do {
                var common = min(event.changedFromWord ?? 0, min(complete, committed.count))
                if event.changedFromWord == nil {
                    while common < min(complete, committed.count), committed[common] == event.words[common] { common += 1 }
                }
                if common < committed.count {
                    try handle.truncate(atOffset: offsets[common]); try handle.seek(toOffset: offsets[common])
                    committed.removeSubrange(common...); offsets.removeSubrange(common...)
                }
                for i in common..<complete {
                    let word = event.words[i]
                    offsets.append(try handle.offset())
                    var text = ""
                    if i % 12 == 0 {
                        if i > 0 { text += "\n" }
                        text += String(format: "[%02d:%02d] ", Int(word.start) / 60, Int(word.start) % 60)
                    }
                    text += word.text + " "
                    try handle.write(contentsOf: Data(text.utf8)); committed.append(word)
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastSync >= 5 { try handle.synchronize(); lastSync = now }
            } catch { record(error) }
        }
    }
    private func record(_ error: Error) {
        if failed == nil { failed = error; onError?(error) }
    }
    func finish(reason: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if closed { if let failed { continuation.resume(throwing: failed) } else { continuation.resume() }; return }
                do {
                    if let failed { throw failed }
                    try handle.write(contentsOf: Data("\n\nEnded: \(ISO8601DateFormatter().string(from: Date())) · \(reason)\n".utf8))
                    try handle.synchronize()
                    try handle.close(); closed = true
                    continuation.resume()
                } catch { record(error); try? handle.close(); closed = true; continuation.resume(throwing: error) }
            }
        }
    }
    func export(to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if !closed { try handle.synchronize() }
                    if let failed { throw failed }
                    if destination.standardizedFileURL != url.standardizedFileURL {
                        try Data(contentsOf: url).write(to: destination, options: .atomic)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

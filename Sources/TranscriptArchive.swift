import Foundation

/// Append complete words to a local document independently of the 300-line UI.
/// The final unfinished word is committed when the session finishes.
///
/// With a staging folder, the file is written there while recording and moved
/// to `destination` when the session finishes. A synced Documents folder then
/// uploads one finished file instead of re-uploading it every few seconds.
final class TranscriptArchive: @unchecked Sendable {
    /// Where the file is written while the session is running.
    let url: URL
    /// Where the finished file belongs.
    let destination: URL
    private var location: URL
    private let queue = DispatchQueue(label: "com.ming.lecturelens.transcript", qos: .utility)
    private let handle: FileHandle
    private var committed: [WordStamp] = []
    private var offsets: [UInt64] = []
    private var failed: Error?
    private var closed = false
    private var lastSync = ProcessInfo.processInfo.systemUptime
    var onError: (@Sendable (Error) -> Void)?

    init(directory: URL, staging: URL? = nil, date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let staging { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let name = "\(format.string(from: date))-\(UUID().uuidString.prefix(6)).txt"
        destination = directory.appendingPathComponent(name)
        url = (staging ?? directory).appendingPathComponent(name)
        location = url
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
    /// Close the file and move it to `destination`. Returns where it now is.
    @discardableResult func finish(reason: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                if closed { if let failed { continuation.resume(throwing: failed) } else { continuation.resume(returning: location) }; return }
                do {
                    if let failed { throw failed }
                    try handle.write(contentsOf: Data("\n\nEnded: \(ISO8601DateFormatter().string(from: Date())) · \(reason)\n".utf8))
                    try handle.synchronize()
                    try handle.close(); closed = true
                } catch { record(error); try? handle.close(); closed = true; continuation.resume(throwing: error); return }
                do {
                    // A failed move leaves the complete file in staging; the
                    // next start moves it again.
                    if location != destination { try FileManager.default.moveItem(at: location, to: destination); location = destination }
                    continuation.resume(returning: location)
                } catch {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "字幕已完整保存在 \(location.path)，但未能移到字幕文件夹：\(error.localizedDescription)"]))
                }
            }
        }
    }
    /// Move transcripts left in staging by an unexpected exit to `directory`.
    static func recover(staging: URL, into directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil),
              !files.isEmpty, (try? manager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        for file in files where file.pathExtension == "txt" {
            if let text = try? String(contentsOf: file, encoding: .utf8), !text.contains("\n\nEnded: "),
               let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data("\n\nEnded: Lecture Lens closed unexpectedly; recovered on next launch.\n".utf8))
                try? handle.close()
            }
            try? manager.moveItem(at: file, to: directory.appendingPathComponent(file.lastPathComponent))
        }
    }
    func export(to target: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if !closed { try handle.synchronize() }
                    if let failed { throw failed }
                    if target.standardizedFileURL != location.standardizedFileURL {
                        try Data(contentsOf: location).write(to: target, options: .atomic)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

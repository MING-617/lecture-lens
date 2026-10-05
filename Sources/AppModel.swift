import SwiftUI
import AppKit
import AVFoundation
import CoreAudio

@MainActor final class AppModel: ObservableObject {
    @Published var history = CaptionHistory()
    @Published var frozen: [Caption]?
    @Published var status = "准备好后，点击开始"
    @Published var error: String?
    @Published var running = false
    @Published var preparing = false
    @Published var stopping = false
    @Published var meter = 0.0
    @Published var latency: Double?
    // Caption/latency publications already refresh the UI on every result.
    // Publishing this large internal value too would copy its old word array
    // through the property wrapper before each in-place suffix update.
    private(set) var tracker = StreamingLatencyTracker()
    @Published var maximumQueueWait = 0.0
    @Published var maximumDecodeTime = 0.0
    @Published var stalled = false
    @Published var devices = InputDevice.list()
    @Published var device: UInt32 = InputDevice.recommended()
    @Published var locale = "en-GB"
    @Published var fontSize = 30.0
    @Published var chineseHints = true
    @Published var floatWindow = false
    @Published var compact = false
    @Published var enhanceTerms = true
    @Published var enhancementActive = false
    @Published var enhancementNotice: String?
    @Published var terms: [Term] = []
    @Published var courseInfo: [CourseInfo] = []
    @Published var known: Set<String> = []
    @Published var showGlossary = false
    @Published var showHelp = false
    @Published var detailTerm: Term?
    @Published var showStopConfirmation = false
    @Published var savedURL: URL?
    @Published var saveFailed = false
    enum StopAction { case session, close, quit }
    weak var window: NSWindow?
    private var pendingRequest: StopAction?
    private var archive: TranscriptArchive?
    private var lastEvent: RecognitionEvent?
    private var generation = UUID()
    private var health = CaptureHealth()
    private var observers: [NSObjectProtocol] = []
    private let transcriptDirectory: URL
    private let makeSession: @MainActor () -> SpeechSession
    private var session: SpeechSession?
    private var startTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var lastMeterPublish = 0.0
    private var currentAudioEnd = 0.0
    private var hintCache: (text: String, context: String, values: [Term])?
    private let preferenceURL: URL
    private struct Preferences: Codable { var terms: [Term]; var known: Set<String>; var version: Int? = 5; var enhanceTerms: Bool? = nil }

    init(transcriptDirectory: URL? = nil, preferenceURL: URL? = nil, makeSession: @escaping @MainActor () -> SpeechSession = { SpeechSession() }) {
        self.preferenceURL = preferenceURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LectureLens/preferences.json")
        self.transcriptDirectory = transcriptDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Lecture Lens 字幕", isDirectory: true)
        self.makeSession = makeSession
        if let url = Bundle.main.url(forResource: "coursepack", withExtension: "json"),
           let data = try? Data(contentsOf: url), let pack = try? JSONDecoder().decode(CoursePack.self, from: data) {
            terms = pack.terms; courseInfo = pack.courses
        }
        if let data = try? Data(contentsOf: self.preferenceURL), let value = try? JSONDecoder().decode(Preferences.self, from: data) {
            // Preserve user edits/imports while hiding exact old demonstration entries.
            let saved = value.terms.filter { term in
                !(term.source ?? "").hasPrefix("课件核对：") &&
                ((value.version ?? 1) >= 2 || !Glossary.defaults.contains { $0.english == term.english && $0.chinese == term.chinese && $0.explanation == term.explanation && $0.course == term.course })
            }
            for term in saved { terms.removeAll { $0.id == term.id }; terms.append(term) }
            known = value.known
            enhanceTerms = value.enhanceTerms ?? true
        }
    }
    var hasActiveSession: Bool { running || preparing || stopping }
    func observeSystem() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupt("系统即将睡眠，字幕已停止；唤醒后点击开始即可继续。") }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        })
    }
    func refreshDevices() {
        devices = InputDevice.list()
        if !hasActiveSession, device != 0, !devices.contains(where: { $0.id == device }) { device = InputDevice.recommended() }
    }
    var displayed: [Caption] { frozen ?? history.captions }
    func toggleCompact() { compact.toggle(); if compact { frozen = nil } }
    func setEnhancement(_ value: Bool) { guard !hasActiveSession else { return }; enhanceTerms = value; savePreferences() }
    var suggestions: [Term] {
        guard chineseHints else { return [] }
        let recent = displayed.filter { !running || frozen != nil || $0.end >= currentAudioEnd - 15 }
        let text = String(recent.suffix(2).map(\.text).joined(separator: " ").suffix(450))
        let context = String(displayed.suffix(6).map(\.text).joined(separator: " ").suffix(1400))
        if let cached = hintCache, cached.text == text && cached.context == context { return cached.values }
        let values = AutomaticTerms.detect(in: text, context: context, terms: terms, known: known)
        hintCache = (text, context, values)
        return values
    }
    func courseTitle(_ code: String) -> String { courseInfo.first { $0.id == code }?.title ?? (code == "General" ? "自备通用词表" : code) }

    func start() {
        guard !hasActiveSession else { return }
        generation = UUID(); let token = generation
        history.clear(); frozen = nil; tracker = StreamingLatencyTracker(); latency = nil
        maximumQueueWait = 0; maximumDecodeTime = 0
        stalled = false; error = nil; preparing = true; saveFailed = false
        currentAudioEnd = 0; hintCache = nil; lastEvent = nil; health = CaptureHealth(); archive = nil
        lastMeterPublish = 0; savedURL = nil
        enhancementActive = false; enhancementNotice = nil
        status = "正在准备麦克风和本地字幕文件…"
        let session = makeSession(); self.session = session
        let vocabulary = enhanceTerms ? RecognitionVocabulary.phrases(terms.map(\.english)) : []
        if enhanceTerms && vocabulary.isEmpty { enhancementNotice = "未找到可用的专业词表，正在使用普通英文识别。" }
        if let settings = Bundle.main.url(forResource: "recognition-settings", withExtension: "json"),
           let data = try? Data(contentsOf: settings), let value = try? JSONDecoder().decode(EnhancementSettings.self, from: data) {
            session.enhancementPaths = value.paths; session.enhancementScore = value.score
        }
        session.onEnhancement = { [weak self] active, note in
            guard let self, self.generation == token else { return }
            self.enhancementActive = active
            if let note { self.enhancementNotice = note }
        }
        session.onStatus = { [weak self] message in guard let self, self.generation == token, !self.stopping else { return }; self.status = message }
        session.onResult = { [weak self] event in
            guard let self, self.generation == token, self.session != nil else { return }
            self.history.acceptStreaming(event); self.archive?.accept(event); self.lastEvent = event
            self.health.text(at: ProcessInfo.processInfo.systemUptime)
            if let lag = self.tracker.accept(event) { self.latency = lag }
            self.stalled = false
            if !self.stopping { self.status = "正在听 · 英文实时字幕" }
        }
        session.onLevel = { [weak self] rms, audioEnd, _ in
            guard let self, self.generation == token, !self.stopping else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // Caption delivery stays immediate; only the strength indicator
            // and hint-expiry clock need this slower refresh.
            if now - self.lastMeterPublish > 0.25 { self.currentAudioEnd = audioEnd; self.meter = min(1, rms * 12); self.lastMeterPublish = now }
        }
        session.onVoice = { [weak self] detected in
            guard let self, self.generation == token, !self.stopping else { return }
            self.health.audio(speech: detected, at: ProcessInfo.processInfo.systemUptime)
        }
        session.onError = { [weak self] error in
            guard let self, self.generation == token, !self.stopping else { return }
            self.interrupt(error.localizedDescription)
        }
        session.onPerformance = { [weak self] wait, decode in
            guard let self, self.generation == token else { return }
            if wait > self.maximumQueueWait { self.maximumQueueWait = wait }
            if decode > self.maximumDecodeTime { self.maximumDecodeTime = decode }
        }
        startTask = Task {
            do {
                let archive = try TranscriptArchive(directory: transcriptDirectory)
                self.archive = archive; savedURL = archive.url
                archive.onError = { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        self.saveFailed = true; self.error = "字幕自动保存失败：" + error.localizedDescription
                    }
                }
                try await session.startMicrophone(device: device, localeID: locale, contextualTerms: vocabulary)
                try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
                preparing = false; running = true; health.audio(speech: false, at: ProcessInfo.processInfo.systemUptime); status = "正在听 · 等待老师讲话"
                watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkDelay() }
                }
            } catch {
                await session.cancel()
                guard generation == token, !stopping else { return }
                if let archive { try? await archive.finish(reason: "未开始：" + error.localizedDescription) }
                self.session = nil; preparing = false; running = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
                status = "未开始 · 可以调整后重试"
            }
        }
    }
    private func checkDelay() {
        guard running else { return }
        let next: (stalled: Bool, status: String)
        switch health.state(at: ProcessInfo.processInfo.systemUptime) {
        case .interrupted: interrupt("麦克风超过 3 秒没有输入，本次字幕已停止。请检查麦克风后重新开始。"); return
        case .noText: next = (true, "检测到人声，但超过 3 秒没有新字幕 · 请检查收音")
        case .waiting: next = (false, "正在听 · 等待英文讲话")
        case .speaking: next = (false, "正在听 · 英文实时字幕")
        }
        // @Published emits even when an assignment repeats the same value.
        if stalled != next.stalled { stalled = next.stalled }
        if status != next.status { status = next.status }
    }
    func requestStop(after action: StopAction = .session) {
        guard hasActiveSession else { perform(action); return }
        guard !stopping, pendingRequest == nil else { return }
        pendingRequest = action
        if showHelp || showGlossary || detailTerm != nil {
            showHelp = false; showGlossary = false; detailTerm = nil
        } else { presentPendingStop() }
    }
    func presentPendingStop() {
        guard pendingRequest != nil, hasActiveSession, !stopping else { return }
        showStopConfirmation = true
    }
    func cancelStop() { pendingRequest = nil; showStopConfirmation = false }
    func confirmStop() {
        guard let action = pendingRequest else { return }
        pendingRequest = nil; showStopConfirmation = false
        stop(after: action)
    }
    func interrupt(_ message: String) {
        guard hasActiveSession, !stopping else { return }
        error = message; cancelStop(); stop(cancel: true, reason: message)
    }
    private func stop(cancel: Bool = false, reason: String = "用户停止", after action: StopAction = .session) {
        guard (running || preparing), !stopping else { return }
        let token = generation, wasPreparing = preparing, startup = startTask, ending = session
        startup?.cancel(); startTask = nil
        // Shut down the actual input synchronously, before waiting for any task.
        ending?.haltCapture()
        watchdog?.invalidate(); watchdog = nil
        running = false; preparing = false; stopping = true; status = "正在停止并保存字幕…"
        Task {
            await startup?.value
            if cancel || wasPreparing { await ending?.cancel() } else { await ending?.finish() }
            guard generation == token else { return }
            if let event = lastEvent {
                archive?.accept(RecognitionEvent(received: event.received, start: event.start, end: event.end, text: event.text, isFinal: true, words: event.words))
            }
            do { try await archive?.finish(reason: reason) } catch { saveFailed = true; self.error = "字幕保存失败：" + error.localizedDescription }
            // Invalidate every old callback before permitting a new session.
            generation = UUID(); session = nil; stopping = false; meter = 0; stalled = false; refreshDevices()
            status = saveFailed ? "已停止 · 字幕保存发生错误" : "已停止 · 完整字幕已保存在本地"
            if !saveFailed { perform(action) }
        }
    }
    private func perform(_ action: StopAction) {
        switch action {
        case .session: break
        case .close: window?.performClose(nil)
        case .quit: NSApplication.shared.terminate(nil)
        }
    }

    func toggleReview() { frozen = frozen == nil ? history.captions : nil }
    func markKnown(_ term: Term) {
        for alias in terms where alias.chinese == term.chinese { known.insert(alias.id) }
        savePreferences()
    }
    func forgetKnown() { known = []; savePreferences() }
    func addTerm(english: String, chinese: String, explanation: String, course: String, source: String) {
        let term = Term(english: english.trimmingCharacters(in: .whitespacesAndNewlines), chinese: chinese.trimmingCharacters(in: .whitespacesAndNewlines), explanation: explanation, course: course, source: source.isEmpty ? "手动添加，未提供课程材料出处" : source)
        guard !term.english.isEmpty, !term.chinese.isEmpty else { return }
        terms.removeAll { $0.id == term.id }; terms.append(term); savePreferences()
    }
    func importTerms() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.tabSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            var imported: [Term] = []
            for (index, line) in lines.enumerated() {
                let fields = line.components(separatedBy: "\t")
                guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                    throw NSError(domain: "Glossary", code: 1, userInfo: [NSLocalizedDescriptionKey: "第 \(index + 1) 行格式不正确。请用 Tab 分隔英文和中文。"])
                }
                imported.append(Term(english: fields[0], chinese: fields[1], explanation: fields.count > 2 ? fields[2] : "", course: fields.count > 3 && !fields[3].isEmpty ? fields[3] : "General", source: fields.count > 4 && !fields[4].isEmpty ? fields[4] : "导入文件：\(url.lastPathComponent)，课程适用性尚未核对"))
            }
            for term in imported { terms.removeAll { $0.id == term.id }; terms.append(term) }
            savePreferences()
        } catch { self.error = error.localizedDescription }
    }
    func exportCaptions() {
        guard let archive else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = archive.url.lastPathComponent; panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await archive.export(to: url) } catch { self?.error = error.localizedDescription }
            }
        }
    }
    func revealTranscript() {
        if let savedURL { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
    }
    private func savePreferences() {
        hintCache = nil
        do {
            try FileManager.default.createDirectory(at: preferenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let custom = terms.filter { !($0.source ?? "").hasPrefix("课件核对：") }
            let data = try JSONEncoder().encode(Preferences(terms: custom, known: known, enhanceTerms: enhanceTerms))
            try data.write(to: preferenceURL, options: .atomic)
        } catch { self.error = "无法保存术语设置：\(error.localizedDescription)" }
    }
}

struct EnhancementSettings: Codable { var paths: Int; var score: Float }

import SwiftUI
import AppKit

private let accent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.47, green: 0.79, blue: 0.70, alpha: 1)
        : NSColor(srgbRed: 0.16, green: 0.36, blue: 0.31, alpha: 1)
})

struct LensView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        // Term detection runs at most once per refresh.
        let suggestions = model.suggestions
        VStack(spacing: 0) {
            if model.compact { compactContent(suggestions) } else {
            header
            Divider()
            controls.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(14).background(Color.orange.opacity(0.09))
            }
            captions
            if !suggestions.isEmpty { hints(suggestions) }
            Divider()
            footer
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .frame(minWidth: model.compact ? 360 : 700, minHeight: model.compact ? 160 : 500)
        .sheet(isPresented: $model.showGlossary, onDismiss: model.presentPendingStop) { GlossaryView().environmentObject(model) }
        .sheet(item: $model.detailTerm, onDismiss: model.presentPendingStop) { TermDetail(term: $0, courseTitle: model.courseTitle($0.course)) }
        .sheet(isPresented: $model.showHelp, onDismiss: model.presentPendingStop) {
            VStack(alignment: .leading, spacing: 18) {
                Text("使用 Lecture Lens").font(.title2.bold())
                Text("1. 直接点击“开始”，无需选择课程或章节。\n2. 英文逐步出现，文字仍可能修正；专业词增强自动使用词表，中文开关只控制解释。\n3. 软件自动识别已有课程词表中的专业词，结合上下文显示中文提示；不确定的词义先不提示。\n4. “回看”只暂停画面；“回到实时”可追赶。\n5. “悬浮字幕”切换小窗口并置顶，不停止收音；“返回主界面”恢复原窗口。\n6. 点击术语旁的 ⓘ 看解释、来源与页码；“术语表”可搜索词条。\n7. 点击“停止”后，再点击“确认停止”；按回车默认继续听课。")
                    .lineSpacing(8)
                Text("字幕采用持续流式识别，最新词逐步补齐，前面的词不会等待长句最终校正。延迟根据模型词片时间戳估计，界面不截断超时读数。目标是持续跟上、控制在 2–3 秒以内；准确率和教室收音仍需现场检查。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("英文模型已内置，音频在本地处理，不写入录音文件；完整英文字幕按每次开始自动保存到“文稿 / Lecture Lens 字幕”。不录制音频。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("明白了") { model.showHelp = false }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 540)
        }
        .background(WindowAccessor(floating: model.floatWindow, compact: model.compact, model: model))
        .onAppear { model.observeSystem() }
        .alert("是否停止本次字幕？", isPresented: $model.showStopConfirmation) {
            Button("继续听课", role: .cancel) { model.cancelStop() }.keyboardShortcut(.defaultAction)
            Button("确认停止", role: .destructive) { model.confirmStop() }
        } message: {
            Text("确认后会停止收音并保存本次完整字幕。")
        }
    }

    private func compactContent(_ suggestions: [Term]) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("返回主界面", systemImage: "arrow.up.left.and.arrow.down.right") { model.toggleCompact() }
                WindowDragHandle().frame(maxWidth: .infinity).frame(height: 24).help("拖动悬浮窗口")
                Button { model.fontSize = max(20, model.fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }.help("缩小字幕")
                Button { model.fontSize = min(54, model.fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }.help("放大字幕")
                Button(model.running || model.preparing ? "停止" : "开始") {
                    if model.running || model.preparing { model.requestStop() } else { model.start() }
                }.buttonStyle(.borderedProminent).disabled(model.stopping).keyboardShortcut("r", modifiers: [.command])
            }.font(.caption)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.history.captions.isEmpty {
                            Text(model.running ? "等待英文讲话…" : "点击“开始”即可听课").foregroundStyle(.secondary).padding(.vertical, 16)
                        } else {
                            ForEach(model.history.captions.suffix(2)) { caption in
                                Text(caption.text).foregroundStyle(caption.isFinal ? Color.primary : Color.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("compact-bottom")
                    }.font(.system(size: model.fontSize)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onChange(of: model.history.captions) { _, _ in proxy.scrollTo("compact-bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("compact-bottom", anchor: .bottom) }
            }
            if !suggestions.isEmpty {
                Text(suggestions.prefix(2).map { $0.english + "：" + $0.chinese }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Color(nsColor: .systemGreen)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(model.error ?? model.enhancementNotice ?? model.status).lineLimit(2)
                    .foregroundStyle(model.error != nil || model.enhancementNotice != nil || model.stalled ? Color.orange : Color.secondary)
                Spacer()
                if let delay = model.latency { Text(String(format: "≈ %.1f 秒", delay)).foregroundStyle(delay > 3 ? Color.orange : Color.secondary) }
            }.font(.caption)
        }.padding(12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "captions.bubble.fill").font(.system(size: 27)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Lecture Lens").font(.system(size: 21, weight: .semibold))
                Text("听英文 · 看英文").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label("本地处理", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            Button { model.showHelp = true } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.plain).help("使用说明")
        }.padding(.horizontal, 24).padding(.vertical, 19)
    }
    private var controls: some View {
        HStack(spacing: 14) {
            Picker("麦克风", selection: $model.device) {
                Text("系统默认麦克风").tag(UInt32(0))
                ForEach(model.devices) { Text($0.name).tag($0.id) }
            }.labelsHidden().frame(maxWidth: 220).disabled(model.running || model.preparing || model.stopping)
            Text("English · 实时").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if model.preparing || model.stopping { ProgressView().controlSize(.small) }
            Button {
                if model.running || model.preparing { model.requestStop() } else { model.start() }
            } label: {
                Label(model.running || model.preparing ? "停止" : "开始", systemImage: model.running || model.preparing ? "stop.fill" : "mic.fill")
                    .frame(minWidth: 95)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.stopping)
                .keyboardShortcut("r", modifiers: [.command])
        }
    }
    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.displayed.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: model.running ? "waveform" : "text.bubble").font(.system(size: 43, weight: .light)).foregroundStyle(accent.opacity(0.7))
                        Text(model.running ? "等待英文讲话…" : "让老师的英文，出现在这里。")
                            .font(.system(size: 26, weight: .medium))
                        Text(model.running ? "确保麦克风能够清楚收到声音" : "英文实时字幕为主，中文只提示遇到的术语")
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 90)
                } else {
                    LazyVStack(alignment: .leading, spacing: 25) {
                        ForEach(model.displayed) { caption in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 8) {
                                    Text(String(format: "%02d:%02d", Int(caption.start) / 60, Int(caption.start) % 60))
                                    if !caption.isFinal { Text("识别中") }
                                }.font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(caption.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.system(size: model.fontSize, weight: .regular))
                                    .foregroundStyle(caption.isFinal ? Color.primary : Color.secondary)
                                    .lineSpacing(8).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.id(caption.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 30).padding(.vertical, 26)
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onChange(of: model.history.captions) { _, _ in
                if model.frozen == nil { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { if model.frozen == nil { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.frozen == nil) { _, live in if live { proxy.scrollTo("bottom", anchor: .bottom) } }
            .overlay(alignment: .topTrailing) {
                if model.frozen != nil {
                    Label("回看中 · 后台仍在识别", systemImage: "pause.circle.fill")
                        .font(.caption).padding(9).background(.regularMaterial, in: Capsule()).padding(12)
                }
            }
        }
    }
    private func hints(_ suggestions: [Term]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自动术语提示 · 点击 ⓘ 查看解释和课件出处").font(.caption).foregroundStyle(.secondary)
            ForEach(suggestions) { term in
                HStack(alignment: .top, spacing: 10) {
                    Text(term.english).font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
                    Text(term.chinese).font(.system(size: 15))
                    Spacer()
                    Button { model.detailTerm = term } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("查看 \(term.english) 的解释和课件出处")
                    Button { model.markKnown(term) } label: { Image(systemName: "checkmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("已掌握，以后少提示")
                }.help(term.explanation + "\n出处：" + (term.source ?? "未提供课程材料出处"))
            }
        }.padding(.horizontal, 24).padding(.vertical, 14).background(accent.opacity(0.055))
    }
    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Circle().fill(model.running ? accent : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                Text(model.enhancementNotice ?? model.status).font(.caption).foregroundStyle(model.stalled || model.enhancementNotice != nil ? .orange : .secondary).lineLimit(1)
                if model.running { Text(model.enhancementActive ? "专业词增强" : "普通识别").font(.caption).foregroundStyle(.secondary) }
                MeterBar(meter: model.meter).frame(width: 60, height: 5).help("麦克风声音强度")
                Spacer()
                if let delay = model.latency {
                    Text(String(format: "最新词延迟 ≈ %.1f 秒", delay)).font(.caption.monospacedDigit())
                        .foregroundStyle(delay > 3 || model.stalled ? Color.orange : Color.secondary)
                        .help(String(format: "首次出现最大 %.2f 秒；修订后拼写最大 %.2f 秒；本次估计最大 %.2f 秒；超过 3 秒：%d 次。采集／排队最大 %.2f 秒，单次处理最大 %.2f 秒。使用词片时间戳估计，遗漏不计入；不截断超时值。", model.tracker.firstDisplayMaximum, model.tracker.correctionMaximum, model.tracker.maximum, model.tracker.overLimit, model.maximumQueueWait, model.maximumDecodeTime))
                } else { Text("目标 ≤ 3 秒 · 尚未测量").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 16) {
                Button(model.frozen == nil ? "回看" : "回到实时", systemImage: model.frozen == nil ? "pause" : "forward.end") { model.toggleReview() }
                    .disabled(model.history.captions.isEmpty).keyboardShortcut(.space, modifiers: [.command])
                Toggle("中文术语", isOn: $model.chineseHints).toggleStyle(.checkbox).disabled(model.terms.isEmpty).help("自动识别课程专业词汇，无需选课；关闭后只显示英文字幕")
                Button("术语表") { model.showGlossary = true }
                Button("悬浮字幕", systemImage: "rectangle.compress.vertical") { model.toggleCompact() }
                Spacer()
                Button { model.fontSize = max(20, model.fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }.help("缩小字幕")
                Button { model.fontSize = min(54, model.fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }.help("放大字幕")
                Toggle("窗口置顶", isOn: $model.floatWindow).toggleStyle(.checkbox).help("让字幕窗口留在其他普通窗口前面，方便同时查看课件")
                Button(model.saveFailed ? "保存异常" : "字幕文件") { model.revealTranscript() }.disabled(model.savedURL == nil).help(model.savedURL?.path ?? "开始后自动创建完整字幕文件")
                Button("导出字幕") { model.exportCaptions() }.disabled(model.savedURL == nil || model.stopping).help("导出本次完整英文字幕")
            }.font(.caption).buttonStyle(.borderless)
        }.padding(.horizontal, 24).padding(.vertical, 15)
    }
}

private struct MeterBar: View {
    @ObservedObject var meter: MeterModel
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(accent.opacity(0.13))
                .overlay(alignment: .leading) { Capsule().fill(accent).frame(width: max(2, geometry.size.width * meter.level)) }
        }
    }
}

struct GlossaryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var english = ""
    @State private var chinese = ""
    @State private var explanation = ""
    @State private var termCourse = ""
    @State private var source = ""
    @State private var search = ""
    @State private var detailTerm: Term?
    private var filtered: [Term] {
        model.terms.filter { search.isEmpty || ($0.english + " " + $0.chinese + " " + model.courseTitle($0.course)).localizedCaseInsensitiveContains(search) }
            .sorted { $0.english.localizedCaseInsensitiveCompare($1.english) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("课程术语").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            Text("已整理桌面 Moodle 资料中 6 门课的 55 份课件。字幕会自动匹配专业词和上下文，无需选课。中文是辅助解释，未上传的新课件和词条不会自动加入。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("专业词增强", isOn: Binding(get: { model.enhanceTerms }, set: model.setEnhancement))
                .disabled(model.hasActiveSession).help("自动用英文课程词表帮助识别；停止后可调整，下次开始生效。中文术语开关不影响英文识别。")
            TextField("搜索英文、中文或课程名（\(model.terms.count) 个词条／词义）", text: $search)
            HStack { TextField("英文词或词组", text: $english); TextField("中文释义", text: $chinese) }
            TextField("简短解释（可选）", text: $explanation)
            HStack { TextField("课程名（留空为通用）", text: $termCourse); TextField("出处，例如课件名／页码", text: $source) }
            HStack {
                Button("添加词条") {
                    model.addTerm(english: english, chinese: chinese, explanation: explanation, course: termCourse.isEmpty ? "General" : termCourse, source: source)
                    english = ""; chinese = ""; explanation = ""
                }.disabled(english.trimmingCharacters(in: .whitespaces).isEmpty || chinese.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("导入 TSV…") { model.importTerms() }
                Spacer()
                Button("恢复已掌握提示") { model.forgetKnown() }.disabled(model.known.isEmpty)
            }
            Text("TSV：英文 ⇥ 中文 ⇥ 解释 ⇥ 课程 ⇥ 出处；后三项可选。⇥ 表示 Tab 键。")
                .font(.caption).foregroundStyle(.secondary)
            if filtered.isEmpty {
                VStack(spacing: 9) {
                    Text("没有匹配的词条").font(.headline)
                    Text("可以尝试其他拼写，或添加自己的词条。英文字幕始终可以独立使用。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { term in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(term.english).fontWeight(.medium); Spacer(); Text(term.chinese).foregroundStyle(.secondary)
                            Button { detailTerm = term } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).help("查看 \(term.english) 的全部课件出处")
                            if model.known.contains(term.id) { Image(systemName: "checkmark").foregroundStyle(accent) }
                        }
                        Text(model.courseTitle(term.course) + " · " + (term.source ?? "未提供出处"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.help(term.explanation)
                }
            }
        }.padding(24).frame(width: 700, height: 660)
        .sheet(item: $detailTerm) { TermDetail(term: $0, courseTitle: model.courseTitle($0.course)) }
    }
}

struct TermDetail: View {
    let term: Term
    let courseTitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var openError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(term.english).font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            Text(term.chinese).font(.title3)
            Text(term.explanation).textSelection(.enabled)
            Text(courseTitle).font(.caption).foregroundStyle(.secondary)
            Divider()
            if let references = term.references, !references.isEmpty {
                Text("课件出处 · 页码从 1 开始").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(references.enumerated()), id: \.offset) { _, ref in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(ref.file).font(.callout).textSelection(.enabled)
                                    Text((ref.format == "slide" ? "幻灯片" : "PDF") + " 第 \(ref.page) 页").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("打开课件") {
                                    if !NSWorkspace.shared.open(URL(fileURLWithPath: ref.path)) { openError = "未能打开原文件；它可能已被移动。出处和页码仍可在这里查看。" }
                                }.font(.caption)
                            }
                        }
                    }
                }.frame(maxHeight: 270)
            } else { Text(term.source ?? "未提供课程材料出处").font(.callout).foregroundStyle(.secondary) }
            if let openError { Text(openError).font(.caption).foregroundStyle(.orange) }
            Text("中文是根据课程语境编写的辅助释义，不是官方译文；自动判断可能有误。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 600)
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    final class Handle: NSView {
        private var anchor: NSPoint?
        private var origin: NSPoint?
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            anchor = window.convertPoint(toScreen: event.locationInWindow); origin = window.frame.origin
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let anchor, let origin else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            var next = NSPoint(x: origin.x + point.x - anchor.x, y: origin.y + point.y - anchor.y)
            if let visible = window.screen?.visibleFrame {
                next.x = min(visible.maxX - 80, max(visible.minX - window.frame.width + 80, next.x))
                next.y = min(visible.maxY - window.frame.height, max(visible.minY + 28 - window.frame.height, next.y))
            }
            window.setFrameOrigin(next)
        }
        override func mouseUp(with event: NSEvent) { anchor = nil; origin = nil }
    }
    func makeNSView(context: Context) -> NSView {
        let view = Handle()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("拖动悬浮窗口")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct WindowAccessor: NSViewRepresentable {
    var floating: Bool
    var compact: Bool = false
    var model: AppModel
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var model: AppModel?
        weak var original: NSWindowDelegate?
        var lastCompact = false
        var lastLevel: NSWindow.Level?
        weak var attached: NSWindow?
        var normalFrame: NSRect?
        var compactFrame: NSRect?
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || (original?.responds(to: selector) ?? false) }
        override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if let model, model.hasActiveSession { model.requestStop(after: .close); return false }
            return original?.windowShouldClose?(sender) ?? true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        // SwiftUI calls this on every caption refresh. Touch the window only
        // when its floating or compact state actually changes.
        let coordinator = context.coordinator
        let level: NSWindow.Level = floating || compact ? .floating : .normal
        if let window = view.window, coordinator.attached === window,
           coordinator.lastLevel == level, coordinator.lastCompact == compact { return }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovable = true
            window.isMovableByWindowBackground = compact
            if coordinator.lastLevel != level { window.level = level; coordinator.lastLevel = level }
            if coordinator.lastCompact != compact {
                if compact {
                    coordinator.normalFrame = window.frame
                    let frame = coordinator.compactFrame ?? NSRect(x: window.frame.minX, y: window.frame.maxY - 268, width: 560, height: 268)
                    window.contentMinSize = NSSize(width: 360, height: 160)
                    window.setFrame(frame, display: true)
                } else {
                    coordinator.compactFrame = window.frame
                    window.contentMinSize = NSSize(width: 700, height: 500)
                    if let frame = coordinator.normalFrame { window.setFrame(frame, display: true) }
                }
                coordinator.lastCompact = compact
            }
            model.window = window
            coordinator.model = model
            coordinator.attached = window
            if window.delegate !== coordinator {
                coordinator.original = window.delegate; window.delegate = coordinator
            }
        }
    }
}

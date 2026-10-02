import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasActiveSession else { return .terminateNow }
        model.requestStop(after: .quit); return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
}

struct LensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Lecture Lens", id: "main") {
            LensView().environmentObject(model).onAppear { delegate.model = model }
        }.defaultSize(width: 1000, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("Lecture Lens 使用说明") { model.showHelp = true }
            }
        }
    }
}

@main enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--benchmark") {
            Task { @MainActor in
                let status = await Benchmark.run(arguments: CommandLine.arguments)
                exit(status)
            }
            dispatchMain()
        } else { LensApp.main() }
    }
}

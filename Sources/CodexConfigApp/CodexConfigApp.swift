import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var reopenMain: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.detector?.remoteMayBeActive == true {
            let alert = NSAlert()
            alert.messageText = "网站上的检测可能仍在运行"
            alert.informativeText = "退出本工具不会自动停止远端计费请求，且会丢失本次会话的停止权限。建议返回检测面板，停止任务并等待确认。"
            alert.addButton(withTitle: "返回检测")
            alert.addButton(withTitle: "仍然退出")
            if alert.runModal() != .alertSecondButtonReturn {
                DispatchQueue.main.async { self.reopenMain?() }
                return .terminateCancel
            }
        }
        guard model?.isDirty == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还有未保存的编辑"
        alert.informativeText = "退出会丢弃编辑区的未保存内容，已经应用到 Codex 的配置不会撤销。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "放弃并退出")
        if alert.runModal() == .alertSecondButtonReturn { return .terminateNow }
        // Closing the last window may have triggered termination. Bring it back on cancel.
        DispatchQueue.main.async { self.reopenMain?() }
        return .terminateCancel
    }
}

@main
struct CodexConfigApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Codex 配置", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(model.isDemo && CommandLine.arguments.contains("--demo-dark") ? .dark : nil)
                .onAppear {
                    delegate.model = model
                    delegate.reopenMain = { openWindow(id: "main") }
                    if CommandLine.arguments.contains("--measure-startup") {
                        print("CGL_WINDOW_READY")
                        fflush(stdout)
                    }
                }
        }
        .defaultSize(width: 850, height: 610)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新增配置") { model.request { model.newProfile() } }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存到收藏") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.validDraft || !model.storeReadable)
            }
        }
        MenuBarExtra("Codex 配置", systemImage: "slider.horizontal.3") {
            StatusMenuView(model: model)
        }
        .menuBarExtraStyle(.menu)

    }
}

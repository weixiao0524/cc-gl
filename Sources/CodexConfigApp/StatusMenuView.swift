import SwiftUI
import AppKit

struct StatusMenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isDemo ? "Codex 配置 · 隔离演示" : "Codex 配置")
        Text(model.current.map { "当前地址：\($0.config.baseURL)" } ?? "当前配置不可用")
        Divider()
        Text("切换到收藏线路…")
        if model.profiles.isEmpty {
            Text("暂无收藏，请在主窗口添加")
        }
        ForEach(model.profiles) { profile in
            Button {
                // Let the native menu dismiss before presenting an application modal alert.
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "切换到“\(profile.name)”？"
                    alert.informativeText = "目标地址：\(profile.baseURL)\n\n将应用收藏的地址与密钥，并备份原文件。编辑区内容会保留。切换后请重启 Codex 或相关会话。"
                    alert.addButton(withTitle: "切换")
                    alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    if !model.applySavedProfile(profile) {
                        let failure = NSAlert()
                        failure.messageText = "切换未完成"
                        failure.informativeText = model.errorMessage ?? "当前配置不可用，请打开主窗口检查或恢复配置。"
                        failure.runModal()
                        model.errorMessage = nil
                    }
                }
            }
            label: {
                let title = profile.name + " · " + (URLComponents(string: profile.baseURL)?.host ?? profile.baseURL)
                if model.activeProfileIDs.contains(profile.id) {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
            .accessibilityLabel(profile.name + (model.activeProfileIDs.contains(profile.id) ? "，当前已应用" : ""))
            .disabled(model.current == nil || !model.storeReadable || model.needsRecovery)
        }
        Divider()
        Text(model.status)
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("退出 Codex 配置") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
        .onAppear { model.refreshMenu() }
    }
}

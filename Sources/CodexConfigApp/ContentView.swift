import SwiftUI
import AppKit
import CodexConfigCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var revealKey = false
    @State private var showConfigurationInfo = false
    @State private var showCloudSync = false
    @State private var showMCP = false
    private let accent = Color(red: 0.12, green: 0.48, blue: 0.43)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            editor
        }
        .frame(minWidth: 800, minHeight: 590)
        .tint(accent)
        .sheet(item: $model.detector) { detector in
            DetectionView(model: detector) { model.detector = nil }
        }
        .sheet(isPresented: $showCloudSync) {
            CloudSyncView(model: model.cloudSync)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { model.request { model.reload() } } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
                .help("重新读取两个本地文件，不进行写入")
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("放弃未保存的编辑？", isPresented: $model.showDiscard, titleVisibility: .visible) {
            Button("放弃编辑", role: .destructive) { revealKey = false; model.discardAndContinue() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("已经应用到 Codex 的配置不会撤销。") }
        .alert("应用此配置？", isPresented: $model.showApply) {
            Button("取消", role: .cancel) {}
            Button("应用") { model.apply() }
        } message: {
            Text("目标地址：\(model.draft.baseURL)\n\n仅替换当前提供方的 base_url 和 auth.json 的 API Key。原文件将备份；本工具不会发起网络请求。")
        }
        .alert("恢复上次配置？", isPresented: $model.showRestore) {
            Button("取消", role: .cancel) {}
            Button("恢复") { revealKey = false; model.restore() }
        } message: { Text("恢复最近一次切换前的两个文件。若文件已有其他改动，将拒绝覆盖。当前编辑区会重新加载。") }
        .alert("删除这条收藏？", isPresented: $model.showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除收藏", role: .destructive) { model.delete() }
        } message: { Text("将删除“\(model.draft.name)”及其收藏密钥，不修改 Codex 当前使用的配置。") }
        .onChange(of: model.selection) { _ in revealKey = false }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex 配置").font(.headline)
                    Text("线路切换 · 权限设置").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 26)

            sidebarButton(title: "当前文件", subtitle: "读取本机正在使用的配置", icon: "doc.text", selected: model.selection == nil) {
                model.request { model.useCurrent() }
            }
            .padding(.horizontal, 10)

            HStack {
                Text("我的收藏").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.profiles.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.profiles) { profile in
                        sidebarButton(title: profile.name,
                                      subtitle: URLComponents(string: profile.baseURL)?.host ?? profile.baseURL,
                                      icon: "server.rack", selected: model.selection == profile.id) {
                            model.request { model.select(profile) }
                        }
                    }
                    if model.profiles.isEmpty {
                        Text("保存常用地址和密钥，\n下次直接选中应用。")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    if model.selection != nil && !model.isSaved {
                        sidebarButton(title: "新配置", subtitle: "尚未保存", icon: "pencil", selected: true) {}
                    }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            Button { model.request { model.newProfile() } } label: {
                Label("新增配置", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .controlSize(.large).padding(16)
            CloudSyncSidebarButton(model: model.cloudSync) { showCloudSync = true }
            .padding(.horizontal, 20).padding(.bottom, 16)
            HStack(spacing: 5) {
                Image(systemName: model.isDemo ? "testtube.2" : "internaldrive")
                Text(model.isDemo ? "演示模式 · 隔离数据" : "状态栏快捷切换 · 按需检测")
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.bottom, 18)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func sidebarButton(title: String, subtitle: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 22)
                    .foregroundStyle(selected ? accent : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(selected ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.selection == nil ? "当前配置" : "编辑配置")
                        .font(.system(size: 26, weight: .semibold))
                    Text("选择地址，保存密钥，需要时一键应用。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.matchesCurrent {
                    Label("与当前文件一致", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(accent)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(accent.opacity(0.08), in: Capsule())
                } else if model.isDirty {
                    Text("未保存").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                fieldLabel("配置名称", hint: "只用于本地收藏") {
                    TextField("例如：日常使用", text: $model.draft.name)
                        .accessibilityIdentifier("profile-name")
                }
                fieldLabel("Base URL", hint: "完整保留输入地址，不自动添加 /v1") {
                    TextField("https://api.example.com/v1", text: $model.draft.baseURL)
                        .font(.system(size: 13, design: .monospaced))
                        .accessibilityIdentifier("base-url")
                }
                fieldLabel("API Key", hint: "收藏密钥存入 macOS 钥匙串") {
                    HStack(spacing: 8) {
                        Group {
                            if revealKey { TextField("输入 API Key", text: $model.apiKey) }
                            else { SecureField("输入 API Key", text: $model.apiKey) }
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .accessibilityIdentifier("api-key")
                        Button { revealKey.toggle() } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye").frame(width: 20)
                        }
                        .buttonStyle(.borderless)
                        .help(revealKey ? "隐藏密钥" : "显示密钥")
                        .accessibilityLabel(revealKey ? "隐藏密钥" : "显示密钥")
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .padding(22)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06), lineWidth: 1))

            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.current?.config.yoloEnabled ?? false },
                    set: { model.setYOLO($0) }
                )) {
                    Text("YOLO 模式").font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("codex-yolo")
                .disabled(model.current == nil || model.needsRecovery)

                Text(model.current == nil ? "未读取" : model.current?.config.yoloEnabled == true ? "免审批 · 完全访问" : "未开启")
                    .font(.caption2)
                    .foregroundStyle(model.current?.config.yoloEnabled == true ? accent : .secondary)

                Button { showConfigurationInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("权限与配置说明")
                .help("权限与配置说明")
                .popover(isPresented: $showConfigurationInfo, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("权限与配置").font(.headline)
                        Text("YOLO 为全局设置，切换即保存。开启后免审批、完全访问；关闭后使用工作区写入、按需审批。")
                        Text("重启 Codex 或新建会话后读取。命令行、项目配置或受托管策略可能覆盖此设置。")
                        Divider()
                        Text("应用线路只更新地址和密钥，其他设置保持原样。支持恢复最近一次修改。")
                        Text(model.isDemo ? "演示数据与真实配置完全隔离" : "目录：\(model.service.codexDirectory.path)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18)
                    .frame(width: 310)
                }

                Spacer(minLength: 8)
                Button { showMCP.toggle() } label: {
                    Label("MCP 管理", systemImage: "puzzlepiece.extension")
                }
                .controlSize(.small)
                .accessibilityIdentifier("mcp-management")
                .popover(isPresented: $showMCP, arrowEdge: .bottom) {
                    mcpModule
                        .frame(width: 360, height: 420)
                }
                Button { model.openDetector() } label: {
                    Label("模型检测", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                .disabled(model.draft.baseURL.isEmpty || model.apiKey.isEmpty)
                .help("使用当前地址和 Key 打开模型侦探；开始检测前会说明费用与数据用途")
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 0)

            if model.needsRecovery {
                Label("发现未完成的切换，请先恢复上次配置。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                if model.isSaved {
                    Button(role: .destructive) { model.showDelete = true } label: {
                        Image(systemName: "trash")
                    }.help("删除收藏，不修改 Codex 文件")
                }
                Button("恢复上次配置") { model.showRestore = true }
                    .disabled(!model.hasBackup)
                Spacer(minLength: 0)
                Button("保存到收藏") { model.save() }
                    .disabled(!model.validDraft || !model.storeReadable)
                Button("应用此配置") { model.showApply = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.validDraft || model.current == nil || model.needsRecovery || model.matchesCurrent)
            }
            .controlSize(.large)

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: model.statusIsError ? "exclamationmark.circle" : "info.circle")
                Text(model.status).textSelection(.enabled).lineLimit(3)
            }
            .font(.caption).foregroundStyle(model.statusIsError ? Color.orange : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 30, alignment: .top)
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mcpModule: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text("MCP 管理").font(.system(size: 14, weight: .semibold))
                    Text("选择要启用的服务").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showMCP = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.primary.opacity(0.05), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭 MCP 管理")
            }
            .padding(18)
            Divider().padding(.horizontal, 18)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    if let config = model.current?.config {
                        switch Result(catching: { try config.mcpServers() }) {
                        case .success(let servers):
                            if servers.isEmpty {
                                Text("尚未配置 MCP 服务")
                                    .font(.caption).foregroundStyle(.secondary).padding(12)
                            }
                            ForEach(servers) { server in
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(server.enabled ? accent : Color.secondary.opacity(0.25))
                                        .frame(width: 6, height: 6)
                                    Text(server.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(server.name)
                                    Spacer(minLength: 8)
                                    Toggle(server.name, isOn: Binding(
                                        get: { server.enabled },
                                        set: { model.setMCP(server.name, enabled: $0) }
                                    ))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                    .fixedSize()
                                    .disabled(model.needsRecovery)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 40)
                                .background(server.enabled ? accent.opacity(0.055) : Color.primary.opacity(0.025),
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                        case .failure:
                            Text("MCP 配置无法读取，请检查服务表和 enabled 字段。")
                                .font(.caption).foregroundStyle(.orange).padding(12)
                        }
                    } else {
                        Text("请先成功读取 Codex 配置")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            Divider().padding(.horizontal, 18)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                Text("切换即保存，重启 Codex 或相关会话后生效。")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
    }

    private func fieldLabel<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

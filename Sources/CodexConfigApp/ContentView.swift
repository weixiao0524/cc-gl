import SwiftUI
import AppKit
import CodexConfigCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var revealKey = false
    @State private var showConfigurationInfo = false
    @State private var showCloudSync = false
    @State private var showMCP = false
    @State private var search = ""
    @State private var visitedFields: Set<AppModel.DraftField> = []
    @FocusState private var focusedField: AppModel.DraftField?
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.47, green: 0.83, blue: 0.71) : Color(red: 0.12, green: 0.48, blue: 0.43)
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
            editor.frame(minWidth: 550)
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
        .onChange(of: model.selection) { _ in
            revealKey = false
            focusedField = nil
            visitedFields = []
        }
        .onChange(of: focusedField) { [focusedField] _ in
            if let focusedField { visitedFields.insert(focusedField) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex 配置").font(.headline)
                }
            }
            .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 26)

            sidebarButton(title: "本地配置", subtitle: "config.toml · auth.json", icon: "doc.text", selected: model.selection == nil) {
                model.request { model.useCurrent() }
            }
            .padding(.horizontal, 10)

            HStack {
                Text("我的收藏").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.profiles.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索收藏", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索收藏名称或地址")
                    .accessibilityIdentifier("profile-search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 12)).padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.filteredProfiles(matching: search)) { profile in
                        sidebarButton(title: profile.name,
                                      subtitle: URLComponents(string: profile.baseURL)?.host ?? profile.baseURL,
                                      icon: "server.rack", selected: model.selection == profile.id,
                                      active: model.activeProfileIDs.contains(profile.id), fullSubtitle: profile.baseURL) {
                            model.request { model.select(profile) }
                        }
                    }
                    if model.profiles.isEmpty {
                        Text("暂无收藏")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else if model.filteredProfiles(matching: search).isEmpty {
                        Text("没有匹配的收藏").font(.caption).foregroundStyle(.secondary).padding(12)
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
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.bottom, 18)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func sidebarButton(title: String, subtitle: String, icon: String, selected: Bool, active: Bool = false, fullSubtitle: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 22)
                    .foregroundStyle(selected ? accent : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                        .help("地址和密钥与本地文件一致")
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(selected ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("\(title)\n\(fullSubtitle ?? subtitle)" + (active ? "\n地址和密钥与本地文件一致" : ""))
        .accessibilityLabel("\(title)，\(fullSubtitle ?? subtitle)" + (active ? "，与本地文件一致" : ""))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    editorHeader
                    connectionFields
                    HStack {
                        Spacer()
                        Button { model.openDetector() } label: {
                            Label("模型检测", systemImage: "magnifyingglass")
                        }
                        .disabled(!model.validConnection)
                        .help("检测编辑区的地址与密钥；开始前确认费用和数据用途")
                    }
                    Divider()
                    globalSettings
                }
                .padding(24)
            }
            Divider()
            editorFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selection == nil ? "本地配置" : model.isSaved ? "编辑收藏" : "新增收藏")
                .font(.system(size: 22, weight: .semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { collectionStatus; fileStatus }
                VStack(alignment: .leading, spacing: 6) { collectionStatus; fileStatus }
            }
            .font(.system(size: 12))
        }
    }

    private var collectionStatus: some View {
        Label(model.collectionStatus, systemImage: model.isDirty ? "pencil.circle" : model.isSaved ? "bookmark.fill" : "bookmark")
            .foregroundStyle(model.isDirty ? Color.orange : Color.secondary)
            .accessibilityIdentifier("collection-status")
    }

    private var fileStatus: some View {
        Label(model.current == nil ? "本地配置不可用" : model.matchesCurrent ? "与本地文件一致" : "未写入本地文件",
              systemImage: model.matchesCurrent ? "checkmark.circle.fill" : "doc.text")
            .foregroundStyle(model.matchesCurrent ? accent : .secondary)
            .accessibilityIdentifier("file-status")
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldLabel("收藏名称", hint: "仅收藏时必填", field: .name) {
                TextField("例如：日常使用", text: $model.draft.name)
                    .focused($focusedField, equals: .name)
                    .accessibilityLabel("收藏名称")
                    .accessibilityIdentifier("profile-name")
            }
            fieldLabel("Base URL", hint: "完整地址，不自动添加 /v1", field: .baseURL) {
                TextField("https://api.example.com/v1", text: $model.draft.baseURL)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focusedField, equals: .baseURL)
                    .accessibilityLabel("Base URL")
                    .accessibilityIdentifier("base-url")
            }
            fieldLabel("API Key", hint: "收藏密钥存于 macOS 钥匙串", field: .apiKey) {
                HStack(spacing: 8) {
                    Group {
                        if revealKey { TextField("输入 API Key", text: $model.apiKey) }
                        else { SecureField("输入 API Key", text: $model.apiKey) }
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focusedField, equals: .apiKey)
                    .accessibilityLabel("API Key")
                    .accessibilityIdentifier("api-key")
                    Button { revealKey.toggle() } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help(revealKey ? "隐藏密钥" : "显示密钥")
                    .accessibilityLabel(revealKey ? "隐藏密钥" : "显示密钥")
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
    }

    private var globalSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("全局设置").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("本机 · 即时保存").font(.system(size: 11)).foregroundStyle(.secondary)
            }
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
                    .font(.system(size: 11))
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
            }
        }
    }

    private var editorFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.needsRecovery {
                Label("发现未完成的切换，请先恢复上次配置。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                if model.isSaved {
                    Button(role: .destructive) { model.showDelete = true } label: {
                        Image(systemName: "trash")
                    }.help("删除收藏，不修改 Codex 文件").accessibilityLabel("删除收藏")
                }
                Button("恢复上次配置") { model.showRestore = true }
                    .disabled(!model.hasBackup)
                Spacer(minLength: 0)
                Button("保存到收藏") { model.save() }
                    .disabled(model.saveDisabledReason != nil)
                    .help(model.saveDisabledReason ?? "保存地址和密钥，不修改本地配置")
                Button("应用此配置") { model.showApply = true }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(model.applyDisabledReason == nil ? (colorScheme == .dark ? Color.black : .white) : .secondary)
                    .disabled(model.applyDisabledReason != nil)
                    .help(model.applyDisabledReason ?? "将地址和密钥写入本地配置，不自动保存收藏")
            }
            .controlSize(.large)

            if let issue = actionIssue {
                Text(issue).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: model.statusIsError ? "exclamationmark.circle" : "info.circle")
                Text(model.status).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption).foregroundStyle(model.statusIsError ? Color.orange : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 30, alignment: .top)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var actionIssue: String? {
        if !model.storeReadable { return "收藏不可用，请检查钥匙串和文件访问状态。" }
        if model.current == nil { return "本地配置不可用，暂时无法应用线路。" }
        if model.validationError(for: .baseURL) != nil { return "请填写有效的 Base URL 后保存或应用。" }
        if model.validationError(for: .apiKey) != nil { return "请填写有效的 API Key 后保存或应用。" }
        if model.validationError(for: .name) != nil { return "收藏需要名称；直接应用线路无需名称。" }
        return nil
    }

    private var mcpModule: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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

    private func fieldLabel<Content: View>(_ title: String, hint: String, field: AppModel.DraftField, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
            if visitedFields.contains(field), let error = model.validationError(for: field) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

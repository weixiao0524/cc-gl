import XCTest
import SwiftUI
import AppKit
import CodexConfigCore
@testable import CodexConfigApp

final class EditorUXTests: XCTestCase {
    @MainActor
    func testRenamingCurrentFavoriteKeepsBothStatuses() throws {
        let model = AppModel(isDemo: true)
        defer { removeDemo(model) }
        let profile = try XCTUnwrap(model.profiles.first { model.activeProfileIDs.contains($0.id) })
        model.select(profile)
        XCTAssertEqual(model.collectionStatus, "收藏已保存")
        XCTAssertNotNil(model.saveDisabledReason)
        model.draft.name = "Renamed favorite"
        XCTAssertTrue(model.matchesCurrent)
        XCTAssertEqual(model.collectionStatus, "收藏有未保存修改")
        XCTAssertNil(model.saveDisabledReason)
        model.save()
        XCTAssertEqual(model.collectionStatus, "收藏已保存")
        XCTAssertTrue(model.matchesCurrent)
    }

    @MainActor
    func testApplyingUnnamedConnectionDoesNotSaveOrClearDirtyState() {
        let model = AppModel(isDemo: true)
        defer { removeDemo(model) }
        let count = model.profiles.count
        model.newProfile()
        model.draft.baseURL = "https://new.example.com/v1"
        model.apiKey = "demo-new-key"
        XCTAssertTrue(model.validConnection)
        XCTAssertFalse(model.validDraft)
        XCTAssertNotNil(model.saveDisabledReason)
        XCTAssertNil(model.applyDisabledReason)
        model.apply()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.matchesCurrent)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.collectionStatus, "收藏有未保存修改")
        XCTAssertEqual(model.profiles.count, count)
        XCTAssertEqual(model.current?.config.baseURL, "https://new.example.com/v1")
    }

    @MainActor
    func testValidationExplainsEachFieldWithoutEchoingSecrets() {
        let model = AppModel(isDemo: true)
        defer { removeDemo(model) }
        model.newProfile()
        XCTAssertNotNil(model.validationError(for: .name))
        XCTAssertNotNil(model.validationError(for: .baseURL))
        XCTAssertNotNil(model.validationError(for: .apiKey))
        model.draft.name = "Valid favorite"
        model.draft.baseURL = "https://example.com/v1"
        model.apiKey = "private-secret with-space"
        XCTAssertNil(model.validationError(for: .name))
        XCTAssertNil(model.validationError(for: .baseURL))
        XCTAssertFalse(model.validationError(for: .apiKey)?.contains("private-secret") ?? true)
        XCTAssertNotNil(model.applyDisabledReason)
        model.apiKey = "demo-key"
        XCTAssertTrue(model.validDraft)
        XCTAssertNil(model.applyDisabledReason)
        model.needsRecovery = true
        XCTAssertEqual(model.applyDisabledReason, "请先恢复上次配置。")
    }

    @MainActor
    func testSearchMatchesNamesAndFullAddressesWithoutChangingSelection() throws {
        let model = AppModel(isDemo: true)
        defer { removeDemo(model) }
        let profile = try XCTUnwrap(model.profiles.first { $0.baseURL.contains("backup") })
        model.select(profile)
        XCTAssertEqual(model.filteredProfiles(matching: "  BACKUP  ").map(\.id), [profile.id])
        XCTAssertEqual(model.filteredProfiles(matching: "备用").map(\.id), [profile.id])
        XCTAssertEqual(model.filteredProfiles(matching: "/v1").count, model.profiles.count)
        XCTAssertEqual(model.filteredProfiles(matching: " \n ").count, model.profiles.count)
        XCTAssertTrue(model.filteredProfiles(matching: "no-match").isEmpty)
        XCTAssertEqual(model.selection, profile.id)
    }

    @MainActor
    func testGlobalSettingsPreserveUnsavedConnection() {
        let model = AppModel(isDemo: true)
        defer { removeDemo(model) }
        let originalURL = model.current?.config.baseURL
        model.draft.baseURL = "https://unsaved.example.com/v1"
        model.apiKey = "unsaved-key"
        model.setYOLO(true)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.current?.config.baseURL, originalURL)
        XCTAssertEqual(model.current?.config.yoloEnabled, true)
        XCTAssertEqual(model.draft.baseURL, "https://unsaved.example.com/v1")
        XCTAssertEqual(model.apiKey, "unsaved-key")
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testModelInstructionsAndContextLimitsWriteCodexConfig() throws {
        let model = AppModel(isDemo: true)
        defer { removeDemo(model) }
        let originalURL = model.current?.config.baseURL
        model.draft.baseURL = "https://unsaved.example.com/v1"
        model.apiKey = "unsaved-key"
        model.startInstructionsFile(open: false)
        XCTAssertNil(model.errorMessage)
        let instructions = try XCTUnwrap(try model.current?.config.modelSettings().instructionsFile)
        XCTAssertEqual(instructions, model.service.codexDirectory.appendingPathComponent("model_instructions.md").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: instructions))
        XCTAssertTrue(String(decoding: try Data(contentsOf: URL(fileURLWithPath: instructions)), as: UTF8.self).contains("Codex 模型指令"))
        model.setContextLimits(window: 272_000, compact: 240_000)
        XCTAssertNil(model.errorMessage)
        let settings = try XCTUnwrap(try model.current?.config.modelSettings())
        XCTAssertEqual(settings.contextWindow, 272_000)
        XCTAssertEqual(settings.autoCompactTokenLimit, 240_000)
        let written = String(decoding: try Data(contentsOf: model.service.codexDirectory.appendingPathComponent("config.toml")), as: UTF8.self)
        XCTAssertTrue(written.contains("model_instructions_file = \"\(instructions)\""))
        XCTAssertTrue(written.contains("model_context_window = 272000"))
        XCTAssertTrue(written.contains("model_auto_compact_token_limit = 240000"))
        XCTAssertEqual(model.current?.config.baseURL, originalURL)
        XCTAssertEqual(model.draft.baseURL, "https://unsaved.example.com/v1")
        XCTAssertTrue(model.isDirty)
        model.setInstructionsFile(nil)
        model.setContextLimits(window: nil, compact: nil)
        XCTAssertNil(try model.current?.config.modelSettings().instructionsFile)
        XCTAssertNil(try model.current?.config.modelSettings().contextWindow)
        XCTAssertFalse(String(decoding: try Data(contentsOf: model.service.codexDirectory.appendingPathComponent("config.toml")), as: UTF8.self).contains("model_instructions_file"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: instructions))
    }

    func testSyncFormValidationAndPasswordRetention() {
        var form = SyncConnectionForm()
        XCTAssertFalse(form.isValid)
        form.password = "existing-pass"
        XCTAssertTrue(form.isValid)
        form.create = true
        XCTAssertEqual(form.confirmationError, "两次输入的密码不一致。")
        form.confirmation = form.password
        XCTAssertTrue(form.isValid)
        form.finishConnection(succeeded: false)
        XCTAssertEqual(form.password, "existing-pass")
        XCTAssertEqual(form.confirmation, "existing-pass")
        form.finishConnection(succeeded: true)
        XCTAssertTrue(form.password.isEmpty)
        XCTAssertTrue(form.confirmation.isEmpty)
        form.password = "short"
        form.confirmation = "short"
        XCTAssertNotNil(form.passwordError)
        XCTAssertFalse(form.isValid)
        form.create = false
        form.password = String(repeating: "x", count: 1025)
        XCTAssertNotNil(form.passwordError)
        XCTAssertFalse(form.isValid)
    }

    @MainActor
    func testFailedSyncConnectionResetsBusyAndAllowsRetry() async throws {
        let model = AppModel(isDemo: true)
        defer { removeDemo(model) }
        let sync = try XCTUnwrap(model.cloudSync)
        sync.folder = model.service.codexDirectory
        let succeeded = await sync.connect(password: "demo-password", create: false)
        XCTAssertFalse(succeeded)
        XCTAssertFalse(sync.busy)
        XCTAssertFalse(sync.enabled)
        XCTAssertNotNil(sync.error)
        XCTAssertEqual(sync.status, "连接失败")
    }

    @MainActor
    func testCompletedReportStaysBoundToTestedCandidate() throws {
        let model = DetectionViewModel(baseURL: "https://example.com/v1", apiKey: "demo-key", profileName: "Demo", isDemo: true)
        XCTAssertFalse(model.hasCompletedReport)
        model.testedCandidate = .astra
        model.report = try JSONDecoder().decode(DetectionReport.self, from: Data("""
        {"id":"demo","status":"complete","planned":20,"completed":20,"valid":18,"attempts":20}
        """.utf8))
        model.phase = .finished
        model.candidate = .sol
        XCTAssertTrue(model.hasCompletedReport)
        XCTAssertEqual(model.reportCandidate, .astra)
        XCTAssertEqual(model.report?.valid, 18)
    }

    @MainActor
    func testMainWindowRendersModelSettingsControls() throws {
        let model = AppModel(isDemo: true)
        defer { removeDemo(model) }
        model.startInstructionsFile(open: false)
        model.setContextLimits(window: 272_000, compact: 240_000)
        let host = NSHostingView(rootView: ContentView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        XCTAssertEqual(image.pixelsWide, 900)
        XCTAssertEqual(image.pixelsHigh, 640)
        var colors = Set<String>()
        for x in stride(from: 8, to: image.pixelsWide - 8, by: 12) {
            for y in stride(from: 8, to: image.pixelsHigh - 8, by: 12) {
                if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 20, "主窗口渲染结果过空")
        let windowLabels = labels(in: host)
        XCTAssertTrue(windowLabels.contains(where: { $0.contains("上下文上限 272000") }), windowLabels.joined(separator: " | "))
        XCTAssertTrue(windowLabels.contains(where: { $0.contains("自动压缩 240000") }))
        let panelHost = NSHostingView(rootView: ModelSettingsPanel(model: model, accent: Color(red: 0.12, green: 0.48, blue: 0.43), onClose: {}))
        panelHost.frame = NSRect(x: 0, y: 0, width: 400, height: 560)
        panelHost.layoutSubtreeIfNeeded()
        let panelImage = try XCTUnwrap(panelHost.bitmapImageRepForCachingDisplay(in: panelHost.bounds))
        panelHost.cacheDisplay(in: panelHost.bounds, to: panelImage)
        XCTAssertEqual(panelImage.pixelsWide, 400)
        XCTAssertEqual(panelImage.pixelsHigh, 560)
        let panelLabels = labels(in: panelHost)
        XCTAssertTrue(panelLabels.contains(where: { $0.contains("model_instructions.md") }), panelLabels.joined(separator: " | "))
        XCTAssertTrue(panelLabels.contains(where: { $0.contains("272000") }))
        XCTAssertTrue(panelLabels.contains(where: { $0.contains("240000") }))
        if let directory = ProcessInfo.processInfo.environment["MODEL_SETTINGS_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: url.appendingPathComponent("main-window.png"))
            try XCTUnwrap(panelImage.representation(using: .png, properties: [:]))
                .write(to: url.appendingPathComponent("model-settings.png"))
        }
    }

    private func labels(in view: NSView) -> [String] {
        var result: [String] = []
        if let text = (view as? NSTextField)?.stringValue, !text.isEmpty { result.append(text) }
        if let button = view as? NSButton, !button.title.isEmpty { result.append(button.title) }
        if let label = view.accessibilityLabel(), !label.isEmpty { result.append(label) }
        if let title = view.accessibilityTitle(), !title.isEmpty { result.append(title) }
        if let value = view.accessibilityValue() as? String, !value.isEmpty { result.append(value) }
        for child in view.subviews { result.append(contentsOf: labels(in: child)) }
        return result
    }

    @MainActor
    private func removeDemo(_ model: AppModel) {
        try? FileManager.default.removeItem(at: model.service.codexDirectory.deletingLastPathComponent())
    }
}

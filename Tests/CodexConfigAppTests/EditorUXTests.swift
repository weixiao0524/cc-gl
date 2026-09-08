import XCTest
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
    private func removeDemo(_ model: AppModel) {
        try? FileManager.default.removeItem(at: model.service.codexDirectory.deletingLastPathComponent())
    }
}

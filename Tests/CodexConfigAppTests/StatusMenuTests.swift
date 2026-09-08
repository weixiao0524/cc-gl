import XCTest
@testable import CodexConfigApp

final class StatusMenuTests: XCTestCase {
    @MainActor
    func testSwitchUsesSavedCredentialsAndPreservesDirtyEditor() throws {
        let model = AppModel(isDemo: true)
        defer { try? FileManager.default.removeItem(at: model.service.codexDirectory.deletingLastPathComponent()) }
        let profile = try XCTUnwrap(model.profiles.first { $0.baseURL.contains("backup") })
        model.draft.name = "未保存的编辑"
        model.apiKey = "unsaved-key"
        let draft = model.draft
        XCTAssertTrue(model.applySavedProfile(profile))
        XCTAssertEqual(model.current?.config.baseURL, profile.baseURL)
        XCTAssertEqual(model.current?.auth.apiKey, "demo-backup-key")
        XCTAssertEqual(model.draft, draft)
        XCTAssertEqual(model.apiKey, "unsaved-key")
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.hasBackup)
        XCTAssertEqual(model.activeProfileIDs, [profile.id])
    }

    @MainActor
    func testActiveMarkerMatchesKeyAndRefreshesAfterRestore() throws {
        let model = AppModel(isDemo: true)
        defer { try? FileManager.default.removeItem(at: model.service.codexDirectory.deletingLastPathComponent()) }
        let original = try XCTUnwrap(model.profiles.first { $0.baseURL == model.current?.config.baseURL })
        XCTAssertEqual(model.activeProfileIDs, [original.id])
        model.newProfile()
        model.draft.name = "同地址不同密钥"
        model.draft.baseURL = original.baseURL
        model.apiKey = "different-key"
        model.save()
        XCTAssertEqual(model.activeProfileIDs, [original.id])
        let saved = model.draft
        XCTAssertTrue(model.applySavedProfile(saved))
        XCTAssertEqual(model.activeProfileIDs, [saved.id])
        model.restore()
        XCTAssertEqual(model.activeProfileIDs, [original.id])
        try FileManager.default.removeItem(at: model.service.codexDirectory.appendingPathComponent("config.toml"))
        model.refreshMenu()
        XCTAssertTrue(model.activeProfileIDs.isEmpty)
    }

    @MainActor
    func testRejectsStaleProfileAndExternalFileChanges() throws {
        let model = AppModel(isDemo: true)
        defer { try? FileManager.default.removeItem(at: model.service.codexDirectory.deletingLastPathComponent()) }
        let profile = try XCTUnwrap(model.profiles.first)
        var stale = profile
        stale.baseURL = "https://stale.example.com/v1"
        XCTAssertFalse(model.applySavedProfile(stale))
        let file = model.service.codexDirectory.appendingPathComponent("config.toml")
        var data = try Data(contentsOf: file)
        data.append(Data("\n# external edit\n".utf8))
        try data.write(to: file)
        XCTAssertFalse(model.applySavedProfile(profile))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
}

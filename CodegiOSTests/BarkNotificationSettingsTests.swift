import Foundation
import XCTest
@testable import Codeg

@MainActor
final class BarkNotificationSettingsTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let chinese = Locale(identifier: "zh-Hans_CN")

    func testDefaultsAndLoadDoNotRegisterUntilExplicitSave() async {
        let api = BarkSettingsStub()
        let id = UUID()
        let model = NotificationsSettingsModel(deviceID: id, api: api)
        XCTAssertEqual(model.draft, BarkNotificationSettings())
        XCTAssertFalse(model.draft.enabled)
        XCTAssertFalse(model.draft.includePreview)
        XCTAssertEqual(model.draft.pushUrl, "")
        XCTAssertEqual(model.draft.language, "en")
        XCTAssertFalse(model.canEdit)
        await model.load()
        XCTAssertEqual(api.loadedIDs, [id])
        XCTAssertTrue(api.writes.isEmpty)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.canTest)
        XCTAssertTrue(model.canEdit)
    }

    func testSaveUsesProfileIdentityLocaleAndNormalizedResponse() async {
        let api = BarkSettingsStub()
        let id = UUID()
        let model = NotificationsSettingsModel(deviceID: id, api: api)
        await model.load()
        model.draft.enabled = true
        model.draft.pushUrl = "  http://bark.example/key/ \n"
        model.draft.includePreview = true
        api.normalized = BarkNotificationSettings(enabled: true, pushUrl: "http://bark.example/key",
                                                   includePreview: true, language: "zh-Hans")
        await model.save(locale: chinese)
        XCTAssertEqual(api.writes.first?.0, id)
        XCTAssertEqual(api.writes.first?.1.pushUrl, "http://bark.example/key/")
        XCTAssertEqual(api.writes.first?.1.language, "zh-Hans")
        XCTAssertEqual(model.draft, api.normalized)
        XCTAssertEqual(model.saved, api.normalized)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertTrue(model.canTest)

        // Reopening reads persisted server state rather than resetting defaults.
        let reopened = NotificationsSettingsModel(deviceID: id, api: api)
        await reopened.load()
        XCTAssertEqual(reopened.draft, model.saved)
    }

    func testUnsavedEditsCannotBeTestedOrImplicitlySaved() async {
        let api = BarkSettingsStub(settings: .configured)
        let model = NotificationsSettingsModel(deviceID: UUID(), api: api)
        await model.load()
        model.draft.includePreview = true
        await model.test(locale: chinese)
        XCTAssertEqual(model.failure, .unsaved)
        XCTAssertTrue(api.writes.isEmpty)
        XCTAssertTrue(api.testedIDs.isEmpty)
        XCTAssertTrue(model.draft.includePreview)
        XCTAssertFalse(model.canTest)
    }

    func testTestUpdatesAppLocaleBeforeSendingAndWaitsForAck() async {
        let api = BarkSettingsStub(settings: .configured)
        let id = UUID()
        let model = NotificationsSettingsModel(deviceID: id, api: api)
        await model.load()
        let gate = BarkOperationGate()
        api.testGate = gate
        let task = Task { await model.test(locale: chinese) }
        await gate.waitUntilEntered()
        XCTAssertEqual(api.events, ["load", "save", "test"])
        XCTAssertEqual(api.writes.first?.1.language, "zh-Hans")
        XCTAssertEqual(api.testedIDs, [id])
        XCTAssertEqual(model.operation, .testing)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.canTest)
        await model.test(locale: english)
        await model.save(locale: english)
        XCTAssertEqual(api.events, ["load", "save", "test"])
        gate.release()
        await task.value
        XCTAssertNotNil(model.notice)
        XCTAssertNil(model.failure)
    }

    func testFailedLocaleSavePreventsTestAndCanRetry() async {
        let api = BarkSettingsStub(settings: .configured)
        let model = NotificationsSettingsModel(deviceID: UUID(), api: api)
        await model.load()
        api.saveError = APIError.transport("unreachable")
        await model.test(locale: chinese)
        XCTAssertEqual(model.failure, .offline)
        XCTAssertTrue(api.testedIDs.isEmpty)
        XCTAssertEqual(model.saved?.language, "en")
        XCTAssertEqual(model.draft, .configured)
        api.saveError = nil
        await model.test(locale: chinese)
        XCTAssertEqual(api.testedIDs.count, 1)
        XCTAssertEqual(model.saved?.language, "zh-Hans")
    }

    func testSaveAndTestFailuresPreserveInputAndRedactBackendDetails() async {
        let api = BarkSettingsStub(settings: .configured)
        let model = NotificationsSettingsModel(deviceID: UUID(), api: api)
        await model.load()
        model.draft.pushUrl = "https://private.example/secret-key"
        let draft = model.draft
        api.saveError = APIError.server(status: 422, code: nil, message: draft.pushUrl, detail: draft.pushUrl)
        await model.save(locale: english)
        XCTAssertEqual(model.failure, .request)
        XCTAssertFalse(model.failure!.rawValue.contains("secret-key"))
        XCTAssertEqual(model.draft, draft)
        XCTAssertEqual(model.saved, .configured)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertFalse(model.isBusy)
        api.saveError = nil
        await model.save(locale: english)
        api.testError = APIError.transport(draft.pushUrl)
        await model.test(locale: english)
        XCTAssertEqual(model.failure, .offline)
        XCTAssertEqual(model.draft, draft)
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.canTest)
        api.testError = nil
        await model.test(locale: english)
        XCTAssertNil(model.failure)
        XCTAssertNotNil(model.notice)
    }

    func testLoadErrorsAreActionableAndRetryable() async {
        let cases: [(Error, NotificationsSettingsModel.Failure)] = [
            (APIError.transport("offline"), .offline),
            (APIError.unauthorized, .unauthorized),
            (APIError.server(status: 404, code: nil, message: "old server", detail: nil), .unsupported),
            (APIError.decoding("HTML response"), .unsupported)
        ]
        for (error, failure) in cases {
            let api = BarkSettingsStub()
            api.loadError = error
            let model = NotificationsSettingsModel(deviceID: UUID(), api: api)
            await model.load()
            XCTAssertEqual(model.failure, failure)
            XCTAssertNil(model.saved)
            XCTAssertFalse(model.canEdit)
            XCTAssertFalse(model.isBusy)
            await model.save(locale: english)
            await model.test(locale: english)
            XCTAssertTrue(api.writes.isEmpty)
            XCTAssertTrue(api.testedIDs.isEmpty)
            api.loadError = nil
            await model.load()
            XCTAssertNil(model.failure)
            XCTAssertTrue(model.canEdit)
        }
        let missing = NotificationsSettingsModel(deviceID: nil, api: nil)
        await missing.load()
        XCTAssertEqual(missing.failure, .noServer)
    }

    func testURLValidationAllowsDisabledBlankAndSelfHostedHTTP() async {
        let api = BarkSettingsStub()
        let model = NotificationsSettingsModel(deviceID: UUID(), api: api)
        await model.load()
        await model.save(locale: english)
        XCTAssertEqual(api.writes.count, 1)
        model.draft.enabled = true
        for invalid in ["", "file:///key", "https://", "bark.example/key"] {
            model.draft.pushUrl = invalid
            await model.save(locale: english)
            XCTAssertEqual(model.failure, .invalidURL)
        }
        XCTAssertEqual(api.writes.count, 1)
        model.draft.pushUrl = "http://192.0.2.1:8080/custom/key"
        await model.save(locale: english)
        XCTAssertNil(model.failure)
        XCTAssertEqual(api.writes.count, 2)
        XCTAssertEqual(BarkNotificationSettings.language(for: Locale(identifier: "fr_FR")), "en")
    }

    func testLoadingAndSavingRejectOverlapsAndOtherProfileStaysIsolated() async {
        let firstID = UUID(), secondID = UUID()
        let firstAPI = BarkSettingsStub(settings: .configured)
        let secondAPI = BarkSettingsStub()
        let first = NotificationsSettingsModel(deviceID: firstID, api: firstAPI)
        let second = NotificationsSettingsModel(deviceID: secondID, api: secondAPI)
        let loadGate = BarkOperationGate()
        firstAPI.loadGate = loadGate
        let load = Task { await first.load() }
        await loadGate.waitUntilEntered()
        XCTAssertEqual(first.operation, .loading)
        await first.load()
        await first.save(locale: english)
        await first.test(locale: english)
        XCTAssertEqual(firstAPI.events, ["load"])
        loadGate.release()
        await load.value

        let saveGate = BarkOperationGate()
        firstAPI.saveGate = saveGate
        first.draft.includePreview = true
        let save = Task { await first.save(locale: chinese) }
        await saveGate.waitUntilEntered()
        XCTAssertEqual(first.operation, .saving)
        XCTAssertFalse(first.canEdit)
        await first.save(locale: english)
        await first.test(locale: english)
        await second.load()
        saveGate.release()
        await save.value
        XCTAssertEqual(firstAPI.writes.count, 1)
        XCTAssertEqual(firstAPI.writes.first?.0, firstID)
        XCTAssertTrue(firstAPI.testedIDs.isEmpty)
        XCTAssertEqual(secondAPI.loadedIDs, [secondID])
        XCTAssertEqual(second.draft, BarkNotificationSettings())
        XCTAssertTrue(secondAPI.writes.isEmpty)
    }
}

private extension BarkNotificationSettings {
    static var configured: Self {
        Self(enabled: true, pushUrl: "https://api.day.app/test-key", includePreview: false, language: "en")
    }
}

/// Continuation barriers make overlap and acknowledgement assertions deterministic.
@MainActor
private final class BarkOperationGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { continuation in
            completion = continuation
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() { completion?.resume(); completion = nil }
}

@MainActor
private final class BarkSettingsStub: BarkNotificationAPI {
    var settings: BarkNotificationSettings
    var normalized: BarkNotificationSettings?
    var loadError: Error?, saveError: Error?, testError: Error?
    var loadGate: BarkOperationGate?, saveGate: BarkOperationGate?, testGate: BarkOperationGate?
    var loadedIDs: [UUID] = []
    var writes: [(UUID, BarkNotificationSettings)] = []
    var testedIDs: [UUID] = []
    var events: [String] = []

    init(settings: BarkNotificationSettings = .init()) { self.settings = settings }

    func barkNotificationSettings(deviceID: UUID) async throws -> BarkNotificationSettings {
        loadedIDs.append(deviceID)
        events.append("load")
        await loadGate?.hold()
        if let loadError { throw loadError }
        return settings
    }

    func setBarkNotificationSettings(deviceID: UUID, settings: BarkNotificationSettings) async throws -> BarkNotificationSettings {
        writes.append((deviceID, settings))
        events.append("save")
        await saveGate?.hold()
        if let saveError { throw saveError }
        self.settings = normalized ?? settings
        return self.settings
    }

    func testBarkNotification(deviceID: UUID) async throws {
        testedIDs.append(deviceID)
        events.append("test")
        await testGate?.hold()
        if let testError { throw testError }
    }
}

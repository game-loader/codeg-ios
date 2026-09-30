import Foundation
import Observation

protocol BarkNotificationAPI: Sendable {
    func barkNotificationSettings(deviceID: UUID) async throws -> BarkNotificationSettings
    func setBarkNotificationSettings(deviceID: UUID, settings: BarkNotificationSettings) async throws -> BarkNotificationSettings
    func testBarkNotification(deviceID: UUID) async throws
}

extension CodegClient: BarkNotificationAPI {}

@MainActor
@Observable
final class NotificationsSettingsModel {
    enum Operation: Equatable { case loading, saving, testing }
    enum Failure: String {
        case noServer = "Select a server and check its connection settings."
        case offline = "Could not reach the server. Check your connection and retry."
        case unauthorized = "Authentication failed. Check the server token and retry."
        case unsupported = "Update the server to a version that supports Bark notifications, then retry."
        case invalidURL = "Enter a valid HTTP or HTTPS Bark URL."
        case unsaved = "Save your changes before sending a test notification."
        case request = "Notification request failed. Check the Bark URL and server, then retry."
    }

    var draft = BarkNotificationSettings() {
        didSet { notice = nil }
    }
    private(set) var saved: BarkNotificationSettings?
    private(set) var operation: Operation?
    private(set) var failure: Failure?
    private(set) var notice: String?

    // Immutable scope: a new profile/endpoint gets a new view and model. An
    // outstanding operation can only update its original model and server.
    private let deviceID: UUID?
    private let selectedServerName: String?
    private let api: (any BarkNotificationAPI)?

    init(deviceID: UUID?, selectedServerName: String? = nil, api: (any BarkNotificationAPI)?) {
        self.deviceID = deviceID
        self.selectedServerName = selectedServerName
        self.api = api
    }

    var isBusy: Bool { operation != nil }
    var canEdit: Bool { saved != nil && !isBusy }
    var hasUnsavedChanges: Bool { saved != draft }
    var canTest: Bool { canEdit && !hasUnsavedChanges && !draft.pushUrl.isEmpty }

    func load() async {
        guard !isBusy, saved == nil else { return }
        guard let api, let deviceID else { failure = .noServer; return }
        operation = .loading
        failure = nil
        defer { operation = nil }
        do {
            let settings = try await api.barkNotificationSettings(deviceID: deviceID)
            draft = settings
            saved = settings
            // Prefill only on the initial successful load, without registering
            // or silently saving the subscription (including its other fields).
            if Self.normalizedSourceName(settings.sourceName ?? "").isEmpty,
               let selectedServerName {
                let name = Self.normalizedSourceName(selectedServerName)
                if !name.isEmpty { draft.sourceName = name }
            }
        } catch { failure = Self.failure(for: error) }
    }

    func save(locale: Locale) async {
        guard canEdit, let api, let deviceID else { return }
        var settings = draft
        settings.pushUrl = settings.pushUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.sourceName = settings.sourceName.map(Self.normalizedSourceName)
        guard Self.isValid(settings) else { failure = .invalidURL; return }
        settings.language = BarkNotificationSettings.language(for: locale)
        operation = .saving
        failure = nil
        notice = nil
        defer { operation = nil }
        do {
            let normalized = try await api.setBarkNotificationSettings(deviceID: deviceID, settings: settings)
            draft = normalized
            saved = normalized
            notice = "Notification settings saved."
        } catch { failure = Self.failure(for: error) }
    }

    func test(locale: Locale) async {
        guard canEdit, let api, let deviceID else { return }
        guard !hasUnsavedChanges else { failure = .unsaved; return }
        guard !draft.pushUrl.isEmpty, Self.isValid(draft) else { failure = .invalidURL; return }
        operation = .testing
        failure = nil
        notice = nil
        defer { operation = nil }
        do {
            // The test endpoint takes only deviceId. Persist the current app
            // language first if it changed, without silently saving user edits.
            var settings = draft
            settings.language = BarkNotificationSettings.language(for: locale)
            if settings != saved {
                let normalized = try await api.setBarkNotificationSettings(deviceID: deviceID, settings: settings)
                draft = normalized
                saved = normalized
            }
            try await api.testBarkNotification(deviceID: deviceID)
            notice = "Test notification sent."
        } catch { failure = Self.failure(for: error) }
    }

    private static func normalizedSourceName(_ value: String) -> String {
        let singleLine = value.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var name = String(singleLine.prefix(80))
        // Also fit validators that count UTF-16 units, without splitting a
        // composed character or an emoji at the limit.
        while name.utf16.count > 80 { name.removeLast() }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValid(_ settings: BarkNotificationSettings) -> Bool {
        if settings.pushUrl.isEmpty { return !settings.enabled }
        guard let url = URLComponents(string: settings.pushUrl),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.url != nil else { return false }
        return true
    }

    private static func failure(for error: Error) -> Failure {
        // Never display raw backend/transport errors: either can echo the URL
        // (including the Bark device key).
        guard let error = error as? APIError else {
            return error is URLError ? .offline : .request
        }
        switch error {
        case .unauthorized: return .unauthorized
        case .transport: return .offline
        case .decoding: return .unsupported
        case .server(let status, _, _, _) where [404, 405, 501].contains(status): return .unsupported
        default: return .request
        }
    }
}

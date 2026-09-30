import Foundation

/// Stored on the selected server, keyed by the saved ServerProfile UUID.
/// `pushUrl` contains a credential; never log it or persist it on device.
struct BarkNotificationSettings: Codable, Equatable, Sendable {
    var enabled = false
    var pushUrl = ""
    var includePreview = false
    var language = "en"
    /// Preserve server-browser settings when editing the same subscription.
    var serverUrl: String?

    // Keep Url (not URL): both camelCase and the shared snake-case decoder
    // resolve to this spelling.
    static func language(for locale: Locale) -> String {
        locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
    }
}

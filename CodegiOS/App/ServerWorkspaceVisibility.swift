import SwiftUI

private struct ServerWorkspaceVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var serverWorkspaceVisible: Bool {
        get { self[ServerWorkspaceVisibilityKey.self] }
        set { self[ServerWorkspaceVisibilityKey.self] = newValue }
    }
}

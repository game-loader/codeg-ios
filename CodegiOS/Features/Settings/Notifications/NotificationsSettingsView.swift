import SwiftUI

struct NotificationsSettingsView: View {
    @State private var model: NotificationsSettingsModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.locale) private var locale

    init(selectedServerID: UUID?, client: CodegClient?) {
        _model = State(initialValue: NotificationsSettingsModel(deviceID: selectedServerID, api: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 22) {
                    EditorSection(title: "Bark") {
                        Toggle("Enable notifications", isOn: $model.draft.enabled)
                            .padding(16)
                        SettingsRowDivider()
                        FieldRow(label: "Bark URL") {
                            SecretField(placeholder: "https://api.day.app/<key>", text: $model.draft.pushUrl)
                                .keyboardType(.URL)
                                .privacySensitive()
                                .accessibilityLabel("Bark URL")
                        }
                        SettingsRowDivider()
                        Toggle("Include reply preview", isOn: $model.draft.includePreview)
                            .padding(16)
                    }
                    .disabled(!model.canEdit)

                    if let failure = model.failure {
                        Text(LocalizedStringKey(failure.rawValue))
                            .font(.callout)
                            .foregroundStyle(Theme.danger)
                    }
                    if model.saved == nil, !model.isBusy {
                        Button("Retry") { Task { await model.load() } }
                    }
                    if model.isBusy { ProgressView() }

                    Button("Save") { Task { await model.save(locale: locale) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canEdit)
                    Button("Test Notification") { Task { await model.test(locale: locale) } }
                        .buttonStyle(.bordered)
                        .disabled(!model.canTest)
                    if model.saved != nil, model.hasUnsavedChanges {
                        Text("Save your changes before sending a test notification.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let notice = model.notice {
                        Text(LocalizedStringKey(notice))
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .screenTitle("Notifications", compact: horizontalSizeClass == .compact)
        .task { await model.load() }
    }
}

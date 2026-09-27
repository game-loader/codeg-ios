import SwiftUI

/// A tinted card carrying an error or a status note, with optional content
/// below the message (a login link, a retry button).
struct NoticeCard<Accessory: View>: View {
    enum Tone { case error, warning, info }

    let tone: Tone
    let title: LocalizedStringKey?
    let message: String
    @ViewBuilder var accessory: () -> Accessory

    init(tone: Tone, title: LocalizedStringKey? = nil, message: String,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.tone = tone
        self.title = title
        self.message = message
        self.accessory = accessory
    }

    private var color: Color {
        switch tone {
        case .error: Theme.danger
        case .warning: Theme.warning
        case .info: Theme.textSecondary
        }
    }

    private var symbol: String {
        switch tone {
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                // Server text: shown as is, never parsed as Markdown.
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: color.opacity(0.30))
    }
}

/// A small filled (or hollow, for "unknown") status dot.
struct StatusDot: View {
    let color: Color
    var hollow = false

    var body: some View {
        Group {
            if hollow {
                Circle().strokeBorder(color, lineWidth: 1.5)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 8, height: 8)
    }
}

/// A caption label over a value, for detail grids.
struct LabeledValue: View {
    let label: LocalizedStringKey
    let value: String?
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.textTertiary)
            Group {
                if let value, !value.isEmpty {
                    Text(verbatim: value)
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Text("Unknown")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(monospaced ? .footnote.monospaced() : .subheadline)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

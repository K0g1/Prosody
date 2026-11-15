import SwiftUI

struct SettingsPageHeader: View {
    @Environment(\.prosodyPalette) private var palette
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 25, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsGroupTitle: View {
    @Environment(\.prosodyPalette) private var palette
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(palette.secondary)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .prosodyPanel(padding: 0)
    }
}

struct SettingsRow<Trailing: View>: View {
    @Environment(\.prosodyPalette) private var palette
    let title: String
    let detail: String?
    let accessibilityID: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityIdentifier(accessibilityID)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

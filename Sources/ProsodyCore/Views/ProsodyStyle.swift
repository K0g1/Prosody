import SwiftUI

enum ProsodyDimensions {
    static let popoverWidth: CGFloat = 368
    static let popoverCornerRadius: CGFloat = 16
    static let rowCornerRadius: CGFloat = 11
}

struct ProsodyPanelModifier: ViewModifier {
    @Environment(\.prosodyPalette) private var palette
    var cornerRadius: CGFloat = ProsodyDimensions.rowCornerRadius
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(palette.text.opacity(0.12), lineWidth: 1)
            }
    }
}

extension View {
    func prosodyPanel(cornerRadius: CGFloat = ProsodyDimensions.rowCornerRadius, padding: CGFloat = 12) -> some View {
        modifier(ProsodyPanelModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

struct ProsodyMarkView: View {
    var body: some View {
        Image(nsImage: MenuBarIconView.artwork)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

struct ProsodyLogoView: View {
    @Environment(\.prosodyPalette) private var palette
    var size: CGFloat = 40
    var prominent = false

    var body: some View {
        ProsodyMarkView()
            .frame(width: size * 0.66, height: size * 0.66)
            .foregroundStyle(palette.accent)
            .frame(width: size, height: size)
            .background(
                prominent ? palette.accent.opacity(0.10) : palette.text.opacity(0.07),
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(
                        prominent ? palette.accent.opacity(0.35) : palette.text.opacity(0.12),
                        lineWidth: 1
                    )
            }
            .accessibilityLabel(AppConstants.applicationName)
    }
}

struct ProsodyStatusDot: View {
    @Environment(\.prosodyPalette) private var palette
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(palette.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

struct ProsodyHeaderView: View {
    @Environment(\.prosodyPalette) private var palette
    let status: RecordingState
    var title: String = AppConstants.applicationName
    var trailing: AnyView?
    var showsBranding: Bool

    init(status: RecordingState, title: String = AppConstants.applicationName, trailing: AnyView? = nil, showsBranding: Bool = true) {
        self.status = status
        self.title = title
        self.trailing = trailing
        self.showsBranding = showsBranding
    }

    var body: some View {
        HStack(spacing: 12) {
            if showsBranding {
                ProsodyLogoView(size: 40, prominent: status == .idle)
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            if let trailing {
                trailing
            } else {
                ProsodyStatusView(state: status)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clippy.menu.header")
    }
}

struct ProsodyStatusView: View {
    @Environment(\.prosodyPalette) private var palette
    let state: RecordingState

    private var color: Color {
        switch state {
        case .recording: return .primary
        case .paused: return .secondary
        case .completed: return .primary
        case .failed: return .primary
        case .preparing, .stopping, .finalizingTranscript, .diarizing, .generatingNotes: return .secondary
        case .idle: return .primary
        }
    }

    private var title: String {
        switch state {
        case .recording, .paused: return state.statusTitle
        default: return state.statusTitle
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(palette.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(title)")
    }
}

struct ProsodyPrimaryButtonStyle: ButtonStyle {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(prominent ? palette.onAccent : palette.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                prominent ? AnyShapeStyle(palette.accentGradient) : AnyShapeStyle(palette.accent.opacity(0.10)),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.80 : 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ProsodySecondaryButtonStyle: ButtonStyle {
    @Environment(\.prosodyPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(palette.text.opacity(0.12), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ProsodyFooterView: View {
    @Environment(\.prosodyPalette) private var palette
    let openTranscript: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: openTranscript) {
                Label("Transcripts", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .accessibilityIdentifier("clippy.open-transcript")

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 14)

            Button { AppWindowController.shared.showSettings() } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .accessibilityIdentifier("clippy.open-settings")

            Spacer(minLength: 0)
            Button { AppWindowController.shared.importFile() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help("Transcribe Audio File")
            .accessibilityLabel("Transcribe Audio File")
            .accessibilityIdentifier("clippy.import-file")
        }
        .padding(.top, 2)
    }
}

struct ProsodySectionTitle: View {
    @Environment(\.prosodyPalette) private var palette
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

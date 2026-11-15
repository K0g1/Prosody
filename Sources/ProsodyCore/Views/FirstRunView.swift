import SwiftUI

/// A standalone first-run surface that can be presented by the future
/// permission coordinator without changing the menu-bar or settings scenes.
public struct FirstRunView: View {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject public var model: AppModel
    public let finish: () -> Void

    public init(model: AppModel, finish: @escaping () -> Void = {}) {
        self.model = model
        self.finish = finish
    }

    public var body: some View {
        VStack(spacing: 22) {
            ProsodyLogoView(size: 72, prominent: true)
            VStack(spacing: 7) {
                Text("Welcome to \(AppConstants.applicationName)")
                    .font(.system(size: 26, weight: .semibold))
                Text("Capture conversations, lectures, and meetings from your menu bar.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(title: "System audio", detail: "Capture audio playing on your Mac.", systemImage: "speaker.wave.2")
                PermissionRow(title: "Microphone", detail: "Keep your voice separate when using System + Mic.", systemImage: "mic")
                PermissionRow(title: "Output folder", detail: "Save transcripts and notes where you choose.", systemImage: "folder")
            }
            .prosodyPanel()

            Button {
                finish()
            } label: {
                Text("Set Up \(AppConstants.applicationName)")
            }
            .buttonStyle(ProsodyPrimaryButtonStyle())
            .accessibilityIdentifier("clippy.first-run.setup")
        }
        .padding(34)
        .frame(width: 440)
        .background(palette.sidebar.opacity(0.9))
        .accessibilityIdentifier("clippy.first-run")
    }
}

private struct PermissionRow: View {
    @Environment(\.prosodyPalette) private var palette
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
            }
        }
    }
}

import AppKit
import SwiftUI

/// Visible setup surface used when the app is launched specifically to ask
/// for capture permissions. Keeping this in a normal window makes the system
/// consent sheets discoverable even though the production app is an LSUIElement.
public struct PermissionRequestView: View {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject public var model: AppModel
    @State private var requesting = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 20) {
            ProsodyLogoView(size: 68, prominent: true)
            VStack(spacing: 7) {
                Text("Set Up \(AppConstants.applicationName)")
                    .font(.system(size: 25, weight: .semibold))
                Text("Allow \(AppConstants.applicationName) to capture the sources you selected in Audio settings.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 13) {
                PermissionRequestRow(
                    title: "System audio",
                    detail: "Screen Recording permission",
                    systemImage: "speaker.wave.2"
                )
                PermissionRequestRow(
                    title: "Microphone",
                    detail: "Microphone permission",
                    systemImage: "mic"
                )
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button(requesting ? "Requesting…" : "Request Permissions") {
                requesting = true
                Task { @MainActor in
                    await model.requestPermissionsForCurrentCaptureMode()
                    requesting = false
                }
            }
            .buttonStyle(ProsodyPrimaryButtonStyle())
            .disabled(requesting)
            .accessibilityIdentifier("clippy.permissions.request")

            if let notice = model.lastNotice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clippy.permissions.status")
            }

            Text("You can change these choices later in System Settings → Privacy & Security.")
                .font(.system(size: 11))
                .foregroundStyle(palette.secondary.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(width: 430)
        .background(palette.surface.opacity(0.42))
        .accessibilityIdentifier("clippy.permissions.window")
    }
}

private struct PermissionRequestRow: View {
    @Environment(\.prosodyPalette) private var palette
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 25)
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

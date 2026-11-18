import AppKit
import OSLog
import SwiftUI

@MainActor
public struct MenuBarIconView: View {
    // Reused by the in-app mark so every surface has the same cached artwork.
    static let artwork: NSImage = {
        if let url = ProsodyResources.url(named: "ProsodyMenuBar.svg"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        AppLogger.app.warning("Missing or invalid bundled ProsodyMenuBar.svg; using a system icon.")
        return NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 18, height: 18))
    }()

    private static let idleImage = makeStatusImage(recording: false)
    private static let recordingImage = makeStatusImage(recording: true)

    static func statusImage(recording: Bool) -> NSImage {
        recording ? recordingImage : idleImage
    }

    private static func makeStatusImage(recording: Bool) -> NSImage {
        let artwork = artwork
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            artwork.draw(in: NSRect(x: 0.5, y: 0.5, width: 17, height: 17))
            if recording {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: 13, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? "Prosody, Recording" : "Prosody, Ready"
        return image
    }
    public let state: RecordingState

    public init(state: RecordingState) {
        self.state = state
    }

    public var body: some View {
        Image(nsImage: Self.statusImage(recording: state == .recording))
            .renderingMode(.original)
            .frame(width: 18, height: 18)
            .accessibilityLabel("Prosody, \(state.statusTitle)")
            .accessibilityIdentifier("clippy.menu-bar-icon")
    }
}

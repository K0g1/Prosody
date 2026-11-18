import AVFoundation

@MainActor
enum MicrophonePermission {
    static var isGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        // Use AVFoundation's async overlay. TCC calls the callback API on a
        // private queue, so a closure inherited from MainActor can trap.
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

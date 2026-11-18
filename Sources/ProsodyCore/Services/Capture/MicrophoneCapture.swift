@preconcurrency import AVFoundation
import Foundation

/// Native audio-only capture, so dictation and microphone recordings never
/// enumerate displays or require Screen & System Audio Recording access.
final class MicrophoneCapture: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let controlQueue = DispatchQueue(label: "com.openai.clippy.capture.microphone-control", qos: .userInitiated)
    let output = AVCaptureAudioDataOutput()
    private var observers: [NSObjectProtocol] = []

    init(
        deviceID: String?,
        delegate: any AVCaptureAudioDataOutputSampleBufferDelegate,
        sampleQueue: DispatchQueue,
        failed: @escaping @Sendable (ObjectIdentifier, ScreenCaptureCoordinatorError) -> Void
    ) throws {
        let selected = deviceID.flatMap(AVCaptureDevice.init(uniqueID:))
        guard let device = selected ?? AVCaptureDevice.default(for: .audio) else {
            throw ScreenCaptureCoordinatorError.startFailed("No microphone is available.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw ScreenCaptureCoordinatorError.startFailed("Could not connect the microphone.")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            throw ScreenCaptureCoordinatorError.startFailed("Could not configure microphone audio.")
        }
        output.setSampleBufferDelegate(delegate, queue: sampleQueue)
        session.addOutput(output)

        let outputID = ObjectIdentifier(output)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            failed(outputID, .startFailed(error?.localizedDescription ?? "Microphone capture stopped unexpectedly."))
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in
            failed(outputID, .startFailed("Microphone capture was interrupted."))
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            controlQueue.async { [self] in
                session.startRunning()
                if session.isRunning {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ScreenCaptureCoordinatorError.startFailed("Could not start microphone capture."))
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlQueue.async { [self] in
                session.stopRunning()
                continuation.resume()
            }
        }
    }
}

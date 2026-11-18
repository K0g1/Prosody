import Foundation

/// Resolve staged app resources and the SwiftPM command-line/test layout.
/// The generated Bundle.module lookup assumes a different .app layout and
/// falls back to a machine-specific build path.
enum ProsodyResources {
    static func url(named name: String) -> URL? {
        let main = Bundle.main
        for directory in [main.resourceURL, main.bundleURL].compactMap({ $0 }) {
            let candidates = [
                directory.appendingPathComponent(name),
                directory.appendingPathComponent("Prosody_ProsodyCore.bundle").appendingPathComponent(name)
            ]
            if let found = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) {
                return found
            }
        }
        #if DEBUG
        // Test runners may load ProsodyCore without setting Bundle.main to
        // the package executable. SwiftPM owns this build-only fallback.
        if main.bundleURL.pathExtension != "app" {
            return Bundle.module.url(forResource: name, withExtension: nil)
        }
        #endif
        return nil
    }
}

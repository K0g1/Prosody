import CryptoKit
import Foundation

/// Only the pinned Core ML assets required by each adapter are downloaded.
struct SpeechModelPackage: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String?
    }

    let repository: String
    let revision: String
    let files: [Asset]

    private static let packages: [String: Self] = {
        guard let url = ProsodyResources.url(named: "SpeechModelPackages.json"),
              let data = try? Data(contentsOf: url),
              let packages = try? JSONDecoder().decode([String: Self].self, from: data) else { return [:] }
        return packages
    }()

    static func package(for model: SpeechModel) -> Self? { packages[model.rawValue] }

    func isComplete(at directory: URL) -> Bool {
        files.allSatisfy { asset in
            let values = try? directory.appendingPathComponent(asset.path)
                .resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && values?.fileSize.map(Int64.init) == asset.bytes
        }
    }

    func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let total = files.reduce(Int64.zero) { $0 + $1.bytes }
        var completed: Int64 = 0
        for asset in files {
            try Task.checkCancellation()
            let url = URL(string: "https://huggingface.co")!
                .appending(path: repository).appending(path: "resolve")
                .appending(path: revision).appending(path: asset.path)
            let downloadProgress = DownloadProgress(completed: completed, total: total, report: progress)
            let (temporary, response) = try await session.download(for: URLRequest(url: url), delegate: downloadProgress)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let fileSize = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(fileSize) == asset.bytes else {
                throw STTModelManagerError.downloadFailed("The download for \(asset.path) was incomplete.")
            }
            if let expected = asset.sha256, try Self.sha256(of: temporary) != expected {
                throw STTModelManagerError.downloadFailed("The integrity check for \(asset.path) failed.")
            }
            let destination = directory.appendingPathComponent(asset.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: destination)
            completed += asset.bytes
            progress(Double(completed) / Double(total))
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let completed: Int64
    let total: Int64
    let report: @Sendable (Double) -> Void

    init(completed: Int64, total: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.completed = completed
        self.total = total
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(Double(completed + totalBytesWritten) / Double(total))
    }
}

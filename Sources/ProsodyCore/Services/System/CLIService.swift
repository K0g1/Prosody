import AppKit
import Darwin
import Network
import ProsodyIPC

@MainActor
final class CLIService {
    private let queue = DispatchQueue(label: "prosody.cli")
    private var listener: NWListener?
    private var lockDescriptor: Int32 = -1
    private var connections: [UUID: NWConnection] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]

    var installationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/prosody")
    }

    private var bundledExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/prosody")
    }

    func install(previousTarget: String?) throws {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: bundledExecutable.path) else {
            throw UserFacingError(title: "CLI unavailable", message: "Use the packaged Prosody app to install the CLI.")
        }
        try manager.createDirectory(at: installationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let destination = try? manager.destinationOfSymbolicLink(atPath: installationURL.path) {
            if destination == bundledExecutable.path { return }
            if destination == previousTarget { try manager.removeItem(at: installationURL) }
        }
        try manager.createSymbolicLink(at: installationURL, withDestinationURL: bundledExecutable)
    }

    func uninstall(target: String?) throws {
        let manager = FileManager.default
        if let target, (try? manager.destinationOfSymbolicLink(atPath: installationURL.path)) == target {
            try manager.removeItem(at: installationURL)
        }
    }

    var currentTarget: String { bundledExecutable.path }

    func start(model: AppModel) throws {
        guard listener == nil else { return }
        let directory = try CLISocket.directory()
        let socketURL = try CLISocket.socketURL()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard values.isDirectory == true, values.isSymbolicLink != true,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw UserFacingError(title: "Could not start CLI", message: "The local CLI socket directory is not private.")
        }
        // A stale socket can remain after a crash. Hold an OS-owned lock so
        // neither a second app instance nor a restarted listener unlinks a live socket.
        let lockPath = directory.appendingPathComponent("listener.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw UserFacingError(title: "CLI in use", message: "The command-line tool is already running in another Prosody instance.")
        }
        defer { if lockDescriptor != descriptor { close(descriptor) } }
        if let socket = try? manager.attributesOfItem(atPath: socketURL.path) {
            guard socket[.type] as? FileAttributeType == .typeSocket else { throw CocoaError(.fileWriteFileExists) }
            try manager.removeItem(at: socketURL)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = try CLISocket.endpoint()
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, weak model, weak listener] state in
            if case .failed(let error) = state {
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    self.stop()
                    model?.userFacingError = UserFacingError(title: "Could not start CLI", message: error.localizedDescription)
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak model] connection in
            Task { @MainActor in
                guard let self, let model, model.preferences.cliEnabled else { connection.cancel(); return }
                self.accept(connection, model: model)
            }
        }
        self.listener = listener
        lockDescriptor = descriptor
        listener.start(queue: queue)
    }

    func stop() {
        guard listener != nil else { return }
        listener?.cancel()
        listener = nil
        for job in jobs.values { job.cancel() }
        for connection in connections.values { connection.cancel() }
        jobs.removeAll()
        connections.removeAll()
        if let path = try? CLISocket.socketURL() { try? FileManager.default.removeItem(at: path) }
        if lockDescriptor >= 0 {
            close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    private func accept(_ connection: NWConnection, model: AppModel) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.disconnect(id) }
            default: break
            }
        }
        connection.start(queue: queue)
        CLISocket.receive(CLIRequest.self, on: connection, limit: CLISocket.requestLimit) { [weak self, weak model] result in
            Task { @MainActor in
                guard let self, let model, self.connections[id] != nil else { connection.cancel(); return }
                // Keep the connection open until the client reads the
                // response. contentProcessed only confirms a local send.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                    Task { @MainActor in self?.disconnect(id) }
                }
                guard case .success(let request) = result else {
                    self.reply(CLIResponse(error: "Invalid CLI request."), to: id)
                    return
                }
                self.jobs[id] = Task {
                    let response = await model.runFileAutomation(request)
                    if !Task.isCancelled { self.reply(response, to: id) }
                }
            }
        }
    }

    private func reply(_ response: CLIResponse, to id: UUID) {
        guard let connection = connections[id] else { return }
        do {
            try CLISocket.send(response, on: connection, limit: CLISocket.responseLimit) { [weak self] error in
                if error != nil { Task { @MainActor in self?.disconnect(id) } }
            }
        } catch {
            disconnect(id)
        }
    }

    private func disconnect(_ id: UUID) {
        jobs.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}

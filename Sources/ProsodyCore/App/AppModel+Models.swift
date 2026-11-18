import AppKit

extension AppModel {
    public var selectedSpeechModel: SpeechModel {
        SpeechModel(rawValue: preferences.sttModelID) ?? .unified
    }

    var canManageModelSelection: Bool {
        canBrowseSessions && dictation.canChangeRecognitionModel
    }

    public func refreshModelInventory() async {
        let inventory = await modelManager.inventory()
        installedModelIDs = inventory.installed
        modelStorageUsedBytes = inventory.storedBytes
        cachedModelIDs = inventory.cached
    }

    public func revealModelsFolder() async {
        do {
            let directory = try await modelManager.createModelsDirectory()
            NSWorkspace.shared.open(directory)
        } catch {
            userFacingError = UserFacingError(title: "Could not open Models folder", message: error.localizedDescription)
        }
    }

    func startModelDownload(_ model: SpeechModel) {
        guard modelDownloadTask == nil else { return }
        modelDownloadTask = Task { [weak self] in
            await self?.installModel(model.descriptor)
            self?.modelDownloadTask = nil
        }
    }

    func cancelModelDownload() { modelDownloadTask?.cancel() }

    public func installModel(_ descriptor: STTModelDescriptor) async {
        guard modelDownloadingID == nil, let speechModel = SpeechModel(descriptor: descriptor) else { return }
        modelDownloadingID = descriptor.id
        modelDownloadProgress = 0
        userFacingError = nil
        lastNotice = nil
        defer {
            modelDownloadingID = nil
            modelDownloadProgress = 0
        }

        do {
            try await modelManager.install(descriptor) { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.modelDownloadingID == descriptor.id else { return }
                    self.modelDownloadProgress = max(self.modelDownloadProgress, min(max(value, 0), 1))
                }
            }
            await refreshModelInventory()
            if canManageModelSelection {
                if !installedModelIDs.contains(selectedSpeechModel.rawValue) {
                    await selectSpeechModel(speechModel)
                } else if selectedSpeechModel == speechModel, !demoMode {
                    dictation.prewarmRecognition()
                }
            }
            lastNotice = "\(descriptor.displayName) is ready."
        } catch {
            if !Task.isCancelled && !(error is CancellationError) {
                userFacingError = UserFacingError(title: "Model download failed", message: error.localizedDescription)
            }
            await refreshModelInventory()
        }
    }

    public func selectSpeechModel(_ speechModel: SpeechModel) async {
        guard canManageModelSelection, selectedSpeechModel != speechModel else { return }
        isTransitioning = true
        defer {
            isTransitioning = false
            if preferences.sttModelID == speechModel.rawValue, !demoMode { dictation.prewarmRecognition() }
        }
        guard await modelManager.isInstalled(speechModel.descriptor) else {
            userFacingError = UserFacingError(title: "Model unavailable", message: STTModelManagerError.modelNotFound.localizedDescription)
            await refreshModelInventory()
            return
        }
        preferences.sttModelID = speechModel.rawValue
        userFacingError = nil
        lastNotice = nil
        await dictation.selectRecognitionModel(speechModel, inventory: modelManager)
    }

    public func removeModel(_ descriptor: STTModelDescriptor) async {
        guard canManageModelSelection, modelDownloadingID != descriptor.id,
              let speechModel = SpeechModel(descriptor: descriptor) else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        do {
            if selectedSpeechModel == speechModel {
                let inventory = await modelManager.inventory()
                let replacement = SpeechModel.allCases.first { $0 != speechModel && inventory.installed.contains($0.rawValue) }
                let next = replacement ?? .unified
                await dictation.selectRecognitionModel(next, inventory: modelManager)
                preferences.sttModelID = next.rawValue
            }
            try await modelManager.remove(descriptor)
            userFacingError = nil
            lastNotice = "\(descriptor.displayName) deleted."
        } catch {
            userFacingError = UserFacingError(title: "Could not delete model", message: error.localizedDescription)
        }
        await refreshModelInventory()
    }

    func transcribeAudio(files: [AudioSource: [URL]], session: RecordingSession,
                         configuration: TranscriptSegmentationConfiguration) async throws -> AudioFileTranscription {
        guard session.sttEngineID == .parakeet, let model = SpeechModel(rawValue: session.sttModelID) else {
            throw STTError.unsupportedModel(session.sttModelID)
        }
        return try await AudioFileTranscriber(segmentationConfiguration: configuration, inventory: modelManager)
            .transcribe(files: files, speakerMode: session.speakerMode, model: model)
    }
}

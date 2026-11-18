extension AppModel {
    func importPreferences(_ archive: PreferenceArchive) async throws -> Int {
        guard canManageModelSelection, !isCompressingAudio else {
            throw UserFacingError(title: "Prosody is busy", message: "Finish the current audio work and try importing preferences again.")
        }
        isTransitioning = true
        let previousModel = selectedSpeechModel
        defer {
            isTransitioning = false
            if !demoMode, previousModel != selectedSpeechModel { dictation.prewarmRecognition() }
        }
        let count = try preferences.importSettings(archive)
        if selectedSpeechModel != previousModel {
            await dictation.selectRecognitionModel(selectedSpeechModel, inventory: modelManager)
        }
        if !demoMode {
            configureGlobalHotkey()
            dictation.configureShortcut()
        }
        reloadSessions()
        return count
    }
}

import Combine
import Foundation
import Sparkle

/// Sparkle owns the signed feed, download, installation and relaunch.
/// Prosody owns the policy for when it can safely relinquish the process.
@MainActor
final class SoftwareUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    private weak var model: AppModel?
    private var controller: SPUStandardUpdaterController?
    private var subscriptions: Set<AnyCancellable> = []
    private var deferredInstall: Task<Void, Never>?
    private var holdsRelaunchLock = false

    init(model: AppModel) { self.model = model }

    func start() {
        guard controller == nil, let model, !model.demoMode,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = model.preferences.checkForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &subscriptions)
        model.preferences.$checkForUpdates.removeDuplicates()
            .sink { [weak updater] enabled in
                if let updater, updater.automaticallyChecksForUpdates != enabled {
                    updater.automaticallyChecksForUpdates = enabled
                }
            }
            .store(in: &subscriptions)
        controller.startUpdater()
    }

    func check() {
        guard canCheck, model?.canRelaunchForUpdate == true else { return }
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard model?.canRelaunchForUpdate == false else {
            reserveRelaunch()
            return false
        }
        model?.lastNotice = "Prosody will install the update after the current audio work finishes."
        deferredInstall?.cancel()
        deferredInstall = Task { @MainActor [weak self] in
            while self?.model?.canRelaunchForUpdate == false {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.deferredInstall = nil
            self.reserveRelaunch()
            installHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if holdsRelaunchLock {
            model?.isTransitioning = false
            holdsRelaunchLock = false
        }
        deferredInstall?.cancel()
        deferredInstall = nil
    }

    private func reserveRelaunch() {
        model?.preferences.flushBeforeUpdate()
        model?.isTransitioning = true
        holdsRelaunchLock = true
    }
}

extension AppModel {
    var canRelaunchForUpdate: Bool {
        canBrowseSessions && !isCompressingAudio && modelDownloadingID == nil && !dictation.hasPendingCleanup
    }
}

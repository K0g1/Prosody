import AppKit
import Combine
import OSLog
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "app")
    private var permissionWindow: NSWindow?
    private var shortcutRefresh: AnyCancellable?
    private var privacySettingsWereActive = false
    private let showsDebugControls = ProcessInfo.processInfo.arguments.contains("--show-controls")

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // The recorder and global event tap live in this menu-bar-only process.
        // Closing Settings or Transcripts must not let macOS reclaim the
        // process, or the dictation shortcut silently stops receiving events.
        ProcessInfo.processInfo.disableAutomaticTermination("Prosody menu bar and dictation service")
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let requestPermissions = ProcessInfo.processInfo.arguments.contains("--request-permissions")
        NSApp.setActivationPolicy(showsDebugControls || requestPermissions ? .regular : .accessory)
        AppWindowController.shared.install(debugControlsEnabled: showsDebugControls)
        shortcutRefresh = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let dictation = AppModel.shared.dictation
                if self.privacySettingsWereActive || !dictation.shortcutReady { dictation.configureShortcut() }
                self.privacySettingsWereActive = app?.bundleIdentifier == "com.apple.systempreferences"
            }
        // The controller checks existing Accessibility and microphone grants,
        // demo/fixture mode, and recognition idleness before starting the
        // installed-only model flight. This call never waits for Core ML.
        AppModel.shared.dictation.prewarmRecognition()
        if showsDebugControls {
            AppWindowController.shared.showDebugRecorder()
        }
        if requestPermissions {
            showPermissionWindow()
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                // Let LaunchServices finish attaching the app bundle before
                // CoreGraphics presents the Screen Recording consent UI.
                try? await Task.sleep(for: .milliseconds(500))
                await AppModel.shared.requestPermissionsForCurrentCaptureMode()
                NSApp.setActivationPolicy(.accessory)
            }
        }
        AppModel.shared.restoreCLI()
        AppModel.shared.softwareUpdates.start()
        logger.info("Prosody launched")
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.dictation.configureShortcut()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !AppModel.shared.dictation.isActive else { return false }
        if !flag {
            if showsDebugControls {
                AppWindowController.shared.showDebugRecorder()
            } else {
                AppWindowController.shared.showRecordingControls()
            }
        }
        return flag
    }

    public func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.dictation.stopMonitoring()
        AppModel.shared.cliService.stop()
        ProcessInfo.processInfo.enableAutomaticTermination("Prosody menu bar and dictation service")
    }

    private func showPermissionWindow() {
        let rootView = PermissionRequestView(model: AppModel.shared)
        let hostingController = NSHostingController(rootView: ThemedRoot(preferences: AppModel.shared.preferences) { rootView })
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Prosody Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setContentSize(NSSize(width: 430, height: 475))
        window.center()
        window.makeKeyAndOrderFront(nil)
        permissionWindow = window
    }
}

import AppKit
import OSLog
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "app")
    private var permissionWindow: NSWindow?
    private let showsDebugControls = ProcessInfo.processInfo.arguments.contains("--show-controls")

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if !AppConstants.isDemoModeRequested {
            LegacyDataMigration.migrateIfNeeded()
        }
        let requestPermissions = ProcessInfo.processInfo.arguments.contains("--request-permissions")
        NSApp.setActivationPolicy(showsDebugControls || requestPermissions ? .regular : .accessory)
        AppWindowController.shared.install(debugControlsEnabled: showsDebugControls)
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

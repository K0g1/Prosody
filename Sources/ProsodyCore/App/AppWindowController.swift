import AppKit
import Combine
import SwiftUI

/// Owns the few imperative desktop surfaces: reusable foreground windows, a
/// status item with distinct mouse actions, and a nonactivating dictation HUD.
/// All content and recording state remain in SwiftUI/AppModel.
@MainActor
public final class AppWindowController: NSObject, NSWindowDelegate {
    public static let shared = AppWindowController()
    private var windows: [String: NSWindow] = [:]
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var debugControlsEnabled = false
    private var subscriptions: Set<AnyCancellable> = []
    private var overlay: NSPanel?
    private var model: AppModel { .shared }

    public func install(debugControlsEnabled: Bool = false) {
        self.debugControlsEnabled = debugControlsEnabled
        let item = NSStatusBar.system.statusItem(withLength: 26)
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityIdentifier("clippy.menu-bar-icon")
        statusItem = item
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ThemedRoot(preferences: model.preferences, expands: false, backdrop: .systemPopover) {
            MenuBarRootView(model: self.model)
        })
        model.preferences.$theme.removeDuplicates().sink { [weak self] theme in
            let appearance = theme.isAdaptive ? nil : NSAppearance(named: theme.palette.dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            self?.popover.appearance = appearance
        }.store(in: &subscriptions)
        model.$recordingState.combineLatest(model.dictation.$state)
            .map { state, dictation -> String? in
                if state.isRecording { return state.statusTitle }
                return dictation == .listening ? "Dictating" : nil
            }
            .removeDuplicates()
            .sink { [weak self] in self?.updateIcon(activity: $0) }
            .store(in: &subscriptions)
        model.dictation.$state.removeDuplicates()
            .combineLatest(model.preferences.$dictationOverlayAppearance.removeDuplicates())
            .sink { [weak self] state, _ in
                if state.showsOverlay {
                    // @Published emits before the mutation. Read both current
                    // values when laying out the panel on the main queue.
                    DispatchQueue.main.async { self?.updateOverlay() }
                } else {
                    self?.overlay?.orderOut(nil)
                }
            }.store(in: &subscriptions)
        installMainMenu()
        model.dictation.configureShortcut()
    }

    public func showSettings() {
        present(id: "settings", title: "\(AppConstants.applicationName) Settings", size: NSSize(width: 980, height: 740),
            minimum: NSSize(width: 980, height: 740), view: SettingsRootView(model: model), integratedChrome: true)
        model.dictation.configureShortcut()
    }

    public func showLibrary() {
        present(id: "library", title: "\(AppConstants.applicationName) Transcripts", size: NSSize(width: 1160, height: 740),
            minimum: NSSize(width: 1020, height: 600), view: TranscriptLibraryView(model: model), integratedChrome: true)
    }

    public func showRecordingControls() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func showDebugRecorder() {
        guard debugControlsEnabled else { return }
        present(id: "recorder", title: "\(AppConstants.applicationName) Recorder — Debug", size: NSSize(width: 400, height: 650),
            minimum: NSSize(width: 400, height: 500), view: ScrollView { MenuBarRootView(model: model, expands: true) })
    }

    public func importFile() {
        showLibrary()
        model.chooseTranscriptionFile()
    }

    private func present<Content: View>(id: String, title: String, size: NSSize, minimum: NSSize,
                                        view: Content, integratedChrome: Bool = false) {
        popover.performClose(nil)
        let window: NSWindow
        if let existing = windows[id] { window = existing }
        else {
            var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            if integratedChrome { styleMask.insert(.fullSizeContentView) }
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: styleMask,
                              backing: .buffered, defer: false)
            window.title = title
            window.identifier = NSUserInterfaceItemIdentifier("clippy.\(id)")
            if integratedChrome {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.titlebarSeparatorStyle = .none
                window.collectionBehavior.insert(.fullScreenPrimary)
            }
            let chrome = integratedChrome ? WindowChromeLayout(window: window) : nil
            let host = NSHostingController(rootView: ThemedRoot(preferences: model.preferences) {
                if let chrome {
                    view.environment(\.windowChromeLayout, chrome)
                        .environment(\.layoutDirection, chrome.direction)
                } else {
                    view
                }
            })
            // The sidebar and its background start at the physical top edge.
            // Only the chrome views reserve space for the native controls.
            if integratedChrome { host.safeAreaRegions = [] }
            window.contentViewController = host
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            window.setContentSize(size)
            window.contentMinSize = minimum
            window.setFrameAutosaveName("Clippy-\(id)")
            if !window.setFrameUsingName("Clippy-\(id)") { window.center() }
            windows[id] = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        // Activation can finish after the menu bar's tracking loop dismisses.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // A minimized window still needs the Dock so it can be restored.
        if !windows.values.contains(where: { $0 !== closing && ($0.isVisible || $0.isMiniaturized) }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func statusClicked() {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = NSMenu()
            add("Show \(AppConstants.applicationName)", action: #selector(recordingControlsAction), to: menu)
            if debugControlsEnabled {
                add("Show Debug Recorder", action: #selector(debugRecorderAction), to: menu)
            }
            add("Browse Transcripts…", action: #selector(libraryAction), to: menu)
            add("Transcribe Audio File…", action: #selector(importAction), to: menu, enabled: model.canBrowseSessions)
            menu.addItem(.separator())
            add(model.recordingState == .paused ? "Resume Recording" : model.recordingState == .recording ? "Pause Recording" : "Start Recording",
                action: #selector(toggleAction), to: menu, enabled: model.canToggleRecording)
            add("Finish Recording", action: #selector(finishAction), to: menu, enabled: model.canFinishRecording)
            menu.addItem(.separator())
            add("Settings…", action: #selector(settingsAction), to: menu)
            add("Quit \(AppConstants.applicationName)", action: #selector(quitAction), to: menu)
            if let event = NSApp.currentEvent {
                // Pop the menu directly from the original right-click event.
                // Assigning a temporary status-item menu and simulating a
                // second click can re-enter this action as a left click on
                // some macOS releases.
                NSMenu.popUpContextMenu(menu, with: event, for: button)
            }
        } else if popover.isShown { popover.performClose(nil) }
        else { showRecordingControls() }
    }

    private func updateIcon(activity: String?) {
        guard let button = statusItem?.button else { return }
        button.image = MenuBarIconView.statusImage(recording: activity != nil)
        button.toolTip = activity.map { "\(AppConstants.applicationName) — \($0)" } ?? AppConstants.applicationName
        button.setAccessibilityLabel("\(AppConstants.applicationName), \(activity ?? "Ready")")
    }

    private func updateOverlay() {
        let state = model.dictation.state
        guard state.showsOverlay else { return }
        let layout = DictationOverlayLayout(state: state, appearance: model.preferences.dictationOverlayAppearance)
        if overlay == nil {
            let panel = DictationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            let host = NSHostingController(rootView: DictationOverlayView(controller: model.dictation, preferences: model.preferences))
            host.sizingOptions = []
            panel.title = "\(AppConstants.applicationName) Dictation"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.contentViewController = host
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            overlay = panel
        }
        guard let overlay else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = layout.size
        overlay.ignoresMouseEvents = layout == .minimal
        overlay.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 22, width: size.width, height: size.height), display: true)
        overlay.orderFrontRegardless()
    }

    private func installMainMenu() {
        let root = NSMenu()
        let application = NSMenuItem()
        root.addItem(application)
        let menu = NSMenu(title: AppConstants.applicationName)
        application.submenu = menu
        add("About \(AppConstants.applicationName)", action: #selector(aboutAction), to: menu)
        menu.addItem(.separator())
        add("Settings…", action: #selector(settingsAction), to: menu, key: ",")
        add("Browse Transcripts…", action: #selector(libraryAction), to: menu, key: "l")
        add("Transcribe Audio File…", action: #selector(importAction), to: menu, key: "o")
        add("Show \(AppConstants.applicationName)", action: #selector(recordingControlsAction), to: menu, key: "0")
        if debugControlsEnabled {
            add("Show Debug Recorder", action: #selector(debugRecorderAction), to: menu)
        }
        menu.addItem(.separator())
        add("Quit \(AppConstants.applicationName)", action: #selector(quitAction), to: menu, key: "q")
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        root.addItem(edit)

        let viewMenu = NSMenu(title: "View")
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        root.addItem(viewItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        root.addItem(windowItem)
        NSApp.mainMenu = root
        NSApp.windowsMenu = windowMenu
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu, key: String = "", enabled: Bool = true) {
        menu.autoenablesItems = false
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
    }
    @objc private func recordingControlsAction() {
        DispatchQueue.main.async { self.showRecordingControls() }
    }
    @objc private func debugRecorderAction() { showDebugRecorder() }
    @objc private func settingsAction() { showSettings() }
    @objc private func libraryAction() { showLibrary() }
    @objc private func importAction() { importFile() }
    @objc private func toggleAction() { model.toggleRecording() }
    @objc private func finishAction() { model.finishRecording() }
    @objc private func quitAction() { NSApp.terminate(nil) }
    @objc private func aboutAction() { Self.showAboutPanel() }

    public static func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppConstants.applicationName,
            .applicationVersion: "\(AppConstants.releaseLabel) (build \(AppConstants.buildNumber))"
        ]
        if let repositoryURL = AppConstants.repositoryURL {
            let credits = NSMutableAttributedString(string: repositoryURL.absoluteString)
            credits.addAttribute(
                .link, value: repositoryURL,
                range: NSRange(location: 0, length: credits.length)
            )
            options[.credits] = credits
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

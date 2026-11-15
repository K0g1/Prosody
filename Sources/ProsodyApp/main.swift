import AppKit
import ProsodyCore

// The AppKit shell owns status-item mouse routing and foreground activation;
// every content surface is hosted SwiftUI backed by the shared AppModel.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()

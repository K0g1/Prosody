import AppIntents

struct ProsodyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: ["Start recording with \(.applicationName)"],
                    shortTitle: "Start Recording", systemImageName: "record.circle")
        AppShortcut(intent: FinishRecordingIntent(), phrases: ["Finish recording with \(.applicationName)"],
                    shortTitle: "Finish Recording", systemImageName: "stop.circle")
        AppShortcut(intent: OpenTranscriptsIntent(), phrases: ["Show my transcripts in \(.applicationName)"],
                    shortTitle: "Open Transcripts", systemImageName: "text.alignleft")
    }
}

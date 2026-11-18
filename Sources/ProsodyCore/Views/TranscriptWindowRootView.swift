import AppKit
import Combine
import SwiftUI

public struct TranscriptWindowRootView: View {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject public var model: AppModel

    @State private var searchText = ""
    @State private var showingSpeakerEditor = false
    @State private var copiedFormat = ""
    @State private var followsAudio = true
    @State private var followsAudioBeforeSearch = false
    @State private var player: SessionAudioPlayer
    @State private var playbackLoadTask: Task<Void, Never>?
    @State private var retainedAudioBytes: Int64 = 0
    @State private var audioAvailability: Bool? = nil
    @StateObject private var readerCache: TranscriptReaderCache
    @StateObject private var followController = TranscriptFollowController()

    private struct PlaybackSource: Equatable {
        let sessionID: UUID?
        let audioURLs: [URL]
        let assetRevision: Int
    }

    public init(model: AppModel) {
        self.model = model
        _readerCache = StateObject(wrappedValue: TranscriptReaderCache(transcript: model.transcript))
        _player = State(initialValue: SessionAudioPlayer(duration: 0))
    }

    private var projection: TranscriptReaderProjection { readerCache.projection }
    private var hasAudio: Bool { audioAvailability ?? !model.selectedSessionAudioURLs.isEmpty }
    private var hasSelectedSession: Bool { model.selectedSessionID != nil || model.activeSession != nil }

    private var playbackSource: PlaybackSource {
        PlaybackSource(sessionID: model.selectedSessionID, audioURLs: model.selectedSessionAudioURLs, assetRevision: model.audioAssetRevision)
    }

    public var body: some View {
        let timeline = projection.timeline
        let rows = projection.rows
        let duration = sessionDuration
        let date = sessionDate
        let title = readerTitle
        VStack(spacing: 0) {
            header(title: title, date: date, duration: duration)
            SavedRecordingLabelsView(model: model)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Divider()

            if rows.isEmpty {
                emptyState(hasAudio: hasAudio)
            } else {
                transcriptList(rows: rows, canSeekAudio: hasAudio)
            }

            Divider()
            if let notice = model.lastNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }

            TranscriptPlaybackTransport(
                player: player,
                timeline: timeline,
                followsAudio: $followsAudio,
                isSearchActive: !searchText.isEmpty
            )
            .disabled(model.isCompressingAudio)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            footer(timeline: timeline)
        }
        .background {
            TranscriptAudioClockObserver(
                player: player,
                timeline: projection.timeline,
                autoFollow: followsAudio && hasAudio,
                isSearchActive: !searchText.isEmpty,
                controller: followController
            )
        }
        .background {
            TranscriptPlaybackWindowLifecycle { player.stop() }
        }
        .sheet(isPresented: $showingSpeakerEditor) {
            SpeakerEditorView(segments: projection.timeline.segments, rename: model.renameSpeakers)
        }
        .onReceive(model.$transcript) { readerCache.update(transcript: $0) }
        .onChange(of: searchText) { oldValue, newValue in
            readerCache.updateSearch(newValue)
            let wasSearching = !oldValue.isEmpty
            let isSearching = !newValue.isEmpty
            if !wasSearching, isSearching {
                followsAudioBeforeSearch = followsAudio
                followsAudio = false
                followController.suspend()
            } else if wasSearching, !isSearching {
                if followsAudioBeforeSearch {
                    followsAudio = true
                }
                followsAudioBeforeSearch = false
            }
        }
        .onChange(of: followsAudio) { _, enabled in
            if !enabled {
                followController.suspend()
            }
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            searchText = ""
            copiedFormat = ""
            followsAudio = true
            followsAudioBeforeSearch = false
            audioAvailability = nil
            followController.suspend()
            player.load(audioURLs: [], sessionDuration: 0, bookmarkData: nil)
        }
        .onChange(of: playbackSource) { _, _ in configurePlayback() }
        .onReceive(player.audioAvailabilityPublisher.dropFirst()) { audioAvailability = $0 }
        .onAppear {
            readerCache.update(transcript: model.transcript)
            readerCache.updateSearch(searchText)
            configurePlayback()
        }
        .onDisappear {
            playbackLoadTask?.cancel()
            playbackLoadTask = nil
        }
        .onChange(of: model.isCompressingAudio) { _, value in
            if value { player.stop() }
        }
        .task(id: playbackSource) {
            retainedAudioBytes = 0
            guard let session = model.activeSession, session.id == model.selectedSessionID else { return }
            let bytes = await model.retainedAudioBytes(for: session)
            if !Task.isCancelled { retainedAudioBytes = bytes }
        }
        .task(id: copiedFormat) {
            guard !copiedFormat.isEmpty else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedFormat = ""
        }
        .accessibilityIdentifier("clippy.transcript-window")
    }

    private func header(
        title: String,
        date: Date?,
        duration: TimeInterval
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                    .help("\(title) · \(metadataText(date: date, duration: duration))")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityValue(metadataText(date: date, duration: duration))

                Text(metadataText(date: date, duration: duration))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
            searchField
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.secondary)
                .accessibilityHidden(true)
            TextField("Search transcript", text: $searchText)
                .textFieldStyle(.plain)
                .frame(width: 190)
                .help("Search transcript text and speaker names")
                .accessibilityLabel("Search transcript text and speaker names")
                .accessibilityIdentifier("clippy.transcript.search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
                .help("Clear transcript search")
                .accessibilityLabel("Clear transcript search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.text.opacity(0.08), lineWidth: 1)
        }
    }

    private func transcriptList(
        rows: [TranscriptTimelineRow],
        canSeekAudio: Bool
    ) -> some View {
        TranscriptNativeTableView(
            rows: rows,
            revision: readerCache.projectionRevision,
            canSeekAudio: canSeekAudio,
            followedRowID: followController.directive?.rowID,
            followDirective: followController.directive,
            isScrubbing: { player.isScrubbing },
            reduceMotion: reduceMotion,
            palette: palette,
            rename: model.renameSpeaker,
            seek: player.seek,
            onUserInteraction: suspendFollowForUserInteraction
        )
    }

    private func suspendFollowForUserInteraction() {
        guard followsAudio || followsAudioBeforeSearch || followController.directive != nil else { return }
        followsAudioBeforeSearch = false
        if followsAudio { followsAudio = false }
        followController.suspend()
    }

    private func emptyState(hasAudio: Bool) -> some View {
        let isSearching = !searchText.isEmpty
        let title: String
        let message: String
        let icon: String

        if isSearching {
            title = "No matches"
            message = "Try a different speaker or phrase."
            icon = "magnifyingglass"
        } else if !hasSelectedSession {
            title = "Choose a transcript"
            message = "Select a saved session from the transcript library to read, search, copy, or export it."
            icon = "doc.text.magnifyingglass"
        } else if hasAudio {
            title = "No speech detected"
            message = "Audio is available for this session, but there are no spoken segments to display."
            icon = "waveform.slash"
        } else {
            title = "No transcript yet"
            message = "Start a recording from the menu bar. Saved transcripts will appear here for reading and export."
            icon = "doc.text"
        }

        return VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(palette.secondary.opacity(0.7))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            if isSearching {
                Button("Clear Search") { searchText = "" }
                    .buttonStyle(ThemedControlButtonStyle())
                    .accessibilityIdentifier("clippy.transcript.clear-search")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func footer(timeline: TranscriptTimeline) -> some View {
        HStack(spacing: 10) {
            Button {
                copyText(model.transcript.rawText, format: "raw")
            } label: {
                Label(copiedFormat == "raw" ? "Copied" : "Copy Raw", systemImage: copiedFormat == "raw" ? "checkmark" : "text.alignleft")
            }
            .help("Copy speech with a blank line between segments, without timestamps or speaker names")
            .disabled(timeline.rows.isEmpty)
            .accessibilityIdentifier("clippy.transcript.copy-raw")

            Button { copyTranscript() } label: {
                Label(copiedFormat == "markdown" ? "Copied" : "Copy Markdown", systemImage: copiedFormat == "markdown" ? "checkmark" : "doc.on.doc")
            }
            .help("Copy Markdown using Settings → Transcript Export, including the selected metadata and speech details")
            .disabled(timeline.rows.isEmpty)
            .accessibilityIdentifier("clippy.transcript.copy")

            Spacer(minLength: 8)
            if retainedAudioBytes > 0 {
                Button("Compress Audio…", systemImage: "arrow.down.right.and.arrow.up.left") { model.confirmAudioCompression() }
                    .help("Replace retained audio with a smaller AAC copy when possible")
                    .disabled(!model.canCompressSelectedAudio)
            }
            Menu {
                Button("Rename Speakers", systemImage: "person.crop.circle.badge.pencil") { showingSpeakerEditor = true }
                    .disabled(!model.canBrowseSessions || timeline.rows.isEmpty)
                Button("Regenerate Notes", systemImage: "arrow.clockwise") { model.regenerateNotes() }
                    .disabled(!model.canBrowseSessions || model.activeSession?.status != "completed" || timeline.rows.isEmpty)
                Button("Open Notes", systemImage: "note.text") { model.openNotes() }
                    .disabled(!model.selectedSessionHasNotes)
                Divider()
                Button("Reveal in Finder", systemImage: "folder") { model.revealCompletedSession() }
            } label: {
                Label("More Transcript Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More transcript actions")
            .accessibilityLabel("More transcript actions")
            .accessibilityIdentifier("clippy.transcript.more")
        }
        .buttonStyle(ThemedControlButtonStyle())
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var sessionDuration: TimeInterval {
        if let activeSession = model.activeSession, activeSession.id == model.selectedSessionID {
            return model.recordingState.isRecording ? model.currentDuration : activeSession.duration
        }
        return model.recentSessions.first(where: { $0.id == model.selectedSessionID })?.duration ?? 0
    }

    private var sessionDate: Date? {
        if let activeSession = model.activeSession, activeSession.id == model.selectedSessionID {
            return activeSession.createdAt
        }
        return model.recentSessions.first(where: { $0.id == model.selectedSessionID })?.createdAt
    }

    private var readerTitle: String {
        if !hasSelectedSession { return "Transcripts" }
        return model.selectedSessionTitle
    }

    private func metadataText(date: Date?, duration: TimeInterval) -> String {
        guard let date else { return "Choose a transcript to read" }
        let audioStatus: String
        if hasAudio {
            audioStatus = retainedAudioBytes > 0
                ? "Audio \(ByteCountFormatter.string(fromByteCount: retainedAudioBytes, countStyle: .file))"
                : "Audio available"
        } else if player.didFinishLoading && player.requestedAudioCount > 0 {
            audioStatus = "Audio unavailable"
        } else {
            audioStatus = "Audio not retained"
        }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) · \(ProsodyFormatters.duration(duration)) · \(audioStatus)"
    }

    private func configurePlayback() {
        let audioURLs = model.selectedSessionAudioURLs
        let duration = sessionDuration
        let bookmarkData = model.selectedSessionBookmarkData
        audioAvailability = nil
        playbackLoadTask?.cancel()
        player.cancelLoading()
        let player = player
        playbackLoadTask = Task {
            await player.loadAsync(
                audioURLs: audioURLs,
                sessionDuration: duration,
                bookmarkData: bookmarkData
            )
        }
    }

    private func copyTranscript() {
        let markdown: String
        if let session = model.activeSession {
            markdown = TranscriptExportFormatter.render(
                SessionDocument(session: session, transcript: model.transcript), options: model.preferences.transcriptExport
            )
        } else {
            markdown = MarkdownRenderer.render(model.transcript, title: model.selectedSessionTitle,
                                                date: sessionDate ?? .now, duration: sessionDuration)
        }
        copyText(markdown, format: "markdown")
    }

    private func copyText(_ text: String, format: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedFormat = format
    }
}

struct TranscriptRowView: View {
    @Environment(\.prosodyPalette) private var palette
    let segment: TranscriptSegment
    let canSeekAudio: Bool
    let isFollowed: Bool
    let rename: (String, String) -> Void
    let seek: (TimeInterval) -> Void

    @State private var isEditingSpeaker = false
    @State private var draftSpeakerName: String

    init(
        segment: TranscriptSegment,
        canSeekAudio: Bool,
        isFollowed: Bool,
        rename: @escaping (String, String) -> Void,
        seek: @escaping (TimeInterval) -> Void
    ) {
        self.segment = segment
        self.canSeekAudio = canSeekAudio
        self.isFollowed = isFollowed
        self.rename = rename
        self.seek = seek
        _draftSpeakerName = State(initialValue: segment.visibleSpeakerName)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                if isEditingSpeaker {
                    TextField("Speaker", text: $draftSpeakerName, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                } else {
                    Button(segment.visibleSpeakerName) {
                        draftSpeakerName = segment.visibleSpeakerName
                        isEditingSpeaker = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .help("Rename speaker")
                    .accessibilityHint("Rename speaker")
                }

                if canSeekAudio {
                    Button {
                        seek(segment.start)
                    } label: {
                        Text(ProsodyFormatters.timestamp(segment.start))
                            .font(.system(size: 12).monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.secondary)
                    .help("Play from \(ProsodyFormatters.timestamp(segment.start))")
                    .accessibilityLabel("Play from \(ProsodyFormatters.timestamp(segment.start))")
                } else {
                    Text(ProsodyFormatters.timestamp(segment.start))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(palette.secondary)
                }
            }
            .frame(width: 108, alignment: .leading)

            Text(segment.text)
                .font(.system(size: 15))
                .foregroundStyle(palette.text.opacity(segment.isFinal ? 1 : 0.68))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isFollowed ? palette.accent.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if isFollowed {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(palette.accent.opacity(0.65))
                    .frame(width: 3)
                    .padding(.vertical, 10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clippy.transcript.window-segment.\(segment.id.uuidString)")
    }

    private func commitRename() {
        let trimmed = draftSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rename(segment.visibleSpeakerName, trimmed)
        isEditingSpeaker = false
    }
}

struct SpeakerEditorView: View {
    @Environment(\.prosodyPalette) private var palette
    let segments: [TranscriptSegment]
    let rename: ([String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String]

    init(segments: [TranscriptSegment], rename: @escaping ([String: String]) -> Void) {
        self.segments = segments
        self.rename = rename
        let speakerNames = Set(segments.map(\.visibleSpeakerName)).sorted()
        _names = State(initialValue: Dictionary(uniqueKeysWithValues: speakerNames.map { ($0, $0) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename Speakers")
                .font(.system(size: 20, weight: .semibold))
            Text("Names update the transcript and will be used for future note generation.")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondary)

            Form {
                ForEach(names.keys.sorted(), id: \.self) { oldName in
                    TextField(oldName, text: Binding(
                        get: { names[oldName, default: oldName] },
                        set: { names[oldName] = $0 }
                    ))
                    .accessibilityIdentifier("clippy.speaker-editor.\(oldName)")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    rename(names)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("clippy.speaker-editor.save")
            }
        }
        .padding(24)
        .frame(width: 440, height: 320)
        .background { ThemeBackground(palette: palette) }
    }
}

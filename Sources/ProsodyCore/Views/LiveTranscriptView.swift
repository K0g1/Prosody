import SwiftUI

struct LiveTranscriptView: View {
    @Environment(\.prosodyPalette) private var palette
    let segments: [TranscriptSegment]
    var maxItems: Int = 6
    var compact = true

    @State private var followsLive = true
    @State private var showJumpToLive = false

    private var visibleSegments: [TranscriptSegment] {
        Array(segments.filter { !$0.isEchoDuplicate }.suffix(maxItems))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if visibleSegments.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "waveform")
                        .foregroundStyle(palette.accent)
                    Text("Live transcription will appear here.")
                        .foregroundStyle(palette.secondary)
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: compact ? 12 : 18) {
                            ForEach(visibleSegments) { segment in
                                LiveTranscriptRow(segment: segment, compact: compact)
                                    .id(segment.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("live-end")
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxWidth: .infinity, minHeight: compact ? 110 : 180, maxHeight: compact ? 178 : 300)
                    .onChange(of: visibleSegments.last?.text) { _, _ in
                        guard followsLive else {
                            showJumpToLive = true
                            return
                        }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("live-end", anchor: .bottom)
                        }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting {
                            followsLive = false
                            showJumpToLive = true
                        }
                    }

                    if showJumpToLive {
                        Button {
                            followsLive = true
                            showJumpToLive = false
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("live-end", anchor: .bottom)
                            }
                        } label: {
                            Label("Jump to live", systemImage: "arrow.down.to.line")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accent)
                        .accessibilityIdentifier("clippy.live-transcript.jump-to-live")
                    }
                }
            }
        }
        .accessibilityIdentifier("clippy.live-transcript")
    }
}

private struct LiveTranscriptRow: View {
    @Environment(\.prosodyPalette) private var palette
    let segment: TranscriptSegment
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(segment.visibleSpeakerName)
                    .font(.system(size: compact ? 13 : 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(ProsodyFormatters.timestamp(segment.start))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                if !segment.isFinal {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(palette.secondary)
                }
            }
            Text(segment.text)
                .font(.system(size: compact ? 13 : 15))
                .foregroundStyle(palette.text.opacity(segment.isFinal ? 1 : 0.70))
                .lineSpacing(2)
                .lineLimit(compact ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(segment.visibleSpeakerName), \(ProsodyFormatters.timestamp(segment.start)): \(segment.text)")
        .accessibilityIdentifier("clippy.transcript-segment.\(segment.id.uuidString)")
    }
}

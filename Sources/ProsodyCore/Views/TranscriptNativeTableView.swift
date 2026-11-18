import AppKit
import Foundation
import SwiftUI

/// A view-based AppKit table used by the large transcript reader. The table
/// owns row virtualization and scrolling; SwiftUI only renders the visible
/// rows. Playback updates therefore do not rebuild or diff the row collection.
struct TranscriptNativeTableView: NSViewRepresentable {
    let rows: [TranscriptTimelineRow]
    let revision: Int
    let canSeekAudio: Bool
    let followedRowID: UUID?
    let followDirective: TranscriptFollowDirective?
    let isScrubbing: () -> Bool
    var reduceMotion = false
    let palette: ThemePalette
    let rename: (String, String) -> Void
    let seek: (TimeInterval) -> Void
    let onUserInteraction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            rename: rename,
            seek: seek,
            onUserInteraction: onUserInteraction,
            isScrubbing: isScrubbing
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TranscriptTableScrollView()
        let tableView = TranscriptTableView()
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        column.width = 640
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 60
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.autoresizingMask = [.width]
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.setAccessibilityIdentifier("clippy.transcript.list")
        tableView.setAccessibilityLabel("Transcript")

        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView

        context.coordinator.install(scrollView: scrollView, tableView: tableView)
        context.coordinator.update(
            rows: rows,
            revision: revision,
            canSeekAudio: canSeekAudio,
            followedRowID: followedRowID,
            followDirective: followDirective,
            isScrubbing: isScrubbing,
            reduceMotion: reduceMotion,
            palette: palette,
            rename: rename,
            seek: seek,
            onUserInteraction: onUserInteraction
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(
            rows: rows,
            revision: revision,
            canSeekAudio: canSeekAudio,
            followedRowID: followedRowID,
            followDirective: followDirective,
            isScrubbing: isScrubbing,
            reduceMotion: reduceMotion,
            palette: palette,
            rename: rename,
            seek: seek,
            onUserInteraction: onUserInteraction
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("clippy.transcript.native-column")

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private struct RowHeightKey: Hashable {
            let rowID: UUID
            let width: CGFloat
            let revision: Int
        }

        private var rows: [TranscriptTimelineRow] = []
        private var rowIndexByID: [UUID: Int] = [:]
        private var rowHeights: [RowHeightKey: CGFloat] = [:]
        private var revision: Int?
        private var measuredWidth: CGFloat = 0
        private var canSeekAudio = false
        private var followedRowID: UUID?
        private var palette: ThemePalette?
        private var rename: (String, String) -> Void
        private var seek: (TimeInterval) -> Void
        private var onUserInteraction: () -> Void
        private weak var scrollView: TranscriptTableScrollView?
        private weak var tableView: TranscriptTableView?
        private var lastDirectiveRequestID: Int?
        private var isScrubbingProvider: () -> Bool
        private var scrubbing = false
        private var followTask: Task<Void, Never>?
        private var widthUpdateTask: Task<Void, Never>?
        private var reduceMotion = false

        init(
            rename: @escaping (String, String) -> Void,
            seek: @escaping (TimeInterval) -> Void,
            onUserInteraction: @escaping () -> Void,
            isScrubbing: @escaping () -> Bool
        ) {
            self.rename = rename
            self.seek = seek
            self.onUserInteraction = onUserInteraction
            self.isScrubbingProvider = isScrubbing
            super.init()
        }

        func install(scrollView: TranscriptTableScrollView, tableView: TranscriptTableView) {
            self.scrollView = scrollView
            self.tableView = tableView
            scrollView.onUserInteraction = { [weak self] in self?.userDidInteract() }
            tableView.onUserInteraction = { [weak self] in self?.userDidInteract() }
            tableView.onWidthChange = { [weak self] width in self?.widthDidChange(width) }
            NotificationCenter.default.addObserver(self,
                selector: #selector(scrollViewWillLiveScroll(_:)),
                name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        }

        func update(
            rows: [TranscriptTimelineRow],
            revision: Int,
            canSeekAudio: Bool,
            followedRowID: UUID?,
            followDirective: TranscriptFollowDirective?,
            isScrubbing: @escaping () -> Bool,
            reduceMotion: Bool,
            palette: ThemePalette,
            rename: @escaping (String, String) -> Void,
            seek: @escaping (TimeInterval) -> Void,
            onUserInteraction: @escaping () -> Void
        ) {
            self.rename = rename
            self.seek = seek
            self.onUserInteraction = onUserInteraction
            self.isScrubbingProvider = isScrubbing

            let rowsChanged = self.revision != revision
            let appearanceChanged = self.canSeekAudio != canSeekAudio || self.palette != palette
            let previousFollowedRowID = self.followedRowID
            let followedChanged = previousFollowedRowID != followedRowID
            let scrubbingNow = self.isScrubbingProvider()
            self.reduceMotion = reduceMotion

            self.canSeekAudio = canSeekAudio
            self.palette = palette
            self.followedRowID = followedRowID
            self.scrubbing = scrubbingNow

            if rowsChanged {
                replaceRows(rows, revision: revision)
            }
            if appearanceChanged || rowsChanged {
                updateVisibleCells()
            } else if followedChanged {
                updateFollowedCells(from: previousFollowedRowID, to: followedRowID)
            }

            if let followDirective, followDirective.requestID != lastDirectiveRequestID {
                lastDirectiveRequestID = followDirective.requestID
                cancelFollowTask()
                // Finish covering the row reload and layout pass before
                // measuring the row's new height.
                followTask = Task { @MainActor [weak self] in
                    self?.centerRow(followDirective)
                }
            } else if followDirective == nil {
                cancelFollowTask()
            }
        }

        func dismantle() {
            cancelFollowTask()
            widthUpdateTask?.cancel()
            widthUpdateTask = nil
            NotificationCenter.default.removeObserver(self)
            scrollView?.onUserInteraction = nil
            tableView?.onUserInteraction = nil
            tableView?.onWidthChange = nil
            tableView?.dataSource = nil
            tableView?.delegate = nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 60 }
            // Reading NSTableView.bounds can synchronously invoke tile()
            // from inside AppKit's row-height callback.
            let width = max(1, measuredWidth > 0 ? measuredWidth : tableView.frame.width)
            let key = RowHeightKey(
                rowID: rows[row].id,
                width: width,
                revision: revision ?? 0
            )
            if let cached = rowHeights[key] { return cached }
            let height = measuredHeight(for: rows[row].segment, width: width)
            rowHeights[key] = height
            return height
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let palette else { return nil }
            let item = rows[row]
            let cellIdentifier = NSUserInterfaceItemIdentifier("clippy.transcript.native-cell")
            let cell: TranscriptTableCell
            if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? TranscriptTableCell {
                cell = reused
            } else {
                cell = TranscriptTableCell(
                    segment: item.segment,
                    canSeekAudio: canSeekAudio,
                    isFollowed: followedRowID == item.id,
                    palette: palette,
                    rename: rename,
                    seek: seek
                )
                cell.identifier = cellIdentifier
            }
            cell.configure(
                segment: item.segment,
                canSeekAudio: canSeekAudio,
                isFollowed: followedRowID == item.id,
                palette: palette,
                rename: rename,
                seek: seek
            )
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = NSTableRowView()
            rowView.backgroundColor = .clear
            rowView.isEmphasized = false
            rowView.selectionHighlightStyle = .none
            return rowView
        }

        private func replaceRows(_ newRows: [TranscriptTimelineRow], revision: Int) {
            guard let tableView else { return }
            let anchorID = visibleRows(in: tableView).first.flatMap { row in
                rows.indices.contains(row) ? rows[row].id : nil
            }
            self.rows = newRows
            self.revision = revision
            rowIndexByID = Dictionary(
                newRows.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            rowHeights.removeAll(keepingCapacity: true)
            measuredWidth = tableView.frame.width
            tableView.reloadData()
            if let anchorID, let index = rowIndexByID[anchorID] {
                scrollRowToVisible(index)
            } else if !newRows.isEmpty {
                scrollRowToVisible(0)
            }
        }

        private func updateVisibleCells() {
            guard let tableView, let palette else { return }
            for row in visibleRows(in: tableView) {
                guard rows.indices.contains(row),
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCell
                else { continue }
                let item = rows[row]
                cell.configure(
                    segment: item.segment,
                    canSeekAudio: canSeekAudio,
                    isFollowed: followedRowID == item.id,
                    palette: palette,
                    rename: rename,
                    seek: seek
                )
            }
        }

        private func updateFollowedCells(from oldRowID: UUID?, to newRowID: UUID?) {
            guard let tableView, let palette else { return }
            var updated = Set<UUID>()
            for rowID in [oldRowID, newRowID].compactMap({ $0 }) where updated.insert(rowID).inserted {
                guard let row = rowIndexByID[rowID], rows.indices.contains(row),
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCell
                else { continue }
                cell.configure(
                    segment: rows[row].segment,
                    canSeekAudio: canSeekAudio,
                    isFollowed: followedRowID == rowID,
                    palette: palette,
                    rename: rename,
                    seek: seek
                )
            }
        }

        private func measuredHeight(for segment: TranscriptSegment, width: CGFloat) -> CGFloat {
            let textWidth = max(1, width - 188)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 3
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15),
                .paragraphStyle: paragraph
            ]
            let textRect = (segment.text as NSString).boundingRect(
                with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
            let speakerFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
            let timestampFont = NSFont.systemFont(ofSize: 12)
            let speakerParagraph = NSMutableParagraphStyle()
            speakerParagraph.lineBreakMode = .byWordWrapping
            let speakerRect = (segment.visibleSpeakerName as NSString).boundingRect(
                with: NSSize(width: 108, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: speakerFont, .paragraphStyle: speakerParagraph]
            )
            // The inline speaker editor is a single-line rounded TextField.
            let speakerControlHeight = max(ceil(speakerRect.height), 24)
            let speakerHeight = speakerControlHeight
                + 3
                + ceil(timestampFont.boundingRectForFont.height)
            let contentHeight = max(ceil(textRect.height) + 1, speakerHeight)
            return max(60, contentHeight + 26)
        }

        private func visibleRows(in tableView: NSTableView) -> Range<Int> {
            let range = tableView.rows(in: tableView.visibleRect)
            guard range.location != NSNotFound, range.length > 0 else { return 0..<0 }
            return range.location..<(range.location + range.length)
        }

        private func widthDidChange(_ width: CGFloat) {
            guard width > 0, abs(width - measuredWidth) > 0.5 else { return }
            widthUpdateTask?.cancel()
            // AppKit calls setFrameSize from tile() and during live resizing.
            // Invalidate after the final width settles, outside that layout.
            widthUpdateTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, !Task.isCancelled, let tableView = self.tableView,
                      !self.rows.isEmpty else { return }
                let width = tableView.frame.width
                guard abs(width - self.measuredWidth) > 0.5 else { return }
                self.measuredWidth = width
                self.rowHeights.removeAll(keepingCapacity: true)
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.rows.count))
            }
        }

        private func centerRow(_ directive: TranscriptFollowDirective) {
            guard !Task.isCancelled, let scrollView, let tableView,
                  let index = rowIndexByID[directive.rowID], rows.indices.contains(index) else { return }
            let clip = scrollView.contentView
            let start = clip.bounds.origin
            let row = tableView.convert(tableView.rect(ofRow: index), to: clip)
            var goal = clip.bounds
            goal.origin.y = row.midY - goal.height / 2
            goal = clip.constrainBoundsRect(goal)
            let distance = goal.minY - start.y
            guard abs(distance) > 0.75 else { return }
            let animate = directive.shouldAnimate && !reduceMotion && !scrubbing
                && abs(distance) < clip.bounds.height * 4
            if !animate {
                setScrollOrigin(goal.origin, in: scrollView)
                return
            }

            followTask = Task { @MainActor [weak self, weak scrollView] in
                let clock = ContinuousClock()
                let began = clock.now
                let duration = 0.20
                while let self, let scrollView, !Task.isCancelled {
                    let d = began.duration(to: clock.now).components
                    let seconds = Double(d.seconds) + Double(d.attoseconds) / 1e18
                    let fraction = min(seconds / duration, 1)
                    let remaining = 1 - fraction
                    let eased = 1 - remaining * remaining * remaining
                    self.setScrollOrigin(NSPoint(x: start.x, y: start.y + distance * eased), in: scrollView)
                    if fraction == 1 { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }

        private func setScrollOrigin(_ point: NSPoint, in scrollView: TranscriptTableScrollView) {
            scrollView.isProgrammaticScroll = true
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollView.isProgrammaticScroll = false
        }

        private func scrollRowToVisible(_ index: Int) {
            scrollView?.isProgrammaticScroll = true
            tableView?.scrollRowToVisible(index)
            scrollView?.isProgrammaticScroll = false
        }

        private func cancelFollowTask() {
            followTask?.cancel()
            followTask = nil
        }

        private func userDidInteract() {
            cancelFollowTask()
            onUserInteraction()
        }

        @objc private func scrollViewWillLiveScroll(_ notification: Notification) {
            guard scrollView?.isProgrammaticScroll != true else { return }
            userDidInteract()
        }

    }
}

@MainActor
final class TranscriptTableScrollView: NSScrollView {
    var onUserInteraction: (() -> Void)?
    var isProgrammaticScroll = false

    override func scrollWheel(with event: NSEvent) {
        onUserInteraction?()
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        onUserInteraction?()
        super.magnify(with: event)
    }
}

@MainActor
final class TranscriptTableView: NSTableView {
    var onUserInteraction: (() -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?

    override func accessibilityChildren() -> [Any]? {
        guard let children = super.accessibilityChildren() else { return nil }
        // Recycled AppKit row views can appear in subview order. Keep the
        // accessibility hierarchy in transcript order without creating rows.
        let rows = children.compactMap { $0 as? NSTableRowView }
        var sortedRows = rows.sorted { row(for: $0) < row(for: $1) }.makeIterator()
        return children.map { item in
            guard item is NSTableRowView, let row = sortedRows.next() else { return item }
            return row
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if abs(newSize.width - oldWidth) > 0.5 {
            onWidthChange?(newSize.width)
        }
    }

    override func keyDown(with event: NSEvent) {
        if Self.scrollingKeyCodes.contains(event.keyCode) {
            onUserInteraction?()
        }
        super.keyDown(with: event)
    }

    private static let scrollingKeyCodes: Set<UInt16> = [115, 116, 119, 121, 125, 126]
}

@MainActor
final class TranscriptTableCell: NSTableCellView {
    private let hostingView: NSHostingView<TranscriptRowHostView>
    private var segment: TranscriptSegment?
    private var followed = false
    private var canSeekAudio = false
    private var palette: ThemePalette?

    init(
        segment: TranscriptSegment,
        canSeekAudio: Bool,
        isFollowed: Bool,
        palette: ThemePalette,
        rename: @escaping (String, String) -> Void,
        seek: @escaping (TimeInterval) -> Void
    ) {
        hostingView = NSHostingView(rootView: TranscriptRowHostView(
            segment: segment,
            canSeekAudio: canSeekAudio,
            isFollowed: isFollowed,
            palette: palette,
            rename: rename,
            seek: seek
        ))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.segment = segment
        self.followed = isFollowed
        self.canSeekAudio = canSeekAudio
        self.palette = palette
        setAccessibilityIdentifier("clippy.transcript.window-segment.\(segment.id.uuidString)")
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func configure(
        segment: TranscriptSegment,
        canSeekAudio: Bool,
        isFollowed: Bool,
        palette: ThemePalette,
        rename: @escaping (String, String) -> Void,
        seek: @escaping (TimeInterval) -> Void
    ) {
        let changed = self.segment != segment
            || self.followed != isFollowed
            || self.canSeekAudio != canSeekAudio
            || self.palette != palette
        guard changed else { return }
        self.segment = segment
        followed = isFollowed
        self.canSeekAudio = canSeekAudio
        self.palette = palette
        hostingView.rootView = TranscriptRowHostView(
            segment: segment,
            canSeekAudio: canSeekAudio,
            isFollowed: isFollowed,
            palette: palette,
            rename: rename,
            seek: seek
        )
        setAccessibilityIdentifier("clippy.transcript.window-segment.\(segment.id.uuidString)")
    }
}

private struct TranscriptRowHostView: View {
    let segment: TranscriptSegment
    let canSeekAudio: Bool
    let isFollowed: Bool
    let palette: ThemePalette
    let rename: (String, String) -> Void
    let seek: (TimeInterval) -> Void

    var body: some View {
        TranscriptRowView(
            segment: segment,
            canSeekAudio: canSeekAudio,
            isFollowed: isFollowed,
            rename: rename,
            seek: seek
        )
        .environment(\.prosodyPalette, palette)
        .environment(\.colorScheme, palette.dark ? .dark : .light)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .id(segment.id)
    }
}

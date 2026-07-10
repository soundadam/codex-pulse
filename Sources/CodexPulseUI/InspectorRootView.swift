import Charts
import Core
import SwiftUI

struct InspectorRootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    PulsePalette.accent.opacity(0.055),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 14)

                Divider()
                    .opacity(0.6)

                controlBar
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let errorBannerMessage = model.errorBannerMessage {
                            ErrorBannerView(message: errorBannerMessage)
                        }

                        switch model.selectedTab {
                        case .allTurns:
                            allTurnsContent
                        case .threadDetail:
                            threadDetailContent
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(
            minWidth: 840,
            idealWidth: 840,
            maxWidth: 840,
            minHeight: 560,
            idealHeight: 620,
            maxHeight: 680,
            alignment: .topLeading
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [PulsePalette.accent, PulsePalette.accent.opacity(0.68)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: PulsePalette.accent.opacity(0.24), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Pulse")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionTint)
                        .frame(width: 6, height: 6)
                    Text(connectionLabel)
                    Text("·")
                    Text(lastRefreshLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            HeaderMetric(
                value: model.invalidTimelineTurnCount,
                label: "Invalid",
                tint: PulsePalette.invalid
            )
            HeaderMetric(
                value: model.runningThreadCount,
                label: "Running",
                tint: PulsePalette.running
            )
            HeaderMetric(
                value: model.observedTimelineTurnCount,
                label: "Observed",
                tint: PulsePalette.valid
            )

            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .rotationEffect(model.isRefreshing ? .degrees(180) : .zero)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(PulsePalette.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(model.isRefreshing)
            .help("Refresh now (⌘R)")
            .accessibilityLabel("Refresh Codex telemetry")
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("View", selection: Binding(
                get: { model.selectedTab },
                set: { model.setSelectedTab($0) }
            )) {
                Label("Timeline", systemImage: "chart.xyaxis.line")
                    .tag(TimelineTab.allTurns)
                Label("Threads", systemImage: "rectangle.split.3x1")
                    .tag(TimelineTab.threadDetail)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search projects, threads, or turns", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                if model.searchQuery.isEmpty == false {
                    Button {
                        model.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(PulsePalette.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            }
        }
    }

    @ViewBuilder
    private var allTurnsContent: some View {
        if model.recentReasoningSessions.isEmpty {
            ContentUnavailableView(
                model.searchQuery.isEmpty ? "No timeline items yet" : "No matching turns",
                systemImage: "waveform.path.ecg",
                description: Text(model.searchQuery.isEmpty
                    ? "Codex Pulse will chart live samples and completed turns here."
                    : "Try a project name, thread title, model, or preview text.")
            )
            .frame(maxWidth: .infinity, minHeight: 330)
            .pulseSurface()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(
                    eyebrow: "LAST HOUR",
                    title: "Reasoning stream",
                    trailing: "\(model.recentReasoningSessions.count) samples"
                )
                HStack(spacing: 14) {
                    SignalLegend(label: "Invalid", tint: PulsePalette.invalid)
                    SignalLegend(label: "Observed", tint: PulsePalette.valid)
                    SignalLegend(label: "No live sample", tint: PulsePalette.unknown)
                }
                TimelineScroller(
                    sessions: model.recentReasoningSessions,
                    selectedKey: model.selectedCompletedSession?.key,
                    onSelect: model.selectSession
                )
            }
            .padding(14)
            .pulseSurface()

            if let group = model.selectedTimelineThreadGroup,
               let turn = model.selectedTimelineTurnDetail {
                ThreadTurnStrip(
                    group: group,
                    turns: model.selectedTimelineTurns,
                    selectedTurnKey: turn.key,
                    onSelect: model.selectTurn
                )

                TurnDetailCard(
                    group: group,
                    turn: turn,
                    samples: model.selectedTimelineTurnSamples,
                    openRollout: model.openSelectedRollout
                )
            } else if let session = model.selectedCompletedSession {
                SessionDetailCard(
                    session: session,
                    openRollout: model.openSelectedRollout
                )
            }
        }
    }

    @ViewBuilder
    private var threadDetailContent: some View {
        if model.threadDetailThreads.isEmpty {
            ContentUnavailableView(
                model.searchQuery.isEmpty ? "No threads yet" : "No matching threads",
                systemImage: "bubble.left.and.bubble.right",
                description: Text(model.searchQuery.isEmpty
                    ? "Recent Codex threads will appear as soon as they are discovered."
                    : "Try searching by project path, thread title, or assistant preview.")
            )
            .frame(maxWidth: .infinity, minHeight: 380)
            .pulseSurface()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(
                    eyebrow: "INSPECT",
                    title: "Thread explorer",
                    trailing: "\(model.threadDetailThreads.count) recent"
                )

                HStack(alignment: .top, spacing: 12) {
                    ThreadListColumn(
                        threads: model.threadDetailThreads,
                        selectedThreadID: model.selectedThreadID,
                        onSelect: model.selectThread
                    )
                    .frame(width: 210)

                    TurnListColumn(
                        turns: model.selectedThreadTurns,
                        selectedTurnKey: model.selectedTurnDetail?.key,
                        onSelect: model.selectTurn
                    )
                    .frame(width: 170)

                    if let group = model.selectedThreadTurnGroup,
                       let turn = model.selectedTurnDetail {
                        TurnDetailCard(
                            group: group,
                            turn: turn,
                            samples: model.selectedTurnSamples,
                            openRollout: model.openSelectedRollout
                        )
                    } else {
                        ContentUnavailableView(
                            "No turns for selected thread",
                            systemImage: "list.bullet.rectangle",
                            description: Text("Select another thread or wait for a turn to complete.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .pulseSurface()
                    }
                }
            }
        }
    }

    private var lastRefreshLabel: String {
        guard let lastRefreshAt = model.lastRefreshAt else {
            return "Waiting for first sync"
        }
        return "Updated \(lastRefreshAt.formatted(date: .omitted, time: .shortened))"
    }

    private var connectionLabel: String {
        if model.errorMessage != nil {
            return "Disconnected"
        }
        return model.isRefreshing ? "Syncing" : "Live"
    }

    private var connectionTint: Color {
        if model.errorMessage != nil {
            return PulsePalette.invalid
        }
        return model.isRefreshing ? PulsePalette.accent : PulsePalette.valid
    }
}

private struct TimelineScroller: View {
    let sessions: [CompletedSession]
    let selectedKey: String?
    let onSelect: (String?) -> Void
    private let nodeSpacing: CGFloat = 12
    private let sidePadding: CGFloat = 24

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ReasoningCurveChart(
                        sessions: sessions,
                        selectedKey: selectedKey
                    )
                    .frame(width: contentWidth, height: 120)

                    ZStack(alignment: .center) {
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 2)
                            .padding(.horizontal, 34)

                        HStack(alignment: .top, spacing: nodeSpacing) {
                            ForEach(sessions) { session in
                                Button {
                                    onSelect(session.key)
                                } label: {
                                    TimelineNode(
                                        session: session,
                                        isSelected: session.key == selectedKey
                                    )
                                }
                                .buttonStyle(.plain)
                                .frame(width: nodeWidth)
                                .id(session.key)
                            }
                        }
                    }
                }
                .padding(.horizontal, sidePadding)
                .frame(width: contentWidth, alignment: .leading)
            }
            .frame(height: 220)
            .onAppear {
                scrollToLatest(with: proxy)
            }
            .onChange(of: selectedKey) { _, _ in
                scrollToLatest(with: proxy)
            }
            .onChange(of: sessions.map(\.key)) { _, _ in
                scrollToLatest(with: proxy)
            }
        }
    }

    private var nodeWidth: CGFloat { 76 }

    private var contentWidth: CGFloat {
        let nodesWidth = CGFloat(sessions.count) * nodeWidth
        let spacingWidth = CGFloat(max(0, sessions.count - 1)) * nodeSpacing
        let paddedWidth = nodesWidth + spacingWidth + sidePadding * 2
        return max(paddedWidth, 700)
    }

    private func scrollToLatest(with proxy: ScrollViewProxy) {
        let targetKey = selectedKey ?? sessions.last?.key
        guard let targetKey else {
            return
        }

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(targetKey, anchor: .trailing)
            }
        }
    }
}

private struct ReasoningCurveChart: View {
    let sessions: [CompletedSession]
    let selectedKey: String?

    var body: some View {
        Chart(Array(sessions.enumerated()), id: \.element.id) { index, session in
            AreaMark(
                x: .value("Index", index),
                y: .value("Reasoning", session.timelineReasoningTokens)
            )
            .interpolationMethod(.linear)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        signalColor(for: session.signalState).opacity(0.16),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Index", index),
                y: .value("Reasoning", session.timelineReasoningTokens)
            )
            .interpolationMethod(.linear)
            .lineStyle(.init(lineWidth: session.key == selectedKey ? 3 : 2, lineCap: .round, lineJoin: .round))
            .foregroundStyle(signalColor(for: session.signalState))

            PointMark(
                x: .value("Index", index),
                y: .value("Reasoning", session.timelineReasoningTokens)
            )
            .symbolSize(session.key == selectedKey ? 90 : 55)
            .foregroundStyle(signalColor(for: session.signalState))
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let number = value.as(Int.self) {
                        Text(numberText(number))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }
}

private struct TimelineNode: View {
    let session: CompletedSession
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(numberText(session.timelineReasoningTokens))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(signalColor(for: session.signalState))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            ZStack {
                Circle()
                    .fill(signalColor(for: session.signalState))
                    .frame(width: isSelected ? 20 : 16, height: isSelected ? 20 : 16)
                Circle()
                    .strokeBorder(isSelected ? Color.primary : signalColor(for: session.signalState).opacity(0.45), lineWidth: isSelected ? 3 : 2)
                    .frame(width: isSelected ? 24 : 20, height: isSelected ? 24 : 20)
            }

            VStack(spacing: 2) {
                Text(formatDate(session.completedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(session.projectName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private struct SessionDetailCard: View {
    let session: CompletedSession
    let openRollout: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(signalColor(for: session.signalState))
                    .frame(width: 10, height: 10)

                Text(session.projectName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(signalColor(for: session.signalState))
            }

            Text(session.threadTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(session.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 10) {
                MetricChip(label: "Last", value: numberText(session.tokenUsage.last.reasoningOutputTokens), tint: signalColor(for: session.signalState))
                MetricChip(label: "Total", value: numberText(session.tokenUsage.total.reasoningOutputTokens), tint: .primary)
            }

            HStack(spacing: 10) {
                Text(session.completedAt?.formatted(date: .omitted, time: .shortened) ?? "-")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Open Rollout") {
                    _ = openRollout()
                }
                .buttonStyle(.link)
                .disabled(session.rolloutPath == nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pulseSurface()
    }

    private var statusText: String {
        switch session.signalState {
        case .invalid:
            return "Invalid signal"
        case .valid:
            return session.monitorState == .running ? "Live turn" : "Observed turn"
        case .unknown:
            return "No live samples"
        }
    }
}

private struct ThreadTurnStrip: View {
    let group: ThreadTurnGroup
    let turns: [TurnDetailItem]
    let selectedTurnKey: String?
    let onSelect: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.projectName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(group.threadTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(turns) { turn in
                        Button {
                            onSelect(turn.key)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(signalColor(for: turn.signalState))
                                        .frame(width: 7, height: 7)
                                    Text(numberText(turn.lastUsage.reasoningOutputTokens))
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                        .foregroundStyle(signalColor(for: turn.signalState))
                                        .lineLimit(1)
                                }

                                Text(formatDate(turn.completedAt ?? turn.startedAt))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Text(turn.displayTurnID)
                                    .font(.caption2)
                                    .foregroundStyle(turn.key == selectedTurnKey ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                            .padding(10)
                            .frame(width: 112, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(turn.key == selectedTurnKey ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .pulseSurface()
    }
}

private struct ThreadListColumn: View {
    let threads: [MonitorThread]
    let selectedThreadID: String?
    let onSelect: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Threads")
                .font(.subheadline.weight(.semibold))

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(threads) { thread in
                        Button {
                            onSelect(thread.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(thread.monitorState == .running ? Color.orange : Color.secondary)
                                        .frame(width: 7, height: 7)
                                    Text(thread.threadTitle)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                Text(thread.projectName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(thread.id == selectedThreadID ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .pulseSurface()
    }
}

private struct TurnListColumn: View {
    let turns: [TurnDetailItem]
    let selectedTurnKey: String?
    let onSelect: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Turns")
                .font(.subheadline.weight(.semibold))

            if turns.isEmpty {
                Text("No turns for this thread yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(turns) { turn in
                            Button {
                                onSelect(turn.key)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(signalColor(for: turn.signalState))
                                            .frame(width: 8, height: 8)
                                        Text(turn.displayTurnID)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                    }
                                    Text(formatDate(turn.completedAt ?? turn.startedAt))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(turn.key == selectedTurnKey ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .pulseSurface()
    }
}

private struct TurnDetailCard: View {
    let group: ThreadTurnGroup
    let turn: TurnDetailItem
    let samples: [LiveTurnSample]
    let openRollout: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(signalColor(for: turn.signalState))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.projectName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(group.threadTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(turnStatusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(signalColor(for: turn.signalState))
            }

            Text(turn.displayTurnID)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            if samples.isEmpty {
                ContentUnavailableView(
                    "No live samples captured",
                    systemImage: "waveform.path.ecg",
                    description: Text("Completed breakdown is available, but this turn was not fully observed in realtime.")
                )
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                TurnSampleChart(
                    samples: samples,
                    signalState: turn.signalState
                )
                .frame(height: 140)
            }

            HStack(spacing: 10) {
                UsageBreakdownCard(
                    title: "Last Sample",
                    usage: turn.lastUsage,
                    tint: signalColor(for: turn.signalState)
                )
                UsageBreakdownCard(
                    title: "Total",
                    usage: turn.totalUsage,
                    tint: .primary
                )
            }

            MetadataStrip(
                model: turn.model,
                effort: turn.reasoningEffort,
                startedAt: turn.startedAt,
                completedAt: turn.completedAt,
                contextWindow: samples.last?.modelContextWindow
            )

            if let assistantPreview = turn.assistantPreview,
               assistantPreview.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assistant Preview")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(assistantPreview)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                }
            }

            HStack(spacing: 10) {
                if let rolloutPath = turn.rolloutPath {
                    Text(rolloutPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Open Rollout") {
                    _ = openRollout()
                }
                .buttonStyle(.link)
                .disabled(turn.rolloutPath == nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pulseSurface()
    }

    private var turnStatusText: String {
        switch turn.signalState {
        case .invalid:
            return "Invalid signal"
        case .valid:
            return turn.status == .running ? "Live turn" : "Observed turn"
        case .unknown:
            return "Unknown"
        }
    }
}

private struct TurnSampleChart: View {
    let samples: [LiveTurnSample]
    let signalState: TurnSignalState

    var body: some View {
        Chart(Array(samples.enumerated()), id: \.element.id) { index, sample in
            LineMark(
                x: .value("Index", index),
                y: .value("Reasoning", sample.tokenUsage.last.reasoningOutputTokens)
            )
            .interpolationMethod(.linear)
            .foregroundStyle(signalColor(for: signalState))
            .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            PointMark(
                x: .value("Index", index),
                y: .value("Reasoning", sample.tokenUsage.last.reasoningOutputTokens)
            )
            .symbolSize(55)
            .foregroundStyle(signalColor(for: signalState))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let index = value.as(Int.self), samples.indices.contains(index) {
                        Text(samples[index].observedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let number = value.as(Int.self) {
                        Text(numberText(number))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }
}

private struct UsageBreakdownCard: View {
    let title: String
    let usage: TurnUsage
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                BreakdownRow(label: "Reasoning", value: usage.reasoningOutputTokens)
                BreakdownRow(label: "Output", value: usage.outputTokens)
                BreakdownRow(label: "Cached", value: usage.cachedInputTokens)
                BreakdownRow(label: "Input", value: usage.inputTokens)
                BreakdownRow(label: "Total", value: usage.totalTokens)
            }
            .foregroundStyle(tint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}

private struct BreakdownRow: View {
    let label: String
    let value: Int

    var body: some View {
        GridRow {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(numberText(value))
                .font(.system(.caption, design: .monospaced).weight(.semibold))
        }
    }
}

private struct MetadataStrip: View {
    let model: String?
    let effort: String?
    let startedAt: Date?
    let completedAt: Date?
    let contextWindow: Int?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            MetadataRow(label: "Model", value: model ?? "-")
            MetadataRow(label: "Effort", value: effort ?? "-")
            MetadataRow(label: "Started", value: formatDate(startedAt))
            MetadataRow(label: "Completed", value: formatDate(completedAt))
            MetadataRow(label: "Context", value: contextWindow.map(numberText) ?? "-")
        }
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

private struct MetricChip: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}

private struct ErrorBannerView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.yellow.opacity(0.14))
        )
    }
}

private func signalColor(for signalState: TurnSignalState) -> Color {
    switch signalState {
    case .invalid:
        return PulsePalette.invalid
    case .valid:
        return PulsePalette.valid
    case .unknown:
        return PulsePalette.unknown
    }
}

private func numberText(_ number: Int) -> String {
    number.formatted(.number.grouping(.automatic))
}

private func formatDate(_ date: Date?) -> String {
    guard let date else {
        return "-"
    }
    return date.formatted(date: .omitted, time: .shortened)
}

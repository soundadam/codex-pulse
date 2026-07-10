import AppKit
import Charts
import Core
import SwiftUI

struct InspectorRootView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(model: model)
                .padding(.horizontal, 12)
                .frame(height: 48)

            Divider()
                .opacity(0.55)

            if let message = model.errorBannerMessage {
                CompactErrorBanner(message: message)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }

            InspectorTimelineContent(
                model: model,
                hasErrorBanner: model.errorBannerMessage != nil
            )
                .padding(.horizontal, 12)
                .padding(.top, model.errorBannerMessage == nil ? 8 : 0)
                .padding(.bottom, 10)
        }
        .frame(width: 760, height: 520, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    PulsePalette.accent.opacity(0.045),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

}

/// Header observation is intentionally isolated from the chart. Polling state
/// and the minute label can update without invalidating Swift Charts.
private struct InspectorHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [PulsePalette.accent, PulsePalette.accent.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Codex Pulse")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                HStack(spacing: 5) {
                    Circle()
                        .fill(connectionTint)
                        .frame(width: 5, height: 5)
                    Text(connectionLabel)
                    Text("·")
                    Text(lastRefreshLabel)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            CompactHeaderMetric(
                value: model.invalidTimelineTurnCount,
                label: "invalid",
                tint: PulsePalette.invalid
            )
            CompactHeaderMetric(
                value: model.runningThreadCount,
                label: "running",
                tint: PulsePalette.running
            )
            CompactHeaderMetric(
                value: model.observedTimelineTurnCount,
                label: "observed",
                tint: PulsePalette.valid
            )

            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
                    .rotationEffect(model.isRefreshing ? .degrees(180) : .zero)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(PulsePalette.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(model.isRefreshing)
            .help("Refresh now (⌘R)")
            .accessibilityLabel("Refresh Codex telemetry")
        }
    }

    private var lastRefreshLabel: String {
        guard let lastRefreshAt = model.lastRefreshAt else {
            return "waiting"
        }
        return lastRefreshAt.formatted(date: .omitted, time: .shortened)
    }

    private var connectionLabel: String {
        if model.errorMessage != nil {
            return "disconnected"
        }
        return model.isRefreshing ? "syncing" : "live"
    }

    private var connectionTint: Color {
        if model.errorMessage != nil {
            return PulsePalette.invalid
        }
        return model.isRefreshing ? PulsePalette.accent : PulsePalette.valid
    }
}

/// Timeline observation is isolated from header polling state. The chart only
/// changes for a new immutable presentation or an explicit selection change.
private struct InspectorTimelineContent: View {
    @Bindable var model: AppModel
    let hasErrorBanner: Bool

    @ViewBuilder
    var body: some View {
        if model.timelineSeries.isEmpty {
            ContentUnavailableView(
                "No turns in this window",
                systemImage: "chart.xyaxis.line",
                description: Text("Live and completed turns will appear on the timeline.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pulseSurface()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                MultiThreadTimelineChart(
                    presentation: model.timelinePresentation,
                    window: model.selectedTimelineWindow,
                    selectedThreadID: model.selectedThreadID,
                    selectedSessionKey: model.selectedSessionKey,
                    selectWindow: model.setTimelineWindow,
                    selectThread: model.selectThreadLine,
                    selectPoint: model.selectTimelinePoint,
                    resetFocus: model.resetTimelineFocus
                )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: chartMinimumHeight,
                        maxHeight: .infinity
                    )
                    .layoutPriority(1)

                if model.selectedTimelinePoint != nil {
                    SelectedTurnInspectorPane(model: model)
                    .frame(height: 134)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(10)
            .pulseSurface()
            .animation(.easeOut(duration: 0.16), value: model.selectedSessionKey)
        }
    }

    private var chartMinimumHeight: CGFloat {
        if model.selectedTimelinePoint != nil {
            return hasErrorBanner ? 172 : 204
        }
        return hasErrorBanner ? 220 : 260
    }
}

/// Lazy detail loading and model-call samples update this subtree only, keeping
/// the much more expensive main chart stable.
private struct SelectedTurnInspectorPane: View {
    @Bindable var model: AppModel

    @ViewBuilder
    var body: some View {
        if let point = model.selectedTimelinePoint {
            ReasoningTurnInspector(
                point: point,
                reasoningSamples: model.selectedTurnReasoningSamples,
                isLoadingDetails: model.isLoadingSelectedTurnDetails,
                openRollout: model.openSelectedRollout
            )
        }
    }
}

private struct MultiThreadTimelineChart: View {
    let presentation: TimelinePresentation
    let window: TimelineWindow
    let selectedThreadID: String?
    let selectedSessionKey: String?
    let selectWindow: (TimelineWindow) -> Void
    let selectThread: (String) -> Void
    let selectPoint: (String) -> Void
    let resetFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThreadChartLegend(
                series: presentation.series,
                window: window,
                selectWindow: selectWindow,
                selectedThreadID: selectedThreadID,
                selectThread: selectThread
            )

            Chart {
                ForEach(presentation.series) { series in
                    ForEach(series.points) { point in
                        LineMark(
                            x: .value("Turn time", point.timestamp),
                            y: .value(
                                "Turn reasoning",
                                TimelineLogScale.plotValue(point.turnTotalReasoningTokens)
                            ),
                            series: .value("Thread", series.threadID)
                        )
                        .interpolationMethod(.linear)
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: lineWidth(for: series.threadID),
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .foregroundStyle(
                            seriesColor(for: series).opacity(lineOpacity(for: series.threadID))
                        )
                    }
                }

                ForEach(presentation.series) { series in
                    ForEach(series.points) { point in
                        PointMark(
                            x: .value("Turn time", point.timestamp),
                            y: .value(
                                "Turn reasoning",
                                TimelineLogScale.plotValue(point.turnTotalReasoningTokens)
                            )
                        )
                        .foregroundStyle(.clear)
                        .symbol {
                            TimelinePointSymbol(
                                point: point,
                                seriesColor: seriesColor(for: series),
                                diameter: presentation.nodeSizeScale.diameter(for: point.turnTotalTokens),
                                isSelected: point.id == selectedSessionKey,
                                opacity: pointOpacity(for: series.threadID)
                            )
                        }
                    }
                }
            }
            .chartXScale(domain: presentation.dateDomain)
            .chartYScale(domain: presentation.reasoningDomain, type: .log)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.10))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.14))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.7))
                        .foregroundStyle(.secondary.opacity(0.45))
                    AxisValueLabel {
                        if let tokens = value.as(Double.self) {
                            Text(numberText(Int(tokens.rounded())))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartPlotStyle { plotArea in
                plotArea.clipped()
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plotAnchor = proxy.plotFrame {
                        let plotFrame = geometry[plotAnchor]
                        ChartClickCapture { location, clickCount in
                            if clickCount >= 2 {
                                resetFocus()
                            } else {
                                handleSingleTap(location: location, proxy: proxy)
                            }
                        }
                        .frame(width: plotFrame.width, height: plotFrame.height)
                        .position(x: plotFrame.midX, y: plotFrame.midY)
                    }
                }
            }
        }
        .accessibilityLabel("Turn reasoning timeline grouped by thread")
        .animation(.easeOut(duration: 0.16), value: selectedThreadID)
    }

    private func handleSingleTap(
        location: CGPoint,
        proxy: ChartProxy
    ) {
        let renderedSeries = presentation.series.map { series in
            let renderedPoints = series.points.compactMap { point -> TimelineRenderedPoint? in
                guard let x = proxy.position(forX: point.timestamp),
                      let y = proxy.position(
                        forY: TimelineLogScale.plotValue(point.turnTotalReasoningTokens)
                      ) else {
                    return nil
                }
                return TimelineRenderedPoint(
                    pointID: point.id,
                    position: CGPoint(x: x, y: y)
                )
            }
            return TimelineRenderedSeries(
                threadID: series.threadID,
                points: renderedPoints
            )
        }

        switch TimelineHitTester.hitTest(
            location: location,
            series: renderedSeries,
            nodeRadius: 18,
            lineTolerance: 11
        ) {
        case let .point(pointID):
            selectPoint(pointID)
        case let .thread(threadID):
            selectThread(threadID)
        case nil:
            break
        }
    }

    private func seriesColor(for series: ThreadTimelineSeries) -> Color {
        PulsePalette.seriesColors[series.colorIndex % PulsePalette.seriesColors.count]
    }

    private func lineWidth(for threadID: String) -> CGFloat {
        guard let selectedThreadID else {
            return 1.8
        }
        return selectedThreadID == threadID ? 3.2 : 0.9
    }

    private func lineOpacity(for threadID: String) -> Double {
        guard let selectedThreadID else {
            return 0.72
        }
        return selectedThreadID == threadID ? 0.96 : 0.10
    }

    private func pointOpacity(for threadID: String) -> Double {
        guard let selectedThreadID else {
            return 0.86
        }
        return selectedThreadID == threadID ? 0.94 : 0.14
    }
}

private struct ThreadChartLegend: View {
    let series: [ThreadTimelineSeries]
    let window: TimelineWindow
    let selectWindow: (TimelineWindow) -> Void
    let selectedThreadID: String?
    let selectThread: (String) -> Void

    @State private var showsWindowPicker = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showsWindowPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("TURN")
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(window.shortLabel.uppercased())
                        .fontDesign(.monospaced)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(PulsePalette.accent)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $showsWindowPicker, arrowEdge: .top) {
                TimelineWindowWheel(
                    selection: window,
                    selectWindow: selectWindow
                )
            }
            .help("Scroll to expand history. Longer windows use more resources.")

            Divider()
                .frame(height: 15)

            ScrollView(.horizontal, showsIndicators: series.count > 3) {
                LazyHStack(spacing: 5) {
                    ForEach(series) { item in
                        Button {
                            selectThread(item.threadID)
                        } label: {
                            HStack(spacing: 5) {
                                Capsule(style: .continuous)
                                    .fill(seriesColor(item))
                                    .frame(width: 18, height: selectedThreadID == item.threadID ? 4 : 3)
                                Text(item.shortLabel)
                                    .font(.system(size: 9.5, weight: selectedThreadID == item.threadID ? .bold : .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 190)
                            }
                            .foregroundStyle(itemForegroundStyle(item))
                            .opacity(itemOpacity(item))
                            .padding(.horizontal, 5)
                            .frame(height: 20)
                            .fixedSize(horizontal: true, vertical: false)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(selectedThreadID == item.threadID
                                        ? seriesColor(item).opacity(0.20)
                                        : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(item.shortLabel)
                    }
                }
            }
            .contentMargins(.horizontal, 2, for: .scrollContent)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
    }

    private func seriesColor(_ item: ThreadTimelineSeries) -> Color {
        PulsePalette.seriesColors[item.colorIndex % PulsePalette.seriesColors.count]
    }

    private func itemOpacity(_ item: ThreadTimelineSeries) -> Double {
        guard let selectedThreadID else {
            return 0.88
        }
        return selectedThreadID == item.threadID ? 1 : 0.36
    }

    private func itemForegroundStyle(_ item: ThreadTimelineSeries) -> Color {
        guard let selectedThreadID else {
            return Color.primary
        }
        return selectedThreadID == item.threadID ? Color.primary : Color.secondary
    }
}

private struct TimelineWindowWheel: View {
    let selection: TimelineWindow
    let selectWindow: (TimelineWindow) -> Void

    @State private var scrollSelection: TimelineWindow?

    var body: some View {
        VStack(spacing: 6) {
            Text("HISTORY")
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(PulsePalette.accent.opacity(0.10))
                    .frame(height: 28)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(PulsePalette.accent.opacity(0.28), lineWidth: 1)
                    }

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(TimelineWindow.allCases) { window in
                            Text(window.shortLabel)
                                .font(
                                    .system(
                                        size: scrollSelection == window ? 14 : 11,
                                        weight: scrollSelection == window ? .bold : .medium,
                                        design: .monospaced
                                    )
                                )
                                .foregroundStyle(
                                    scrollSelection == window
                                        ? Color.primary
                                        : Color.secondary.opacity(0.62)
                                )
                                .scaleEffect(scrollSelection == window ? 1 : 0.92)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        scrollSelection = window
                                    }
                                }
                                .id(window)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 42)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .scrollPosition(id: $scrollSelection, anchor: .center)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.30), location: 0.16),
                            .init(color: .black, location: 0.40),
                            .init(color: .black, location: 0.60),
                            .init(color: .black.opacity(0.30), location: 0.84),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(width: 96, height: 112)

            Text("More history uses more resources")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(10)
        .onAppear {
            scrollSelection = selection
        }
        .onChange(of: scrollSelection) { _, nextWindow in
            if let nextWindow, nextWindow != selection {
                selectWindow(nextWindow)
            }
        }
    }
}

private struct ChartClickCapture: NSViewRepresentable {
    let onClick: (CGPoint, Int) -> Void

    func makeNSView(context: Context) -> ChartClickCaptureView {
        let view = ChartClickCaptureView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ChartClickCaptureView, context: Context) {
        nsView.onClick = onClick
    }
}

private final class ChartClickCaptureView: NSView {
    var onClick: ((CGPoint, Int) -> Void)?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onClick?(point, event.clickCount)
    }
}

private struct TimelinePointSymbol: View {
    let point: TimelinePoint
    let seriesColor: Color
    let diameter: Double
    let isSelected: Bool
    let opacity: Double

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(seriesColor.opacity(0.16))
                    .padding(-5)
            }

            Circle()
                .fill(seriesColor)

            if point.isRunning {
                Circle()
                    .strokeBorder(PulsePalette.running, lineWidth: 1.5)
                    .padding(-2)
            }

            if isSelected {
                Circle()
                    .strokeBorder(Color.primary, lineWidth: 2)
                    .padding(-3)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .topTrailing) {
            if point.session.signalState == .invalid {
                Circle()
                    .fill(PulsePalette.invalid)
                    .frame(width: statusBadgeDiameter, height: statusBadgeDiameter)
                    .overlay {
                        Circle()
                            .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                    }
                    .offset(x: 2, y: -2)
            } else if point.session.signalState == .unknown {
                Circle()
                    .fill(PulsePalette.unknown)
                    .frame(width: statusBadgeDiameter, height: statusBadgeDiameter)
                    .overlay {
                        Circle()
                            .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                    }
                    .offset(x: 2, y: -2)
            }
        }
        .opacity(opacity)
        .shadow(color: isSelected ? Color.black.opacity(0.18) : .clear, radius: 3, y: 1)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        "\(point.session.threadTitle), \(numberText(point.turnTotalReasoningTokens)) reasoning tokens, \(numberText(point.turnTotalTokens)) total tokens"
    }

    private var statusBadgeDiameter: Double {
        min(max(diameter * 0.34, 4), 6)
    }
}

private enum TurnInspectorPage: Int, CaseIterable, Identifiable {
    case reasoning
    case tokenMix

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .reasoning:
            return "Reasoning"
        case .tokenMix:
            return "Token Mix"
        }
    }
}

private struct ReasoningTurnInspector: View {
    let point: TimelinePoint
    let reasoningSamples: [TurnReasoningSample]
    let isLoadingDetails: Bool
    let openRollout: () -> Bool

    @State private var page: TurnInspectorPage? = .reasoning

    private var samples: [TimelineSamplePoint] {
        let source = reasoningSamples.isEmpty
            ? [TurnReasoningSample(observedAt: point.timestamp, tokenUsage: point.session.tokenUsage)]
            : reasoningSamples
        return source.enumerated().map { index, sample in
            TimelineSamplePoint(
                id: "\(point.id):detail:\(index):\(sample.id)",
                timestamp: sample.observedAt,
                reasoningTokens: sample.reasoningOutputTokens
            )
        }
    }

    var body: some View {
        let preparedSamples = samples
        let preparedSummary = ReasoningSampleSummary(samples: preparedSamples)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(point.session.projectName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text("/")
                    .foregroundStyle(.tertiary)
                Text(point.session.threadTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(point.session.model ?? "–")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(point.session.reasoningEffort ?? "–")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Button("Open Rollout") {
                    _ = openRollout()
                }
                .buttonStyle(.link)
                .font(.system(size: 9.5, weight: .semibold))
                .disabled(point.session.rolloutPath == nil)
            }

            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        reasoningPage(
                            samples: preparedSamples,
                            summary: preparedSummary
                        )
                            .frame(width: geometry.size.width)
                            .id(TurnInspectorPage.reasoning)

                        tokenMixPage
                            .frame(width: geometry.size.width)
                            .id(TurnInspectorPage.tokenMix)
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $page)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack(spacing: 7) {
                Text(point.timestamp.formatted(date: .omitted, time: .shortened))
                Text(point.session.turnId ?? "unknown turn")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()

                Button {
                    setPage(.reasoning)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(currentPage == .reasoning)
                .accessibilityLabel("Show reasoning details")

                Text(currentPage.title.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 72)

                HStack(spacing: 4) {
                    ForEach(TurnInspectorPage.allCases) { item in
                        Circle()
                            .fill(item == currentPage ? threadColor : Color.secondary.opacity(0.28))
                            .frame(width: 4, height: 4)
                    }
                }

                Button {
                    setPage(.tokenMix)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(currentPage == .tokenMix)
                .accessibilityLabel("Show token mix details")
            }
            .font(.system(size: 8.8, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PulsePalette.accent.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .contentShape(Rectangle())
        .help("Swipe left or right to switch between Reasoning and Token Mix")
    }

    private func reasoningPage(
        samples: [TimelineSamplePoint],
        summary: ReasoningSampleSummary
    ) -> some View {
        HStack(spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                metricRow("CALLS", summary.count.formatted())
                metricRow("REASONING", numberText(point.turnTotalReasoningTokens))
                metricRow(
                    "RANGE",
                    "\(numberText(summary.minimum))–\(numberText(summary.maximum))"
                )
                metricRow("MEDIAN", numberText(summary.median))
                metricRow("SPAN", durationText(summary.duration))
            }
            .frame(width: 156, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("MODEL CALL REASONING OVER TIME · LOG")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                    if isLoadingDetails {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                Chart(TimelineSampleDownsampler.reduce(samples, limit: 36)) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Reasoning", sample.plotReasoningTokens)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(threadColor.opacity(0.78))

                    PointMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Reasoning", sample.plotReasoningTokens)
                    )
                    .symbolSize(10)
                    .foregroundStyle(threadColor.opacity(0.88))
                }
                .chartYScale(
                    domain: TimelineLogScale.domain(for: samples.map(\.reasoningTokens)),
                    type: .log
                )
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.025))
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var tokenMixPage: some View {
        HStack(spacing: 12) {
            usageColumn(
                title: "LAST CALL",
                usage: point.session.tokenUsage.last,
                reasoningTokens: point.session.tokenUsage.last.reasoningOutputTokens,
                allTokens: lastCallTotalTokens
            )

            Divider()

            usageColumn(
                title: "TURN TOTAL",
                usage: point.session.tokenUsage.total,
                reasoningTokens: point.turnTotalReasoningTokens,
                allTokens: point.turnTotalTokens
            )

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("RATIOS")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)

                ratioMetric(
                    "Cached / input",
                    value: cachedInputRatio,
                    tint: PulsePalette.accent
                )
                ratioMetric(
                    "Reasoning / output",
                    value: reasoningOutputRatio,
                    tint: PulsePalette.running
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func usageColumn(
        title: String,
        usage: TurnUsage,
        reasoningTokens: Int,
        allTokens: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
                metricRow("REASONING", numberText(reasoningTokens))
                metricRow("OUTPUT", numberText(usage.outputTokens))
                metricRow("CACHED", numberText(usage.cachedInputTokens))
                metricRow("INPUT", numberText(usage.inputTokens))
                metricRow("ALL TOKENS", numberText(allTokens))
            }
        }
        .frame(width: 182, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private func ratioMetric(_ label: String, value: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .foregroundStyle(tint)
            }
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.secondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: geometry.size.width * value)
                }
            }
            .frame(height: 6)
        }
    }

    private var lastCallTotalTokens: Int {
        let usage = point.session.tokenUsage.last
        return max(usage.totalTokens, usage.inputTokens + usage.outputTokens, usage.reasoningOutputTokens)
    }

    private var cachedInputRatio: Double {
        ratio(
            numerator: point.session.tokenUsage.total.cachedInputTokens,
            denominator: point.session.tokenUsage.total.inputTokens
        )
    }

    private var reasoningOutputRatio: Double {
        ratio(
            numerator: point.turnTotalReasoningTokens,
            denominator: point.session.tokenUsage.total.outputTokens
        )
    }

    private func ratio(numerator: Int, denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0
        }
        return min(max(Double(numerator) / Double(denominator), 0), 1)
    }

    private func setPage(_ nextPage: TurnInspectorPage) {
        guard nextPage != currentPage else {
            return
        }
        withAnimation(.snappy(duration: 0.24)) {
            page = nextPage
        }
    }

    private var currentPage: TurnInspectorPage {
        page ?? .reasoning
    }

    private var statusColor: Color {
        if point.session.signalState == .invalid {
            return PulsePalette.invalid
        }
        if point.isRunning {
            return PulsePalette.running
        }
        if point.session.signalState == .unknown {
            return PulsePalette.unknown
        }
        return PulsePalette.valid
    }

    private var threadColor: Color {
        let index = TimelinePresentationBuilder.stablePaletteIndex(
            threadID: point.threadID,
            paletteCount: PulsePalette.seriesColors.count
        )
        return PulsePalette.seriesColors[index]
    }

    private func durationText(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return "\(Int(duration.rounded()))s"
        }
        return "\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s"
    }
}


private struct CompactHeaderMetric: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(value.formatted())
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

private struct CompactErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.12))
        )
        .help(message)
    }
}

private func numberText(_ number: Int) -> String {
    number.formatted(.number.grouping(.automatic))
}

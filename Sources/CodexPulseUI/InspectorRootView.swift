import AppKit
import Charts
import Core
import SwiftUI

struct InspectorRootView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .frame(height: 48)

            Divider()
                .opacity(0.55)

            toolbar
                .padding(.horizontal, 12)
                .frame(height: 40)

            if let message = model.errorBannerMessage {
                CompactErrorBanner(message: message)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            timelineContent
                .padding(.horizontal, 12)
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

    private var header: some View {
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

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search projects or threads", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
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
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PulsePalette.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            }

            Picker(
                "Time window",
                selection: Binding(
                    get: { model.selectedTimelineWindow },
                    set: { model.setTimelineWindow($0) }
                )
            ) {
                ForEach(TimelineWindow.allCases) { window in
                    Text(window.shortLabel)
                        .tag(window)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 166)
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        if model.timelineSeries.isEmpty {
            ContentUnavailableView(
                model.searchQuery.isEmpty ? "No turns in this window" : "No matching threads",
                systemImage: "chart.xyaxis.line",
                description: Text(model.searchQuery.isEmpty
                    ? "Live and completed turns will appear on the timeline."
                    : "Try a project name, thread title, model, or preview text.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pulseSurface()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                chartHeading

                MultiThreadTimelineChart(model: model)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: chartMinimumHeight,
                        maxHeight: .infinity
                    )
                    .layoutPriority(1)

                if let point = model.selectedTimelinePoint {
                    ReasoningTurnInspector(
                        point: point,
                        openRollout: model.openSelectedRollout
                    )
                    .frame(height: 126)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(10)
            .pulseSurface()
            .animation(.easeOut(duration: 0.16), value: model.selectedSessionKey)
        }
    }

    private var chartHeading: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("MULTI-THREAD · \(model.selectedTimelineWindow.shortLabel.uppercased())")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(PulsePalette.accent)
                Text("Turn total (L) · model call (R)")
                    .font(.caption.weight(.semibold))
            }

            Spacer()

            if let selectedSeries = model.selectedThreadSeries {
                HStack(spacing: 6) {
                    Capsule(style: .continuous)
                        .fill(seriesColor(selectedSeries))
                        .frame(width: 20, height: 4)
                    Text(selectedSeries.shortLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 9.5, weight: .bold))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    Capsule(style: .continuous)
                        .fill(seriesColor(selectedSeries).opacity(0.16))
                )
            } else {
                Text("\(model.timelinePoints.count) turns · click line to focus · double-click to reset")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: 26)
    }

    private func seriesColor(_ series: ThreadTimelineSeries) -> Color {
        PulsePalette.seriesColors[series.colorIndex % PulsePalette.seriesColors.count]
    }

    private var chartMinimumHeight: CGFloat {
        if model.selectedTimelinePoint != nil {
            return model.errorBannerMessage == nil ? 220 : 180
        }
        return model.errorBannerMessage == nil ? 260 : 220
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

private struct MultiThreadTimelineChart: View {
    @Bindable var model: AppModel

    var body: some View {
        let scale = dualScale

        VStack(alignment: .leading, spacing: 6) {
            ThreadChartLegend(
                series: model.timelineSeries,
                selectedThreadID: model.selectedThreadID,
                selectThread: model.selectThreadLine
            )

            Chart {
                // Layer 1: per-call traces. The Turn ID is the series key, so
                // these lines can never bridge two Turns.
                ForEach(model.timelineSeries) { series in
                    ForEach(series.points) { point in
                        if point.session.reasoningSamples.count > 1 {
                            ForEach(point.displayedReasoningSamples) { sample in
                                LineMark(
                                    x: .value("Sample time", sample.timestamp),
                                    y: .value(
                                        "Call reasoning axis",
                                        scale.callPosition(for: sample.reasoningTokens)
                                    ),
                                    series: .value("Turn call trace", point.callTraceSeriesID)
                                )
                                .interpolationMethod(.monotone)
                                .lineStyle(
                                    StrokeStyle(
                                        lineWidth: sampleLineWidth(for: series.threadID),
                                        lineCap: .round,
                                        lineJoin: .round
                                    )
                                )
                                .foregroundStyle(
                                    seriesColor(for: series).opacity(sampleOpacity(for: series.threadID))
                                )

                                PointMark(
                                    x: .value("Sample time", sample.timestamp),
                                    y: .value(
                                        "Call reasoning axis",
                                        scale.callPosition(for: sample.reasoningTokens)
                                    )
                                )
                                .symbolSize(model.selectedThreadID == series.threadID ? 8 : 4)
                                .foregroundStyle(
                                    seriesColor(for: series).opacity(samplePointOpacity(for: series.threadID))
                                )
                            }
                        }
                    }
                }

                // Layer 2: selected Thread glow, aligned only to Turn-total nodes.
                ForEach(model.timelineSeries) { series in
                    if model.selectedThreadID == series.threadID {
                        ForEach(series.points) { point in
                            LineMark(
                                x: .value("Turn time", point.timestamp),
                                y: .value(
                                    "Turn total axis",
                                    scale.turnPosition(for: point.turnTotalReasoningTokens)
                                ),
                                series: .value("Selected Turn-total Thread", series.threadID)
                            )
                            .interpolationMethod(.monotone)
                            .lineStyle(
                                StrokeStyle(
                                    lineWidth: 12,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                            .foregroundStyle(seriesColor(for: series).opacity(0.26))
                        }
                    }
                }

                // Layer 3: cross-Turn backbone. Only large Turn-total nodes feed it.
                ForEach(model.timelineSeries) { series in
                    ForEach(series.points) { point in
                        LineMark(
                            x: .value("Turn time", point.timestamp),
                            y: .value(
                                "Turn total axis",
                                scale.turnPosition(for: point.turnTotalReasoningTokens)
                            ),
                            series: .value("Turn-total Thread", series.threadID)
                        )
                        .interpolationMethod(.monotone)
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

                // Layer 4: interactive Turn-total nodes stay above every call trace.
                ForEach(model.timelineSeries) { series in
                    ForEach(series.points) { point in
                        PointMark(
                            x: .value("Turn time", point.timestamp),
                            y: .value(
                                "Turn total axis",
                                scale.turnPosition(for: point.turnTotalReasoningTokens)
                            )
                        )
                        .foregroundStyle(.clear)
                        .symbol {
                            TimelinePointSymbol(
                                point: point,
                                seriesColor: seriesColor(for: series),
                                isSelected: point.id == model.selectedSessionKey,
                                opacity: pointOpacity(for: series.threadID)
                            )
                        }
                    }
                }
            }
            .chartXScale(domain: model.timelineDomain)
            .chartYScale(domain: 0.0...1.0)
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
                AxisMarks(position: .leading, values: scale.turnTickPositions) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.14))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.7))
                        .foregroundStyle(.secondary.opacity(0.45))
                    AxisValueLabel {
                        if let position = value.as(Double.self) {
                            Text(numberText(scale.turnLabel(at: position)))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                AxisMarks(position: .trailing, values: scale.callTickPositions) { value in
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.7))
                        .foregroundStyle(PulsePalette.accent.opacity(0.55))
                    AxisValueLabel {
                        if let position = value.as(Double.self) {
                            Text(numberText(scale.callLabel(at: position)))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(PulsePalette.accent.opacity(0.82))
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
                                model.resetTimelineFocus()
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
        .accessibilityLabel("Reasoning timeline grouped by thread")
        .animation(.easeOut(duration: 0.16), value: model.selectedThreadID)
    }

    private var dualScale: TimelineDualLogScale {
        TimelineDualLogScale(
            turnValues: model.timelinePoints.map(\.turnTotalReasoningTokens),
            callValues: model.timelinePoints.flatMap { point in
                point.reasoningSamples.map(\.reasoningTokens)
            }
        )
    }

    private func handleSingleTap(
        location: CGPoint,
        proxy: ChartProxy
    ) {
        let scale = dualScale
        let renderedSeries = model.timelineSeries.map { series in
            TimelineRenderedSeries(
                threadID: series.threadID,
                points: series.points.compactMap { point in
                    guard let x = proxy.position(forX: point.timestamp),
                          let y = proxy.position(
                            forY: scale.turnPosition(for: point.turnTotalReasoningTokens)
                          ) else {
                        return nil
                    }
                    return TimelineRenderedPoint(
                        pointID: point.id,
                        position: CGPoint(x: x, y: y)
                    )
                },
                lineRuns: series.points.compactMap { point in
                    let positions = point.displayedReasoningSamples.compactMap { sample -> CGPoint? in
                        guard let x = proxy.position(forX: sample.timestamp),
                              let y = proxy.position(
                                forY: scale.callPosition(for: sample.reasoningTokens)
                              ) else {
                            return nil
                        }
                        return CGPoint(x: x, y: y)
                    }
                    return positions.count > 1 ? positions : nil
                }
            )
        }

        switch TimelineHitTester.hitTest(
            location: location,
            series: renderedSeries,
            nodeRadius: 18,
            lineTolerance: 15
        ) {
        case let .point(pointID):
            model.selectTimelinePoint(pointID)
        case let .thread(threadID):
            model.selectThreadLine(threadID)
        case nil:
            break
        }
    }

    private func seriesColor(for series: ThreadTimelineSeries) -> Color {
        PulsePalette.seriesColors[series.colorIndex % PulsePalette.seriesColors.count]
    }

    private func lineWidth(for threadID: String) -> CGFloat {
        guard let selectedThreadID = model.selectedThreadID else {
            return 3.4
        }
        return selectedThreadID == threadID ? 5.6 : 1.2
    }

    private func lineOpacity(for threadID: String) -> Double {
        guard let selectedThreadID = model.selectedThreadID else {
            return 0.90
        }
        return selectedThreadID == threadID ? 1 : 0.10
    }

    private func pointOpacity(for threadID: String) -> Double {
        guard let selectedThreadID = model.selectedThreadID else {
            return 0.78
        }
        return selectedThreadID == threadID ? 0.94 : 0.14
    }

    private func sampleLineWidth(for threadID: String) -> CGFloat {
        guard let selectedThreadID = model.selectedThreadID else {
            return 0.8
        }
        return selectedThreadID == threadID ? 1.35 : 0.5
    }

    private func sampleOpacity(for threadID: String) -> Double {
        guard let selectedThreadID = model.selectedThreadID else {
            return 0.26
        }
        return selectedThreadID == threadID ? 0.56 : 0.045
    }

    private func samplePointOpacity(for threadID: String) -> Double {
        guard let selectedThreadID = model.selectedThreadID else {
            return 0.30
        }
        return selectedThreadID == threadID ? 0.62 : 0.055
    }
}

private struct ThreadChartLegend: View {
    let series: [ThreadTimelineSeries]
    let selectedThreadID: String?
    let selectThread: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: series.count > 3) {
            LazyHStack(spacing: 5) {
                ForEach(series) { item in
                    Button {
                        selectThread(item.threadID)
                    } label: {
                        HStack(spacing: 5) {
                            Capsule(style: .continuous)
                                .fill(seriesColor(item))
                                .frame(width: 20, height: selectedThreadID == item.threadID ? 4 : 3)
                            Text(item.threadTitle)
                                .font(.system(size: 9.5, weight: selectedThreadID == item.threadID ? .bold : .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 150)
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 20)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selectedThreadID == item.threadID
                                    ? seriesColor(item).opacity(0.22)
                                    : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(item.shortLabel)
                }
            }
        }
        .contentMargins(.horizontal, 5, for: .scrollContent)
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
    let isSelected: Bool
    let opacity: Double

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(seriesColor.opacity(0.16))
                    .padding(-5)
            }

            if point.session.signalState == .unknown {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                Circle()
                    .strokeBorder(PulsePalette.unknown, lineWidth: 1.5)
            } else {
                Circle()
                    .fill(point.session.signalState == .invalid ? PulsePalette.invalid : seriesColor)
            }

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
        .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
        .opacity(opacity)
        .shadow(color: isSelected ? Color.black.opacity(0.18) : .clear, radius: 3, y: 1)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        "\(point.session.threadTitle), \(numberText(point.turnTotalReasoningTokens)) total reasoning tokens"
    }
}

private struct ReasoningTurnInspector: View {
    let point: TimelinePoint
    let openRollout: () -> Bool

    private var samples: [TimelineSamplePoint] {
        point.reasoningSamples
    }

    private var summary: ReasoningSampleSummary {
        ReasoningSampleSummary(samples: samples)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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

            HStack(spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    reasoningMetric("CALLS", summary.count.formatted())
                    reasoningMetric("TURN TOTAL", numberText(point.turnTotalReasoningTokens))
                    reasoningMetric(
                        "RANGE",
                        "\(numberText(summary.minimum))–\(numberText(summary.maximum))"
                    )
                    reasoningMetric("MEDIAN", numberText(summary.median))
                    reasoningMetric("SPAN", durationText(summary.duration))
                }
                .frame(width: 156, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("REASONING TOKENS OVER TIME · LOG")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)

                    Chart(samples) { sample in
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

            HStack(spacing: 7) {
                Text(point.timestamp.formatted(date: .omitted, time: .shortened))
                Text(point.session.turnId ?? "unknown turn")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("Large node = Turn · small nodes = model calls")
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
    }

    private func reasoningMetric(_ label: String, _ value: String) -> some View {
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

import Core
import SwiftUI

struct InspectorRootView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let errorBannerMessage = model.errorBannerMessage {
                ErrorBannerView(message: errorBannerMessage)
            }

            if model.recentReasoningSessions.isEmpty {
                ContentUnavailableView(
                    "No completed replies",
                    systemImage: "text.bubble",
                    description: Text("Wait for a completed turn, then refresh.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(
                    sessions: model.recentReasoningSessions,
                    selectedKey: model.selectedCompletedSession?.key,
                    onSelect: model.selectSession
                )

                if let session = model.selectedCompletedSession {
                    SessionDetailCard(
                        session: session,
                        openRollout: model.openSelectedRollout
                    )
                }
            }
        }
        .padding(14)
        .frame(minWidth: 430, idealWidth: 430, maxWidth: 430, minHeight: 300, idealHeight: 300, maxHeight: 340, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reasoning Timeline")
                    .font(.headline)
                Text(lastRefreshLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if invalidCount > 0 {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("\(invalidCount) invalid")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
            }

            Button {
                model.refreshNow()
            } label: {
                Image(systemName: model.isRefreshing ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(model.isRefreshing)
        }
    }

    private var invalidCount: Int {
        model.recentReasoningSessions.filter(\.isInvalidReasoning).count
    }

    private var lastRefreshLabel: String {
        guard let lastRefreshAt = model.lastRefreshAt else {
            return "Waiting for first refresh"
        }
        return "Updated \(lastRefreshAt.formatted(date: .omitted, time: .standard))"
    }
}

private struct TimelineView: View {
    let sessions: [CompletedSession]
    let selectedKey: String?
    let onSelect: (String?) -> Void

    var body: some View {
        ZStack(alignment: .center) {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 2)
                .padding(.horizontal, 34)

            HStack(alignment: .top, spacing: 12) {
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
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TimelineNode: View {
    let session: CompletedSession
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text("\(session.timelineReasoningTokens)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(session.isInvalidReasoning ? .red : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            ZStack {
                Circle()
                    .fill(nodeFill)
                    .frame(width: isSelected ? 20 : 16, height: isSelected ? 20 : 16)
                Circle()
                    .strokeBorder(nodeStroke, lineWidth: isSelected ? 3 : 2)
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

    private var nodeFill: Color {
        session.isInvalidReasoning ? .red : .green
    }

    private var nodeStroke: Color {
        isSelected ? .primary : nodeFill.opacity(0.45)
    }
}

private struct SessionDetailCard: View {
    let session: CompletedSession
    let openRollout: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(session.isInvalidReasoning ? Color.red : Color.green)
                    .frame(width: 10, height: 10)

                Text(session.projectName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(session.isInvalidReasoning ? "Invalid reply" : "Valid reply")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(session.isInvalidReasoning ? .red : .green)
            }

            Text(session.threadTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(session.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 10) {
                MetricChip(label: "Last", value: session.tokenUsage.last.reasoningOutputTokens, tint: session.isInvalidReasoning ? .red : .primary)
                MetricChip(label: "Total", value: session.tokenUsage.total.reasoningOutputTokens, tint: .primary)
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct MetricChip: View {
    let label: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
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
                .font(.caption)
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

private func formatDate(_ date: Date?) -> String {
    guard let date else {
        return "-"
    }
    return date.formatted(date: .omitted, time: .shortened)
}

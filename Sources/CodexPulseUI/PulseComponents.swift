import SwiftUI

enum PulsePalette {
    static let accent = Color(red: 0.33, green: 0.42, blue: 0.98)
    static let valid = Color(red: 0.12, green: 0.68, blue: 0.50)
    static let invalid = Color(red: 0.93, green: 0.25, blue: 0.34)
    static let running = Color(red: 0.96, green: 0.57, blue: 0.17)
    static let unknown = Color.secondary
    static let surface = Color(nsColor: .controlBackgroundColor).opacity(0.86)
}

struct HeaderMetric: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.formatted())
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(value == 0 ? .secondary : .primary)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(value == 0 ? 0.055 : 0.10))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

struct SectionHeading: View {
    let eyebrow: String
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(PulsePalette.accent)
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SignalLegend: View {
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PulseSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PulsePalette.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.075), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.035), radius: 12, y: 5)
    }
}

extension View {
    func pulseSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(PulseSurfaceModifier(cornerRadius: cornerRadius))
    }
}

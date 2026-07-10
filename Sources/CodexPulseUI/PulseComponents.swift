import SwiftUI

enum PulsePalette {
    static let accent = Color(red: 0.33, green: 0.42, blue: 0.98)
    static let valid = Color(red: 0.12, green: 0.68, blue: 0.50)
    static let invalid = Color(red: 0.93, green: 0.25, blue: 0.34)
    static let running = Color(red: 0.96, green: 0.57, blue: 0.17)
    static let unknown = Color.secondary
    static let surface = Color(nsColor: .controlBackgroundColor).opacity(0.86)
    static let seriesColors: [Color] = [
        Color(red: 0.30, green: 0.68, blue: 0.78),
        Color(red: 0.36, green: 0.48, blue: 0.82),
        Color(red: 0.66, green: 0.50, blue: 0.76),
        Color(red: 0.52, green: 0.65, blue: 0.48),
        Color(red: 0.86, green: 0.75, blue: 0.36),
        Color(red: 0.90, green: 0.89, blue: 0.84),
        Color(red: 0.58, green: 0.61, blue: 0.65),
        Color(red: 0.67, green: 0.58, blue: 0.48),
    ]
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

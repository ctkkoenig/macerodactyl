import SwiftUI

/// One shared status-color definition used everywhere on both surfaces:
/// green running, red stopped, amber transitioning/unhealthy. Kept small and
/// semantic so the palette stays consistent and legible in light and dark.
public enum StatusPalette {
    public static func color(for container: DockerContainer) -> Color {
        switch (container.state, container.health) {
        case (.running, .unhealthy), (.running, .starting): .orange
        case (.running, _): .green
        case (.restarting, _), (.paused, _), (.removing, _): .orange
        default: .red
        }
    }

    public static func label(for container: DockerContainer) -> String {
        if let health = container.health, container.isRunning { return health.rawValue }
        return container.state.rawValue
    }
}

/// A small status dot. Uses a plain filled circle — no gradient, no glow.
public struct StatusDot: View {
    let container: DockerContainer
    var size: CGFloat = 9

    public init(container: DockerContainer, size: CGFloat = 9) {
        self.container = container
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(StatusPalette.color(for: container))
            .frame(width: size, height: size)
            .accessibilityLabel(StatusPalette.label(for: container))
    }
}

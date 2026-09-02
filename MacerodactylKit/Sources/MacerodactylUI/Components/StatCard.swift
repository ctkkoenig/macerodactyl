import MacerodactylKit
import SwiftUI

/// The live resource stat card — the app's one deliberately memorable element.
/// A quiet container with a large measured value, a thin accent tick, and an
/// optional sparkline built only from real samples. Everything else in the app
/// stays plainer than this on purpose.
public struct StatCard: View {
    let title: String
    let value: String
    let secondary: String?
    let accent: Color
    /// Fraction 0...1 for the mini-meter, or nil to omit it.
    let fraction: Double?
    /// Measured samples (0...1) for the sparkline, oldest first. Empty = none yet.
    let samples: [Double]
    let unavailable: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String, value: String, secondary: String? = nil, accent: Color = .accentColor,
        fraction: Double? = nil, samples: [Double] = [], unavailable: Bool = false
    ) {
        self.title = title
        self.value = value
        self.secondary = secondary
        self.accent = accent
        self.fraction = fraction
        self.samples = samples
        self.unavailable = unavailable
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(unavailable ? Color.secondary.opacity(0.4) : accent)
                    .frame(width: 3, height: 11)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if unavailable {
                Text("Unavailable")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxHeight: .infinity, alignment: .center)
            } else {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                if !samples.isEmpty {
                    Sparkline(samples: samples, color: accent)
                        .frame(height: 22)
                } else if fraction != nil {
                    Meter(fraction: fraction ?? 0, color: accent)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

/// A thin horizontal meter (used when there's a fraction but no history yet).
struct Meter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}

/// A sparkline of measured samples only (0...1, oldest first). Never seeded
/// with placeholder points — it starts empty and fills as readings arrive.
struct Sparkline: View {
    let samples: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let count = samples.count
            Path { path in
                guard count > 1 else { return }
                let stepX = geo.size.width / CGFloat(count - 1)
                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = geo.size.height * (1 - CGFloat(max(0, min(1, sample))))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The stat-card row shown on Console and Overview. Fed by the focused stream.
public struct StatCardRow: View {
    let stats: ContainerStats?
    let availability: StatsAvailability
    let cpuHistory: [Double]
    let memHistory: [Double]
    let uptime: String?

    public init(stats: ContainerStats?, availability: StatsAvailability, cpuHistory: [Double], memHistory: [Double], uptime: String?) {
        self.stats = stats
        self.availability = availability
        self.cpuHistory = cpuHistory
        self.memHistory = memHistory
        self.uptime = uptime
    }

    private var unavailable: Bool {
        if case .available = availability { return false }
        return true
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .unavailable(let reason) = availability {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if case .measuring = availability, stats == nil {
                Text("Measuring…").font(.caption).foregroundStyle(.secondary)
            }
            let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
            LazyVGrid(columns: columns, spacing: 10) {
                StatCard(
                    title: "CPU", value: cpuValue, accent: .blue,
                    samples: cpuHistory, unavailable: unavailable)
                StatCard(
                    title: "Memory", value: memValue, secondary: memSecondary, accent: .purple,
                    fraction: stats.map { $0.memPercent / 100 }, samples: memHistory, unavailable: unavailable)
                StatCard(
                    title: "Network", value: netValue, secondary: netSecondary, accent: .teal,
                    unavailable: unavailable)
                StatCard(
                    title: "Uptime", value: uptime ?? "—", accent: .green,
                    unavailable: unavailable && uptime == nil)
            }
        }
    }

    private var cpuValue: String { stats.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "—" }
    private var memValue: String { stats.map { ByteFormat.string($0.memUsedBytes) } ?? "—" }
    private var memSecondary: String? { stats.map { "of \(ByteFormat.string($0.memLimitBytes))" } }
    private var netValue: String { stats.map { "↓ \(ByteFormat.string($0.netRxBytes))" } ?? "—" }
    private var netSecondary: String? { stats.map { "↑ \(ByteFormat.string($0.netTxBytes))" } }
}

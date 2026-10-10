import AppKit
import SwiftUI

enum Theme {
    static let bg = Color(red: 0.055, green: 0.062, blue: 0.074)
    static let card = Color(red: 0.105, green: 0.118, blue: 0.138)
    static let line = Color.white.opacity(0.08)
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.38)
    static let neutral = Color(red: 0.55, green: 0.74, blue: 0.86)

    static func gauge(_ fraction: Double, polarity: Polarity) -> Color {
        let hot: Double
        switch polarity {
        case .usage: hot = fraction
        case .health: hot = 1 - fraction
        case .neutral: return neutral
        }
        if hot < 0.55 { return Color(red: 0.49, green: 0.82, blue: 0.52) }
        if hot < 0.82 { return Color(red: 0.95, green: 0.72, blue: 0.32) }
        return Color(red: 0.93, green: 0.38, blue: 0.36)
    }
}

struct DashboardView: View {
    var model: ProfilerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !model.snapshot.heroes.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        ForEach(model.snapshot.heroes) { metric in
                            HeroTile(metric: metric)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 460), spacing: 14)], spacing: 14) {
                    ForEach(model.snapshot.groups) { group in
                        GroupCard(group: group)
                    }
                }
                ProcessCard(processes: model.snapshot.processes, memoryCeiling: model.snapshot.memoryCeiling)
                footnote
            }
            .padding(22)
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .background(WindowChrome())
        .frame(minWidth: 880, minHeight: 640)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MAC PROFILER")
                    .font(.caption.weight(.semibold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.secondary)
                Text(model.snapshot.header.name)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.primary)
                Text(model.snapshot.header.detail)
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                Text(model.snapshot.header.os)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("LIVE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.gauge(0.2, polarity: .health))
                Text(model.snapshot.capturedAt, format: .dateTime.hour().minute().second())
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                Text("\(model.snapshot.readingCount) readings")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var footnote: some View {
        Text("Each bar is the live reading against a ceiling. Processor, graphics, and charge use 100%. Memory and disk space use what is installed. Disk throughput uses the class peak for this Mac’s SSD, not a speed test. Network throughput uses the current Wi-Fi radio rate when macOS reports it. Power uses the sustained envelope of this machine. CPU die temperature is not available to apps; battery temperature and thermal pressure are the readings macOS does publish.")
            .font(.caption)
            .foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}

struct HeroTile: View {
    var metric: Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.name.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.secondary)
            Text(metric.reading)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            GaugeBar(fraction: metric.fraction, polarity: metric.polarity)
                .frame(height: 8)
            Text(metric.scale)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }
}

struct GroupCard: View {
    var group: MetricGroup

    private var cores: [Metric] {
        group.metrics.filter { $0.id.hasPrefix("cpu.core.") }
    }

    private var rows: [Metric] {
        group.metrics.filter { !$0.id.hasPrefix("cpu.core.") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: group.symbol)
                    .foregroundStyle(Theme.secondary)
                Text(group.title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer()
                Text("\(group.metrics.count + group.facts.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            if !group.facts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(group.facts) { fact in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.name)
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiary)
                            Text(fact.value)
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            ForEach(rows) { metric in
                MetricRow(metric: metric)
            }
            if !cores.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(cores) { metric in
                        CoreCell(metric: metric)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }
}

struct MetricRow: View {
    var metric: Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.name)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 8)
                Text(metric.reading)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
            }
            GaugeBar(fraction: metric.fraction, polarity: metric.polarity)
                .frame(height: 6)
            HStack(alignment: .firstTextBaseline) {
                Text(metric.note.map { "\(metric.scale) · \($0)" } ?? metric.scale)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(metric.percentText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}

struct CoreCell: View {
    var metric: Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text(metric.percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.primary)
            }
            GaugeBar(fraction: metric.fraction, polarity: metric.polarity)
                .frame(height: 4)
        }
        .padding(8)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct GaugeBar: View {
    var fraction: Double
    var polarity: Polarity

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.08))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.gauge(fraction, polarity: polarity))
                    .scaleEffect(x: max(fraction, 0.015), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
    }
}

struct ProcessCard: View {
    var processes: [ProcessLoad]
    var memoryCeiling: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "list.number")
                    .foregroundStyle(Theme.secondary)
                Text("Busiest processes")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer()
                Text("share of all cores")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            if processes.isEmpty {
                Text("Collecting the first second of CPU time.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
            } else {
                ForEach(processes) { process in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(process.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(String(format: "%.1f%%", process.machineShare * 100))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.primary)
                        }
                        GaugeBar(fraction: min(1, process.machineShare), polarity: .usage)
                            .frame(height: 6)
                        HStack {
                            Text(String(format: "of the whole CPU · %.0f%% of one core", process.coreShare * 100))
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiary)
                            Spacer()
                            Text(Format.bytes(process.memoryBytes) + (memoryCeiling > 0 ? " of \(Format.bytes(memoryCeiling))" : ""))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }
}

struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.style(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.style(nsView) }
    }

    private static func style(_ view: NSView) {
        guard let window = view.window else { return }
        window.titlebarAppearsTransparent = true
        window.title = "Mac Profiler"
        window.backgroundColor = NSColor(srgbRed: 0.055, green: 0.062, blue: 0.074, alpha: 1)
    }
}

struct MenuStatusView: View {
    var model: ProfilerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.snapshot.header.name)
                .font(.headline)
            ForEach(model.snapshot.heroes) { metric in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(metric.name)
                        Spacer()
                        Text(metric.reading).monospacedDigit()
                    }
                    .font(.callout)
                    GaugeBar(fraction: metric.fraction, polarity: metric.polarity)
                        .frame(height: 5)
                    Text(metric.scale)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Open Dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit Mac Profiler") {
                NSApp.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

import Foundation

enum Polarity: Equatable {
    /// High values fill the bar and shift toward red.
    case usage
    /// High values are the healthy end of the scale.
    case health
    /// The bar is only a scale. Color stays neutral.
    case neutral
}

struct Metric: Identifiable, Equatable {
    var id: String
    var name: String
    var value: Double
    var floor: Double
    var ceiling: Double
    /// The live number, already formatted.
    var reading: String
    /// What the right edge of the bar means.
    var scale: String
    var note: String?
    var polarity: Polarity

    var fraction: Double {
        let span = ceiling - floor
        guard span > 0, value.isFinite else { return 0 }
        return min(1, max(0, (value - floor) / span))
    }

    var percentText: String {
        let span = ceiling - floor
        guard span > 0, value.isFinite else { return "—" }
        return String(format: "%.0f%%", (value - floor) / span * 100)
    }
}

struct Fact: Identifiable, Equatable {
    var id: String
    var name: String
    var value: String
}

struct MetricGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
    var metrics: [Metric]
    var facts: [Fact]
}

struct ProcessLoad: Identifiable, Equatable {
    var id: Int32
    var name: String
    /// 0...1+ of every core combined.
    var machineShare: Double
    /// 0...1+ of a single core. Can exceed 1 when a process uses several cores.
    var coreShare: Double
    var memoryBytes: Double
}

struct MachineHeader: Equatable {
    var name: String
    var detail: String
    var os: String
}

struct Snapshot: Equatable {
    var capturedAt: Date
    var header: MachineHeader
    var menuLabel: String
    var heroes: [Metric]
    var groups: [MetricGroup]
    var processes: [ProcessLoad]
    var memoryCeiling: Double

    static let empty = Snapshot(
        capturedAt: .now,
        header: MachineHeader(name: "This Mac", detail: "Measuring…", os: ""),
        menuLabel: "Measuring…",
        heroes: [],
        groups: [],
        processes: [],
        memoryCeiling: 0
    )

    var readingCount: Int {
        groups.reduce(0) { $0 + $1.metrics.count + $1.facts.count } + processes.count
    }

    var debugText: String {
        var lines: [String] = []
        lines.append(header.name)
        lines.append(header.detail)
        lines.append(header.os)
        lines.append("readings \(readingCount)")
        for hero in heroes {
            lines.append("HERO \(hero.name): \(hero.reading) \(hero.scale)")
        }
        for group in groups {
            lines.append("## \(group.title)")
            for fact in group.facts {
                lines.append("  \(fact.name): \(fact.value)")
            }
            for metric in group.metrics {
                lines.append("  \(metric.name): \(metric.reading) \(metric.scale) [\(metric.percentText)]")
            }
        }
        lines.append("## Processes")
        for process in processes {
            lines.append(String(format: "  %@  machine %.1f%%  one-core %.0f%%  mem %@",
                                process.name,
                                process.machineShare * 100,
                                process.coreShare * 100,
                                Format.bytes(process.memoryBytes)))
        }
        return lines.joined(separator: "\n")
    }
}

enum Format {
    static func bytes(_ value: Double) -> String {
        let sign = value < 0 ? -1.0 : 1.0
        var amount = abs(value)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        let number: String
        if index == 0 {
            number = String(format: "%.0f", amount)
        } else if amount >= 100 {
            number = String(format: "%.0f", amount)
        } else if amount >= 10 {
            number = String(format: "%.1f", amount)
        } else {
            number = String(format: "%.2f", amount)
        }
        return (sign < 0 ? "-" : "") + number + " " + units[index]
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// Decimal MB/s, matching link rates and SSD class peaks.
    static func decimalRate(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_000_000
        if mb >= 100 { return String(format: "%.0f MB/s", mb) }
        if mb >= 10 { return String(format: "%.1f MB/s", mb) }
        if mb >= 0.05 { return String(format: "%.2f MB/s", mb) }
        let kb = bytesPerSecond / 1_000
        if kb >= 0.05 { return String(format: "%.1f KB/s", kb) }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    static func perSecondCount(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f/s", value) }
        if value >= 10 { return String(format: "%.1f/s", value) }
        return String(format: "%.2f/s", value)
    }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func count(_ value: Double) -> String {
        if abs(value) >= 100 {
            return String(format: "%.0f", value)
        }
        if abs(value) >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }

    static func duration(minutes: Double) -> String {
        guard minutes.isFinite, minutes >= 0, minutes < 10_000 else { return "Calculating" }
        let total = Int(minutes.rounded())
        let hours = total / 60
        let mins = total % 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    static func uptime(since boot: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(boot))
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        let minutes = (Int(interval) % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

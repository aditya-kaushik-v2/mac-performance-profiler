import AppKit
import CoreGraphics
import CoreWLAN
import Darwin
import Foundation
import IOKit

final class Sampler {
    private struct CoreTicks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private struct DiskCounters {
        var readBytes: UInt64
        var writeBytes: UInt64
        var readOps: UInt64
        var writeOps: UInt64
    }

    private struct NetCounters {
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    private struct VMCounters {
        var pageins: UInt64
        var pageouts: UInt64
        var swapins: UInt64
        var compressions: UInt64
    }

    private var previousCores: [CoreTicks]?
    private var previousDisk: DiskCounters?
    private var previousNet: [String: NetCounters] = [:]
    private var previousVM: VMCounters?
    private var previousProcessCPU: [Int32: UInt64] = [:]
    private var previousTime: TimeInterval?
    private var sessionPeaks: [String: Double] = [:]
    private let started = Date()
    /// proc_taskinfo CPU times are mach absolute ticks, not nanoseconds.
    private let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    func sample() -> Snapshot {
        let now = Date().timeIntervalSince1970
        let dt = previousTime.map { now - $0 }
        previousTime = now

        let machine = readMachine()
        let cpu = readCPU(dt: dt, coreCount: machine.logicalCores, performanceCores: machine.performanceCores)
        let memory = readMemory(dt: dt, total: machine.memoryBytes)
        let gpu = readGPU(memoryCeiling: machine.memoryBytes)
        let disk = readDisk(dt: dt, chip: machine.chip)
        let network = readNetwork(dt: dt)
        let battery = readBattery(model: machine.modelIdentifier, chip: machine.chip)
        let display = readDisplay()
        let processes = readProcesses(dt: dt, coreCount: machine.logicalCores)
        let system = readSystem(processCount: processes.count, threadCount: processes.threads, maxProc: machine.maxProcesses)

        var groups: [MetricGroup] = [
            MetricGroup(id: "cpu", title: "Processor", symbol: "cpu", metrics: cpu.metrics, facts: cpu.facts),
            MetricGroup(id: "memory", title: "Memory", symbol: "memorychip", metrics: memory.metrics, facts: memory.facts),
            MetricGroup(id: "gpu", title: "Graphics", symbol: "square.stack.3d.up", metrics: gpu, facts: []),
            MetricGroup(id: "disk", title: "Storage", symbol: "internaldrive", metrics: disk.metrics, facts: disk.facts),
            MetricGroup(id: "network", title: "Network", symbol: "network", metrics: network.metrics, facts: network.facts),
            MetricGroup(id: "battery", title: "Battery and power", symbol: "battery.100percent", metrics: battery.metrics, facts: battery.facts),
            MetricGroup(id: "display", title: "Display", symbol: "display", metrics: display.metrics, facts: display.facts),
            MetricGroup(id: "system", title: "System", symbol: "desktopcomputer", metrics: system.metrics, facts: system.facts),
        ]
        groups.removeAll { $0.metrics.isEmpty && $0.facts.isEmpty }

        let heroes = [cpu.busy, memory.metrics.first { $0.id == "mem.used" }, gpu.first { $0.id == "gpu.device" }, battery.charge]
            .compactMap { $0 }

        let menuParts = heroes.prefix(3).map { hero in
            let short: String
            switch hero.id {
            case "cpu.busy": short = "CPU"
            case "mem.used": short = "RAM"
            case "gpu.device": short = "GPU"
            case "bat.charge": short = "BAT"
            default: short = hero.name
            }
            return "\(short) \(hero.percentText)"
        }

        return Snapshot(
            capturedAt: Date(),
            header: MachineHeader(name: machine.marketingName, detail: machine.detail, os: machine.os),
            menuLabel: menuParts.isEmpty ? "Mac Profiler" : menuParts.joined(separator: "   "),
            heroes: heroes,
            groups: groups,
            processes: processes.top,
            memoryCeiling: machine.memoryBytes
        )
    }

    // MARK: Machine

    private struct Machine {
        var marketingName: String
        var detail: String
        var os: String
        var chip: String
        var modelIdentifier: String
        var logicalCores: Int
        var performanceCores: Int
        var memoryBytes: Double
        var maxProcesses: Double?
    }

    private func readMachine() -> Machine {
        let model = Sysctl.string("hw.model") ?? "Mac"
        let chip = Sysctl.string("machdep.cpu.brand_string") ?? "Apple silicon"
        let logical = Int(Sysctl.integer("hw.logicalcpu") ?? Sysctl.integer("hw.ncpu") ?? 1)
        let performance = Int(Sysctl.integer("hw.perflevel0.physicalcpu") ?? 0)
        let efficiency = Int(Sysctl.integer("hw.perflevel1.physicalcpu") ?? 0)
        let memory = Double(Sysctl.unsigned("hw.memsize") ?? 0)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        var coreDetail = "\(logical) cores"
        if performance > 0, efficiency > 0 {
            coreDetail = "\(performance) performance + \(efficiency) efficiency cores"
        }
        let detail = "\(chip)  ·  \(coreDetail)  ·  \(Format.bytes(memory))"
        let maxProc = Sysctl.integer("kern.maxproc").map(Double.init)

        return Machine(
            marketingName: marketingName(model),
            detail: detail + "  ·  " + host,
            os: os,
            chip: chip,
            modelIdentifier: model,
            logicalCores: max(logical, 1),
            performanceCores: performance,
            memoryBytes: memory,
            maxProcesses: maxProc
        )
    }

    private func marketingName(_ model: String) -> String {
        let known = [
            "MacBookPro17,1": "MacBook Pro 13-inch (M1)",
            "MacBookPro18,1": "MacBook Pro 16-inch (M1 Pro)",
            "MacBookPro18,2": "MacBook Pro 16-inch (M1 Max)",
            "MacBookPro18,3": "MacBook Pro 14-inch (M1 Pro)",
            "MacBookPro18,4": "MacBook Pro 14-inch (M1 Max)",
            "MacBookAir10,1": "MacBook Air (M1)",
            "Macmini9,1": "Mac mini (M1)",
        ]
        if let name = known[model] { return name }
        if model.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if model.hasPrefix("MacBookAir") { return "MacBook Air" }
        if model.hasPrefix("Macmini") { return "Mac mini" }
        if model.hasPrefix("iMac") { return "iMac" }
        if model.hasPrefix("Mac") { return "Mac" }
        return model
    }

    // MARK: CPU

    private struct CPURead {
        var busy: Metric?
        var metrics: [Metric]
        var facts: [Fact]
    }

    private func readCPU(dt: TimeInterval?, coreCount: Int, performanceCores: Int) -> CPURead {
        let cores = loadCores()
        guard !cores.isEmpty else {
            return CPURead(busy: nil, metrics: [], facts: [])
        }

        var metrics: [Metric] = []
        var busyMetric: Metric?
        if let previous = previousCores, previous.count == cores.count, let dt, dt > 0.2 {
            var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
            for index in cores.indices {
                let now = cores[index]
                let then = previous[index]
                let dUser = UInt64(now.user &- then.user)
                let dSystem = UInt64(now.system &- then.system)
                let dIdle = UInt64(now.idle &- then.idle)
                let dNice = UInt64(now.nice &- then.nice)
                user += dUser
                system += dSystem
                idle += dIdle
                nice += dNice
                let total = dUser + dSystem + dIdle + dNice
                let busy = total > 0 ? Double(dUser + dSystem + dNice) / Double(total) * 100 : 0
                let label = coreLabel(index: index, performanceCores: performanceCores, total: cores.count)
                metrics.append(percentMetric(id: "cpu.core.\(index)", name: label, value: busy, note: nil))
            }
            let total = user + system + idle + nice
            func part(_ ticks: UInt64) -> Double {
                total > 0 ? Double(ticks) / Double(total) * 100 : 0
            }
            let busy = part(user + system + nice)
            busyMetric = percentMetric(id: "cpu.busy", name: "Busy", value: busy, note: "user + system + nice")
            let head = [
                busyMetric!,
                percentMetric(id: "cpu.user", name: "User", value: part(user), note: nil),
                percentMetric(id: "cpu.system", name: "System", value: part(system), note: nil),
                percentMetric(id: "cpu.nice", name: "Nice", value: part(nice), note: nil),
                percentMetric(id: "cpu.idle", name: "Idle", value: part(idle), note: nil, polarity: .health),
            ]
            metrics.insert(contentsOf: head, at: 0)
            _ = dt
        } else {
            metrics.append(Metric(
                id: "cpu.busy", name: "Busy", value: 0, floor: 0, ceiling: 100,
                reading: "Measuring…", scale: "of 100%", note: "Needs one second of ticks", polarity: .usage
            ))
        }
        previousCores = cores

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            let ceiling = Double(coreCount)
            let windows = [("1 min", loads[0], "cpu.load.1"), ("5 min", loads[1], "cpu.load.5"), ("15 min", loads[2], "cpu.load.15")]
            for window in windows {
                metrics.append(Metric(
                    id: window.2,
                    name: "Load \(window.0)",
                    value: window.1,
                    floor: 0,
                    ceiling: ceiling,
                    reading: Format.count(window.1),
                    scale: "of \(Format.count(ceiling)) cores",
                    note: "1.0 per core is a full machine",
                    polarity: .usage
                ))
            }
        }

        return CPURead(busy: busyMetric, metrics: metrics, facts: [])
    }

    private func coreLabel(index: Int, performanceCores: Int, total: Int) -> String {
        if performanceCores > 0, performanceCores < total {
            if index < performanceCores { return "P\(index + 1)" }
            return "E\(index - performanceCores + 1)"
        }
        return "Core \(index + 1)"
    }

    private func loadCores() -> [CoreTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        guard result == KERN_SUCCESS, let info, count > 0 else { return [] }
        defer {
            let bytes = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), bytes)
        }
        var cores: [CoreTicks] = []
        info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(count)) { pointer in
            for index in 0..<Int(count) {
                let ticks = pointer[index].cpu_ticks
                cores.append(CoreTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3))
            }
        }
        return cores
    }

    // MARK: Memory

    private struct MemoryRead {
        var metrics: [Metric]
        var facts: [Fact]
    }

    private func readMemory(dt: TimeInterval?, total: Double) -> MemoryRead {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS, total > 0 else { return MemoryRead(metrics: [], facts: []) }

        let page = Double(vm_kernel_page_size)
        let app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        let cached = (Double(stats.external_page_count) + Double(stats.purgeable_count)) * page
        let free = (Double(stats.free_count) + Double(stats.speculative_count)) * page
        let used = app + wired + compressed

        var metrics: [Metric] = [
            byteMetric(id: "mem.used", name: "Used", value: used, ceiling: total, note: "app + wired + compressed"),
            byteMetric(id: "mem.app", name: "App memory", value: app, ceiling: total, note: nil),
            byteMetric(id: "mem.wired", name: "Wired", value: wired, ceiling: total, note: "cannot be compressed"),
            byteMetric(id: "mem.compressed", name: "Compressed", value: compressed, ceiling: total, note: nil),
            byteMetric(id: "mem.cached", name: "Cached files", value: cached, ceiling: total, note: nil, polarity: .neutral),
            byteMetric(id: "mem.free", name: "Free", value: free, ceiling: total, note: "free + speculative", polarity: .health),
        ]

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0, swap.xsu_total > 0 {
            metrics.append(byteMetric(
                id: "mem.swap",
                name: "Swap used",
                value: Double(swap.xsu_used),
                ceiling: Double(swap.xsu_total),
                note: "of the current swap files"
            ))
        } else {
            metrics.append(Metric(
                id: "mem.swap", name: "Swap used", value: 0, floor: 0, ceiling: 1,
                reading: "0 B", scale: "no swap file", note: nil, polarity: .usage
            ))
        }

        if let level = Sysctl.integer("kern.memorystatus_level") {
            metrics.append(Metric(
                id: "mem.pressure",
                name: "Memory available",
                value: Double(level),
                floor: 0,
                ceiling: 100,
                reading: "\(level)",
                scale: "of 100 jetsam level",
                note: "Higher means more memory is still available",
                polarity: .health
            ))
        }

        let counters = VMCounters(
            pageins: stats.pageins,
            pageouts: stats.pageouts,
            swapins: stats.swapins,
            compressions: stats.compressions
        )
        var facts: [Fact] = []
        if let previous = previousVM, let dt, dt > 0.2 {
            facts.append(Fact(id: "mem.pageins", name: "Page ins", value: Format.perSecondCount(Double(counters.pageins &- previous.pageins) / dt)))
            facts.append(Fact(id: "mem.pageouts", name: "Page outs", value: Format.perSecondCount(Double(counters.pageouts &- previous.pageouts) / dt)))
            facts.append(Fact(id: "mem.swapins", name: "Swap ins", value: Format.perSecondCount(Double(counters.swapins &- previous.swapins) / dt)))
            facts.append(Fact(id: "mem.compressions", name: "Compressions", value: Format.perSecondCount(Double(counters.compressions &- previous.compressions) / dt)))
        }
        previousVM = counters
        return MemoryRead(metrics: metrics, facts: facts)
    }

    // MARK: GPU

    private func readGPU(memoryCeiling: Double) -> [Metric] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var metrics: [Metric] = []
        var index = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary else { continue }
            let prefix = index == 0 ? "" : " \(index + 1)"
            if let device = registryDouble(stats["Device Utilization %"]) {
                metrics.append(percentMetric(id: "gpu.device.\(index)", name: "Device\(prefix)", value: device, note: "GPU busy"))
            }
            if let renderer = registryDouble(stats["Renderer Utilization %"]) {
                metrics.append(percentMetric(id: "gpu.renderer.\(index)", name: "Renderer\(prefix)", value: renderer, note: nil))
            }
            if let tiler = registryDouble(stats["Tiler Utilization %"]) {
                metrics.append(percentMetric(id: "gpu.tiler.\(index)", name: "Tiler\(prefix)", value: tiler, note: nil))
            }
            if let inUse = registryDouble(stats["In use system memory"]), memoryCeiling > 0 {
                metrics.append(byteMetric(
                    id: "gpu.mem.\(index)",
                    name: "GPU memory\(prefix)",
                    value: inUse,
                    ceiling: memoryCeiling,
                    note: "unified memory in use by the GPU"
                ))
            }
            index += 1
        }
        // Hero looks up gpu.device. The first device metric uses a stable id.
        if let first = metrics.firstIndex(where: { $0.id == "gpu.device.0" }) {
            metrics[first].id = "gpu.device"
        }
        return metrics
    }

    // MARK: Disk

    private struct DiskRead {
        var metrics: [Metric]
        var facts: [Fact]
    }

    private func readDisk(dt: TimeInterval?, chip: String) -> DiskRead {
        var metrics: [Metric] = []
        var facts: [Fact] = []
        if let volume = dataVolume() {
            let total = Double(volume.blocks) * Double(volume.blockSize)
            let available = Double(volume.available) * Double(volume.blockSize)
            let used = max(0, total - available)
            metrics.append(byteMetric(
                id: "disk.used",
                name: "SSD used",
                value: used,
                ceiling: total,
                note: volume.mount
            ))
            let peak = storagePeak(chip: chip, totalBytes: total)
            let counters = diskCounters()
            if let previous = previousDisk, let dt, dt > 0.2 {
                let read = Double(counters.readBytes &- previous.readBytes) / dt
                let write = Double(counters.writeBytes &- previous.writeBytes) / dt
                let readOps = Double(counters.readOps &- previous.readOps) / dt
                let writeOps = Double(counters.writeOps &- previous.writeOps) / dt
                metrics.append(Metric(
                    id: "disk.read",
                    name: "Read",
                    value: read,
                    floor: 0,
                    ceiling: peak.read,
                    reading: Format.decimalRate(read),
                    scale: "of \(Format.decimalRate(peak.read))",
                    note: peak.label,
                    polarity: .neutral
                ))
                metrics.append(Metric(
                    id: "disk.write",
                    name: "Write",
                    value: write,
                    floor: 0,
                    ceiling: peak.write,
                    reading: Format.decimalRate(write),
                    scale: "of \(Format.decimalRate(peak.write))",
                    note: peak.label,
                    polarity: .neutral
                ))
                facts.append(Fact(id: "disk.iops.read", name: "Read ops", value: Format.perSecondCount(readOps)))
                facts.append(Fact(id: "disk.iops.write", name: "Write ops", value: Format.perSecondCount(writeOps)))
            }
            previousDisk = counters
        }
        return DiskRead(metrics: metrics, facts: facts)
    }

    private struct VolumeInfo {
        var blocks: UInt64
        var available: UInt64
        var blockSize: UInt32
        var mount: String
    }

    private func dataVolume() -> VolumeInfo? {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard let buffer, count > 0 else { return nil }
        var fallback: VolumeInfo?
        for index in 0..<Int(count) {
            let entry = buffer[index]
            let mount = CString.fromTuple(entry.f_mntonname)
            let type = CString.fromTuple(entry.f_fstypename)
            guard type == "apfs" || type == "hfs" else { continue }
            let info = VolumeInfo(
                blocks: UInt64(entry.f_blocks),
                available: UInt64(entry.f_bavail),
                blockSize: UInt32(entry.f_bsize),
                mount: mount
            )
            if mount == "/System/Volumes/Data" { return info }
            if mount == "/" { fallback = info }
        }
        return fallback
    }

    private func diskCounters() -> DiskCounters {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return DiskCounters(readBytes: 0, writeBytes: 0, readOps: 0, writeOps: 0)
        }
        defer { IOObjectRelease(iterator) }

        var best = DiskCounters(readBytes: 0, writeBytes: 0, readOps: 0, writeOps: 0)
        var bestTotal: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if registryChainContainsDiskImage(service) { continue }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary,
                  let read = registryDouble(stats["Bytes (Read)"]) else { continue }
            let counters = DiskCounters(
                readBytes: UInt64(read),
                writeBytes: UInt64(registryDouble(stats["Bytes (Write)"]) ?? 0),
                readOps: UInt64(registryDouble(stats["Operations (Read)"]) ?? 0),
                writeOps: UInt64(registryDouble(stats["Operations (Write)"]) ?? 0)
            )
            let total = counters.readBytes &+ counters.writeBytes
            if total >= bestTotal {
                bestTotal = total
                best = counters
            }
        }
        return best
    }

    private func registryChainContainsDiskImage(_ entry: io_registry_entry_t) -> Bool {
        var current = entry
        var shouldRelease = false
        defer { if shouldRelease { IOObjectRelease(current) } }
        for _ in 0..<12 {
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(current, &name)
            let text = String(cString: name)
            if text.localizedCaseInsensitiveContains("DiskImage") || text.contains("HDIX") {
                return true
            }
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS {
                return false
            }
            if shouldRelease { IOObjectRelease(current) }
            current = parent
            shouldRelease = true
        }
        return false
    }

    private struct StoragePeak {
        var read: Double
        var write: Double
        var label: String
    }

    /// Class peaks are published ballpark speeds for the SSD in this Mac, not a benchmark run just now.
    private func storagePeak(chip: String, totalBytes: Double) -> StoragePeak {
        let gigabytes = totalBytes / 1_000_000_000
        let plainM1 = chip.contains("M1") && !chip.contains("Pro") && !chip.contains("Max") && !chip.contains("Ultra")
        if plainM1 && gigabytes < 400 {
            return StoragePeak(read: 2_200 * 1_000_000, write: 1_500 * 1_000_000, label: "M1 256 GB class peak")
        }
        if plainM1 {
            return StoragePeak(read: 2_800 * 1_000_000, write: 2_300 * 1_000_000, label: "M1 class peak")
        }
        if chip.contains("M2") {
            return StoragePeak(read: 3_000 * 1_000_000, write: 2_500 * 1_000_000, label: "M2 class peak")
        }
        if chip.contains("M3") || chip.contains("M4") || chip.contains("M5") {
            return StoragePeak(read: 3_500 * 1_000_000, write: 3_000 * 1_000_000, label: "Apple silicon class peak")
        }
        return StoragePeak(read: 2_000 * 1_000_000, write: 2_000 * 1_000_000, label: "SSD class peak")
    }

    // MARK: Network

    private struct NetRead {
        var metrics: [Metric]
        var facts: [Fact]
    }

    private func readNetwork(dt: TimeInterval?) -> NetRead {
        let wifi = readWiFi()
        var facts: [Fact] = []
        if let wifi {
            if !wifi.ssid.isEmpty { facts.append(Fact(id: "net.ssid", name: "Wi-Fi", value: wifi.ssid)) }
            if wifi.rate > 1 {
                facts.append(Fact(id: "net.phy", name: "PHY rate", value: String(format: "%.0f Mbps", wifi.rate)))
            }
        }

        var metrics: [Metric] = []
        if let wifi, wifi.rssi < 0 {
            let snr = wifi.noise < 0 ? Double(wifi.rssi - wifi.noise) : nil
            metrics.append(Metric(
                id: "net.rssi",
                name: "Signal",
                value: Double(wifi.rssi),
                floor: -90,
                ceiling: -30,
                reading: "\(wifi.rssi) dBm",
                scale: "of −30 dBm",
                note: "−90 dBm is weak, −30 dBm is strong",
                polarity: .health
            ))
            if let snr {
                metrics.append(Metric(
                    id: "net.snr",
                    name: "Signal to noise",
                    value: snr,
                    floor: 0,
                    ceiling: 60,
                    reading: String(format: "%.0f dB", snr),
                    scale: "of 60 dB",
                    note: nil,
                    polarity: .health
                ))
            }
        }

        var current: [String: NetCounters] = [:]
        var interfaces: [(name: String, bytesIn: UInt64, bytesOut: UInt64, baud: UInt64)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let pointer else {
            return NetRead(metrics: metrics, facts: facts)
        }
        defer { freeifaddrs(pointer) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = pointer
        var seen = Set<String>()
        while let node = cursor {
            let address = node.pointee
            cursor = address.ifa_next
            guard let sa = address.ifa_addr, Int32(sa.pointee.sa_family) == AF_LINK else { continue }
            let name = String(cString: address.ifa_name)
            guard seen.insert(name).inserted else { continue }
            let flags = Int32(address.ifa_flags)
            if (flags & IFF_LOOPBACK) != 0 { continue }
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw")
                || name.hasPrefix("bridge") || name.hasPrefix("gif") || name.hasPrefix("stf")
                || name.hasPrefix("ap") || name.hasPrefix("anpi") { continue }
            guard (flags & IFF_UP) != 0, let data = address.ifa_data else { continue }
            let link = data.assumingMemoryBound(to: if_data.self).pointee
            let bytesIn = UInt64(link.ifi_ibytes)
            let bytesOut = UInt64(link.ifi_obytes)
            let isWiFi = wifi?.name == name
            if bytesIn == 0, bytesOut == 0, !isWiFi { continue }
            current[name] = NetCounters(bytesIn: bytesIn, bytesOut: bytesOut)
            interfaces.append((name, bytesIn, bytesOut, UInt64(link.ifi_baudrate)))
        }

        if let dt, dt > 0.2 {
            for iface in interfaces.sorted(by: { $0.name < $1.name }) {
                guard let then = previousNet[iface.name] else { continue }
                let bytesIn = Double(iface.bytesIn &- then.bytesIn) / dt
                let bytesOut = Double(iface.bytesOut &- then.bytesOut) / dt
                let phyCeiling: Double
                let note: String
                let label = (wifi?.name == iface.name) ? "Wi-Fi" : iface.name
                if let wifi, wifi.name == iface.name, wifi.rate > 1 {
                    phyCeiling = wifi.rate * 125_000
                    note = "current Wi-Fi PHY rate"
                } else if iface.baud > 0 {
                    phyCeiling = Double(iface.baud) / 8
                    note = "link rate"
                } else {
                    phyCeiling = 125_000_000
                    note = "1 Gbps scale, link rate not reported"
                }
                metrics.append(Metric(
                    id: "net.\(iface.name).in",
                    name: "\(label) in",
                    value: bytesIn, floor: 0, ceiling: phyCeiling,
                    reading: Format.decimalRate(bytesIn),
                    scale: "of \(Format.decimalRate(phyCeiling))",
                    note: note, polarity: .neutral
                ))
                metrics.append(Metric(
                    id: "net.\(iface.name).out",
                    name: "\(label) out",
                    value: bytesOut, floor: 0, ceiling: phyCeiling,
                    reading: Format.decimalRate(bytesOut),
                    scale: "of \(Format.decimalRate(phyCeiling))",
                    note: note, polarity: .neutral
                ))
            }
        }
        previousNet = current
        return NetRead(metrics: metrics, facts: facts)
    }

    private struct WiFiInfo {
        var name: String
        var ssid: String
        var rate: Double
        var rssi: Int
        var noise: Int
    }

    private func readWiFi() -> WiFiInfo? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        let ssid = interface.ssid() ?? ""
        return WiFiInfo(
            name: interface.interfaceName ?? "en0",
            ssid: ssid,
            rate: interface.transmitRate(),
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement()
        )
    }

    // MARK: Battery

    private struct BatteryRead {
        var charge: Metric?
        var metrics: [Metric]
        var facts: [Fact]
    }

    private func readBattery(model: String, chip: String) -> BatteryRead {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return BatteryRead(charge: nil, metrics: [], facts: [Fact(id: "bat.none", name: "Battery", value: "Not installed")])
        }
        defer { IOObjectRelease(service) }

        func number(_ key: String) -> Double? {
            guard let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
            return registryDouble(property.takeRetainedValue())
        }
        func signed(_ key: String) -> Int64? {
            guard let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
            return signedRegistryInteger(property.takeRetainedValue())
        }
        func flag(_ key: String) -> Bool {
            (number(key) ?? 0) != 0
        }

        let current = number("CurrentCapacity") ?? 0
        let maxCapacity = number("MaxCapacity") ?? 0
        let design = number("DesignCapacity") ?? 0
        let rawMax = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity") ?? 0
        let chargePercent: Double
        if maxCapacity > 0, maxCapacity <= 100, current <= 100 {
            chargePercent = current / maxCapacity * 100
        } else if maxCapacity > 0 {
            chargePercent = current / maxCapacity * 100
        } else {
            chargePercent = 0
        }

        var metrics: [Metric] = []
        let charge = percentMetric(id: "bat.charge", name: "Charge", value: chargePercent, note: "of the battery's current full charge", polarity: .health)
        metrics.append(charge)

        if design > 100, rawMax > 100 {
            let health = rawMax / design * 100
            metrics.append(Metric(
                id: "bat.health",
                name: "Health",
                value: health, floor: 0, ceiling: 100,
                reading: Format.percent(health),
                scale: "of design capacity",
                note: "\(Int(rawMax)) of \(Int(design)) mAh",
                polarity: .health
            ))
            let ofDesign = chargePercent / 100 * health
            metrics.append(percentMetric(
                id: "bat.design",
                name: "Charge vs design",
                value: ofDesign,
                note: "current energy compared with the battery when it was new",
                polarity: .health
            ))
        }

        if let cycles = number("CycleCount") {
            metrics.append(Metric(
                id: "bat.cycles",
                name: "Cycles",
                value: cycles, floor: 0, ceiling: 1000,
                reading: String(format: "%.0f", cycles),
                scale: "of 1,000",
                note: "Apple rates this battery for 1,000 cycles",
                polarity: .usage
            ))
        }

        if var temperature = number("Temperature") {
            if temperature > 200 { temperature /= 100 }
            metrics.append(Metric(
                id: "bat.temp",
                name: "Battery temperature",
                value: temperature, floor: 0, ceiling: 45,
                reading: String(format: "%.1f°C", temperature),
                scale: "of 45°C",
                note: "Battery cell temperature. macOS does not publish CPU die temperature to apps.",
                polarity: .usage
            ))
        }

        let millivolts = signed("Voltage") ?? 0
        let milliamps = signed("InstantAmperage") ?? signed("Amperage") ?? 0
        let volts = Double(millivolts) / 1000
        let amps = Double(milliamps) / 1000
        let watts = volts * amps
        let envelope = powerEnvelope(model: model, chip: chip)
        if abs(watts) > 0.05 {
            let charging = watts > 0
            metrics.append(Metric(
                id: "bat.power",
                name: charging ? "Charging" : "Drawing",
                value: abs(watts), floor: 0, ceiling: envelope.watts,
                reading: String(format: "%.1f W", abs(watts)),
                scale: String(format: "of %.0f W", envelope.watts),
                note: charging
                    ? "Power entering the battery. \(envelope.label)"
                    : "Power leaving the battery, close to system draw. \(envelope.label)",
                polarity: .usage
            ))
        }

        var facts: [Fact] = []
        let onPower = flag("ExternalConnected")
        facts.append(Fact(id: "bat.source", name: "Power source", value: onPower ? "Power adapter" : "Battery"))
        if let minutes = number("TimeRemaining"), minutes < 10_000 {
            let label = flag("IsCharging") ? "Time to full" : "Time remaining"
            facts.append(Fact(id: "bat.time", name: label, value: Format.duration(minutes: minutes)))
        }
        if millivolts > 0 {
            facts.append(Fact(id: "bat.voltage", name: "Voltage", value: String(format: "%.2f V", volts)))
        }
        facts.append(Fact(id: "bat.current", name: "Current", value: String(format: "%+.0f mA", Double(milliamps))))

        return BatteryRead(charge: charge, metrics: metrics, facts: facts)
    }

    private func powerEnvelope(model: String, chip: String) -> (watts: Double, label: String) {
        if model == "MacBookPro17,1" || model.hasPrefix("MacBookAir") {
            return (20, "20 W is the sustained envelope of this fanless Mac")
        }
        if chip.contains("Ultra") { return (80, "80 W scale for this chip class") }
        if chip.contains("Max") { return (60, "60 W scale for this chip class") }
        if chip.contains("Pro") { return (40, "40 W scale for this chip class") }
        return (30, "30 W scale")
    }

    // MARK: Display

    private struct DisplayRead {
        var metrics: [Metric]
        var facts: [Fact]
    }

    private func readDisplay() -> DisplayRead {
        let display = CGMainDisplayID()
        guard let current = CGDisplayCopyDisplayMode(display) else {
            return DisplayRead(metrics: [], facts: [])
        }
        let width = Double(current.pixelWidth)
        let height = Double(current.pixelHeight)
        var maxWidth = width
        var maxHeight = height
        var maxRefresh = current.refreshRate
        var currentRefresh = maxRefresh
        if let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] {
            for mode in modes {
                let modeWidth = Double(mode.pixelWidth)
                let modeHeight = Double(mode.pixelHeight)
                if modeWidth * modeHeight > maxWidth * maxHeight {
                    maxWidth = modeWidth
                    maxHeight = modeHeight
                }
                maxRefresh = max(maxRefresh, mode.refreshRate)
            }
        }
        if currentRefresh == 0 { currentRefresh = 60 }
        if maxRefresh == 0 { maxRefresh = currentRefresh }

        let pixels = width * height
        let maxPixels = max(maxWidth * maxHeight, 1)
        var metrics = [
            Metric(
                id: "display.pixels",
                name: "Pixels",
                value: pixels, floor: 0, ceiling: maxPixels,
                reading: "\(Int(width))×\(Int(height))",
                scale: "of \(Int(maxWidth))×\(Int(maxHeight))",
                note: "Framebuffer pixels versus the largest mode",
                polarity: .health
            ),
            Metric(
                id: "display.refresh",
                name: "Refresh",
                value: Double(currentRefresh), floor: 0, ceiling: Double(maxRefresh),
                reading: String(format: "%.0f Hz", currentRefresh),
                scale: String(format: "of %.0f Hz", maxRefresh),
                note: nil,
                polarity: .health
            ),
        ]
        var facts: [Fact] = []
        if let screen = NSScreen.screens.first {
            let scale = screen.backingScaleFactor
            facts.append(Fact(id: "display.scale", name: "Scale", value: scale == 1 ? "1×" : String(format: "%.0f×", scale)))
            facts.append(Fact(id: "display.count", name: "Displays", value: "\(NSScreen.screens.count)"))
        }
        if metrics.isEmpty { metrics = [] }
        return DisplayRead(metrics: metrics, facts: facts)
    }

    // MARK: System

    private struct SystemRead {
        var metrics: [Metric]
        var facts: [Fact]
    }

    private func readSystem(processCount: Int, threadCount: Int, maxProc: Double?) -> SystemRead {
        let thermal = ProcessInfo.processInfo.thermalState
        let (level, word): (Double, String) = {
            switch thermal {
            case .nominal: return (0, "Nominal")
            case .fair: return (1, "Fair")
            case .serious: return (2, "Serious")
            case .critical: return (3, "Critical")
            @unknown default: return (0, "Nominal")
            }
        }()
        var metrics = [
            Metric(
                id: "sys.thermal",
                name: "Thermal pressure",
                value: level, floor: 0, ceiling: 3,
                reading: word,
                scale: "of Critical",
                note: "macOS thermal state. Nominal means the machine is not limiting itself.",
                polarity: .usage
            )
        ]
        let procCeiling = maxProc ?? sessionPeak("sys.processes", value: Double(processCount))
        metrics.append(Metric(
            id: "sys.processes",
            name: "Processes",
            value: Double(processCount), floor: 0, ceiling: max(procCeiling, 1),
            reading: "\(processCount)",
            scale: maxProc == nil ? "of peak since launch" : "of \(Int(procCeiling)) max",
            note: nil,
            polarity: .usage
        ))
        var facts: [Fact] = [
            Fact(id: "sys.threads", name: "Threads", value: Format.grouped(threadCount))
        ]
        if let boot = Sysctl.bootDate() {
            facts.append(Fact(id: "sys.uptime", name: "Uptime", value: Format.uptime(since: boot)))
        }
        facts.append(Fact(id: "sys.profiler", name: "Profiler running", value: Format.uptime(since: started)))
        if let maxFiles = Sysctl.integer("kern.maxfiles") {
            facts.append(Fact(id: "sys.maxfiles", name: "Max open files", value: "\(maxFiles)"))
        }
        return SystemRead(metrics: metrics, facts: facts)
    }

    // MARK: Processes

    private struct ProcessRead {
        var top: [ProcessLoad]
        var count: Int
        var threads: Int
    }

    private func readProcesses(dt: TimeInterval?, coreCount: Int) -> ProcessRead {
        // proc_listallpids returns a pid count, not a byte count.
        let reported = proc_listallpids(nil, 0)
        guard reported > 0 else { return ProcessRead(top: [], count: 0, threads: 0) }
        var pids = [pid_t](repeating: 0, count: Int(reported) + 64)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        let count = max(0, min(pids.count, Int(written)))

        var nextCPU: [Int32: UInt64] = [:]
        var ranked: [ProcessLoad] = []
        var threads = 0
        for index in 0..<min(count, pids.count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let cpuTime = info.pti_total_user &+ info.pti_total_system
            nextCPU[pid] = cpuTime
            threads += Int(info.pti_threadnum)
            guard let dt, dt > 0.2, let then = previousProcessCPU[pid], cpuTime >= then else { continue }
            let cpuSeconds = Double(cpuTime - then) * nanosPerTick / 1_000_000_000
            let coreShare = cpuSeconds / dt
            let machineShare = coreShare / Double(coreCount)
            if machineShare < 0.001 && info.pti_resident_size == 0 { continue }
            ranked.append(ProcessLoad(
                id: pid,
                name: processName(pid),
                machineShare: machineShare,
                coreShare: coreShare,
                memoryBytes: Double(info.pti_resident_size)
            ))
        }
        previousProcessCPU = nextCPU
        ranked.sort { lhs, rhs in
            if lhs.machineShare == rhs.machineShare { return lhs.memoryBytes > rhs.memoryBytes }
            return lhs.machineShare > rhs.machineShare
        }
        return ProcessRead(top: Array(ranked.prefix(8)), count: count, threads: threads)
    }

    private func processName(_ pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let full = String(cString: path)
            let last = (full as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        let text = String(cString: name)
        return text.isEmpty ? "pid \(pid)" : text
    }

    // MARK: Metric builders

    private func percentMetric(id: String, name: String, value: Double, note: String?, polarity: Polarity = .usage) -> Metric {
        Metric(
            id: id, name: name, value: value, floor: 0, ceiling: 100,
            reading: Format.percent(value), scale: "of 100%", note: note, polarity: polarity
        )
    }

    private func byteMetric(id: String, name: String, value: Double, ceiling: Double, note: String?, polarity: Polarity = .usage) -> Metric {
        Metric(
            id: id, name: name, value: value, floor: 0, ceiling: ceiling,
            reading: Format.bytes(value), scale: "of \(Format.bytes(ceiling))", note: note, polarity: polarity
        )
    }

    private func sessionPeak(_ id: String, value: Double) -> Double {
        let peak = max(sessionPeaks[id] ?? 0, value)
        sessionPeaks[id] = peak
        return peak
    }
}

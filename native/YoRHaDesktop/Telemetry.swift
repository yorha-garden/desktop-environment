import Darwin
import Foundation
import IOKit.ps

// hud.jsx forked a shell pipeline every second (ps, memory_pressure, uptime, pmset,
// netstat + awk/sed/grep). Every value comes straight from the kernel here instead.

struct Telemetry: Equatable {
    var cpu: Int            // % of all cores busy
    var mem: Int            // memory pressure %, as `memory_pressure` reports it
    var uptime: String      // wording of `uptime`
    var battery: Int?       // nil on a Mac without a battery
    var onAC: Bool          // pmset: "Now drawing from 'AC Power'"

    var memAlert: Bool { mem >= 80 }
    var batteryAlert: Bool { battery.map { $0 < 20 && !onAC } ?? false }
}

enum HUDFormat {
    // fmtRate in hud.jsx
    static func rate(bytesPerSecond bps: Double) -> String {
        guard bps.isFinite, bps >= 0 else { return "—" }
        if bps >= 1_048_576 { return String(format: "%.1f MB/S", bps / 1_048_576) }
        return "\(Int((bps / 1024).rounded())) KB/S"
    }

    // The text `uptime` prints between "up " and ", N users". Like BSD w(1), past
    // the first minute it adds 30 s so minutes round to nearest instead of down.
    static func uptime(seconds raw: Int) -> String {
        let total = raw > 60 ? raw + 30 : raw
        let days = total / 86_400
        let hrs = total % 86_400 / 3_600
        let mins = total % 3_600 / 60
        let secs = total % 60
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }

        let clock: String
        if hrs > 0 && mins > 0 { clock = String(format: "%d:%02d", hrs, mins) }
        else if hrs > 0 { clock = plural(hrs, "hr") }
        else if mins > 0 { clock = plural(mins, "min") }
        else if days > 0 { return plural(days, "day") }
        else { clock = plural(secs, "sec") }
        return days > 0 ? "\(plural(days, "day")), \(clock)" : clock
    }
}

final class TelemetrySampler {
    private let host = mach_host_self()
    private var lastTicks: (busy: UInt64, total: UInt64)?

    func sample(now: Date = Date()) -> Telemetry {
        let power = Self.power()
        let boot = Self.bootTime() ?? now
        return Telemetry(
            cpu: cpuPercent(),
            mem: Self.memoryPressure(),
            uptime: HUDFormat.uptime(seconds: max(0, Int(now.timeIntervalSince(boot)))),
            battery: power.battery,
            onAC: power.onAC
        )
    }

    // Busy share of CPU ticks since the previous sample (since boot on the first).
    func cpuPercent() -> Int {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else {
            return total > 0 ? Int((Double(busy) / Double(total) * 100).rounded()) : 0
        }
        return Int((Double(busy - last.busy) / Double(total - last.total) * 100).rounded())
    }

    // memory_pressure prints "System-wide memory free percentage: N%", which is
    // kern.memorystatus_level; the HUD shows 100 - N.
    static func memoryPressure() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return 0 }
        return 100 - Int(level)
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    static func power() -> (battery: Int?, onAC: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (nil, false) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onAC = providing == "AC Power"
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            return (Int((Double(current) / Double(maximum) * 100).rounded()), onAC)
        }
        return (nil, onAC)
    }

    // 64-bit byte counters (netstat -ib) for one interface. getifaddrs only
    // exposes 32-bit counters, which wrap every 4 GB.
    static func networkBytes(interface: String = "en0") -> (received: UInt64, sent: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }

        var received: UInt64 = 0, sent: UInt64 = 0, found = false
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil,
                       String(cString: name) == interface {
                        received += message.ifm_data.ifi_ibytes
                        sent += message.ifm_data.ifi_obytes
                        found = true
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return found ? (received, sent) : nil
    }
}

// One clock for every screen: network each second, the rest every three seconds.
// Stops while the displays sleep, since nothing is visible to update.
final class TelemetryClock {
    var onTick: ((Telemetry, String) -> Void)?
    private let sampler = TelemetrySampler()
    private var rate = NetworkRate()
    private var telemetry: Telemetry?
    private var nextTelemetryAt: TimeInterval = 0
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: HUDStyle.networkInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        rate = NetworkRate()   // a rate across a sleep gap would be meaningless
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let current = rate.update(TelemetrySampler.networkBytes(), at: now)
        if telemetry == nil || now >= nextTelemetryAt {
            telemetry = sampler.sample()
            nextTelemetryAt = now + HUDStyle.telemetryInterval
        }
        if let telemetry { onTick?(telemetry, current) }
    }
}

// Network rate from successive counter readings, as hud.jsx computed it: a
// counter that went backwards (interface reset) shows "—" for one sample.
struct NetworkRate {
    private var previous: (received: UInt64, sent: UInt64, at: TimeInterval)?

    mutating func update(_ bytes: (received: UInt64, sent: UInt64)?, at now: TimeInterval) -> String {
        guard let bytes else { previous = nil; return "—" }
        defer { previous = (bytes.received, bytes.sent, now) }
        guard let p = previous, bytes.received >= p.received, bytes.sent >= p.sent else { return "—" }
        let elapsed = max(now - p.at, 0.001)
        let delta = Double(bytes.received - p.received) + Double(bytes.sent - p.sent)
        return HUDFormat.rate(bytesPerSecond: delta / elapsed)
    }
}

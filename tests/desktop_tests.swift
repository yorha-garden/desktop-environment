import AppKit

// Pure palette, geometry, and timing checks for YoRHa Desktop. Compiled with
// every native/YoRHaDesktop source except main.swift.
@main struct DesktopTests {
    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-6 }
    static func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        near(a.origin, b.origin) && near(a.width, b.width) && near(a.height, b.height)
    }

    static func main() {
        // theme.jsx tokens
        precondition(Palette.forMode(.light) == .light)
        precondition(Palette.forMode(.dark) == .dark)
        precondition(Palette.light.ornament == RGBA(74, 71, 65))
        precondition(Palette.dark.ornament == RGBA(110, 123, 139))
        precondition(Palette.dark.value == RGBA(239, 235, 219))
        precondition(Palette.light.panel == RGBA(214, 210, 193, 0.5))
        precondition(Palette.dark.beamSurface == RGBA(58, 58, 64))
        precondition(near(Palette.transitionDuration, 0.2))
        precondition(resolveMode(for: NSAppearance(named: .darkAqua)!) == .dark)
        precondition(resolveMode(for: NSAppearance(named: .aqua)!) == .light)

        // beam.jsx: 14vh band, -16vh -> 102vh, 11s
        precondition(near(BeamGeometry.bandHeight(screenHeight: 1000), 140))
        let travel = BeamGeometry.travel(screenHeight: 1000)
        precondition(near(travel.from, -160) && near(travel.to, 1020))
        precondition(BeamGeometry.duration == 11)
        precondition(BeamGeometry.locations == [0, 0.45, 0.55, 1])
        precondition(BeamGeometry.colors(.light).map(\.alpha) == [0, 0.05, 0.07, 0])

        // arcs.jsx corner placement on a 1710x1112 screen
        let screen = CGSize(width: 1710, height: 1112)
        let arcs = ArcGeometry.arcCornerFrames(in: screen)
        precondition(near(arcs.topLeft, CGRect(x: 0, y: 0, width: 428, height: 432)))
        precondition(near(arcs.bottomRight, CGRect(x: 1282, y: 680, width: 428, height: 432)))
        let lines = ArcGeometry.lineCornerFrames(in: screen)
        precondition(near(lines.topLeft, CGRect(x: 0, y: 0, width: 707, height: 714)))
        // bottom: -64px; right: -96px
        precondition(near(lines.bottomRight, CGRect(x: 1099, y: 462, width: 707, height: 714)))

        // verbatim SVG endpoints
        let paths = ArcGeometry.arcPaths()
        precondition(paths.count == 2)
        precondition(near(paths[0].currentPoint, CGPoint(x: 0.017, y: 431)))
        precondition(near(paths[1].currentPoint, CGPoint(x: 0, y: 418.261)))
        precondition(near(ArcGeometry.linePath(2).currentPoint, CGPoint(x: 707.354, y: 651.647)))
        precondition(near(ArcGeometry.strokeOpacity, 0.3) && near(ArcGeometry.strokeWidth, 2))

        // motion parameters
        precondition(ArcMotion.drawDuration == 1.5)
        precondition(ArcMotion.drawCurve == (0.22, 1, 0.36, 1))
        precondition(ArcMotion.breatheDuration == 3 && near(ArcMotion.breatheScale, 1.1))
        precondition(ArcMotion.arcDelays == [0, 0.5])
        precondition(ArcMotion.waveDuration == 4 && near(ArcMotion.waveLift, -10))
        precondition(ArcMotion.lineDelays == [0, 0.2, 0.4])

        // hud.jsx fmtRate
        precondition(HUDFormat.rate(bytesPerSecond: 0) == "0 KB/S")
        precondition(HUDFormat.rate(bytesPerSecond: 18 * 1024 + 300) == "18 KB/S")
        precondition(HUDFormat.rate(bytesPerSecond: 1_048_576) == "1.0 MB/S")
        precondition(HUDFormat.rate(bytesPerSecond: 2.4 * 1_048_576) == "2.4 MB/S")
        precondition(HUDFormat.rate(bytesPerSecond: -1) == "—")
        precondition(HUDFormat.rate(bytesPerSecond: .nan) == "—")

        // `uptime` wording
        precondition(HUDFormat.uptime(seconds: 30) == "30 secs")
        precondition(HUDFormat.uptime(seconds: 60) == "1 min")
        precondition(HUDFormat.uptime(seconds: 35 * 60) == "35 mins")
        precondition(HUDFormat.uptime(seconds: 3_600) == "1 hr")
        precondition(HUDFormat.uptime(seconds: 2 * 3_600) == "2 hrs")
        precondition(HUDFormat.uptime(seconds: 2 * 3_600 + 34 * 60) == "2:34")
        precondition(HUDFormat.uptime(seconds: 2 * 3_600 + 5 * 60 + 29) == "2:05")
        precondition(HUDFormat.uptime(seconds: 2 * 3_600 + 5 * 60 + 30) == "2:06")   // rounds like w(1)
        precondition(HUDFormat.uptime(seconds: 86_400 + 2 * 3_600 + 34 * 60) == "1 day, 2:34")
        precondition(HUDFormat.uptime(seconds: 3 * 86_400 + 12 * 60) == "3 days, 12 mins")
        precondition(HUDFormat.uptime(seconds: 2 * 86_400) == "2 days")

        // alerts: memory >= 80, battery < 20 only when not on AC
        var t = Telemetry(cpu: 10, mem: 79, uptime: "1 hr", battery: 19, onAC: false)
        precondition(!t.memAlert && t.batteryAlert)
        t.mem = 80; t.onAC = true
        precondition(t.memAlert && !t.batteryAlert)
        t.battery = nil; t.onAC = false
        precondition(!t.batteryAlert)

        // network rate: first reading and counter resets show "—"
        var rate = NetworkRate()
        precondition(rate.update((1_000, 1_000), at: 10) == "—")
        precondition(rate.update((1_000 + 20_480, 1_000 + 10_240), at: 11) == "30 KB/S")
        precondition(rate.update((5, 5), at: 12) == "—")
        precondition(rate.update(nil, at: 13) == "—")

        // HUD layout constants and meters
        precondition(HUDStyle.top == 60 && HUDStyle.side == 30 && HUDStyle.bottom == 28)
        precondition(HUDStyle.meterSize == CGSize(width: 126, height: 3))
        precondition(near(HUDStyle.meterFill(50), 63))
        precondition(near(HUDStyle.meterFill(140), 126) && near(HUDStyle.meterFill(-5), 0))
        precondition(HUDStyle.bootDelays == [0.1, 0.35, 0.6] && HUDStyle.bootDuration == 0.55)
        precondition(HUDStyle.bootCurve == (0.34, 1.56, 0.64, 1))
        precondition(HUDStyle.networkInterval == 1 && HUDStyle.telemetryInterval == 3)

        // Pod: `df -h` disk wording
        let gi: UInt64 = 1 << 30
        precondition(PodReports.human(bytes: 24 * gi) == "24Gi")
        precondition(PodReports.human(bytes: 228 * gi) == "228Gi")
        precondition(PodReports.human(bytes: gi * 34 / 10) == "3.4Gi")
        precondition(PodReports.human(bytes: 512 << 20) == "512Mi")
        precondition(PodReports.human(bytes: 1000 << 20) == "1.0Gi")
        precondition(PodReports.human(bytes: 999) == "999B")

        // Pod: built-in reports, unchanged wording
        let low = PodReports.fallback(disk: "24Gi", mem: 85, battery: 7, onAC: false)
        precondition(low.count == 6)
        precondition(low[0] == "Proposal: system nominal. Continue operation.")
        precondition(low[1] == "Disk reserve: 24Gi available.")
        precondition(low[2] == "Warning: memory pressure 85%. Exceeds tolerance.")
        precondition(low[3] == "Power reserve 7%.")
        precondition(low[5] == "Analysis: operator condition stable. Recommendation: hydrate.")
        let ok = PodReports.fallback(disk: "24Gi", mem: 40, battery: 90, onAC: true)
        precondition(ok[2] == "Memory pressure 40%. Within tolerance.")
        precondition(ok[3] == "Power reserve 90%. External supply connected.")

        // Pod: oracle cache is used only while fresh (< 20 min), non-empty, well-formed
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func cache(_ json: String) -> [String]? { PodReports.cached(json.data(using: .utf8), now: now) }
        precondition(cache(#"{"generated": 1799998801, "messages": ["a", "b"]}"#) == ["a", "b"])
        precondition(cache(#"{"generated": 1799998800, "messages": ["a"]}"#) == nil)   // exactly 20 min
        precondition(cache(#"{"generated": 1799999999, "messages": []}"#) == nil)
        precondition(cache(#"{"messages": ["a"]}"#) == nil)
        precondition(cache("not json") == nil)
        precondition(PodReports.cached(nil, now: now) == nil)

        // Pod: marquee maths, panel box
        precondition(PodStyle.marqueeOvershoot(textWidth: 427) == 127)
        precondition(PodStyle.marqueeOvershoot(textWidth: 280) <= 0)
        precondition(PodStyle.marqueeDuration(overshoot: 127) == 8.1)   // (3.2 + 127/26).toFixed(1)
        precondition(PodStyle.typeSteps == 44 && PodStyle.typeDuration == 1.6)
        precondition(PodStyle.cycleInterval == 30 && PodStyle.staleAfter == 1200)
        precondition(near(PodStyle.size.width, 332))
        // 1+13 + header 9 + 7 + rule 1 + 8 + 11*1.7 + 13+1, with Cascadia Code installed
        if NSFont(name: HUDStyle.family, size: 8) != nil {
            precondition(near(PodStyle.headerHeight, 9))
            precondition(near(PodStyle.size.height, 71.7))
        }

        // Bar: sketchybarrc colours. Text follows the palette; BRAND is the wordmark.
        precondition(Palette.light.wordmark == RGBA(hex: 0x4A4741) && Palette.light.text == RGBA(hex: 0x4A4741))
        precondition(Palette.dark.wordmark == RGBA(hex: 0xBC9A5A) && Palette.dark.text == RGBA(hex: 0xD8D4C4))

        // Bar: sketchybarrc geometry and entrance
        precondition(BarStyle.height == 32 && BarStyle.side == 12 && BarStyle.itemPadding == 6)
        precondition(BarStyle.crestSlot == 22 && BarStyle.crestSize == CGSize(width: 15.5, height: 18))
        precondition(BarStyle.entranceOffset == -36 && BarStyle.entranceDuration == 0.5)
        precondition(BarStyle.entranceCurve == (0.61, 1, 0.88, 1))
        // item boxes as `sketchybar --query` reported them on a 1710 pt screen
        precondition(BarStyle.layout(screenWidth: 1710, date: 66, clock: 33)
            == BarLayout(crest: 12, wordmark: 34, date: 1581, clock: 1659))
        if NSFont(name: HUDStyle.family, size: 11) != nil {
            let regular = BarStyle.font(bold: false), bold = BarStyle.font(bold: true)
            precondition(regular.fontName == "CascadiaCode-Regular" && bold.fontName == "CascadiaCode-Bold")
            func width(_ s: String, _ font: NSFont) -> CGFloat {
                BarStyle.labelWidth(NSAttributedString(string: s, attributes: [.font: font]))
            }
            precondition(width("YoRHa", bold) == 34)
            precondition(width("07.14", regular) == 33 && width("WED 21 OCT", regular) == 66)
            precondition(BarStyle.baseline(regular) == 20 && BarStyle.baseline(bold) == 20)
        }

        // Bar: `date` wording, independent of the system locale
        let utc = TimeZone(identifier: "UTC")!
        let morning = Date(timeIntervalSince1970: 1_792_566_840)   // 2026-10-21 07:14 UTC
        precondition(BarFormat.clock(morning, timeZone: utc) == "07.14")
        precondition(BarFormat.day(morning, timeZone: utc) == "WED 21 OCT")
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        precondition(BarFormat.clock(morning, timeZone: jakarta) == "14.14")
        let firstOfMarch = Date(timeIntervalSince1970: 1_803_859_200)   // 2027-03-01 00:00 UTC
        precondition(BarFormat.clock(firstOfMarch, timeZone: utc) == "00.00")
        precondition(BarFormat.day(firstOfMarch, timeZone: utc) == "MON 01 MAR")

        // Bar: the next wall-clock minute, never the current one
        let boundary = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(BarFormat.nextMinute(after: boundary).timeIntervalSince1970 == 1_800_000_060)
        precondition(BarFormat.nextMinute(after: boundary + 0.5).timeIntervalSince1970 == 1_800_000_060)
        precondition(BarFormat.nextMinute(after: boundary - 0.001).timeIntervalSince1970 == 1_800_000_000)

        // Bar: embedded crest decodes at its 31x36 px size
        precondition(BarCrest.image?.width == 31 && BarCrest.image?.height == 36)
        // With the repo path: both installed crests share the embedded alpha, and the
        // dark one is the plain #BC9A5A tint the bar paints through it.
        if CommandLine.arguments.count > 1 {
            let assets = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("assets")
            func pixels(_ data: Data) -> [[Int]] {
                let rep = NSBitmapImageRep(data: data)!
                return (0..<rep.pixelsHigh).flatMap { y in (0..<rep.pixelsWide).map { x in
                    var px = [Int](repeating: 0, count: 4)
                    rep.getPixel(&px, atX: x, y: y)
                    return px
                } }
            }
            let mask = pixels(BarCrest.png)
            for name in ["yorha-icon-light.png", "yorha-icon-dark.png"] {
                let asset = pixels(try! Data(contentsOf: assets.appendingPathComponent(name)))
                precondition(asset.map { $0[3] } == mask.map { $0[3] }, "\(name) alpha differs")
            }
            precondition(mask.filter { $0[3] > 0 }.allSatisfy { $0[0..<3] == [0xBC, 0x9A, 0x5A] })
        }

        // live sampler: plausible values from the kernel
        let live = TelemetrySampler().sample()
        precondition((0...100).contains(live.cpu) && (0...100).contains(live.mem))
        precondition(!live.uptime.isEmpty)
        if let battery = live.battery { precondition((0...100).contains(battery)) }

        print("desktop tests passed")
    }
}

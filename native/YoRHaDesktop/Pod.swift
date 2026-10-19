import AppKit

// pod.jsx: Pod 042's message panel, bottom-right. Shows the Gemini oracle's cached
// messages (bin/pod-oracle.py, every 5 minutes) while they are fresh, else the
// built-in reports. One message per 30 s, typed in, ping-pong scrolled if long.

enum PodStyle {
    // .pod { bottom: 28px; right: 30px; width: 300px; padding: 13px 15px; border: 1px }
    static let right: CGFloat = 30
    static let bottom: CGFloat = 28
    static let contentWidth: CGFloat = 300
    static let paddingV: CGFloat = 13
    static let paddingH: CGFloat = 15
    static let border: CGFloat = 1
    // ::before / ::after: 8x8 box with a 1px border on two sides
    static let bracket: CGFloat = 9
    // .pod-hd { 8px; .3em; opacity .6; padding-bottom 7px; margin-bottom 8px }
    static let headerSize: CGFloat = 8
    static let headerTracking: CGFloat = 0.3
    static let headerOpacity: CGFloat = 0.6
    static let headerPadding: CGFloat = 7
    static let headerGap: CGFloat = 8
    // .pod-src { 7px; .18em; opacity .55 }  .live { accent; opacity .9 }
    static let sourceSize: CGFloat = 7
    static let sourceTracking: CGFloat = 0.18
    static let sourceOpacity: CGFloat = 0.55
    static let liveOpacity: CGFloat = 0.9
    // .pod-msg { 11px; line-height 1.7; .03em }
    static let messageSize: CGFloat = 11
    static let messageLineHeight: CGFloat = 1.7
    static let messageTracking: CGFloat = 0.03
    // type 1.6s steps(44, end); marquee after 2s; podIn .6s after .85s
    static let typeDuration: CFTimeInterval = 1.6
    static let typeSteps = 44
    static let marqueeDelay: CFTimeInterval = 2
    static let enterDelay: CFTimeInterval = 0.85
    static let enterDuration: CFTimeInterval = 0.6
    static let cycleInterval: TimeInterval = 30
    static let staleAfter: TimeInterval = 20 * 60   // ~4 missed oracle runs
    static let title = "Pod 042 — Support Unit"

    static var size: CGSize {
        CGSize(width: contentWidth + 2 * (paddingH + border),
               height: 2 * (border + paddingV) + headerHeight + headerPadding + 1
                   + headerGap + messageLine)
    }

    static var messageLine: CGFloat { messageSize * messageLineHeight }

    // A flex row of 8px and 7px text aligned on the baseline.
    static var headerHeight: CGFloat {
        let title = LineMetrics(HUDStyle.font(headerSize))
        let source = LineMetrics(HUDStyle.font(sourceSize))
        return max(title.ascent, source.ascent) + max(title.descent, source.descent)
    }

    // Measured from the rendered string, not estimated per character.
    static func marqueeOvershoot(textWidth: CGFloat) -> CGFloat {
        ceil(textWidth - contentWidth)
    }

    // (3.2 + overshoot / 26).toFixed(1)
    static func marqueeDuration(overshoot: CGFloat) -> CFTimeInterval {
        ((3.2 + Double(overshoot) / 26) * 10).rounded() / 10
    }
}

// WebKit's line box metrics: ascent and descent rounded separately.
struct LineMetrics {
    let ascent: CGFloat
    let descent: CGFloat
    let fontAscender: CGFloat

    init(_ font: NSFont) {
        ascent = font.ascender.rounded()
        descent = (-font.descender).rounded()
        fontAscender = font.ascender
    }

    // y for a TextLayer so its baseline sits `baseline` below the line top
    func textTop(baseline: CGFloat) -> CGFloat { baseline - fontAscender }
}

enum PodReports {
    static let cachePath = NSString(string: "~/.config/yorha/cache/pod-oracle.json").expandingTildeInPath

    // `df -h /` Avail column: 1024-based, "Gi"-style suffix, one decimal below 10.
    static func human(bytes: UInt64) -> String {
        let units = ["B", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei"]
        var value = Double(bytes)
        var unit = 0
        while value.rounded() >= 1000, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit > 0, value < 9.95 { return String(format: "%.1f%@", value, units[unit]) }
        return String(format: "%.0f%@", value.rounded(), units[unit])
    }

    static func diskFree(path: String = "/") -> String {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return "—" }
        return human(bytes: UInt64(s.f_bavail) * UInt64(s.f_bsize))
    }

    // Built-in reports, unchanged from the pre-Gemini widget.
    static func fallback(disk: String, mem: Int, battery: Int?, onAC: Bool) -> [String] {
        let power = battery.map(String.init) ?? "—"
        return [
            "Proposal: system nominal. Continue operation.",
            "Disk reserve: \(disk) available.",
            mem >= 80
                ? "Warning: memory pressure \(mem)%. Exceeds tolerance."
                : "Memory pressure \(mem)%. Within tolerance.",
            onAC
                ? "Power reserve \(power)%. External supply connected."
                : "Power reserve \(power)%.",
            "Maintenance cycle complete. No anomalies detected.",
            "Analysis: operator condition stable. Recommendation: hydrate.",
        ]
    }

    // The oracle's messages, or nil when missing, malformed, empty, or stale.
    static func cached(_ data: Data?, now: Date) -> [String]? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [String], !messages.isEmpty
        else { return nil }
        let generated = (json["generated"] as? NSNumber)?.doubleValue ?? 0
        let age = floor(now.timeIntervalSince1970) - generated
        return age < PodStyle.staleAfter ? messages : nil
    }
}

// One message stream for every screen.
final class PodFeed {
    var onMessage: ((String, Bool) -> Void)?
    private(set) var current: (message: String, live: Bool)?
    private var cycle = 0
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: PodStyle.cycleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let cached = PodReports.cached(
            FileManager.default.contents(atPath: PodReports.cachePath), now: Date())
        let reports = cached ?? {
            let power = TelemetrySampler.power()
            return PodReports.fallback(disk: PodReports.diskFree(),
                                       mem: TelemetrySampler.memoryPressure(),
                                       battery: power.battery, onAC: power.onAC)
        }()
        let message = reports[cycle % reports.count]
        cycle += 1
        current = (message, cached != nil)
        onMessage?(message, cached != nil)
    }
}

final class PodWidget {
    let layer = CALayer()
    private let reduceMotion: Bool
    private var palette: Palette
    private var latest: (message: String, live: Bool)?
    private var entered = false

    private let box = CALayer()        // entrance animates the whole panel
    private let brackets = (0..<4).map { _ in CALayer() }
    private let header = CALayer()     // opacity .6 covers title, source, and rule
    private let title = TextLayer()
    private let source = TextLayer()
    private let rule = CALayer()
    private let clip = CALayer()       // typewriter reveal + marquee window
    private let message = TextLayer()

    init(size: CGSize, scale: CGFloat, palette: Palette, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        self.palette = palette
        layer.frame = CGRect(origin: .zero, size: size)

        let s = PodStyle.size
        box.anchorPoint = .zero
        box.bounds = CGRect(origin: .zero, size: s)
        box.position = CGPoint(x: size.width - PodStyle.right - s.width,
                               y: size.height - PodStyle.bottom - s.height)
        box.borderWidth = PodStyle.border
        box.isHidden = true
        layer.addSublayer(box)

        // ::before top-left, ::after bottom-right, drawn over the border
        let b = PodStyle.bracket
        let bars = [CGRect(x: 0, y: 0, width: b, height: 1), CGRect(x: 0, y: 0, width: 1, height: b),
                    CGRect(x: s.width - b, y: s.height - 1, width: b, height: 1),
                    CGRect(x: s.width - 1, y: s.height - b, width: 1, height: b)]
        for (bar, frame) in zip(brackets, bars) {
            bar.frame = frame
            box.addSublayer(bar)
        }

        let inset = PodStyle.border + PodStyle.paddingH
        let top = PodStyle.border + PodStyle.paddingV
        header.frame = CGRect(x: inset, y: top, width: PodStyle.contentWidth,
                              height: PodStyle.headerHeight + PodStyle.headerPadding + 1)
        header.opacity = Float(PodStyle.headerOpacity)
        rule.frame = CGRect(x: 0, y: header.bounds.height - 1, width: PodStyle.contentWidth, height: 1)
        for t in [title, source, message] {
            t.anchorPoint = .zero
            t.contentsScale = scale
        }
        header.sublayers = [title, source, rule]
        box.addSublayer(header)

        clip.anchorPoint = .zero
        clip.position = CGPoint(x: inset, y: header.frame.maxY + PodStyle.headerGap)
        clip.bounds = CGRect(x: 0, y: 0, width: PodStyle.contentWidth, height: PodStyle.messageLine)
        clip.masksToBounds = true
        clip.addSublayer(message)
        box.addSublayer(clip)
    }

    func show(_ text: String, live: Bool) {
        latest = (text, live)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        render()
        CATransaction.commit()

        box.isHidden = false
        guard !reduceMotion else { return }
        if !entered {
            entered = true
            enter()
        }
        typeIn()
        marquee()
    }

    // Called inside DesktopScene's palette transaction: colours ease over 200 ms.
    func apply(_ palette: Palette) {
        self.palette = palette
        render()
    }

    // MARK: - render

    private func render() {
        guard let (text, live) = latest else { return }
        let p = palette
        box.backgroundColor = p.panel.cgColor
        box.borderColor = p.podBorder.cgColor
        brackets.forEach { $0.backgroundColor = p.ornament.cgColor }
        rule.backgroundColor = p.podRule.cgColor

        set(title, PodStyle.title.uppercased(), size: PodStyle.headerSize,
            tracking: PodStyle.headerTracking, color: p.text)
        set(source, live ? "◂LINK" : "LOCAL", size: PodStyle.sourceSize,
            tracking: PodStyle.sourceTracking,
            color: live ? p.accent.withAlpha(PodStyle.liveOpacity)
                        : p.text.withAlpha(PodStyle.sourceOpacity))
        set(message, text, size: PodStyle.messageSize,
            tracking: PodStyle.messageTracking, color: p.text)

        // header: baseline-aligned flex row, source pushed to the right edge
        let titleMetrics = LineMetrics(HUDStyle.font(PodStyle.headerSize))
        let sourceMetrics = LineMetrics(HUDStyle.font(PodStyle.sourceSize))
        let baseline = max(titleMetrics.ascent, sourceMetrics.ascent)
        title.position = CGPoint(x: 0, y: titleMetrics.textTop(baseline: baseline))
        source.position = CGPoint(x: PodStyle.contentWidth - source.bounds.width,
                                  y: sourceMetrics.textTop(baseline: baseline))

        // message: CSS half-leading inside the 1.7 line box
        let m = LineMetrics(HUDStyle.font(PodStyle.messageSize))
        let halfLeading = (PodStyle.messageLine - m.ascent - m.descent) / 2
        message.position = CGPoint(x: 0, y: m.textTop(baseline: halfLeading + m.ascent))
    }

    private func set(_ t: TextLayer, _ string: String, size: CGFloat, tracking: CGFloat, color: RGBA) {
        t.text = NSAttributedString(string: string, attributes: [
            .font: HUDStyle.font(size), .kern: tracking * size, .foregroundColor: color.nsColor,
        ])
        let s = t.text.size()
        t.bounds = CGRect(x: 0, y: 0, width: ceil(s.width), height: ceil(s.height))
    }

    // MARK: - motion

    // podIn: opacity 0 -> 1 by 60%, translateY 10 -> -2 -> 0, delay .85s
    private func enter() {
        let c = HUDStyle.bootCurve
        let curve = CAMediaTimingFunction(controlPoints: c.0, c.1, c.2, c.3)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1]
        let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
        rise.values = [10, -2, 0]
        for a in [fade, rise] {
            a.keyTimes = [0, 0.6, 1]
            a.timingFunctions = [curve, curve]
        }
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = PodStyle.enterDuration
        group.beginTime = CACurrentMediaTime() + PodStyle.enterDelay
        group.fillMode = .backwards
        box.add(group, forKey: "podIn")
    }

    // type: max-width 0 -> 100% in 44 discrete steps over 1.6s. The model value is
    // the full width, so a reveal that never runs leaves the message visible.
    private func typeIn() {
        let steps = PodStyle.typeSteps
        let width = PodStyle.contentWidth
        let type = CAKeyframeAnimation(keyPath: "bounds.size.width")
        type.calculationMode = .discrete
        type.values = (0..<steps).map { width * CGFloat($0) / CGFloat(steps) }
        type.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        type.duration = PodStyle.typeDuration
        clip.add(type, forKey: "type")
    }

    // Long lines ping-pong: dwell, scroll left, dwell, scroll back, forever.
    private func marquee() {
        message.removeAnimation(forKey: "marquee")
        let overshoot = PodStyle.marqueeOvershoot(textWidth: message.text.size().width)
        guard overshoot > 0 else { return }
        let scroll = CAKeyframeAnimation(keyPath: "transform.translation.x")
        scroll.values = [0, 0, -overshoot, -overshoot]
        scroll.keyTimes = [0, 0.18, 0.82, 1]
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        scroll.timingFunctions = [ease, ease, ease]
        scroll.duration = PodStyle.marqueeDuration(overshoot: overshoot)
        scroll.autoreverses = true
        scroll.repeatCount = .infinity
        scroll.beginTime = CACurrentMediaTime() + PodStyle.marqueeDelay
        message.add(scroll, forKey: "marquee")
    }
}

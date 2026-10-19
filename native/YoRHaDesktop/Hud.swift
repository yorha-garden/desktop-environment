import AppKit

// hud.jsx: corner telemetry. Processor load + network top-left, memory pressure +
// power reserve top-right, uptime bottom-left. Each box boots in once, staggered.

enum HUDStyle {
    static let family = "Cascadia Code"
    // .tl/.tr { top: 60px; left|right: 30px }  .bl { bottom: 28px; left: 30px }
    static let top: CGFloat = 60
    static let side: CGFloat = 30
    static let bottom: CGFloat = 28
    // .k { 8.5px; letter-spacing .3em; uppercase; opacity .55 }
    static let labelSize: CGFloat = 8.5
    static let labelTracking: CGFloat = 0.3
    static let labelOpacity: CGFloat = 0.55
    // .v { 19px; letter-spacing .09em; margin-top 2px }  .v small { 10px; opacity .6 }
    static let valueSize: CGFloat = 19
    static let secondaryValueSize: CGFloat = 14
    static let unitSize: CGFloat = 10
    static let unitOpacity: CGFloat = 0.6
    static let valueTracking: CGFloat = 0.09
    static let valueGap: CGFloat = 2
    // .meter { 126x3; margin-top 8px }  .sub { margin-top 14px }
    static let meterSize = CGSize(width: 126, height: 3)
    static let meterGap: CGFloat = 8
    static let subGap: CGFloat = 14
    static let meterDuration: CFTimeInterval = 0.8
    // .hud-enter: bootIn .55s cubic-bezier(.34,1.56,.64,1), delays .1/.35/.6
    static let bootDuration: CFTimeInterval = 0.55
    static let bootCurve: (Float, Float, Float, Float) = (0.34, 1.56, 0.64, 1)
    static let bootDelays: [CFTimeInterval] = [0.1, 0.35, 0.6]
    // network every second; the rest adopts a fresh sample every three
    static let networkInterval: TimeInterval = 1
    static let telemetryInterval: TimeInterval = 3

    static func font(_ size: CGFloat) -> NSFont {
        NSFont(name: family, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // CSS line-height: normal = ascent + descent + line gap.
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        let f = font(size)
        return (f.ascender - f.descender + f.leading).rounded()
    }

    static func meterFill(_ percent: Int) -> CGFloat {
        meterSize.width * CGFloat(min(max(percent, 0), 100)) / 100
    }
}

final class HudWidget {
    let layer = CALayer()
    private let size: CGSize
    private let scale: CGFloat
    private let reduceMotion: Bool
    private var palette: Palette
    private var latest: (Telemetry, String)?
    private var booted = false

    private let boxes: [CALayer]   // tl, tr, bl — each animates in as a unit
    private let cpuLabel, cpuValue, netLabel, netValue: TextLayer
    private let memLabel, memValue, powerLabel, powerValue: TextLayer
    private let upLabel, upValue: TextLayer
    private let cpuMeter, memMeter: Meter

    init(size: CGSize, scale: CGFloat, palette: Palette, reduceMotion: Bool) {
        self.size = size
        self.scale = scale
        self.reduceMotion = reduceMotion
        self.palette = palette
        layer.frame = CGRect(origin: .zero, size: size)

        func text() -> TextLayer {
            let t = TextLayer()
            t.contentsScale = scale
            t.anchorPoint = .zero
            return t
        }
        cpuLabel = text(); cpuValue = text(); netLabel = text(); netValue = text()
        memLabel = text(); memValue = text(); powerLabel = text(); powerValue = text()
        upLabel = text(); upValue = text()
        cpuMeter = Meter(scale: scale)
        memMeter = Meter(scale: scale)

        boxes = (0..<3).map { _ in
            let box = CALayer()
            box.frame = CGRect(origin: .zero, size: size)
            box.isHidden = true   // nothing until the first sample, like the empty first render
            return box
        }
        boxes[0].sublayers = [cpuLabel, cpuValue, cpuMeter.track, netLabel, netValue]
        boxes[1].sublayers = [memLabel, memValue, memMeter.track, powerLabel, powerValue]
        boxes[2].sublayers = [upLabel, upValue]
        boxes.forEach(layer.addSublayer)
    }

    func update(_ telemetry: Telemetry, rate: String) {
        latest = (telemetry, rate)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        render()
        CATransaction.commit()

        if !booted {
            booted = true
            boxes.forEach { $0.isHidden = false }
            if !reduceMotion { bootIn() }
        }
    }

    // Called inside DesktopScene's palette transaction, so colours ease over 200 ms.
    func apply(_ palette: Palette) {
        self.palette = palette
        render()
    }

    // MARK: - render

    private func render() {
        guard let (t, rate) = latest else { return }
        let p = palette

        set(cpuLabel, label("Processor load"))
        set(cpuValue, value("\(t.cpu)", unit: "%", alert: false))
        set(netLabel, label("Network"))
        set(netValue, secondary(rate, alert: false))
        set(memLabel, label("Memory pressure"))
        set(memValue, value("\(t.mem)", unit: "%", alert: t.memAlert))
        set(powerLabel, label("Power reserve"))
        set(powerValue, secondary((t.battery.map { "\($0)%" } ?? "—") + (t.onAC ? " ◂AC" : ""),
                                  alert: t.batteryAlert))
        set(upLabel, label("Uptime"))
        set(upValue, secondary(t.uptime, alert: false))

        cpuMeter.apply(track: p.track, fill: p.value)
        memMeter.apply(track: p.track, fill: t.memAlert ? p.alert : p.value)
        setMeter(cpuMeter, t.cpu)
        setMeter(memMeter, t.mem)

        layout()
    }

    private func layout() {
        let labelLine = HUDStyle.lineHeight(HUDStyle.labelSize)
        let valueLine = HUDStyle.lineHeight(HUDStyle.valueSize)
        let secondaryLine = HUDStyle.lineHeight(HUDStyle.secondaryValueSize)

        // The two top boxes share one vertical rhythm.
        var y = HUDStyle.top
        let labelY = y;            y += labelLine + HUDStyle.valueGap
        let valueY = y;            y += valueLine + HUDStyle.meterGap
        let meterY = y;            y += HUDStyle.meterSize.height + HUDStyle.subGap
        let subLabelY = y;         y += labelLine + HUDStyle.valueGap
        let subValueY = y

        let left = HUDStyle.side
        place(cpuLabel, x: left, y: labelY)
        place(cpuValue, x: left, y: valueY)
        cpuMeter.track.position = CGPoint(x: left, y: meterY)
        place(netLabel, x: left, y: subLabelY)
        place(netValue, x: left, y: subValueY)

        let right = size.width - HUDStyle.side
        place(memLabel, right: right, y: labelY)
        place(memValue, right: right, y: valueY)
        memMeter.track.position = CGPoint(x: right - HUDStyle.meterSize.width, y: meterY)
        place(powerLabel, right: right, y: subLabelY)
        place(powerValue, right: right, y: subValueY)

        let upTop = size.height - HUDStyle.bottom - (labelLine + HUDStyle.valueGap + secondaryLine)
        place(upLabel, x: left, y: upTop)
        place(upValue, x: left, y: upTop + labelLine + HUDStyle.valueGap)
    }

    private func place(_ t: TextLayer, x: CGFloat, y: CGFloat) {
        t.position = CGPoint(x: x, y: y)
    }

    private func place(_ t: TextLayer, right: CGFloat, y: CGFloat) {
        t.position = CGPoint(x: right - t.bounds.width, y: y)
    }

    private func set(_ t: TextLayer, _ string: NSAttributedString) {
        t.text = string
        let s = string.size()
        t.bounds = CGRect(x: 0, y: 0, width: ceil(s.width), height: ceil(s.height))
    }

    // MARK: - text styles

    private func label(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: HUDStyle.font(HUDStyle.labelSize),
            .kern: HUDStyle.labelTracking * HUDStyle.labelSize,
            .foregroundColor: palette.text.withAlpha(HUDStyle.labelOpacity).nsColor,
        ])
    }

    private func value(_ number: String, unit: String, alert: Bool) -> NSAttributedString {
        let color = alert ? palette.alert : palette.value
        // letter-spacing in em is computed on .v and inherited by <small> as a length
        let kern = HUDStyle.valueTracking * HUDStyle.valueSize
        let s = NSMutableAttributedString(string: number, attributes: [
            .font: HUDStyle.font(HUDStyle.valueSize), .kern: kern, .foregroundColor: color.nsColor,
        ])
        s.append(NSAttributedString(string: unit, attributes: [
            .font: HUDStyle.font(HUDStyle.unitSize), .kern: kern,
            .foregroundColor: color.withAlpha(HUDStyle.unitOpacity).nsColor,
        ]))
        return s
    }

    private func secondary(_ text: String, alert: Bool) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: HUDStyle.font(HUDStyle.secondaryValueSize),
            .kern: HUDStyle.valueTracking * HUDStyle.secondaryValueSize,
            .foregroundColor: (alert ? palette.alert : palette.value).nsColor,
        ])
    }

    // MARK: - motion

    // .meter i { transition: width .8s ease }
    private func setMeter(_ meter: Meter, _ percent: Int) {
        let width = HUDStyle.meterFill(percent)
        guard meter.fill.bounds.width != width else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(reduceMotion || !booted)
        CATransaction.setAnimationDuration(HUDStyle.meterDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .default))
        meter.fill.bounds.size.width = width
        CATransaction.commit()
    }

    // bootIn: opacity 0 -> 1 by 60%, translateY 9 -> -2 (60%) -> 0, same curve per segment
    private func bootIn() {
        let c = HUDStyle.bootCurve
        let curve = CAMediaTimingFunction(controlPoints: c.0, c.1, c.2, c.3)
        let start = CACurrentMediaTime()
        for (box, delay) in zip(boxes, HUDStyle.bootDelays) {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1]
            let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
            rise.values = [9, -2, 0]
            for a in [fade, rise] {
                a.keyTimes = [0, 0.6, 1]
                a.timingFunctions = [curve, curve]
            }
            let group = CAAnimationGroup()
            group.animations = [fade, rise]
            group.duration = HUDStyle.bootDuration
            group.beginTime = start + delay
            group.fillMode = .backwards   // hidden through the stagger delay
            box.add(group, forKey: "bootIn")
        }
    }
}

// A 126x3 track with a value fill anchored at its left edge.
final class Meter {
    let track = CALayer()
    let fill = CALayer()

    init(scale: CGFloat) {
        track.anchorPoint = .zero
        track.bounds = CGRect(origin: .zero, size: HUDStyle.meterSize)
        track.masksToBounds = true
        track.contentsScale = scale
        fill.anchorPoint = .zero
        fill.position = .zero
        fill.bounds = CGRect(x: 0, y: 0, width: 0, height: HUDStyle.meterSize.height)
        track.addSublayer(fill)
    }

    func apply(track trackColor: RGBA, fill fillColor: RGBA) {
        track.backgroundColor = trackColor.cgColor
        fill.backgroundColor = fillColor.cgColor
    }
}

import AppKit

// sketchybarrc: a transparent 32 pt bar across the top of every screen. Crest and
// YoRHa wordmark on the left; date and clock on the right, redrawn on wall-clock
// minute boundaries. Replaces SketchyBar and its launchd minute trigger.

enum BarStyle {
    // --bar height=32 padding_left=12 padding_right=12
    static let height: CGFloat = 32
    static let side: CGFloat = 12
    // --default padding_left=6 padding_right=6; the wordmark has padding_left=0
    static let itemPadding: CGFloat = 6
    // yorha_icon: width=22 slot; the 31x36 px PNG at scale 0.5 sits at the slot's
    // left edge (measured: SketchyBar does not centre it), centred vertically.
    static let crestSlot: CGFloat = 22
    static let crestSize = CGSize(width: 15.5, height: 18)
    // label.font="Cascadia Code:Regular:11.0", wordmark Bold
    static let family = "Cascadia Code"
    static let fontSize: CGFloat = 11
    static let wordmark = "YoRHa"
    // y_offset -36 -> 0 with `--animate sin 30`: 30 frames at 60 Hz of sin(t·π/2)
    static let entranceOffset: CGFloat = -36
    static let entranceDuration: CFTimeInterval = 0.5
    static let entranceCurve: (Float, Float, Float, Float) = (0.61, 1, 0.88, 1)   // easeOutSine
    // SketchyBar draws each label 1 pt into its box.
    static let labelInset: CGFloat = 1

    static func font(bold: Bool) -> NSFont {
        let font = NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [],
                                             weight: bold ? 9 : 5, size: fontSize)
        return font ?? .monospacedSystemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
    }

    // SketchyBar sizes a label by its glyph ink, not its advance: the ink's right
    // edge rounded up, plus the 1 pt inset. `sketchybar --query` reports 34 for
    // the wordmark, 33 for "07.14", 66 for "WED 21 OCT".
    static func labelWidth(_ text: NSAttributedString) -> CGFloat {
        let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
        return ceil(ink.maxX) + labelInset
    }

    // Baseline below the bar top. SketchyBar centres ascent - descent on the
    // midline in y-up points and truncates to a whole point: 20 for Cascadia 11.
    static func baseline(_ font: NSFont) -> CGFloat {
        height - floor(height / 2 - (font.ascender + font.descender) / 2)
    }

    // Left items run from the left padding; right items pack in from the right
    // padding in the order the rc added them, so the clock is rightmost.
    static func layout(screenWidth: CGFloat, date: CGFloat, clock: CGFloat) -> BarLayout {
        let clockX = screenWidth - side - itemPadding - clock
        return BarLayout(crest: side, wordmark: side + crestSlot,
                         date: clockX - 2 * itemPadding - date, clock: clockX)
    }
}

// `yorha-watcher off bar` leaves this marker and restarts the app, which then
// draws the desktop layer without the bar. Read once at launch.
enum BarSwitch {
    static let marker = ".config/yorha/bar-off"

    // launchd sets HOME for the agent; tests point it at a sandbox.
    static func isOn(home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) -> Bool {
        !FileManager.default.fileExists(atPath: (home as NSString).appendingPathComponent(marker))
    }
}

// x of each item's box, in points from the screen's left edge
struct BarLayout: Equatable {
    let crest: CGFloat
    let wordmark: CGFloat
    let date: CGFloat
    let clock: CGFloat
}

enum BarFormat {
    // date '+%H.%M'
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, "HH.mm", timeZone)
    }

    // date '+%a %d %b' | tr '[:lower:]' '[:upper:]', in the C locale launchd gave it
    static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, "EEE dd MMM", timeZone).uppercased()
    }

    static func nextMinute(after date: Date) -> Date {
        Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / 60) + 1) * 60)
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

// One clock for every bar. A wall-clock deadline at each minute boundary replaces
// the launchd trigger: unlike a relative interval it fires on time after a sleep.
// Stops while the displays sleep; start() redraws at once, as system_woke did.
final class MinuteClock {
    var onTick: ((Date) -> Void)?
    private var timer: DispatchSourceTimer?

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        tick()
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // The system clock or time zone changed: redraw now and re-arm.
    func refresh() {
        guard timer != nil else { return }
        tick()
    }

    private func tick() {
        let now = Date()
        onTick?(now)
        let next = BarFormat.nextMinute(after: now).timeIntervalSince1970
        let deadline = timespec(tv_sec: Int(next), tv_nsec: 0)
        timer?.schedule(wallDeadline: DispatchWallTime(timespec: deadline), leeway: .milliseconds(50))
    }
}

// One click-through strip per screen at SketchyBar's level (backstop menu, -20):
// above the desktop layer, below app windows, on every Space but full-screen ones.
final class BarWindow: NSWindow {
    let bar: BarWidget

    init(screen: NSScreen, palette: Palette, reduceMotion: Bool, entrance: Bool) {
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - BarStyle.height,
                           width: screen.frame.width, height: BarStyle.height)
        bar = BarWidget(width: frame.width, scale: screen.backingScaleFactor, palette: palette,
                        reduceMotion: reduceMotion, entrance: entrance)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(frame, display: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = layerHostingView(size: frame.size, root: bar.layer)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BarWidget {
    let layer = CALayer()
    private let width: CGFloat
    private var palette: Palette
    private var now: Date?

    // The entrance slides this, not the root: the root's own transform applies in
    // the unflipped host layer's y-up space, which measured as a slide up from below.
    private let content = CALayer()
    private let crest = CALayer()       // tinted fill, shaped by the crest mask
    private let wordmark = TextLayer()
    private let date = TextLayer()
    private let clock = TextLayer()

    init(width: CGFloat, scale: CGFloat, palette: Palette, reduceMotion: Bool, entrance: Bool) {
        self.width = width
        self.palette = palette
        layer.isGeometryFlipped = true
        layer.frame = CGRect(x: 0, y: 0, width: width, height: BarStyle.height)
        layer.contentsScale = scale
        content.frame = layer.bounds
        layer.addSublayer(content)

        let s = BarStyle.crestSize
        crest.frame = CGRect(x: BarStyle.side, y: (BarStyle.height - s.height) / 2,
                             width: s.width, height: s.height)
        let mask = CALayer()
        mask.frame = crest.bounds
        mask.contents = BarCrest.image
        mask.contentsGravity = .resize
        mask.contentsScale = scale
        crest.mask = mask
        content.addSublayer(crest)

        for t in [wordmark, date, clock] {
            t.anchorPoint = .zero
            t.contentsScale = scale
            t.smoothsFonts = false
            content.addSublayer(t)
        }
        render()

        // Model values stay at rest, so a dropped animation still leaves the bar
        // on screen (the rc's y_offset=0 guarantee).
        guard entrance, !reduceMotion else { return }
        let c = BarStyle.entranceCurve
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = BarStyle.entranceOffset
        slide.toValue = 0
        slide.duration = BarStyle.entranceDuration
        slide.timingFunction = CAMediaTimingFunction(controlPoints: c.0, c.1, c.2, c.3)
        content.add(slide, forKey: "entrance")
    }

    func show(_ date: Date) {
        now = date
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        render()
        CATransaction.commit()
    }

    // Called inside the palette transaction, so colours ease over 200 ms.
    func apply(_ palette: Palette) {
        self.palette = palette
        render()
    }

    private func render() {
        let p = palette
        crest.backgroundColor = p.wordmark.cgColor
        let mark = set(wordmark, BarStyle.wordmark, bold: true, color: p.wordmark)
        let day = set(date, now.map { BarFormat.day($0) } ?? "", bold: false, color: p.text)
        let time = set(clock, now.map { BarFormat.clock($0) } ?? "", bold: false, color: p.text)

        let x = BarStyle.layout(screenWidth: width, date: day, clock: time)
        wordmark.frame = CGRect(x: x.wordmark, y: 0, width: mark, height: BarStyle.height)
        date.frame = CGRect(x: x.date, y: 0, width: day, height: BarStyle.height)
        clock.frame = CGRect(x: x.clock, y: 0, width: time, height: BarStyle.height)
    }

    // Sets the line and its in-layer origin; returns the box width. The layer
    // stays on whole points and the baseline lands exactly where SketchyBar's does.
    private func set(_ t: TextLayer, _ string: String, bold: Bool, color: RGBA) -> CGFloat {
        let font = BarStyle.font(bold: bold)
        t.text = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color.nsColor,
        ])
        t.origin = CGPoint(x: BarStyle.labelInset, y: BarStyle.baseline(font) - font.ascender)
        return string.isEmpty ? 0 : BarStyle.labelWidth(t.text)
    }
}

import AppKit

// One borderless, click-through window per screen, pinned to the desktop layer on
// every Space — the same placement Übersicht used, so Finder's icons stay on top.
final class DesktopWindow: NSWindow {
    let scene: DesktopScene

    init(screen: NSScreen, palette: Palette, reduceMotion: Bool) {
        scene = DesktopScene(size: screen.frame.size, scale: screen.backingScaleFactor,
                             palette: palette, reduceMotion: reduceMotion)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = layerHostingView(size: screen.frame.size, root: scene.root)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Layer-hosting view. AppKit resets isGeometryFlipped on the view's own layer
// (measured: a flipped hosting layer still drew y-up), so a flipped root goes in
// as a sublayer of a plain host layer instead.
func layerHostingView(size: CGSize, root: CALayer) -> NSView {
    let view = NSView(frame: NSRect(origin: .zero, size: size))
    let host = CALayer()
    view.layer = host
    view.wantsLayer = true
    host.frame = view.bounds
    host.addSublayer(root)
    return view
}

// Everything drawn on one screen. Widgets are added here phase by phase.
final class DesktopScene {
    let root = CALayer()
    private let beam: BeamWidget
    private let arcs: ArcsWidget
    private let hud: HudWidget
    private let pod: PodWidget

    init(size: CGSize, scale: CGFloat, palette: Palette, reduceMotion: Bool) {
        root.isGeometryFlipped = true
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale

        // Beam behind the ornaments; telemetry and the Pod panel on top.
        beam = BeamWidget(size: size, scale: scale, palette: palette, reduceMotion: reduceMotion)
        arcs = ArcsWidget(size: size, scale: scale, palette: palette, reduceMotion: reduceMotion)
        hud = HudWidget(size: size, scale: scale, palette: palette, reduceMotion: reduceMotion)
        pod = PodWidget(size: size, scale: scale, palette: palette, reduceMotion: reduceMotion)
        [beam.layer, arcs.layer, hud.layer, pod.layer].forEach(root.addSublayer)
    }

    func update(_ telemetry: Telemetry, rate: String) {
        hud.update(telemetry, rate: rate)
    }

    func show(podMessage message: String, live: Bool) {
        pod.show(message, live: live)
    }

    func apply(_ palette: Palette) {
        beam.apply(palette)
        arcs.apply(palette)
        hud.apply(palette)
        pod.apply(palette)
    }
}

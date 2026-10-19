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

        // Layer-hosting view. AppKit resets isGeometryFlipped on the view's own
        // layer (measured: a flipped hosting layer still drew y-up), so the
        // flipped scene root is a sublayer of a plain host layer instead.
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let host = CALayer()
        view.layer = host
        view.wantsLayer = true
        host.frame = view.bounds
        host.addSublayer(scene.root)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Everything drawn on one screen. Widgets are added here phase by phase.
final class DesktopScene {
    let root = CALayer()
    private let beam: BeamWidget
    private let arcs: ArcsWidget

    init(size: CGSize, scale: CGFloat, palette: Palette, reduceMotion: Bool) {
        root.isGeometryFlipped = true
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale

        // Beam behind the ornaments; HUD and Pod will stack above both.
        beam = BeamWidget(size: size, scale: scale, palette: palette, reduceMotion: reduceMotion)
        arcs = ArcsWidget(size: size, scale: scale, palette: palette, reduceMotion: reduceMotion)
        root.addSublayer(beam.layer)
        root.addSublayer(arcs.layer)
    }

    func apply(_ palette: Palette, animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Palette.transitionDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        beam.apply(palette)
        arcs.apply(palette)
        CATransaction.commit()
    }
}

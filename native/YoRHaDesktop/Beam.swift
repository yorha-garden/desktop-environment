import QuartzCore

// beam.jsx: a 14vh gradient band sweeping top to bottom every 11s, forever.
// A render-server animation on one layer — no timers, no per-frame code.
final class BeamWidget {
    let layer = CALayer()
    private let band = CAGradientLayer()

    init(size: CGSize, scale: CGFloat, palette: Palette, reduceMotion: Bool) {
        layer.frame = CGRect(origin: .zero, size: size)
        layer.masksToBounds = true

        band.frame = CGRect(x: 0, y: 0, width: size.width,
                            height: BeamGeometry.bandHeight(screenHeight: size.height))
        band.startPoint = CGPoint(x: 0.5, y: 0)
        band.endPoint = CGPoint(x: 0.5, y: 1)
        band.locations = BeamGeometry.locations
        band.colors = BeamGeometry.colors(palette)
        band.contentsScale = scale
        layer.addSublayer(band)

        // prefers-reduced-motion: animation none, opacity 0
        guard !reduceMotion else {
            band.isHidden = true
            return
        }
        let travel = BeamGeometry.travel(screenHeight: size.height)
        let sweep = CABasicAnimation(keyPath: "transform.translation.y")
        sweep.fromValue = travel.from
        sweep.toValue = travel.to
        sweep.duration = BeamGeometry.duration
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        band.add(sweep, forKey: "sweep")
    }

    func apply(_ palette: Palette) {
        band.colors = BeamGeometry.colors(palette)
    }
}

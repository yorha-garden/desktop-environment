import QuartzCore

// arcs.jsx: two quarter-arcs and three diagonals in the top-left corner, the same
// pair rotated 180° in the bottom-right. Each stroke draws on once; arcs then
// breathe and lines wave. As in the CSS, the motion lives on a wrapper layer and
// the stroke itself is never re-rasterized.
final class ArcsWidget {
    let layer = CALayer()
    private var strokes: [CAShapeLayer] = []
    private let scale: CGFloat
    private let reduceMotion: Bool
    private let start = CACurrentMediaTime()

    init(size: CGSize, scale: CGFloat, palette: Palette, reduceMotion: Bool) {
        self.scale = scale
        self.reduceMotion = reduceMotion
        layer.frame = CGRect(origin: .zero, size: size)
        layer.masksToBounds = true

        let lines = ArcGeometry.lineCornerFrames(in: size)
        layer.addSublayer(lineCorner(lines.topLeft, rotated: false))
        layer.addSublayer(lineCorner(lines.bottomRight, rotated: true))
        let arcs = ArcGeometry.arcCornerFrames(in: size)
        layer.addSublayer(arcCorner(arcs.topLeft, rotated: false))
        layer.addSublayer(arcCorner(arcs.bottomRight, rotated: true))

        apply(palette)
    }

    func apply(_ palette: Palette) {
        let color = palette.ornament.withAlpha(ArcGeometry.strokeOpacity).cgColor
        strokes.forEach { $0.strokeColor = color }
    }

    // MARK: - corners

    private func arcCorner(_ frame: CGRect, rotated: Bool) -> CALayer {
        let corner = box(frame, rotated: rotated)
        for (i, path) in ArcGeometry.arcPaths().enumerated() {
            let wrapper = box(CGRect(origin: .zero, size: frame.size), rotated: false)
            let stroke = makeStroke(path, size: frame.size)
            wrapper.addSublayer(stroke)
            corner.addSublayer(wrapper)
            let delay = ArcMotion.arcDelays[i]
            animateDraw(stroke, delay: delay)
            animateBreathe(wrapper, delay: delay)
        }
        return corner
    }

    private func lineCorner(_ frame: CGRect, rotated: Bool) -> CALayer {
        let corner = box(frame, rotated: rotated)
        for i in ArcGeometry.lines.indices {
            let wrapper = box(CGRect(origin: .zero, size: frame.size), rotated: false)
            let stroke = makeStroke(ArcGeometry.linePath(i), size: frame.size)
            wrapper.addSublayer(stroke)
            corner.addSublayer(wrapper)
            let delay = ArcMotion.lineDelays[i]
            animateDraw(stroke, delay: delay)
            animateWave(wrapper, delay: delay)
        }
        return corner
    }

    // A layer placed by bounds + position so scale and rotation pivot on its
    // centre, like CSS transform-origin: center.
    private func box(_ frame: CGRect, rotated: Bool) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        if rotated {
            layer.transform = CATransform3DMakeRotation(.pi, 0, 0, 1)
        }
        return layer
    }

    private func makeStroke(_ path: CGPath, size: CGSize) -> CAShapeLayer {
        let stroke = CAShapeLayer()
        stroke.frame = CGRect(origin: .zero, size: size)
        stroke.path = path
        stroke.fillColor = nil
        stroke.lineWidth = ArcGeometry.strokeWidth
        stroke.contentsScale = scale
        strokes.append(stroke)
        return stroke
    }

    // MARK: - motion (all skipped under reduced motion: strokes stay fully drawn)

    private func animateDraw(_ stroke: CAShapeLayer, delay: CFTimeInterval) {
        guard !reduceMotion else { return }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = ArcMotion.drawDuration
        let c = ArcMotion.drawCurve
        draw.timingFunction = CAMediaTimingFunction(controlPoints: c.0, c.1, c.2, c.3)
        draw.beginTime = start + delay
        // backwards covers the delay gap; the model value stays fully drawn, so a
        // dropped animation fails visible, not blank.
        draw.fillMode = .backwards
        stroke.add(draw, forKey: "draw")
    }

    private func animateBreathe(_ wrapper: CALayer, delay: CFTimeInterval) {
        guard !reduceMotion else { return }
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 1
        breathe.toValue = ArcMotion.breatheScale
        breathe.duration = ArcMotion.breatheDuration
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.beginTime = start + delay
        wrapper.add(breathe, forKey: "breathe")
    }

    private func animateWave(_ wrapper: CALayer, delay: CFTimeInterval) {
        guard !reduceMotion else { return }
        let wave = CAKeyframeAnimation(keyPath: "transform.translation.y")
        wave.values = [0, ArcMotion.waveLift, 0]
        wave.keyTimes = [0, 0.5, 1]
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        wave.timingFunctions = [ease, ease]
        wave.duration = ArcMotion.waveDuration
        wave.repeatCount = .infinity
        wave.beginTime = start + delay
        wrapper.add(wave, forKey: "wave")
    }
}

import AppKit

// Draws one attributed line with macOS font smoothing. CATextLayer renders thinner
// than WebKit did on a transparent window, because it turns smoothing off for
// non-opaque backgrounds.
final class TextLayer: CALayer {
    var text = NSAttributedString() {
        didSet { if text != oldValue { setNeedsDisplay() } }
    }

    // Where the line's top-left is drawn inside the layer. Lets a caller keep the
    // layer on the pixel grid while the baseline lands at a fractional offset.
    var origin = CGPoint.zero {
        didSet { if origin != oldValue { setNeedsDisplay() } }
    }

    // SketchyBar draws with smoothing off (its font_smoothing default), which is
    // lighter than the widgets' WebKit-matched weight.
    var smoothsFonts = true {
        didSet { if smoothsFonts != oldValue { setNeedsDisplay() } }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? TextLayer {
            text = other.text
            origin = other.origin
            smoothsFonts = other.smoothsFonts
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(in ctx: CGContext) {
        ctx.setAllowsFontSmoothing(smoothsFonts)
        ctx.setShouldSmoothFonts(smoothsFonts)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: contentsAreFlipped())
        text.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }
}

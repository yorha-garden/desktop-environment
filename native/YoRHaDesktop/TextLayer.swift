import AppKit

// Draws one attributed line with macOS font smoothing. CATextLayer renders thinner
// than WebKit did on a transparent window, because it turns smoothing off for
// non-opaque backgrounds.
final class TextLayer: CALayer {
    var text = NSAttributedString() {
        didSet { if text != oldValue { setNeedsDisplay() } }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? TextLayer { text = other.text }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(in ctx: CGContext) {
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: contentsAreFlipped())
        text.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }
}

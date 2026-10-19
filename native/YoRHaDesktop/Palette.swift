import AppKit

// The theme.jsx tokens, verbatim. Light is the default; dark follows the
// effective macOS appearance exactly as `prefers-color-scheme: dark` did.

struct RGBA: Equatable {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF), alpha)
    }

    func withAlpha(_ alpha: CGFloat) -> RGBA { RGBA(r, g, b, alpha) }

    var cgColor: CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

enum Mode: String {
    case light, dark
}

func resolveMode(for appearance: NSAppearance) -> Mode {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
}

struct Palette: Equatable {
    let field: RGBA
    let text: RGBA
    let value: RGBA
    let panel: RGBA
    let ornament: RGBA
    let track: RGBA
    let accent: RGBA
    let alert: RGBA
    // beam.jsx: --yorha-beam-rgb / --yorha-beam-surface-rgb
    let beam: RGBA
    let beamSurface: RGBA

    static let light = Palette(
        field: RGBA(hex: 0xCAC5B0),
        text: RGBA(hex: 0x4A4741),
        value: RGBA(hex: 0x4A4741),
        panel: RGBA(214, 210, 193, 0.5),
        ornament: RGBA(hex: 0x4A4741),
        track: RGBA(74, 71, 65, 0.18),
        accent: RGBA(hex: 0xBC9A5A),
        alert: RGBA(hex: 0xBB3B36),
        beam: RGBA(74, 71, 65),
        beamSurface: RGBA(214, 210, 193)
    )

    static let dark = Palette(
        field: RGBA(hex: 0x16161A),
        text: RGBA(hex: 0xD8D4C4),
        value: RGBA(hex: 0xEFEBDB),
        panel: RGBA(58, 58, 64, 0.72),
        ornament: RGBA(hex: 0x6E7B8B),
        track: RGBA(216, 212, 196, 0.18),
        accent: RGBA(hex: 0xBC9A5A),
        alert: RGBA(hex: 0xBB3B36),
        beam: RGBA(110, 123, 139),
        beamSurface: RGBA(58, 58, 64)
    )

    static func forMode(_ mode: Mode) -> Palette {
        mode == .dark ? .dark : .light
    }

    // Every widget eased colour changes over 200 ms.
    static let transitionDuration: CFTimeInterval = 0.2
}

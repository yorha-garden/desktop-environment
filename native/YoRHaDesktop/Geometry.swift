import CoreGraphics
import QuartzCore

// Pure layout and timing, ported from beam.jsx and arcs.jsx. All coordinates are
// top-left origin, y down (the root layer is geometry-flipped to match CSS).

enum BeamGeometry {
    // .beam { height: 14vh } swept by translateY(-16vh) -> translateY(102vh)
    static let bandFraction: CGFloat = 0.14
    static let startFraction: CGFloat = -0.16
    static let endFraction: CGFloat = 1.02
    static let duration: CFTimeInterval = 11

    // linear-gradient(to bottom, beam 0, beam .05 @45%, surface .07 @55%, beam 0)
    static let locations: [NSNumber] = [0, 0.45, 0.55, 1]

    static func bandHeight(screenHeight h: CGFloat) -> CGFloat { h * bandFraction }

    static func travel(screenHeight h: CGFloat) -> (from: CGFloat, to: CGFloat) {
        (h * startFraction, h * endFraction)
    }

    static func colors(_ p: Palette) -> [CGColor] {
        [p.beam.withAlpha(0).cgColor,
         p.beam.withAlpha(0.05).cgColor,
         p.beamSurface.withAlpha(0.07).cgColor,
         p.beam.withAlpha(0).cgColor]
    }
}

enum ArcGeometry {
    // CircleLine box and its two nested quarter-arcs, verbatim from the portfolio.
    static let arcBox = CGSize(width: 428, height: 432)
    // ThreeLine box and its three parallel 45° diagonals.
    static let linesBox = CGSize(width: 707, height: 714)
    // .arc-lines-br { bottom: -64px; right: -96px }
    static let linesBottomRightOverhang = CGSize(width: 96, height: 64)

    static let strokeOpacity: CGFloat = 0.3
    static let strokeWidth: CGFloat = 2

    static let lines: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 0.353803, y: -0.353303), CGPoint(x: 707.354, y: 707.647)),
        (CGPoint(x: 34.3541, y: 86.647), CGPoint(x: 659.354, y: 713.647)),
        (CGPoint(x: 143.354, y: 86.6468), CGPoint(x: 707.354, y: 651.647)),
    ]

    // P1: M427.112 0 C436.64 210.577 247.658 431 .017 431
    // P2: M413.878 0 C423.112 204.353 239.978 418.261 0 418.261
    static func arcPaths() -> [CGPath] {
        let p1 = CGMutablePath()
        p1.move(to: CGPoint(x: 427.112, y: 0))
        p1.addCurve(to: CGPoint(x: 0.017, y: 431),
                    control1: CGPoint(x: 436.64, y: 210.577),
                    control2: CGPoint(x: 247.658, y: 431))
        let p2 = CGMutablePath()
        p2.move(to: CGPoint(x: 413.878, y: 0))
        p2.addCurve(to: CGPoint(x: 0, y: 418.261),
                    control1: CGPoint(x: 423.112, y: 204.353),
                    control2: CGPoint(x: 239.978, y: 418.261))
        return [p1, p2]
    }

    static func linePath(_ index: Int) -> CGPath {
        let path = CGMutablePath()
        path.move(to: lines[index].0)
        path.addLine(to: lines[index].1)
        return path
    }

    // .arc-tl { top:0; left:0 }  .arc-br { bottom:0; right:0; rotate(180deg) }
    static func arcCornerFrames(in screen: CGSize) -> (topLeft: CGRect, bottomRight: CGRect) {
        (CGRect(origin: .zero, size: arcBox),
         CGRect(x: screen.width - arcBox.width, y: screen.height - arcBox.height,
                width: arcBox.width, height: arcBox.height))
    }

    static func lineCornerFrames(in screen: CGSize) -> (topLeft: CGRect, bottomRight: CGRect) {
        (CGRect(origin: .zero, size: linesBox),
         CGRect(x: screen.width - linesBox.width + linesBottomRightOverhang.width,
                y: screen.height - linesBox.height + linesBottomRightOverhang.height,
                width: linesBox.width, height: linesBox.height))
    }
}

enum ArcMotion {
    // draw-on: dashoffset 100 -> 0, 1.5s cubic-bezier(0.22, 1, 0.36, 1)
    static let drawDuration: CFTimeInterval = 1.5
    static let drawCurve: (Float, Float, Float, Float) = (0.22, 1, 0.36, 1)
    // breathing: scale 1 <-> 1.1, 3s ease-in-out, alternate, infinite
    static let breatheDuration: CFTimeInterval = 3
    static let breatheScale: CGFloat = 1.1
    static let arcDelays: [CFTimeInterval] = [0, 0.5]
    // wave: translateY 0 -> -10 -> 0, 4s ease-in-out, infinite
    static let waveDuration: CFTimeInterval = 4
    static let waveLift: CGFloat = -10
    static let lineDelays: [CFTimeInterval] = [0, 0.2, 0.4]
}

import AppKit

// Pure palette, geometry, and timing checks for YoRHa Desktop. Compiled with
// every native/YoRHaDesktop source except main.swift.
@main struct DesktopTests {
    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-6 }
    static func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        near(a.origin, b.origin) && near(a.width, b.width) && near(a.height, b.height)
    }

    static func main() {
        // theme.jsx tokens
        precondition(Palette.forMode(.light) == .light)
        precondition(Palette.forMode(.dark) == .dark)
        precondition(Palette.light.ornament == RGBA(74, 71, 65))
        precondition(Palette.dark.ornament == RGBA(110, 123, 139))
        precondition(Palette.dark.value == RGBA(239, 235, 219))
        precondition(Palette.light.panel == RGBA(214, 210, 193, 0.5))
        precondition(Palette.dark.beamSurface == RGBA(58, 58, 64))
        precondition(near(Palette.transitionDuration, 0.2))
        precondition(resolveMode(for: NSAppearance(named: .darkAqua)!) == .dark)
        precondition(resolveMode(for: NSAppearance(named: .aqua)!) == .light)

        // beam.jsx: 14vh band, -16vh -> 102vh, 11s
        precondition(near(BeamGeometry.bandHeight(screenHeight: 1000), 140))
        let travel = BeamGeometry.travel(screenHeight: 1000)
        precondition(near(travel.from, -160) && near(travel.to, 1020))
        precondition(BeamGeometry.duration == 11)
        precondition(BeamGeometry.locations == [0, 0.45, 0.55, 1])
        precondition(BeamGeometry.colors(.light).map(\.alpha) == [0, 0.05, 0.07, 0])

        // arcs.jsx corner placement on a 1710x1112 screen
        let screen = CGSize(width: 1710, height: 1112)
        let arcs = ArcGeometry.arcCornerFrames(in: screen)
        precondition(near(arcs.topLeft, CGRect(x: 0, y: 0, width: 428, height: 432)))
        precondition(near(arcs.bottomRight, CGRect(x: 1282, y: 680, width: 428, height: 432)))
        let lines = ArcGeometry.lineCornerFrames(in: screen)
        precondition(near(lines.topLeft, CGRect(x: 0, y: 0, width: 707, height: 714)))
        // bottom: -64px; right: -96px
        precondition(near(lines.bottomRight, CGRect(x: 1099, y: 462, width: 707, height: 714)))

        // verbatim SVG endpoints
        let paths = ArcGeometry.arcPaths()
        precondition(paths.count == 2)
        precondition(near(paths[0].currentPoint, CGPoint(x: 0.017, y: 431)))
        precondition(near(paths[1].currentPoint, CGPoint(x: 0, y: 418.261)))
        precondition(near(ArcGeometry.linePath(2).currentPoint, CGPoint(x: 707.354, y: 651.647)))
        precondition(near(ArcGeometry.strokeOpacity, 0.3) && near(ArcGeometry.strokeWidth, 2))

        // motion parameters
        precondition(ArcMotion.drawDuration == 1.5)
        precondition(ArcMotion.drawCurve == (0.22, 1, 0.36, 1))
        precondition(ArcMotion.breatheDuration == 3 && near(ArcMotion.breatheScale, 1.1))
        precondition(ArcMotion.arcDelays == [0, 0.5])
        precondition(ArcMotion.waveDuration == 4 && near(ArcMotion.waveLift, -10))
        precondition(ArcMotion.lineDelays == [0, 0.2, 0.4])

        print("desktop tests passed")
    }
}

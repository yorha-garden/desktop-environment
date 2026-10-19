import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // `--appearance light|dark` pins the palette, for side-by-side visual checks.
    private let forcedMode: Mode?
    private var windows: [DesktopWindow] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var mode: Mode = .light

    init(arguments: [String]) {
        if let i = arguments.firstIndex(of: "--appearance"), i + 1 < arguments.count {
            forcedMode = Mode(rawValue: arguments[i + 1])
        } else {
            forcedMode = nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mode = currentMode()
        buildWindows()

        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.appearanceDidChange() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(rebuild),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    private func currentMode() -> Mode {
        forcedMode ?? resolveMode(for: NSApp.effectiveAppearance)
    }

    private func appearanceDidChange() {
        let next = currentMode()
        guard next != mode else { return }
        mode = next
        let palette = Palette.forMode(mode)
        windows.forEach { $0.scene.apply(palette, animated: true) }
    }

    // Screens changed or reduced motion toggled: start over. Entrance animations
    // replay, which matches Übersicht reloading its widgets in the same cases.
    @objc private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        buildWindows()
    }

    private func buildWindows() {
        let palette = Palette.forMode(mode)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for screen in NSScreen.screens {
            let window = DesktopWindow(screen: screen, palette: palette, reduceMotion: reduceMotion)
            window.orderFront(nil)
            windows.append(window)
        }
    }
}

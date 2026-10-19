import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // `--appearance light|dark` pins the palette, for side-by-side visual checks.
    private let forcedMode: Mode?
    private var windows: [DesktopWindow] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var mode: Mode = .light
    private let clock = TelemetryClock()
    private let pod = PodFeed()

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
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(rebuild),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil)

        clock.onTick = { [weak self] telemetry, rate in
            self?.windows.forEach { $0.scene.update(telemetry, rate: rate) }
        }
        clock.start()

        pod.onMessage = { [weak self] message, live in
            self?.windows.forEach { $0.scene.show(podMessage: message, live: live) }
        }
        pod.start()
    }

    @objc private func screensDidSleep() {
        clock.stop()
        pod.stop()
    }

    @objc private func screensDidWake() {
        clock.start()
        pod.start()
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
            if let current = pod.current {
                window.scene.show(podMessage: current.message, live: current.live)
            }
            window.orderFront(nil)
            windows.append(window)
        }
    }
}

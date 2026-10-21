import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // `--appearance light|dark` pins the palette, for side-by-side visual checks.
    private let forcedMode: Mode?
    private var windows: [DesktopWindow] = []
    private var bars: [BarWindow] = []
    private var barEntered = false
    private var appearanceObservation: NSKeyValueObservation?
    private var mode: Mode = .light
    private let clock = TelemetryClock()
    private let pod = PodFeed()
    private let minute = MinuteClock()

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
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(
            self, selector: #selector(clockDidChange),
            name: .NSSystemClockDidChange, object: nil)
        center.addObserver(
            self, selector: #selector(clockDidChange),
            name: .NSSystemTimeZoneDidChange, object: nil)
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

        minute.onTick = { [weak self] now in
            self?.bars.forEach { $0.bar.show(now) }
        }
        minute.start()
    }

    @objc private func screensDidSleep() {
        clock.stop()
        pod.stop()
        minute.stop()
    }

    @objc private func screensDidWake() {
        clock.start()
        pod.start()
        minute.start()
    }

    @objc private func clockDidChange() {
        NSTimeZone.resetSystemTimeZone()
        minute.refresh()
    }

    private func currentMode() -> Mode {
        forcedMode ?? resolveMode(for: NSApp.effectiveAppearance)
    }

    private func appearanceDidChange() {
        let next = currentMode()
        guard next != mode else { return }
        mode = next
        let palette = Palette.forMode(mode)
        Palette.transition(animated: true) {
            windows.forEach { $0.scene.apply(palette) }
            bars.forEach { $0.bar.apply(palette) }
        }
    }

    // Screens changed or reduced motion toggled: start over. Desktop entrance
    // animations replay, which matches Übersicht reloading its widgets in the same
    // cases. The bar slides in only once per launch, as SketchyBar did once per boot.
    @objc private func rebuild() {
        (windows as [NSWindow] + bars).forEach { $0.orderOut(nil) }
        windows.removeAll()
        bars.removeAll()
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

            let bar = BarWindow(screen: screen, palette: palette, reduceMotion: reduceMotion,
                                entrance: !barEntered)
            bar.bar.show(Date())
            bar.orderFront(nil)
            bars.append(bar)
        }
        barEntered = true
    }
}

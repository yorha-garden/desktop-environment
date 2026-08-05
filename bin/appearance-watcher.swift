import AppKit
import Foundation

func resolveAppearance(style: String?) -> String {
    style == "Dark" ? "dark" : "light"
}

func coordinatorArguments(mode: String) -> [String] {
    [mode]
}

func runCoordinator(path: String, mode: String) {
    guard path.hasPrefix("/") else {
        fputs("appearance watcher: coordinator path must be absolute\n", stderr)
        return
    }

    let coordinatorURL = URL(fileURLWithPath: path)
    guard FileManager.default.isExecutableFile(atPath: coordinatorURL.path) else {
        fputs("appearance watcher: coordinator is not executable: \(path)\n", stderr)
        return
    }

    let process = Process()
    process.executableURL = coordinatorURL
    process.arguments = coordinatorArguments(mode: mode)
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            fputs("appearance watcher: coordinator exited \(process.terminationStatus)\n", stderr)
        }
    } catch {
        fputs("appearance watcher: coordinator failed: \(error)\n", stderr)
    }
}

final class AppearanceWatcher {
    private let styleProvider: () -> String?
    private let applyMode: (String) -> Void
    private let coordinatorQueue: DispatchQueue
    private var themeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pendingApply: DispatchWorkItem?

    init(coordinatorPath: String) {
        coordinatorQueue = DispatchQueue(
            label: "com.yorha.appearance-watcher.coordinator",
            qos: .utility
        )
        styleProvider = {
            UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        }
        applyMode = { [coordinatorPath] mode in
            runCoordinator(path: coordinatorPath, mode: mode)
        }
        installObservers()
    }

    #if TESTING
    init(
        coordinatorPath: String,
        styleProvider: @escaping () -> String?,
        applyMode: @escaping (String) -> Void
    ) {
        _ = coordinatorPath
        coordinatorQueue = DispatchQueue(
            label: "com.yorha.appearance-watcher.coordinator.testing"
        )
        self.styleProvider = styleProvider
        self.applyMode = applyMode
        installObservers()
    }

    func applyStartupForTesting() {
        scheduleApply(after: 0)
    }

    func appearanceDidChangeForTesting() {
        scheduleApply(after: 0.15)
    }

    func didWakeForTesting() {
        scheduleApply(after: 0)
    }
    #endif

    private func installObservers() {
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleApply(after: 0.15)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleApply(after: 0)
        }
    }

    deinit {
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func scheduleApply(after delay: TimeInterval) {
        pendingApply?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.applyCurrentAppearance()
        }
        pendingApply = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func applyCurrentAppearance() {
        pendingApply = nil
        let mode = resolveAppearance(style: styleProvider())
        let applyMode = self.applyMode
        coordinatorQueue.async {
            applyMode(mode)
        }
    }
}

#if !TESTING
private final class AppearanceWatcherMain {
    private let watcher: AppearanceWatcher

    init() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            fputs("usage: \(arguments[0]) <absolute-coordinator-path>\n", stderr)
            exit(64)
        }

        let coordinatorPath = arguments[1]
        guard coordinatorPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: coordinatorPath) else {
            fputs("appearance watcher: coordinator must be an executable absolute path\n", stderr)
            exit(64)
        }

        NSApplication.shared.setActivationPolicy(.prohibited)
        watcher = AppearanceWatcher(coordinatorPath: coordinatorPath)
        watcher.scheduleApply(after: 0)
        RunLoop.main.run()
    }
}

private let appearanceWatcherMain = AppearanceWatcherMain()
#endif

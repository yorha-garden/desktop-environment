import Foundation

@main struct AppearanceWatcherBehaviorTests {
    static func wait(
        _ timeout: TimeInterval,
        until condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    static func main() {
        var appliedModes: [String] = []
        let watcher = AppearanceWatcher(
            coordinatorPath: "/unused",
            styleProvider: { "Dark" },
            applyMode: { appliedModes.append($0) }
        )

        watcher.applyStartupForTesting()
        precondition(wait(0.08) { appliedModes == ["dark"] })

        appliedModes.removeAll()
        watcher.appearanceDidChangeForTesting()
        watcher.appearanceDidChangeForTesting()
        watcher.appearanceDidChangeForTesting()
        precondition(!wait(0.08) { !appliedModes.isEmpty })
        precondition(wait(0.35) { appliedModes == ["dark"] })

        appliedModes.removeAll()
        watcher.didWakeForTesting()
        precondition(wait(0.08) { appliedModes == ["dark"] })

        print("appearance watcher behavior tests passed")
    }
}

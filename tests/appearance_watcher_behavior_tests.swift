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

        let overlapLock = NSLock()
        let releaseFirst = DispatchSemaphore(value: 0)
        var overlapStyle: String? = "Dark"
        var overlapEvents: [String] = []
        var finalMode: String?
        var firstDidStart = false
        let overlapWatcher = AppearanceWatcher(
            coordinatorPath: "/unused",
            styleProvider: {
                overlapLock.lock()
                defer { overlapLock.unlock() }
                return overlapStyle
            },
            applyMode: { mode in
                overlapLock.lock()
                overlapEvents.append("start:\(mode)")
                if mode == "dark" { firstDidStart = true }
                overlapLock.unlock()
                if mode == "dark" {
                    releaseFirst.wait()
                }
                overlapLock.lock()
                overlapEvents.append("finish:\(mode)")
                finalMode = mode
                overlapLock.unlock()
            }
        )

        overlapWatcher.applyStartupForTesting()
        precondition(wait(0.2) {
            overlapLock.lock()
            defer { overlapLock.unlock() }
            return firstDidStart
        })
        overlapLock.lock()
        overlapStyle = nil
        overlapLock.unlock()
        overlapWatcher.didWakeForTesting()
        precondition(!wait(0.08) {
            overlapLock.lock()
            defer { overlapLock.unlock() }
            return overlapEvents.count > 1
        })
        releaseFirst.signal()
        precondition(wait(0.3) {
            overlapLock.lock()
            defer { overlapLock.unlock() }
            return overlapEvents == [
                "start:dark", "finish:dark", "start:light", "finish:light",
            ] && finalMode == "light"
        })

        print("appearance watcher behavior tests passed")
    }
}

import Foundation

@main struct AppearanceWatcherTests {
    static func main() {
        precondition(resolveAppearance(style: "Dark") == "dark")
        precondition(resolveAppearance(style: nil) == "light")
        precondition(resolveAppearance(style: "Light") == "light")
        precondition(coordinatorArguments(mode: "dark") == ["dark"])
        print("appearance watcher tests passed")
    }
}

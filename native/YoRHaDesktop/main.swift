import AppKit

// YoRHa Desktop — the native replacement for the Übersicht widget layer.
// Accessory policy: no Dock icon, no menu bar, never takes focus.
let app = NSApplication.shared
let delegate = AppDelegate(arguments: CommandLine.arguments)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

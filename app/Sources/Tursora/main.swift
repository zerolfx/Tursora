import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Explicit so the app behaves the same whether launched from the .app bundle
// or straight from `swift run` during development.
app.setActivationPolicy(.regular)
app.run()

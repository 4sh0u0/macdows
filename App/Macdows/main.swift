import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
MainMenu.install(on: app)
app.run()

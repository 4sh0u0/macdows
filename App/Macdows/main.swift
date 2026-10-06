import AppKit

// ADR-0024 D-8 (F-3): before anything can create WinPR's root logger, so no WinPR logging variable in
// this process's environment can redirect FreeRDP's log to a file or the network, or raise a tag
// to the DEBUG level that prints account names.
// A failure is one value-free line on stderr (gate r1 m-14): the variables are cleared before the
// root logger exists either way; what failed is setting its appender / level through the API.
if !CRSession.pinProcessLogConfiguration() {
	fputs("[log] WinPR root logger configuration failed; FreeRDP logging keeps WinPR's defaults\n", stderr)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
MainMenu.install(on: app)
app.run()

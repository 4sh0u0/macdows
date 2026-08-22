import AppKit

// M1 (W4b review): explicit @MainActor, matching App/RemoteWindowRendering's own classes --
// without it, none of this class's methods (connectTapped, a button target-action; drainTick,
// a Timer callback) are statically known to run on the MainActor even though both always do
// in practice (AppKit target-actions and this app's own Timer usage are both main-thread by
// construction), so every AppKit property they touch (statusLabel.stringValue,
// connectButton.isEnabled, ...) was a "main actor-isolated property can not be mutated from a
// nonisolated context" warning under Swift 6's mandatory strict concurrency checking.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private var window: NSWindow!
	private var statusLabel: NSTextField!
	private var connectButton: NSButton!

	// Not started automatically: the app bundle has its own, separate TCC identity from
	// a Terminal.app-relayed CLI process (Tools/bridge-smoke, W4a's actual verification
	// vehicle), so the *first* local-network connection attempt from this app pops a
	// permission dialog nobody can answer while unattended. This drain exists so a human
	// can manually kick off + observe a real connection later (e.g. the morning after an
	// overnight W4a run), without blocking W4a's own acceptance criteria, which
	// bridge-smoke already satisfies independently.
	private var session: CRSession?
	private var registry: RemoteWindowRegistry?
	private var drainTimer: Timer?
	private var eventCount: Int = 0

	func applicationDidFinishLaunching(_ notification: Notification) {
		// Proves the Swift app actually links through CRBridge into the vendored
		// FreeRDP dylibs — check Console.app / stderr for the logged version string.
		CRSession.logFreeRDPVersion()

		let contentRect = NSRect(x: 0, y: 0, width: 640, height: 400)
		let newWindow = NSWindow(
			contentRect: contentRect,
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		newWindow.title = "Macdows"
		newWindow.center()

		let label = NSTextField(labelWithString: "Macdows scaffold")
		label.font = .systemFont(ofSize: 20, weight: .medium)
		label.alignment = .center
		label.translatesAutoresizingMaskIntoConstraints = false

		let status = NSTextField(labelWithString: "Not connected. Reads ~/.config/macdows/host.env.")
		status.font = .systemFont(ofSize: 13)
		status.textColor = .secondaryLabelColor
		status.alignment = .center
		status.maximumNumberOfLines = 0 // now shows a second line (remote window count)
		status.translatesAutoresizingMaskIntoConstraints = false
		statusLabel = status

		let button = NSButton(title: "Connect (manual, real host)", target: self, action: #selector(connectTapped))
		button.translatesAutoresizingMaskIntoConstraints = false
		connectButton = button

		let stack = NSStackView(views: [label, status, button])
		stack.orientation = .vertical
		stack.spacing = 16
		stack.alignment = .centerX
		stack.translatesAutoresizingMaskIntoConstraints = false

		let contentView = NSView(frame: contentRect)
		contentView.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
		])
		newWindow.contentView = contentView

		window = newWindow
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	@objc private func connectTapped() {
		guard session == nil else {
			statusLabel.stringValue = "Already connecting/connected."
			return
		}

		guard let env = try? String(contentsOfFile: NSHomeDirectory() + "/.config/macdows/host.env", encoding: .utf8) else {
			statusLabel.stringValue = "Could not read ~/.config/macdows/host.env"
			return
		}
		var values: [String: String] = [:]
		for line in env.split(separator: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
			values[String(trimmed[trimmed.startIndex..<eq])] = String(trimmed[trimmed.index(after: eq)...])
		}
		guard let host = values["WIN_HOST"], let user = values["WIN_USER"], let pass = values["WIN_PASS"],
			!host.isEmpty, !user.isEmpty, !pass.isEmpty
		else {
			statusLabel.stringValue = "host.env missing WIN_HOST/WIN_USER/WIN_PASS"
			return
		}

		let newSession = CRSession(host: host, user: user, password: pass, program: "C:\\Windows\\System32\\winver.exe")
		// Size the remote desktop to the primary screen -- same NSScreen the registry's
		// coordinate mapping anchors on. Without this the server clamps remote windows to
		// FreeRDP's 1024x768 default desktop (an invisible drag wall mid-screen, and
		// position desync that breaks clicks after a drag; see CRSession.desktopWidth).
		if let screen = NSScreen.screens.first {
			newSession.desktopWidth = UInt32(max(0, screen.frame.width))
			newSession.desktopHeight = UInt32(max(0, screen.frame.height))
		}
		session = newSession
		registry = RemoteWindowRegistry(session: newSession)
		eventCount = 0
		statusLabel.stringValue = "Connecting..."
		connectButton.isEnabled = false

		// W4c review: push-style draining, replacing what used to be this timer's only
		// job. A user-reported "everything feels laggy, ~5 FPS" bug root-caused to this
		// exact 0.2s poll interval: with a fixed-interval Timer as the *only* way drainTick
		// ever runs, the average wait before a ready frame's next drain is ~half the
		// interval (~100ms for 0.2s), and 1000ms / 200ms lands exactly on the observed ~5
		// FPS ceiling -- not a render-pipeline slowness, a polling-interval one.
		// CRSession.onEventsAvailable fires (already hopped to the main queue internally,
		// coalesced "at most once per drain cycle") the moment new control-lane events
		// (including FRAME_READY) are actually posted, so drainTick now runs promptly
		// instead of waiting out whatever fraction of the poll interval remained.
		newSession.onEventsAvailable = { [weak self] in
			MainActor.assumeIsolated {
				self?.drainTick()
			}
		}
		newSession.start()

		// Kept, but no longer the drain trigger -- this is now purely a slow backstop for
		// -lastConnectError, which (per that property's own doc comment) can be set with
		// zero control-lane events ever having been posted at all (e.g. a DNS/TCP/TLS/NLA
		// failure before any protocol traffic occurs), so onEventsAvailable's push above
		// would never fire for that specific failure mode on its own. 1.0s, not 0.2s: a
		// connection failure surfacing up to a second late is imperceptible to a human;
		// this interval no longer gates frame latency the way it used to. M1's
		// assumeIsolated reasoning (below) still applies unchanged.
		drainTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.drainTick()
			}
		}
	}

	private func drainTick() {
		guard let session else { return }
		if let error = session.lastConnectError {
			statusLabel.stringValue = "Connect failed: \(error.localizedDescription)"
			drainTimer?.invalidate()
			drainTimer = nil
			connectButton.isEnabled = true
			return
		}
		// Mirrors Tools/window-smoke/main.swift's own tick() exactly: every drained event
		// (control-lane orders and the FRAME_READY doorbell alike) goes straight to the
		// registry, which handles FRAME_READY internally (copyPublishedSurface -> present)
		// -- there's no separate frame-lane consumption call needed at this layer.
		let delivered = session.drainEvents { [weak self] event in
			self?.eventCount += 1
			self?.registry?.handle(event)
		}
		if delivered > 0 || eventCount > 0 {
			let windowCount = registry?.windowSnapshots().count ?? 0
			statusLabel.stringValue = """
				Connected — \(eventCount) event(s) so far (generation \(session.currentGeneration))
				\(windowCount) remote window(s) live
				"""
		}
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}

	func applicationWillTerminate(_ notification: Notification) {
		drainTimer?.invalidate()
		session?.shutdownAndWait()
	}
}

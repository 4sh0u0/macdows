import AppKit
import MacdowsCore

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
	/// True between the Connect press and the boundary gate's verdict. `session` is still nil
	/// across that window, so it cannot serve as the "already busy" flag on its own.
	private var isCheckingBoundary = false

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
		// `isCheckingBoundary` as well as `session`: the boundary check below is asynchronous,
		// and during its window `session` is still nil, so this guard alone would let a second
		// press start a second check. The button is disabled synchronously before the Task for
		// the same reason (AppKit delivers actions serially on the main actor, so a disable that
		// happens before this method returns cannot be raced).
		guard session == nil, !isCheckingBoundary else {
			statusLabel.stringValue = "Already connecting/connected."
			return
		}

		// MacdowsCore.EnvFile, not the inline loop this method used to carry. That loop keyed
		// each line on everything left of the first `=`, so the ordinary line
		// `export WIN_HOST=x` was filed under the key "export WIN_HOST" and was invisible to
		// the lookup right below it -- and it stripped no quotes, so `WIN_HOST="x"` dialled a
		// host whose name included the quote characters. Both defects were duplicated verbatim
		// in Tools/window-smoke, and both disagreed with the rules
		// Scripts/run-window-smoke.command applies to the same file; EnvFile's own doc comment
		// records how that disagreement was measured fail-open. One parser now, in the package
		// that has a test bundle (this target has none).
		//
		// MacdowsPaths.hostEnvPath() rather than a local `NSHomeDirectory()` concatenation, for
		// the same reason: LabBoundary locates its own boundary file through $HOME, so the two
		// halves of the gate a few lines below -- the host, and the segments it is judged
		// against -- used to be able to come out of two different homes when HOME is redirected.
		// One resolver now decides both (see MacdowsPaths for the reconciled order and why).
		// In the default environment the path is byte-identical to the one this line built
		// before, so nothing about a normal launch changes.
		//
		// This method deliberately does NOT take the WIN_HOST/WIN_USER/WIN_PASS environment
		// variables into account, unlike the two command-line harnesses (which get them from
		// Scripts/run-window-smoke.command, the whole point of the precedence there). This is a
		// GUI app: it is launched by Finder, by Xcode's Run button or by `open`, none of which
		// is a place a maintainer sets a variable on purpose, and honouring one would add a way
		// to change which host a button press dials that is invisible in the window the human
		// is looking at. host.env is the app's single source, the status label says so, and
		// EnvFile.value(forKey:in:environment:) is deliberately not called here.
		let values: [String: String]
		do {
			values = try EnvFile.parse(path: MacdowsPaths.hostEnvPath())
		} catch {
			statusLabel.stringValue = "Could not read ~/.config/macdows/host.env"
			return
		}
		guard let host = values["WIN_HOST"], let user = values["WIN_USER"], let pass = values["WIN_PASS"],
			!host.isEmpty, !user.isEmpty, !pass.isEmpty
		else {
			statusLabel.stringValue = "host.env missing WIN_HOST/WIN_USER/WIN_PASS"
			return
		}

		// Live-host testing boundary gate (owner rule, 2026-08-31), the in-process mirror of
		// Scripts/lib.sh's crdp_assert_lab_boundary. Pressing Connect used to build a CRSession
		// straight from host.env with nothing between the button and the socket -- the shell
		// gate can only guard steps that go through a shell, and this one never did.
		//
		// Unconditional, NOT #if DEBUG. This app is a developer harness today, and gating only
		// Debug builds would mean the one configuration a stray Release build runs in is the
		// ungated one. When the product shell replaces this scaffold it will have to revisit
		// this: a shipped Macdows obviously must connect to hosts that are not the maintainer's
		// own lab, so the gate belongs to the harness, not to the product, and removing it is a
		// deliberate act at that point rather than an omission now.
		//
		// The refusal line names the host (the operator typed it into host.env and is looking
		// at the label) and a reason category. It can never contain a boundary segment -- see
		// LabBoundary's doc comment, and the no-leak test that sweeps the whole refusal
		// vocabulary.
		//
		// Off the main actor, because the gate can block: a WIN_HOST that is a *name* rather
		// than a numeric literal sends LabBoundary into getaddrinfo, which is synchronous and
		// can take seconds (much longer for a dead .local). Running that on the main actor
		// would beachball the UI on the one press that is supposed to feel instant --
		// CRSession.start explicitly "returns immediately" and connects on its own thread, so
		// before this gate existed nothing on this path blocked at all, and it must stay that
		// way. A literal host short-circuits inside LabBoundary without touching the resolver,
		// so the maintainer's own host.env pays only a Task hop.
		//
		// Task.detached rather than a plain `nonisolated async` helper: whether a nonisolated
		// async function actually leaves the caller's actor is exactly what the
		// NonisolatedNonsendingByDefault upcoming feature changes, and this has to be off the
		// main actor under every language mode and feature set. The enclosing `Task {}` inherits
		// MainActor isolation, so everything after the await is back on the main actor and may
		// touch AppKit directly.
		isCheckingBoundary = true
		connectButton.isEnabled = false
		statusLabel.stringValue = "Checking the live-host boundary..."
		Task { [weak self] in
			let verdict = await Task.detached(priority: .userInitiated) {
				LabBoundary.check(host: host)
			}.value
			guard let self else { return }
			self.isCheckingBoundary = false
			switch verdict {
			case .allowed:
				self.beginSession(host: host, user: user, password: pass)
			case .refused(let refusal):
				self.statusLabel.stringValue = LabBoundary.refusalLine(host: host, refusal: refusal)
				self.connectButton.isEnabled = true
			}
		}
	}

	/// Everything `connectTapped` used to do inline once the credentials were in hand. Split out
	/// only so the boundary gate above can be awaited without nesting the whole method inside a
	/// closure; the body is unchanged, and it is only ever reached on an `.allowed` verdict.
	private func beginSession(host: String, user: String, password pass: String) {
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

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
	/// adr/0020 D-4 (K1): the scaffold's second button, which ends the current session. A button of
	/// its own beside Connect rather than one Connect that toggles: a double-click on a toggling
	/// button lands its second click on the opposite action. Named so that nothing in it spells
	/// `connectButton`, `connectTapped` or the teardown's name -- the pins on this file count those
	/// as substrings.
	private var endSessionButton: NSButton!

	// Not started automatically: the app bundle has its own, separate TCC identity from
	// a Terminal.app-relayed CLI process (Tools/bridge-smoke, W4a's actual verification
	// vehicle), so the *first* local-network connection attempt from this app pops a
	// permission dialog nobody can answer while unattended. This drain exists so a human
	// can manually kick off + observe a real connection later (e.g. the morning after an
	// overnight W4a run), without blocking W4a's own acceptance criteria, which
	// bridge-smoke already satisfies independently.
	private var session: CRSession? {
		// adr/0020 D-4 (K1): the End-session button is usable exactly while there is a session to
		// end, and this is the ONE statement that says so. A `didSet` covers both of this
		// property's assignments -- `beginSession`'s and the teardown's -- without adding a line to
		// either. `applyShell` is deliberately not the place: three of the four session ends never
		// call it after their teardown, and the give-up one calls it BEFORE its teardown, while this
		// property is still set. Every assignment happens after `applicationDidFinishLaunching` has
		// built the button.
		didSet { endSessionButton.isEnabled = session != nil }
	}
	private var registry: RemoteWindowRegistry?
	/// adr/0019 §2 lane D: the reconnect driver for the session above, armed in `beginSession` and
	/// dropped when this app stops having a session to reconnect. Per-connection, exactly like
	/// `session` and `registry`, and deliberately NOT app-resident: it holds the very `CRSession`
	/// it restarts, so a driver outliving that session would be armed against a connection nobody
	/// owns any more.
	private var reconnectDriver: ReconnectDriver?
	private var drainTimer: Timer?
	private var eventCount: Int = 0
	/// True between the Connect press and the boundary gate's verdict. `session` is still nil
	/// across that window, so it cannot serve as the "already busy" flag on its own.
	private var isCheckingBoundary = false

	/// M1/W1: the project's only `NSScreen` reader and the owner of the screen-parameter
	/// observer (adr/0015 §5.A.5). A `let` initialised with this delegate rather than something
	/// created in `applicationDidFinishLaunching`, because adr/0015 §5.A.1's answer to U8 is that
	/// the observer is **app-resident** -- registered once, never per connection, never torn down
	/// -- and a stored `let` is the shortest expression of that lifetime. Its callback is attached
	/// at launch, once the status label it writes into exists.
	private let displayTopology = DisplayTopologyProvider()

	/// The most recent screen-parameter change, kept only so `drainTick`'s status text does not
	/// overwrite it a second later. Text, nothing else: adr/0015 §5.A.3 forbids the observer's
	/// event from causing a reconnect, a resize or a desktop-size re-send, and this app honours
	/// that by having the event reach exactly one place -- a label.
	private var lastDisplayChangeNote: String?

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

		// adr/0020 D-4 (K1): NSButton starts out enabled, so the End-session button's initial state
		// is written here, as a literal -- there is no session at launch. After this line its only
		// writer is `session`'s `didSet`; spelling the initial value as that same predicate would
		// make it two.
		let endButton = NSButton(title: "Disconnect", target: self, action: #selector(endSessionTapped))
		endButton.translatesAutoresizingMaskIntoConstraints = false
		endButton.isEnabled = false
		endSessionButton = endButton

		let stack = NSStackView(views: [label, status, button, endButton])
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

		// M1/W1 deliverable 2: the screen-parameter observer's *observable* half. The provider
		// already logs every change (Console.app, category "DisplayTopology"); this puts the same
		// verdict where a human running the scaffold can see it, which matters because the state
		// worth seeing -- "this session's desktop size no longer matches the displays" -- only
		// exists while a session is up and the label is otherwise busy showing event counts.
		//
		// Attached here rather than in the provider's own initializer because it writes into
		// `statusLabel`, which is created a few lines above; the provider itself is constructed
		// with this delegate and is already observing by now, so a change that arrives before
		// this line is still logged and still updates `currentTopology` -- it just has no label
		// to write to yet.
		//
		// This closure is the complete list of what a display change does in this app: it sets a
		// string. No reconnect, no resize, no desktop-size re-send (adr/0015 §5.A.3).
		displayTopology.onScreenParametersChange = { [weak self] change in
			guard let self else { return }
			let note: String
			if change.currentTopologyIsEmpty {
				// adr/0015 §5.A.6: an empty screen list is a real, transient state (lock, sleep,
				// a display switching mode) and is reported, never folded into a 0x0 desktop.
				note = "Display change: no usable display right now."
			} else if change.sessionDesktopSize == nil {
				// No connect since launch (or since the last session ended), so there is no
				// negotiated size to be stale. Distinguishable precisely because the payload
				// carries the session's size (adr/0015 §5.A.2), so say so instead of reporting
				// "unaffected", which would imply a session exists.
				note = "Display change: no session yet -- the desktop size is taken at connect."
			} else if change.connectedDesktopSizeIsStale {
				note = "Display change: this session's desktop size is now out of date -- reconnect to re-negotiate."
			} else {
				note = "Display change: this session's desktop size is unaffected."
			}
			self.lastDisplayChangeNote = note
			self.statusLabel.stringValue = note
		}

		// adr/0019 §2 R-6 tool lane T1: the two unattended-launch knobs, both default OFF. With
		// neither variable exported -- which is every launch by Finder, by Xcode's Run button or
		// by `open` -- `plan` is `ShellAutolaunch.off`, both `if`s are not taken, and this app
		// finishes launching byte-for-byte as it did before this lane. See `ShellAutolaunch` for
		// why reading these two names is not the thing `connectTapped` refuses to do (that refusal
		// is about where a HOST comes from; neither knob names a host, an account or a credential).
		//
		// Read once, into one value, because the pin next door holds `ShellAutolaunch.plan(` to
		// exactly one occurrence in this file: two call sites could disagree about the same launch.
		let autolaunch = ShellAutolaunch.plan(environment: ProcessInfo.processInfo.environment)
		if autolaunch.autoconnect {
			// `connectTapped()` itself, never a copy of any step inside it: the host.env read, the
			// live-host boundary gate and the button/`isCheckingBoundary` interlock all have to run
			// exactly as they do for a human press, and the only way to guarantee that is to make
			// the press. `@objc private` is callable from inside this file, so no visibility changes.
			connectTapped()
		}
		if let quitAfter = autolaunch.quitAfterInterval {
			// `NSApp.terminate`, not `exit()` and not a SIGTERM from outside: terminate is the one
			// route that runs `applicationWillTerminate` below, and that method's detach ->
			// shutdownAndWait -> endSession sequence is part of what an unattended run has to
			// exercise. It doubles as the safety net -- a batch that dies leaves behind no app
			// still holding a live session.
			//
			// One-shot and deliberately unstored: there is nothing to cancel it for. The ceiling
			// applies to the process, not to a session, and an app that has already been asked to
			// stop by this timer is going away whatever a later session does.
			//
			// assumeIsolated for the same reason drainTimer's block does it (see below): the timer
			// is scheduled on, and fires on, the main run loop.
			_ = Timer.scheduledTimer(withTimeInterval: quitAfter, repeats: false) { _ in
				MainActor.assumeIsolated {
					NSApp.terminate(nil)
				}
			}
		}
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
		//
		// adr/0020 D-8 (#6): the host.env read and its three-key check run in that same detached
		// task, ahead of the gate, instead of on the main actor before it. The file is local and
		// small, but a HOME on a network mount can stall a read, and a stalled read on the main
		// actor is the beachball the paragraph above rules out. The price is that the two host.env
		// failures now arrive after the button has been disabled, so each of them -- like the
		// gate's refusal -- has to hand the button back: `isCheckingBoundary` is reset once, before
		// the verdict is read, whatever it is, and every failure arm re-enables Connect with a
		// literal `true`. Without that, one bad host.env would lock Connect for the life of the
		// process. The two failure lines are unchanged; the "Checking" line now also covers the
		// read, which is part of the same check.
		isCheckingBoundary = true
		connectButton.isEnabled = false
		statusLabel.stringValue = "Checking the live-host boundary..."
		Task { [weak self] in
			let preflight = await Task.detached(priority: .userInitiated) { () -> ConnectPreflight in
				// MacdowsCore.EnvFile, not the inline loop this method used to carry. That loop keyed
				// each line on everything left of the first `=`, so the ordinary line
				// `export WIN_HOST=x` was filed under the key "export WIN_HOST" and was invisible to
				// the lookup right below it -- and it stripped no quotes, so `WIN_HOST="x"` dialled a
				// host whose name included the quote characters. Both defects were duplicated verbatim
				// in Tools/window-smoke, and both disagreed with the rules
				// Scripts/run-window-smoke.command applies to the same file; EnvFile's own doc comment
				// records how that disagreement was measured fail-open. One parser now, in the package
				// whose tests run in every replay-gate pass (the app-side bundle, MacdowsAppTests,
				// arrived later -- D7, 2026-09-02 -- and does not change where a parser belongs).
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
					return .unreadable
				}
				guard let host = values["WIN_HOST"], let user = values["WIN_USER"], let pass = values["WIN_PASS"],
					!host.isEmpty, !user.isEmpty, !pass.isEmpty
				else {
					return .missingKeys
				}
				return .checked(host: host, user: user, password: pass, verdict: LabBoundary.check(host: host))
			}.value
			guard let self else { return }
			self.isCheckingBoundary = false
			switch preflight {
			case .unreadable:
				self.statusLabel.stringValue = "Could not read ~/.config/macdows/host.env"
				self.connectButton.isEnabled = true
			case .missingKeys:
				self.statusLabel.stringValue = "host.env missing WIN_HOST/WIN_USER/WIN_PASS"
				self.connectButton.isEnabled = true
			case .checked(let host, let user, let pass, .allowed):
				self.beginSession(host: host, user: user, password: pass)
			case .checked(let host, _, _, .refused(let refusal)):
				self.statusLabel.stringValue = LabBoundary.refusalLine(host: host, refusal: refusal)
				self.connectButton.isEnabled = true
			}
		}
	}

	/// adr/0020 D-8 (#6): everything the off-main half of a Connect press can come back with --
	/// host.env unreadable, host.env without all three keys, or the three values together with
	/// the live-host gate's verdict on the host. One value, so the main-actor half reads the
	/// whole outcome in one `switch` and cannot act on credentials without the verdict that goes
	/// with them.
	private enum ConnectPreflight: Sendable {
		case unreadable
		case missingKeys
		case checked(host: String, user: String, password: String, verdict: LabBoundary.Verdict)
	}

	/// Everything `connectTapped` used to do inline once the credentials were in hand. Split out
	/// only so the boundary gate above can be awaited without nesting the whole method inside a
	/// closure; the body is unchanged, and it is only ever reached on an `.allowed` verdict.
	private func beginSession(host: String, user: String, password pass: String) {
		let newSession = CRSession(host: host, user: user, password: pass, program: "C:\\Windows\\System32\\winver.exe")
		// Size the remote desktop to the UNION of the local screens, in remote pixels -- adr/0015
		// §3 rule 3's `desktopSizePx`, the only value allowed to reach desktopWidth/Height.
		// Without a desktop size at all the server clamps remote windows to FreeRDP's 1024x768
		// default (an invisible drag wall mid-screen, and position desync that breaks clicks
		// after a drag; see CRSession.desktopWidth). What changed in M1 is which number this is:
		// it used to be the primary screen's frame in *points* read straight off NSScreen, which
		// (a) ignored every screen but the first, leaving the charter's union constraint
		// (ARCHITECTURE.md:38, in force since Phase 1) unimplemented, and (b) carried no unit --
		// on the 1x hardware this project owns, points and remote pixels are the same number, so
		// the two were indistinguishable until the type made them different.
		//
		// freezeSessionSnapshot() is also the moment this session's topology is frozen (adr/0015
		// §5.A): the size returned here and the Y-flip anchor the registry uses come from one
		// NSScreen read, which is §5.A.4's invariant. A later display change is reported by the
		// observer and deliberately does NOT re-send anything (§5.A.3).
		//
		// nil means "no usable display" (headless, every display asleep, a mode switch in
		// flight). In that state we set NOTHING and let the connection proceed: adr/0015 §5.A.6
		// is explicit that 0x0 must never be sent, because CRSession.h:285-286 records that 0/0
		// is exactly what makes FreeRDP fall back to the 1024x768 desktop this line exists to
		// prevent. UInt32(clamping:) cannot actually clamp -- DisplayTopology guarantees
		// 0 < value <= maxExtentInRemotePixels (65535) -- and is written that way so that if that
		// guarantee is ever relaxed, the connect path degrades instead of trapping.
		if let desktop = displayTopology.freezeSessionSnapshot() {
			newSession.desktopWidth = UInt32(clamping: desktop.width)
			newSession.desktopHeight = UInt32(clamping: desktop.height)
		}
		// ADR-0018 U-1 (owner ruled D, 2026-09-08 13:28 JST; W3 lane H): advertise the product default
		// from the SAME frozen topology the desktop size came from. `productDefault` is MacdowsCore's one
		// statement of the ruling (2x -> DesktopScaleFactor 200 / DeviceScaleFactor 100; 1x -> 100/100,
		// wire-identical to the old behaviour); window-smoke's knob-unset path resolves through the same
		// function, so the fixture measures what ships. Both fields are assigned together -- CRSession
		// sets neither setting unless both are non-zero. No usable display -> nothing assigned.
		if let scale = displayTopology.sessionSnapshot?.rasterScale,
		   let advertised = ScaleAdvertisement.productDefault(rasterScale: scale) {
			newSession.advertisedDesktopScaleFactor = advertised.desktopScaleFactor
			newSession.advertisedDeviceScaleFactor = advertised.deviceScaleFactor
		}
		// A staleness verdict belongs to the session it was computed against, and the line above
		// just started a new one against a fresh snapshot.
		lastDisplayChangeNote = nil
		session = newSession
		// The registry is handed the session's FROZEN snapshot, not the live provider -- adr/0015
		// §5.A.4: within one session the Y-flip anchor and the desktop size must come from the
		// same topology read. freezeSessionSnapshot() above performed that read and derived the
		// size assigned to the CRSession from it; StaticDisplayTopologyProvider wraps the very
		// same value, so the registry structurally cannot observe a different layout than the one
		// the server was sized for. Handing over `displayTopology` itself would leave the
		// invariant resting on these two statements running in the same main-actor turn, and
		// would additionally let the registry's own re-take on a generation rollover pick up a
		// layout the (never re-sent, CRSession.h:284-286) desktop size no longer matches -- which
		// is exactly the divergence §5.A.4 forbids. Without any provider the registry cannot learn
		// about screens at all (its NSScreen read was removed in M1) and would decline to position
		// any window, warning once -- loud, but still broken.
		let newRegistry = RemoteWindowRegistry(
			session: newSession,
			topologyProvider: StaticDisplayTopologyProvider(displayTopology.sessionSnapshot)
		)
		registry = newRegistry
		// adr/0019 §2 lane D: arm the reconnect driver for THIS connection. Built here rather than
		// at launch because it is made out of the two objects the lines above just created, and
		// armed before `newSession.start()` below, so no event can be posted before there is an
		// armed driver to see it. Nothing else in this file constructs one.
		let driver = ReconnectDriver(session: newSession, registry: newRegistry)
		// adr/0015 §5.A.5 keeps every `NSScreen` read in this project inside `displayTopology`, so
		// the driver is handed a CLOSURE over this delegate's resident provider and never a
		// provider of its own. `ReconnectTopologyRefresh.refreeze` performs the connect-moment
		// re-take and RETURNS the snapshot provider the registry must read for the connection about
		// to begin; `prepareForReconnect(refreezingTopologyWith:)` installs it, which is what makes
		// "re-take, then tear the table down" a property of that method's call shape rather than an
		// order this closure would have to remember (adr/0019 §2 lane C).
		//
		// `[weak self]` is load-bearing: this delegate holds the driver, the driver holds this
		// closure, and a strong `self` would close that cycle. `unowned newSession` is safe for the
		// opposite reason -- the driver owns the session it restarts, so this closure cannot
		// outlive it, and the session holds no reference back to the driver.
		driver.topologyRefresh = { [weak self, unowned newSession] in
			guard let self else { return nil }
			return ReconnectTopologyRefresh.refreeze(session: newSession, topology: self.displayTopology)
		}
		driver.onStateChange = { [weak self] state in
			self?.applyReconnectState(state)
		}
		driver.attach()
		reconnectDriver = driver
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
			connectButton.isEnabled = true
			// The session-end lane (lane D impl-report §8 #1): this branch now ENDS the session
			// instead of only announcing that it failed. It used to stop the timer, re-enable the
			// button and drop the topology freeze but keep `session` -- and `connectTapped`'s first
			// guard is `session == nil`, so the button it had just enabled answered "Already
			// connecting/connected." to every press. `tearDownSession()` drops the session along
			// with everything else a session owns, so the button really starts a new connection.
			//
			// UI first, teardown second: the order the give-up path has too. The failure line and
			// the literal `true` are what lane D froze here that a human actually sees, and both are
			// kept; this branch stays the one place a connect ERROR re-enables the button.
			//
			// Still BEFORE the drain below, so the `.disconnected` that accompanies a bridge refusal
			// never reaches the driver on this path. The teardown disarms and drops the driver,
			// which is what keeps it from sitting in `.reconnecting` for ever, armed against a
			// session whose failure the UI has already announced. Why the shutdown the teardown now
			// performs on this path is short: see the connect-error precondition on
			// `tearDownSession()`.
			tearDownSession()
			return
		}
		// Mirrors Tools/window-smoke/main.swift's own tick() exactly: every drained event
		// (control-lane orders and the FRAME_READY doorbell alike) goes straight to the
		// registry, which handles FRAME_READY internally (copyPublishedSurface -> present)
		// -- there's no separate frame-lane consumption call needed at this layer.
		let delivered = session.drainEvents { [weak self] event in
			self?.eventCount += 1
			self?.registry?.handle(event)
			// adr/0019 §2 lane D: the driver reads the same stream, ALWAYS after the registry and
			// never instead of it. `.disconnected` reaches the registry as `closeAllWindows()`,
			// while the driver's reaction to the same event calls straight back into
			// `applyReconnectState` on this turn -- so a driver that ran first would have this
			// delegate announce "Reconnecting" with the window table still full and the live-window
			// count still non-zero. `.handshakeFlags`, which the registry ignores, is the driver's
			// only evidence that a connection actually works, which is why every event goes to both
			// rather than being routed by kind.
			self?.reconnectDriver?.handle(event)
		}
		// The drain above can end the session: a driver that gives up on this turn reaches
		// `tearDownSession()` from inside the handler -- the one teardown every session end in this
		// file goes through. `guard let session` at the top of this method holds a local strong
		// reference and cannot see that, so re-read the property rather than overwrite the give-up
		// line with a "Connected" one describing a session that no longer exists.
		guard self.session != nil else { return }
		if delivered > 0 || eventCount > 0 {
			// M1/W1: carry the screen-parameter note through this tick's overwrite. Without it,
			// the one event this milestone adds would be legible for well under a second whenever
			// a session is live -- which is precisely the state in which it means anything. The
			// note is now appended by `ShellReconnectPresenter` in every state, reconnects
			// included, for the same reason.
			//
			// adr/0019 §2 lane D: ONE WRITER. This block used to hard-code the "Connected" wording,
			// so a dropped session went on being announced as connected once a second for as long
			// as the app ran -- `eventCount > 0` stays true after a drop, and this tick is what R-5
			// means by "the status line stops at the last Connected". What the label says is now a
			// function of the driver's state, and that function lives in one place.
			//
			// `?? .live` is the no-driver reading and is deliberately today's wording: a tick with
			// no driver is the pre-lane-D shell, unchanged.
			applyShell(for: reconnectDriver?.state ?? .live)
		}
	}

	/// The driver's state changes, as this app's reaction to them. Called on T_main from
	/// `ReconnectDriver`'s own transition, after its `state` has been updated.
	private func applyReconnectState(_ state: ReconnectDriver.State) {
		if case .reconnecting = state {
			// The connect path's rule, applied to the other way a session begins: a staleness
			// verdict belongs to the session it was computed against, and a reconnect has just
			// re-frozen the topology against a fresh read. Cleared on `.reconnecting` rather than
			// on `.live` so the note does not hang over the very attempt that is making it untrue.
			lastDisplayChangeNote = nil
			// adr/0020 D-7 (#4): the event count starts again with the connection it counts. The
			// status line puts it beside `generation`, which the bridge steps when it shuts the old
			// connection down, and the driver announces this state and then restarts the session in
			// one synchronous turn -- so resetting here keeps both numbers about one connection.
			// Accepted cost, owner-ruled with D-7: until the new connection's first event, the drain
			// tick's `eventCount > 0` gate is shut, so a display-change note written straight into
			// the label in that interval stays there alone. The `.reconnecting` line itself does not
			// depend on the tick: `applyShell` below writes it on this very call.
			eventCount = 0
		}
		applyShell(for: state)
		if case .gaveUp = state {
			// This app's half of "the driver has stopped trying": end the session for real, so the
			// button `ShellReconnectPresenter` has just enabled can actually start a new one.
			tearDownSession()
		}
	}

	/// The End-session button's action (adr/0020 D-5 = Q1): the user ending the session on
	/// purpose, and the teardown's fourth caller.
	///
	/// The connect-error branch's shape, UI first and teardown second: this method's own status
	/// line, then Connect enabled by a literal `true`, then the teardown. Neither goes through
	/// `ShellReconnectPresenter`, because ending a session on purpose is not a reconnect state --
	/// the reason `applyShell` gives for the other literal `true`s. This button is not written here
	/// at all: the teardown's `session = nil` disables it through `session`'s `didSet`.
	///
	/// Pressable in every state that has a session (adr/0020 D-6): before the handshake, where it
	/// amounts to cancelling the connect, and in `.live`, `.waiting` and `.reconnecting`. The
	/// teardown disarms and drops the driver before it shuts anything down, which closes both of
	/// the driver's edges in all four, so the driver gains no API for this. In `.live` the teardown
	/// blocks this thread until the bridge has joined T_rdp -- the same class of wait as the quit
	/// ceiling's exit -- and the label a human sees is the one written below, once that wait is
	/// over. Not deferred to a later turn to paint first: a deferral is a window in which a push
	/// could re-enter a session this press has already decided to end.
	///
	/// It writes nothing to stdout and nothing to the unified log (adr/0020 D-10): an unattended run
	/// that needs a press anchor is to get one from the knob that presses this button (adr/0020
	/// lane K), not from the button itself.
	@objc private func endSessionTapped() {
		guard session != nil else { return }
		statusLabel.stringValue = "Session ended. Press Connect to start a new one."
		connectButton.isEnabled = true
		tearDownSession()
	}

	/// The one way a session ends in this app. Four callers, and only four: the connect-error
	/// branch of `drainTick`, the `.gaveUp` branch of `applyReconnectState`, the End-session
	/// button's `endSessionTapped` (adr/0020), and `applicationWillTerminate`. The status line and
	/// the button are NOT written here: each caller says what happened in its own words before it
	/// calls this (or says nothing, on the way out of the process).
	///
	/// WHY ONE FUNCTION (the session-end lane, repairing lane D impl-report §8 #1, #3, #5 and #7).
	/// There used to be three hand-written teardowns, and each was missing a different step. The
	/// connect-error branch kept `session`, so the button it re-enabled refused every press (#1);
	/// termination dropped nothing (#7); none of the three cleared the push hook (#5); and a session
	/// ending any other way would have left `drainTimer` rewriting the status line once a second for
	/// the life of the process (#3). With every step spelled once, here, a session cannot be shut
	/// down without its timer being stopped in the same breath, so #3 is closed by construction
	/// rather than detected.
	///
	/// THE ORDER, (a) to (g), and why each step is where it is:
	///
	/// (a) The timer first. It is the only thing that can call `drainTick` again on its own.
	///
	/// (b) Disarm the driver and drop it, BEFORE the shutdown. `-shutdownAndWait` sets
	/// `teardownInitiated`, which stops the driver reacting to the DISCONNECTED the shutdown is about
	/// to cause -- but that closes the EVENT edge only. A retry already scheduled on the clock is a
	/// second edge, and disarming is what cancels it (and what the driver's own timer-edge guard
	/// reads before it restarts anything). Dropping the driver as well means a retry block, which
	/// holds it weakly, finds nothing even if it fires.
	///
	/// (c) Clear the push hook, BEFORE the shutdown, so a push the shutdown itself causes is a no-op
	/// from the moment it is produced. The bridge reads the hook inside its main-queue block, when
	/// the block runs (`AppDelegateSessionEndPinTests` pins that premise), so a push already queued
	/// reads nil too. Cleared here rather than by the bridge because the reconnect path runs the very
	/// same `-shutdownAndWait` and keeps using the hook after it. And cleared through `session?.`
	/// BEFORE `session = nil`: after it, the same statement compiles and does nothing.
	///
	/// (d) Shut down, after both disconnections and before any reference is dropped.
	///
	/// (e) Close the RAIL windows, through the registry's session-end entry (adr/0020 D-2 = P1):
	/// AFTER the shutdown and BEFORE either reference is dropped. After, because `-shutdownAndWait`
	/// returns only once both FreeRDP threads are gone -- adr/0005 §4 closes an NSWindow only then --
	/// and because by then the bridge has destroyed its outbound queue, so nothing this step sets
	/// off (a modifier release from a window giving up key status as it closes included) can reach
	/// the wire, and has cleared its surface pool, so a surface a closing window hands back is
	/// released rather than reused. Before, because each window hands its surface back through the
	/// session the registry still holds, and because a registry dropped with its windows still
	/// ordered in would leave them on screen with no owner: a window with `isReleasedWhenClosed =
	/// false` survives losing its last App-side reference. Every caller runs it. On the give-up and
	/// connect-error paths the window table is already empty when this runs (adr/0020 §0(b)), so
	/// there it closes nothing and only resets the registry's own tray and input state -- "argued
	/// empty" becomes "closed by construction". The End-session button and the exit path are where
	/// it closes windows that are still open.
	///
	/// (f) Drop `session` and `registry`. `session = nil` is the load-bearing statement:
	/// `connectTapped`'s first guard is `session == nil`, and an automatic reconnect reuses the SAME
	/// `CRSession`, so an ending that re-enabled the button without dropping the session would
	/// produce a button that answers "Already connecting/connected." to every press -- enabled and
	/// useless.
	///
	/// (g) The topology's session end, last. With no session left, a later display change must not
	/// report a desktop size as stale, and advise a reconnect, for a session that does not exist. It
	/// has no output, and nothing above depends on it.
	///
	/// PRECONDITIONS, caller by caller.
	///
	/// FROM THE GIVE-UP BRANCH this runs from INSIDE the drain that delivered the `.disconnected`, so
	/// what makes (d) safe there is not that it is cheap -- it is that step 4 of the bridge's
	/// five-step teardown performs no drain of its own on that path. The bridge sets its
	/// per-connection disconnect-sentinel bit BEFORE it calls the drain handler (adr/0019 §2 lane B,
	/// and `ReconnectSemanticsPinTests` pins that order), step 4 seeds its loop from that bit, and a
	/// seed of `true` means the loop body never runs: no 100 x 50 ms poll, and no NESTED
	/// `crdpq_drain`.
	///
	/// A nested drain would not deadlock -- `crdpq_drain` releases its lock before it calls the
	/// visitor -- and that is exactly what makes it dangerous rather than merely wasteful. It would
	/// swap the double buffer a second time, handing the buffer the OUTER drain is still iterating
	/// back to the producers with its element count zeroed: the next `crdpq_post` would overwrite
	/// entries the outer loop has not reached yet, and a growth step would `realloc` the outer
	/// loop's `drain_buf` out from under it. "No nested drain" is a memory-safety precondition of
	/// calling this from a drain handler, not a performance note.
	///
	/// `pthread_join` inside the bridge's step 5 is bounded for the same reason the sentinel is
	/// already set: both paths that post DISCONNECTED do so as their last act before returning, and
	/// the bridge hands work to the main queue with `dispatch_async`, never `dispatch_sync`, so T_rdp
	/// cannot be waiting on the main thread that is waiting on it.
	///
	/// The give-up branch may also be running inside the push hook's own block when (c) clears the
	/// hook. That is safe for the same reason releasing the driver from inside its own callback is:
	/// the bridge invokes the value its getter returned, which ARC keeps alive for the whole call.
	///
	/// FROM THE CONNECT-ERROR BRANCH this runs before that method's own drain, never inside one. A
	/// `-start` that failed synchronously left the session idle, and `-shutdownAndWait` returns from
	/// idle at once. A connect that failed on T_rdp set the error first and posted the sentinel as
	/// its last act before returning, so step 4 drains for the sentinel itself -- a flat drain, not a
	/// nested one -- and waits at most until T_rdp gets there; the join is of a thread on its way out.
	///
	/// FROM `endSessionTapped` nothing is inside a drain: it is an AppKit target-action on the main
	/// thread, and every other way into this file's session code -- the push hook's block, the
	/// backstop timer, the driver's retry clock -- runs on that same thread, one at a time. A driver
	/// may have a retry pending, which (b) cancels. In `.live` the shutdown's step 4 waits for the
	/// sentinel the abort produces and step 5 joins T_rdp without a timeout, so the main thread is
	/// blocked for that long, as it is on the quit ceiling's exit.
	///
	/// FROM `applicationWillTerminate` nothing is inside a drain either, and a driver may have a
	/// retry pending, which (b) cancels. The process is going away regardless; it ends its session in
	/// this shape anyway so that "a session ends" has ONE shape in this file -- and since adr/0020
	/// D-3 (X1) that shape includes (e): windows still open at exit are closed inside this function,
	/// after the shutdown and before the references are dropped, like every other caller's.
	/// Closing the last windows there does not make AppKit ask
	/// `applicationShouldTerminateAfterLastWindowClosed` again or re-enter `terminate:` (adr/0020
	/// D-3's offline exit probe, run for lane S).
	private func tearDownSession() {
		drainTimer?.invalidate()
		drainTimer = nil
		reconnectDriver?.detach()
		reconnectDriver = nil
		session?.onEventsAvailable = nil
		session?.shutdownAndWait()
		registry?.closeWindowsForSessionEnd()
		session = nil
		registry = nil
		displayTopology.endSession()
	}

	/// The Connect button and the status label, written together out of one decision.
	///
	/// The only place in this file that derives either of them from a reconnect state, which is
	/// what keeps `ShellReconnectPresenter`'s offline tests worth anything: this app contributes
	/// the binding and nothing else. The button's five literal `isEnabled = true` sites -- the
	/// boundary refusal and the connect-error branch, which predate the driver, the End-session
	/// action (adr/0020 D-5) and the two host.env failures that moved behind the button's disable
	/// (adr/0020 D-8) -- keep their literal: none of them is a reconnect state.
	private func applyShell(for state: ReconnectDriver.State) {
		let shell = ShellReconnectPresenter.shell(
			for: state,
			connected: .init(
				events: eventCount,
				generation: session?.currentGeneration ?? 0,
				windows: registry?.windowSnapshots().count ?? 0
			),
			displayNote: lastDisplayChangeNote
		)
		statusLabel.stringValue = shell.statusLine
		connectButton.isEnabled = shell.connectEnabled
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}

	func applicationWillTerminate(_ notification: Notification) {
		// The session-end lane (lane D impl-report §8 #7): the app's last session end goes through
		// the same teardown as every other, instead of a shorter one of its own that dropped
		// nothing. It still disarms the driver before the shutdown (a retry already on the clock
		// is an edge `teardownInitiated` does not close), and everything it drops, it drops after
		// the shutdown. See the exit precondition on `tearDownSession()`.
		tearDownSession()
	}
}

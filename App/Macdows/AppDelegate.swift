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
	/// UI slice ① (UI-1 spec §1): the Hosts window, which replaced the scaffold window. It hosts the
	/// session controls built below (title, status line, Connect, Disconnect) and owns host editing.
	private var mainWindow: MainWindowController!
	/// ADR-0024 D-9 (M-a): the host records -- the only source of WHICH host a Connect press dials.
	private let hostStore = HostRecordStore(fileURL: HostRecordStore.defaultFileURL())
	/// ADR-0024 D-1 / D-3: the keychain stores (file-based login keychain, S-b). Every call is made
	/// off the main thread.
	private let credentialStore: any CredentialStore = KeychainCredentialStore()
	private let pinStore: any PinStore = KeychainPinStore()
	/// The chain the current session belongs to (ADR-0024 D-2): its host, the trust context its
	/// certificate callback judges by, and whether it has reached live.
	private var chainHost: HostID?
	private var chainContext: CertificateDecision.Context?
	private var chainReachedLive = false
	/// ADR-0024 D-2′: a certificate the callback rejected, waiting for the user's answer. Holds the
	/// rejected chain's `CRSession` (and so its password) until Trust / Replace re-starts it or
	/// Cancel drops it.
	private var pendingReview: PendingCertificateReview?
	/// True while a drain is running, so a session end seen from inside it is reviewed after it.
	private var isDraining = false
	/// True from a give-up until the chain's end is recorded: the reconnect driver can give up from
	/// its retry clock, outside any drain, and that end is a lost connection, not a Disconnect press.
	private var endingByGiveUp = false
	/// UI-1 spec §4.3: "Enter Password…" on the sign-in banner asks for the password once even when
	/// the keychain has one.
	private var askPasswordOnNextPress = false
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
	private var registry: RemoteWindowRegistry? {
		// adr/0022 D-6 / adr/0023 D-6 (P-a): the status item is handed the current session's
		// registry -- the source of its Remote tray section -- and nil when there is none (an
		// empty source: the section hides). A `didSet` covers both of this property's assignments,
		// the connect's and the teardown's, without adding a statement to either.
		didSet { statusItemController.bind(registry) }
	}
	/// adr/0022 D-6 (T1, UI slice ②): the Macdows status item and its menu. App-resident -- created
	/// with this delegate, put in the menu bar at launch, taken out when the App terminates -- and
	/// never per session; it reads the session through `statusItemReading()` and is handed the
	/// registry by `registry`'s `didSet`.
	private let statusItemController = StatusItemController()
	/// The address the current session was opened to, for the status item's rows and the Remote
	/// tray section's header (adr/0023 D-4). Read only while `session` is set.
	private var statusItemHost: String?
	/// adr/0019 §2 lane D: the reconnect driver for the session above, armed in `beginSession` and
	/// dropped when this app stops having a session to reconnect. Per-connection, exactly like
	/// `session` and `registry`, and deliberately NOT app-resident: it holds the very `CRSession`
	/// it restarts, so a driver outliving that session would be armed against a connection nobody
	/// owns any more.
	private var reconnectDriver: ReconnectDriver?
	private var drainTimer: Timer?
	private var eventCount: Int = 0
	/// UI slice ④ (UI-1 spec §4.1 "since 12:03"): when the current connection leg reached `.live`
	/// -- the RAIL handshake completed. The App's ONE record of that moment: the status bar
	/// (`connectedSummary()`) and the status item (`statusItemReading()`) both read it. Set on the
	/// first `.live` of a leg, cleared by every other state and when the chain ends.
	private var liveSince: Date?
	/// UI slice ④ (adr/0011 §2, UI-1 spec §4.3): this leg's input-method notice -- the session's
	/// `unicodeInputSupported`, read once on the leg's first `.live`; the status bar's `dg_bar`
	/// follows `degraded`.
	private var inputNotice = InputCapabilityNotice()
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

		// UI slice ① (UI-1 spec §1): the session controls -- the selected host's title, the status
		// line, Connect and Disconnect -- are built here, as before, and handed to the Hosts window,
		// which lays them out at the top of the host detail. The scaffold window is gone.
		let label = NSTextField(labelWithString: "")
		label.translatesAutoresizingMaskIntoConstraints = false

		let status = NSTextField(labelWithString: UIStrings.notConnected)
		status.font = .systemFont(ofSize: 13)
		status.textColor = .secondaryLabelColor
		status.maximumNumberOfLines = 0 // a display-change note adds a second line
		status.translatesAutoresizingMaskIntoConstraints = false
		statusLabel = status

		let button = NSButton(title: "Connect", target: self, action: #selector(connectTapped))
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
		stack.spacing = 8
		stack.alignment = .leading
		stack.translatesAutoresizingMaskIntoConstraints = false

		mainWindow = MainWindowController(
			store: hostStore, actions: HostActions(credentials: credentialStore, pins: pinStore)
		)
		mainWindow.installSessionControls(stack, title: label, status: status, connect: button, disconnect: endButton)
		mainWindow.onHostsChanged = { [weak self] in
			self?.statusItemController.refresh()
		}
		mainWindow.onSessionPresenceChange = { [weak self] present in
			self?.sessionPresenceChanged(present)
		}
		mainWindow.showWindow(nil)
		NSApp.activate(ignoringOtherApps: true)
		// Gate r1 I-2 (UI slice ①): the Hosts window can be closed, and closing it only orders it
		// out. View ▸ Show Hosts gets the controller as its explicit target (a closed window's
		// controller is not in the responder chain), and the status item's Open Macdows shows it
		// too; a Dock-icon reopen is `applicationShouldHandleReopen` below.
		MainMenu.bindShowHosts(in: NSApp.mainMenu, to: mainWindow)
		statusItemController.onOpenMacdows = { [weak self] in
			self?.mainWindow.showHosts(nil)
		}

		// UI slice ① (ADR-0024 §3 adr/0023 row): the status item's Connect to lists the host
		// records and presses Connect for the chosen one, through the Hosts window.
		statusItemController.hostEntries = { [weak self] in
			self?.hostStore.records.map { StatusItemController.HostEntry(id: $0.id, title: $0.title) } ?? []
		}
		statusItemController.onConnectTo = { [weak self] host in
			self?.mainWindow.connect(to: host)
		}

		// adr/0022 D-6 (UI slice ②): the status item, once, at launch.
		statusItemController.reading = { [weak self] in
			self?.statusItemReading() ?? .noSession
		}
		statusItemController.install()

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
				note = UIStrings.displayNoteNoDisplay
			} else if change.sessionDesktopSize == nil {
				// No connect since launch (or since the last session ended), so there is no
				// negotiated size to be stale. Distinguishable precisely because the payload
				// carries the session's size (adr/0015 §5.A.2), so say so instead of reporting
				// "unaffected", which would imply a session exists.
				note = UIStrings.displayNoteNoSession
			} else if change.connectedDesktopSizeIsStale {
				note = UIStrings.displayNoteStale
			} else {
				note = UIStrings.displayNoteUnaffected
			}
			self.lastDisplayChangeNote = note
			self.statusLabel.stringValue = note
		}

		// adr/0019 §2 R-6 tool lane T1, extended by adr/0020 lane K and adr/0021 lane LC-2: six
		// unattended-launch knobs, all default OFF. With none of the six variables exported --
		// which is every launch by Finder, by Xcode's Run button or by `open` -- `plan` is
		// `ShellAutolaunch.off`, none of the `if`s below are taken, and this app finishes launching
		// byte-for-byte as it did before any of these lanes. See `ShellAutolaunch` for why reading
		// these names is not the thing `connectTapped` refuses to do (that refusal is about where a
		// HOST comes from; none of the six knobs names a host, an account or a credential).
		//
		// Read once, into one value, because the pin next door holds `ShellAutolaunch.plan(` to
		// exactly one occurrence in this file: two call sites could disagree about the same launch.
		let autolaunch = ShellAutolaunch.plan(environment: ProcessInfo.processInfo.environment)
		if autolaunch.keyWitness {
			// adr/0021 lane CA-2: the bridge's observation-only `[key-witness]` lines. Set before the
			// autoconnect press below, so every connection this process starts copies it in at its
			// own `-start`. Off (the default) leaves the class switch at its initial `NO`.
			CRSession.keyWitnessEnabled = true
		}
		if autolaunch.autoconnect {
			// `connectTapped()` itself, never a copy of any step inside it: the selected record's
			// preflight (the live-host boundary gate, the pin item, the keychain password) and the
			// button/`isCheckingBoundary` interlock all have to run exactly as they do for a human press, and the only way to guarantee that is to make
			// the press. `@objc private` is callable from inside this file, so no visibility changes.
			connectTapped()
		}
		if let disconnectAfter = autolaunch.disconnectAfterInterval {
			// adr/0020 lane K (D-10 = V1): the same real button a human's mouse would press, by
			// the same route as `connectTapped()` above -- one Timer, scheduled once, calling the
			// `@objc` action method itself, never a step copied out of it. `ShellAutolaunch.plan`
			// (gate r1 I-2, folded in) never returns a `disconnectAfterInterval` unless
			// `autoconnect` is also on, so this block cannot be entered by an environment that only
			// sets this one knob, and this press cannot land on a session a human started by hand
			// instead of this knob's own autoconnect press.
			//
			// If the autoconnect attempt above has already failed (`drainTick`'s connect-error
			// branch already tore its session down) or never got as far as `beginSession` at all,
			// `endSessionTapped()`'s own `guard session != nil` makes THIS press a silent no-op
			// (gate r1 m-2) -- and the reconnect press below then starts what is really a RETRY of
			// that same failed attempt, not a second connection to one still up.
			_ = Timer.scheduledTimer(withTimeInterval: disconnectAfter, repeats: false) { _ in
				MainActor.assumeIsolated {
					ShellAutolaunch.notePress(.disconnect)
					self.endSessionTapped()
					if let reconnectAfter = autolaunch.reconnectAfterInterval {
						// "Another t2 seconds" -- relative to the moment `self.endSessionTapped()`
						// just above RETURNED, not to launch and not to when it was CALLED (gate
						// r1 m-1): that call blocks (in `.live`, through `tearDownSession()`'s
						// `shutdownAndWait()`), so this Timer is scheduled, and starts counting,
						// only once that block is over. Nested here rather than a second
						// top-level `if let` for the same reason as above: `ShellAutolaunch.plan`
						// (gate r1 I-2) already reads `MACDOWS_RECONNECT_AFTER_SECONDS` as `nil`
						// whenever `MACDOWS_DISCONNECT_AFTER_SECONDS` did not itself parse to a
						// value, since there is then no Disconnect press for it to be "after".
						_ = Timer.scheduledTimer(withTimeInterval: reconnectAfter, repeats: false) { _ in
							MainActor.assumeIsolated {
								ShellAutolaunch.notePress(.connect)
								self.connectTapped()
							}
						}
					}
				}
			}
		}
		if let quitAfter = autolaunch.quitAfterInterval {
			// `NSApp.terminate`, not `exit()` and not a SIGTERM from outside: terminate is the one
			// route that runs `applicationWillTerminate` below, and that method's detach ->
			// shutdownAndWait -> close windows -> endSession sequence is part of what an
			// unattended run has to exercise. It doubles as the safety net -- a batch that dies
			// leaves behind no app still holding a live session, and none of its RAIL windows
			// still on screen (adr/0020 D-3, X1).
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
		if let extraExecAfter = autolaunch.extraExecAfterInterval, let extraExecProgram = autolaunch.extraExecProgram {
			// adr/0021 lane LC-2 (owner ruling O-1): one extra RAIL ClientExecute, inside the
			// connection this app holds when the Timer fires, counted from launch. One-shot and
			// unstored, like the ceiling above: it is sent once, never re-sent, and never routed
			// through the ARC_COMPLETED start path. `ShellAutolaunch.plan` already guarantees
			// autoconnect, a ceiling after this delay and, if a Disconnect press is scheduled at
			// all, one strictly after it (O-2), so nothing is re-checked here.
			//
			// The anchor line (witness A-X) is printed FIRST and always, carrying only the program's
			// byte count and whether a session exists -- never the program itself. With no session
			// (the autoconnect press failed, or has not reached `beginSession`) nothing is sent; the
			// line's `session=absent` is what says so. `session` is read once, so the line and the
			// send cannot disagree. A session whose RAIL channel is not up yet drops the command in
			// the bridge with its own WARN line.
			_ = Timer.scheduledTimer(withTimeInterval: extraExecAfter, repeats: false) { _ in
				MainActor.assumeIsolated {
					let session = self.session
					ShellAutolaunch.notePress(.extraExec, programBytes: extraExecProgram.utf8.count, sessionPresent: session != nil)
					if let session {
						session.executeProgram(extraExecProgram)
					}
				}
			}
		}
	}

	@objc private func connectTapped() {
		// `isCheckingBoundary` as well as `session`: the preflight below is asynchronous, and during
		// its window `session` is still nil, so this guard alone would let a second press start a
		// second one. The button is disabled synchronously before the Task for the same reason
		// (AppKit delivers actions serially on the main actor, so a disable that happens before this
		// method returns cannot be raced).
		guard session == nil, !isCheckingBoundary else {
			statusLabel.stringValue = UIStrings.oneSessionAtATime
			return
		}
		// ADR-0024 D-9 (M-a): the host is the record selected in the Hosts window -- the one place a
		// human can see which host this press dials -- and nothing else. No file and no environment
		// variable names a host, an account or a password any more. With no selection (no records,
		// or several and none chosen, which is also how M-a-1 keeps an unattended
		// `MACDOWS_AUTOCONNECT` press from guessing) the press does nothing but say so, in one line
		// that names no address.
		guard let record = mainWindow.selectedRecord else {
			ConnectChain.log.notice("[connect] refused: no host selected (host records: \(self.hostStore.records.count, privacy: .public))")
			statusLabel.stringValue = UIStrings.notConnected
			return
		}
		// A new press abandons a certificate question still open from the last chain: dropping the
		// review drops that chain's session, which overwrites its password (ADR-0024 D-2).
		pendingReview = nil
		mainWindow.clearBanners()
		let forcePassword = askPasswordOnNextPress
		askPasswordOnNextPress = false

		// Live-host testing boundary gate (owner rule, 2026-08-31), the in-process mirror of
		// Scripts/lib.sh's crdp_assert_lab_boundary. Unconditional, NOT #if DEBUG: a shipped Macdows
		// obviously must connect to hosts that are not the maintainer's own lab, so the gate belongs
		// to the harness, not to the product, and removing it is a deliberate act -- registered by
		// ADR-0024 D-9 as a Phase 4 item, not done here. The refusal line names the host (the address
		// of the record the human selected) and a reason category, never a boundary segment.
		//
		// Off the main actor, in ONE `KeychainQueue.run` body, for the reasons adr/0020 D-8 gave for
		// the host.env read this replaced: the gate can block (a host NAME goes through getaddrinfo),
		// and so can the keychain -- the file-based keychain shows an authorisation prompt and blocks
		// the calling thread until it is answered (ADR-0024 probe K). On that serial queue a blocked
		// call holds the queue's own thread, never one of the cooperative pool's (gate r1 m-5). `ConnectFlow.preflight` runs
		// the gate first (nothing is read from the keychain for an address that may not be dialled),
		// then the pin item (a pin that cannot be read stops before the password is touched, D-3′),
		// then the password -- once per press, which is the chain's one credential read (D-2).
		// `isCheckingBoundary` is reset once, before the result is read, whatever it is, and every
		// arm that does not start a session hands the button back with a literal `true`.
		isCheckingBoundary = true
		connectButton.isEnabled = false
		statusLabel.stringValue = UIStrings.connecting
		mainWindow.activeHostID = record.id
		applyHostsWindow(state: nil, host: record.id)
		let credentials = credentialStore
		let pins = pinStore
		let host = record.id
		let address = record.address
		let recordSaysPinned = record.pinned
		let readsKeychain = record.remembersPassword && !forcePassword
		Task { [weak self] in
			let preflight = await KeychainQueue.run { () -> ConnectFlow.Preflight in
				ConnectFlow.preflight(
					host: host, address: address, recordSaysPinned: recordSaysPinned, remembersPassword: readsKeychain,
					credentials: credentials, pins: pins, boundary: { LabBoundary.check(host: $0) }
				)
			}
			guard let self else { return }
			self.isCheckingBoundary = false
			switch preflight {
			case .refusedByBoundary(let refusal):
				self.statusLabel.stringValue = LabBoundary.refusalLine(host: address, refusal: refusal)
				self.connectButton.isEnabled = true
				self.chainEnded()
			case .pinUnavailable(let status):
				self.showPinUnavailable(record, status: status)
				self.connectButton.isEnabled = true
				self.chainEnded()
			case .ready(let context, let secret?, _):
				self.beginChain(record, context: context, secret: secret)
			case .ready(let context, nil, let keychainStatus):
				if let keychainStatus {
					ConnectChain.log.notice("[connect] keychain read failed status=\(keychainStatus, privacy: .public); asking for the password")
				}
				self.askForPassword(record, context: context)
			}
		}
	}

	/// ADR-0024 D-1: the password was not saved, the keychain did not hand it over, or the user
	/// asked to type it again -- the Password sheet asks, and nothing else is tried.
	private func askForPassword(_ record: HostRecord, context: CertificateDecision.Context) {
		mainWindow.presentPasswordSheet(for: record) { [weak self] result in
			guard let self else { return }
			guard let result else {
				self.statusLabel.stringValue = UIStrings.notConnected
				self.connectButton.isEnabled = true
				self.chainEnded()
				return
			}
			guard result.remember else {
				self.beginChain(record, context: context, secret: result.secret)
				return
			}
			let credentials = self.credentialStore
			Task { [weak self] in
				let saved = await ConnectChain.savePassword(result.secret, for: record.id, displayName: record.title, credentials: credentials)
				guard let self else { return }
				// Gate r1 m-11: the record says "Saved in Keychain" only when the save succeeded;
				// otherwise it keeps its bit and the detail keeps saying "Asked for on each connection".
				var current = record
				if saved {
					current.remembersPassword = true
					self.hostStore.upsert(current)
				} else {
					ConnectChain.log.notice("[connect] the password could not be saved; it is asked for again next time")
				}
				self.beginChain(current, context: context, secret: result.secret)
			}
		}
	}

	/// The start of a chain (ADR-0024 D-2): its `CRSession` copies the password bytes, which are then
	/// overwritten here; every later `-start` of the chain -- reconnects, and the re-start after a
	/// certificate confirmation -- reuses that session and never reads the keychain again.
	private func beginChain(_ record: HostRecord, context: CertificateDecision.Context, secret: SessionSecret) {
		let chainSession = secret.withUnsafeData { bytes in
			CRSession(host: record.address, user: record.userName, passwordBytes: bytes, program: "C:\\Windows\\System32\\winver.exe")
		}
		secret.wipe()
		chainSession.port = record.port
		chainReachedLive = false
		beginSession(chainSession, record: record, context: context)
	}

	/// Everything `connectTapped` used to do inline once the credentials were in hand. Split out
	/// only so the preflight above can be awaited without nesting the whole method inside a
	/// closure. Reached with a new chain's session, or -- after Trust / Replace (ADR-0024 D-2′) --
	/// with the SAME session the certificate callback rejected, and the context the sheet produced.
	private func beginSession(_ newSession: CRSession, record: HostRecord, context: CertificateDecision.Context) {
		// ADR-0024 D-4 (Y-b): the trust snapshot the certificate callback reads on T_rdp -- the one
		// fingerprint this connection may accept, or none (first use, pin lost).
		newSession.acceptedCertificateFingerprint = ConnectFlow.trustSnapshot(for: context)
		chainHost = record.id
		chainContext = context
		mainWindow.activeHostID = record.id
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
		statusItemHost = record.title
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
		statusLabel.stringValue = UIStrings.connecting
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
				self?.drainThenReview()
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
				self?.drainThenReview()
			}
		}
	}

	private func drainTick() {
		guard let session else { return }
		if let error = session.lastConnectError {
			// UI slice ④ (UI-1 spec §4.1): the status line says `st_err`; the error itself goes to
			// the `[connect]` log line only (and with it to the diagnostics export), as its domain
			// and code -- never its description, which can carry the host's address.
			ConnectChain.log.notice("[connect] failed: domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)")
			statusLabel.stringValue = UIStrings.connectionFailed
			connectButton.isEnabled = true
			// The session-end lane (lane D impl-report §8 #1): this branch now ENDS the session
			// instead of only announcing that it failed. It used to stop the timer, re-enable the
			// button and drop the topology freeze but keep `session` -- and `connectTapped`'s first
			// guard is `session == nil`, so the button it had just enabled refused every press.
			// `tearDownSession()` drops the session along with everything else a session owns, so
			// the button really starts a new connection.
			//
			// UI first, teardown second: the order the give-up path has too. The failure line and
			// the literal `true` are what lane D froze here that a human actually sees, and both are
			// kept (the line re-worded to the catalog's `st_err` by UI slice ④); this branch stays
			// the one place a connect ERROR re-enables the button.
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
			// `?? .live` is the no-driver reading: a tick with no driver says "Connected" (with no
			// handshake moment recorded, the status bar keeps the short form too).
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
		// UI slice ④: the input capability, read once per leg (only READ: the registry's own gate
		// keeps its log line and its counters).
		let showInputBanner = inputNotice.observe(state) { session?.unicodeInputSupported ?? true }
		// UI slice ④: the handshake moment of this leg, recorded before anything below reads it.
		if case .live = state {
			if liveSince == nil { liveSince = Date() }
		} else {
			liveSince = nil
		}
		applyShell(for: state)
		// UI slice ①: the Hosts window's marker, subtitle and status bar follow the same state, and
		// the chain's first live state is recorded (and a matching preset pinned, ADR-0024 D-5).
		applyHostsWindow(state: state, host: chainHost)
		applySessionBanners(for: state, showInputBanner: showInputBanner)
		if case .live = state {
			noteChainLive()
		}
		if case .gaveUp = state {
			endingByGiveUp = true
		}
		// adr/0022 D-6 / adr/0023 D-4: the status item's rows and Remote tray section follow the
		// driver's state, including while its menu is open.
		statusItemController.refresh()
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
		statusLabel.stringValue = UIStrings.sessionEnded
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
	/// produce a button that refuses every press (`connectTapped`'s first guard) -- enabled and
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
	/// On the common exit path (a quit ceiling or an explicit `NSApp.terminate`) closing the last
	/// windows here never makes AppKit ask `applicationShouldTerminateAfterLastWindowClosed` at
	/// all -- that ask never fires during termination on that path. Since UI slice ① that ask
	/// answers false (the status item keeps the App reachable, gate r1 I-2), so closing the last
	/// RAIL window no longer starts termination at all; before it, where that close was the
	/// trigger, the ask happened exactly once, before this function ever ran. Either way this step
	/// does not re-enter `terminate:` (adr/0020 D-3's offline exit probe, run for lane S, and gate
	/// r1's G6 arm, which drove termination from that very check).
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

	/// The Connect button, the status label and the status bar, written together out of one
	/// decision.
	///
	/// The only place in this file that derives any of them from a reconnect state, which is what
	/// keeps `ShellReconnectPresenter`'s offline tests worth anything: this app contributes the
	/// binding and nothing else. The button's five literal `isEnabled = true` sites -- the
	/// boundary refusal and the connect-error branch, which predate the driver, the End-session
	/// action (adr/0020 D-5), the unreadable pin item (ADR-0024 D-3′) and the Password sheet's
	/// Cancel (ADR-0024 D-1) -- keep their literal: none of them is a reconnect state.
	///
	/// UI slice ④: the status bar is written here too, because the drain tick calls this and the
	/// bar's live text carries the window count; `applyHostsWindow` writes the same text on a state
	/// change, from the same presenter function.
	private func applyShell(for state: ReconnectDriver.State) {
		let shell = ShellReconnectPresenter.shell(
			for: state,
			connected: connectedSummary(),
			displayNote: lastDisplayChangeNote
		)
		statusLabel.stringValue = shell.statusLine
		connectButton.isEnabled = shell.connectEnabled
		mainWindow.setStatusBarText(shell.statusBar)
	}

	/// The current session as the presenter reads it: its live-window count, the handshake moment
	/// of its current leg (`liveSince`). One builder, so the status line's writer and the Hosts
	/// window's cannot describe two different sessions.
	private func connectedSummary() -> ShellReconnectPresenter.ConnectedSummary {
		.init(windows: registry?.windowSnapshots().count ?? 0, liveSince: liveSince, inputDegraded: inputNotice.degraded)
	}

	/// What the status item shows, read from this delegate's own state (adr/0022 D-6): whether a
	/// session exists -- the End-session button's predicate --, the reconnect driver's state, and the
	/// address. Read, never written.
	private func statusItemReading() -> StatusItemController.SessionReading {
		StatusItemController.SessionReading(
			hasSession: session != nil, state: reconnectDriver?.state, host: statusItemHost, liveSince: liveSince
		)
	}

	// MARK: - UI slice ①: the chain around the session (ADR-0024 D-2 / D-2′ / D-3′ / D-5)

	/// The push hook's and the backstop timer's body: the drain, then -- if that drain ended the
	/// session -- the review of how it ended. `ended` is a strong local, so the session the drain
	/// tore down (the connect-error branch and the give-up branch both drop `session`) stays alive
	/// for the review: a certificate rejection keeps it, and its password, for the sheet
	/// (D-2′); every other end lets it go when this returns, which overwrites the password (D-2).
	private func drainThenReview() {
		let ended = session
		isDraining = true
		drainTick()
		isDraining = false
		if let ended, session == nil {
			reviewSessionEnd(of: ended)
		}
	}

	/// A session ended inside a drain: a certificate rejection opens the certificate question;
	/// a first connect that failed otherwise gets its failure banner (UI-1 spec §4.3).
	private func reviewSessionEnd(of ended: CRSession) {
		guard let host = chainHost, let record = hostStore.record(host) else {
			chainEnded()
			return
		}
		if let rejection = ended.lastCertificateRejection, let context = chainContext {
			let presented = rejection.sha256Fingerprint.flatMap(CertificateFingerprint.init(canonical:))
			let verdict = CertificateDecision.verdict(for: context, presented: presented, unsupportedRoute: rejection.unsupportedRoute)
			presentCertificateQuestion(record, verdict: verdict, session: ended, rejection: rejection)
			return
		}
		if !chainReachedLive, let error = ended.lastConnectError {
			hostStore.note(.connectFailed, for: host)
			showConnectFailure(record, kind: ConnectFlow.failureKind(errorCode: (error as NSError).code, certificateRejected: false))
		} else if chainReachedLive {
			hostStore.note(.connectionLost, for: host)
		}
		chainEnded()
	}

	/// The Disconnect button turned on or off -- `session`'s didSet is its one writer, so this is a
	/// session beginning or ending, by any path. An end outside a drain is the End-session press or
	/// termination; one inside a drain is reviewed after it (`drainThenReview`).
	private func sessionPresenceChanged(_ present: Bool) {
		guard !present, !isDraining else { return }
		if let host = chainHost, chainReachedLive {
			hostStore.note(endingByGiveUp ? .connectionLost : .disconnectedByUser, for: host)
		}
		chainEnded()
	}

	/// The chain is over (or never began): forget it and put the Hosts window back to "no session".
	/// A pending certificate question keeps its own session; it is not touched here.
	private func chainEnded() {
		let host = chainHost
		// UI slice ④ (UI-1 spec §4.1): a chain that gave up keeps its give-up row -- red marker,
		// `s_gx` / `s_gr` in the status bar, `st_off` subtitle -- until the next press.
		let gaveUp = endingByGiveUp
		chainHost = nil
		chainContext = nil
		chainReachedLive = false
		endingByGiveUp = false
		liveSince = nil
		// UI slice ④: the input-method notice belongs to the connection that just ended, and so
		// does a connection banner that was still saying "reconnecting" (the user pressed
		// Disconnect); a give-up's banner stays until it is dismissed or the next press.
		inputNotice.reset()
		mainWindow.removeBanner(id: ShellReconnectPresenter.inputBannerID)
		if !gaveUp {
			mainWindow.removeBanner(id: ShellReconnectPresenter.connectionBannerID)
		}
		if pendingReview == nil {
			mainWindow.activeHostID = nil
		}
		if let host, !gaveUp, mainWindow.bannerIDs.isEmpty {
			applyHostsWindow(state: nil, host: host, ended: true)
		}
	}

	/// The first live state of a chain: a recent-connections row, and -- when the certificate
	/// matched an unpinned host's preset -- that preset written as the pin (ADR-0024 D-5).
	private func noteChainLive() {
		guard !chainReachedLive, let host = chainHost, let record = hostStore.record(host) else { return }
		chainReachedLive = true
		hostStore.note(.connected, for: host)
		guard case .preset(let expected)? = chainContext else { return }
		chainContext = .pinned(expected)
		let pins = pinStore
		Task { [weak self] in
			guard await ConnectChain.writePresetPin(expected, for: host, displayName: record.title, pins: pins) else {
				ConnectChain.log.notice("[connect] preset matched but the pin could not be written; the preset is compared again next time")
				return
			}
			self?.hostStore.setPinned(true, for: host)
			self?.hostStore.note(.certificatePinnedFromPreset, for: host)
		}
	}

	/// UI-1 spec §4.1: the Hosts window's marker, subtitle and status bar for the current state.
	private func applyHostsWindow(state: ReconnectDriver.State?, host: HostID?, ended: Bool = false) {
		let title = host.flatMap(hostStore.record)?.title ?? ""
		let presentation = ConnectChain.presentation(hasSession: !ended, state: state, hostTitle: title, connected: connectedSummary())
		mainWindow.setShell(subtitle: presentation.subtitle, statusBar: presentation.statusBar, marker: presentation.marker, for: host)
		mainWindow.setRemoteWindowsNote(ShellReconnectPresenter.remoteWindowsNote(for: ended ? nil : state))
	}

	/// UI slice ④ (UI-1 spec §4.2 / §4.3): the session banners, written from the driver's state in
	/// this one place. The connection banner is one id, replaced as the state moves on and removed
	/// by `.live` (and by a certificate give-up, whose banner is the certificate path's); the
	/// input-method banner shows at most once per connection leg and leaves with the leg. No
	/// button ends or starts a session by itself: Disconnect presses the Hosts window's Disconnect
	/// button (the End-session action), Reconnect presses its Connect button for the chain's host
	/// (the same route as the status item's Connect to), Dismiss removes the banner, Learn More
	/// opens Settings on its Keyboard page.
	private func applySessionBanners(for state: ReconnectDriver.State, showInputBanner: Bool) {
		let host = chainHost
		let title = host.flatMap(hostStore.record)?.title ?? ""
		if let banner = ShellReconnectPresenter.connectionBanner(for: state, hostTitle: title) {
			mainWindow.showBanner(sessionBannerModel(banner, host: host))
		} else {
			mainWindow.removeBanner(id: ShellReconnectPresenter.connectionBannerID)
		}
		if showInputBanner {
			mainWindow.showBanner(sessionBannerModel(ShellReconnectPresenter.inputBanner(hostTitle: title), host: host))
		} else if state != .live {
			mainWindow.removeBanner(id: ShellReconnectPresenter.inputBannerID)
		}
	}

	/// A presenter banner with its buttons wired to the existing paths (see `applySessionBanners`).
	private func sessionBannerModel(_ banner: ShellReconnectPresenter.SessionBanner, host: HostID?) -> BannerView.Model {
		let id = banner.id
		return .session(
			banner,
			disconnect: { [weak self] in self?.mainWindow.disconnectSession() },
			dismiss: { [weak self] in self?.mainWindow.removeBanner(id: id) },
			reconnect: { [weak self] in
				guard let host else { return }
				self?.mainWindow.connect(to: host)
			},
			learnMore: { [weak self] in self?.mainWindow.showKeyboardPage() }
		)
	}

	/// ADR-0024 D-3′: the pin item could not be read -- no connection, no first-use sheet, no retry.
	private func showPinUnavailable(_ record: HostRecord, status: Int32) {
		ConnectChain.log.notice("[connect] pin item unreadable status=\(status, privacy: .public); not connecting")
		statusLabel.stringValue = UIStrings.notConnected
		mainWindow.showBanner(.init(
			id: "pin-unavailable", title: UIStrings.pinUnavailableTitle(record.title), body: UIStrings.pinUnavailableBody,
			tone: .error, actions: [.init(title: UIStrings.dismiss) { [weak self] in self?.mainWindow.removeBanner(id: "pin-unavailable") }]
		))
		mainWindow.setShell(subtitle: nil, statusBar: UIStrings.connectionFailed, marker: .failed, for: record.id)
	}

	/// UI-1 spec §4.3: the three first-connect failure banners.
	private func showConnectFailure(_ record: HostRecord, kind: ConnectFlow.FailureKind) {
		let model: BannerView.Model
		let bar: String
		switch kind {
		case .unreachable:
			bar = UIStrings.barUnreachable
			model = .init(id: "connect-failed", title: UIStrings.unreachableTitle(record.title),
						  body: UIStrings.unreachableBody(address: record.address, port: Int(record.port)), tone: .error,
						  actions: [.init(title: UIStrings.editHostAction) { [weak self] in
							  self?.mainWindow.select(record.id)
							  self?.mainWindow.editHost(nil)
						  }])
		case .signIn:
			bar = UIStrings.barSignIn
			model = .init(id: "connect-failed", title: UIStrings.signInTitle(record.title), body: UIStrings.signInBody, tone: .error,
						  actions: [.init(title: UIStrings.enterPassword) { [weak self] in
							  self?.askPasswordOnNextPress = true
							  self?.mainWindow.connect(to: record.id)
						  }])
		case .certificate, .other:
			mainWindow.setShell(subtitle: nil, statusBar: UIStrings.connectionFailed, marker: .failed, for: record.id)
			return
		}
		mainWindow.showBanner(model)
		mainWindow.setShell(subtitle: nil, statusBar: bar, marker: .failed, for: record.id)
	}

	/// ADR-0024 D-5: a rejected certificate. First use and a change open their sheet (a change on a
	/// reconnect leg first shows the banner with Review Certificate…); a redirect / gateway route or
	/// an unreadable certificate gets the banner only. The rejected session is kept in
	/// `pendingReview` only while a sheet can still confirm it.
	private func presentCertificateQuestion(_ record: HostRecord, verdict: CertificateDecision.Verdict,
											session ended: CRSession, rejection: CRCertificateRejection) {
		statusLabel.stringValue = UIStrings.notConnected
		mainWindow.setShell(subtitle: nil, statusBar: UIStrings.barCertificate, marker: .failed, for: record.id)
		let wasLive = chainReachedLive
		chainHost = nil
		chainContext = nil
		chainReachedLive = false
		// Gate r1 m-13: this chain ends here, so a give-up flag it raised must not be read as the
		// end of the next one (it would log that user's Disconnect as "Connection lost").
		endingByGiveUp = false
		let variant: CertificateSheet.Variant
		switch verdict {
		case .firstUse(let presented):
			variant = .firstUse(presented: presented, subject: rejection.subject, issuer: rejection.issuer)
		case .changed(let old, let oldSource, let presented):
			variant = .changed(old: old, oldSource: oldSource, presented: presented, subject: rejection.subject, issuer: rejection.issuer)
		case .unsupportedRoute, .unreadableCertificate, .accept:
			let body = verdict == .unsupportedRoute ? UIStrings.unsupportedRouteBody : UIStrings.certificateRejectedBody
			mainWindow.showBanner(.init(id: "certificate", title: UIStrings.certificateRejectedTitle(record.title), body: body, tone: .error,
										actions: [.init(title: UIStrings.dismiss) { [weak self] in self?.mainWindow.removeBanner(id: "certificate") }]))
			mainWindow.activeHostID = nil
			return
		}
		let review = PendingCertificateReview(session: ended, host: record.id, verdict: verdict,
											  subject: rejection.subject, issuer: rejection.issuer)
		pendingReview = review
		let openSheet: () -> Void = { [weak self] in
			self?.mainWindow.presentCertificateSheet(variant, for: record) { confirmed in
				self?.answerCertificateQuestion(review, record: record, confirmed: confirmed)
			}
		}
		if case .changed = verdict {
			mainWindow.showBanner(.init(id: "certificate", title: UIStrings.certificateRejectedTitle(record.title),
										body: UIStrings.certificateRejectedBody, tone: .error,
										actions: [.init(title: UIStrings.reviewCertificate, handler: openSheet)]))
		}
		if !wasLive {
			openSheet()
		}
	}

	/// The sheet's answer. Cancel ends the chain (its session -- and password -- go with the
	/// review). Trust / Replace write the pin and re-start the SAME session with the new trust
	/// context: no second credential read, no Password sheet (ADR-0024 D-2′).
	private func answerCertificateQuestion(_ review: PendingCertificateReview, record: HostRecord, confirmed: Bool) {
		guard let pending = pendingReview, pending.session === review.session else { return }
		guard confirmed else {
			pendingReview = nil
			mainWindow.activeHostID = nil
			return
		}
		let pins = pinStore
		Task { [weak self] in
			let result = await ConnectChain.confirm(review, displayName: record.title, pins: pins)
			guard let self, let pending = self.pendingReview, pending.session === review.session else { return }
			self.pendingReview = nil
			switch result {
			case .success(let (context, confirmation)):
				self.hostStore.setPinned(true, for: record.id)
				switch confirmation {
				case .trusted:
					self.hostStore.note(.certificateTrusted, for: record.id)
				case .replaced(let old, let new):
					self.hostStore.note(.certificatePinReplaced, detail: "\(old?.shortDisplay ?? "—") → \(new.shortDisplay)", for: record.id)
				}
				self.mainWindow.removeBanner(id: "certificate")
				guard self.session == nil, !self.isCheckingBoundary, let current = self.hostStore.record(record.id) else {
					self.mainWindow.activeHostID = nil
					return
				}
				self.chainReachedLive = false
				self.beginSession(review.session, record: current, context: context)
			case .failure:
				ConnectChain.log.notice("[connect] the pin could not be written; not connecting")
				self.mainWindow.activeHostID = nil
			}
		}
	}

	/// Gate r1 I-2 (UI slice ①): the App stays running when its last window closes -- the status
	/// item is always there (adr/0022 D-6), the Hosts window comes back through View ▸ Show Hosts,
	/// Open Macdows or a Dock-icon reopen, and a session that ends while the Hosts window is closed
	/// no longer takes the App down with its last remote window.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}

	/// A Dock-icon click (or `open`) with no window on screen brings the Hosts window back.
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if !flag {
			mainWindow.showHosts(nil)
		}
		return true
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

/// adr/0022 D-11 (K3-R): File ▸ Disconnect and the status item's Disconnect are nil-target items
/// whose action is the End-session button's own method (`MainMenu.disconnectAction`); no window
/// implements it, so the responder chain brings them here. They are enabled by the button's own
/// predicate, a session to end, so the two menu items and the button are never in disagreement.
/// Every other item this delegate is asked about keeps AppKit's answer (enabled).
extension AppDelegate: NSMenuItemValidation {
	func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		guard menuItem.action == MainMenu.disconnectAction else { return true }
		return session != nil
	}
}

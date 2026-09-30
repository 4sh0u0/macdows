/*
 * stim-window.c -- parameterless RAIL stimulus for the rail-probe measurement lane.
 *
 * WHAT THIS IS. A tiny, self-contained Win32 GUI program with no command line and no
 * persistent footprint. rail-probe launches it on the lab host as a RemoteApp (one RAIL
 * ClientExecute: program = this .exe's path, arguments field empty, exec flags 0 -- the
 * shape ADR-0021 §5 S1 annotates and rail-probe.c sends for the primary --app via the
 * FreeRDP helper client_rail_server_start_cmd, which populates only
 * FreeRDP_RemoteApplicationProgram). It creates one top-level window (so the server emits a
 * RAIL window-create order the moment it appears -- that order, arriving in the probe's
 * JSONL, IS the stimulus taking effect), holds it visible for a fixed interval, then closes
 * itself and the process exits 0. Nothing is written to disk, the registry, or the task
 * scheduler.
 *
 * It is a MEASUREMENT FIXTURE, not a wrapper around another program. "Parameterless
 * wrapper" is read here as "the parameterless artifact the probe launches"; it deliberately
 * does not shell out to anything else, because a child process or a second window would
 * defeat the clean-exit guarantee below.
 *
 * ---------------------------------------------------------------------------------------
 * HOW IT MEETS THE DELIVERY CONTRACT (the nine requirements, in order):
 *
 *  1. One path, no arguments. RAIL sends exactly one ClientExecute with an empty argument
 *     field and flags 0. This program never reads its command line -- WinMain's lpCmdLine
 *     is explicitly discarded. The only tunables are the two compile-time #defines below;
 *     there is nothing to pass at launch and nothing that a missing argument would break.
 *
 *  2. Runs as the lab account, in the probe's session. The server starts it inside the
 *     RAIL session rail-probe connected to, so it inherits that account's token, working
 *     directory and desktop. It touches only per-session, per-user resources (a window on
 *     the session's desktop) and needs no elevation and no interactive console logon.
 *
 *  3. Launchable by RAIL. Built as a native Win32 .exe (SUBSYSTEM:WINDOWS), which the RDS
 *     server starts by path directly -- the one program shape ADR-0021 marks as PROVEN, as
 *     opposed to .cmd/.bat/.lnk. With fAllowUnlistedRemotePrograms = 1 (host snapshot
 *     2026-09-28) it needs no TSAppAllowList entry. Confirm the launch succeeded by reading
 *     the probe's exec-result for this program (RAIL_EXEC_S_OK = 0; any non-zero is the
 *     server's own error code, e.g. FILE_NOT_FOUND for a bad path).
 *
 *  4. Path shape (the controller-side red-line rules; the string reaches print-plan, B-0
 *     and the docs archive). Install and launch it from a path that is NOT under \Users\,
 *     contains NO whitespace, is NOT IP-shaped, and DOES contain a backslash. Recommended:
 *
 *         C:\Lab\stim-window.exe
 *
 *     Provision C:\Lab once, as the owner/admin (the lab account cannot create a directory
 *     at the drive root), and let it inherit the default C:\ ACL so the lab account gets
 *     Read & Execute. That one-time placement is setup, not runtime state (see req 8).
 *
 *  5/6. Timing. The window is created during WinMain startup, so the create order lands
 *     essentially at launch -- far inside both the delay+300 s witness window and the 420 s
 *     session, and nowhere near the orchestration's `delay + 60 >= D` interceptor. No human
 *     interaction is required for the effect. STIM_VISIBLE_MS then closes the window well
 *     before the session ends (see the knob's own note for the safe ceiling).
 *
 *  7. Self-exit, no residue. A single-shot WM_TIMER fires once, DestroyWindow -> WM_DESTROY
 *     -> PostQuitMessage(0) drains the message loop, and WinMain returns: the process is
 *     gone and no window survives into a later snapshot. The launch does emit RAIL window
 *     events into the JSONL -- that is expected registration, not a problem. There is no
 *     resident thread, timer or handle left behind.
 *
 *  8. No persistent host state. At runtime this program creates no files, writes no registry
 *     keys and registers no scheduled task -- it only draws a window. The m=2 observation
 *     batch therefore needs no cleanup of anything this program wrote; the manual reset
 *     between the two executions and the batch's tail logoff are unaffected by it. (The .exe
 *     living on disk is the pre-placed artifact of req 4, not something the run mutates.)
 *
 *  9. No sensitive output. The window shows only two fixed, benign strings identifying it as
 *     a lab fixture. Nothing from the environment, the session or the account is read or
 *     displayed, so nothing sensitive can reach the KVM screen or the JSONL.
 *
 * ---------------------------------------------------------------------------------------
 * BUILD (produces a no-argument GUI .exe; pick either toolchain):
 *
 *   Cross-compile on the Mac (keeps a compiler off the host):
 *       brew install mingw-w64
 *       x86_64-w64-mingw32-gcc -O2 -mwindows -Wall -Wextra \
 *           -o stim-window.exe stim-window.c -luser32 -lgdi32
 *     (-mwindows selects the GUI subsystem, so there is no console window; this file uses
 *      the ANSI *A APIs and WinMain, so no -municode is needed.)
 *
 *   On the host with the MSVC Build Tools:
 *       cl /O2 stim-window.c /link /SUBSYSTEM:WINDOWS user32.lib gdi32.lib
 *
 * Then copy the resulting stim-window.exe to C:\Lab\ on the host (req 4).
 */

#include <windows.h>

/* ===================================================================================== */
/* The two knobs. Both are compile-time: the RAIL launch carries no arguments (req 1), so */
/* anything adjustable has to be baked in here rather than passed on the command line.    */
/* ===================================================================================== */

/*
 * How long the window stays up before it closes itself, in milliseconds.
 *
 * rail-probe records window orders as they arrive, so BOTH the create and the destroy land
 * in the JSONL regardless of this value; the interval only decides how long the window sits
 * in its steady state (long enough to be caught on a KVM screenshot, short enough to read as
 * transient). 8 s is a deliberate middle.
 *
 * Safe ceiling: the window closes at (connect + second-delay + STIM_VISIBLE_MS/1000). Keep
 * that comfortably below the 420 s session end -- with the default second-delay of 30 s,
 * any value under ~300 s is safe, and staying <= the witness window (delay + 300 s) also
 * keeps the destroy order inside the observed span. Raise it only if a host-side steady-
 * state read is added that needs the window to persist.
 */
#ifndef STIM_VISIBLE_MS
#define STIM_VISIBLE_MS 8000
#endif

/*
 * Deterministic outer-window geometry (frame included; CreateWindow's w/h are the outer
 * rect). Fixed rather than CW_USEDEFAULT so every run of the fixture presents the same
 * rectangle to the geometry measurement, independent of where the session would otherwise
 * place a default window.
 */
#ifndef STIM_X
#define STIM_X 120
#endif
#ifndef STIM_Y
#define STIM_Y 120
#endif
#ifndef STIM_W
#define STIM_W 480
#endif
#ifndef STIM_H
#define STIM_H 320
#endif

#define STIM_CLASS    "MacdowsRailStim"
#define STIM_TITLE    "Macdows RAIL Stimulus"
#define STIM_TIMER_ID 1

static LRESULT CALLBACK StimWndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
	switch (msg)
	{
		case WM_CREATE:
			/* Arm the single-shot self-close. */
			SetTimer(hWnd, STIM_TIMER_ID, STIM_VISIBLE_MS, NULL);
			return 0;

		case WM_TIMER:
			if (wParam == STIM_TIMER_ID)
			{
				KillTimer(hWnd, STIM_TIMER_ID);
				DestroyWindow(hWnd);
			}
			return 0;

		case WM_PAINT:
		{
			PAINTSTRUCT ps;
			HDC hdc = BeginPaint(hWnd, &ps);
			RECT rc;
			static const char line1[] = "RAIL stimulus window (lab measurement fixture).";
			static const char line2[] = "No input needed; this window closes itself.";
			GetClientRect(hWnd, &rc);
			FillRect(hdc, &rc, (HBRUSH)(COLOR_WINDOW + 1));
			SetBkMode(hdc, TRANSPARENT);
			TextOutA(hdc, 16, 16, line1, (int)(sizeof(line1) - 1));
			TextOutA(hdc, 16, 40, line2, (int)(sizeof(line2) - 1));
			EndPaint(hWnd, &ps);
			return 0;
		}

		case WM_DESTROY:
			PostQuitMessage(0);
			return 0;
	}
	return DefWindowProcA(hWnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
	WNDCLASSA wc;
	HWND hWnd;
	MSG m;

	(void)hPrevInstance;
	(void)lpCmdLine; /* Parameterless by contract (req 1): the command line is never read. */
	(void)nCmdShow;  /* Fixed SW_SHOWNORMAL below keeps the presented geometry deterministic. */

	ZeroMemory(&wc, sizeof(wc));
	wc.lpfnWndProc   = StimWndProc;
	wc.hInstance     = hInstance;
	wc.hCursor       = LoadCursor(NULL, IDC_ARROW);
	wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
	wc.lpszClassName = STIM_CLASS;
	if (!RegisterClassA(&wc))
		return 1;

	hWnd = CreateWindowExA(0, STIM_CLASS, STIM_TITLE, WS_OVERLAPPEDWINDOW, STIM_X, STIM_Y,
	                       STIM_W, STIM_H, NULL, NULL, hInstance, NULL);
	if (!hWnd)
		return 1;

	ShowWindow(hWnd, SW_SHOWNORMAL);
	UpdateWindow(hWnd);

	/* Standard modal message loop; GetMessage returns 0 at PostQuitMessage, -1 on error. */
	while (GetMessage(&m, NULL, 0, 0) > 0)
	{
		TranslateMessage(&m);
		DispatchMessage(&m);
	}
	return 0;
}

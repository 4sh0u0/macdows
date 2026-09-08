#!/usr/bin/env python3
"""Offline tests for Scripts/lab/etw_summarize.py -- the redacting summariser for Device Portal
realtime ETW captures (one JSON batch per line).

The fixture here is SYNTHETIC. It has the shape of a real capture (batches of events carrying a
Windows FILETIME and string-valued provider fields) but every name-bearing field value and every
free-text message carries a sentinel string. The central assertions are negative and generic: no
sentinel, and more broadly no non-numeric field value, may reach the tool's stdout -- with or
without --messages. Positive assertions pin the counters, the FILETIME -> UTC conversion, every
digest line, the masking markers and the --top cap, so the negative assertions cannot pass just
because the tool printed nothing.

No network and no lab host is touched: HOME is redirected to an empty temp directory in every
test, so the real $HOME/.config/macdows/host.env is never opened. All addresses are RFC 5737
documentation addresses; the account and secret are the lane's placeholders.

Run:  cd Scripts/lab && python3 -m unittest -v test_etw_summarize
"""
import calendar
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import etw_summarize  # noqa: E402

MODULE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "etw_summarize.py")

# --- fixture vocabulary -------------------------------------------------------------------
ST = "Microsoft.Windows.RemoteDesktop.ServerStack"
CORE = "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS"
RCM = "Microsoft-Windows-TerminalServices-RemoteConnectionManager"

# A localized TaskName, as RdpCoreTS really emits (kept as escapes so this source stays ASCII).
TASK_LOCALIZED = "RemoteFX \u6a21\u5757 "

# Sentinels: none of these may ever appear on stdout.
S_HOST = "SENTINEL-HOST-9f3a"
S_ACTIVITY = "SENTINEL-ACTIVITY-2b71"
S_RELATED = "SENTINEL-RELATED-6c02"
S_CHANNEL = "SENTINEL-CHANNEL-c40d"
S_SID = "SENTINEL-SID-77aa"
S_FUNC = "SENTINEL-FUNC-1d2e"
S_TRANSPORT = "SENTINEL-TRANSPORT-8e55"
S_RAW = "SENTINEL-RAW-0c19"
S_IPV4 = "192.0.2.77"
S_IPV6 = "2001:db8::77"
S_UNC = "\\\\SENTINEL-SRV\\share"
S_USERPATH = "C:\\Users\\SENTINEL-USER"
SENTINELS = [
    S_HOST, S_ACTIVITY, S_RELATED, S_CHANNEL, S_SID, S_FUNC, S_TRANSPORT, S_RAW,
    S_IPV4, S_IPV6, S_UNC, S_USERPATH, "SENTINEL-SRV", "SENTINEL-USER",
]

META = (
    "ActivityId", "RelatedActivityId", "ID", "Keyword", "Level", "OpCode",
    "ProcessId", "ThreadId", "ProviderName", "TaskName", "Timestamp",
)

BASE_EPOCH = calendar.timegm((2026, 9, 8, 12, 0, 0, 0, 0, 0))  # 2026-09-08T12:00:00Z
BASE_FILETIME = (BASE_EPOCH + 11644473600) * 10 ** 7
FIRST_UTC = "2026-09-08T12:00:00.000000Z"
LAST_UTC = "2026-09-08T12:00:03.600000Z"


def ft(offset):
    """FILETIME (100 ns since 1601-01-01 UTC) `offset` seconds after the fixture's base time."""
    return BASE_FILETIME + int(round(offset * 10 ** 7))


def q(text):
    """ServerStack's `msg` values arrive with their double quotes included."""
    return '"' + text + '"'


def ev(provider, task, ident, level, ts, **fields):
    event = {
        "ActivityId": S_ACTIVITY,
        "RelatedActivityId": S_RELATED,
        "ID": ident,
        "Keyword": 0,
        "Level": level,
        "OpCode": 0,
        "ProcessId": 1234,
        "ThreadId": 5678,
        "ProviderName": provider,
        "TaskName": task,
    }
    if ts is not None:
        event["Timestamp"] = ts
    event.update(fields)
    return event


def batch(events, frequency=10000000):
    return json.dumps({"Frequency": frequency, "Events": events})


B1 = [
    ev(ST, "ServerGfxProvider", 0, 4, ft(0.0), msg=q("Using RemoteAppDownsampling (0=Off, 1=On)"),
       Enabled="1", ServerName=S_HOST, function=S_FUNC),
    # Same field name, different message: must NOT be read as RemoteAppDownsampling.
    ev(ST, "ServerGfxPlugin", 0, 4, ft(0.05), msg=q("Using SomeOtherToggle (0=Off, 1=On)"),
       Enabled="0"),
    ev(ST, "ServerGfxProvider", 0, 4, ft(0.1), msg=q("Using MinDownSamplDesktopScale"),
       MinDownSampleDesktopScale="200"),
    ev(ST, "ServerGfxProvider", 0, 4, ft(0.2), msg=q("Using MaxDownSamplDesktopScale"),
       MaxDownSampleDesktopScale="300"),
    ev(ST, "ServerGfxProvider", 0, 4, ft(0.3),
       msg=q("Using DownsampleInterpolationMode (0=NN,1=Lin,2=Cubic,3=Fant)"),
       InterpolationMode="1"),
    ev(ST, "ServerGfxProvider", 0, 4, ft(0.4), msg=q("Using DownsampleHardwareMode (0=Off, 1=On)"),
       HardwareMode="1"),
    ev(ST, "ServerGfxProvider", 0, 4, ft(0.5), msg=q("WDDM IDD mode (0=Off, 1=On)"), IddMode="1"),
]

B2 = [
    ev(ST, "ServerGfxProvider", 0, 4, ft(1.0), msg=q("Created new output layout"),
       Width="2560", Height="1440", NumberOfMonitors="1"),
    ev(ST, "ServerGfxProvider", 0, 4, ft(1.1), msg=q("New virtual desktop"),
       Width="2560", Height="1440", X="0", Y="0"),
    ev(ST, "ServerGfxProvider", 0, 4, ft(1.2), msg=q("Surface mapped"), Id="1", Width="2560",
       Height="1440", Size="14745600", DownSampled="0", DownSampledWidth="0",
       DownSampledHeight="0"),
    ev(CORE, TASK_LOCALIZED, 168, 5, ft(2.0), Message="Failed to format message", MonitorNum="0",
       MonitorWidth="2560", MonitorHeight="1440", MonitorX="0", MonitorY="0", ServerName=S_HOST),
    ev(CORE, "RemoteFX Graphics", 162, 5, ft(2.1), Message="Failed to format message",
       Version="657153", ClientMode="2", AvcEnabled="0", ProfileIdNum="2", ServerName=S_HOST),
    ev(CORE, "TSSession", 66, 5, ft(2.2), Message="Failed to format message", SessionID="2",
       ConnectionName=S_CHANNEL),
]

B3 = [
    ev(ST, "ProtProvSessionCreated", 0, 4, ft(3.0), SessionId="2", SID=S_SID),
    ev(ST, "ProtProvSessionReconnect", 0, 4, ft(3.1), SessionId="2", DoReconnect="false"),
    ev(ST, "ProtProvDisconnected", 0, 4, ft(3.2), SessionId="2", Reason="13"),
    ev(ST, "ServerGfxProvider", 0, 4, ft(3.3), msg=q("First non-black frame processed for session"),
       SessionId="2"),
    ev(ST, "ServerConnection", 0, 4, ft(3.4), WinlogonStatusCode="0", ClientErrorCode="0xFFFFFFFB",
       DiagnosticCode="0", DisconnectReason="2", ConnectionName=S_CHANNEL),
    ev(CORE, "TSTransport", 135, 5, ft(3.5), Message="Failed to format message",
       TransportType=S_TRANSPORT, TunnelID="3"),
    # No Timestamp at all: the digest line must degrade to t=?.
    ev(ST, "ServerGfxProvider", 0, 4, None, msg=q("Surface mapped"), Id="2", Width="1280",
       Height="720", DownSampled="1", DownSampledWidth="1280", DownSampledHeight="720"),
    ev(ST, "ServerGfxPlugin", 0, 4, ft(3.6),
       msg=q("Client " + S_IPV4 + " and " + S_IPV6 + " opened " + S_UNC + " as " + S_USERPATH)),
]

FIXTURE_EVENTS = B1 + B2 + B3
FIXTURE_LINES = [
    batch(B1),
    batch(B2),
    json.dumps({"raw": "unparsable portal text " + S_RAW}),
    "",
    batch(B3),
    "not-json-at-all",
]


def write_lines(directory, name, lines):
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as handle:
        for line in lines:
            handle.write(line + "\n")
    return path


class SummarizerTestCase(unittest.TestCase):
    """Base: a temp dir, an isolated HOME (so the real host.env is never read) and a runner."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name
        self.home = os.path.join(self.dir, "home")
        os.makedirs(self.home)
        self.env = {"HOME": self.home}
        self.fixture = write_lines(self.dir, "etw-fixture.jsonl", FIXTURE_LINES)

    def run_tool(self, args, env=None):
        out = io.StringIO()
        err = io.StringIO()
        rc = etw_summarize.main(args, stdout=out, stderr=err,
                                environ=self.env if env is None else env)
        return rc, out.getvalue(), err.getvalue()

    def summary(self, args=None, env=None):
        rc, out, err = self.run_tool((args or []) + [self.fixture], env=env)
        self.assertEqual(rc, 0, "unexpected rc, stderr=%r" % err)
        return out

    def write_host_env(self, body):
        directory = os.path.join(self.home, ".config", "macdows")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "host.env")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        return path


class RedactionTest(SummarizerTestCase):
    """The point of the tool: the output is paste-safe by construction."""

    def test_no_sentinel_in_output_without_messages(self):
        out = self.summary()
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, out)

    def test_no_sentinel_in_output_with_messages(self):
        out = self.summary(["--messages"])
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, out)

    def test_no_non_numeric_field_value_is_ever_printed(self):
        """Generic form of the rule: for every event field that is not meta and not a message,
        a non-numeric value must not appear anywhere on stdout."""
        plain = self.summary()
        with_messages = self.summary(["--messages"])
        checked = 0
        for event in FIXTURE_EVENTS:
            for name, value in event.items():
                if name in META or name in ("msg", "Message"):
                    continue
                if etw_summarize.is_numeric(value):
                    continue
                checked += 1
                self.assertNotIn(value, plain, "leaked %s" % name)
                self.assertNotIn(value, with_messages, "leaked %s" % name)
        self.assertGreaterEqual(checked, 6, "fixture lost its non-numeric field values")

    def test_message_templates_are_withheld_unless_asked(self):
        out = self.summary()
        self.assertNotIn("(0=Off, 1=On)", out)
        self.assertNotIn("Failed to format message", out)
        self.assertNotIn("messages:", out)

    def test_messages_section_is_masked(self):
        out = self.summary(["--messages"])
        self.assertIn("messages:", out)
        self.assertIn("Client <ipv4> and <ipv6> opened \\\\<unc> as C:\\Users\\<user>", out)
        self.assertIn("Failed to format message", out)

    def test_a_message_cannot_forge_an_output_line(self):
        """Capture text is data, never layout: control characters fold to spaces, so a message
        carrying a newline cannot add a line that reads like a digest line."""
        forged = "real\nsession: t=+9.999 FORGED SessionId=7\tend"
        path = write_lines(self.dir, "forged.jsonl",
                           [batch([ev(ST, "ServerGfxPlugin", 0, 4, ft(0.0), msg=q(forged))])])
        rc, out, err = self.run_tool(["--messages", path])
        self.assertEqual(rc, 0, err)
        self.assertIn("  1  real session: t=+9.999 FORGED SessionId=7 end\n", out)
        for line in out.splitlines():
            self.assertFalse(line.startswith("session:"), line)

    def test_message_quotes_are_stripped(self):
        out = self.summary(["--messages"])
        self.assertIn("  1  Created new output layout", out)
        self.assertNotIn('"Created new output layout"', out)


class HeaderTest(SummarizerTestCase):

    def test_header_counts_and_filetime_conversion(self):
        out = self.summary()
        self.assertIn(
            "etw-summary: files=1 frames=3 raw_frames=1 events=21 span=3.600s "
            "first=%s last=%s" % (FIRST_UTC, LAST_UTC),
            out,
        )

    def test_unparsable_line_is_counted_and_skipped(self):
        out = self.summary()
        self.assertIn("note: skipped 1 unparsable line(s)", out)

    def test_two_files_are_aggregated(self):
        second = write_lines(self.dir, "second.jsonl", [batch(B1)])
        rc, out, err = self.run_tool([self.fixture, second])
        self.assertEqual(rc, 0, err)
        self.assertIn("files=2 frames=4 raw_frames=1 events=28", out)

    def test_empty_file(self):
        empty = write_lines(self.dir, "empty.jsonl", [])
        rc, out, err = self.run_tool([empty])
        self.assertEqual(rc, 0, err)
        self.assertIn("etw-summary: files=1 frames=0 raw_frames=0 events=0 span=? first=? last=?",
                      out)
        self.assertIn("downsampling: RemoteAppDownsampling=? min=? max=? interpolation=? "
                      "hardware=? idd=?", out)

    def test_unreadable_file_is_a_noinput_error_and_prints_nothing(self):
        missing = os.path.join(self.dir, "nope.jsonl")
        rc, out, err = self.run_tool([missing])
        self.assertEqual(rc, etw_summarize.EX_NOINPUT)
        self.assertEqual(out, "")
        self.assertIn("cannot read", err)

    def test_no_file_argument_is_a_usage_error(self):
        rc, out, err = self.run_tool([])
        self.assertEqual(rc, etw_summarize.EX_USAGE)
        self.assertEqual(out, "")

    def test_non_positive_top_is_a_usage_error(self):
        rc, out, err = self.run_tool(["--top", "0", self.fixture])
        self.assertEqual(rc, etw_summarize.EX_USAGE)
        self.assertEqual(out, "")


class SectionsTest(SummarizerTestCase):

    def test_providers(self):
        out = self.summary()
        self.assertIn("providers:\n  17  " + ST + "\n  4  " + CORE + "\n", out)

    def test_levels(self):
        out = self.summary()
        self.assertIn("levels:\n  17  level=4\n  4  level=5\n", out)

    def test_tasks_top_line_and_provider_short_name(self):
        out = self.summary()
        self.assertIn("tasks:\n  11  ServerStack id=0 task=ServerGfxProvider level=4\n", out)
        self.assertIn("  1  RdpCoreTS id=168 task=RemoteFX \u6a21\u5757 level=5\n", out)
        self.assertIn("  1  RdpCoreTS id=66 task=TSSession level=5\n", out)

    def test_top_caps_tasks_and_messages(self):
        out = self.summary(["--messages", "--top", "2"])
        tasks = self.section(out, "tasks:")
        self.assertEqual(len(tasks), 2, tasks)
        messages = self.section(out, "messages:")
        self.assertEqual(len(messages), 2, messages)
        self.assertEqual(messages[0], "  4  Failed to format message")
        self.assertEqual(messages[1], "  2  Surface mapped")

    def test_fields_lists_names_only(self):
        out = self.summary()
        self.assertIn("fields:\n", out)
        self.assertIn("  RdpCoreTS task=RemoteFX \u6a21\u5757: Message, MonitorHeight, MonitorNum, "
                      "MonitorWidth, MonitorX, MonitorY, ServerName\n", out)
        self.assertIn("  RdpCoreTS task=TSTransport: Message, TransportType, TunnelID\n", out)

    def section(self, out, header):
        """The indented body lines that follow `header` up to the next unindented line."""
        lines = out.splitlines()
        start = lines.index(header) + 1
        body = []
        for line in lines[start:]:
            if not line.startswith("  "):
                break
            body.append(line)
        return body


class DigestTest(SummarizerTestCase):

    def test_downsampling_matches_on_the_message_not_the_field(self):
        out = self.summary()
        self.assertIn("downsampling: RemoteAppDownsampling=1 min=200 max=300 interpolation=1 "
                      "hardware=1 idd=1\n", out)

    def test_surface(self):
        out = self.summary()
        self.assertIn("surface: t=+1.200 id=1 2560x1440 DownSampled=0 DownSampledWidth=0 "
                      "DownSampledHeight=0\n", out)

    def test_surface_without_timestamp(self):
        out = self.summary()
        self.assertIn("surface: t=? id=2 1280x720 DownSampled=1 DownSampledWidth=1280 "
                      "DownSampledHeight=720\n", out)

    def test_layout_and_desktop(self):
        out = self.summary()
        self.assertIn("layout: t=+1.000 2560x1440 monitors=1\n", out)
        self.assertIn("desktop: t=+1.100 2560x1440@0,0\n", out)

    def test_monitor168(self):
        out = self.summary()
        self.assertIn("monitor168: t=+2.000 num=0 2560x1440@0,0\n", out)

    def test_gfx162_and_session66(self):
        out = self.summary()
        self.assertIn("gfx162: t=+2.100 Version=657153 ClientMode=2 AvcEnabled=0 ProfileIdNum=2\n",
                      out)
        self.assertIn("session66: t=+2.200 SessionID=2\n", out)

    def test_session_lines(self):
        out = self.summary()
        self.assertIn("session: t=+3.000 ProtProvSessionCreated SessionId=2\n", out)
        self.assertIn("session: t=+3.100 ProtProvSessionReconnect SessionId=2 DoReconnect=false\n",
                      out)
        self.assertIn("session: t=+3.200 ProtProvDisconnected SessionId=2 Reason=13\n", out)
        self.assertIn("session: t=+3.300 ServerGfxProvider SessionId=2\n", out)

    def test_connection_line(self):
        out = self.summary()
        self.assertIn("connection: t=+3.400 WinlogonStatusCode=0 ClientErrorCode=0xFFFFFFFB "
                      "DiagnosticCode=0\n", out)

    def test_absent_field_renders_question_mark(self):
        line = batch([ev(ST, "ServerGfxProvider", 0, 4, ft(0.0), msg=q("Created new output layout"),
                         Width="800", Height="600")])
        path = write_lines(self.dir, "partial.jsonl", [line])
        rc, out, err = self.run_tool([path])
        self.assertEqual(rc, 0, err)
        self.assertIn("layout: t=+0.000 800x600 monitors=?\n", out)

    def test_non_numeric_value_renders_question_mark(self):
        line = batch([ev(CORE, "TSSession", 66, 5, ft(0.0), SessionID="not-a-number")])
        path = write_lines(self.dir, "weird.jsonl", [line])
        rc, out, err = self.run_tool([path])
        self.assertEqual(rc, 0, err)
        self.assertIn("session66: t=+0.000 SessionID=?\n", out)
        self.assertNotIn("not-a-number", out)


class MaskingTest(SummarizerTestCase):

    def masked(self, text, environ=None):
        return etw_summarize.build_masker(environ or self.env).mask(text)

    def test_ipv4_ipv6_unc_and_user_path(self):
        self.assertEqual(self.masked("a 192.0.2.77 b"), "a <ipv4> b")
        self.assertEqual(self.masked("a 2001:db8::77 b"), "a <ipv6> b")
        self.assertEqual(self.masked("a \\\\SRVNAME\\share\\x b"), "a \\\\<unc> b")
        self.assertEqual(self.masked("a C:\\Users\\somebody b"), "a C:\\Users\\<user> b")
        self.assertEqual(self.masked("a d:\\users\\Somebody\\x b"), "a C:\\Users\\<user>\\x b")

    def test_control_characters_fold_to_single_spaces(self):
        self.assertEqual(self.masked("a\nb\tc\r\n  d "), "a b c d")
        # Non-whitespace controls too: a capture string may carry an ANSI escape or a NUL, and
        # the summary is read in a terminal.
        self.assertEqual(self.masked("a\x1b[31mred\x00b\x7f"), "a [31mred b")

    def test_clock_like_text_is_not_mistaken_for_ipv6(self):
        self.assertEqual(self.masked("took 10:20 s"), "took 10:20 s")

    def test_env_mask_tokens(self):
        env = dict(self.env)
        env["ETW_MASK_TOKENS"] = "SENTINEL-TOKEN-4a11;;other-token"
        self.assertEqual(self.masked("x sentinel-token-4A11 y OTHER-TOKEN z", env),
                         "x <redacted> y <redacted> z")

    def test_host_env_values_are_masked_case_insensitively(self):
        self.write_host_env('WIN_HOST="192.0.2.10"\nWIN_USER=labtest-placeholder\n'
                            'WIN_PASS=LABTEST-PLACEHOLDER-SECRET-3f9a\n')
        masked = self.masked("host 192.0.2.10 user LABTEST-Placeholder")
        self.assertEqual(masked, "host <redacted> user <redacted>")

    def test_missing_host_env_is_silent(self):
        self.assertEqual(self.masked("plain text"), "plain text")

    def test_host_env_masking_end_to_end(self):
        self.write_host_env("WIN_HOST=192.0.2.10\nWIN_USER=labtest-placeholder\n"
                            "WIN_PASS=LABTEST-PLACEHOLDER-SECRET-3f9a\n")
        line = batch([ev(ST, "ServerGfxPlugin", 0, 4, ft(0.0),
                         msg=q("session for labtest-placeholder from 192.0.2.10"))])
        path = write_lines(self.dir, "hostenv.jsonl", [line])
        rc, out, err = self.run_tool(["--messages", path])
        self.assertEqual(rc, 0, err)
        self.assertIn("session for <redacted> from <redacted>", out)
        self.assertNotIn("labtest-placeholder", out)
        self.assertNotIn("192.0.2.10", out)
        self.assertNotIn("LABTEST-PLACEHOLDER-SECRET-3f9a", out)

    def test_long_message_is_truncated(self):
        long_text = "A" * (etw_summarize.MAX_MESSAGE_CHARS + 50)
        masked = self.masked(long_text)
        self.assertEqual(len(masked), etw_summarize.MAX_MESSAGE_CHARS + 3)
        self.assertTrue(masked.endswith("..."))


class MalformedInputTest(SummarizerTestCase):
    """A capture is written by a portal, not by this repo: odd lines must degrade, not crash."""

    def summarise(self, lines, args=None):
        path = write_lines(self.dir, "odd.jsonl", lines)
        rc, out, err = self.run_tool((args or []) + [path])
        self.assertEqual(rc, 0, err)
        return out

    def test_a_json_array_line_is_not_a_batch(self):
        out = self.summarise(["[1, 2, 3]"])
        self.assertIn("frames=0 raw_frames=0 events=0", out)
        self.assertIn("note: skipped 1 unparsable line(s)", out)

    def test_a_batch_without_events_is_still_a_frame(self):
        out = self.summarise([json.dumps({"Frequency": 10000000})])
        self.assertIn("frames=1 raw_frames=0 events=0", out)
        self.assertNotIn("note:", out)

    def test_stringified_meta_integers_are_understood(self):
        event = ev(CORE, "TSMonitor", "168", "5", str(ft(0.0)), MonitorNum="0",
                   MonitorWidth="800", MonitorHeight="600", MonitorX="0", MonitorY="0")
        out = self.summarise([batch([event])])
        self.assertIn("monitor168: t=+0.000 num=0 800x600@0,0\n", out)
        self.assertIn("  1  RdpCoreTS id=168 task=TSMonitor level=5\n", out)

    def test_event_without_payload_fields(self):
        out = self.summarise([batch([ev(ST, "EmptyTask", 0, 4, ft(0.0))])])
        self.assertIn("  ServerStack task=EmptyTask: -\n", out)

    def test_missing_level_renders_question_mark(self):
        event = ev(ST, "EmptyTask", 0, 4, ft(0.0))
        del event["Level"]
        out = self.summarise([batch([event])])
        self.assertIn("  1  level=?\n", out)
        self.assertIn("  1  ServerStack id=0 task=EmptyTask level=?\n", out)

    def test_unknown_flag_is_a_usage_error(self):
        stderr = io.StringIO()
        saved = sys.stderr
        sys.stderr = stderr  # argparse writes its own error to the process stderr
        try:
            rc, out, err = self.run_tool(["--nope", self.fixture])
        finally:
            sys.stderr = saved
        self.assertEqual(rc, etw_summarize.EX_USAGE)
        self.assertEqual(out, "")


class PrimitivesTest(unittest.TestCase):

    def test_is_numeric(self):
        for good in ("0", "-3", "2.5", "0xFFFFFFFB", "true", "FALSE", 7, 2.5, True):
            self.assertTrue(etw_summarize.is_numeric(good), good)
        for bad in ("", "1.2.3", "0x", "2560x1440", "yes", S_HOST, "198.51.100.9", None, []):
            self.assertFalse(etw_summarize.is_numeric(bad), bad)

    def test_render_numeric(self):
        self.assertEqual(etw_summarize.render_numeric({"a": "0x1F"}, "a"), "0x1F")
        self.assertEqual(etw_summarize.render_numeric({"a": True}, "a"), "true")
        self.assertEqual(etw_summarize.render_numeric({"a": 12}, "a"), "12")
        self.assertEqual(etw_summarize.render_numeric({"a": "x"}, "a"), "?")
        self.assertEqual(etw_summarize.render_numeric({}, "a"), "?")

    def test_provider_short(self):
        self.assertEqual(etw_summarize.provider_short(ST), "ServerStack")
        self.assertEqual(etw_summarize.provider_short(CORE), "RdpCoreTS")
        self.assertEqual(etw_summarize.provider_short(RCM), "RemoteConnectionManager")
        self.assertEqual(etw_summarize.provider_short(""), "?")

    def test_filetime_conversion(self):
        self.assertEqual(etw_summarize.format_filetime(BASE_FILETIME, 10000000), FIRST_UTC)
        # A non-default Frequency is used as the divisor.
        self.assertEqual(etw_summarize.format_filetime((BASE_EPOCH + 11644473600) * 1000, 1000),
                         FIRST_UTC)

    def test_strip_quotes(self):
        self.assertEqual(etw_summarize.strip_quotes('"hello"'), "hello")
        self.assertEqual(etw_summarize.strip_quotes('hello'), "hello")
        self.assertEqual(etw_summarize.strip_quotes('"'), '"')


class ScriptEntryPointTest(SummarizerTestCase):

    def test_runs_as_a_script(self):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""),
               "PYTHONIOENCODING": "utf-8"}
        proc = subprocess.run([sys.executable, MODULE_PATH, self.fixture],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        out = proc.stdout.decode("utf-8")
        self.assertEqual(proc.returncode, 0, proc.stderr.decode("utf-8"))
        self.assertIn("etw-summary: files=1 frames=3 raw_frames=1 events=21", out)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, out)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Redacting summariser for Device Portal realtime ETW captures.

    python3 etw_summarize.py [--messages] [--top N] FILE...

Input is one or more JSONL capture files as written by Scripts/lab/wdp_etw.py: one JSON batch
per line, `{"Frequency": 10000000, "Events": [ ... ]}`, plus `{"raw": "..."}` lines for portal
text that was not a JSON object. Output is plain text on stdout.

REDACTION RULE (the reason this tool exists). A capture is full of names and addresses --
ServerName, ConnectionName, ClientIP, ChannelName, SID, function/file, correlation ids -- so the
raw JSONL must never be committed or pasted. This summariser is safe to paste BY CONSTRUCTION:
the only things it prints are

  * literal text of its own,
  * structural identifiers from the capture schema: ProviderName, TaskName, event ID, Level and
    field NAMES (never their values),
  * field VALUES that pass the numeric test `^(0x[0-9A-Fa-f]+|-?\\d+(\\.\\d+)?|true|false)$`
    (case-insensitive) -- anything else, and anything absent, prints as `?`,
  * counts and times derived from the above,
  * and, only under --messages, the fixed English `msg`/`Message` templates, after masking.

Masking (applied to messages and to the structural identifiers alike): IPv4 literals -> <ipv4>,
IPv6 literals -> <ipv6>, UNC paths -> \\\\<unc>, `X:\\Users\\<name>` -> `C:\\Users\\<user>`, and
every token of $ETW_MASK_TOKENS (`;`-separated) plus the WIN_HOST / WIN_USER values of
$HOME/.config/macdows/host.env when that file is readable -> <redacted> (case-insensitive; a
missing file is silently fine and the token values themselves are never printed). Control
characters are folded to spaces and messages are truncated, so no capture text can forge a line.
Masking is pattern-based, which is exactly why --messages is opt-in: a name that matches none of
the shapes above and is not named in ETW_MASK_TOKENS would survive into a message line. Without
the flag no message text is printed at all, and no field value has ever been printable.
Messages are counted AFTER masking, so two messages differing only in an address collapse into
one line with a count of two.

Timestamps are Windows FILETIMEs (100 ns units since 1601-01-01 UTC); the batch's `Frequency` is
the divisor (1e7 in every capture seen so far). `t=+<s>` in the digest is seconds after the
earliest event of the run; an event without a usable Timestamp prints `t=?`.

Sections, in order: the `etw-summary:` header, `providers:`, `levels:`, `tasks:` (top N), the
pre-registration digest (`downsampling:`, `surface:`, `layout:`, `desktop:`, `monitor168:`,
`gfx162:`, `session66:`, `session:`, `connection:`), `fields:`, and `messages:` with --messages.

Exit codes: 0 ok, 64 usage, 66 an input file could not be read (nothing is printed in that case).
"""
import argparse
import collections
import datetime
import json
import os
import re
import sys

EX_OK = 0
EX_USAGE = 64
EX_NOINPUT = 66

DEFAULT_TOP = 20
DEFAULT_FREQUENCY = 10000000
MAX_MESSAGE_CHARS = 200
MAX_LABEL_CHARS = 80

FILETIME_EPOCH = datetime.datetime(1601, 1, 1, tzinfo=datetime.timezone.utc)

# Per-event bookkeeping written by the ETW pipeline itself, not provider payload. ActivityId and
# RelatedActivityId are correlation ids and are deliberately in here: they are never printed.
META_FIELDS = frozenset((
    "ActivityId", "RelatedActivityId", "ID", "Keyword", "Level", "OpCode",
    "ProcessId", "ThreadId", "ProviderName", "TaskName", "Timestamp",
))
MESSAGE_FIELDS = ("msg", "Message")

NUMERIC_RE = re.compile(r"(?:0x[0-9A-Fa-f]+|-?\d+(?:\.\d+)?|true|false)\Z", re.IGNORECASE)

# UNC: two backslashes, a host, then the rest of the path up to whitespace.
UNC_RE = re.compile(r"\\\\[^\s\\]+(?:\\[^\s]*)?")
# A Windows profile directory on any drive, in any case; only the name segment is replaced.
USER_PATH_RE = re.compile(r"[A-Za-z]:\\Users\\[^\\\s]+", re.IGNORECASE)
IPV4_RE = re.compile(r"(?<![\w.])\d{1,3}(?:\.\d{1,3}){3}(?![\w.])")
# Two shapes, both anchored by lookarounds so a hex run or a word is not sliced up:
# four or more explicit hextets, or any `::` compressed form. A two-group `12:34` (a clock, a
# ratio) matches neither, which keeps the false-positive rate down without weakening the rule.
IPV6_RE = re.compile(
    r"(?<![0-9A-Za-z:.])"
    r"(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){3,7}"
    r"|(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?)"
    r"(?![0-9A-Za-z:.])"
)
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
WHITESPACE_RE = re.compile(r"\s+")

HOST_ENV_RELPATH = os.path.join(".config", "macdows", "host.env")
HOST_ENV_KEYS = ("WIN_HOST", "WIN_USER")
MIN_TOKEN_CHARS = 3

ABSENT = "?"


# --------------------------------------------------------------------------- primitives

def is_numeric(value):
    """True when `value` may be printed verbatim (the redaction rule's only value class)."""
    if isinstance(value, bool):
        return True
    if isinstance(value, (int, float)):
        return True
    if isinstance(value, str):
        return NUMERIC_RE.match(value) is not None
    return False


def render_numeric(fields, name):
    """`fields[name]` if it is numeric, else `?` -- absent and non-numeric look the same on
    purpose: neither may be printed, and the reader is told only that there is no number."""
    if name not in fields:
        return ABSENT
    value = fields[name]
    if not is_numeric(value):
        return ABSENT
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def as_int(value):
    """The meta ints arrive as ints, but a capture that stringified them still has to work."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value.strip(), 0)
        except ValueError:
            return None
    return None


def provider_short(name):
    """`Microsoft-Windows-...-RdpCoreTS` -> `RdpCoreTS`: the text after the last `.` or `-`."""
    text = (name or "").strip()
    cut = max(text.rfind("."), text.rfind("-"))
    short = text[cut + 1:] if cut >= 0 else text
    return short or ABSENT


def strip_quotes(text):
    """ServerStack's `msg` values carry their own double quotes; manifest `Message` does not."""
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        return text[1:-1]
    return text


def filetime_to_epoch(timestamp, frequency):
    """FILETIME -> POSIX seconds as a float (used for spans and relative times)."""
    freq = frequency if frequency else DEFAULT_FREQUENCY
    return timestamp / float(freq) - 11644473600.0


def format_filetime(timestamp, frequency):
    """FILETIME -> UTC ISO 8601 with microseconds, by integer arithmetic so the printed instant
    is exact rather than rounded through a float."""
    freq = int(frequency) if frequency else DEFAULT_FREQUENCY
    if freq <= 0:
        freq = DEFAULT_FREQUENCY
    seconds, remainder = divmod(int(timestamp), freq)
    micros = remainder * 1000000 // freq
    moment = FILETIME_EPOCH + datetime.timedelta(seconds=seconds, microseconds=micros)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


# --------------------------------------------------------------------------- masking

class Masker(object):
    """Rewrites capture text into something that may be pasted into a document."""

    def __init__(self, tokens=()):
        self.tokens = sorted({t for t in tokens if t and len(t) >= MIN_TOKEN_CHARS},
                             key=len, reverse=True)
        self._tokens_re = None
        if self.tokens:
            self._tokens_re = re.compile("|".join(re.escape(t) for t in self.tokens),
                                         re.IGNORECASE)

    def mask(self, text, limit=MAX_MESSAGE_CHARS):
        masked = CONTROL_RE.sub(" ", text)
        if self._tokens_re is not None:
            masked = self._tokens_re.sub("<redacted>", masked)
        masked = UNC_RE.sub("\\\\\\\\<unc>", masked)
        masked = USER_PATH_RE.sub("C:\\\\Users\\\\<user>", masked)
        masked = IPV4_RE.sub("<ipv4>", masked)
        masked = IPV6_RE.sub("<ipv6>", masked)
        masked = WHITESPACE_RE.sub(" ", masked).strip()
        if limit is not None and len(masked) > limit:
            masked = masked[:limit] + "..."
        return masked

    def label(self, text):
        """A structural identifier (provider, task, field name) cleaned for one output line."""
        cleaned = self.mask(text or "", limit=MAX_LABEL_CHARS)
        return cleaned or ABSENT


def read_host_env_tokens(path):
    """WIN_HOST / WIN_USER out of the lab's host.env. Unreadable or missing is silently fine --
    the file is the operator's, not the tool's, and its values are only ever used as needles."""
    tokens = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                stripped = line.strip()
                if stripped.startswith("export "):
                    stripped = stripped[len("export "):].strip()
                if "=" not in stripped or stripped.startswith("#"):
                    continue
                key, _, value = stripped.partition("=")
                if key.strip() not in HOST_ENV_KEYS:
                    continue
                value = value.strip().strip("\r").strip('"').strip("'").strip()
                if value:
                    tokens.append(value)
    except OSError:
        return []
    return tokens


def build_masker(environ=None):
    env = os.environ if environ is None else environ
    tokens = [t.strip() for t in env.get("ETW_MASK_TOKENS", "").split(";")]
    home = env.get("HOME", "")
    if home:
        tokens.extend(read_host_env_tokens(os.path.join(home, HOST_ENV_RELPATH)))
    return Masker(tokens)


# --------------------------------------------------------------------------- capture model

class Event(object):
    __slots__ = ("provider", "short", "task", "ident", "level", "fields", "message",
                 "timestamp", "frequency", "epoch")

    def __init__(self, raw, frequency):
        self.provider = raw.get("ProviderName", "")
        self.short = provider_short(self.provider)
        self.task = raw.get("TaskName", "")
        self.ident = as_int(raw.get("ID"))
        self.level = as_int(raw.get("Level"))
        self.frequency = frequency
        self.timestamp = as_int(raw.get("Timestamp"))
        self.epoch = None
        if self.timestamp is not None:
            self.epoch = filetime_to_epoch(self.timestamp, frequency)
        self.fields = {k: v for k, v in raw.items() if k not in META_FIELDS}
        self.message = None
        for name in MESSAGE_FIELDS:
            value = raw.get(name)
            if isinstance(value, str) and value.strip():
                self.message = strip_quotes(value.strip()).strip()
                break

    def starts_with(self, prefix):
        return self.message is not None and self.message.startswith(prefix)

    def num(self, name):
        return render_numeric(self.fields, name)


# Digest groups, emitted in this order; within a group, events keep their read order.
GROUP_SURFACE, GROUP_LAYOUT, GROUP_DESKTOP, GROUP_MONITOR, GROUP_GFX, GROUP_SESSION66, \
    GROUP_SESSION, GROUP_CONNECTION = range(8)


class Summary(object):
    """Accumulates counters and the (few) digest records, then renders the report at the end.

    Only digest records are kept, never the events, so a multi-hour capture costs a constant
    amount of memory.
    """

    def __init__(self, masker, top=DEFAULT_TOP, show_messages=False):
        self.masker = masker
        self.top = top
        self.show_messages = show_messages
        self.files = 0
        self.frames = 0
        self.raw_frames = 0
        self.events = 0
        self.bad_lines = 0
        self.first = None       # (epoch, timestamp, frequency)
        self.last = None
        self.providers = collections.Counter()
        self.levels = collections.Counter()
        self.tasks = collections.Counter()
        self.messages = collections.Counter()
        self.field_names = collections.defaultdict(set)
        self.records = []       # (group, sequence, label, epoch, payload)
        self.downsampling = collections.OrderedDict(
            (("RemoteAppDownsampling", ABSENT), ("min", ABSENT), ("max", ABSENT),
             ("interpolation", ABSENT), ("hardware", ABSENT), ("idd", ABSENT)))

    # -- ingestion ---------------------------------------------------------

    def add_file(self, handle):
        self.files += 1
        for line in handle:
            self.add_line(line)

    def add_line(self, line):
        text = line.strip()
        if not text:
            return
        try:
            parsed = json.loads(text)
        except ValueError:
            self.bad_lines += 1
            return
        if not isinstance(parsed, dict):
            self.bad_lines += 1
            return
        if "raw" in parsed:
            self.raw_frames += 1
            return
        self.frames += 1
        frequency = as_int(parsed.get("Frequency")) or DEFAULT_FREQUENCY
        events = parsed.get("Events")
        if not isinstance(events, list):
            return
        for raw in events:
            if isinstance(raw, dict):
                self.add_event(Event(raw, frequency))

    def add_event(self, event):
        self.events += 1
        self._note_time(event)
        self.providers[event.provider] += 1
        self.levels[event.level] += 1
        self.tasks[(event.short, event.ident, event.task, event.level)] += 1
        self.field_names[(event.short, event.task)].update(event.fields.keys())
        if event.message is not None:
            self.messages[self.masker.mask(event.message)] += 1
        self._digest(event)

    def _note_time(self, event):
        if event.epoch is None:
            return
        stamp = (event.epoch, event.timestamp, event.frequency)
        if self.first is None or stamp[0] < self.first[0]:
            self.first = stamp
        if self.last is None or stamp[0] > self.last[0]:
            self.last = stamp

    def _record(self, group, label, event, payload):
        self.records.append((group, len(self.records), label, event.epoch, payload))

    def _digest(self, event):
        if event.starts_with("Using RemoteAppDownsampling"):
            self.downsampling["RemoteAppDownsampling"] = event.num("Enabled")
        for key, name in (("min", "MinDownSampleDesktopScale"),
                          ("max", "MaxDownSampleDesktopScale"),
                          ("interpolation", "InterpolationMode"),
                          ("hardware", "HardwareMode"),
                          ("idd", "IddMode")):
            if name in event.fields:
                self.downsampling[key] = event.num(name)

        if "DownSampled" in event.fields:
            self._record(GROUP_SURFACE, "surface", event,
                         "id=%s %sx%s DownSampled=%s DownSampledWidth=%s DownSampledHeight=%s" % (
                             event.num("Id"), event.num("Width"), event.num("Height"),
                             event.num("DownSampled"), event.num("DownSampledWidth"),
                             event.num("DownSampledHeight")))
        if event.starts_with("Created new output layout"):
            self._record(GROUP_LAYOUT, "layout", event, "%sx%s monitors=%s" % (
                event.num("Width"), event.num("Height"), event.num("NumberOfMonitors")))
        if event.starts_with("New virtual desktop"):
            self._record(GROUP_DESKTOP, "desktop", event, "%sx%s@%s,%s" % (
                event.num("Width"), event.num("Height"), event.num("X"), event.num("Y")))

        if event.short == "RdpCoreTS":
            if event.ident == 168:
                self._record(GROUP_MONITOR, "monitor168", event, "num=%s %sx%s@%s,%s" % (
                    event.num("MonitorNum"), event.num("MonitorWidth"),
                    event.num("MonitorHeight"), event.num("MonitorX"), event.num("MonitorY")))
            elif event.ident == 162:
                self._record(GROUP_GFX, "gfx162", event,
                             "Version=%s ClientMode=%s AvcEnabled=%s ProfileIdNum=%s" % (
                                 event.num("Version"), event.num("ClientMode"),
                                 event.num("AvcEnabled"), event.num("ProfileIdNum")))
            elif event.ident == 66:
                self._record(GROUP_SESSION66, "session66", event,
                             "SessionID=%s" % event.num("SessionID"))

        task = event.task or ""
        if task.startswith("ProtProv") or (task == "ServerGfxProvider"
                                           and event.starts_with("First non-black frame")):
            payload = "%s SessionId=%s" % (self.masker.label(task), event.num("SessionId"))
            if "DoReconnect" in event.fields:
                payload += " DoReconnect=%s" % event.num("DoReconnect")
            if "Reason" in event.fields:
                payload += " Reason=%s" % event.num("Reason")
            self._record(GROUP_SESSION, "session", event, payload)
        if task == "ServerConnection" and any(
                name in event.fields for name in
                ("WinlogonStatusCode", "ClientErrorCode", "DiagnosticCode")):
            self._record(GROUP_CONNECTION, "connection", event,
                         "WinlogonStatusCode=%s ClientErrorCode=%s DiagnosticCode=%s" % (
                             event.num("WinlogonStatusCode"), event.num("ClientErrorCode"),
                             event.num("DiagnosticCode")))

    # -- rendering ---------------------------------------------------------

    def _relative(self, epoch):
        if epoch is None or self.first is None:
            return ABSENT
        return "+%.3f" % (epoch - self.first[0])

    def header(self):
        if self.first is None:
            span, first, last = ABSENT, ABSENT, ABSENT
        else:
            span = "%.3fs" % (self.last[0] - self.first[0])
            first = format_filetime(self.first[1], self.first[2])
            last = format_filetime(self.last[1], self.last[2])
        return ("etw-summary: files=%d frames=%d raw_frames=%d events=%d span=%s "
                "first=%s last=%s" % (self.files, self.frames, self.raw_frames, self.events,
                                      span, first, last))

    def lines(self):
        out = [self.header()]
        if self.bad_lines:
            out.append("note: skipped %d unparsable line(s)" % self.bad_lines)

        out.append("providers:")
        for name, count in sorted(self.providers.items(), key=lambda kv: (-kv[1], str(kv[0]))):
            out.append("  %d  %s" % (count, self.masker.label(name)))

        out.append("levels:")
        for level, count in sorted(self.levels.items(),
                                   key=lambda kv: (kv[0] is None, kv[0], -kv[1])):
            out.append("  %d  level=%s" % (count, ABSENT if level is None else level))

        out.append("tasks:")
        ordered = sorted(self.tasks.items(),
                         key=lambda kv: (-kv[1], kv[0][0], kv[0][1] is None, kv[0][1], kv[0][2]))
        for (short, ident, task, level), count in ordered[:self.top]:
            out.append("  %d  %s id=%s task=%s level=%s" % (
                count, self.masker.label(short), ABSENT if ident is None else ident,
                self.masker.label(task), ABSENT if level is None else level))

        out.append("downsampling: RemoteAppDownsampling=%s min=%s max=%s interpolation=%s "
                   "hardware=%s idd=%s" % tuple(self.downsampling.values()))
        for group, _seq, label, epoch, payload in sorted(self.records,
                                                         key=lambda r: (r[0], r[1])):
            out.append("%s: t=%s %s" % (label, self._relative(epoch), payload))

        out.append("fields:")
        for (short, task) in sorted(self.field_names, key=lambda k: (str(k[0]), str(k[1]))):
            names = sorted(self.field_names[(short, task)])
            out.append("  %s task=%s: %s" % (
                self.masker.label(short), self.masker.label(task),
                ", ".join(self.masker.label(n) for n in names) or "-"))

        if self.show_messages:
            out.append("messages:")
            for text, count in sorted(self.messages.items(),
                                      key=lambda kv: (-kv[1], kv[0]))[:self.top]:
                out.append("  %d  %s" % (count, text))
        return out


# --------------------------------------------------------------------------- entry point

def build_parser():
    parser = argparse.ArgumentParser(
        prog="etw_summarize.py",
        description="Summarise Device Portal realtime ETW capture JSONL without printing any "
                    "name, address or other free-text field value.")
    parser.add_argument("--messages", action="store_true",
                        help="also print the distinct msg/Message templates, after masking")
    parser.add_argument("--top", type=int, default=DEFAULT_TOP,
                        help="cap the tasks and messages sections (default %d)" % DEFAULT_TOP)
    parser.add_argument("files", nargs="*", help="capture JSONL file(s)")
    return parser


def main(argv=None, stdout=None, stderr=None, environ=None):
    argv = sys.argv[1:] if argv is None else list(argv)
    out = sys.stdout if stdout is None else stdout
    err = sys.stderr if stderr is None else stderr
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return EX_USAGE
    if not args.files:
        err.write("%s\nerror: at least one capture file is required\n" % parser.format_usage())
        return EX_USAGE
    if args.top < 1:
        err.write("error: --top must be a positive integer\n")
        return EX_USAGE

    summary = Summary(build_masker(environ), top=args.top, show_messages=args.messages)
    for path in args.files:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                summary.add_file(handle)
        except OSError as exc:
            # Nothing has been written yet, so a bad argument produces no partial report.
            err.write("etw_summarize: cannot read %s (%s)\n" % (path, exc.__class__.__name__))
            return EX_NOINPUT
    out.write("\n".join(summary.lines()) + "\n")
    return EX_OK


if __name__ == "__main__":
    sys.exit(main())

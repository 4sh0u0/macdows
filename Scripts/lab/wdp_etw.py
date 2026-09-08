#!/usr/bin/env python3
"""Realtime ETW capture client for the lab host's Windows Device Portal.

Opens `wss://<host>:<port>/api/etw/session/realtime`, turns the requested ETW providers on,
writes every batch the portal pushes as one JSON line, turns the providers off again and
closes. Stdlib only (no `websockets`, no `requests`) so the lab suites run on a stock
python3, and Python 3.9 compatible.

Read-only on the host: the only bytes this client ever sends after the HTTP upgrade are the
control texts `provider <guid> enable <level>` and `provider <guid> disable`, plus WebSocket
pongs and the closing frame. It starts and stops a realtime trace session; it never writes a
file, a registry key or a setting on the host, and it never asks the portal to run anything.

Configuration is taken from the environment and never from argv, because argv is world
readable through `ps` and one of the values is a path to a credential file.

| var                | meaning                                                               |
|--------------------|-----------------------------------------------------------------------|
| `WDP_HOST`         | portal host (the wrapper's boundary gate has already judged it)      |
| `WDP_PORT`         | portal port, default 50443                                            |
| `WDP_PATH`         | request path, default `/api/etw/session/realtime`                     |
| `WDP_CRED_FILE`    | file holding one line `user:password`, mode 0600 or stricter; a       |
|                    | group/world-readable file is refused before anything is connected     |
| `WDP_CERT_SHA256`  | SHA-256 of the portal's leaf certificate in DER form, hex, colons     |
|                    | optional. Empty or malformed is refused before connecting; a          |
|                    | mismatch is refused after the TLS handshake and BEFORE the first      |
|                    | HTTP byte is sent                                                     |
| `WDP_PROVIDERS`    | `<guid>:<level>;<guid>:<level>...`, level 0-5, GUID 8-4-4-4-12 hex    |
| `WDP_DURATION`     | capture length in seconds, float > 0, default 60                      |
| `WDP_OUT`          | JSONL output path, created only once the WebSocket is open            |

The certificate pin is the whole trust decision: TLS runs with `CERT_NONE` (the portal's
certificate is self-signed) and the pin recorded once by the wrapper is what says "this is
the machine we recorded". Checking it before the request is what keeps the Basic credential
from reaching a machine-in-the-middle.

Exit codes (also exported as module constants):

    0   EX_OK           capture completed
    64  EX_USAGE        missing/malformed variable, or a credential file others can read
    69  EX_UNAVAILABLE  the connection or the TLS handshake failed
    76  EX_HANDSHAKE    the upgrade was refused (non-101, or a wrong Sec-WebSocket-Accept)
    79  EX_PIN          no usable certificate pin, or the pin did not match

Tokens printed on stdout (one per line; the wrapper copies them into its log, so none of
them may carry a credential or an address):

    WS-OPEN                                          the upgrade succeeded, capture running
    WS-CLOSE | WS-EOF                                the portal closed / went away
    SUMMARY frames=<n> events=<n> seconds=<s.s> end=timeout|close|eof
    ENV-MISSING <VAR> | PORT-INVALID | DURATION-INVALID | PROVIDERS-INVALID
    CERT-PIN-MISSING <reason> | CERT-PIN-MISMATCH expected=<hex> got=<hex>
    CRED-FILE-PERMS <reason> | CRED-FILE-INVALID <reason> | CRED-FILE-UNREADABLE <reason>
    CONNECT-FAILED <ExcClass> errno=<n>              class and errno only: the exception
                                                     text quotes the address
    HANDSHAKE-FAILED <status line>[ | <detail>]
    OUT-UNWRITABLE <ExcClass> errno=<n>              WDP_OUT could not be created

Usage (every value comes from the environment, nothing from argv):

    WDP_HOST=... WDP_PORT=50443 WDP_CRED_FILE=... WDP_CERT_SHA256=...
    WDP_PROVIDERS=<guid>:5 WDP_DURATION=150 WDP_OUT=.../etw-<tag>.jsonl
    python3 wdp_etw.py

Tested offline by `test_wdp_etw.py`, which drives this client against a fake portal on
127.0.0.1; `wdp-etw.command` is the wrapper that supplies the environment on the lab host.
"""
import base64
import hashlib
import hmac
import ipaddress
import json
import math
import os
import re
import socket
import ssl
import struct
import sys
import time
from typing import Any, Dict, List, Optional, TextIO, Tuple

EX_OK = 0
EX_USAGE = 64
EX_UNAVAILABLE = 69
EX_HANDSHAKE = 76
EX_PIN = 79

DEFAULT_PORT = 50443
DEFAULT_PATH = "/api/etw/session/realtime"
DEFAULT_DURATION = 60.0

#: RFC 6455 section 1.3 -- the constant mixed into Sec-WebSocket-Accept.
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONTINUATION = 0x0
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

CONNECT_TIMEOUT = 10.0
HANDSHAKE_TIMEOUT = 15.0
#: Half a second, so the capture stops within a second of the requested duration even when
#: the portal has gone quiet. A recv that times out must leave the bytes it did get in the
#: reader's buffer -- see FrameReader.
RECV_TIMEOUT = 0.5
#: How long we wait for the portal's closing frame after sending ours.
DRAIN_TIMEOUT = 0.5
RECV_CHUNK = 65536
#: A text message that is not a JSON object is recorded as {"raw": <first 2000 chars>}.
RAW_LIMIT = 2000
#: Refuse to allocate for an absurd declared frame length (a broken or hostile portal).
MAX_FRAME_BYTES = 64 * 1024 * 1024
#: A response head larger than this is not an HTTP head.
MAX_HEAD_BYTES = 64 * 1024
#: Headers worth quoting back when the upgrade is refused; none of them carries a secret.
FAILURE_HEADERS = ("www-authenticate", "location", "content-type")

_GUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
#: socket.timeout is TimeoutError from 3.10 on; both names are listed for 3.9.
_TIMEOUTS = (socket.timeout, TimeoutError)


class PinError(Exception):
    """Base class for the certificate-pin refusals (exit code EX_PIN)."""


class PinMissing(PinError):
    """No pin was configured, or it was not 64 hex digits."""


class PinMismatch(PinError):
    """The portal's certificate is not the one that was pinned."""

    def __init__(self, expected: str, actual: str) -> None:
        super().__init__("expected=%s got=%s" % (expected, actual))
        self.expected = expected
        self.actual = actual


class CredentialError(Exception):
    """A credential file that cannot be used. `token` is the stdout token to print."""

    def __init__(self, token: str, reason: str) -> None:
        super().__init__("%s %s" % (token, reason))
        self.token = token
        self.reason = reason


# ----------------------------------------------------------------------------------------
# Configuration helpers
# ----------------------------------------------------------------------------------------

def parse_providers(spec: str) -> List[Tuple[str, int]]:
    """Parse `<guid>:<level>;<guid>:<level>...` into [(guid lower-case, level int)].

    Raises ValueError with a message that does not echo the input, so a malformed value
    cannot smuggle anything into the wrapper's log.
    """
    items = []  # type: List[Tuple[str, int]]
    for chunk in (spec or "").split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        guid, sep, level = chunk.partition(":")
        if not sep:
            raise ValueError("expected '<guid>:<level>' pairs separated by ';'")
        guid = guid.strip().lower()
        if not _GUID_RE.match(guid):
            raise ValueError("provider id must be a GUID in 8-4-4-4-12 hex form")
        level = level.strip()
        if not level.isdigit() or not 0 <= int(level) <= 5:
            raise ValueError("provider level must be an integer between 0 and 5")
        items.append((guid, int(level)))
    if not items:
        raise ValueError("at least one '<guid>:<level>' pair is required")
    return items


def normalise_pin(value: str) -> str:
    """Return a SHA-256 fingerprint as 64 lower-case hex digits.

    Accepts the colon-separated form `openssl x509 -fingerprint -sha256` prints and any
    surrounding whitespace. Raises PinMissing when there is nothing usable: an absent pin
    and a typo have to fail the same way, because both mean "we cannot tell whose
    certificate this is".
    """
    text = "".join((value or "").split()).replace(":", "").lower()
    if not text:
        raise PinMissing("set WDP_CERT_SHA256 to the portal certificate's SHA-256")
    if not _HEX64_RE.match(text):
        raise PinMissing("WDP_CERT_SHA256 must be 64 hex digits (colons optional)")
    return text


def check_pin(der: bytes, expected: str) -> str:
    """Compare the SHA-256 of a DER certificate with the configured pin.

    Raises PinMissing when the pin itself is unusable, PinMismatch when the certificate is
    not the pinned one. Returns the certificate's fingerprint on success.
    """
    want = normalise_pin(expected)
    got = hashlib.sha256(der or b"").hexdigest()
    if not hmac.compare_digest(got, want):
        raise PinMismatch(want, got)
    return got


def read_credential(path: str) -> Tuple[str, str]:
    """Read one line `user:password` from a file only its owner can read.

    The permission check happens before the file is opened and before any socket exists, so
    a credential that leaked to the group/world never leaves the machine.
    """
    try:
        info = os.stat(path)
    except OSError as exc:
        raise CredentialError("CRED-FILE-UNREADABLE", "errno=%s" % _errno_of(exc))
    if info.st_mode & 0o077:
        raise CredentialError("CRED-FILE-PERMS", "must be readable by its owner only (chmod 600)")
    try:
        with open(path, "r", encoding="utf-8") as handle:
            first = handle.readline()
    except OSError as exc:
        raise CredentialError("CRED-FILE-UNREADABLE", "errno=%s" % _errno_of(exc))
    except UnicodeDecodeError:
        raise CredentialError("CRED-FILE-INVALID", "expected UTF-8 text")
    user, sep, password = first.rstrip("\r\n").partition(":")
    if not sep or not user:
        raise CredentialError("CRED-FILE-INVALID", "expected a single line 'user:password'")
    return user, password


def _errno_of(exc: BaseException) -> int:
    return getattr(exc, "errno", None) or 0


# ----------------------------------------------------------------------------------------
# WebSocket frame codec (RFC 6455 section 5)
# ----------------------------------------------------------------------------------------

def encode_frame(opcode: int, payload: bytes, mask: bytes) -> bytes:
    """Build one FIN frame. Client frames are always masked, so `mask` is 4 bytes."""
    if not isinstance(mask, (bytes, bytearray)) or len(mask) != 4:
        raise ValueError("a client frame needs a 4-byte masking key")
    mask = bytes(mask)
    payload = bytes(payload)
    head = bytearray([0x80 | (opcode & 0x0F)])
    length = len(payload)
    if length < 126:
        head.append(0x80 | length)
    elif length < 65536:
        head.append(0x80 | 126)
        head += struct.pack(">H", length)
    else:
        head.append(0x80 | 127)
        head += struct.pack(">Q", length)
    head += mask
    return bytes(head) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


class FrameReader:
    """Decode frames off a socket, keeping whatever is left over between calls.

    Two properties matter here. Nothing is consumed from the buffer until a whole frame is
    present, so a recv that times out (or an unfinished frame at the end of a chunk) leaves
    the partial frame buffered for the next call instead of dropping it. And `initial`
    takes the bytes that the HTTP response read pulled in past the blank line, which are
    already the first frames.
    """

    def __init__(self, sock: Any, initial: bytes = b"") -> None:
        self.sock = sock
        self.buf = bytearray(initial)

    def _fill(self, want: int) -> None:
        while len(self.buf) < want:
            chunk = self.sock.recv(RECV_CHUNK)
            if not chunk:
                raise EOFError("the peer closed the connection")
            self.buf += chunk

    def frame(self) -> Tuple[bool, int, bytes]:
        """Return (fin, opcode, payload) for the next frame; raise EOFError at end of stream."""
        self._fill(2)
        fin = bool(self.buf[0] & 0x80)
        opcode = self.buf[0] & 0x0F
        masked = bool(self.buf[1] & 0x80)
        length = self.buf[1] & 0x7F
        offset = 2
        if length == 126:
            self._fill(offset + 2)
            length = struct.unpack(">H", bytes(self.buf[offset:offset + 2]))[0]
            offset += 2
        elif length == 127:
            self._fill(offset + 8)
            length = struct.unpack(">Q", bytes(self.buf[offset:offset + 8]))[0]
            offset += 8
        if length > MAX_FRAME_BYTES:
            raise ValueError("frame length %d exceeds the accepted maximum" % length)
        mask = b""
        if masked:
            self._fill(offset + 4)
            mask = bytes(self.buf[offset:offset + 4])
            offset += 4
        self._fill(offset + length)
        payload = bytes(self.buf[offset:offset + length])
        del self.buf[:offset + length]
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, opcode, payload


def accept_key(key: str) -> str:
    """RFC 6455 section 4.2.2: base64(sha1(client key + WS_GUID)).

    SHA-1 here is the protocol's choice, not a security decision of ours.
    """
    digest = hashlib.sha1((key + WS_GUID).encode("ascii")).digest()  # noqa: S324 - RFC 6455
    return base64.b64encode(digest).decode("ascii")


# ----------------------------------------------------------------------------------------
# Batch parsing
# ----------------------------------------------------------------------------------------

def parse_batch(text: str) -> Tuple[Dict[str, Any], int]:
    """Turn one text message into (object to record, number of events in it).

    A JSON object is recorded as it stands; anything else (a fragment, an error page, a
    JSON array) is recorded as {"raw": <first 2000 chars>} so the capture keeps evidence of
    what arrived without ever failing.
    """
    try:
        obj = json.loads(text)
    except ValueError:
        return {"raw": text[:RAW_LIMIT]}, 0
    if not isinstance(obj, dict):
        return {"raw": text[:RAW_LIMIT]}, 0
    events = obj.get("Events")
    return obj, len(events) if isinstance(events, list) else 0


# ----------------------------------------------------------------------------------------
# Wire helpers
# ----------------------------------------------------------------------------------------

def _send(sock: Any, opcode: int, payload: bytes) -> bool:
    """Send one masked frame; report failure instead of raising (the peer may be gone)."""
    try:
        sock.sendall(encode_frame(opcode, payload, os.urandom(4)))
        return True
    except OSError:
        return False


def _close_quietly(sock: Any) -> None:
    try:
        sock.close()
    except OSError:
        pass


def _host_header(host: str, port: int) -> str:
    return "[%s]:%d" % (host, port) if ":" in host else "%s:%d" % (host, port)


def _sni_for(host: str) -> Optional[str]:
    """SNI carries host names only; an IP literal is sent without it."""
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return host
    return None


def _read_head(sock: Any) -> Tuple[str, bytes]:
    """Read the HTTP response head; return (head text, bytes already read past it)."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(RECV_CHUNK)
        if not chunk:
            raise EOFError("the portal closed the connection during the upgrade")
        buf += chunk
        if len(buf) > MAX_HEAD_BYTES:
            raise ValueError("the response head is too large to be an HTTP head")
    head, _, rest = buf.partition(b"\r\n\r\n")
    return head.decode("latin-1", "replace"), rest


def _parse_headers(head: str) -> Dict[str, str]:
    headers = {}  # type: Dict[str, str]
    for line in head.split("\r\n")[1:]:
        name, sep, value = line.partition(":")
        if sep:
            headers[name.strip().lower()] = value.strip()
    return headers


def _failure_detail(headers: Dict[str, str]) -> str:
    parts = [headers[name] for name in FAILURE_HEADERS if headers.get(name)]
    return " | " + "; ".join(parts) if parts else ""


# ----------------------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------------------

def main(environ: Optional[Dict[str, str]] = None, stdout: Optional[TextIO] = None) -> int:
    """Run one capture. Returns one of the EX_* codes; never raises for a peer's misbehaviour."""
    env = dict(os.environ if environ is None else environ)
    out = sys.stdout if stdout is None else stdout

    def say(line: str) -> None:
        print(line, file=out)
        out.flush()

    # ---- configuration, all of it before a socket exists ---------------------------------
    for name in ("WDP_HOST", "WDP_CRED_FILE", "WDP_PROVIDERS", "WDP_OUT"):
        if not env.get(name, "").strip():
            say("ENV-MISSING %s" % name)
            return EX_USAGE
    host = env["WDP_HOST"].strip()
    out_path = env["WDP_OUT"].strip()
    path = env.get("WDP_PATH", "").strip() or DEFAULT_PATH
    if not path.startswith("/"):
        path = "/" + path

    port_text = env.get("WDP_PORT", "").strip() or str(DEFAULT_PORT)
    if not port_text.isdigit() or not 1 <= int(port_text) <= 65535:
        say("PORT-INVALID expected a TCP port between 1 and 65535")
        return EX_USAGE
    port = int(port_text)

    duration_text = env.get("WDP_DURATION", "").strip() or str(DEFAULT_DURATION)
    try:
        duration = float(duration_text)
    except ValueError:
        duration = float("nan")
    if not math.isfinite(duration) or duration <= 0:
        say("DURATION-INVALID expected a positive number of seconds")
        return EX_USAGE

    try:
        providers = parse_providers(env["WDP_PROVIDERS"])
    except ValueError as exc:
        say("PROVIDERS-INVALID %s" % exc)
        return EX_USAGE

    # The pin is checked for shape here so that a missing pin never opens a socket at all.
    try:
        pin = normalise_pin(env.get("WDP_CERT_SHA256", ""))
    except PinMissing as exc:
        say("CERT-PIN-MISSING %s" % exc)
        return EX_PIN

    try:
        user, password = read_credential(env["WDP_CRED_FILE"].strip())
    except CredentialError as exc:
        say("%s %s" % (exc.token, exc.reason))
        return EX_USAGE

    # ---- TCP, TLS, pin -------------------------------------------------------------------
    try:
        raw = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
    except OSError as exc:
        # Class and errno only: the exception's text quotes the address we dialled.
        say("CONNECT-FAILED %s errno=%s" % (type(exc).__name__, _errno_of(exc)))
        return EX_UNAVAILABLE

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False          # must be cleared before CERT_NONE
    context.verify_mode = ssl.CERT_NONE     # the pin below is the trust decision
    try:
        sock = context.wrap_socket(raw, server_hostname=_sni_for(host))
    except OSError as exc:
        _close_quietly(raw)
        say("CONNECT-FAILED %s errno=%s" % (type(exc).__name__, _errno_of(exc)))
        return EX_UNAVAILABLE

    try:
        check_pin(sock.getpeercert(binary_form=True) or b"", pin)
    except PinMismatch as exc:
        # Refused after the handshake and before the first HTTP byte: the Basic credential
        # must not reach a machine we did not pin.
        _close_quietly(sock)
        say("CERT-PIN-MISMATCH expected=%s got=%s" % (exc.expected, exc.actual))
        return EX_PIN

    # ---- HTTP/1.1 upgrade ----------------------------------------------------------------
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    authorization = base64.b64encode(("%s:%s" % (user, password)).encode("utf-8")).decode("ascii")
    request = (
        "GET %s HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Authorization: Basic %s\r\n"
        "\r\n"
    ) % (path, _host_header(host, port), key, authorization)
    sock.settimeout(HANDSHAKE_TIMEOUT)
    try:
        sock.sendall(request.encode("utf-8"))
        head, leftover = _read_head(sock)
    except (EOFError, ValueError, OSError) as exc:
        _close_quietly(sock)
        say("CONNECT-FAILED %s errno=%s" % (type(exc).__name__, _errno_of(exc)))
        return EX_UNAVAILABLE

    status_line = head.split("\r\n")[0].strip()
    headers = _parse_headers(head)
    fields = status_line.split()
    if len(fields) < 2 or fields[1] != "101":
        _close_quietly(sock)
        say("HANDSHAKE-FAILED %s%s" % (status_line, _failure_detail(headers)))
        return EX_HANDSHAKE
    if headers.get("sec-websocket-accept", "") != accept_key(key):
        _close_quietly(sock)
        say("HANDSHAKE-FAILED %s | Sec-WebSocket-Accept mismatch" % status_line)
        return EX_HANDSHAKE

    # ---- capture -------------------------------------------------------------------------
    try:
        sink = open(out_path, "w", encoding="utf-8", buffering=1)
    except OSError as exc:
        _close_quietly(sock)
        say("OUT-UNWRITABLE %s errno=%s" % (type(exc).__name__, _errno_of(exc)))
        return EX_USAGE

    reader = FrameReader(sock, leftover)
    say("WS-OPEN")
    for guid, level in providers:
        _send(sock, OP_TEXT, ("provider %s enable %d" % (guid, level)).encode("utf-8"))

    started = time.monotonic()
    deadline = started + duration
    frames = 0
    events = 0
    ending = "timeout"
    pending = bytearray()
    sock.settimeout(RECV_TIMEOUT)
    try:
        while True:
            if time.monotonic() >= deadline:
                ending = "timeout"
                break
            try:
                fin, opcode, data = reader.frame()
            except _TIMEOUTS:
                continue  # the partial frame, if any, stays in the reader's buffer
            except (EOFError, ValueError, OSError):
                ending = "eof"
                say("WS-EOF")
                break
            if opcode in (OP_TEXT, OP_BINARY):
                pending = bytearray(data)
            elif opcode == OP_CONTINUATION:
                pending += data
            elif opcode == OP_PING:
                _send(sock, OP_PONG, data[:125])
                continue
            elif opcode == OP_CLOSE:
                ending = "close"
                say("WS-CLOSE")
                break
            else:
                continue  # a pong of our own ping, or a reserved opcode
            if fin:
                obj, count = parse_batch(bytes(pending).decode("utf-8", "replace"))
                pending = bytearray()
                sink.write(json.dumps(obj, ensure_ascii=False) + "\n")
                frames += 1
                events += count
        seconds = time.monotonic() - started
    finally:
        # In a finally block because a realtime ETW session left enabled keeps costing the
        # host: however this loop ends, the providers are turned off again. Each _send here
        # swallows its own OSError, so a peer that has already gone cannot mask a real error.
        for guid, _level in providers:
            _send(sock, OP_TEXT, ("provider %s disable" % guid).encode("utf-8"))
        _send(sock, OP_CLOSE, struct.pack(">H", 1000))
        _drain_close(sock, reader)
        _close_quietly(sock)
        sink.close()  # last, so a failed flush is still reported rather than swallowed

    say("SUMMARY frames=%d events=%d seconds=%.1f end=%s" % (frames, events, seconds, ending))
    return EX_OK


def _drain_close(sock: Any, reader: FrameReader) -> None:
    """Wait briefly for the portal's own closing frame after we sent ours.

    RFC 6455 asks for it, and it also keeps us from dropping the connection while the portal
    is still writing, which would turn its last send into a reset.
    """
    limit = time.monotonic() + DRAIN_TIMEOUT
    try:
        sock.settimeout(DRAIN_TIMEOUT)
        while time.monotonic() < limit:
            _fin, opcode, _data = reader.frame()
            if opcode == OP_CLOSE:
                return
    except (EOFError, ValueError, OSError):
        return


if __name__ == "__main__":
    sys.exit(main())

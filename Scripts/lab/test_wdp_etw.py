#!/usr/bin/env python3
"""Offline tests for Scripts/lab/wdp_etw.py -- the stdlib WebSocket client that reads the lab
host's Device Portal realtime ETW session (wss://<host>:50443/api/etw/session/realtime).

Everything here runs without the host: the frame codec and the batch parser are exercised on
bytes in memory, and the end-to-end cases drive the REAL client against a fake portal that
listens on 127.0.0.1 with a throw-away self-signed certificate generated into a temp dir. The
fake portal records exactly what the client sent (the HTTP upgrade, every provider command,
the pong, the close), so each assertion is about the client's behaviour on the wire and not
about a mock. The credential used is a placeholder string; the address is loopback; no packet
leaves the machine.

Run:  cd Scripts/lab && python3 -m unittest -v test_wdp_etw
"""
import ast
import base64
import builtins
import contextlib
import hashlib
import io
import json
import os
import re
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import unittest.mock
import warnings

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wdp_etw  # noqa: E402

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
GUID_A = "1139c61b-b549-4251-8ed3-27250a1edec8"  # RdpCoreTS (a public Microsoft provider id)
GUID_B = "c76baa63-ae81-421c-b425-340b4b24157f"  # RCM


class FakeSocket:
    """recv() hands out at most `chunk` bytes per call, so a reader that assumes one recv per
    frame is caught; an empty script means the peer closed."""

    def __init__(self, data, chunk=1):
        self.buf = io.BytesIO(data)
        self.chunk = chunk
        self.sent = b""

    def recv(self, n):
        return self.buf.read(min(n, self.chunk))

    def sendall(self, b):
        self.sent += b


def xor_mask(payload, mask):
    return bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def server_frame(opcode, payload, fin=True):
    """A frame as the (unmasked) server side would send it."""
    head = bytearray([(0x80 if fin else 0) | opcode])
    n = len(payload)
    if n < 126:
        head.append(n)
    elif n < 65536:
        head.append(126)
        head += struct.pack(">H", n)
    else:
        head.append(127)
        head += struct.pack(">Q", n)
    return bytes(head) + payload


class ProvidersTests(unittest.TestCase):
    def test_parse_providers_accepts_guid_level_list(self):
        got = wdp_etw.parse_providers(f"{GUID_A}:5;{GUID_B}:4")
        self.assertEqual(got, [(GUID_A, 5), (GUID_B, 4)])

    def test_parse_providers_upper_case_guid_is_normalised(self):
        got = wdp_etw.parse_providers(GUID_A.upper() + ":1")
        self.assertEqual(got, [(GUID_A, 1)])

    def test_parse_providers_rejects_level_outside_0_to_5(self):
        with self.assertRaises(ValueError):
            wdp_etw.parse_providers(f"{GUID_A}:6")

    def test_parse_providers_rejects_missing_level(self):
        with self.assertRaises(ValueError):
            wdp_etw.parse_providers(GUID_A)

    def test_parse_providers_rejects_non_guid(self):
        with self.assertRaises(ValueError):
            wdp_etw.parse_providers("not-a-guid:5")

    def test_parse_providers_rejects_empty_list(self):
        with self.assertRaises(ValueError):
            wdp_etw.parse_providers("")
        with self.assertRaises(ValueError):
            wdp_etw.parse_providers(";")


class FrameCodecTests(unittest.TestCase):
    def test_encode_frame_masks_payload_and_sets_fin(self):
        mask = b"\x01\x02\x03\x04"
        got = wdp_etw.encode_frame(0x1, b"abc", mask)
        self.assertEqual(got, b"\x81\x83" + mask + xor_mask(b"abc", mask))

    def test_encode_frame_uses_16_bit_length_at_126(self):
        mask = b"\x00\x00\x00\x00"
        payload = b"x" * 126
        got = wdp_etw.encode_frame(0x1, payload, mask)
        self.assertEqual(got[:4], b"\x81\xfe\x00\x7e")
        self.assertEqual(got[4:8], mask)
        self.assertEqual(got[8:], payload)

    def test_encode_frame_uses_64_bit_length_above_65535(self):
        mask = b"\x00\x00\x00\x00"
        payload = b"y" * 70000
        got = wdp_etw.encode_frame(0x2, payload, mask)
        self.assertEqual(got[:2], b"\x82\xff")
        self.assertEqual(struct.unpack(">Q", got[2:10])[0], 70000)
        self.assertEqual(got[10:14], mask)
        self.assertEqual(len(got), 14 + 70000)

    def test_encode_frame_requires_a_four_byte_mask(self):
        with self.assertRaises(ValueError):
            wdp_etw.encode_frame(0x1, b"abc", b"\x01\x02")

    def test_reader_decodes_unmasked_frames_across_recv_boundaries(self):
        payload = b"p" * 300  # 16-bit length
        rd = wdp_etw.FrameReader(FakeSocket(server_frame(0x1, payload), chunk=1))
        self.assertEqual(rd.frame(), (True, 0x1, payload))

    def test_reader_decodes_64_bit_length(self):
        payload = b"q" * 70000
        rd = wdp_etw.FrameReader(FakeSocket(server_frame(0x1, payload), chunk=4096))
        self.assertEqual(rd.frame(), (True, 0x1, payload))

    def test_reader_decodes_masked_frames(self):
        mask = b"\x0a\x0b\x0c\x0d"
        rd = wdp_etw.FrameReader(FakeSocket(wdp_etw.encode_frame(0x1, b"hello", mask), chunk=2))
        self.assertEqual(rd.frame(), (True, 0x1, b"hello"))

    def test_reader_returns_fin_false_for_a_fragment_then_continuation(self):
        data = server_frame(0x1, b"first", fin=False) + server_frame(0x0, b"second", fin=True)
        rd = wdp_etw.FrameReader(FakeSocket(data, chunk=3))
        self.assertEqual(rd.frame(), (False, 0x1, b"first"))
        self.assertEqual(rd.frame(), (True, 0x0, b"second"))

    def test_reader_keeps_bytes_handed_over_from_the_http_response(self):
        rd = wdp_etw.FrameReader(FakeSocket(b"", chunk=1), initial=server_frame(0x9, b"hb"))
        self.assertEqual(rd.frame(), (True, 0x9, b"hb"))

    def test_reader_raises_eoferror_when_the_peer_closes_mid_frame(self):
        rd = wdp_etw.FrameReader(FakeSocket(server_frame(0x1, b"abcdef")[:4], chunk=1))
        with self.assertRaises(EOFError):
            rd.frame()


class HandshakeHelperTests(unittest.TestCase):
    def test_accept_key_matches_the_rfc_6455_example(self):
        self.assertEqual(wdp_etw.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

    def test_check_pin_normalises_colons_and_case(self):
        der = b"\x30\x03\x02\x01\x01"
        fp = hashlib.sha256(der).hexdigest()
        colon = ":".join(fp[i:i + 2] for i in range(0, len(fp), 2)).upper()
        wdp_etw.check_pin(der, colon)  # no exception
        wdp_etw.check_pin(der, fp.lower())

    def test_check_pin_rejects_mismatch(self):
        with self.assertRaises(wdp_etw.PinMismatch):
            wdp_etw.check_pin(b"\x30\x00", "ab" * 32)

    def test_check_pin_rejects_a_missing_pin_rather_than_trusting_everything(self):
        with self.assertRaises(wdp_etw.PinMissing):
            wdp_etw.check_pin(b"\x30\x00", "")
        with self.assertRaises(wdp_etw.PinMissing):
            wdp_etw.check_pin(b"\x30\x00", "  \n")

    def test_check_pin_rejects_a_malformed_pin(self):
        with self.assertRaises(wdp_etw.PinMissing):
            wdp_etw.check_pin(b"\x30\x00", "not-hex")


class BatchTests(unittest.TestCase):
    def test_parse_batch_counts_events(self):
        obj, n = wdp_etw.parse_batch('{"Frequency": 10000000, "Events": [{"ID": 1}, {"ID": 2}]}')
        self.assertEqual(n, 2)
        self.assertEqual(obj["Frequency"], 10000000)

    def test_parse_batch_wraps_invalid_json_as_raw(self):
        obj, n = wdp_etw.parse_batch("{not json")
        self.assertEqual(n, 0)
        self.assertEqual(obj, {"raw": "{not json"})

    def test_parse_batch_truncates_raw_to_2000_chars(self):
        obj, n = wdp_etw.parse_batch("x" * 5000)
        self.assertEqual(len(obj["raw"]), 2000)

    def test_parse_batch_treats_a_non_object_document_as_raw(self):
        obj, n = wdp_etw.parse_batch("[1, 2, 3]")
        self.assertEqual(n, 0)
        self.assertEqual(obj, {"raw": "[1, 2, 3]"})

    def test_parse_batch_object_without_events_counts_zero(self):
        obj, n = wdp_etw.parse_batch('{"Frequency": 1}')
        self.assertEqual(n, 0)
        self.assertEqual(obj, {"Frequency": 1})


# ------------------------------------------------------------------------------------------
# End-to-end against a fake portal on loopback
# ------------------------------------------------------------------------------------------

@contextlib.contextmanager
def _quiet_tls_deprecations():
    """ssl.TLSVersion.TLSv1 / TLSv1_1 are deprecated on newer interpreters; the behaviour case
    has to touch them on purpose, so the warning is silenced only around those touches."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        yield


def _cap_server_context(ctx, tls_max):
    """Limit a server context to TLS 1.0 .. `tls_max`; relax the OpenSSL security level when the
    library has one (LibreSSL rejects the '@SECLEVEL' syntax, and needs no relaxing)."""
    with _quiet_tls_deprecations():
        ctx.minimum_version = ssl.TLSVersion.TLSv1
        ctx.maximum_version = tls_max
    try:
        ctx.set_ciphers("DEFAULT:@SECLEVEL=0")
    except ssl.SSLError:
        pass


def probe_old_tls(certfile, keyfile, version):
    """Control for the TLS-floor behaviour case: handshake a deliberately permissive client
    (floor TLS 1.0, seclevel 0 where supported) against a server capped at `version` on loopback.
    Returns (negotiated version string or None, reason string)."""
    with _quiet_tls_deprecations():
        wants_1_1 = version is ssl.TLSVersion.TLSv1_1
    if wants_1_1 and not getattr(ssl, "HAS_TLSv1_1", False):
        return None, "ssl.HAS_TLSv1_1 is False (this TLS library has TLS 1.1 compiled out)"
    server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.load_cert_chain(certfile, keyfile)
    _cap_server_context(server, version)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(5.0)
    port = listener.getsockname()[1]

    def serve():
        try:
            raw, _ = listener.accept()
            raw.settimeout(5.0)
            try:
                server.wrap_socket(raw, server_side=True).close()
            except (OSError, ssl.SSLError):
                raw.close()
        except OSError:
            pass
        finally:
            listener.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    control = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    control.check_hostname = False
    control.verify_mode = ssl.CERT_NONE
    with _quiet_tls_deprecations():
        control.minimum_version = ssl.TLSVersion.TLSv1
        control.maximum_version = version
    try:
        control.set_ciphers("DEFAULT:@SECLEVEL=0")
    except ssl.SSLError:
        pass
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5.0) as raw:
            with control.wrap_socket(raw, server_hostname="localhost") as tls:
                return tls.version(), "control handshake succeeded"
    except (OSError, ssl.SSLError) as exc:
        return None, "control handshake failed (%s)" % type(exc).__name__
    finally:
        thread.join(6.0)


class FakePortal(threading.Thread):
    """TLS WebSocket server for one connection (a portal built with `tls_max` keeps accepting more
    until `stop` is set). `script` decides what it does after the upgrade:
    a list of ('send', bytes) / ('await', kind) steps. Records everything the client sent."""

    def __init__(self, certfile, keyfile, user, pw, mode="ok", script=None, deadline=8.0, tls_max=None):
        super().__init__(daemon=True)
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(certfile, keyfile)
        if tls_max is not None:
            _cap_server_context(self.ctx, tls_max)
        self.user, self.pw, self.mode, self.script = user, pw, mode, script or []
        self.deadline = deadline
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(deadline)
        self.port = self.listener.getsockname()[1]
        self.accepted = 0
        self.request = b""
        self.commands = []   # text frames from the client, decoded
        self.pongs = []
        self.closed = False
        self.errors = []
        self.handshake_error = None  # class name of the server-side TLS handshake failure, if any
        self.tls_max = tls_max
        self.stop = threading.Event()  # tells a capped portal that no further connection is due

    def run(self):
        try:
            try:
                self._serve()
            except Exception as exc:  # recorded, asserted by the test
                self.errors.append(repr(exc))
            if self.tls_max is not None:
                self._accept_more()
        finally:
            self.listener.close()

    def _accept_more(self):
        """A capped portal keeps listening after the first connection (until `stop` is set and the
        backlog is drained), like the real one: a client that dials again, e.g. with a fresh
        context, would otherwise find a closed port and look as if it had been refused."""
        self.listener.settimeout(0.2)
        end = time.monotonic() + self.deadline
        while time.monotonic() < end:
            try:
                raw, _ = self.listener.accept()
            except socket.timeout:
                if self.stop.is_set():
                    return
                continue
            self.accepted += 1
            raw.settimeout(2.0)
            try:
                s = self.ctx.wrap_socket(raw, server_side=True)
                self.request += s.recv(4096)
                s.close()
            except OSError:
                raw.close()

    def _read_client_frame(self, rd):
        fin, op, data = rd.frame()
        if op == 0x1:
            self.commands.append(data.decode())
        elif op == 0xA:
            self.pongs.append(data)
        elif op == 0x8:
            self.closed = True
        return op

    def _serve(self):
        raw, _ = self.listener.accept()
        self.accepted += 1
        raw.settimeout(self.deadline)
        try:
            s = self.ctx.wrap_socket(raw, server_side=True)
        except OSError as exc:  # ssl.SSLError is an OSError
            self.handshake_error = type(exc).__name__
            raise
        try:
            self._talk(s)
        finally:
            s.close()

    def _talk(self, s):
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                return  # the client closed after TLS without speaking HTTP (pin refusal)
            buf += chunk
        self.request = buf
        head = buf.split(b"\r\n\r\n", 1)[0].decode()
        headers = {}
        for line in head.split("\r\n")[1:]:
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
        want_auth = "Basic " + base64.b64encode(f"{self.user}:{self.pw}".encode()).decode()
        if self.mode == "401" or headers.get("authorization") != want_auth:
            s.sendall(b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"portal\"\r\nContent-Length: 0\r\n\r\n")
            return
        accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + WS_GUID).encode()).digest()).decode()
        if self.mode == "bad-accept":
            accept = "AAAAAAAAAAAAAAAAAAAAAAAAAAA="
        s.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        rd = wdp_etw.FrameReader(s, buf.split(b"\r\n\r\n", 1)[1])
        for step, arg in self.script:
            if step == "send":
                s.sendall(arg)
            elif step == "await-commands":
                while len(self.commands) < arg:
                    self._read_client_frame(rd)
            elif step == "await-pong":
                while not self.pongs:
                    self._read_client_frame(rd)
            elif step == "silence":
                time.sleep(arg)  # stay connected, read nothing, send nothing
            elif step == "await-close":
                while not self.closed:
                    try:
                        self._read_client_frame(rd)
                    except EOFError:
                        break
                s.sendall(server_frame(0x8, b""))


def make_cert(tmpdir):
    cert = os.path.join(tmpdir, "cert.pem")
    key = os.path.join(tmpdir, "key.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                    "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=localhost", "-days", "2"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(cert) as f:
        der = ssl.PEM_cert_to_DER_cert(f.read())
    return cert, key, hashlib.sha256(der).hexdigest()


class EndToEndTests(unittest.TestCase):
    USER = "labtest-placeholder"
    PW = "LABTEST-PLACEHOLDER-SECRET-3f9a"

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="wdp-etw-test.")
        cls.cert, cls.key, cls.pin = make_cert(cls.tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def cred_file(self, mode=0o600):
        path = os.path.join(self.tmp.name, f"cred-{id(self)}-{mode:o}")
        with open(path, "w") as f:
            f.write(f"{self.USER}:{self.PW}\n")
        os.chmod(path, mode)
        return path

    def env(self, portal, **override):
        out = os.path.join(self.tmp.name, f"out-{id(self)}-{portal.port}.jsonl")
        env = {
            "WDP_HOST": "127.0.0.1", "WDP_PORT": str(portal.port), "WDP_CRED_FILE": self.cred_file(),
            "WDP_CERT_SHA256": self.pin, "WDP_PROVIDERS": f"{GUID_A}:5;{GUID_B}:4",
            "WDP_DURATION": "1.5", "WDP_OUT": out,
        }
        env.update(override)
        return env

    def run_main(self, env):
        stdout = io.StringIO()
        rc = wdp_etw.main(env, stdout=stdout)
        return rc, stdout.getvalue()

    def test_capture_end_to_end(self):
        batch1 = json.dumps({"Frequency": 10000000, "Events": [{"ID": 1}, {"ID": 2}]}).encode()
        batch2 = json.dumps({"Frequency": 10000000, "Events": [{"ID": 3, "pad": "z" * 200}]}).encode()
        batch3 = json.dumps({"Frequency": 10000000, "Events": [{"ID": 4, "pad": "w" * 70000}]}).encode()
        half = len(batch2) // 2
        script = [
            ("await-commands", 2),
            ("send", server_frame(0x1, batch1)),
            ("send", server_frame(0x9, b"hb")),
            ("await-pong", None),
            ("send", server_frame(0x1, batch2[:half], fin=False)),
            ("send", server_frame(0x0, batch2[half:], fin=True)),
            ("send", server_frame(0x1, batch3)),
            ("send", server_frame(0x1, b"{not json")),
            ("await-close", None),
        ]
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, script=script)
        portal.start()
        env = self.env(portal)
        rc, out = self.run_main(env)
        portal.join(10)
        self.assertEqual(portal.errors, [])
        self.assertEqual(rc, 0, out)
        self.assertIn("WS-OPEN", out)
        self.assertRegex(out, r"SUMMARY frames=4 events=4 seconds=\d+\.\d end=timeout")
        self.assertEqual(portal.commands[:2], [f"provider {GUID_A} enable 5", f"provider {GUID_B} enable 4"])
        self.assertEqual(portal.commands[2:], [f"provider {GUID_A} disable", f"provider {GUID_B} disable"])
        self.assertEqual(portal.pongs, [b"hb"])
        self.assertTrue(portal.closed, "client did not send a close frame")
        with open(env["WDP_OUT"], encoding="utf-8") as f:
            lines = [json.loads(line) for line in f]
        self.assertEqual([len(o.get("Events", [])) for o in lines[:3]], [2, 1, 1])
        self.assertEqual(lines[2]["Events"][0]["pad"], "w" * 70000)
        self.assertEqual(lines[3], {"raw": "{not json"})
        request = portal.request.decode()
        self.assertTrue(request.startswith("GET /api/etw/session/realtime HTTP/1.1\r\n"), request)
        self.assertIn("Sec-WebSocket-Version: 13\r\n", request)
        self.assertNotIn(self.PW, out)
        self.assertNotIn(self.PW, json.dumps(lines))

    def test_server_close_frame_ends_the_capture_early(self):
        batch1 = json.dumps({"Frequency": 10000000, "Events": [{"ID": 1}]}).encode()
        script = [("await-commands", 2), ("send", server_frame(0x1, batch1)), ("send", server_frame(0x8, b""))]
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, script=script)
        portal.start()
        rc, out = self.run_main(self.env(portal, WDP_DURATION="30"))
        portal.join(10)
        self.assertEqual(portal.errors, [])
        self.assertEqual(rc, 0, out)
        self.assertRegex(out, r"SUMMARY frames=1 events=1 seconds=\d+\.\d end=close")

    def test_server_eof_ends_the_capture(self):
        script = [("await-commands", 2)]  # then the portal simply closes the socket
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, script=script)
        portal.start()
        rc, out = self.run_main(self.env(portal, WDP_DURATION="30"))
        portal.join(10)
        self.assertEqual(rc, 0, out)
        self.assertRegex(out, r"SUMMARY frames=0 events=0 seconds=\d+\.\d end=eof")

    def test_wrong_pin_is_refused_before_the_http_upgrade_is_sent(self):
        portal = FakePortal(self.cert, self.key, self.USER, self.PW)
        portal.start()
        env = self.env(portal, WDP_CERT_SHA256="00" * 32)
        rc, out = self.run_main(env)
        portal.join(10)
        self.assertEqual(rc, wdp_etw.EX_PIN, out)
        self.assertIn("CERT-PIN-MISMATCH", out)
        self.assertEqual(portal.request, b"", "the client spoke HTTP to a server whose certificate it did not trust")
        self.assertFalse(os.path.exists(env["WDP_OUT"]))
        self.assertNotIn(self.PW, out)

    def test_a_tls_1_1_only_server_is_refused_before_any_http_byte(self):
        # The control client proves this interpreter's TLS library can stand up a TLS 1.1 server
        # at all; without that, "the handshake failed" would only prove the SERVER is unable.
        # Scope: the outcome asserted here (a TLS 1.1-only server is refused before any HTTP
        # byte) holds everywhere. On OpenSSL 3.x the client's default security level refuses
        # TLS 1.1 even without the floor, so this case discriminates the floor only where the
        # library defaults still allow TLS 1.1, e.g. LibreSSL 2.8; the source pin below is the
        # interpreter-independent guard.
        negotiated, why = probe_old_tls(self.cert, self.key, ssl.TLSVersion.TLSv1_1)
        if negotiated != "TLSv1.1":
            self.skipTest("cannot stand up a TLS 1.1 server here: %s (negotiated=%r)" % (why, negotiated))
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, tls_max=ssl.TLSVersion.TLSv1_1)
        portal.start()
        rc, out = self.run_main(self.env(portal))
        portal.stop.set()  # the portal still accepts until now, so a redial would be recorded
        portal.join(10)
        self.assertEqual(rc, wdp_etw.EX_UNAVAILABLE, out)
        self.assertIn("CONNECT-FAILED", out)
        # Server-side evidence that the failure was a TLS handshake and not a missing TCP
        # connection: the portal accepted the socket, then its own handshake failed.
        self.assertEqual(portal.accepted, 1, "expected exactly one TCP connection to the server "
                         "(0 = never connected, 2 or more = dialled again)")
        self.assertIsNotNone(portal.handshake_error, "the server-side TLS handshake did not fail")
        self.assertEqual(portal.request, b"", "an application byte reached a server that only speaks TLS 1.1")
        self.assertEqual(portal.commands, [])
        self.assertNotIn(self.PW, out)

    def test_a_failed_handshake_is_not_retried_on_a_second_connection(self):
        # Interpreter-independent: the peer reads the ClientHello and hangs up, so the TLS
        # handshake fails without any TLS 1.1 support, and it keeps listening for a bounded
        # time. A client that dials again (say with a fresh, unfloored context) is counted.
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(4)
        listener.settimeout(0.2)
        accepted = []
        stop = threading.Event()

        def serve():
            end = time.monotonic() + 8.0
            while time.monotonic() < end:
                try:
                    raw, _ = listener.accept()
                except socket.timeout:
                    if stop.is_set():
                        return
                    continue
                accepted.append(1)
                raw.settimeout(2.0)
                try:
                    raw.recv(4096)
                except OSError:
                    pass
                raw.close()

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        peer = types.SimpleNamespace(port=listener.getsockname()[1])
        try:
            rc, out = self.run_main(self.env(peer))
        finally:
            # A synchronous redial inside main() is already in the backlog by now. A redial started
            # after main() returns (a timer or thread) is invisible here; the pin's import
            # allow-list and guarded names are what cover that.
            stop.set()
            thread.join(10)
            listener.close()
        self.assertEqual(rc, wdp_etw.EX_UNAVAILABLE, out)
        self.assertIn("CONNECT-FAILED", out)
        self.assertEqual(len(accepted), 1, "the client dialled again after its TLS handshake failed")
        self.assertNotIn(self.PW, out)

    def test_missing_pin_is_refused_without_connecting(self):
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, deadline=1.0)
        portal.start()
        env = self.env(portal, WDP_CERT_SHA256="")
        rc, out = self.run_main(env)
        portal.join(5)
        self.assertEqual(rc, wdp_etw.EX_PIN, out)
        self.assertIn("CERT-PIN-MISSING", out)
        self.assertEqual(portal.accepted, 0, "the client connected although it had no pin to check against")

    def test_401_is_reported_as_a_handshake_failure(self):
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, mode="401")
        portal.start()
        rc, out = self.run_main(self.env(portal))
        portal.join(10)
        self.assertEqual(rc, wdp_etw.EX_HANDSHAKE, out)
        self.assertIn("HANDSHAKE-FAILED HTTP/1.1 401 Unauthorized", out)
        self.assertEqual(portal.commands, [])
        self.assertNotIn(self.PW, out)

    def test_wrong_accept_key_is_a_handshake_failure(self):
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, mode="bad-accept")
        portal.start()
        rc, out = self.run_main(self.env(portal))
        portal.join(10)
        self.assertEqual(rc, wdp_etw.EX_HANDSHAKE, out)
        self.assertIn("HANDSHAKE-FAILED", out)
        self.assertIn("Sec-WebSocket-Accept", out)
        self.assertEqual(portal.commands, [])

    def test_unreachable_port_is_reported_not_raised(self):
        # A listener that is closed at once: the port is known-free, the connect is refused.
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        portal_stub = type("P", (), {"port": port})()
        rc, out = self.run_main(self.env(portal_stub))
        self.assertEqual(rc, wdp_etw.EX_UNAVAILABLE, out)
        self.assertIn("CONNECT-FAILED", out)

    def test_world_readable_credential_file_is_refused(self):
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, deadline=1.0)
        portal.start()
        rc, out = self.run_main(self.env(portal, WDP_CRED_FILE=self.cred_file(0o644)))
        portal.join(5)
        self.assertEqual(rc, wdp_etw.EX_USAGE, out)
        self.assertIn("CRED-FILE-PERMS", out)
        self.assertEqual(portal.accepted, 0)

    def test_invalid_providers_are_refused_without_connecting(self):
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, deadline=1.0)
        portal.start()
        rc, out = self.run_main(self.env(portal, WDP_PROVIDERS=f"{GUID_A}:9"))
        portal.join(5)
        self.assertEqual(rc, wdp_etw.EX_USAGE, out)
        self.assertIn("PROVIDERS-INVALID", out)
        self.assertEqual(portal.accepted, 0)

    def test_invalid_duration_is_refused_without_connecting(self):
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, deadline=1.0)
        portal.start()
        rc, out = self.run_main(self.env(portal, WDP_DURATION="soon"))
        portal.join(5)
        self.assertEqual(rc, wdp_etw.EX_USAGE, out)
        self.assertIn("DURATION-INVALID", out)
        self.assertEqual(portal.accepted, 0)

    def test_missing_required_variable_is_refused(self):
        env = self.env(type("P", (), {"port": 1})())
        del env["WDP_OUT"]
        rc, out = self.run_main(env)
        self.assertEqual(rc, wdp_etw.EX_USAGE, out)
        self.assertIn("ENV-MISSING WDP_OUT", out)

    def test_sink_write_failure_after_ws_open_is_reported_not_raised(self):
        """m-1: once the capture is running (providers already enabled), an OSError from the
        JSONL sink must not escape main() -- it is reported as OUT-UNWRITABLE/EX_USAGE, and
        the providers this session turned on are still turned off (the finally block runs)."""
        batch1 = json.dumps({"Frequency": 10000000, "Events": [{"ID": 1}]}).encode()
        script = [("await-commands", 2), ("send", server_frame(0x1, batch1)), ("await-close", None)]
        portal = FakePortal(self.cert, self.key, self.USER, self.PW, script=script)
        portal.start()
        env = self.env(portal, WDP_DURATION="30")
        out_path = env["WDP_OUT"]

        class FailingSink:
            def write(self, data):
                raise OSError(28, "No space left on device")

            def close(self):
                pass

        real_open = builtins.open

        def fake_open(path, *args, **kwargs):
            if path == out_path:
                return FailingSink()
            return real_open(path, *args, **kwargs)

        with unittest.mock.patch.object(wdp_etw, "open", fake_open, create=True):
            rc, out = self.run_main(env)
        portal.join(10)
        self.assertEqual(rc, wdp_etw.EX_USAGE, out)
        self.assertIn("OUT-UNWRITABLE", out)
        self.assertNotIn("Traceback", out)
        self.assertEqual(portal.commands[:2], [f"provider {GUID_A} enable 5", f"provider {GUID_B} enable 4"])
        self.assertEqual(portal.commands[2:], [f"provider {GUID_A} disable", f"provider {GUID_B} disable"])
        self.assertTrue(portal.closed, "client did not send a close frame after the sink failed")
        self.assertFalse(os.path.exists(out_path))

    def test_summary_seconds_are_measured_after_the_close_drain(self):
        """m-11(b): the wait for the portal's own closing frame must count toward the wall
        time SUMMARY reports, not be silently absorbed after the measurement is taken. The
        portal never answers the client's close frame, so the client must burn the full
        DRAIN_TIMEOUT before giving up -- a gap only the fixed code folds into `seconds`."""
        portal = FakePortal(self.cert, self.key, self.USER, self.PW,
                            script=[("await-commands", 2), ("silence", 2.0)], deadline=8.0)
        portal.start()
        env = self.env(portal, WDP_DURATION="1.0")
        started = time.monotonic()
        rc, out = self.run_main(env)
        wall = time.monotonic() - started
        portal.join(10)
        self.assertEqual(rc, 0, out)
        match = re.search(r"seconds=(\d+\.\d)", out)
        self.assertIsNotNone(match, out)
        seconds = float(match.group(1))
        self.assertGreaterEqual(seconds, 1.0, out)
        self.assertAlmostEqual(seconds, wall, delta=0.2, msg=out)


# ------------------------------------------------------------------------------------------
# Source pin: the TLS floor in wdp_etw.py, read on the syntax tree of the file on disk
# ------------------------------------------------------------------------------------------

WDP_ETW_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "wdp_etw.py")

# The frozen run of statements from the try that creates `raw` through the context construction up
# to (not including) the try that wraps the handshake. `raw` is part of it because wrap_socket only
# handshakes inside the call when `raw` is already connected; where `raw` comes from is therefore a
# precondition of the floor. It also freezes the check_hostname / verify_mode lines: changing any
# statement in it needs a deliberate re-freeze of this expectation. Compared as ast.dump (no line
# or column numbers).
FROZEN_PREFIX_SRC = """
try:
    raw = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
except OSError as exc:
    say("CONNECT-FAILED %s errno=%s" % (type(exc).__name__, _errno_of(exc)))
    return EX_UNAVAILABLE
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
context.minimum_version = ssl.TLSVersion.TLSv1_2
"""
# The WHOLE try statement that holds wrap_socket is frozen: body, handlers, else and finally. The
# except branch is inside the freeze on purpose (a retry there with a fresh, unfloored context is
# the way around a floor that is only checked on the first attempt); changing it needs a
# deliberate re-freeze as well.
FROZEN_TRY_SRC = """
try:
    sock = context.wrap_socket(raw, server_hostname=_sni_for(host))
except OSError as exc:
    _close_quietly(raw)
    say("CONNECT-FAILED %s errno=%s" % (type(exc).__name__, _errno_of(exc)))
    return EX_UNAVAILABLE
"""
SSL_ATTRIBUTES = {"CERT_NONE", "PROTOCOL_TLS_CLIENT", "SSLContext", "TLSVersion"}
BYPASS_NAMES = {"setattr", "delattr", "__setattr__", "__dict__", "exec", "eval", "globals",
                "locals", "vars", "set_ciphers", "importlib", "__import__", "__globals__"}
BYPASS_WRITES = {"maximum_version", "options"}
# Closed list: the top-level modules wdp_etw.py imports today (14, ssl included). A new import is
# a new way to reach the ssl module object or a second TLS stack, so it must be a deliberate edit.
ALLOWED_IMPORTS = {"base64", "hashlib", "hmac", "ipaddress", "json", "math", "os", "re", "socket",
                   "ssl", "struct", "sys", "time", "typing"}
# Closed list guarding two sides: the entry points an SSLContext builds sockets / handshakes with
# (class hooks, the module table, frame and traceback access to a caller's locals), and the
# entry points on an SSLSocket that can establish, redo, re-target (context) or strip (unwrap) TLS
# after wrap_socket returned. wdp_etw.py mentions none of them as an attribute today.
GUARDED_ATTRS = {"modules", "sslsocket_class", "sslobject_class", "_create", "_wrap_socket",
                 "_wrap_bio", "wrap_bio", "_getframe", "f_locals", "f_back", "tb_frame",
                 "connect", "connect_ex", "_real_connect", "do_handshake", "context", "_context",
                 "_sslobj", "_connected", "unwrap"}
# Bare names (never attributes: re.compile stays legal) that run code built at run time.
BYPASS_BARE_NAMES = {"compile"}
# Closed list: names that reach a context's floor, its handshake entry points or the ssl module
# object by reflection. A string constant equal to one of them is how a name is smuggled through
# getattr / sys.modules / __import__ without the attribute ever being written out.
GUARDED_STRINGS = {"minimum_version", "maximum_version", "options", "wrap_socket", "SSLContext",
                   "set_ciphers", "TLSVersion", "ssl"} | GUARDED_ATTRS
# Every code the pin function may return; the self-check must carry one decoy per code.
ALL_CODES = frozenset({
    "import-ssl-count", "import-ssl-other", "import-allowlist", "ssl-attrs", "ssl-bare",
    "sslcontext-call", "wrap-socket", "min-version-write", "min-version-mention",
    "max-version-mention", "tlsversion-mention", "bypass-write", "bypass-name", "guarded-string",
    "guarded-attr", "ssl-rebind", "context-rebind", "position", "frozen-sequence",
})


# Where to look for each rule code (the rule is numbered in tls_floor_violations below).
CODE_POINTERS = {
    "import-ssl-count": "rule 1: exactly one module-level plain `import ssl`",
    "import-ssl-other": "rule 1: no `from ssl import ...` / `import ssl as ...` / nested ssl import",
    "import-allowlist": "rule 1: the imported top-level modules differ from ALLOWED_IMPORTS",
    "ssl-attrs": "rule 2: the attributes used on `ssl` differ from SSL_ATTRIBUTES",
    "ssl-bare": "rule 2: the name `ssl` is used other than as `ssl.<attr>`",
    "sslcontext-call": "rule 2: exactly one `ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)` is allowed",
    "wrap-socket": "rule 3: exactly one `context.wrap_socket(...)` call is allowed",
    "min-version-write": "rule 4: the floor must be the single plain assignment "
                         "`context.minimum_version = ssl.TLSVersion.TLSv1_2`",
    "min-version-mention": "rule 4: `minimum_version` may be mentioned exactly once (the floor itself)",
    "max-version-mention": "rule 4: `maximum_version` / `options` must not be mentioned",
    "tlsversion-mention": "rule 4: `TLSVersion` may be mentioned exactly once (the floor itself)",
    "bypass-write": "rule 5: BYPASS_WRITES (maximum_version / options) must not be written",
    "bypass-name": "rule 5: BYPASS_NAMES (setattr, exec, __globals__, ...) or the bare name `compile` appears",
    "guarded-string": "rule 5: a string constant equals a GUARDED_STRINGS name",
    "guarded-attr": "rule 5: an attribute named in GUARDED_ATTRS is mentioned (SSLContext or SSLSocket "
                    "handshake / re-target / strip entry point)",
    "ssl-rebind": "rule 7: the name `ssl` is rebound",
    "context-rebind": "rule 7: the name `context` is rebound (or bound by an import alias / match)",
    "position": "rule 6: the raw-creating try, construct, floor and handshake try must be direct siblings "
                "in one function body, in order, the raw try directly before the construct",
    "frozen-sequence": "rule 6: the run raw-try..floor (FROZEN_PREFIX_SRC) or the whole handshake try "
                       "(FROZEN_TRY_SRC) changed",
}


def floor_failure_message(codes):
    """The assertion message for the real file: one pointer line per broken rule code."""
    lines = ["wdp_etw.py breaks the TLS-floor source pin (rule codes below; see tls_floor_violations):"]
    lines += ["  %s -> %s" % (code, CODE_POINTERS.get(code, "unknown code")) for code in sorted(codes)]
    lines.append("If the edit is deliberate and cannot touch a TLS handshake, update the matching closed list "
                 "or frozen text (ALLOWED_IMPORTS, GUARDED_STRINGS, GUARDED_ATTRS, SSL_ATTRIBUTES, "
                 "FROZEN_PREFIX_SRC, FROZEN_TRY_SRC) as a deliberate re-freeze. If it can touch a handshake, "
                 "first confirm the TLS 1.2 floor still applies on every handshake path.")
    return "\n".join(lines)


def _dumps(source):
    return [ast.dump(node) for node in ast.parse(source).body]


def _is_ssl_attr(node, attr=None):
    return (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
            and node.value.id == "ssl" and (attr is None or node.attr == attr))


def tls_floor_violations(source):
    """Return the set of rule codes the source of wdp_etw.py breaks (empty = the TLS floor is
    pinned). Pure: takes text, returns codes; the real assertion and the self-checks share it."""
    tree = ast.parse(source)
    nodes = list(ast.walk(tree))
    parent = {child: node for node in nodes for child in ast.iter_child_nodes(node)}
    found = set()

    def flag(code):
        assert code in ALL_CODES, code
        found.add(code)

    # 1. import shape: one module-level plain `import ssl`, nothing else touching the module;
    #    the set of imported top-level modules is exactly ALLOWED_IMPORTS.
    plain = [n for n in tree.body if isinstance(n, ast.Import)
             and any(a.name == "ssl" and a.asname is None for a in n.names)]
    other_ssl = 0
    imported = set()
    for n in nodes:
        if isinstance(n, ast.Import):
            imported |= {a.name.split(".")[0] for a in n.names}
            for a in n.names:
                if a.name == "ssl" or a.name.startswith("ssl."):
                    if not (a.name == "ssl" and a.asname is None and n in plain):
                        other_ssl += 1
        elif isinstance(n, ast.ImportFrom):
            imported.add((n.module or "").split(".")[0])
            if (n.module or "").split(".")[0] == "ssl":
                other_ssl += 1
    if len(plain) != 1 or any(len(n.names) != 1 for n in plain):
        flag("import-ssl-count")
    if other_ssl:
        flag("import-ssl-other")
    if imported != ALLOWED_IMPORTS:
        flag("import-allowlist")

    # 2. the only context comes from ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ssl attribute set.
    ssl_attrs = {n.attr for n in nodes if _is_ssl_attr(n)}
    if ssl_attrs != SSL_ATTRIBUTES:
        flag("ssl-attrs")
    bare_ssl = [n for n in nodes if isinstance(n, ast.Name) and n.id == "ssl"
                and not (isinstance(parent.get(n), ast.Attribute) and parent[n].value is n)]
    if bare_ssl:
        flag("ssl-bare")
    ctor_mentions = [n for n in nodes if _is_ssl_attr(n, "SSLContext")]
    ctor_calls = [n for n in nodes if isinstance(n, ast.Call) and _is_ssl_attr(n.func, "SSLContext")]
    if len(ctor_mentions) != 1 or len(ctor_calls) != 1:
        flag("sslcontext-call")
    elif not (len(ctor_calls[0].args) == 1 and not ctor_calls[0].keywords
              and _is_ssl_attr(ctor_calls[0].args[0], "PROTOCOL_TLS_CLIENT")):
        flag("sslcontext-call")

    # 3. exactly one wrap_socket, a call on the name `context`.
    wraps = [n for n in nodes if isinstance(n, ast.Attribute) and n.attr == "wrap_socket"]
    if not (len(wraps) == 1 and isinstance(parent.get(wraps[0]), ast.Call)
            and parent[wraps[0]].func is wraps[0]
            and isinstance(wraps[0].value, ast.Name) and wraps[0].value.id == "context"):
        flag("wrap-socket")

    # 4. the floor is written once, as `context.minimum_version = ssl.TLSVersion.TLSv1_2`.
    writes = [n for n in nodes if isinstance(n, ast.Attribute) and n.attr == "minimum_version"
              and isinstance(n.ctx, (ast.Store, ast.Del))]
    floor_assign = None
    if len(writes) == 1:
        stmt = parent.get(writes[0])
        if (isinstance(stmt, ast.Assign) and stmt.targets == [writes[0]]
                and isinstance(writes[0].value, ast.Name) and writes[0].value.id == "context"
                and isinstance(stmt.value, ast.Attribute) and stmt.value.attr == "TLSv1_2"
                and _is_ssl_attr(stmt.value.value, "TLSVersion")):
            floor_assign = stmt
    if floor_assign is None:
        flag("min-version-write")
    # Any mention of the attribute, in any context: a Load can reach a setter by reflection.
    if len([n for n in nodes if isinstance(n, ast.Attribute) and n.attr == "minimum_version"]) != 1:
        flag("min-version-mention")
    if any(isinstance(n, ast.Attribute) and n.attr in ("maximum_version", "options") for n in nodes):
        flag("max-version-mention")
    if len([n for n in nodes if isinstance(n, ast.Attribute) and n.attr == "TLSVersion"]) != 1:
        flag("tlsversion-mention")

    # 5. no side doors.
    if any(isinstance(n, ast.Attribute) and n.attr in BYPASS_WRITES
           and isinstance(n.ctx, (ast.Store, ast.Del)) for n in nodes):
        flag("bypass-write")
    for n in nodes:
        mentioned = set()
        if isinstance(n, ast.Name):
            mentioned.add(n.id)
        elif isinstance(n, ast.Attribute):
            mentioned.add(n.attr)
        elif isinstance(n, ast.alias):
            mentioned.add(n.name.split(".")[0])
        elif isinstance(n, ast.ImportFrom):
            mentioned.add((n.module or "").split(".")[0])
        elif isinstance(n, ast.Constant) and isinstance(n.value, str):
            mentioned.add(n.value)
        elif isinstance(n, ast.keyword) and n.arg:
            mentioned.add(n.arg)
        if mentioned & BYPASS_NAMES or (isinstance(n, ast.Name) and n.id in BYPASS_BARE_NAMES):
            flag("bypass-name")
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and n.value in GUARDED_STRINGS:
            flag("guarded-string")
        if isinstance(n, ast.Attribute) and n.attr in GUARDED_ATTRS:
            flag("guarded-attr")

    # 7. no rebinding of `ssl` or `context` by any binding form (the Match nodes only exist on
    #    3.10+, so they are matched by type name); `context` is bound once in its function.
    for n in nodes:
        if isinstance(n, ast.Name) and n.id == "ssl" and isinstance(n.ctx, (ast.Store, ast.Del)):
            flag("ssl-rebind")
        if isinstance(n, ast.alias) and n.asname == "ssl":
            flag("ssl-rebind")
        if isinstance(n, ast.ImportFrom):
            for a in n.names:
                if (a.asname or a.name) == "ssl":
                    flag("ssl-rebind")
        if isinstance(n, ast.alias) and (n.asname or n.name.split(".")[0]) == "context":
            flag("context-rebind")
        if isinstance(n, ast.arg) and n.arg == "ssl":
            flag("ssl-rebind")
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and n.name == "ssl":
            flag("ssl-rebind")
        if isinstance(n, ast.ExceptHandler) and n.name == "ssl":
            flag("ssl-rebind")
        if isinstance(n, (ast.Global, ast.Nonlocal)) and "ssl" in n.names:
            flag("ssl-rebind")
        if type(n).__name__ in ("MatchAs", "MatchStar", "MatchMapping"):
            bound = getattr(n, "rest" if type(n).__name__ == "MatchMapping" else "name", None)
            if bound == "ssl":
                flag("ssl-rebind")
            if bound == "context":
                flag("context-rebind")
    func = None
    construct = None
    if len(ctor_calls) == 1:
        assign = parent.get(ctor_calls[0])
        if (isinstance(assign, ast.Assign) and assign.value is ctor_calls[0]
                and len(assign.targets) == 1 and isinstance(assign.targets[0], ast.Name)
                and assign.targets[0].id == "context"
                and isinstance(parent.get(assign), (ast.FunctionDef, ast.AsyncFunctionDef))
                and assign in parent[assign].body):
            func, construct = parent[assign], assign
    if func is None:
        flag("position")
    else:
        rebinds = 0
        for n in ast.walk(func):
            if isinstance(n, ast.Name) and n.id == "context" and isinstance(n.ctx, (ast.Store, ast.Del)):
                rebinds += 1
            elif isinstance(n, ast.arg) and n.arg == "context":
                rebinds += 1
            elif isinstance(n, ast.ExceptHandler) and n.name == "context":
                rebinds += 1
            elif isinstance(n, (ast.Global, ast.Nonlocal)):
                rebinds += 2
            elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and n.name == "context":
                rebinds += 1
        if rebinds != 1:
            flag("context-rebind")

    # 6. position and order: construct, floor, try-with-wrap_socket are direct siblings in the
    #    same function body, strictly increasing, directly after the try that creates `raw`; the run
    #    from that try to the handshake try and the whole handshake try are frozen.
    if func is not None and floor_assign is not None and len(wraps) == 1:
        body = func.body
        try_stmt = next((s for s in body if isinstance(s, ast.Try)
                         and any(n is wraps[0] for n in ast.walk(s))), None)
        in_body = floor_assign in body and try_stmt is not None
        ci = body.index(construct) if construct in body else -1
        if (not in_body or ci < 1 or not isinstance(body[ci - 1], ast.Try)
                or not (ci < body.index(floor_assign) < body.index(try_stmt))):
            flag("position")
        else:
            run = body[ci - 1:body.index(try_stmt)]
            if ([ast.dump(s) for s in run] != _dumps(FROZEN_PREFIX_SRC)
                    or [ast.dump(try_stmt)] != _dumps(FROZEN_TRY_SRC)):
                flag("frozen-sequence")
    return found


MINIMAL_GOOD = "".join("import %s\n" % m for m in sorted(ALLOWED_IMPORTS)) + '''

def main(host, port):
    """Docstring."""
    try:
        raw = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
    except OSError as exc:
        say("CONNECT-FAILED %s errno=%s" % (type(exc).__name__, _errno_of(exc)))
        return EX_UNAVAILABLE
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    try:
        sock = context.wrap_socket(raw, server_hostname=_sni_for(host))
    except OSError as exc:
        _close_quietly(raw)
        say("CONNECT-FAILED %s errno=%s" % (type(exc).__name__, _errno_of(exc)))
        return EX_UNAVAILABLE
    return sock
'''
REFLECT_HELPER = (
    "def _sni_for(host):\n"
    '    _c = sys._getframe(1).f_locals["context"]\n'
    "    type(_c).minimum_version.__set__(_c, 769)\n"
    "\n\n"
)
FLOOR_LINE = "    context.minimum_version = ssl.TLSVersion.TLSv1_2\n"
TAIL_LINE = "    return sock\n"
HANDLER_LINE = "        return EX_UNAVAILABLE\n"
RAW_LINE = "        raw = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)\n"


class TlsFloorSourcePinTests(unittest.TestCase):
    """Source pin for the TLS 1.2 floor in wdp_etw.py. It guards: exactly one literal
    `ssl.SSLContext(...)` construction; the statements from the try that creates `raw` through the
    construction and floor, and the whole handshake `try`, frozen; and closed lists for imports,
    reflection entry points and SSLSocket connect / re-target / strip entry points. Together that
    pins: the handshake happens only inside the frozen `wrap_socket` call, on the `raw` created and
    connected in the frozen run, with the context that run gives the TLS 1.2 floor. It reads the
    tree of the file on disk, so a comment, a docstring or a dead branch cannot stand in for the
    floor line. It cannot prove what a called function does, names assembled at run time, code
    strings that are executed, reflection paths outside the lists, shadowing inside `main` of a
    function the frozen run calls, or another module altering the `ssl` object; the two loopback
    behaviour cases cover part of that at run time."""

    def mutate(self, replacement, extra_after=None):
        self.assertEqual(MINIMAL_GOOD.count(FLOOR_LINE), 1)
        text = MINIMAL_GOOD.replace(FLOOR_LINE, replacement)
        if extra_after is not None:
            text = text.replace("    try:\n        sock =", extra_after + "    try:\n        sock =")
        return text

    def replace_last(self, old, new):
        i = MINIMAL_GOOD.rindex(old)
        return MINIMAL_GOOD[:i] + new + MINIMAL_GOOD[i + len(old):]

    def before_return(self, line):
        self.assertEqual(MINIMAL_GOOD.count(TAIL_LINE), 1)
        return MINIMAL_GOOD.replace(TAIL_LINE, line + TAIL_LINE)

    def test_the_pin_logic_accepts_the_fixed_shape_and_rejects_each_decoy_for_its_own_reason(self):
        self.assertEqual(tls_floor_violations(MINIMAL_GOOD), set())
        gone = {"min-version-write", "min-version-mention", "ssl-attrs", "tlsversion-mention"}
        decoys = {
            "comment": (self.mutate("    # context.minimum_version = ssl.TLSVersion.TLSv1_2\n"), gone),
            "docstring": (MINIMAL_GOOD.replace('"""Docstring."""',
                                               '"""context.minimum_version = ssl.TLSVersion.TLSv1_2"""')
                          .replace(FLOOR_LINE, ""), gone),
            "dead-branch": (self.mutate("    if False:\n    " + FLOOR_LINE), {"position"}),
            "setattr": (self.mutate('    setattr(context, "minimum_version", ssl.TLSVersion.TLSv1_2)\n'),
                        {"min-version-write", "min-version-mention", "bypass-name", "guarded-string"}),
            "second-context": (self.mutate(FLOOR_LINE, "    other = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)\n"),
                               {"sslcontext-call", "position"}),
            "from-import": ("from ssl import TLSVersion\n" + MINIMAL_GOOD, {"import-ssl-other"}),
            "rebinding": (self.before_return("    context = None\n"), {"context-rebind"}),
            "reflective-load": (MINIMAL_GOOD.replace("def main(", REFLECT_HELPER + "def main("),
                                {"min-version-mention", "guarded-attr", "guarded-string"}),
            "lowered-floor": (self.mutate(FLOOR_LINE + "    context.minimum_version = ssl.TLSVersion.TLSv1\n"),
                              {"min-version-write", "min-version-mention", "tlsversion-mention"}),
            # the retry shape that got past the first pin: a fresh unfloored context in the except
            "except-redial": (self.replace_last(HANDLER_LINE, "        legacy = type(context)(ssl.PROTOCOL_TLS_CLIENT)\n"
                                                + HANDLER_LINE), {"frozen-sequence"}),
            # the Y1 shape: an unconnected raw, then the socket is re-targeted and connected later
            "unconnected-raw-retarget": (MINIMAL_GOOD.replace(RAW_LINE, "        raw = socket.socket()\n").replace(
                TAIL_LINE, "    sock.context = other\n    sock.connect((host, port))\n" + TAIL_LINE),
                                         {"frozen-sequence", "guarded-attr"}),
            "raw-origin": (MINIMAL_GOOD.replace(RAW_LINE, "        raw = socket.socket()\n"), {"frozen-sequence"}),
            "getattr-guarded": (self.before_return('    _f = getattr(sock, "do_handshake")\n'), {"guarded-string"}),
            "bare-compile": (self.before_return('    compile("1", "<x>", "single")\n'), {"bypass-name"}),
            "globals-attr": (self.before_return("    _g = say.__globals__\n"), {"bypass-name"}),
            "unwrap-call": (self.before_return("    sock.unwrap()\n"), {"guarded-attr"}),
            "options-load": (self.before_return("    _o = context.options\n"), {"max-version-mention"}),
            "extra-import": ("import http.client\n" + MINIMAL_GOOD, {"import-allowlist"}),
            "missing-import": (MINIMAL_GOOD.replace("import ssl\n", ""),
                               {"import-ssl-count", "import-allowlist"}),
            "guarded-string": (self.before_return('    _name = "wrap_bio"\n'), {"guarded-string"}),
            "handshake-attr": (self.before_return("    _x = sock.sslsocket_class\n"), {"guarded-attr"}),
            "bare-ssl": (self.before_return("    _m = ssl\n"), {"ssl-bare"}),
            "second-wrap": (self.before_return("    other.wrap_socket(raw)\n"), {"wrap-socket"}),
            "max-version-load": (self.before_return("    _m = context.maximum_version\n"), {"max-version-mention"}),
            "options-write": (self.before_return("    context.options |= 0\n"), {"bypass-write", "max-version-mention"}),
            "ssl-rebound": (self.before_return("    ssl = None\n"), {"ssl-rebind", "ssl-bare"}),
            "ssl-attr": (self.before_return("    _v = ssl.OP_NO_TLSv1\n"), {"ssl-attrs"}),
            "alias-context": ("import types as context\n" + MINIMAL_GOOD, {"context-rebind", "import-allowlist"}),
            "from-import-ssl-name": ("from urllib.request import ssl\n" + MINIMAL_GOOD,
                                     {"ssl-rebind", "import-allowlist"}),
        }
        if sys.version_info >= (3, 10):
            decoys["match-mapping-rest"] = (
                self.before_return("    match raw:\n        case {**context}:\n            pass\n"), {"context-rebind"})
        for name, (text, want) in decoys.items():
            with self.subTest(decoy=name):
                compile(text, name, "exec")
                self.assertEqual(tls_floor_violations(text), want)
        # A rule added without a decoy (or a decoy for a code that no longer exists) turns red.
        self.assertEqual(set().union(*(want for _, want in decoys.values())), set(ALL_CODES))
        self.assertEqual(set(CODE_POINTERS), set(ALL_CODES))
        self.assertTrue(GUARDED_ATTRS <= GUARDED_STRINGS)
        # Counter-example: an attribute call named compile (re.compile) is legal and must stay green.
        self.assertEqual(tls_floor_violations(self.before_return('    re.compile("x")\n')), set())
        # The failure message must point at the list / text behind each code that actually fired.
        text = "import http.client\n" + self.before_return('    _name = "wrap_bio"\n')
        message = floor_failure_message(tls_floor_violations(text))
        self.assertIn("import-allowlist -> rule 1", message)
        self.assertIn("ALLOWED_IMPORTS", message)
        self.assertIn("guarded-string -> rule 5", message)
        self.assertIn("GUARDED_STRINGS", message)
        self.assertNotIn("frozen-sequence", message)

    def test_wdp_etw_sets_the_tls_1_2_floor_exactly_once_and_in_place(self):
        with open(WDP_ETW_PATH, encoding="utf-8") as f:
            source = f.read()
        found = tls_floor_violations(source)
        self.assertEqual(found, set(), floor_failure_message(found))


if __name__ == "__main__":
    unittest.main()

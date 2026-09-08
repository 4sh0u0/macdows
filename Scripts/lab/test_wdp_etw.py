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
import base64
import hashlib
import io
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

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

class FakePortal(threading.Thread):
    """One-connection TLS WebSocket server. `script` decides what it does after the upgrade:
    a list of ('send', bytes) / ('await', kind) steps. Records everything the client sent."""

    def __init__(self, certfile, keyfile, user, pw, mode="ok", script=None, deadline=8.0):
        super().__init__(daemon=True)
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(certfile, keyfile)
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

    def run(self):
        try:
            self._serve()
        except Exception as exc:  # recorded, asserted by the test
            self.errors.append(repr(exc))
        finally:
            self.listener.close()

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
        s = self.ctx.wrap_socket(raw, server_side=True)
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


if __name__ == "__main__":
    unittest.main()

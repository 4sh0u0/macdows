import CryptoKit
import Foundation
import MacdowsCore
import Testing

// ADR-0024 D-10 ③ and ④ (bridge half): the certificate callback's decision, run offline through
// the same static function the FreeRDP callback calls, on FreeRDP's own vendored test certificates,
// and the bridge's security settings pinned as source.

private func certRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func vendoredPEM(_ name: String) throws -> Data {
    try Data(contentsOf: certRepoRoot().appendingPathComponent("ThirdParty/FreeRDP/libfreerdp/crypto/test/\(name)"))
}

/// The first PEM block's DER, SHA-256'd independently of FreeRDP (CryptoKit), lower-case hex.
private func independentLeafSHA256(_ pem: Data) throws -> String {
    let text = String(decoding: pem, as: UTF8.self)
    let begin = try #require(text.range(of: "-----BEGIN CERTIFICATE-----"))
    let end = try #require(text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex))
    let body = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
    let der = try #require(Data(base64Encoded: String(body)))
    return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
}

@Suite("ADR-0024 D-4 / D-10 ③ — the certificate callback, offline")
struct CertificateCallbackTests {
    static let redirect: UInt32 = 0x10
    static let gateway: UInt32 = 0x20
    static let legacy: UInt32 = 0x02

    @Test("the bridge's fingerprint is the leaf DER's SHA-256, canonical form", arguments: ["rsa_pss_sha256_cert.pem", "ecdsa_sha256_cert.pem", "rsa_pkcs1_sha256_cert.pem"])
    func fingerprintIsLeafDERSHA256(_ name: String) throws {
        let pem = try vendoredPEM(name)
        let bridge = try #require(CRSession.sha256Fingerprint(ofCertificatePEM: pem))
        #expect(bridge == (try independentLeafSHA256(pem)))
        #expect(CertificateFingerprint(canonical: bridge)?.canonical == bridge, "already canonical")
    }

    @Test("a chain: only the first (leaf) certificate is fingerprinted")
    func chainUsesLeaf() throws {
        let leaf = try vendoredPEM("rsa_pss_sha256_cert.pem")
        let other = try vendoredPEM("ecdsa_sha256_cert.pem")
        let chain = leaf + Data("\n".utf8) + other
        #expect(CRSession.sha256Fingerprint(ofCertificatePEM: chain) == (try independentLeafSHA256(leaf)))
    }

    @Test("a buffer without a NUL terminator is read by its length")
    func lengthNotTerminator() throws {
        let pem = try vendoredPEM("rsa_pss_sha256_cert.pem")
        var padded = pem
        padded.append(contentsOf: [0x41, 0x41, 0x41])
        let exact = padded.prefix(pem.count)
        #expect(CRSession.sha256Fingerprint(ofCertificatePEM: Data(exact)) == (try independentLeafSHA256(pem)))
    }

    @Test("accept: 2 when the presented fingerprint is the accepted one, compared ignoring case")
    func acceptsTheAcceptedFingerprint() throws {
        let pem = try vendoredPEM("rsa_pss_sha256_cert.pem")
        let fp = try independentLeafSHA256(pem)
        for accepted in [fp, fp.uppercased()] {
            var rejection: CRCertificateRejection?
            #expect(CRSession.certificateVerdict(forPEM: pem, flags: 0, acceptedFingerprint: accepted, rejection: &rejection) == 2)
            #expect(rejection == nil)
        }
        var rejection: CRCertificateRejection?
        #expect(CRSession.certificateVerdict(forPEM: pem, flags: Self.legacy, acceptedFingerprint: fp, rejection: &rejection) == 2,
                "LEGACY alone is not a route flag")
    }

    @Test("reject: 0 with a rejection record for another fingerprint, for none, and for a REDIRECT / GATEWAY route")
    func rejects() throws {
        let pem = try vendoredPEM("rsa_pss_sha256_cert.pem")
        let fp = try independentLeafSHA256(pem)
        let other = String(repeating: "0", count: 64)
        let cases: [(String?, UInt32, Bool)] = [
            (other, 0, false), (nil, 0, false), ("", 0, false), (String(fp.dropLast()), 0, false),
            (fp, Self.redirect | Self.legacy, true), (fp, Self.gateway | Self.legacy, true),
        ]
        for (accepted, flags, route) in cases {
            var rejection: CRCertificateRejection?
            let verdict = CRSession.certificateVerdict(forPEM: pem, flags: flags, acceptedFingerprint: accepted, rejection: &rejection)
            #expect(verdict == 0, "\(String(describing: accepted)) \(flags)")
            let record = try #require(rejection)
            #expect(record.sha256Fingerprint == fp)
            #expect(record.flags == flags)
            #expect(record.unsupportedRoute == route)
            #expect(!record.subject.isEmpty)
        }
    }

    @Test("an unparsable certificate is rejected with no fingerprint; the answer is never negative")
    func garbageIsRejected() throws {
        for bytes in [Data(), Data("not a certificate".utf8), Data("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n".utf8)] {
            var rejection: CRCertificateRejection?
            let verdict = CRSession.certificateVerdict(forPEM: bytes, flags: 0, acceptedFingerprint: String(repeating: "a", count: 64), rejection: &rejection)
            #expect(verdict == 0)
            #expect(verdict >= 0)
            #expect(rejection?.sha256Fingerprint == nil)
        }
    }
}

// MARK: - ④ source pins on the bridge (ADR-0024 D-4 / D-7 / D-8)

private func certCodeOnly(_ text: String) -> String {
    // Block and line comments removed, whitespace folded.
    var out = ""
    var index = text.startIndex
    while index < text.endIndex {
        if text[index...].hasPrefix("/*"), let close = text.range(of: "*/", range: index..<text.endIndex) {
            index = close.upperBound
            out.append(" ")
        } else if text[index...].hasPrefix("//") {
            index = text[index...].firstIndex(of: "\n") ?? text.endIndex
        } else {
            out.append(text[index])
            index = text.index(after: index)
        }
    }
    return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func certOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Suite("ADR-0024 D-10 ④ — the bridge's certificate and security wiring, pinned as source")
struct BridgeSecurityPinTests {
    static func bridge() throws -> String {
        certCodeOnly(try String(contentsOf: certRepoRoot().appendingPathComponent("App/CRBridge/CRSession.mm"), encoding: .utf8))
    }

    @Test("W-b: ExternalCertificateManagement on, accepted-fingerprints emptied, VerifyX509Certificate hooked, the other two are constant-reject stubs")
    func externalCertificateManagement() throws {
        let code = try Self.bridge()
        #expect(certOccurrences(of: "freerdp_settings_set_bool(settings, FreeRDP_ExternalCertificateManagement, TRUE)", in: code) == 1)
        #expect(certOccurrences(of: "freerdp_settings_set_string(settings, FreeRDP_CertificateAcceptedFingerprints, NULL)", in: code) == 1)
        #expect(certOccurrences(of: "instance->VerifyX509Certificate = crb_verify_x509_certificate;", in: code) == 1)
        #expect(certOccurrences(of: "instance->VerifyCertificateEx = crb_verify_certificate_ex;", in: code) == 1)
        #expect(certOccurrences(of: "instance->VerifyChangedCertificateEx = crb_verify_changed_certificate_ex;", in: code) == 1)
        for stub in ["static DWORD crb_verify_certificate_ex(", "static DWORD crb_verify_changed_certificate_ex("] {
            let start = try #require(code.range(of: stub))
            let end = try #require(code.range(of: "return 0; }", range: start.upperBound..<code.endIndex))
            let body = code[start.lowerBound..<end.upperBound]
            #expect(!body.contains("return 1") && !body.contains("return 2"), "\(stub) never accepts")
        }
        #expect(certOccurrences(of: "return match ? 2 : 0;", in: code) == 1, "the verdict is 2 or 0, never negative")
    }

    @Test("L-c: RDP and TLS-only security are off, NLA on; AAD / RDSTLS off; Ext untouched")
    func securityLayers() throws {
        let code = try Self.bridge()
        #expect(certOccurrences(of: "freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE)", in: code) == 1)
        #expect(certOccurrences(of: "freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, FALSE)", in: code) == 1)
        #expect(certOccurrences(of: "freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE)", in: code) == 1)
        #expect(certOccurrences(of: "freerdp_settings_set_bool(settings, FreeRDP_AadSecurity, FALSE)", in: code) == 1)
        #expect(certOccurrences(of: "freerdp_settings_set_bool(settings, FreeRDP_RdstlsSecurity, FALSE)", in: code) == 1)
        #expect(certOccurrences(of: "FreeRDP_ExtSecurity", in: code) == 0)
        #expect(certOccurrences(of: "FreeRDP_TlsSecurity, TRUE", in: code) == 0)
        #expect(certOccurrences(of: "FreeRDP_RdpSecurity, TRUE", in: code) == 0)
    }

    @Test("the Debug insecure-certificate macro is gone from every App and Tools source and from project.yml")
    func insecureMacroIsGone() throws {
        let literal = "CRB_ALLOW_" + "INSECURE_CERT"
        var scanned = 0
        for directory in ["App", "Tools"] {
            let root = certRepoRoot().appendingPathComponent(directory)
            let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where ["swift", "mm", "m", "h", "c", "yml"].contains(url.pathExtension) {
                if url.path.contains(".xcodeproj/") || url.path.contains("/build/") { continue }
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                #expect(!text.contains(literal), "\(url.lastPathComponent)")
            }
        }
        #expect(scanned > 50, "the walk found the sources (\(scanned))")
    }

    @Test("Y-b: the rejection is cleared on every -start and published by the callback; the password goes through the scratch-and-wipe helper")
    func rejectionLifecycle() throws {
        let code = try Self.bridge()
        #expect(certOccurrences(of: "self.lastConnectError = nil; self.lastCertificateRejection = nil;", in: code) == 1)
        #expect(certOccurrences(of: "session.lastCertificateRejection = rejection;", in: code) == 1)
        #expect(certOccurrences(of: "!crb_apply_password(context->settings, _passwordBytes)", in: code) == 1)
        #expect(certOccurrences(of: "FreeRDP_Password", in: code) == 1, "one place sets the password")
        #expect(certOccurrences(of: "memset_s(scratch, length + 1, 0, length + 1);", in: code) == 1)
        #expect(certOccurrences(of: "memset_s(_passwordBytes.mutableBytes, _passwordBytes.length, 0, _passwordBytes.length);", in: code) == 1)
    }

    @Test("F-3: the WLog root is fixed through the API, the environment is cleared first, and the App's Swift sources never name WLOG_")
    func wlogPinned() throws {
        let code = try Self.bridge()
        let start = try #require(code.range(of: "+ (BOOL)pinProcessLogConfiguration {"))
        let end = try #require(code.range(of: "return YES; }", range: start.upperBound..<code.endIndex))
        let body = String(code[start.lowerBound..<end.upperBound])
        let unset = try #require(body.range(of: "unsetenv(ignored[i]);"))
        let root = try #require(body.range(of: "WLog_GetRoot()"))
        #expect(unset.lowerBound < root.lowerBound, "the variables are gone before the root logger can be created")
        #expect(body.contains("WLog_SetLogAppenderType(root, WLOG_APPENDER_CONSOLE)"))
        #expect(body.contains("WLog_SetLogLevel(root, WLOG_INFO)"))
        for name in ["WLOG_APPENDER", "WLOG_LEVEL", "WLOG_FILTER", "WLOG_PREFIX", "WLOG_FILEAPPENDER_OUTPUT_FILE_PATH",
                     "WLOG_FILEAPPENDER_OUTPUT_FILE_NAME", "WLOG_UDP_TARGET", "WLOG_JOURNALD_ID"] {
            #expect(body.contains("\"\(name)\""), "\(name)")
        }
        #expect(certOccurrences(of: "getenv(", in: code) == 0)

        var scanned = 0
        for directory in ["App/Macdows", "App/SessionControl", "App/RemoteWindowRendering", "App/Security", "App/UI"] {
            let root = certRepoRoot().appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("WLOG" + "_"), "\(url.lastPathComponent)")
            }
        }
        #expect(scanned > 5)
        let main = certCodeOnly(try String(contentsOf: certRepoRoot().appendingPathComponent("App/Macdows/main.swift"), encoding: .utf8))
        #expect(main.hasPrefix("import AppKit if !CRSession.pinProcessLogConfiguration() { fputs("), "the App's first statement")
        #expect(certOccurrences(of: "pinProcessLogConfiguration()", in: main) == 1)
    }
}

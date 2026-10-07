import Testing

@testable import MacdowsCore

/// ADR-0024 D-10 ⑦: the export white list -- one positive case per registered shape, and the
/// key-witness / account / PEM / home-path negatives; `a_include` admits exactly two classes.
@Suite("DiagnosticExportFilter (ADR-0024 D-8, X-b)")
struct DiagnosticExportFilterTests {
    typealias F = DiagnosticExportFilter
    static let home = "/tmp/home-placeholder"

    static func run(_ lines: [F.Line], include: Bool = false) -> F.Result {
        F.export(lines, includeAccountAndKeyWitness: include, homeDirectory: home)
    }

    @Test("each registered shape exports its positive example")
    func positives() {
        let lines: [F.Line] = [
            .init(source: .freerdp, level: .warn, tag: F.bridgeTag, message: "[cert] rejected sha256=00 flags=0x0 route=0"),
            .init(source: .app, level: .info, tag: "Reconnect", message: "[reconnect] attempt=0 delay-ms=1000 state=waiting cause="),
            .init(source: .freerdp, level: .error, tag: "com.freerdp.core.transport", message: "BIO_read returned an error"),
        ]
        let result = Self.run(lines)
        #expect(result.withheld == 0)
        #expect(result.exported.count == 3)
    }

    @Test("default deny: an unregistered line, and a FreeRDP line under the Standard floor, are withheld and counted")
    func defaultDeny() {
        let lines: [F.Line] = [
            .init(source: .app, level: .info, tag: "Somewhere", message: "a brand new line"),
            .init(source: .freerdp, level: .info, tag: "com.freerdp.core.nego", message: "info level"),
            .init(source: .freerdp, level: .debug, tag: "com.freerdp.core.info", message: "UserName: x"),
        ]
        let result = Self.run(lines)
        #expect(result.exported.isEmpty)
        #expect(result.withheld == 3)
    }

    @Test("[key-witness] lines are withheld unless a_include is on")
    func keyWitness() {
        let line = F.Line(source: .freerdp, level: .info, tag: F.bridgeTag, message: "[key-witness] seq=1 kind=scancode flags=0x0000 code=0x1e rc=1")
        #expect(Self.run([line]).exported.isEmpty)
        #expect(Self.run([line]).withheld == 1)
        #expect(Self.run([line], include: true).exported.count == 1)
    }

    @Test("the account segment is masked unless a_include is on")
    func accountSegment() {
        let line = F.Line(source: .app, level: .info, tag: "Connect", message: "[connect] host=workstation.example user=someone port=3389")
        #expect(Self.run([line]).exported == ["app Connect [connect] host=workstation.example user=<account> port=3389"])
        #expect(Self.run([line], include: true).exported == ["app Connect [connect] host=workstation.example user=someone port=3389"])
    }

    @Test("PEM text is never exported, with or without a_include, even on a registered shape")
    func pemNeverExported() {
        let lines: [F.Line] = [
            .init(source: .freerdp, level: .error, tag: "com.freerdp.crypto", message: "VerifyX509Certificate failed: -----BEGIN CERTIFICATE-----MIIB"),
            .init(source: .freerdp, level: .warn, tag: F.bridgeTag, message: "[cert] -----END CERTIFICATE-----"),
        ]
        #expect(Self.run(lines).exported.isEmpty)
        #expect(Self.run(lines, include: true).exported.isEmpty)
        #expect(Self.run(lines, include: true).withheld == 2)
    }

    @Test("the home directory prefix becomes ~")
    func homePath() {
        let line = F.Line(source: .freerdp, level: .warn, tag: "com.freerdp.utils", message: "cannot open /tmp/home-placeholder/.config/freerdp/server")
        #expect(Self.run([line]).exported == ["freerdp com.freerdp.utils cannot open ~/.config/freerdp/server"])
    }

    @Test("a_include admits exactly the key-witness and account classes; nothing unregistered appears")
    func includeAdmitsOnlyTwoClasses() {
        let unregistered = F.Line(source: .app, level: .error, tag: "Keychain", message: "service=x account=y")
        #expect(Self.run([unregistered], include: true).exported.isEmpty)
    }
}

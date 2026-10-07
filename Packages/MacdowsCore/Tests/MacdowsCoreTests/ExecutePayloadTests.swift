import CRDPQueue
import Testing

@testable import MacdowsCore

// ADR-0025 R-4 / §3.1 item 5: the execute payload's shared buffer -- program + NUL + arguments in
// one `crdpq_text_t`, `length` counting both and the separator -- written by `crdpq_execute_set`
// and split by `crdpq_execute_arguments_offset`, the two helpers `CRSession.mm` uses on either side
// of the outbound queue. `flags` stays deferred to a-2, so the outbound sizes do not move: the
// 260 / 264 pins in `CRDPQueueTests.reportSizes` are left exactly as they were.

private typealias Payload = crdpq_cmd_execute_t

private func bytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

/// Calls the C packer with explicit byte counts; nil passes a NULL pointer.
private func pack(_ payload: inout Payload, _ program: [UInt8]?, _ arguments: [UInt8]?) -> crdpq_execute_set_result_t {
    func call(_ p: UnsafePointer<CChar>?, _ pLen: Int, _ a: UnsafePointer<CChar>?, _ aLen: Int) -> crdpq_execute_set_result_t {
        crdpq_execute_set(&payload, p, pLen, a, aLen)
    }
    func withPointer<R>(_ value: [UInt8]?, _ body: (UnsafePointer<CChar>?, Int) -> R) -> R {
        guard let value else { return body(nil, 0) }
        // A one-byte scratch keeps the pointer non-NULL for an empty, non-nil part.
        let storage = value.isEmpty ? [UInt8(0)] : value
        return storage.withUnsafeBytes { raw in
            body(raw.baseAddress?.assumingMemoryBound(to: CChar.self), value.count)
        }
    }
    return withPointer(program) { p, pLen in
        withPointer(arguments) { a, aLen in call(p, pLen, a, aLen) }
    }
}

private func buffer(_ payload: Payload) -> [UInt8] {
    withUnsafeBytes(of: payload.program.bytes) { Array($0) }
}

/// The C string starting at `offset` in the payload's buffer.
private func cString(_ payload: Payload, at offset: Int) -> [UInt8] {
    Array(buffer(payload)[offset...].prefix { $0 != 0 })
}

/// What the outbound visitor hands to RAIL: the program, and the arguments when the split finds any.
private func split(_ payload: Payload) -> (program: [UInt8], arguments: [UInt8]?) {
    var copy = payload
    let at = crdpq_execute_arguments_offset(&copy)
    return (cString(payload, at: 0), at > 0 ? cString(payload, at: at) : nil)
}

@Suite("execute payload: program + NUL + arguments share one 256-byte buffer (ADR-0025 R-4)")
struct ExecutePayloadTests {

    @Test("program only: byte-for-byte the payload crdpq_text_set has always written")
    func programOnlyIsTheOldShape() {
        var packed = Payload()
        #expect(pack(&packed, bytes(#"C:\Windows\System32\notepad.exe"#), nil) == CRDPQ_EXECUTE_SET_OK)
        var legacy = Payload()
        let program = #"C:\Windows\System32\notepad.exe"#
        program.withCString { crdpq_text_set(&legacy.program, $0, strlen($0)) }
        #expect(buffer(packed) == buffer(legacy))
        #expect(packed.program.length == legacy.program.length)
        #expect(packed.program.length == UInt16(program.utf8.count))
        #expect(!packed.program.truncated)
        #expect(crdpq_execute_arguments_offset(&packed) == 0)
        #expect(crdpq_execute_arguments_offset(&legacy) == 0)
        // Empty (non-NULL) arguments are no arguments too.
        var emptyArguments = Payload()
        #expect(pack(&emptyArguments, bytes(program), []) == CRDPQ_EXECUTE_SET_OK)
        #expect(buffer(emptyArguments) == buffer(legacy))
    }

    @Test("with arguments: the bytes, the length and the split follow the shared-buffer rule")
    func programAndArguments() {
        var payload = Payload()
        let program = bytes(#"C:\Tools\Example.exe"#)
        let arguments = bytes(#"/open "C:\Tools\a b.txt""#)
        #expect(pack(&payload, program, arguments) == CRDPQ_EXECUTE_SET_OK)
        let expected = program + [0] + arguments + [0]
        #expect(Array(buffer(payload).prefix(expected.count)) == expected)
        // Every byte after the final NUL is zero.
        #expect(buffer(payload)[expected.count...].allSatisfy { $0 == 0 })
        // length = program + separator + arguments, the final NUL excluded.
        #expect(Int(payload.program.length) == program.count + 1 + arguments.count)
        #expect(!payload.program.truncated)
        #expect(crdpq_execute_arguments_offset(&payload) == program.count + 1)
        let parts = split(payload)
        #expect(parts.program == program)
        #expect(parts.arguments == arguments)
    }

    @Test("repacking a used payload leaves no byte of the old command behind")
    func repackClearsTheTail() {
        var reused = Payload()
        #expect(pack(&reused, bytes(#"C:\Tools\Example.exe"#), bytes(String(repeating: "x", count: 200))) == CRDPQ_EXECUTE_SET_OK)
        #expect(pack(&reused, bytes("notepad.exe"), bytes("a")) == CRDPQ_EXECUTE_SET_OK)
        var fresh = Payload()
        #expect(pack(&fresh, bytes("notepad.exe"), bytes("a")) == CRDPQ_EXECUTE_SET_OK)
        #expect(buffer(reused) == buffer(fresh))
        #expect(reused.program.length == 13)
        #expect(split(reused).arguments == bytes("a"))
    }

    @Test("a round trip through the outbound queue keeps both halves")
    func outboundRoundTrip() {
        let q = crdpq_outbound_create(nil, nil)
        defer { crdpq_outbound_destroy(q) }
        let cases: [(String, String?)] = [
            (#"C:\Tools\Example.exe"#, #"--flag "C:\Tools\a b.txt""#),
            ("notepad.exe", nil),
            ("工具.exe", "é 😀"),
            (String(repeating: "a", count: 200), String(repeating: "b", count: 54)),
        ]
        for (program, arguments) in cases {
            var cmd = CrdpCommand()
            cmd.type = CRDPQ_CMD_EXECUTE
            #expect(pack(&cmd.payload.execute, bytes(program), arguments.map(bytes)) == CRDPQ_EXECUTE_SET_OK)
            #expect(crdpq_outbound_post(q, &cmd))
        }
        var drained: [CrdpCommand] = []
        withUnsafeMutablePointer(to: &drained) { outPtr in
            _ = crdpq_outbound_drain(
                q,
                { cmd, vctx in
                    vctx!.assumingMemoryBound(to: [CrdpCommand].self).pointee.append(cmd!.pointee)
                },
                UnsafeMutableRawPointer(outPtr)
            )
        }
        #expect(drained.count == cases.count)
        for (cmd, expected) in zip(drained, cases) {
            #expect(cmd.type == CRDPQ_CMD_EXECUTE)
            let parts = split(cmd.payload.execute)
            #expect(parts.program == bytes(expected.0))
            #expect(parts.arguments == expected.1.map(bytes))
        }
    }

    @Test("255 bytes between them is accepted, 256 is refused, and a refusal writes nothing")
    func boundary() {
        func result(_ programCount: Int, _ argumentsCount: Int?) -> crdpq_execute_set_result_t {
            var payload = Payload()
            return pack(&payload, [UInt8](repeating: 0x61, count: programCount),
                        argumentsCount.map { [UInt8](repeating: 0x62, count: $0) })
        }
        #expect(result(255, nil) == CRDPQ_EXECUTE_SET_OK)
        #expect(result(256, nil) == CRDPQ_EXECUTE_SET_TOO_LONG)
        #expect(result(200, 54) == CRDPQ_EXECUTE_SET_OK)          // 200 + 1 + 54 = 255
        #expect(result(200, 55) == CRDPQ_EXECUTE_SET_TOO_LONG)    // 256
        #expect(result(253, 1) == CRDPQ_EXECUTE_SET_OK)           // 255
        #expect(result(254, 1) == CRDPQ_EXECUTE_SET_TOO_LONG)     // 256
        #expect(result(255, 1) == CRDPQ_EXECUTE_SET_TOO_LONG)
        #expect(result(1, 253) == CRDPQ_EXECUTE_SET_OK)           // 255
        #expect(result(1, 254) == CRDPQ_EXECUTE_SET_TOO_LONG)     // 256
        #expect(result(1, 100_000) == CRDPQ_EXECUTE_SET_TOO_LONG)
        // A full-length pair still ends in a NUL inside the buffer.
        var full = Payload()
        #expect(pack(&full, [UInt8](repeating: 0x61, count: 200), [UInt8](repeating: 0x62, count: 54)) == CRDPQ_EXECUTE_SET_OK)
        #expect(full.program.length == 255)
        #expect(buffer(full)[255] == 0)

        // Refusals leave the payload exactly as it was.
        var sentinel = Payload()
        _ = pack(&sentinel, bytes("previous.exe"), bytes("x"))
        let before = buffer(sentinel)
        let beforeLength = sentinel.program.length
        #expect(pack(&sentinel, [UInt8](repeating: 0x61, count: 254), [0x62]) == CRDPQ_EXECUTE_SET_TOO_LONG)
        #expect(pack(&sentinel, bytes("a\u{0}b"), nil) == CRDPQ_EXECUTE_SET_EMBEDDED_NUL)
        #expect(pack(&sentinel, [], nil) == CRDPQ_EXECUTE_SET_EMPTY_PROGRAM)
        #expect(buffer(sentinel) == before)
        #expect(sentinel.program.length == beforeLength)
    }

    @Test("an empty or NULL program, or a NUL inside either part, is refused")
    func refusals() {
        var payload = Payload()
        #expect(pack(&payload, nil, nil) == CRDPQ_EXECUTE_SET_EMPTY_PROGRAM)
        #expect(pack(&payload, [], bytes("x")) == CRDPQ_EXECUTE_SET_EMPTY_PROGRAM)
        #expect(pack(&payload, bytes("note\u{0}pad.exe"), nil) == CRDPQ_EXECUTE_SET_EMBEDDED_NUL)
        #expect(pack(&payload, bytes("notepad.exe"), bytes("a\u{0}b")) == CRDPQ_EXECUTE_SET_EMBEDDED_NUL)
        #expect(pack(&payload, [0], nil) == CRDPQ_EXECUTE_SET_EMBEDDED_NUL)
        // NULL arguments with a nonzero count are no arguments, not a read through NULL.
        var program = bytes("notepad.exe")
        let r = program.withUnsafeMutableBytes { raw in
            crdpq_execute_set(&payload, raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count, nil, 99)
        }
        #expect(r == CRDPQ_EXECUTE_SET_OK)
        #expect(crdpq_execute_arguments_offset(&payload) == 0)
        #expect(payload.program.length == 11)
    }

    @Test("the split reads 'no arguments' from anything that is not a well-formed pair")
    func splitRobustness() {
        // A separator with nothing after it.
        var trailing = Payload()
        "abc".withCString { crdpq_text_set(&trailing.program, $0, 3) }
        trailing.program.length = 4
        #expect(crdpq_execute_arguments_offset(&trailing) == 0)
        // A length the buffer cannot hold.
        var oversized = Payload()
        _ = pack(&oversized, bytes("a"), bytes("b"))
        oversized.program.length = 256
        #expect(crdpq_execute_arguments_offset(&oversized) == 0)
        oversized.program.length = UInt16.max
        #expect(crdpq_execute_arguments_offset(&oversized) == 0)
        // The empty payload.
        var empty = Payload()
        #expect(crdpq_execute_arguments_offset(&empty) == 0)
    }

    /// The panel's check (`RunCommandParser.validate`) and the bridge's (`crdpq_execute_set`) must
    /// agree on every input, or the panel would promise a send the bridge then refuses.
    @Test("the parser's limit and the C packer's agree on every boundary input")
    func parserAndPackerAgree() {
        let lengths = [1, 2, 100, 200, 253, 254, 255, 256, 300]
        var inputs: [(String, String)] = []
        for p in lengths {
            inputs.append((String(repeating: "a", count: p), ""))
            for a in [1, 2, 54, 55, 100] {
                inputs.append((String(repeating: "a", count: p), String(repeating: "b", count: a)))
            }
        }
        inputs += [("", ""), ("", "x"), ("a\u{0}", ""), ("a", "\u{0}"), (String(repeating: "工", count: 85), ""),
                   (String(repeating: "工", count: 84), "ab"), (String(repeating: "工", count: 84), "abc")]
        for (program, arguments) in inputs {
            var payload = Payload()
            let c = pack(&payload, bytes(program), arguments.isEmpty ? nil : bytes(arguments))
            let expected: crdpq_execute_set_result_t
            switch RunCommandParser.validate(program: program, arguments: arguments) {
            case .success: expected = CRDPQ_EXECUTE_SET_OK
            case .failure(.empty): expected = CRDPQ_EXECUTE_SET_EMPTY_PROGRAM
            case .failure(.embeddedNul): expected = CRDPQ_EXECUTE_SET_EMBEDDED_NUL
            case .failure(.tooLongPath), .failure(.tooLongWithArguments): expected = CRDPQ_EXECUTE_SET_TOO_LONG
            }
            #expect(c == expected, "\(program.utf8.count) + \(arguments.utf8.count)")
            if c == CRDPQ_EXECUTE_SET_OK {
                let command = RunCommand(program: program, arguments: arguments)
                #expect(Int(payload.program.length) == command.payloadByteCount)
            }
        }
    }
}

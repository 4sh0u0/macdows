import Foundation

/// ADR-0024 D-1 (C-a): a host record's stable identity. The keychain account of both of the
/// host's items (credential and pin) is this UUID, never the host name or address, so renaming a
/// host or changing its address never orphans an item.
struct HostID: Hashable, Codable, Sendable, CustomStringConvertible {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    init?(keychainAccount: String) {
        guard let uuid = UUID(uuidString: keychainAccount) else { return nil }
        self.uuid = uuid
    }

    /// The `kSecAttrAccount` value of this host's items.
    var keychainAccount: String { uuid.uuidString }

    var description: String { uuid.uuidString }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }

    init(from decoder: Decoder) throws {
        uuid = try decoder.singleValueContainer().decode(UUID.self)
    }
}

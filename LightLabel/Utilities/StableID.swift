import Foundation

public enum StableID {
    /// Produces an RFC 4122-shaped UUID from stable input without relying on randomized hashing.
    public static func make(namespace: String, components: some Sequence<String>) -> UUID {
        let input = ([namespace] + Array(components)).joined(separator: "\u{1f}")
        let bytes = Array(input.utf8)
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4

        for byte in bytes {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x100000001b3
            second ^= first.rotateLeft(by: 27)
        }

        var uuidBytes = withUnsafeBytes(of: first.bigEndian, Array.init)
        uuidBytes.append(contentsOf: withUnsafeBytes(of: second.bigEndian, Array.init))
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80

        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }
}

private extension UInt64 {
    func rotateLeft(by count: UInt64) -> UInt64 {
        (self << count) | (self >> (64 - count))
    }
}

import Foundation

/// LZFSE compression helpers (Apple's native, dependency-free codec). Used to
/// shrink the sync payload and to size-gate individual extensions/plugins before
/// they're eligible for sync.
extension Data {
    func prosperCompressed() -> Data? {
        try? (self as NSData).compressed(using: .lzfse) as Data
    }

    func prosperDecompressed() -> Data? {
        try? (self as NSData).decompressed(using: .lzfse) as Data
    }
}

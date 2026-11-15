import CryptoKit
import Foundation
import XCTest
@testable import ProsperApp

/// #1287: SyncCrypto never seals under a key anyone could compute. Keys come from the
/// SyncCrypto seams (never the real Keychain, iCloud key store or the operator's device key);
/// key files live in a tempDir(). No key or payload goes into a message.
final class SyncCryptoKeyTests: XCTestCase {

    private var savedIcloud: SyncCrypto.KeyLookup!
    private var savedDevice: SyncCrypto.KeyLookup!

    override func setUp() {
        super.setUp()
        savedIcloud = SyncCrypto.icloudKey
        savedDevice = SyncCrypto.deviceKey
    }

    override func tearDown() {
        SyncCrypto.icloudKey = savedIcloud
        SyncCrypto.deviceKey = savedDevice
        super.tearDown()
    }

    private let payload = Data("example payload".utf8)

    /// SHA-256 of an empty secret: the key the old fallback sealed under.
    private var emptySecretKey: SymmetricKey { SymmetricKey(data: SHA256.hash(data: Data())) }

    private func noKeys() {
        SyncCrypto.icloudKey = { _ in nil }
        SyncCrypto.deviceKey = { _ in nil }
    }

    func testEncryptIsNilWithNoIcloudKeyAndAThrowingDeviceSource() {
        noKeys()
        XCTAssertTrue(SyncCrypto.encrypt(payload) == nil)
    }

    func testModeIsUnavailableWhenNeitherKeyExists() {
        noKeys()
        XCTAssertEqual(SyncCrypto.mode, .unavailable)
    }

    func testFixedDeviceKeyRoundTripsAndModeIsDeviceFallback() {
        let key = SymmetricKey(size: .bits256)
        SyncCrypto.icloudKey = { _ in nil }
        SyncCrypto.deviceKey = { _ in key }
        XCTAssertEqual(SyncCrypto.mode, .deviceFallback)
        let blob = SyncCrypto.encrypt(payload)
        XCTAssertTrue(blob != nil)
        XCTAssertEqual(blob.flatMap(SyncCrypto.decrypt), payload)
    }

    func testIcloudKeyRoundTripsAndWinsOverTheDeviceKey() {
        let key = SymmetricKey(size: .bits256)
        SyncCrypto.icloudKey = { _ in key }
        SyncCrypto.deviceKey = { _ in nil }
        XCTAssertEqual(SyncCrypto.mode, .icloud)
        XCTAssertEqual(SyncCrypto.encrypt(payload).flatMap(SyncCrypto.decrypt), payload)
    }

    func testNothingIsEverSealedUnderTheEmptySecretKey() throws {
        // Every key source down: no blob at all. With a real key: the blob must not open
        // under SHA-256 of an empty secret.
        noKeys()
        XCTAssertTrue(SyncCrypto.encrypt(payload) == nil)
        SyncCrypto.deviceKey = { _ in SymmetricKey(size: .bits256) }
        let blob = try XCTUnwrap(SyncCrypto.encrypt(payload))
        let box = try AES.GCM.SealedBox(combined: blob.dropFirst(2))
        XCTAssertThrowsError(try AES.GCM.open(box, using: emptySecretKey))
    }

    func testDecryptOfADeviceBlobWithNoKeyIsNil() throws {
        SyncCrypto.icloudKey = { _ in nil }
        SyncCrypto.deviceKey = { _ in SymmetricKey(size: .bits256) }
        let blob = try XCTUnwrap(SyncCrypto.encrypt(payload))
        noKeys()
        XCTAssertTrue(SyncCrypto.decrypt(blob) == nil)
    }

    func testDecryptOfABlobSealedUnderTheEmptySecretKeyIsNil() throws {
        // What the old fallback wrote: envelope [1][device] + a box under the empty-secret key.
        let sealed = try AES.GCM.seal(payload, using: emptySecretKey)
        var blob = Data([1, 1])
        blob.append(try XCTUnwrap(sealed.combined))
        noKeys()
        XCTAssertTrue(SyncCrypto.decrypt(blob) == nil)
        SyncCrypto.deviceKey = { _ in SymmetricKey(size: .bits256) }
        XCTAssertTrue(SyncCrypto.decrypt(blob) == nil)
    }

    func testAMalformedDeviceKeyFileReadsAsNoKeyAndIsLeftAlone() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "device.key")
        let junk = Data("not a key file".utf8)
        try junk.write(to: file)
        SyncCrypto.icloudKey = { _ in nil }
        SyncCrypto.deviceKey = { _ in try? ClipboardCrypto.fileKey(file) }
        XCTAssertTrue(SyncCrypto.encrypt(payload) == nil)
        XCTAssertEqual(SyncCrypto.mode, .unavailable)
        XCTAssertEqual(try Data(contentsOf: file), junk)
    }

    func testAGoodDeviceKeyFileRoundTrips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "device.key")
        SyncCrypto.icloudKey = { _ in nil }
        SyncCrypto.deviceKey = { _ in try? ClipboardCrypto.fileKey(file) }
        XCTAssertEqual(SyncCrypto.encrypt(payload).flatMap(SyncCrypto.decrypt), payload)
    }
}

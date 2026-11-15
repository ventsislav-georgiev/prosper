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
    private var savedAbsent: (@Sendable () -> Bool)!
    private var savedStoreURL: URL!

    override func setUp() {
        super.setUp()
        savedIcloud = SyncCrypto.icloudKey
        savedDevice = SyncCrypto.deviceKey
        savedAbsent = SyncCrypto.deviceKeyAbsent
        savedStoreURL = SupporterStore.fileURL
    }

    override func tearDown() {
        SyncCrypto.icloudKey = savedIcloud
        SyncCrypto.deviceKey = savedDevice
        SyncCrypto.deviceKeyAbsent = savedAbsent
        SupporterStore.fileURL = savedStoreURL
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

    // MARK: - #1293

    /// Points both device-key seams at a file in a tempDir (the production bodies, not the operator's file).
    private func deviceFile(_ name: String = "device.key") -> URL {
        let file = tempDir().appending(path: name)
        SyncCrypto.icloudKey = { _ in nil }
        SyncCrypto.deviceKey = { create in SyncCrypto.deviceKey(at: file, create: create) }
        SyncCrypto.deviceKeyAbsent = { SyncCrypto.deviceKeyAbsent(at: file) }
        return file
    }

    @MainActor
    func testPaneLabelsEveryKeyModeAndUnavailableIsNotLocal() {
        XCTAssertEqual(SyncPane.keyLabel(.icloud), "iCLOUD")
        XCTAssertEqual(SyncPane.keyLabel(.deviceFallback), "LOCAL")
        XCTAssertEqual(SyncPane.keyLabel(.unavailable), "NO KEY")
        XCTAssertEqual(SyncPane.keyDetail(.unavailable), "Sync is paused: Prosper cannot read this Mac's device key")
        XCTAssertFalse(SyncPane.footer(.unavailable).contains("local key"))
        XCTAssertTrue(SyncPane.keyDetail(.deviceFallback).hasPrefix("Local device key"))
    }

    func testModeWithNoDeviceKeyFileIsDeviceFallbackAndCreatesNoFile() {
        let file = deviceFile()
        XCTAssertEqual(SyncCrypto.mode, .deviceFallback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // The first seal creates it.
        XCTAssertTrue(SyncCrypto.encrypt(payload) != nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(SyncCrypto.mode, .deviceFallback)
    }

    func testModeWithAMalformedDeviceKeyFileIsUnavailableAndTheFileIsUntouched() throws {
        let file = deviceFile()
        let junk = Data("not a key file".utf8)
        try junk.write(to: file)
        XCTAssertEqual(SyncCrypto.mode, .unavailable)
        XCTAssertEqual(try Data(contentsOf: file), junk)
    }

    func testDeviceKeyOpenPathWithNoFileCreatesNothing() {
        let file = tempDir().appending(path: "device.key")
        XCTAssertTrue(SyncCrypto.deviceKey(at: file, create: false) == nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(SyncCrypto.deviceKey(at: file, create: true) != nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeviceKeyOfAMalformedFileIsNilAndByteIdentical() throws {
        let file = tempDir().appending(path: "device.key")
        let junk = Data("not a key file".utf8)
        try junk.write(to: file)
        XCTAssertTrue(SyncCrypto.deviceKey(at: file, create: false) == nil)
        XCTAssertTrue(SyncCrypto.deviceKey(at: file, create: true) == nil)
        XCTAssertEqual(try Data(contentsOf: file), junk)
    }

    @MainActor
    func testFinishLoginOutcomeSaysWhenTheSaveWasSkipped() {
        XCTAssertEqual(SupporterClient.loginOutcome(saved: true), .success)
        XCTAssertEqual(SupporterClient.loginOutcome(saved: false),
                       .failed("Signed in for this session; the sign-in can't be saved on this Mac."))
    }

    @MainActor
    func testSupporterStoreSaveReportsASkippedSaveAndWritesNothing() {
        noKeys()
        let file = tempDir().appending(path: "supporter.dat")
        SupporterStore.fileURL = file
        XCTAssertEqual(SupporterStore.save(StoredCredentials(email: "a@example.com", session: "s", token: "t")), false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// #1297: compares path strings only; never calls load, save or clear and touches no file.
    func testSupporterStoreDefaultFileIsNotUnderTheRealHomeConfig() {
        let real = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config").path
        let path = SupporterStore.defaultFileURL.path
        XCTAssertFalse(path.hasPrefix(real), "the default must not be under the real ~/.config")
        XCTAssertTrue(path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @MainActor
    func testSupporterStoreSavesLoadsAndClearsOnlyThroughTheSeam() {
        let file = tempDir().appending(path: "sub/supporter.dat")
        SupporterStore.fileURL = file
        let creds = StoredCredentials(email: "a@example.com", session: "s", token: "t")
        XCTAssertTrue(SupporterStore.save(creds))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(SupporterStore.load()?.session, "s")
        SupporterStore.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(SupporterStore.load() == nil)
    }
}

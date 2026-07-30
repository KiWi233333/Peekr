import CommonCrypto
import CryptoKit
import CCef
import Foundation
import SQLite3
import XCTest
@testable import Peekr

final class ChromeCookieImporterTests: XCTestCase {
    @MainActor
    func testCookiePriorityMatchesChromiumDatabaseValues() {
        XCTAssertEqual(CEFCookieWriter.cefPriority(0), CEF_COOKIE_PRIORITY_LOW)
        XCTAssertEqual(CEFCookieWriter.cefPriority(1), CEF_COOKIE_PRIORITY_MEDIUM)
        XCTAssertEqual(CEFCookieWriter.cefPriority(2), CEF_COOKIE_PRIORITY_HIGH)
        XCTAssertEqual(CEFCookieWriter.cefPriority(-1), CEF_COOKIE_PRIORITY_MEDIUM)
    }

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    func testProfileDiscoveryUsesChromeNamesAndPutsLastUsedFirst() throws {
        let root = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Default"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Profile 1"),
            withIntermediateDirectories: true
        )
        let localState: [String: Any] = [
            "profile": [
                "last_used": "Profile 1",
                "info_cache": [
                    "Default": ["name": "Personal"],
                    "Profile 1": ["name": "Work"],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: localState)
        try data.write(to: root.appendingPathComponent("Local State"))

        let profiles = ChromeCookieImporter.discoverProfiles(in: root)

        XCTAssertEqual(profiles.map(\.id), ["Profile 1", "Default"])
        XCTAssertEqual(profiles.map(\.name), ["Work", "Personal"])
    }

    func testDecryptsVersion24CookieAndValidatesHostDigest() throws {
        let password = Data("test-password".utf8)
        let host = ".example.com"
        let value = "session-token"
        let plaintext = Data(SHA256.hash(data: Data(host.utf8))) + Data(value.utf8)
        let encrypted = Data("v10".utf8) + (try encrypt(plaintext, password: password))

        XCTAssertEqual(
            ChromeCookieImporter.decrypt(
                encrypted,
                host: host,
                databaseVersion: 24,
                password: password
            ),
            value
        )
        XCTAssertNil(
            ChromeCookieImporter.decrypt(
                encrypted,
                host: ".wrong.example",
                databaseVersion: 24,
                password: password
            )
        )
    }

    func testCookieDatabaseFiltersUnsupportedRowsWithoutExposingValues() throws {
        let root = try makeTemporaryDirectory()
        let profileDirectory = root.appendingPathComponent("Default")
        let networkDirectory = profileDirectory.appendingPathComponent("Network")
        try FileManager.default.createDirectory(at: networkDirectory, withIntermediateDirectories: true)
        let databaseURL = networkDirectory.appendingPathComponent("Cookies")
        try createCookieDatabase(at: databaseURL)

        let profile = ChromeProfile(
            id: "Default",
            name: "Personal",
            directoryURL: profileDirectory
        )
        let result = try ChromeCookieImporter.readCookies(
            from: profile,
            keychainPassword: Data("unused".utf8),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(result.totalRows, 4)
        XCTAssertEqual(result.cookies.count, 1)
        XCTAssertEqual(result.cookies.first?.host, ".example.com")
        XCTAssertEqual(result.cookies.first?.value, "plain-value")
        XCTAssertEqual(result.expired, 1)
        XCTAssertEqual(result.partitioned, 1)
        XCTAssertEqual(result.undecryptable, 1)
    }

    func testSnapshotIsReadableOnlyByCurrentUser() throws {
        let root = try makeTemporaryDirectory()
        let sourceURL = root.appendingPathComponent("Cookies")
        try createCookieDatabase(at: sourceURL)

        let snapshotURL = try ChromeCookieImporter.snapshotDatabase(at: sourceURL)
        temporaryDirectories.append(snapshotURL.deletingLastPathComponent())
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: snapshotURL.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        let directoryPermissions =
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
        let filePermissions = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue

        XCTAssertEqual(directoryPermissions.map { $0 & 0o777 }, 0o700)
        XCTAssertEqual(filePermissions.map { $0 & 0o777 }, 0o600)
    }

    @MainActor
    func testCEFCookieSourceURLPreservesSecurityAndPath() {
        let cookie = ChromeCookie(
            host: ".example.com",
            name: "session",
            value: "value",
            path: "/account",
            expiresUTC: 0,
            isSecure: true,
            isHTTPOnly: true,
            creationUTC: 0,
            lastAccessUTC: 0,
            sameSite: 1,
            priority: 1
        )

        XCTAssertEqual(
            CEFCookieWriter.sourceURL(for: cookie)?.absoluteString,
            "https://example.com/account"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekrCookieTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func createCookieDatabase(at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else {
            XCTFail("Could not create test database")
            return
        }
        defer { sqlite3_close(database) }

        let now = ChromeCookieImporter.chromeTime(
            from: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let sql = """
        CREATE TABLE meta (key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        INSERT INTO meta VALUES ('version', '24');
        CREATE TABLE cookies (
            creation_utc INTEGER NOT NULL,
            host_key TEXT NOT NULL,
            top_frame_site_key TEXT NOT NULL,
            name TEXT NOT NULL,
            value TEXT NOT NULL,
            encrypted_value BLOB NOT NULL,
            path TEXT NOT NULL,
            expires_utc INTEGER NOT NULL,
            is_secure INTEGER NOT NULL,
            is_httponly INTEGER NOT NULL,
            last_access_utc INTEGER NOT NULL,
            samesite INTEGER NOT NULL,
            priority INTEGER NOT NULL
        );
        INSERT INTO cookies VALUES
            (1, '.example.com', '', 'valid', 'plain-value', X'', '/', 0, 1, 1, 2, 1, 1);
        INSERT INTO cookies VALUES
            (1, '.expired.example', '', 'expired', 'old', X'', '/', \(now - 1), 0, 0, 2, -1, 0);
        INSERT INTO cookies VALUES
            (1, '.partitioned.example', 'https://top.example', 'partitioned', 'value', X'', '/', 0, 1, 1, 2, 0, 0);
        INSERT INTO cookies VALUES
            (1, '.encrypted.example', '', 'unknown', '', X'01020304', '/', 0, 1, 1, 2, 0, 0);
        """
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        let message = error.map { String(cString: $0) }
        sqlite3_free(error)
        XCTAssertEqual(result, SQLITE_OK, message ?? "SQLite setup failed")
    }

    private func encrypt(_ plaintext: Data, password: Data) throws -> Data {
        let salt = Data("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derivationStatus = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    passwordBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1_003,
                    &key,
                    key.count
                )
            }
        }
        XCTAssertEqual(Int(derivationStatus), kCCSuccess)

        let initializationVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let encryptionStatus = key.withUnsafeBytes { keyBytes in
            initializationVector.withUnsafeBytes { ivBytes in
                plaintext.withUnsafeBytes { plaintextBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintextBytes.count,
                            outputBytes.baseAddress,
                            outputBytes.count,
                            &outputLength
                        )
                    }
                }
            }
        }
        XCTAssertEqual(Int(encryptionStatus), kCCSuccess)
        output.removeSubrange(outputLength..<output.count)
        return output
    }
}

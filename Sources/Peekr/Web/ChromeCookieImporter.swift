import CCef
import CefKit
import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security
import SQLite3

/// A Chrome profile that can be selected as a cookie-import source.
struct ChromeProfile: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let directoryURL: URL

    var cookieDatabaseURL: URL? {
        let fileManager = FileManager.default
        let candidates = [
            directoryURL.appendingPathComponent("Network/Cookies"),
            directoryURL.appendingPathComponent("Cookies"),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}

/// A decrypted Chrome cookie ready to be copied into CEF.
struct ChromeCookie: Equatable, Sendable {
    let host: String
    let name: String
    let value: String
    let path: String
    let expiresUTC: Int64
    let isSecure: Bool
    let isHTTPOnly: Bool
    let creationUTC: Int64
    let lastAccessUTC: Int64
    let sameSite: Int32
    let priority: Int32
}

struct ChromeCookieReadResult: Sendable {
    let cookies: [ChromeCookie]
    let totalRows: Int
    let expired: Int
    let partitioned: Int
    let undecryptable: Int
}

struct ChromeCookieImportResult: Sendable {
    let totalRows: Int
    let imported: Int
    let rejected: Int
    let expired: Int
    let partitioned: Int
    let undecryptable: Int

    var skipped: Int {
        expired + partitioned + undecryptable + rejected
    }
}

enum ChromeCookieImportError: LocalizedError {
    case databaseMissing
    case database(String)
    case keychain(OSStatus)
    case cefUnavailable
    case cefFrameworkMissing
    case cefSymbolMissing(String)

    var errorDescription: String? {
        switch self {
        case .databaseMissing:
            return "The selected Chrome profile has no cookie database."
        case .database(let message):
            return "Chrome's cookie database could not be read: \(message)"
        case .keychain(let status):
            if status == errSecUserCanceled || status == errSecAuthFailed {
                return "Chrome Safe Storage access was not allowed."
            }
            return "Chrome Safe Storage could not be read (OSStatus \(status))."
        case .cefUnavailable:
            return "Peekr's Chromium runtime is not ready."
        case .cefFrameworkMissing:
            return "Peekr's bundled Chromium framework could not be found."
        case .cefSymbolMissing(let name):
            return "The bundled Chromium framework does not provide \(name)."
        }
    }
}

/// Reads Chrome profiles and decrypts their cookies locally.
///
/// Decrypted cookie values only exist in memory for the duration of an explicit
/// import. The access-restricted database snapshot is deleted afterward, and
/// values are never written to Peekr logs or plaintext export files.
enum ChromeCookieImporter {
    static let chromeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)

    static func discoverProfiles(in root: URL = chromeRoot) -> [ChromeProfile] {
        let fileManager = FileManager.default
        let localStateURL = root.appendingPathComponent("Local State")
        var names: [String: String] = [:]
        var lastUsed: String?

        if let data = try? Data(contentsOf: localStateURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = object["profile"] as? [String: Any] {
            lastUsed = profile["last_used"] as? String
            if let infoCache = profile["info_cache"] as? [String: Any] {
                for (directory, rawInfo) in infoCache {
                    guard let info = rawInfo as? [String: Any] else { continue }
                    names[directory] =
                        info["name"] as? String
                        ?? info["shortcut_name"] as? String
                        ?? directory
                }
            }
        }

        if names.isEmpty,
           let children = try? fileManager.contentsOfDirectory(
               at: root,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for child in children {
                let directory = child.lastPathComponent
                if directory == "Default" || directory.hasPrefix("Profile ") {
                    names[directory] = directory
                }
            }
        }

        return names.map { directory, displayName in
            ChromeProfile(
                id: directory,
                name: displayName,
                directoryURL: root.appendingPathComponent(directory, isDirectory: true)
            )
        }
        .sorted { lhs, rhs in
            if lhs.id == lastUsed { return true }
            if rhs.id == lastUsed { return false }
            if lhs.id == "Default" { return true }
            if rhs.id == "Default" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func readCookies(
        from profile: ChromeProfile,
        keychainPassword: Data? = nil,
        now: Date = Date()
    ) throws -> ChromeCookieReadResult {
        guard let databaseURL = profile.cookieDatabaseURL else {
            throw ChromeCookieImportError.databaseMissing
        }

        let snapshot = try snapshotDatabase(at: databaseURL)
        defer {
            try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent())
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            snapshot.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let database { sqlite3_close(database) }
            throw ChromeCookieImportError.database(message)
        }
        defer { sqlite3_close(database) }

        let columns = try cookieColumns(in: database)
        guard columns.contains("host_key"), columns.contains("name") else {
            throw ChromeCookieImportError.database("unsupported cookies table")
        }
        let databaseVersion = readDatabaseVersion(from: database)
        let select = cookieSelect(columns: columns)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, select, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ChromeCookieImportError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [ChromeCookie] = []
        var totalRows = 0
        var expired = 0
        var partitioned = 0
        var undecryptable = 0
        var password = keychainPassword
        let nowUTC = chromeTime(from: now)

        while sqlite3_step(statement) == SQLITE_ROW {
            totalRows += 1
            let host = text(statement, 0)
            let name = text(statement, 1)
            let plaintextValue = text(statement, 2)
            let encryptedValue = blob(statement, 3)
            let path = text(statement, 4)
            let expiresUTC = sqlite3_column_int64(statement, 5)
            let secure = sqlite3_column_int(statement, 6) != 0
            let httpOnly = sqlite3_column_int(statement, 7) != 0
            let creationUTC = sqlite3_column_int64(statement, 8)
            let lastAccessUTC = sqlite3_column_int64(statement, 9)
            let sameSite = sqlite3_column_int(statement, 10)
            let priority = sqlite3_column_int(statement, 11)
            let partitionKey = text(statement, 12)

            if !partitionKey.isEmpty {
                partitioned += 1
                continue
            }
            if expiresUTC != 0, expiresUTC <= nowUTC {
                expired += 1
                continue
            }

            let value: String?
            if !plaintextValue.isEmpty {
                value = plaintextValue
            } else if !encryptedValue.isEmpty {
                if password == nil {
                    password = try chromeSafeStoragePassword()
                }
                value = password.flatMap {
                    decrypt(
                        encryptedValue,
                        host: host,
                        databaseVersion: databaseVersion,
                        password: $0
                    )
                }
            } else {
                value = ""
            }

            guard let value, !host.isEmpty else {
                undecryptable += 1
                continue
            }
            cookies.append(
                ChromeCookie(
                    host: host,
                    name: name,
                    value: value,
                    path: path.isEmpty ? "/" : path,
                    expiresUTC: expiresUTC,
                    isSecure: secure,
                    isHTTPOnly: httpOnly,
                    creationUTC: creationUTC,
                    lastAccessUTC: lastAccessUTC,
                    sameSite: sameSite,
                    priority: priority
                )
            )
        }

        if sqlite3_errcode(database) != SQLITE_OK,
           sqlite3_errcode(database) != SQLITE_DONE {
            throw ChromeCookieImportError.database(String(cString: sqlite3_errmsg(database)))
        }

        return ChromeCookieReadResult(
            cookies: cookies,
            totalRows: totalRows,
            expired: expired,
            partitioned: partitioned,
            undecryptable: undecryptable
        )
    }

    /// Chrome stores timestamps as microseconds since 1601-01-01 UTC.
    static func chromeTime(from date: Date) -> Int64 {
        let secondsBetween1601And1970 = 11_644_473_600.0
        return Int64((date.timeIntervalSince1970 + secondsBetween1601And1970) * 1_000_000)
    }

    /// Decrypts macOS Chrome's `v10`/`v11` AES-CBC cookie payload.
    static func decrypt(
        _ encryptedValue: Data,
        host: String,
        databaseVersion: Int,
        password: Data
    ) -> String? {
        guard encryptedValue.count > 3 else { return nil }
        let prefix = encryptedValue.prefix(3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else {
            return nil
        }

        guard let key = deriveKey(password: password),
              let decrypted = aesCBCDecrypt(Data(encryptedValue.dropFirst(3)), key: key) else {
            return nil
        }

        let valueData: Data
        if databaseVersion >= 24 {
            let hostDigest = Data(SHA256.hash(data: Data(host.utf8)))
            guard decrypted.count >= hostDigest.count,
                  decrypted.prefix(hostDigest.count) == hostDigest else {
                return nil
            }
            valueData = Data(decrypted.dropFirst(hostDigest.count))
        } else {
            valueData = decrypted
        }
        return String(data: valueData, encoding: .utf8)
    }

    static func snapshotDatabase(at sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Peekr-Chrome-Cookies-\(UUID().uuidString)", isDirectory: true)
        var keepSnapshot = false
        defer {
            if !keepSnapshot {
                try? fileManager.removeItem(at: directory)
            }
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destinationURL = directory.appendingPathComponent("Cookies")

        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let source else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let source { sqlite3_close(source) }
            try? FileManager.default.removeItem(at: directory)
            throw ChromeCookieImportError.database(message)
        }
        defer { sqlite3_close(source) }

        guard sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "snapshot failed"
            if let destination { sqlite3_close(destination) }
            try? FileManager.default.removeItem(at: directory)
            throw ChromeCookieImportError.database(message)
        }
        defer { sqlite3_close(destination) }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )

        sqlite3_busy_timeout(source, 2_000)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            try? FileManager.default.removeItem(at: directory)
            throw ChromeCookieImportError.database(String(cString: sqlite3_errmsg(destination)))
        }

        var result = sqlite3_backup_step(backup, -1)
        var retries = 0
        while (result == SQLITE_BUSY || result == SQLITE_LOCKED), retries < 40 {
            sqlite3_sleep(50)
            retries += 1
            result = sqlite3_backup_step(backup, -1)
        }
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(destination))
            try? FileManager.default.removeItem(at: directory)
            throw ChromeCookieImportError.database(message)
        }
        keepSnapshot = true
        return destinationURL
    }

    private static func cookieColumns(in database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(cookies)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ChromeCookieImportError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(text(statement, 1))
        }
        return columns
    }

    private static func cookieSelect(columns: Set<String>) -> String {
        func column(_ name: String, fallback: String) -> String {
            columns.contains(name) ? "\"\(name)\"" : fallback
        }
        return """
        SELECT
            \(column("host_key", fallback: "''")),
            \(column("name", fallback: "''")),
            \(column("value", fallback: "''")),
            \(column("encrypted_value", fallback: "X''")),
            \(column("path", fallback: "'/'")),
            \(column("expires_utc", fallback: "0")),
            \(column("is_secure", fallback: "0")),
            \(column("is_httponly", fallback: "0")),
            \(column("creation_utc", fallback: "0")),
            \(column("last_access_utc", fallback: "0")),
            \(column("samesite", fallback: "-1")),
            \(column("priority", fallback: "0")),
            \(column("top_frame_site_key", fallback: "''"))
        FROM cookies
        """
    }

    private static func readDatabaseVersion(from database: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM meta WHERE key = 'version' LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(text(statement, 0)) ?? 0
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let value = sqlite3_column_blob(statement, column) else {
            return Data()
        }
        return Data(bytes: value, count: count)
    }

    private static func chromeSafeStoragePassword() throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Chrome Safe Storage",
            kSecAttrAccount: "Chrome",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            throw ChromeCookieImportError.keychain(status)
        }
        return password
    }

    private static func deriveKey(password: Data) -> Data? {
        let salt = Data("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = password.withUnsafeBytes { passwordBytes in
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
        return status == kCCSuccess ? Data(key) : nil
    }

    private static func aesCBCDecrypt(_ encrypted: Data, key: Data) -> Data? {
        let initializationVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: encrypted.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = key.withUnsafeBytes { keyBytes in
            initializationVector.withUnsafeBytes { ivBytes in
                encrypted.withUnsafeBytes { encryptedBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            encryptedBytes.baseAddress,
                            encryptedBytes.count,
                            outputBytes.baseAddress,
                            outputBytes.count,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(outputLength..<output.count)
        return output
    }
}

/// Copies decrypted cookies into the global persistent profile used by Peekr's
/// bundled Chromium runtime. CefSwift 0.1.0 does not wrap CookieManager yet, so
/// this resolves the stable CEF C API symbol from the already-loaded framework
/// without modifying the dependency checkout.
@MainActor
enum CEFCookieWriter {
    private typealias GetGlobalCookieManager = @convention(c) (
        UnsafeMutablePointer<cef_completion_callback_t>?
    ) -> UnsafeMutablePointer<cef_cookie_manager_t>?

    static func write(_ source: ChromeCookieReadResult) throws -> ChromeCookieImportResult {
        guard CefRuntime.shared.isInitialized else {
            throw ChromeCookieImportError.cefUnavailable
        }
        guard let frameworkURL = frameworkBinaryURL() else {
            throw ChromeCookieImportError.cefFrameworkMissing
        }
        guard let handle = dlopen(frameworkURL.path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST) else {
            throw ChromeCookieImportError.cefFrameworkMissing
        }
        defer { dlclose(handle) }

        let symbolName = "cef_cookie_manager_get_global_manager"
        guard let symbol = dlsym(handle, symbolName) else {
            throw ChromeCookieImportError.cefSymbolMissing(symbolName)
        }
        let getManager = unsafeBitCast(symbol, to: GetGlobalCookieManager.self)
        guard let manager = getManager(nil) else {
            throw ChromeCookieImportError.cefUnavailable
        }
        defer {
            let base = UnsafeMutableRawPointer(manager)
                .assumingMemoryBound(to: cef_base_ref_counted_t.self)
            _ = base.pointee.release?(base)
        }

        var imported = 0
        var rejected = 0
        for cookie in source.cookies {
            guard let url = sourceURL(for: cookie) else {
                rejected += 1
                continue
            }
            var raw = cef_cookie_t()
            raw.size = MemoryLayout<cef_cookie_t>.stride
            set(cookie.name, into: &raw.name)
            set(cookie.value, into: &raw.value)
            // CEF creates a host-only cookie when domain is empty. Chrome
            // distinguishes domain cookies with a leading dot in host_key.
            set(cookie.host.hasPrefix(".") ? cookie.host : "", into: &raw.domain)
            set(cookie.path, into: &raw.path)
            defer {
                ccef_string_clear(&raw.name)
                ccef_string_clear(&raw.value)
                ccef_string_clear(&raw.domain)
                ccef_string_clear(&raw.path)
            }

            raw.secure = cookie.isSecure ? 1 : 0
            raw.httponly = cookie.isHTTPOnly ? 1 : 0
            raw.creation = cef_basetime_t(val: cookie.creationUTC)
            raw.last_access = cef_basetime_t(val: cookie.lastAccessUTC)
            raw.has_expires = cookie.expiresUTC == 0 ? 0 : 1
            raw.expires = cef_basetime_t(val: cookie.expiresUTC)
            raw.same_site = cefSameSite(cookie.sameSite)
            raw.priority = cefPriority(cookie.priority)

            let accepted = withCefString(url.absoluteString) { cefURL in
                manager.pointee.set_cookie?(manager, cefURL, &raw, nil) ?? 0
            }
            if accepted != 0 {
                imported += 1
            } else {
                rejected += 1
            }
        }
        _ = manager.pointee.flush_store?(manager, nil)

        return ChromeCookieImportResult(
            totalRows: source.totalRows,
            imported: imported,
            rejected: rejected,
            expired: source.expired,
            partitioned: source.partitioned,
            undecryptable: source.undecryptable
        )
    }

    static func sourceURL(for cookie: ChromeCookie) -> URL? {
        let host = cookie.host.hasPrefix(".") ? String(cookie.host.dropFirst()) : cookie.host
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = cookie.isSecure ? "https" : "http"
        components.host = host
        components.path = cookie.path.hasPrefix("/") ? cookie.path : "/\(cookie.path)"
        return components.url
    }

    private static func frameworkBinaryURL() -> URL? {
        let binaryName = "Chromium Embedded Framework"
        let bundleName = "\(binaryName).framework"
        let fileManager = FileManager.default

        var candidates: [URL] = []
        if let override = CefRuntime.shared.configuration?.frameworkDirectory {
            candidates += frameworkCandidates(for: override, bundleName: bundleName, binaryName: binaryName)
        }
        if let frameworks = Bundle.main.privateFrameworksURL {
            candidates.append(
                frameworks.appendingPathComponent(bundleName).appendingPathComponent(binaryName)
            )
        }
        if let environmentPath = ProcessInfo.processInfo.environment["CEF_FRAMEWORK_PATH"],
           !environmentPath.isEmpty {
            candidates += frameworkCandidates(
                for: URL(fileURLWithPath: environmentPath),
                bundleName: bundleName,
                binaryName: binaryName
            )
        }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func frameworkCandidates(
        for url: URL,
        bundleName: String,
        binaryName: String
    ) -> [URL] {
        if url.lastPathComponent == binaryName {
            return [url]
        }
        if url.pathExtension == "framework" {
            return [url.appendingPathComponent(binaryName)]
        }
        return [
            url.appendingPathComponent(bundleName).appendingPathComponent(binaryName),
            url.appendingPathComponent(binaryName),
        ]
    }

    private static func cefSameSite(_ value: Int32) -> cef_cookie_same_site_t {
        switch value {
        case 0: return CEF_COOKIE_SAME_SITE_NO_RESTRICTION
        case 1: return CEF_COOKIE_SAME_SITE_LAX_MODE
        case 2: return CEF_COOKIE_SAME_SITE_STRICT_MODE
        default: return CEF_COOKIE_SAME_SITE_UNSPECIFIED
        }
    }

    static func cefPriority(_ value: Int32) -> cef_cookie_priority_t {
        switch value {
        case 0: return CEF_COOKIE_PRIORITY_LOW
        case 2: return CEF_COOKIE_PRIORITY_HIGH
        default: return CEF_COOKIE_PRIORITY_MEDIUM
        }
    }

    private static func set(_ value: String, into target: inout cef_string_t) {
        guard !value.isEmpty else {
            ccef_string_clear(&target)
            return
        }
        let utf16 = Array(value.utf16)
        _ = utf16.withUnsafeBufferPointer { buffer in
            ccef_string_set_utf16(buffer.baseAddress, buffer.count, &target)
        }
    }

    private static func withCefString<R>(
        _ value: String,
        _ body: (UnsafePointer<cef_string_t>) throws -> R
    ) rethrows -> R {
        var raw = cef_string_t()
        set(value, into: &raw)
        defer { ccef_string_clear(&raw) }
        return try body(&raw)
    }
}

import Foundation

/// #2007 (design #2003 section 4, Storage): a `codex-chatgpt` account's Keychain item, flat JSON
/// `{access_token, refresh_token, id_token, account_id, last_refresh}`. The #2005 two-field item
/// (`{access_token, account_id}`) decodes too and cannot refresh. Nothing logs, describes, counts or puts it in an error
/// string: description, debugDescription and the mirror print no field.
struct CodexCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var accessToken: String
    var accountID: String
    var refreshToken: String?
    var idToken: String?
    /// Epoch seconds of the last refresh. The item holds RFC 3339 text, as Codex's auth.json does.
    var lastRefresh: Double?

    var description: String { "CodexCredential(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }

    /// A login without a refresh token (the #2005 two-field item) is used as it is and never refreshed.
    var canRefresh: Bool { !(refreshToken ?? "").isEmpty }

    /// nil for an item that is not a JSON object or lacks a non-empty access_token or account_id.
    static func decode(_ item: String) -> CodexCredential? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(item.utf8))) as? [String: Any] else { return nil }
        return from(obj, lastRefresh: obj["last_refresh"])
    }

    private static func from(_ obj: [String: Any], lastRefresh: Any?) -> CodexCredential? {
        guard let access = obj["access_token"] as? String, !access.isEmpty,
              let account = obj["account_id"] as? String, !account.isEmpty else { return nil }
        return CodexCredential(accessToken: access, accountID: account, refreshToken: obj["refresh_token"] as? String,
                               idToken: obj["id_token"] as? String, lastRefresh: epoch(lastRefresh))
    }

    /// The flat item text (sorted keys; absent fields are left out).
    func encoded() -> String? {
        var obj: [String: Any] = ["access_token": accessToken, "account_id": accountID]
        if let refreshToken { obj["refresh_token"] = refreshToken }
        if let idToken { obj["id_token"] = idToken }
        if let lastRefresh, lastRefresh.isFinite, (0...1e11).contains(lastRefresh) {
            let f = ISO8601DateFormatter()
            obj["last_refresh"] = f.string(from: Date(timeIntervalSince1970: lastRefresh))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Codex's auth.json (tokens nested under "tokens", last_refresh at the top) as the flat item text P5 stores; nil
    /// when the file lacks the access token or the account id.
    static func flatItem(fromAuthJSON data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any] else { return nil }
        return from(tokens, lastRefresh: obj["last_refresh"])?.encoded()
    }

    /// RFC 3339 text (with or without fractional seconds) or a number of epoch seconds; anything else, or a value
    /// outside 0...1e11, is nil.
    static func epoch(_ v: Any?) -> Double? {
        var d: Double?
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            d = n.doubleValue
        } else if let s = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            // Codex writes microseconds; the formatter may want at most milliseconds, so the fraction is dropped then.
            let cut = s.replacingOccurrences(of: #"\.[0-9]+"#, with: "", options: .regularExpression)
            d = (f.date(from: s) ?? plain.date(from: s) ?? plain.date(from: cut))?.timeIntervalSince1970
        }
        guard let d, d.isFinite, (0...1e11).contains(d) else { return nil }
        return d
    }

    /// The `exp` claim of a JWT, read without verifying the signature; nil when the token is not a JWT or has no sane exp.
    static func jwtExp(_ token: String) -> Double? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return epoch(obj["exp"] as? NSNumber)
    }
}

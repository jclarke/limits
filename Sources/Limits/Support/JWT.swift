import Foundation

/// Minimal JWT claim reading: base64url-decode the payload, no signature
/// check. Used only to pre-screen a local token for expiry so Limits can skip
/// a request that is certain to 401. Real authorization stays server-side.
enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = (payload(token)?["exp"] as? NSNumber)?.doubleValue, exp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }
}

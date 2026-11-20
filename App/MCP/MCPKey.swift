import Foundation
import Security

/// The MCP server's access key, kept in the login keychain. Every request
/// must carry it as `Authorization: Bearer <key>`.
enum MCPKey {
    private static let service = "com.byteclub.titlecut.mcp"
    private static let account = "key"

    /// The stored key, made on first use.
    static var current: String {
        if let stored = read() { return stored }
        return renew()
    }

    /// Replaces the key; clients with the old one are refused from now on.
    @discardableResult
    static func renew() -> String {
        let key = make()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
        return key
    }

    /// Whether `header` (an Authorization value) carries the key.
    static func accepts(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst("Bearer ".count).utf8)
        let expected = Array(current.utf8)
        // Compare in constant time.
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 24 characters from a URL- and shell-safe alphabet: tc_ plus 128+ bits.
    private static func make() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "tc_" + String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

import Foundation
import Security

/// Production keys have one authoritative store: the login Keychain.
struct ApiKeyStore: Sendable {
    static let keyByteCount = 32
    static let defaultAccount = "llama-server-api-key"
    static let service = "com.zenxiv.Launcher27B"
    private let read: @Sendable () throws -> String?
    private let write: @Sendable (String) throws -> Void

    init(read: @escaping @Sendable () throws -> String?, write: @escaping @Sendable (String) throws -> Void) {
        self.read = read
        self.write = write
    }

    static func applicationDefault(supportDirectory: URL) -> ApiKeyStore {
        ApiKeyStore(
            read: { try readKeychain(service: service, account: defaultAccount) },
            write: { try writeKeychain($0, service: service, account: defaultAccount) }
        )
    }

    func existingKey() throws -> String? { try read() }
    func loadOrCreateKey() throws -> String {
        if let key = try read() { return key }
        let key = try Self.generateKey()
        try write(key)
        return key
    }
    @discardableResult func rotateKey() throws -> String {
        let key = try Self.generateKey()
        try write(key)
        return key
    }

    static func generateKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ApiKeyStoreError.randomGenerationFailed(status: status)
        }

        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func readKeychain(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8),
                  !key.isEmpty
            else { throw ApiKeyStoreError.keychainFailure(status: errSecDecode) }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw ApiKeyStoreError.keychainFailure(status: status)
        }
    }

    private static func writeKeychain(_ key: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw ApiKeyStoreError.keychainFailure(status: updateStatus)
        }

        var insert = query
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ApiKeyStoreError.keychainFailure(status: addStatus)
        }
    }

}

enum ApiKeyStoreError: LocalizedError, AppLocalizableError {
    case randomGenerationFailed(status: OSStatus)
    case keychainFailure(status: OSStatus)
    var errorDescription: String? {
        switch self {
        case let .randomGenerationFailed(status): "无法生成 API 密钥（OSStatus \(status)）"
        case let .keychainFailure(status): "无法访问钥匙串以保存 API 密钥（OSStatus \(status)）"
        }
    }
    @MainActor func localizedDescription(using preferences: AppPreferences) -> String {
        switch self {
        case let .randomGenerationFailed(status): preferences.localizedFormat("无法生成 API 密钥（OSStatus %lld）", Int64(status))
        case let .keychainFailure(status): preferences.localizedFormat("无法访问钥匙串以保存 API 密钥（OSStatus %lld）", Int64(status))
        }
    }
}

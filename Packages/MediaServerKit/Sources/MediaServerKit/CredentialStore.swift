import Foundation
import Security

/// 保存一段敏感数据（访问令牌、API 密钥）。
public protocol SecretStore: Sendable {
    func read() -> Data?
    func write(_ data: Data) throws
    func delete()
}

/// 正式版使用：存在 macOS 钥匙串里。
public struct KeychainSecretStore: SecretStore {
    let service: String
    let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(q as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// 仅开发版使用：没有正式签名证书时，每次重新编译钥匙串都会弹窗要求授权，
/// 所以开发版存成只有当前用户可读写（600 权限）的文件。
public struct FileSecretStore: SecretStore {
    let url: URL

    public init(url: URL) { self.url = url }

    public func read() -> Data? { try? Data(contentsOf: url) }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// 已添加的 Emby 服务器账号列表（含访问令牌）。兼容旧版只存一个账号的格式。
public struct AccountStore: Sendable {
    let secrets: any SecretStore

    public init(secrets: any SecretStore) { self.secrets = secrets }

    public func load() -> [EmbyAccount] {
        guard let data = secrets.read() else { return [] }
        if let list = try? JSONDecoder().decode([EmbyAccount].self, from: data) { return list }
        if let single = try? JSONDecoder().decode(EmbyAccount.self, from: data) { return [single] }
        return []
    }

    public func save(_ accounts: [EmbyAccount]) throws {
        if accounts.isEmpty { secrets.delete() } else { try secrets.write(JSONEncoder().encode(accounts)) }
    }
}

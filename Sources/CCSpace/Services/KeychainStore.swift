import Foundation
import os
import Security

private let keychainLog = Logger(
    subsystem: "com.ccspace.app",
    category: "Keychain"
)

enum APIKeySecretStoreError: LocalizedError, Equatable {
    case unavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "系统钥匙串不可用（\(reason)），API Key 已按降级方式保存"
        }
    }
}

/// 机密项存储抽象:生产用 macOS 钥匙串,测试注入内存实现。
protocol APIKeySecretStore: Sendable {
    /// 读取 API Key;无存储项或读取失败返回 nil。
    func readAPIKey() -> String?
    /// 写入 API Key;空字符串语义为删除。失败抛错(调用方决定降级策略)。
    func storeAPIKey(_ apiKey: String) throws
}

/// macOS 钥匙串(Generic Password)封装。
///
/// 用经典文件钥匙串而非 data-protection keychain:后者要求有效的应用标识符
/// entitlement,对本项目(SwiftPM 构建 + ad-hoc 重签,见 run.sh vtool 补丁)
/// 的本地调试产物可能直接报 errSecMissingEntitlement(-34018)。
/// 代价是重建签名后系统可能弹一次"钥匙串访问"授权,属可接受的本地开发摩擦。
struct SecurityAPIKeyStore: APIKeySecretStore {
    static let shared = SecurityAPIKeyStore()

    private let service = "com.ccspace.app.ai"
    private let account = "api-key"

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func readAPIKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                keychainLog.error("event=keychain_read_decode_failed")
                return nil
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            // 其它状态(锁屏拒绝、-67674 ACL 弹窗超时等):按无存储处理但留痕,
            // 让上层降级逻辑可被诊断。
            keychainLog.error("event=keychain_read_failed status=\(status)")
            return nil
        }
    }

    func storeAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空串语义为删除。
        guard trimmed.isEmpty == false else {
            let deleteStatus = SecItemDelete(baseQuery() as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                keychainLog.error("event=keychain_delete_failed status=\(deleteStatus)")
                throw APIKeySecretStoreError.unavailable(reason: "删除旧条目失败(status \(deleteStatus))")
            }
            return
        }

        // 先查询更新、条目不存在才新增:不用"先删后加",否则删除与新增之间崩溃
        // 会把密钥永久丢失。SecItemUpdate 对不存在的条目返回 errSecItemNotFound。
        let updateAttributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addAttributes = baseQuery()
            addAttributes[kSecValueData as String] = Data(trimmed.utf8)
            addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                keychainLog.error("event=keychain_add_failed status=\(addStatus)")
                throw APIKeySecretStoreError.unavailable(reason: "写入失败(status \(addStatus))")
            }
        default:
            keychainLog.error("event=keychain_update_failed status=\(updateStatus)")
            throw APIKeySecretStoreError.unavailable(reason: "更新条目失败(status \(updateStatus))")
        }
    }
}

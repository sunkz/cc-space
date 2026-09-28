import Foundation

/// 机密项存储抽象:生产用 macOS 钥匙串,测试注入内存实现。
///
/// 声明放在 Models 层(实现在 Services/KeychainStore.swift):
/// Models 层的 `AppSettings.backfillAPIKeyFromKeychainIfManaged` 以本协议为参数类型,
/// 而依赖方向约定为 Views→AppState/Stores→Services→Models——协议若留在 Services,
/// 就构成 Models→Services 的反向依赖。协议本身是零实现依赖的纯抽象,
/// 下沉声明即可恢复分层方向,Services 侧实现与全部调用点无需改动(同一 target)。
protocol APIKeySecretStore: Sendable {
    /// 读取 API Key;无存储项或读取失败返回 nil。
    func readAPIKey() -> String?
    /// 写入 API Key;空字符串语义为删除。失败抛错(调用方决定降级策略)。
    func storeAPIKey(_ apiKey: String) throws
}

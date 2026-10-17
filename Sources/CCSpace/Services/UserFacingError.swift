import Foundation

/// 面向用户的错误文案(简体中文)统一入口:直接取 `error.localizedDescription` 会把取消与 POSIX/Cocoa/NSURLError
/// 域的英文原文原样暴露给用户。顺序:取消 → git 错误 → 系统域错误 → 兜底。
/// 未命中 localizeMessage 模式表的 git stderr 是英文原文,这里补中文标识;自带中文文案的 `LocalizedError` 走兜底不被改写。
enum UserFacingError {
    static func message(for error: Error) -> String {
        if error is CancellationError {
            return "操作已取消"
        }
        // 命中模式表的 errorDescription 已是中文(并做凭据脱敏);未命中的 stderr 原样是英文,不补标识用户会在 UI 上看到 git 英文报错。
        // 判据必须是结构性的(是否真被映射过),不能用"是否含汉字":英文报错里出现中文文件名/分支名很常见,含汉字≠已转中文。
        if let gitError = error as? GitServiceError {
            let description = gitError.localizedDescription
            switch gitError {
            case .commandFailed(let stderr):
                // 空 stderr 的 errorDescription 是内置中文标识,同样无需再补前缀。
                let mapped = stderr.isEmpty || GitServiceError.localizeMessage(stderr) != nil
                return mapped ? description : "git 执行失败：\(description)"
            case .operationFailed(let message):
                // 整段文案由调用方给定(本项目内均为中文),按整段含汉字判断即可。
                return containsChinese(message) ? description : "git 执行失败：\(description)"
            }
        }
        // 其余错误域:先做凭据脱敏(远端 URL 里的 token/密码不得随描述进 UI),再按域加中文前缀。
        let description = GitServiceError.redactCredentials(in: error.localizedDescription)
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain, NSPOSIXErrorDomain:
            return "系统错误：\(description)"
        case NSURLErrorDomain:
            // 用户主动取消不是失败(对齐 CancellationError 的文案),不渲染错误横幅。
            if nsError.code == NSURLErrorCancelled {
                return "操作已取消"
            }
            return "网络错误：\(description)"
        default:
            // 自带 errorDescription 的错误文案均为中文,原样透出;纯英文补中文前缀,不让英文进 UI。
            if error is LocalizedError || containsChinese(description) {
                return description
            }
            return "操作失败：\(description)"
        }
    }

    /// 整段文案是否已含汉字(全角标点不算);只用于整段自撰的文案,`commandFailed` 的英文 stderr 不靠它判。
    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }
}

import Foundation

/// 面向用户的错误文案（简体中文）统一入口。
///
/// `lastError` 等最终会显示在 UI 上的字符串若直接取 `error.localizedDescription`,
/// `CancellationError`("The operation couldn't be completed…")与 POSIX/Cocoa/NSURLError 域
/// 系统错误的英文原文会原样暴露给用户,违反"面向用户文案为简体中文"的约定。
///
/// 处理顺序:取消 → git 错误(命中 localizeMessage 模式表的已转中文+脱敏;**未命中已知
/// 模式的 git stderr 是英文原文透出**,这里补中文标识) → 系统域错误(中文前缀 + 描述;
/// 用户主动取消的网络错误按「操作已取消」处理,不报错横幅) → 兜底(自带中文文案原样透出,
/// 纯英文补中文前缀)。自带中文文案的 `LocalizedError`(GitWorktreeSafetyError、
/// WorkplaceRuntimeServiceError 等)走兜底分支,既有中文文案不会被改写。
enum UserFacingError {
    static func message(for error: Error) -> String {
        if error is CancellationError {
            return "操作已取消"
        }
        // 命中 localizeMessage 模式表的 errorDescription 已是中文(并做凭据脱敏),
        // 未命中的 stderr 原样英文(如 merge 冲突、本地改动被覆盖),不补标识会让用户
        // 在 UI 上直接看到英文 git 报错。判据是结构性的(是否真被映射过),不能用
        // "是否含汉字":英文报错里出现中文文件名/分支名很常见
        // (如 `would be overwritten by merge:` + `技术文档.md`),含汉字≠已转中文。
        if let gitError = error as? GitServiceError {
            let description = gitError.localizedDescription
            switch gitError {
            case .commandFailed(_, let stderr):
                // 空 stderr 的 errorDescription 是内置中文标识,同样无需再补前缀。
                let mapped = stderr.isEmpty || GitServiceError.localizeMessage(stderr) != nil
                return mapped ? description : "git 执行失败：\(description)"
            case .operationFailed(let message):
                // 整段文案由调用方给定(本项目内均为中文),按整段含汉字判断即可。
                return containsChinese(message) ? description : "git 执行失败：\(description)"
            }
        }
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
            // 自带 errorDescription 的错误(本项目内 `LocalizedError` 的文案均为中文)
            // 原样透出;裸 NSError 之类的英文描述补中文前缀,不让纯英文进 UI。
            if error is LocalizedError || containsChinese(description) {
                return description
            }
            return "操作失败：\(description)"
        }
    }

    /// 整段文案里是否已有汉字:已含中文则不再重复加前缀(全角标点不算)。
    /// 只用于整段自撰的文案(operationFailed、兜底分支);`commandFailed` 的英文
    /// stderr 不靠它判(见上方结构性判据)。
    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }
}

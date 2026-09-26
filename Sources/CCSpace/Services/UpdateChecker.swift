import Foundation
import os
import Combine

private let updateCheckerLog = Logger(
    subsystem: "com.ccspace.app",
    category: "UpdateChecker"
)

private struct GitHubLatestReleaseResponse: Decodable {
    let tagName: String

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    @Published private(set) var latestVersion: String?
    @Published private(set) var isChecking = false
    @Published private(set) var lastErrorMessage: String?

    let currentVersion: String
    let releasesURL: URL

    private let latestReleaseAPIURL: URL
    private let dataLoader: DataLoader

    init(
        currentVersion: String = UpdateChecker.defaultCurrentVersion,
        releasesURL: URL = URL(string: "https://github.com/sunkz/cc-space/releases")!,
        latestReleaseAPIURL: URL = URL(string: "https://api.github.com/repos/sunkz/cc-space/releases/latest")!,
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.currentVersion = currentVersion
        self.releasesURL = releasesURL
        self.latestReleaseAPIURL = latestReleaseAPIURL
        self.dataLoader = dataLoader
    }

    var hasUpdate: Bool {
        guard let latestVersion else { return false }
        // 无 bundle 的开发运行(如 swift run)拿不到版本号,回退 "0" 会让任何远端版本
        // 都被判定为更新;此时不提示。
        guard currentVersion.isEmpty == false, currentVersion != "0" else { return false }
        return Self.isNewerVersion(latestVersion, than: currentVersion)
    }

    func check() async {
        guard isChecking == false else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CCSpace/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await dataLoader(request)
            guard !Task.isCancelled else { return }
            guard let httpResponse = response as? HTTPURLResponse else {
                latestVersion = nil
                lastErrorMessage = "检查更新失败：响应无效"
                return
            }

            guard httpResponse.statusCode == 200 else {
                latestVersion = nil
                lastErrorMessage = "检查更新失败：HTTP \(httpResponse.statusCode)"
                return
            }

            let release = try JSONDecoder().decode(GitHubLatestReleaseResponse.self, from: data)
            let version = Self.normalizeVersionTag(release.tagName)

            latestVersion = version
            lastErrorMessage = nil
            updateCheckerLog.notice("event=update_check status=success version=\(version)")
        } catch {
            // 失败时**保留**上次已知的 latestVersion:一次网络抖动就让"有更新"
            // 徽标闪烁消失会误导用户(刚才还有新版本,现在又显示无)。
            // 错误信息照记,版本只在成功拿到结果时更新。
            lastErrorMessage = Self.userFacingFailureMessage(for: error)
            updateCheckerLog.error("event=update_check status=failed reason=\(error.localizedDescription)")
        }
    }

    /// 把检查更新失败映射为用户可读中文:NSURLError 的 localizedDescription 是英文,
    /// 直接透出体验差;网络类错误一律给映射文案或通用兜底,不掺英文原文。
    private static func userFacingFailureMessage(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            // 非网络错误(如响应解码失败)保留原格式,便于定位问题。
            return "检查更新失败：\(error.localizedDescription)"
        }
        switch nsError.code {
        case NSURLErrorTimedOut:
            return "检查更新失败：连接超时，请检查网络后重试"
        case NSURLErrorNotConnectedToInternet:
            return "检查更新失败：没有网络连接，请检查网络后重试"
        case NSURLErrorCannotFindHost:
            return "检查更新失败：无法解析更新服务器地址"
        case NSURLErrorCannotConnectToHost:
            return "检查更新失败：无法连接更新服务器"
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateUntrusted:
            return "检查更新失败：安全连接失败，请检查系统时间与网络环境"
        default:
            return "检查更新失败，请稍后重试"
        }
    }

    private static var defaultCurrentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    private nonisolated static func normalizeVersionTag(_ tag: String) -> String {
        // 兼容大小写两种 "v" 前缀:"V1.2.3" 不剥前缀会落进 .numeric 兜底比较,结果不可靠。
        if tag.hasPrefix("v") || tag.hasPrefix("V") {
            return String(tag.dropFirst())
        }
        return tag
    }

    nonisolated static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let normalizedCandidate = normalizeVersionTag(candidate)
        let normalizedCurrent = normalizeVersionTag(current)

        if let candidateVersion = SemanticVersion(normalizedCandidate),
           let currentVersion = SemanticVersion(normalizedCurrent) {
            return candidateVersion > currentVersion
        }

        return normalizedCandidate.compare(normalizedCurrent, options: .numeric) == .orderedDescending
    }
}

private struct SemanticVersion: Comparable {
    let coreComponents: [Int]
    let preReleaseIdentifiers: [SemanticVersionIdentifier]?

    init?(_ rawVersion: String) {
        let trimmedVersion = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedVersion.isEmpty == false else { return nil }

        let versionWithoutBuildMetadata = trimmedVersion
            .split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? trimmedVersion
        let mainParts = versionWithoutBuildMetadata
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)

        let corePart = mainParts[0]
        let parsedCoreComponents = corePart
            .split(separator: ".", omittingEmptySubsequences: false)
            .compactMap { Int($0) }
        guard parsedCoreComponents.isEmpty == false,
              parsedCoreComponents.count == corePart.split(separator: ".", omittingEmptySubsequences: false).count else {
            return nil
        }

        coreComponents = parsedCoreComponents
        if mainParts.count > 1 {
            let preReleasePart = mainParts[1]
            let identifiers = preReleasePart
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(SemanticVersionIdentifier.init)
            preReleaseIdentifiers = identifiers.isEmpty ? nil : identifiers
        } else {
            preReleaseIdentifiers = nil
        }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let maxCoreComponentCount = max(lhs.coreComponents.count, rhs.coreComponents.count)
        for index in 0..<maxCoreComponentCount {
            let lhsValue = index < lhs.coreComponents.count ? lhs.coreComponents[index] : 0
            let rhsValue = index < rhs.coreComponents.count ? rhs.coreComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue < rhsValue
            }
        }

        switch (lhs.preReleaseIdentifiers, rhs.preReleaseIdentifiers) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(lhsIdentifiers), .some(rhsIdentifiers)):
            let maxIdentifierCount = max(lhsIdentifiers.count, rhsIdentifiers.count)
            for index in 0..<maxIdentifierCount {
                guard index < lhsIdentifiers.count else { return true }
                guard index < rhsIdentifiers.count else { return false }
                let lhsIdentifier = lhsIdentifiers[index]
                let rhsIdentifier = rhsIdentifiers[index]
                if lhsIdentifier != rhsIdentifier {
                    return lhsIdentifier < rhsIdentifier
                }
            }
            return false
        }
    }
}

private enum SemanticVersionIdentifier: Comparable {
    case numeric(Int)
    case text(String)

    init(_ rawIdentifier: Substring) {
        if let numericValue = Int(rawIdentifier) {
            self = .numeric(numericValue)
        } else {
            self = .text(String(rawIdentifier))
        }
    }

    static func < (lhs: SemanticVersionIdentifier, rhs: SemanticVersionIdentifier) -> Bool {
        switch (lhs, rhs) {
        case let (.numeric(lhsValue), .numeric(rhsValue)):
            return lhsValue < rhsValue
        case (.numeric, .text):
            return true
        case (.text, .numeric):
            return false
        case let (.text(lhsValue), .text(rhsValue)):
            return lhsValue < rhsValue
        }
    }
}

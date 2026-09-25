import Foundation

enum GitURLParser {
    /// 校验用户配置的远端仓库 URL,阻止两类攻击面进入 git argv:
    /// 1. `ext::`/`fd::` 等可执行任意命令的传输形式(git 对用户直接发起的命令默认放行 ext::);
    /// 2. 以 `-` 开头的 URL 被 git 解析为选项(如 `--upload-pack=`)。
    /// 放行:http(s)/ssh/git/file 协议、scp 风格(user@host:path)与本地路径。
    /// GitProcessRunner 另以 GIT_ALLOW_PROTOCOL 做进程级兜底。
    static func validateRemoteURL(_ rawURL: String) throws {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw gitURLParserError("仓库地址不能为空")
        }
        guard trimmed.hasPrefix("-") == false else {
            throw gitURLParserError("仓库地址不合法：不能以 - 开头")
        }
        guard trimmed.contains(where: { $0.asciiValue != nil && ($0 < " " || $0 == "\u{7f}") }) == false else {
            throw gitURLParserError("仓库地址不合法：包含控制字符")
        }
        if let schemeEnd = trimmed.range(of: "://") {
            let scheme = String(trimmed[trimmed.startIndex..<schemeEnd.lowerBound]).lowercased()
            let allowedSchemes: Set<String> = ["http", "https", "ssh", "git", "file"]
            guard allowedSchemes.contains(scheme) else {
                throw gitURLParserError("仓库地址不合法：不支持的协议 \(scheme)")
            }
            return
        }
        // 无 "://" 时拒绝一切 "xxx::" 传输形式(ext::/fd:: 等);
        // 其余按 scp 风格(user@host:path)或本地路径放行。
        guard trimmed.contains("::") == false else {
            throw gitURLParserError("仓库地址不合法：不支持的协议形式")
        }
    }

    static func repositoryName(from gitURL: String) throws -> String {
        if let location = try? repositoryWebLocation(from: gitURL) {
            return try repositoryName(fromRepositoryPath: location.repositoryPath)
        }

        return try repositoryNameFromLegacyTail(gitURL)
    }

    static func mergeRequestURL(
        from remoteURL: String,
        sourceBranch: String,
        targetBranch: String
    ) throws -> URL {
        let trimmedSourceBranch = sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetBranch = targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedSourceBranch.isEmpty == false else {
            throw gitURLParserError("无法识别当前分支")
        }
        guard trimmedTargetBranch.isEmpty == false else {
            throw gitURLParserError("无法识别仓库默认分支")
        }
        guard trimmedSourceBranch != trimmedTargetBranch else {
            throw gitURLParserError("当前已在默认分支，无法创建 MR")
        }

        let location = try repositoryWebLocation(from: remoteURL)
        var components = URLComponents()
        components.scheme = location.scheme
        components.host = location.host
        components.port = location.port

        switch location.provider {
        case .github, .gitee:
            // Gitee 的对比页与 GitHub 同构:/owner/repo/compare/base...head。
            let encodedTarget = trimmedTargetBranch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedTargetBranch
            let encodedSource = trimmedSourceBranch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedSourceBranch
            components.path = "/\(location.repositoryPath)/compare/\(encodedTarget)...\(encodedSource)"
            components.queryItems = [URLQueryItem(name: "expand", value: "1")]
        case .gitlab:
            components.path = "/\(location.repositoryPath)/merge_requests/new"
            components.queryItems = [
                URLQueryItem(name: "merge_request[source_branch]", value: trimmedSourceBranch),
                URLQueryItem(name: "merge_request[target_branch]", value: trimmedTargetBranch),
            ]
        case .unsupported(let providerName):
            throw gitURLParserError("暂不支持为 \(providerName) 仓库生成 MR 链接")
        }

        guard let url = components.url else {
            throw gitURLParserError("无法生成 MR 链接")
        }
        return url
    }
}

private extension GitURLParser {
    enum HostingProvider {
        case github
        case gitlab
        case gitee
        case unsupported(String)
    }

    struct RepositoryWebLocation {
        let scheme: String
        let host: String
        let port: Int?
        let repositoryPath: String
        let provider: HostingProvider
    }

    static func repositoryWebLocation(from remoteURL: String) throws -> RepositoryWebLocation {
        let trimmedRemoteURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let components = URLComponents(string: trimmedRemoteURL),
           let host = components.host,
           let repositoryPath = normalizedRepositoryPath(from: components.path) {
            return RepositoryWebLocation(
                scheme: normalizedWebScheme(from: components.scheme),
                host: host,
                port: normalizedWebPort(from: components),
                repositoryPath: repositoryPath,
                provider: hostingProvider(for: host)
            )
        }

        if let scpLocation = scpStyleRepositoryLocation(from: trimmedRemoteURL) {
            return RepositoryWebLocation(
                scheme: "https",
                host: scpLocation.host,
                port: nil,
                repositoryPath: scpLocation.repositoryPath,
                provider: hostingProvider(for: scpLocation.host)
            )
        }

        throw gitURLParserError("无法解析仓库地址")
    }

    static func normalizedRepositoryPath(from rawPath: String) -> String? {
        let trimmedPath = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmedPath.isEmpty == false else { return nil }

        if trimmedPath.hasSuffix(".git") {
            return String(trimmedPath.dropLast(4))
        }
        return trimmedPath
    }

    static func repositoryName(fromRepositoryPath repositoryPath: String) throws -> String {
        guard let tail = repositoryPath.split(separator: "/").last else {
            throw gitURLParserError("无法解析仓库名称")
        }
        let repositoryName = String(tail)
        guard repositoryName.isEmpty == false else {
            throw gitURLParserError("仓库名称不能为空")
        }
        return repositoryName
    }

    static func repositoryNameFromLegacyTail(_ gitURL: String) throws -> String {
        guard let tail = gitURL.split(separator: "/").last.map({
            let segment = String($0)
            if let colonIndex = segment.lastIndex(of: ":") {
                return segment[segment.index(after: colonIndex)...]
            }
            return segment[...]
        }) ?? gitURL.split(separator: ":").last else {
            throw gitURLParserError("无法解析仓库名称")
        }

        let repositoryName = tail.hasSuffix(".git") ? String(tail.dropLast(4)) : String(tail)
        guard repositoryName.isEmpty == false else {
            throw gitURLParserError("仓库名称不能为空")
        }
        return repositoryName
    }

    static func scpStyleRepositoryLocation(
        from remoteURL: String
    ) -> (host: String, repositoryPath: String)? {
        guard let atIndex = remoteURL.firstIndex(of: "@") else { return nil }
        let hostAndPath = remoteURL[remoteURL.index(after: atIndex)...]
        guard let colonIndex = hostAndPath.firstIndex(of: ":") else { return nil }

        let host = String(hostAndPath[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pathStartIndex = hostAndPath.index(after: colonIndex)
        let rawPath = String(hostAndPath[pathStartIndex...])

        guard host.isEmpty == false,
              let repositoryPath = normalizedRepositoryPath(from: rawPath) else {
            return nil
        }

        return (host: host, repositoryPath: repositoryPath)
    }

    static func hostingProvider(for host: String) -> HostingProvider {
        let normalizedHost = host.lowercased()

        if normalizedHost.contains("github") {
            return .github
        }
        if normalizedHost.contains("gitlab") {
            return .gitlab
        }
        if normalizedHost.contains("gitee") {
            return .gitee
        }
        if normalizedHost.contains("bitbucket") {
            return .unsupported("Bitbucket")
        }
        if normalizedHost.contains("gitea") || normalizedHost.contains("gogs") {
            return .unsupported("Gitea")
        }
        if normalizedHost.contains("dev.azure") || normalizedHost.contains("visualstudio") {
            return .unsupported("Azure DevOps")
        }
        // Default to GitLab MR format for self-hosted instances (most common)
        return .gitlab
    }

    static func normalizedWebScheme(from scheme: String?) -> String {
        guard let scheme else { return "https" }
        switch scheme.lowercased() {
        case "http", "https":
            return scheme.lowercased()
        default:
            return "https"
        }
    }

    static func normalizedWebPort(from components: URLComponents) -> Int? {
        guard let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return components.port
        default:
            return nil
        }
    }

    static func gitURLParserError(_ message: String) -> NSError {
        NSError(
            domain: "GitURLParser",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

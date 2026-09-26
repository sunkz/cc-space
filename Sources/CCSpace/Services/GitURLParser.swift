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
            // 明文凭据防线:`https://user:pass@host/repo` 会原样进入 git argv,
            // ps 与错误日志可见。用户名单独出现(token 当用户名)仍放行;
            // 同时带用户名和密码则拒绝,引导走凭据管理或 SSH。
            if let components = URLComponents(string: trimmed),
               components.user != nil,
               components.password != nil {
                throw gitURLParserError("远端地址中包含明文账号密码，请改用 SSH 地址或凭据管理（osxkeychain）后再试")
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

    /// 仓库 Web 主页链接(`https://host[:port]/owner/repo`),供"在浏览器打开仓库"使用。
    /// 与 MR 链接同一解析口径:支持 http(s)/ssh/git 与 scp 风格地址,`.git` 后缀剥离。
    static func repositoryWebURL(from remoteURL: String) throws -> URL {
        let location = try repositoryWebLocation(from: remoteURL)
        var components = URLComponents()
        components.scheme = location.scheme
        components.host = location.host
        components.port = location.port
        components.path = "/\(location.repositoryPath)"
        guard let url = components.url else {
            throw gitURLParserError("无法生成仓库链接")
        }
        return url
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
    enum HostingProvider: Equatable {
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
                // URLComponents.path 保留百分号编码,`my%20repo` 会以编码形态
                // 泄漏进仓库名与 Web 链接(再被二次编码成 %2520);
                // 出口处统一解码,解码失败(字面 % 的非法序列)原样返回。
                repositoryPath: percentDecoded(repositoryPath),
                provider: hostingProvider(for: host)
            )
        }

        if let scpLocation = scpStyleRepositoryLocation(from: trimmedRemoteURL) {
            return RepositoryWebLocation(
                scheme: "https",
                host: scpLocation.host,
                port: nil,
                repositoryPath: percentDecoded(scpLocation.repositoryPath),
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

        let repositoryName = percentDecoded(tail.hasSuffix(".git") ? String(tail.dropLast(4)) : String(tail))
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

        // 精确后缀匹配:子串匹配(`contains("github")`)会把 gitlab-cache.example.net、
        // my-giteo-mirror 这类自建域名误分类,生成打不开的 MR 链接。
        func matches(_ domain: String) -> Bool {
            normalizedHost == domain || normalizedHost.hasSuffix("." + domain)
        }
        // 自建实例的 label 启发:主机名**首段**恰好是 gitlab/gitea 等(如 gitlab.acme.com)。
        func firstLabel(_ label: String) -> Bool {
            normalizedHost.split(separator: ".", omittingEmptySubsequences: true).first.map(String.init) == label
        }

        if matches("github.com") || matches("ssh.github.com") || firstLabel("github") {
            return .github
        }
        if matches("gitee.com") || firstLabel("gitee") {
            return .gitee
        }
        if matches("bitbucket.org") || matches("bitbucket.io") || firstLabel("bitbucket") {
            return .unsupported("Bitbucket")
        }
        if matches("dev.azure.com") || matches("visualstudio.com") || firstLabel("dev.azure") || firstLabel("visualstudio") {
            return .unsupported("Azure DevOps")
        }
        if matches("gitlab.com") || matches("gitlab.net") || firstLabel("gitlab") {
            return .gitlab
        }
        if firstLabel("gitea") || firstLabel("gogs") || matches("gitea.com") {
            return .unsupported("Gitea")
        }
        // P2-30 取舍说明:未知 host 维持 GitLab MR 格式兜底而非返回 .unsupported——
        // 枚举虽有 unsupported(String) 可用,但现有 MergeRequestServiceTests 以
        // 未知 host(code.example.com)锁定兜底行为,且自建 GitLab 场景兜底命中率
        // 不低;改为显式报错需要连同上游测试与产品预期一起调整,此处不强行切换。
        // 已知代价:非 GitLab 的未知平台会生成打不开的死 MR 链接
        // (仓库主页链接不受影响)。
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

    /// 百分号解码,失败(含字面 % 的非法序列)原样返回。
    static func percentDecoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    static func gitURLParserError(_ message: String) -> NSError {
        NSError(
            domain: "GitURLParser",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

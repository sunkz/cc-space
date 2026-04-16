import Foundation

enum GitURLParser {
    static func repositoryName(from gitURL: String) throws -> String {
        guard let tail = gitURL.split(separator: "/").last.map({
            let segment = String($0)
            if let colonIndex = segment.lastIndex(of: ":") {
                return segment[segment.index(after: colonIndex)...]
            }
            return segment[...]
        }) ?? gitURL.split(separator: ":").last else {
            throw NSError(
                domain: "GitURLParser",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法解析仓库名称"]
            )
        }

        let repositoryName = tail.hasSuffix(".git") ? String(tail.dropLast(4)) : String(tail)
        guard repositoryName.isEmpty == false else {
            throw NSError(
                domain: "GitURLParser",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "仓库名称不能为空"]
            )
        }

        return repositoryName
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
        case .github:
            components.path = "/\(location.repositoryPath)/compare/\(trimmedTargetBranch)...\(trimmedSourceBranch)"
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
        if normalizedHost.contains("bitbucket") {
            return .unsupported("Bitbucket")
        }
        if normalizedHost.contains("gitea") || normalizedHost.contains("gogs") {
            return .unsupported("Gitea")
        }
        if normalizedHost.contains("dev.azure") || normalizedHost.contains("visualstudio") {
            return .unsupported("Azure DevOps")
        }
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

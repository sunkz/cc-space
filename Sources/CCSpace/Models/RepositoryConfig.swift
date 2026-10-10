import Foundation

struct RepositoryConfig: Equatable, Identifiable, Sendable, Codable {
    let id: UUID
    var gitURL: String
    var repoName: String
    var defaultBranch: String?
    var mrTargetBranches: [String]
    /// 仓库级常用链接(流水线/看板/文档等),设置弹窗录入,工作区仓库行 ⋯ 菜单打开。
    var links: [CommonLink]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        gitURL: String,
        repoName: String,
        defaultBranch: String? = nil,
        mrTargetBranches: [String] = [],
        links: [CommonLink] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.gitURL = gitURL
        self.repoName = repoName
        self.defaultBranch = defaultBranch
        self.mrTargetBranches = Self.deduplicated(mrTargetBranches)
        // links 不变式(去重/合法性/上限)双路径收口,见 CommonLinksInput.sanitize。
        self.links = CommonLinksInput.sanitize(links)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        gitURL = try container.decode(String.self, forKey: .gitURL)
        repoName = try container.decode(String.self, forKey: .repoName)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        // 保序去重:手工编辑/导入的 JSON 可能含重复分支,直存会让
        // MRTargetBranchPicker 的 ForEach(id: \.self) 出现重复 ID(SwiftUI UB)。
        mrTargetBranches = Self.deduplicated(
            try container.decodeIfPresent([String].self, forKey: .mrTargetBranches) ?? []
        )
        // 老配置无 links 字段:解码为空数组;成员式与解码两条路径共用同一净化。
        links = CommonLinksInput.sanitize(
            try container.decodeIfPresent([CommonLink].self, forKey: .links) ?? []
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// 不变式收敛点:`mrTargetBranches` 无重复。
    /// 去重原先只挡解码路径,成员式构造(新增仓库弹窗、导入前的内存对象)可带着
    /// 重复值进入同一个 `ForEach(id: \.self)`,因此两条路径共用此实现。
    static func deduplicated(_ branches: [String]) -> [String] {
        var seen = Set<String>()
        return branches.filter { seen.insert($0).inserted }
    }
}

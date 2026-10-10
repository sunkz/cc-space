import Foundation

struct Workplace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var selectedRepositoryIDs: [UUID]
    var branch: String?
    var isPinned: Bool
    var pinnedRepositoryIDs: [UUID]
    var isArchived: Bool
    /// 工作区级常用链接(需求文档/环境地址等),创建/编辑工作区表单录入,详情页工具栏打开。
    var links: [CommonLink]
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case selectedRepositoryIDs
        case branch
        case isPinned
        case pinnedRepositoryIDs
        case isArchived
        case links
        case createdAt
        case updatedAt
    }

    init(
        id: UUID,
        name: String,
        path: String,
        selectedRepositoryIDs: [UUID],
        branch: String? = nil,
        isPinned: Bool = false,
        pinnedRepositoryIDs: [UUID] = [],
        isArchived: Bool = false,
        links: [CommonLink] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.selectedRepositoryIDs = selectedRepositoryIDs
        self.branch = branch
        self.isPinned = isPinned
        self.pinnedRepositoryIDs = pinnedRepositoryIDs
        self.isArchived = isArchived
        // links 不变式双路径收口(口径同 RepositoryConfig),见 CommonLinksInput.sanitize。
        self.links = CommonLinksInput.sanitize(links)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        selectedRepositoryIDs = try container.decode([UUID].self, forKey: .selectedRepositoryIDs)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinnedRepositoryIDs = try container.decodeIfPresent([UUID].self, forKey: .pinnedRepositoryIDs) ?? []
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        // 老数据无 links 字段:解码为空数组;成员式与解码两条路径共用同一净化。
        links = CommonLinksInput.sanitize(
            try container.decodeIfPresent([CommonLink].self, forKey: .links) ?? []
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(selectedRepositoryIDs, forKey: .selectedRepositoryIDs)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(pinnedRepositoryIDs, forKey: .pinnedRepositoryIDs)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(links, forKey: .links)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

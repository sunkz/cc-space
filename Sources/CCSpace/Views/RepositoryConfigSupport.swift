import CoreGraphics
import Foundation

/// 设置页仓库列表的布局参数。
enum RepositoryListLayout {
    /// 行间距。
    static let rowSpacing: CGFloat = 6

    /// 全量建行（VStack）的行数上限。新增后要 `scrollTo` 定位到那一行，而懒容器
    /// 只实例化视口附近的行、锚点找不到就静默失败，所以默认用 VStack；
    /// 超过这个上限就退回 LazyVStack 并放弃定位（高亮仍在）——
    /// 否则每次搜索/每次面板状态变化都要重建上百行，输入会明显卡。
    static let eagerRowLimit = 150
}

struct RepositorySearchPresentationState {
    /// 「回到顶部」按钮的出现阈值:列表(过滤后)超出阈值、确实可能滚出首屏才值得出现。
    static let backToTopThreshold = 8

    /// 仓库池为空时的空态副标题:此时搜索框已隐藏(没东西可搜),要指向地址框。
    static let emptyLibrarySubtitle = "在上方地址框粘贴 Git 仓库地址，点「新增仓库」即可添加。"

    let filteredRepositories: [RepositoryConfig]
    let emptyTitle: String
    let emptySubtitle: String

    init(
        repositories: [RepositoryConfig],
        searchText: String
    ) {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 整个仓库池为空时不能说"未找到匹配仓库":搜索框此时已经不出现,
        // 让用户去找一个不存在的输入框是误导。
        if trimmedSearchText.isEmpty || repositories.isEmpty {
            filteredRepositories = repositories
            emptyTitle = "暂无仓库配置"
            emptySubtitle = Self.emptyLibrarySubtitle
            return
        }

        filteredRepositories = repositories.filter { Self.matches($0, keyword: trimmedSearchText) }
        emptyTitle = "未找到匹配仓库"
        emptySubtitle = "试试仓库名称或地址中的关键词。"
    }

    /// 单条仓库是否命中关键词。**列表过滤与「新增后要不要清搜索词」必须共用这一个判据**——
    /// 后者若自己再写一份 `contains`,两边规则迟早漂移,表现为"刚加的仓库莫名看不见"。
    static func matches(_ repository: RepositoryConfig, keyword: String) -> Bool {
        repository.repoName.localizedCaseInsensitiveContains(keyword)
            || repository.gitURL.localizedCaseInsensitiveContains(keyword)
    }

    /// 「回到顶部」是否值得出现:按**过滤后**的条数判断——搜索收窄到几条时
    /// 列表滚不出首屏,按钮没有意义(此前用原始总数,搜索态也会显示)。
    var showsBackToTop: Bool {
        filteredRepositories.count > Self.backToTopThreshold
    }
}

/// Git 地址形态校验:设置页地址框与引导页新增共用这一条规则,两个入口一条判据。
///
/// 不能复用 `GitURLParser.repositoryName`——它有 legacy tail 兜底(取末段当仓库名),
/// "abcabc" 这种裸字符串照样解析成功,校验等于没有;`validateRemoteURL` 又只是防
/// 选项注入的守卫,同样放行裸字符串。这里按声明的三类输入显式判定,并要求**指到具体仓库**:
/// 协议地址 / scp 风格 user@host:path / 本地绝对路径。
enum RepositoryURLFormat {
    /// 本地路径前缀只认绝对路径与家目录。`./`、`../` 不算:git 子进程的 cwd 被钉成
    /// 临时目录(见 GitProcessRunner),相对地址建档后永远克隆不下来,
    /// 与 `LocalPathSafety.normalizedPath`"相对路径一律拒绝"的既有立场保持一致。
    /// (`~/` 由 `RepositoryStore.addRepository` 在建档时展开成绝对路径——git 不做
    /// 波浪号展开,shell 才做,而这里从不经过 shell。)
    private static let localPathPrefixes = ["/", "~"]

    /// 浏览器地址栏才有的 UI 段。**≥3 段时连末段一起判**,两段(`owner/repo`)不判末段:
    /// 后者是仓库名的常见位置(`team/settings` 该放行),而 ≥3 段的末段几乎只可能是
    /// `.../repo/issues` 这类网页。取舍是宁可误拒罕见的三层子组命名,也不误放高频的粘贴误操作。
    private static let webUIPathSegments: Set<String> = [
        "-", "blob", "tree", "raw", "src", "blame", "commit", "commits", "compare",
        "network", "merge_request", "merge_requests", "pull", "pulls", "issue", "issues",
        "labels", "milestones", "security", "discussions", "wiki", "wikis", "pages",
        "new", "edit", "delete", "browse", "projects", "packages", "environments",
        "settings", "actions", "runs", "pipelines", "releases", "tags", "branches", "archive",
    ]

    /// 公共托管域:站点根下**单段路径**是页面不是仓库(`github.com/new`、`github.com/features`)。
    /// 自建 host 不在此列——`https://git.internal/repo` 是合法形态,不能一并拒掉。
    private static let publicHostingHosts: Set<String> = [
        "github.com", "gitlab.com", "bitbucket.org", "gitee.com", "dev.azure.com", "visualstudio.com",
    ]

    /// 判定不通过时给用户的解释,新增入口与校验口径共用一份文案。
    static let invalidMessage = "地址格式不正确：需为指向具体仓库的 http(s)/ssh/git 地址、[user@]host:path 或本地绝对路径"

    static func isParseable(_ gitURL: String) -> Bool {
        let trimmed = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              (try? GitURLParser.validateRemoteURL(trimmed)) != nil else { return false }

        if let scheme = scheme(of: trimmed) {
            guard GitURLParser.allowedRemoteSchemes.contains(scheme) else { return false }
            // `file://` 就是本地路径的规范写法,口径与裸路径保持一致:允许空格、host 段
            // 只允许为空或 localhost(两斜杠形态 git 会把 host 吞掉、解析出错误路径)。
            if scheme == "file" {
                let tail = trimmed[trimmed.range(of: "://")!.upperBound...]
                guard let slash = tail.firstIndex(of: "/") else { return false }
                // host 段只允许为空或 localhost:`file://name/path` 会被 git 当成绝对路径
                // `/path`(host 被吞),Web 链接侧则产出 `https://name/path` 的死链。
                let host = tail[tail.startIndex..<slash]
                guard host.isEmpty || host == "localhost" else { return false }
                return hasRepositoryTail(tail[slash...])
            }
            guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
            return pointsAtRepository(trimmed)
        }
        // 本地绝对路径/家目录:空格合法(macOS 上 `~/Documents/My Projects/app.git` 极常见,
        // 而 git 走 argv 数组传参、空格不构成注入),但不许出现 `..`——"绝对路径"的承诺
        // 不该指到任意目录之外。
        if let prefix = localPathPrefixes.first(where: { trimmed.hasPrefix($0) }) {
            // 家目录只认 `~` 与 `~/`:`~admin/repos/x.git` 这种 `~用户` 形态 git 不会展开
            // (shell 才展开 `~user`,而这里从不经过 shell),app 侧
            // `RepositoryStore.expandingHomeDirectory` 也只处理 `~`/`~/`——放行就是
            // "UI 说地址合法、Store 原样入库、克隆永远失败"。
            if prefix == "~", trimmed.count > 1, trimmed.hasPrefix("~/") == false { return false }
            let tail = trimmed.dropFirst(prefix.count)
            guard tail.split(separator: "/").contains(where: { $0 == ".." }) == false else { return false }
            return hasRepositoryTail(tail)
        }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        if let atIndex = trimmed.firstIndex(of: "@") {
            // scp 风格:`@` 前要有用户名,host 与路径都要非空(后半交解析器把门)。
            guard atIndex > trimmed.startIndex else { return false }
            return pointsAtRepository(trimmed)
        }
        // git 的 scp 语法允许省略用户名(`host:path`,走 SSH 默认用户)。此时冒号前
        // 必须"像个主机名"——否则 `v2.0:beta` 这类搜索词会被判成地址。判定通过后按
        // `git@host:path` 交给同一套解析器把门,不另写一份 scp 解析。
        guard let colon = trimmed.firstIndex(of: ":"),
              isHostnameLike(trimmed[trimmed.startIndex..<colon]) else { return false }
        return pointsAtRepository("git@" + trimmed)
    }

    /// 主机名字形:至少两段、末段是 ≥2 个 ASCII 字母的 TLD、各段只含字母数字与连字符。
    private static func isHostnameLike(_ host: Substring) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard let tld = labels.last, labels.count >= 2, tld.count >= 2,
              tld.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            label.isEmpty == false && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// 必须指到具体仓库:host 与仓库路径都非空(借用 Web 链接解析器同一口径),
    /// 不带 query/fragment(`?ref=main` 会被解析器无声吞掉、原样入库后克隆 404),
    /// 且不是浏览器里的文件/设置页地址。
    private static func pointsAtRepository(_ gitURL: String) -> Bool {
        guard gitURL.contains("?") == false, gitURL.contains("#") == false,
              (try? GitURLParser.repositoryWebURL(from: gitURL)) != nil else { return false }
        let segments = repositoryPathSegments(of: gitURL)
        if isPublicHostingHost(host(of: gitURL)), segments.count < 2 { return false }
        guard segments.count >= 3 else { return true }
        return segments.dropFirst().contains { webUIPathSegments.contains($0.lowercased()) } == false
    }

    private static func isPublicHostingHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return publicHostingHosts.contains { normalized == $0 || normalized.hasSuffix(".\($0)") }
    }

    /// authority 段里的 host(去掉 `user@` 与 `:port`);scp 形态取 `@` 之后到冒号之前。
    private static func host(of gitURL: String) -> String {
        let authority: Substring
        if let schemeEnd = gitURL.range(of: "://") {
            let afterScheme = gitURL[schemeEnd.upperBound...]
            authority = afterScheme[afterScheme.startIndex..<(afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex)]
        } else if let colonIndex = gitURL.firstIndex(of: ":") {
            authority = gitURL[gitURL.startIndex..<colonIndex]
        } else {
            return ""
        }
        let userStart = authority.lastIndex(of: "@").map { authority.index(after: $0) } ?? authority.startIndex
        let withoutUser = authority[userStart...]
        guard let portColon = withoutUser.lastIndex(of: ":") else { return String(withoutUser) }
        // IPv6 字面量 `[::1]` 里的冒号不算端口。
        guard withoutUser.hasPrefix("[") == false else { return String(withoutUser) }
        return String(withoutUser[withoutUser.startIndex..<portColon])
    }

    /// 仓库路径按段拆开(去掉 scheme+host、scp 的 `user@host:` 前缀、首尾斜杠)。
    private static func repositoryPathSegments(of gitURL: String) -> [String] {
        let path: String
        if let schemeEnd = gitURL.range(of: "://") {
            let afterScheme = gitURL[schemeEnd.upperBound...]
            let pathStart = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
            path = String(afterScheme[pathStart...])
        } else if let colonIndex = gitURL.firstIndex(of: ":") {
            path = String(gitURL[gitURL.index(after: colonIndex)...])
        } else {
            path = gitURL
        }
        return path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// 末段剥掉 `.git` 后必须还剩名字:与 `GitURLParser.normalizedRepositoryPath` 同口径,
    /// 否则 `/tmp/.git` 这类输入 UI 放行、Store 却抛"仓库名称不能为空"。
    private static func hasRepositoryTail(_ tail: Substring) -> Bool {
        guard let last = tail.split(separator: "/", omittingEmptySubsequences: true).last else { return false }
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : String(last)
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty == false
    }

    private static func scheme(of gitURL: String) -> String? {
        guard let separator = gitURL.range(of: "://") else { return nil }
        return String(gitURL[gitURL.startIndex..<separator.lowerBound]).lowercased()
    }
}

/// 仓库行 MR 目标分支胶囊的折叠展示(纯逻辑,便于测试):
/// 单行平铺会把右侧操作按钮挤出行外,超过 `maxVisible` 条时只展示前几条,
/// 其余折叠为「+N」(悬停列出明细;增删一律在「添加 MR 目标分支」面板里点选)。
struct RepositoryBranchPillGroupPresentationState {
    static let maxVisible = 3

    let visibleBranches: [String]
    let overflowBranches: [String]

    init(branches: [String]) {
        if branches.count > Self.maxVisible {
            visibleBranches = Array(branches.prefix(Self.maxVisible))
            overflowBranches = Array(branches.dropFirst(Self.maxVisible))
        } else {
            visibleBranches = branches
            overflowBranches = []
        }
    }

    /// 折叠胶囊的标题:nil 表示无需折叠。
    var overflowCountText: String? {
        overflowBranches.isEmpty ? nil : "+\(overflowBranches.count)"
    }

    /// 折叠胶囊的悬停提示:逐条列出被折叠的分支名。
    var overflowQuickHelpText: String? {
        guard overflowBranches.isEmpty == false else { return nil }
        return (["MR 目标分支（已折叠）："] + overflowBranches).joined(separator: "\n")
    }
}

struct RepositoryAddPresentationState {
    let canSubmit: Bool
    /// 非空输入是否通过地址格式预检;空串算"还没输入",不报错。
    /// 点击新增时靠它分流提示:空输入是"没填",填了但不合法才是"格式不对"。
    let isURLFormatValid: Bool

    init(gitURL: String) {
        let trimmed = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        isURLFormatValid = trimmed.isEmpty || RepositoryURLFormat.isParseable(trimmed)
        canSubmit = trimmed.isEmpty == false && isURLFormatValid
    }
}

/// 地址框下方那一行提示的判定(纯值):View 只按 `style` 着色、把 `duplicateRepositoryID`
/// 转成滚动动作,不再自己拼文案。
///
/// 判据按优先级排:没输入且用户已点过新增 > 格式不合法 > 地址已建档 > 「将创建」预览。
/// 空框且没点过按钮时 `text` 为**空串**,调用方据此把整一行收掉——框自身的占位词已经说了
/// "粘贴 Git 仓库地址",下面再复述一遍是噪声,两个输入框之间也就保持普通间距。
struct RepositoryAddFieldHint: Equatable {
    enum Style: Equatable {
        /// 灰色:「将创建」预览(空框时 text 为空串,不显示任何字)。
        case neutral
        /// 橙色:该地址已经建过档,附上那一条的 id 供定位。
        case duplicate
        /// 红色:格式不合法,或点过新增但框里没内容。
        case error
    }

    static let missingInputText = "请先在地址框粘贴 Git 仓库地址。"

    let style: Style
    let text: String
    let duplicateRepositoryID: UUID?

    init(gitURL: String, submitAttempted: Bool, repositories: [RepositoryConfig]) {
        let trimmed = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            style = submitAttempted ? .error : .neutral
            text = submitAttempted ? Self.missingInputText : ""
            duplicateRepositoryID = nil
            return
        }
        guard RepositoryURLFormat.isParseable(trimmed) else {
            style = .error
            text = RepositoryURLFormat.invalidMessage
            duplicateRepositoryID = nil
            return
        }

        // 判重复必须走 Store 建档时同一套归一化(展开 `~/`、比对规则),否则提示与真实
        // 结果会漂移:提示说"能新增",点下去却撞 duplicateURL。
        let normalizedGitURL = RepositoryStore.expandingHomeDirectory(trimmed)
        if let existing = repositories.first(where: {
            RepositoryStore.gitURLsMatch($0.gitURL, normalizedGitURL)
        }) {
            style = .duplicate
            text = "该地址已存在：\(existing.repoName)"
            duplicateRepositoryID = existing.id
            return
        }

        style = .neutral
        duplicateRepositoryID = nil
        text = Self.previewText(for: trimmed)
    }

    /// 「将创建 名称 · 来源」。本地路径没有 Web 主页,来源写「本地目录」;
    /// 名称解析不出来时这一行留空(地址已判过形态,这只是兜底,不编造文案)。
    private static func previewText(for gitURL: String) -> String {
        guard let repositoryName = try? GitURLParser.repositoryName(from: gitURL) else {
            return ""
        }
        let source = (try? GitURLParser.repositoryWebURL(from: gitURL))?.host ?? "本地目录"
        return "将创建 \(repositoryName) · \(source)"
    }
}

/// 设置页 MR 目标分支面板的状态机(纯值,View 用 @State 持有)。
///
/// 面板同一时刻只开一个,而"开着哪一次 / 远端名单 / 加载态 / 探测代际"必须是一个整体:
/// 拆成四处 @State 各写各的,就会串写——换行时把上一家的名单当本家的展示并可点写脏,
/// 旧面板迟到的 `onDisappear` 把新面板在途的探测作废。不变式收进类型,不靠调用方自觉。
struct MRBranchPanelState {
    /// **一次呈现**的身份。(repositoryID, session) 而不是单看 repositoryID:
    /// 同一行"关了又开"(连点两次 MR 按钮)时行 ID 没变,旧面板迟到的 cancel 若只按行
    /// 判定,就会正好命中新面板、把它刚发起的 `ls-remote` 作废——表现成"远端没有分支"。
    struct Session: Equatable {
        let repositoryID: UUID
        let identifier: UUID
    }

    private(set) var openedRepositoryID: UUID?
    private(set) var session: Session?
    /// nil=尚未加载(面板给加载态/重试),空数组=远端确无分支。
    private(set) var remoteBranches: [String]?
    private(set) var isLoadingRemoteBranches = false
    /// 探测代际:每次作废(换行/关闭/重新发起)递增,迟到结果按令牌丢弃。
    private(set) var generation = 0

    func isOpen(for repositoryID: UUID) -> Bool { openedRepositoryID == repositoryID }

    /// 面板内容在**构建时刻**取一次快照并随闭包带走:关闭动画尾窗里的旧内容仍持旧快照,
    /// 它的迟到回调因此作废不了新面板。取不到(未打开)返回 nil,调用方按"无归属"处理。
    func sessionToken(for repositoryID: UUID) -> Session? {
        guard openedRepositoryID == repositoryID, let session else { return nil }
        return session
    }

    /// 打开某行的面板;换行即清空上一行的名单并作废其在途探测。
    mutating func open(repositoryID: UUID) {
        guard openedRepositoryID != repositoryID else { return }
        invalidate()
        openedRepositoryID = repositoryID
        session = Session(repositoryID: repositoryID, identifier: UUID())
    }

    /// 关闭:只关当前开着的那一行。
    mutating func close(repositoryID: UUID) {
        guard openedRepositoryID == repositoryID else { return }
        invalidate()
        openedRepositoryID = nil
        session = nil
    }

    /// 面板内容消失时作废在途探测。
    mutating func cancelLoad(_ session: Session?) {
        guard let session, self.session == session else { return }
        generation += 1
        isLoadingRemoteBranches = false
    }

    /// 发起一次探测并返回代际令牌;非当前呈现的请求返回 nil。
    mutating func beginLoad(_ session: Session?) -> Int? {
        guard let session, self.session == session else { return nil }
        generation += 1
        isLoadingRemoteBranches = true
        return generation
    }

    /// 回填探测结果。`branches` 为 nil 表示**探测失败**:只收口加载态、保留上一次名单
    /// (stale-while-revalidate)。把抖动打成"远端没有分支"是不可接受的——胶囊只读,
    /// 面板是已配分支的唯一移除入口。
    mutating func finishLoad(_ session: Session?, generation token: Int, branches: [String]?) {
        guard let session, self.session == session, token == generation else { return }
        if let branches { remoteBranches = branches }
        isLoadingRemoteBranches = false
    }

    private mutating func invalidate() {
        generation += 1
        remoteBranches = nil
        isLoadingRemoteBranches = false
    }
}

/// 点选一条分支后的 MR 目标名单(纯逻辑,便于测试)。
enum MRBranchToggle {
    /// 已加过的移除、没加过的追加到末尾。
    /// 追加而非按远端字母序插入:`mrTargetBranches.first` 是工作区行「创建 MR」的
    /// 默认目标,顺序即优先级,点选顺序比字母序更可预期。
    static func nextBranches(current: [String], toggled branch: String) -> [String] {
        guard let index = current.firstIndex(of: branch) else { return current + [branch] }
        var result = current
        result.remove(at: index)
        return result
    }
}

/// 行上 MR 目标分支胶囊要显示哪些分支(纯逻辑,便于测试)。
enum MRBranchChipDisplay {
    /// 去掉默认分支那颗——它已由行上的橙色「默认分支」胶囊表达,再画一遍是重复信息。
    /// 比较按 trim 后的值:脏值(带空格的历史数据)不该让同一分支既显示又被当成默认。
    static func visibleBranches(branches: [String], defaultBranch: String?) -> [String] {
        let normalizedDefault = defaultBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedDefault, normalizedDefault.isEmpty == false else { return branches }
        return branches.filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) != normalizedDefault
        }
    }
}

/// 建档后后台探测默认分支的回写判定(纯逻辑,便于测试)。
enum DefaultBranchWriteDecision {
    /// 返回应当写入的分支名;nil=不写。
    ///
    /// 探测期间可能又改了地址或删了仓库,地址不是当初那个就不写,免得把新远端的
    /// 默认分支落到别的配置上。比较用 Store 的归一口径 `gitURLsMatch`:裸串比较会因
    /// 大小写/尾斜杠/`.git` 差异把"同一个远端"误判成"地址变了",结果静默永不回写。
    /// `recordedDefaultBranch` 非空也不写——这是"补空"不是"纠正",否则在途探测会盖掉
    /// 期间由导入/合并写进来的值。
    static func branchToWrite(
        probeResult: String?,
        recordedGitURL: String?,
        recordedDefaultBranch: String?,
        probedGitURL: String
    ) -> String? {
        guard let recordedGitURL else { return nil }
        guard (recordedDefaultBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else {
            return nil
        }
        guard let branch = probeResult?.trimmingCharacters(in: .whitespacesAndNewlines),
              branch.isEmpty == false else { return nil }
        guard RepositoryStore.gitURLsMatch(recordedGitURL, probedGitURL) else { return nil }
        return branch
    }
}

enum RepositoryBackupExportPresentationState {
    static func defaultFileName(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "ccspace-git-repositories-\(formatter.string(from: now)).json"
    }
}

struct RepositoryDeletePresentationState: Equatable {
    let repositoryID: UUID
    let title: String
    let message: String
    let confirmLabel: String
    let isBlocked: Bool

    init(
        repository: RepositoryConfig,
        workplaces: [Workplace]
    ) {
        repositoryID = repository.id

        let referencingWorkplaceNames = workplaces
            .filter { $0.selectedRepositoryIDs.contains(repository.id) }
            .map(\.name)
            .sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }

        if referencingWorkplaceNames.isEmpty {
            title = "删除 \(repository.repoName)"
            message = "删除后将无法在新工作区中继续选择该仓库，此操作不可撤销。"
            confirmLabel = "确认删除"
            isBlocked = false
        } else {
            title = "无法删除 \(repository.repoName)"
            message = """
            以下工作区仍在使用该仓库，请先编辑工作区移除后再删除。
            工作区：\(referencingWorkplaceNames.joined(separator: "、"))
            """
            confirmLabel = ""
            isBlocked = true
        }
    }
}

enum RepositoryConfigFeedbackFactory {
    static func addSuccess(repositoryName: String) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已新增 \(repositoryName)")
    }

    static func deleteSuccess(repositoryName: String) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已删除 \(repositoryName)")
    }

    static func exportSuccess(repositoryCount: Int) -> CCSpaceFeedback {
        if repositoryCount == 0 {
            return CCSpaceFeedback(style: .info, message: "已导出空备份文件")
        }
        return CCSpaceFeedbackFactory.actionSuccess("已导出 \(repositoryCount) 个仓库的备份")
    }

    static func importResult(_ result: RepositoryImportResult) -> CCSpaceFeedback {
        var parts: [String] = []
        if result.importedCount > 0 {
            parts.append("导入 \(result.importedCount) 个仓库")
        }
        if result.mergedCount > 0 {
            parts.append("合并 \(result.mergedCount) 个仓库的 MR 目标分支")
        }
        if result.skippedCount > 0 {
            parts.append("跳过 \(result.skippedCount) 个重复项")
        }

        if parts.isEmpty {
            return CCSpaceFeedback(style: .info, message: "未导入任何仓库")
        }

        let message = "已" + parts.joined(separator: "，")
        let style: CCSpaceFeedbackStyle = (result.importedCount > 0 || result.mergedCount > 0) ? .success : .info
        return CCSpaceFeedback(style: style, message: message)
    }
}

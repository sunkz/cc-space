import XCTest
@testable import CCSpace

/// 第四轮代码评审:Git 服务层健壮性回归。
/// 覆盖三块纯解析逻辑:
/// - GitDiffParser rename 两侧的 C 引用是各自独立的(`plain => "quo\tpath"` 形态),
///   切分后必须对各侧独立解码;
/// - C 转义八进制解码的边界:不足 3 位时的终止字符不得被吞掉,
///   且数字判定为 ASCII-only(GitDiffParser.decodeCEscapes 与
///   GitBranchStatusSnapshot.decodePorcelainPath 同一口径);
/// - GitURLParser 不再把第三方商业域名 gitlab.net 当作 GitLab 实例后缀匹配。
final class GitLayerRobustnessTests: XCTestCase {

    // MARK: - rename 两侧的独立 C 引用(评审项 3)

    func test_renameWithQuotedEscapedNewSideDecodesAndMatchesPatch() {
        // 实测 `git mv "plain name.txt" $'quo\tted new.txt'` 后的
        // `git diff --find-renames --numstat -p`:numstat 行是
        // `plain name.txt => "quo\tted new.txt"`——仅新侧带引号。
        // 修复前 filePath 保留字面引号与 `\t` 转义、patch 匹配失败、
        // changeType 退化为 modified。
        let output = """
        1\t1\tplain name.txt => "quo\\tted new.txt"

        diff --git a/plain name.txt b/"quo\\tted new.txt"
        similarity index 100%
        rename from plain name.txt
        rename to "quo\\tted new.txt"
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "quo\tted new.txt")
        XCTAssertEqual(entries[0].changeType, .renamed)
        XCTAssertFalse(entries[0].patch.isEmpty)
        XCTAssertTrue(entries[0].patch.contains("rename to"))
    }

    func test_renameWithQuotedOldSideAndBareNewSideStillMatchesPatch() {
        // 反方向:仅旧侧带引号。新侧为普通路径,切分与消歧行为不变。
        let output = """
        1\t1\t"quo\\tted old.txt" => new.txt

        diff --git "a/quo\\tted old.txt" b/new.txt
        similarity index 100%
        rename from "quo\\tted old.txt"
        rename to new.txt
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "new.txt")
        XCTAssertEqual(entries[0].changeType, .renamed)
        XCTAssertFalse(entries[0].patch.isEmpty)
    }

    func test_renameWithOctalEscapedNewSideDecodesWithoutPatch() {
        // 非 ASCII 新路径(core.quotepath 默认开)输出为八进制转义引用;
        // 无 patch 段时路径也必须完整解码。
        let entries = GitDiffParser.parse(
            output: "1\t1\tplain name.txt => \"\\346\\226\\207\\344\\273\\266.txt\"\n"
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "文件.txt")
    }

    func test_plainRenameFormsStillParseUnchanged() {
        // 回归锁:既有三种 rename 形态(花括号压缩/根目录花括号/无公共前缀)
        // 的侧解码为恒等,行为不受本项修复影响。
        let braced = GitDiffParser.parse(output: "1\t1\tsrc/{old.txt => new.txt}\n")
        XCTAssertEqual(braced.first?.filePath, "src/new.txt")
        let rootBraced = GitDiffParser.parse(output: "1\t1\t{old.txt => new.txt}\n")
        XCTAssertEqual(rootBraced.first?.filePath, "new.txt")
        let plain = GitDiffParser.parse(output: "1\t1\told.txt => nested/new.txt\n")
        XCTAssertEqual(plain.first?.filePath, "nested/new.txt")
    }

    // MARK: - 八进制转义解码边界(评审项 4)

    func test_decodePorcelainKeepsCharThatTerminatesShortOctal() {
        // git 恒输出 3 位八进制,以下为畸形输入的防御性正确:
        // 不足 3 位且后继非八进制数字时,终止字符不能被吞掉
        // (迭代器版 `let next = iterator.next()` 会消耗并丢弃它)。
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"a\\1b\""),
            "a\u{01}b"
        )
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"a\\12x\""),
            "a\nx"
        )
    }

    func test_decodePorcelainStandardOctalUnaffected() {
        // 正常路径必须保持不变:完整 3 位八进制、以及"3 位后紧跟数字"
        // (取满 3 位即停,后继数字按字面保留)。
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"\\303\\251.txt\""),
            "é.txt"
        )
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"\\1414\""),
            "a4"
        )
    }

    func test_decodePorcelainNonASCIIDigitIsNotOctalContinuation() {
        // '٢'(阿拉伯-印度数字,Unicode isNumber 为真)不是合法八进制位:
        // 旧版用 isNumber 判定会把它拼进转义尾造成解码坏值;
        // ASCII-only 版在 '1' 处终止解码,终止字符按字面保留。
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"a\\1٢\""),
            "a\u{01}٢"
        )
    }

    func test_decodePorcelainInvalidOctalStartStaysLiteral() {
        // 非法八进制起始:'8'/'9' 落在 ASCII 数字分支(0-9 均入分支),
        // 但 UInt8(digits, radix: 8) 解析失败 → 按现实现整串字面化保留
        // (反斜杠与数字都不丢,GitService 与 GitDiffParser 两版同一口径)。
        // 锁定该行为,防止后续把解析失败改成丢字符/静默截断造成路径坏值。
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"\\8\""),
            "\\8"
        )
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"a\\9x\""),
            "a\\9x"
        )
    }

    func test_parserOctalEscapeKeepsTerminatingChar() {
        // GitDiffParser 版解码与 GitService 版同一口径:终止字符不吞。
        let entries = GitDiffParser.parse(output: "1\t1\t\"a\\1b.txt\"\n")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "a\u{01}b.txt")
    }

    // MARK: - gitlab.net 域名归属(评审项 5)

    func test_gitLabNetNoLongerInstanceSuffixMatched() throws {
        // gitlab.net 是第三方商业域名,matches("gitlab.net") 已移除
        // (疑似 gitlab.io 笔误)。可观察形态不变:裸 gitlab.net 由
        // firstLabel("gitlab") 命中,子域 www.gitlab.net 落入未知 host 的
        // GitLab 格式兜底(P2-30 既定取舍)。本测试锁定该形态,
        // 防止"实例后缀匹配"语义被误恢复或误改。
        let bare = try GitURLParser.mergeRequestURL(
            from: "https://gitlab.net/team/app.git",
            sourceBranch: "feature/demo",
            targetBranch: "main"
        )
        XCTAssertEqual(
            bare.absoluteString,
            "https://gitlab.net/team/app/merge_requests/new?merge_request%5Bsource_branch%5D=feature/demo&merge_request%5Btarget_branch%5D=main"
        )

        let subdomain = try GitURLParser.mergeRequestURL(
            from: "https://www.gitlab.net/team/app.git",
            sourceBranch: "feature/demo",
            targetBranch: "main"
        )
        XCTAssertEqual(
            subdomain.absoluteString,
            "https://www.gitlab.net/team/app/merge_requests/new?merge_request%5Bsource_branch%5D=feature/demo&merge_request%5Btarget_branch%5D=main"
        )
    }

    func test_selfHostedGitLabFirstLabelStillMatched() throws {
        // 自建实例形态(gitlab.<任意域>)不受影响。
        let url = try GitURLParser.mergeRequestURL(
            from: "https://gitlab.acme.com/team/app.git",
            sourceBranch: "feature/demo",
            targetBranch: "main"
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://gitlab.acme.com/team/app/merge_requests/new?merge_request%5Bsource_branch%5D=feature/demo&merge_request%5Btarget_branch%5D=main"
        )
    }

    // MARK: - 第六轮评审回归(删除分支守卫 / 空 host 拒绝)

    // MARK: - 第七轮评审回归(diffCommit 守卫 / ASCII 十六进制口径)

    func test_diffCommitRejectsOptionLikeHashBeforeSpawningGit() async throws {
        // hash 进 revs 位置且后无 `--`:以 `-` 开头会被 git 当选项(如 --output= 写文件)。
        // 守卫口径必须与 commitDetail/blobContent 一致,在派发进程前拒掉。
        let service = GitService()
        let entries = try await service.diffCommit(hash: "--output=/tmp/pwned", in: "/nonexistent-dir")
        XCTAssertEqual(entries, [])
    }

    func test_isHexObjectIDRejectsNonASCIIHexDigitsAndOutOfRange() {
        XCTAssertTrue(GitService.isHexObjectID("abc1234"))
        XCTAssertTrue(GitService.isHexObjectID(String(repeating: "a", count: 40)))
        // `Character.isHexDigit` 按 Unicode 取值会放行阿拉伯-印度数字,必须拒掉。
        XCTAssertFalse(GitService.isHexObjectID("٦٦٦٦٦٦٦"))
        XCTAssertFalse(GitService.isHexObjectID("abc"))
        XCTAssertFalse(GitService.isHexObjectID(String(repeating: "a", count: 41)))
        XCTAssertTrue(GitService.isHexObjectID(String(repeating: "a", count: 64), maxLength: 64))
    }

    func test_deleteLocalBranchRejectsUnsafeRefBeforeSpawningGit() async throws {
        // 坏 ref 名(含空格)应在进程派发前被守卫拦下,得到统一的中文提示,
        // 而不是 git 底层英文错误——与建分支/切分支口径对齐的回归锁。
        let service = GitService()
        do {
            try await service.deleteLocalBranch("bad name", in: "/nonexistent-dir")
            XCTFail("非法分支名应被守卫拒绝")
        } catch {
            XCTAssertEqual(error.localizedDescription, "分支名不合法：bad name")
        }
    }

    func test_fileURLWithEmptyHostRejectedForRepositoryWebURL() {
        // file:///path 的 URLComponents.host 为空串:放行会产出畸形 Web 链接,
        // 必须与裸本地路径同口径报"无法解析仓库地址"。
        XCTAssertThrowsError(try GitURLParser.repositoryWebURL(from: "file:///tmp/local-repo.git")) { error in
            XCTAssertEqual(error.localizedDescription, "无法解析仓库地址")
        }
    }
}

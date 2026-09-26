import XCTest
@testable import CCSpace

final class GitDiffParserTests: XCTestCase {
    func test_parsesMultipleFilesWithNumstatGroupedFirst() {
        // git diff 的真实输出:numstat 全部在前,patch 全部在后。
        let output = """
        2\t1\tsrc/main.swift
        1\t0\tlib/util.swift

        diff --git a/src/main.swift b/src/main.swift
        index 1111111..2222222 100644
        --- a/src/main.swift
        +++ b/src/main.swift
        @@ -1,3 +1,3 @@
         line1
        -old line
        +new line
        +added line
        diff --git a/lib/util.swift b/lib/util.swift
        index 3333333..4444444 100644
        --- a/lib/util.swift
        +++ b/lib/util.swift
        @@ -1 +1,2 @@
         keep
        +util line
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 2)
        // 第一个文件:增 2 删 1,patch 正确归属。
        XCTAssertEqual(entries[0].filePath, "src/main.swift")
        XCTAssertEqual(entries[0].insertions, 2)
        XCTAssertEqual(entries[0].deletions, 1)
        XCTAssertTrue(entries[0].patch.contains("diff --git a/src/main.swift"))
        XCTAssertTrue(entries[0].patch.contains("+new line"))
        XCTAssertFalse(entries[0].patch.contains("util line"))

        // 第二个文件:增 1 删 0,patch 正确归属(不含第一个文件的改动)。
        XCTAssertEqual(entries[1].filePath, "lib/util.swift")
        XCTAssertEqual(entries[1].insertions, 1)
        XCTAssertEqual(entries[1].deletions, 0)
        XCTAssertTrue(entries[1].patch.contains("diff --git a/lib/util.swift"))
        XCTAssertTrue(entries[1].patch.contains("+util line"))
        XCTAssertFalse(entries[1].patch.contains("new line"))
    }

    func test_parsesSingleModifiedFile() {
        let output = """
        2\t1\tsrc/main.swift

        diff --git a/src/main.swift b/src/main.swift
        index 1111111..2222222 100644
        --- a/src/main.swift
        +++ b/src/main.swift
        @@ -1,3 +1,3 @@
         line1
        -old line
        +new line
        +added line
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.filePath, "src/main.swift")
        XCTAssertEqual(entry.insertions, 2)
        XCTAssertEqual(entry.deletions, 1)
        XCTAssertFalse(entry.isBinary)
        XCTAssertTrue(entry.patch.contains("diff --git"))
        XCTAssertTrue(entry.patch.contains("+new line"))
        XCTAssertEqual(entry.changeType, .modified)
    }

    func test_parsesAddedAndDeletedFiles() {
        let output = """
        1\t0\tnew.txt
        0\t1\tgone.txt

        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +content
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 1111111..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -content
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].filePath, "new.txt")
        XCTAssertEqual(entries[0].changeType, .added)
        XCTAssertTrue(entries[0].patch.contains("+content"))
        XCTAssertEqual(entries[1].filePath, "gone.txt")
        XCTAssertEqual(entries[1].changeType, .deleted)
        XCTAssertTrue(entries[1].patch.contains("-content"))
    }

    func test_handlesBinaryFile() {
        let output = """
        -\t-\timage.png

        diff --git a/image.png b/image.png
        Binary files differ
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.filePath, "image.png")
        XCTAssertTrue(entry.isBinary)
        XCTAssertEqual(entry.insertions, -1)
        XCTAssertEqual(entry.deletions, -1)
    }

    func test_emptyOutputReturnsEmptyArray() {
        XCTAssertTrue(GitDiffParser.parse(output: "").isEmpty)
        XCTAssertTrue(GitDiffParser.parse(output: "\n\n").isEmpty)
    }

    func test_doesNotMisinterpretDiffHeaderAsNumstat() {
        // 只有 `diff --git` 行(无实际 patch 内容)时,不应崩错;
        // parsePatchOnly 会识别它但因为没有实质改动行,patch 为该 header 本身。
        let output = """
        diff --git a/src/a b/src/a
        """
        let entries = GitDiffParser.parse(output: output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "src/a")
        XCTAssertEqual(entries[0].insertions, 0)
        XCTAssertEqual(entries[0].deletions, 0)
    }

    func test_patchOnlyFallbackWithoutNumstat() {
        // 无 --numstat 时,仅有 patch:按 diff --git 分段并从行内容统计增删。
        let output = """
        diff --git a/a.txt b/a.txt
        index 1..2 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1,2 @@
         keep
        +added
        """
        let entries = GitDiffParser.parse(output: output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "a.txt")
        XCTAssertEqual(entries[0].insertions, 1)
        XCTAssertEqual(entries[0].deletions, 0)
    }

    func test_renameWithCommonDirectoryPrefixKeepsPrefixAndPatch() {
        // git 对同目录重命名输出压缩形式 `src/{old => new}`,
        // 公共前缀必须保留,否则与 patch header 的完整路径对不上。
        let output = """
        2\t1\tsrc/{old.txt => new.txt}

        diff --git a/src/old.txt b/src/new.txt
        similarity index 90%
        rename from src/old.txt
        rename to src/new.txt
        index 1111111..2222222 100644
        --- a/src/old.txt
        +++ b/src/new.txt
        @@ -1,3 +1,3 @@
         line1
        -old line
        +new line
        +added
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "src/new.txt")
        XCTAssertEqual(entries[0].changeType, .renamed)
        XCTAssertFalse(entries[0].patch.isEmpty)
        XCTAssertTrue(entries[0].patch.contains("diff --git a/src/old.txt b/src/new.txt"))
        XCTAssertTrue(entries[0].patch.contains("+new line"))
    }

    func test_renameAtRepositoryRootDropsBraces() {
        let output = """
        1\t0\t{old.txt => new.txt}

        diff --git a/old.txt b/new.txt
        similarity index 90%
        rename from old.txt
        rename to new.txt
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "new.txt")
        XCTAssertFalse(entries[0].patch.isEmpty)
    }

    func test_renameWithoutCommonPrefixUsesPlainArrowForm() {
        let output = """
        1\t1\told.txt => nested/new.txt

        diff --git a/old.txt b/nested/new.txt
        similarity index 80%
        rename from old.txt
        rename to nested/new.txt
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "nested/new.txt")
        XCTAssertFalse(entries[0].patch.isEmpty)
    }

    func test_pathContainingSpaceAndBSubdirectorySeparator() {
        // 路径含空格且本身包含 ` b/` 子串(如目录 `dir b`)时,
        // header 必须取最后一个 ` b/` 之后的部分,否则 patch 丢失。
        let output = """
        1\t1\tdir b/edge.rs

        diff --git a/dir b/edge.rs b/dir b/edge.rs
        index 1111111..2222222 100644
        --- a/dir b/edge.rs
        +++ b/dir b/edge.rs
        @@ -1 +1 @@
        -old
        +new
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "dir b/edge.rs")
        XCTAssertFalse(entries[0].patch.isEmpty)
        XCTAssertTrue(entries[0].patch.contains("+new"))
    }

    func test_renameInsideDirectoryWithSpaceKeepsPrefixAndMatchesPatch() {
        // 真实 git 输出:目录 `dir b` 下的重命名,numstat 为压缩形式,
        // header 两侧都含 ` b/` 子串,靠 numstat 路径集合消歧。
        let output = """
        0\t0\tdir b/{edge.rs => renamed.rs}

        diff --git a/dir b/edge.rs b/dir b/renamed.rs
        similarity index 100%
        rename from dir b/edge.rs
        rename to dir b/renamed.rs
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "dir b/renamed.rs")
        XCTAssertEqual(entries[0].changeType, .renamed)
        XCTAssertFalse(entries[0].patch.isEmpty)
    }

    func test_pathWithSimpleSpaceStillMatchesPatch() {
        let output = """
        1\t1\tmy file.txt

        diff --git a/my file.txt b/my file.txt
        index 1111111..2222222 100644
        --- a/my file.txt
        +++ b/my file.txt
        @@ -1 +1 @@
        -old
        +new
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "my file.txt")
        XCTAssertFalse(entries[0].patch.isEmpty)
    }

    /// 文件名本身含 " => " 的普通修改行:git numstat 会输出带引号路径,
    /// 不能按 rename 压缩形式切割,否则路径被腰斩;P2-25 起引号路径会被
    /// C 转义解码(剥离引号),但仍保留完整的 " => " 文件名。
    func test_quotedPathContainingArrowIsNotSplitAsRename() {
        let entries = GitDiffParser.parse(output: "1\t1\t\"weird => name.txt\"\n")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "weird => name.txt")
        XCTAssertEqual(entries[0].insertions, 1)
    }

    /// 含转义序列的引号路径:numstat 与 diff header 均为 C 引用形式,
    /// 必须解码后才能按路径匹配 patch,UI 也不能显示原始转义序列。
    func test_quotedPathWithEscapeIsDecodedAndMatchesPatch() {
        let output = """
        1\t1\t"wei\\trd.txt"

        diff --git "a/wei\\trd.txt" "b/wei\\trd.txt"
        index 1111111..2222222 100644
        --- "a/wei\\trd.txt"
        +++ "b/wei\\trd.txt"
        @@ -1 +1 @@
        -old
        +new
        """
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "wei\trd.txt")
        XCTAssertFalse(entries[0].patch.isEmpty)
        XCTAssertTrue(entries[0].patch.contains("+new"))
    }

    /// 非 ASCII 数字(Unicode isNumber 为真)不是合法计数列:
    /// 误判会让 Int() 失败得到 -1,把普通文本文件错标成二进制。
    func test_nonASCIIDigitLineIsNotParsedAsNumstat() {
        let output = "١٢٣\t٤٥٦\tweird-name.txt\n1\t2\tok.txt\n"
        let entries = GitDiffParser.parse(output: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "ok.txt")
        XCTAssertEqual(entries[0].insertions, 1)
        XCTAssertFalse(entries[0].isBinary)
    }
}

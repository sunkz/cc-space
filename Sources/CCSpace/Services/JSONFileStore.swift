import Foundation
import os

private let jsonFileStoreLog = Logger(
    subsystem: "com.ccspace.app",
    category: "JSONFileStore"
)

struct JSONFileStoreDocument {
    let fileName: String
    let data: Data
}

/// 包装一层"允许失败"的解码:单条记录损坏时该条为 nil,不中断整个数组的解码。
private struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Value.self)
    }
}

struct JSONFileStore: Sendable {
    private static let stagingDirectoryPrefix = ".ccspace-json-write-"
    /// 回滚失败时备份被移出暂存目录后使用的前缀。必须与 `stagingDirectoryPrefix` 不同:
    /// 否则下次启动的 `cleanupStaleStagingDirectories` 会因 mtime 超阈值把装着唯一备份
    /// 的目录直接删掉,"可手工取回"就落空了。
    private static let rollbackBackupDirectoryPrefix = ".ccspace-json-rollback-backup-"

    let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// 清理上次崩溃/强退遗留的暂存目录。
    ///
    /// **必须由 App 启动显式调用一次**,不要放进 init:JSONFileStore 在运行期会被
    /// 反复构造(RootSplitView 每次重建都 new 一个),放进 init 等于每次重建都在
    /// 主线程枚举目录,并可能删掉**正在进行中**的写入暂存目录。
    /// 另外只清理"足够老"的暂存目录,避免误删并发写入。
    static func cleanupStaleStagingDirectories(
        in rootDirectory: URL,
        olderThan interval: TimeInterval = 600
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-interval)
        for url in entries where url.lastPathComponent.hasPrefix(stagingDirectoryPrefix) {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            guard modifiedAt < cutoff else { continue }
            // 崩溃残留的暂存目录里可能装着 backup/(旧版数据副本):
            // 先把备份改名逃到 `.ccspace-json-rollback-backup-` 前缀下(不受本清理管辖),
            // 再删暂存目录——否则会把"被覆写前的唯一副本"连同残留一起销毁。
            let backupDirectory = url.appendingPathComponent("backup", isDirectory: true)
            if let backups = try? fileManager.contentsOfDirectory(
                at: backupDirectory,
                includingPropertiesForKeys: nil
            ), backups.isEmpty == false {
                let recoveryDirectory = rootDirectory.appendingPathComponent(
                    "\(rollbackBackupDirectoryPrefix)\(UUID().uuidString)",
                    isDirectory: true
                )
                try? fileManager.moveItem(at: backupDirectory, to: recoveryDirectory)
            }
            try? fileManager.removeItem(at: url)
        }
    }

    /// 同卷 `rename(2)` 原子覆盖:目标文件在任一时刻都是完整的旧内容或完整的新内容,
    /// **不存在** `removeItem + moveItem` 那种"旧文件已删、新文件未就位"的崩溃窗口。
    /// 不用 `FileManager.moveItem`(目标已存在时报错),也不用 `replaceItemAt`
    /// (backupItemName 传 nil 会把旧文件移进废纸篓,含 API Key 的 settings.json 会滞留系统回收目录)。
    /// 暂存目录就建在 `rootDirectory` 之下,与目标必然同卷,rename 保证原子且即时可见。
    static func atomicReplace(stagedURL: URL, destinationURL: URL) throws {
        let result: Int32 = stagedURL.withUnsafeFileSystemRepresentation { srcPtr in
            destinationURL.withUnsafeFileSystemRepresentation { dstPtr in
                guard let srcPtr, let dstPtr else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return rename(srcPtr, dstPtr)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 把无法解码的数据文件保全为 `xxx.json.corrupt-<时间戳>` 副本,
    /// 避免 Store 用空数据覆写后原内容不可恢复。
    /// 优先改名(move,不留旧文件);失败时退回复制(copy)——即使后续保存覆写原件,副本仍在。
    func preserveCorruptFile(named fileName: String) {
        let sourceURL = rootDirectory.appendingPathComponent(fileName)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // 固定 POSIX locale:用户区域为非公历或区域设置变化时,格式化结果可能含非数字
        // 字符,损坏副本文件名会不稳定甚至无法按时间排序。
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // 时间戳后追加短 UUID:同一秒内两次损坏会产生同名目标,
        // move 与 copy 会双双失败,两份内容都保全不下来。
        let stamp = "\(formatter.string(from: Date()))-\((UUID().uuidString as NSString).substring(to: 8))"
        let destinationURL = rootDirectory.appendingPathComponent("\(fileName).corrupt-\(stamp)")

        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                // 改名失败(如跨卷/权限问题)时退回复制,仍保全一份原始内容。
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
            // 副本内容等同原文件,settings.json 里含 AI API Key,收紧为仅本人可读写。
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
        } catch {
            // 两种保全方式均失败:已无更多手段,原文件保持原样,
            // 下次保存仍可能覆写。此处不能 throw(调用方在启动错误路径上),只能留痕。
            jsonFileStoreLog.error("event=preserve_corrupt_file_failed file=\(fileName, privacy: .public) reason=\(error.localizedDescription)")
        }
        pruneCorruptCopies(named: fileName)
    }

    /// 损坏副本此前会永久累积(且可能含明文 API Key),只保留最近若干份。
    private func pruneCorruptCopies(named fileName: String, keepingMostRecent limit: Int = 5) {
        let fileManager = FileManager.default
        let prefix = "\(fileName).corrupt-"
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let copies = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                return lhsDate > rhsDate
            }
        for stale in copies.dropFirst(limit) {
            try? fileManager.removeItem(at: stale)
        }
    }

    private func makeEncoder() -> JSONEncoder {
        Self.makeEncoder()
    }

    private func makeDecoder() -> JSONDecoder {
        Self.makeDecoder()
    }

    func save<T: Encodable>(_ value: T, as fileName: String) throws {
        try save([document(for: value, as: fileName)])
    }

    func document<T: Encodable>(for value: T, as fileName: String) throws -> JSONFileStoreDocument {
        JSONFileStoreDocument(
            fileName: fileName,
            data: try makeEncoder().encode(value)
        )
    }

    func save(_ documents: [JSONFileStoreDocument]) throws {
        guard documents.isEmpty == false else { return }

        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stagingDirectory = rootDirectory
            .appendingPathComponent("\(Self.stagingDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        let backupDirectory = stagingDirectory.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        // 回滚是否未能全部完成。为 true 时必须保留暂存目录——里面装着唯一一份备份。
        var rollbackFailed = false
        do {
            for document in documents {
                let stagedURL = stagingDirectory.appendingPathComponent(document.fileName)
                try document.data.write(to: stagedURL, options: .atomic)
                // 数据文件含 AI API Key(settings.json)等敏感配置,收紧为仅当前用户可读写;
                // 后续 rename 是把该 inode 直接换到目标位置,权限随文件带过去。
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: stagedURL.path
                )
            }
            var newlyCreatedURLs: [URL] = []
            do {
                for document in documents {
                    let stagedURL = stagingDirectory.appendingPathComponent(document.fileName)
                    let destinationURL = rootDirectory.appendingPathComponent(document.fileName)
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        let backupURL = backupDirectory.appendingPathComponent(document.fileName)
                        try FileManager.default.copyItem(at: destinationURL, to: backupURL)
                        // 回滚副本已自建(backupURL),替换本身用 rename(2) 原子覆盖:
                        // 不留废纸篓副本,且崩溃时目标文件要么是旧内容要么是新内容,不会消失。
                        try Self.atomicReplace(stagedURL: stagedURL, destinationURL: destinationURL)
                    } else {
                        try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
                        newlyCreatedURLs.append(destinationURL)
                    }
                }
            } catch {
                for url in newlyCreatedURLs.reversed() {
                    try? FileManager.default.removeItem(at: url)
                }
                // 回滚覆盖"凡备份存在者",而非仅成功完成的文档:
                // 多文档事务里任何一个 rename 成功都意味着该文件已是新内容,
                // 但整批必须视为失败,凡有备份者都要换回旧内容。
                // 未轮到的文档没有备份,fileExists 守卫自然跳过。
                for document in documents.reversed() {
                    let backupURL = backupDirectory.appendingPathComponent(document.fileName)
                    let destinationURL = rootDirectory.appendingPathComponent(document.fileName)
                    guard FileManager.default.fileExists(atPath: backupURL.path) else { continue }
                    do {
                        // 同主路径:rename(2) 原子换回旧内容,不经废纸篓,也不留中间窗口。
                        // 不能整体 try?:换回失败必须进 rollbackFailed 分支保住备份。
                        try Self.atomicReplace(stagedURL: backupURL, destinationURL: destinationURL)
                    } catch let rollbackError {
                        jsonFileStoreLog.error("event=rollback_restore_failed file=\(document.fileName, privacy: .public) reason=\(rollbackError.localizedDescription)")
                        rollbackFailed = true
                    }
                }
                throw error
            }
        } catch {
            // 回滚未完成时保留备份,让里面的唯一副本有机会被手工取回。
            if rollbackFailed {
                // 备份必须移出 `.ccspace-json-write-` 前缀:留在暂存目录里,
                // 下次启动的 cleanupStaleStagingDirectories 会因 mtime 超阈值把它
                // 当作崩溃残留直接删掉,"可手工取回"就成了空话。
                var recoveryPath = stagingDirectory.path
                let recoveryDirectory = rootDirectory.appendingPathComponent(
                    "\(Self.rollbackBackupDirectoryPrefix)\(UUID().uuidString)",
                    isDirectory: true
                )
                if (try? FileManager.default.moveItem(
                    at: backupDirectory,
                    to: recoveryDirectory
                )) != nil {
                    recoveryPath = recoveryDirectory.path
                    try? FileManager.default.removeItem(at: stagingDirectory)
                } else if (try? FileManager.default.moveItem(
                    at: stagingDirectory,
                    to: recoveryDirectory
                )) != nil {
                    // 备份单独搬不动(磁盘满/权限与主写失败高度相关,失败概率不低):
                    // 把整个暂存目录改名到保全前缀下,同样能逃离启动清理,
                    // 只是连暂存里的半成品文件一起保留。
                    recoveryPath = recoveryDirectory.path
                } else {
                    jsonFileStoreLog.error(
                        "event=backup_recovery_move_failed reason=both_attempts_failed path=\(stagingDirectory.path, privacy: .private)"
                    )
                }
                jsonFileStoreLog.error("event=save_rollback_incomplete backup_preserved path=\(recoveryPath, privacy: .private)")
                throw error
            }
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }

        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    /// 逐元素容错地加载数组。
    ///
    /// 整文件解码失败时(例如某条记录字段缺失/类型不匹配),丢弃坏记录、保留其余,
    /// 而不是让整个文件被判为损坏清空——后者会级联触发下游启动对账把关联数据也清掉。
    /// - Returns: 保留下来的记录与丢弃条数;文件不存在或 JSON 结构本身不合法时返回 nil。
    func loadArrayToleratingBadElements<Value: Decodable>(
        _ type: Value.Type,
        from fileName: String
    ) -> (values: [Value], droppedCount: Int)? {
        let fileURL = rootDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL),
              let elements = try? makeDecoder().decode([FailableDecodable<Value>].self, from: data) else {
            return nil
        }
        let values = elements.compactMap(\.value)
        return (values, elements.count - values.count)
    }

    func load<T: Decodable>(_ type: T.Type, from fileName: String) throws -> T {
        let fileURL = rootDirectory.appendingPathComponent(fileName)
        let data = try Data(contentsOf: fileURL)
        return try makeDecoder().decode(type, from: data)
    }

    func loadIfPresent<T: Decodable>(_ type: T.Type, from fileName: String, default defaultValue: @autoclosure () -> T) throws -> T {
        let fileURL = rootDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return defaultValue()
        }
        return try load(type, from: fileName)
    }
}

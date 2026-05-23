import Foundation

struct JSONFileStoreDocument {
    let fileName: String
    let data: Data
}

struct JSONFileStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
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

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let stagingDirectory = rootDirectory
            .appendingPathComponent(".ccspace-json-write-\(UUID().uuidString)", isDirectory: true)
        let backupDirectory = stagingDirectory.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        do {
            for document in documents {
                let stagedURL = stagingDirectory.appendingPathComponent(document.fileName)
                try document.data.write(to: stagedURL, options: .atomic)
            }

            var movedDocuments: [JSONFileStoreDocument] = []
            do {
                for document in documents {
                    let stagedURL = stagingDirectory.appendingPathComponent(document.fileName)
                    let destinationURL = rootDirectory.appendingPathComponent(document.fileName)
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        let backupURL = backupDirectory.appendingPathComponent(document.fileName)
                        try FileManager.default.copyItem(at: destinationURL, to: backupURL)
                        _ = try FileManager.default.replaceItemAt(
                            destinationURL,
                            withItemAt: stagedURL,
                            backupItemName: nil,
                            options: []
                        )
                    } else {
                        try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
                    }
                    movedDocuments.append(document)
                }
            } catch {
                for moved in movedDocuments.reversed() {
                    let backupURL = backupDirectory.appendingPathComponent(moved.fileName)
                    let destinationURL = rootDirectory.appendingPathComponent(moved.fileName)
                    if FileManager.default.fileExists(atPath: backupURL.path) {
                        _ = try? FileManager.default.replaceItemAt(
                            destinationURL,
                            withItemAt: backupURL,
                            backupItemName: nil,
                            options: []
                        )
                    }
                }
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }

        try? FileManager.default.removeItem(at: stagingDirectory)
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

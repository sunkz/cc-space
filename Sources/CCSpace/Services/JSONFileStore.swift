import Foundation

struct JSONFileStoreDocument {
    let fileName: String
    let data: Data
}

struct JSONFileStore: @unchecked Sendable {
    let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func save<T: Encodable>(_ value: T, as fileName: String) throws {
        try save([document(for: value, as: fileName)])
    }

    func document<T: Encodable>(for value: T, as fileName: String) throws -> JSONFileStoreDocument {
        JSONFileStoreDocument(
            fileName: fileName,
            data: try encoder.encode(value)
        )
    }

    func save(_ documents: [JSONFileStoreDocument]) throws {
        guard documents.isEmpty == false else { return }

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let stagingDirectory = rootDirectory
            .appendingPathComponent(".ccspace-json-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        do {
            for document in documents {
                let stagedURL = stagingDirectory.appendingPathComponent(document.fileName)
                try document.data.write(to: stagedURL, options: .atomic)
            }

            for document in documents {
                let stagedURL = stagingDirectory.appendingPathComponent(document.fileName)
                let destinationURL = rootDirectory.appendingPathComponent(document.fileName)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    _ = try FileManager.default.replaceItemAt(
                        destinationURL,
                        withItemAt: stagedURL,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
                }
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
        return try decoder.decode(type, from: data)
    }

    func loadIfPresent<T: Decodable>(_ type: T.Type, from fileName: String, default defaultValue: @autoclosure () -> T) throws -> T {
        let fileURL = rootDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return defaultValue()
        }
        return try load(type, from: fileName)
    }
}

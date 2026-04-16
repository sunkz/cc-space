import Foundation

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
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let fileURL = rootDirectory.appendingPathComponent(fileName)
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
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

import XCTest
@testable import CCSpace

@MainActor
func makeServiceStores() throws -> (
    repositoryStore: RepositoryStore,
    workplaceStore: WorkplaceStore,
    workspaceRoot: URL
) {
    let appSupportRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: workspaceRoot,
        withIntermediateDirectories: true,
        attributes: nil
    )

    let fileStore = JSONFileStore(rootDirectory: appSupportRoot)
    return (
        repositoryStore: RepositoryStore(fileStore: fileStore),
        workplaceStore: WorkplaceStore(fileStore: fileStore),
        workspaceRoot: workspaceRoot
    )
}

@MainActor
func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        XCTAssertTrue(true, file: file, line: line)
    }
}

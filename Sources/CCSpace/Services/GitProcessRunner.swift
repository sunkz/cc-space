import Foundation
import ObjCExceptionCatch

struct GitProcessResult {
    let terminationStatus: Int32
    let stdoutData: Data
    let stderrData: Data
}

enum GitProcessExecutionError: LocalizedError, Equatable {
    case timedOut(command: String, timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let command, let timeout):
            return "git 命令超时（\(Int(timeout))s）：\(command)"
        }
    }
}

struct GitProcessRunner {
    private static let gitURL: URL? = {
        let candidates = ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }()

    func run(
        arguments: [String],
        captureStdout: Bool,
        captureStderr: Bool,
        timeout: TimeInterval = 60
    ) async throws -> GitProcessResult {
        guard let gitURL = Self.gitURL else {
            throw NSError(
                domain: "GitProcessRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "找不到 git 可执行文件"]
            )
        }

        let process = Process()
        process.executableURL = gitURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        process.environment = environment

        let stdoutPipe = captureStdout ? Pipe() : nil
        let stderrPipe = captureStderr ? Pipe() : nil
        process.standardOutput = stdoutPipe ?? FileHandle.nullDevice
        process.standardError = stderrPipe ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let processBox = SendableProcessBox(process)
        let continuationClaim = ContinuationClaimBox()
        let commandDescription = Self.safeCommandDescription(arguments: arguments)

        let continuationBox = SendableContinuationBox<GitProcessResult>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuationBox.store(continuation)

                let stdoutBox = SendableDataBox()
                let stderrBox = SendableDataBox()
                let readGroup = DispatchGroup()

                if let pipe = stdoutPipe {
                    readGroup.enter()
                    DispatchQueue.global().async {
                        stdoutBox.data = pipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                }

                if let pipe = stderrPipe {
                    readGroup.enter()
                    DispatchQueue.global().async {
                        stderrBox.data = pipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                }

                nonisolated(unsafe) let timeoutWork = DispatchWorkItem { [processBox, continuationClaim] in
                    guard processBox.process.isRunning else { return }
                    guard continuationClaim.claim() else { return }
                    processBox.process.terminate()
                    readGroup.notify(queue: .global()) {
                        continuationBox.resume(
                            throwing: GitProcessExecutionError.timedOut(
                                command: commandDescription,
                                timeout: timeout
                            )
                        )
                    }
                }

                process.terminationHandler = { completedProcess in
                    timeoutWork.cancel()
                    guard continuationClaim.claim() else { return }
                    readGroup.notify(queue: .global()) {
                        continuationBox.resume(
                            returning: GitProcessResult(
                                terminationStatus: completedProcess.terminationStatus,
                                stdoutData: stdoutBox.data,
                                stderrData: stderrBox.data
                            )
                        )
                    }
                }

                do {
                    var launchException: NSException?
                    var swiftError: (any Error)?
                    let launched = ObjCExceptionCatchTryRun({
                        do {
                            try process.run()
                        } catch {
                            swiftError = error
                        }
                    }, &launchException)
                    if let swiftError {
                        throw swiftError
                    }
                    if !launched || !process.isRunning {
                        let message = launchException?.reason ?? "进程启动失败"
                        throw NSError(
                            domain: "GitProcessRunner",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                    }
                } catch {
                    process.terminationHandler = nil
                    timeoutWork.cancel()
                    guard continuationClaim.claim() else { return }
                    stdoutPipe?.fileHandleForReading.closeFile()
                    stderrPipe?.fileHandleForReading.closeFile()
                    continuationBox.resume(throwing: error)
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        } onCancel: {
            if processBox.process.isRunning {
                processBox.process.terminate()
            }
            stdoutPipe?.fileHandleForReading.closeFile()
            stderrPipe?.fileHandleForReading.closeFile()
            if continuationClaim.claim() {
                continuationBox.resume(throwing: CancellationError())
            }
        }
    }

    private static func safeCommandDescription(arguments: [String]) -> String {
        (["git"] + arguments)
            .map(redactedArgument)
            .joined(separator: " ")
    }

    private static func redactedArgument(_ argument: String) -> String {
        guard var components = URLComponents(string: argument),
              components.user != nil || components.password != nil else {
            return argument
        }

        components.user = "redacted"
        components.password = nil
        return components.string ?? "<redacted-url>"
    }
}

private final class SendableProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class SendableDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return _data }
        set { lock.lock(); defer { lock.unlock() }; _data = newValue }
    }
}

private final class ContinuationClaimBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private final class SendableContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    func store(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

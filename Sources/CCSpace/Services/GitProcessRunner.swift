import Foundation

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
    func run(
        arguments: [String],
        captureStdout: Bool,
        captureStderr: Bool,
        timeout: TimeInterval = 60
    ) async throws -> GitProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

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
        let didTimeout = SendableBoolBox()
        let commandDescription = Self.safeCommandDescription(arguments: arguments)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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

                nonisolated(unsafe) let timeoutWork = DispatchWorkItem { [processBox, didTimeout] in
                    guard processBox.process.isRunning else { return }
                    didTimeout.value = true
                    processBox.process.terminate()
                }

                process.terminationHandler = { completedProcess in
                    timeoutWork.cancel()
                    readGroup.notify(queue: .global()) {
                        if didTimeout.value {
                            continuation.resume(
                                throwing: GitProcessExecutionError.timedOut(
                                    command: commandDescription,
                                    timeout: timeout
                                )
                            )
                            return
                        }

                        continuation.resume(
                            returning: GitProcessResult(
                                terminationStatus: completedProcess.terminationStatus,
                                stdoutData: stdoutBox.data,
                                stderrData: stderrBox.data
                            )
                        )
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    timeoutWork.cancel()
                    stdoutPipe?.fileHandleForReading.closeFile()
                    stderrPipe?.fileHandleForReading.closeFile()
                    continuation.resume(throwing: error)
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

private final class SendableBoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

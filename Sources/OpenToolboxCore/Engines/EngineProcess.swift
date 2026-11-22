import Darwin
import Foundation

public struct EngineProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    public var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

public enum EngineProcessError: Error, Equatable, LocalizedError {
    case failed(command: String, exitCode: Int32, detail: String)
    case launchFailed(command: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .failed(let command, let exitCode, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            return coreLocalized("\(command) exited with status \(exitCode).")
        case .launchFailed(let command, let reason):
            return coreLocalized("Could not start \(command): \(reason)")
        }
    }
}

/// Runs external engine subprocesses with concurrent pipe draining, line streaming,
/// output capping, and cancellation termination.
public enum EngineProcess {
    public static let defaultMaxOutputBytes = 16 * 1_024 * 1_024

    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        maxOutputBytes: Int = defaultMaxOutputBytes,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> EngineProcessResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let box = ProcessBox(process: process)
        let (statuses, statusContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { child in
            box.markTerminated()
            statusContinuation.yield(child.terminationStatus)
            statusContinuation.finish()
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try process.run()
            } catch {
                box.markTerminated()
                statusContinuation.finish()
                throw EngineProcessError.launchFailed(
                    command: executable.lastPathComponent,
                    reason: error.localizedDescription
                )
            }
            box.markStarted()

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading
            async let stdoutData = readStream(stdoutHandle, maxBytes: maxOutputBytes, onLine: onStdoutLine)
            async let stderrData = readStream(stderrHandle, maxBytes: maxOutputBytes, onLine: onStderrLine)

            var iterator = statuses.makeAsyncIterator()
            let exitCode = await iterator.next() ?? -1
            let (out, err) = await (stdoutData, stderrData)
            try Task.checkCancellation()
            return EngineProcessResult(exitCode: exitCode, stdout: out, stderr: err)
        } onCancel: {
            box.cancel()
        }
    }

    private static func readStream(
        _ handle: FileHandle,
        maxBytes: Int,
        onLine: (@Sendable (String) -> Void)?
    ) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var collected = Data()
                var lineBuffer = Data()
                while true {
                    let chunk = (try? handle.read(upToCount: 32 * 1_024)) ?? Data()
                    if chunk.isEmpty { break }
                    if collected.count < maxBytes {
                        let remaining = maxBytes - collected.count
                        collected.append(chunk.prefix(remaining))
                    }
                    if let onLine {
                        for byte in chunk {
                            if byte == 0x0a || byte == 0x0d {
                                if !lineBuffer.isEmpty {
                                    onLine(String(decoding: lineBuffer, as: UTF8.self))
                                    lineBuffer.removeAll(keepingCapacity: true)
                                }
                            } else if lineBuffer.count < 16 * 1_024 {
                                lineBuffer.append(byte)
                            }
                        }
                    }
                }
                if let onLine, !lineBuffer.isEmpty {
                    onLine(String(decoding: lineBuffer, as: UTF8.self))
                }
                try? handle.close()
                continuation.resume(returning: collected)
            }
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var started = false
        private var terminated = false
        private var cancelled = false

        init(process: Process) {
            self.process = process
        }

        func markStarted() {
            let shouldKill: Bool = lock.withLock {
                started = true
                return cancelled && !terminated
            }
            if shouldKill { terminateNow() }
        }

        func markTerminated() {
            lock.withLock { terminated = true }
        }

        func cancel() {
            let shouldKill: Bool = lock.withLock {
                cancelled = true
                return started && !terminated
            }
            if shouldKill { terminateNow() }
        }

        private func terminateNow() {
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2)) { [self] in
                let stillRunning: Bool = lock.withLock { !terminated }
                if stillRunning, pid > 0 {
                    _ = kill(pid, SIGKILL)
                }
            }
        }
    }
}

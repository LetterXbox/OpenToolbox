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

/// Runs external engine subprocesses in their own process group with concurrent pipe
/// draining, optional stdin delivery, line streaming, output capping, and process-group
/// termination on cancellation.
public enum EngineProcess {
    public static let defaultMaxOutputBytes = 16 * 1_024 * 1_024

    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        standardInput: Data? = nil,
        maxOutputBytes: Int = defaultMaxOutputBytes,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> EngineProcessResult {
        try Task.checkCancellation()

        var stdoutFDs: [Int32] = [-1, -1]
        var stderrFDs: [Int32] = [-1, -1]
        var stdinFDs: [Int32] = [-1, -1]
        guard pipe(&stdoutFDs) == 0 else {
            throw EngineProcessError.launchFailed(
                command: executable.lastPathComponent,
                reason: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
            )
        }
        guard pipe(&stderrFDs) == 0 else {
            close(stdoutFDs[0])
            close(stdoutFDs[1])
            throw EngineProcessError.launchFailed(
                command: executable.lastPathComponent,
                reason: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
            )
        }
        var stdinNullFD: Int32 = -1
        if standardInput != nil {
            guard pipe(&stdinFDs) == 0 else {
                close(stdoutFDs[0]); close(stdoutFDs[1])
                close(stderrFDs[0]); close(stderrFDs[1])
                throw EngineProcessError.launchFailed(
                    command: executable.lastPathComponent,
                    reason: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
                )
            }
        } else {
            stdinNullFD = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard stdinNullFD >= 0 else {
                close(stdoutFDs[0]); close(stdoutFDs[1])
                close(stderrFDs[0]); close(stderrFDs[1])
                throw EngineProcessError.launchFailed(
                    command: executable.lastPathComponent,
                    reason: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
                )
            }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        if standardInput != nil {
            posix_spawn_file_actions_adddup2(&actions, stdinFDs[0], STDIN_FILENO)
            posix_spawn_file_actions_addclose(&actions, stdinFDs[0])
            posix_spawn_file_actions_addclose(&actions, stdinFDs[1])
        } else {
            posix_spawn_file_actions_adddup2(&actions, stdinNullFD, STDIN_FILENO)
            posix_spawn_file_actions_addclose(&actions, stdinNullFD)
        }
        posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdoutFDs[0])
        posix_spawn_file_actions_addclose(&actions, stdoutFDs[1])
        posix_spawn_file_actions_adddup2(&actions, stderrFDs[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stderrFDs[0])
        posix_spawn_file_actions_addclose(&actions, stderrFDs[1])
        if let currentDirectory {
            _ = currentDirectory.path.withCString { pathPtr in
                posix_spawn_file_actions_addchdir_np(&actions, pathPtr)
            }
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags: Int16 = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)

        let argvStrings = [executable.path] + arguments
        let envDict = environment ?? ProcessInfo.processInfo.environment
        let envStrings = envDict.map { "\($0.key)=\($0.value)" }

        var argvPointers: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        argvPointers.append(nil)
        defer { for ptr in argvPointers { free(ptr) } }

        var envPointers: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        envPointers.append(nil)
        defer { for ptr in envPointers { free(ptr) } }

        var childPID: pid_t = 0
        let spawnStatus: Int32 = executable.path.withCString { exePath in
            argvPointers.withUnsafeMutableBufferPointer { argvBuf in
                envPointers.withUnsafeMutableBufferPointer { envBuf in
                    posix_spawn(&childPID, exePath, &actions, &attr, argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
        }

        close(stdoutFDs[1])
        close(stderrFDs[1])
        if standardInput != nil {
            close(stdinFDs[0])
        } else {
            close(stdinNullFD)
        }

        guard spawnStatus == 0 else {
            close(stdoutFDs[0])
            close(stderrFDs[0])
            if standardInput != nil { close(stdinFDs[1]) }
            let posix = POSIXError(POSIXErrorCode(rawValue: spawnStatus) ?? .EIO)
            throw EngineProcessError.launchFailed(
                command: executable.lastPathComponent,
                reason: posix.localizedDescription
            )
        }

        let box = ProcessGroupBox(pid: childPID)
        let stdoutHandle = FileHandle(fileDescriptor: stdoutFDs[0], closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: stderrFDs[0], closeOnDealloc: true)
        let stdinWriteFD = stdinFDs[1]

        return try await withTaskCancellationHandler {
            if let standardInput {
                writeAllAsync(standardInput, to: stdinWriteFD)
            }
            async let stdoutData = readStream(stdoutHandle, maxBytes: maxOutputBytes, onLine: onStdoutLine)
            async let stderrData = readStream(stderrHandle, maxBytes: maxOutputBytes, onLine: onStderrLine)
            let exitCode = await waitForExit(pid: childPID, box: box)
            let (out, err) = await (stdoutData, stderrData)
            try Task.checkCancellation()
            return EngineProcessResult(exitCode: exitCode, stdout: out, stderr: err)
        } onCancel: {
            box.cancel()
        }
    }

    private static func writeAllAsync(_ data: Data, to fd: Int32) {
        DispatchQueue.global(qos: .utility).async {
            defer { close(fd) }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let count = write(fd, base.advanced(by: written), raw.count - written)
                    if count > 0 {
                        written += count
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }

    private static func waitForExit(pid: pid_t, box: ProcessGroupBox) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while true {
                    let result = waitpid(pid, &status, 0)
                    if result == pid { break }
                    if result < 0 && errno == EINTR { continue }
                    box.markExited()
                    continuation.resume(returning: -1)
                    return
                }
                box.markExited()
                if (status & 0x7f) == 0 {
                    continuation.resume(returning: (status >> 8) & 0xff)
                } else {
                    continuation.resume(returning: -(status & 0x7f))
                }
            }
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

    private final class ProcessGroupBox: @unchecked Sendable {
        private let lock = NSLock()
        private let pid: pid_t
        private var exited = false

        init(pid: pid_t) {
            self.pid = pid
        }

        func markExited() {
            lock.withLock { exited = true }
        }

        func cancel() {
            let shouldKill: Bool = lock.withLock { !exited }
            guard shouldKill, pid > 0 else { return }
            _ = kill(-pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2)) { [self] in
                let stillRunning: Bool = lock.withLock { !exited }
                if stillRunning {
                    _ = kill(-pid, SIGKILL)
                }
            }
        }
    }
}

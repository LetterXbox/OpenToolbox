import Foundation

/// Runs a system command and drains both pipes concurrently so neither can stall the child.
enum MacUtilityCommand {
    @MainActor
    static func run(_ executable: String, arguments: [String]) async throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let (statuses, statusContinuation) = AsyncStream<Int32>.makeStream()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { child in
            statusContinuation.yield(child.terminationStatus)
            statusContinuation.finish()
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            let outputReader = output.fileHandleForReading
            let errorReader = errors.fileHandleForReading
            async let standardOutput = read(outputReader)
            async let standardError = read(errorReader)
            var iterator = statuses.makeAsyncIterator()
            let status = await iterator.next()
            let (data, diagnostics) = try await (standardOutput, standardError)
            try Task.checkCancellation()
            guard status == 0 else {
                let detail = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw CommandError(
                    command: URL(fileURLWithPath: executable).lastPathComponent, status: status, detail: detail
                )
            }
            return data
        } onCancel: {
            Task { @MainActor in
                if process.isRunning { process.terminate() }
            }
        }
    }

    private static func read(_ handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try handle.readToEnd() ?? Data() })
            }
        }
    }

    private struct CommandError: LocalizedError {
        let command: String
        let status: Int32?
        let detail: String

        var errorDescription: String? {
            if !detail.isEmpty { return detail }
            if let status { return coreLocalized("\(command) failed with exit status \(status).") }
            return coreLocalized("\(command) ended before reporting an exit status.")
        }
    }
}

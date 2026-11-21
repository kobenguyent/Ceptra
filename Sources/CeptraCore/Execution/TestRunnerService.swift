import Foundation

public struct RunExecutionResult: Sendable {
    public let exitCode: Int32
    public let wasCancelled: Bool
    public let startedAt: Date
    public let finishedAt: Date
    public let rawOutput: String
    public let parsedScenarios: [ExecutedScenarioRecord]
    public let summaryPassed: Int?
    public let summaryFailed: Int?
    public let summarySkipped: Int?
}

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let parser = LiveOutputParser()
    private var stdoutRemainder = ""
    private var stderrRemainder = ""
    private var collectedLines: [String] = []

    func consume(_ data: Data, isStderr: Bool) -> [LiveOutputEvent] {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return [] }
        return lock.withLock {
            let combined = (isStderr ? stderrRemainder : stdoutRemainder) + chunk
            var lines = combined.components(separatedBy: "\n")
            let remainder = lines.popLast() ?? ""
            if isStderr {
                stderrRemainder = remainder
            } else {
                stdoutRemainder = remainder
            }
            var emitted: [LiveOutputEvent] = []
            for line in lines {
                collectedLines.append(LiveOutputParser.stripANSI(line))
                emitted.append(contentsOf: parser.feed(line: line, isStderr: isStderr))
            }
            if isStderr && remainder.localizedCaseInsensitiveContains("Waiting for the debugger to disconnect") {
                emitted.append(.inspectorWaitingToDisconnect)
            }
            return emitted
        }
    }

    func finalize() -> (
        events: [LiveOutputEvent],
        rawOutput: String,
        scenarios: [ExecutedScenarioRecord],
        passed: Int?,
        failed: Int?,
        skipped: Int?
    ) {
        lock.withLock {
            var finalEvents: [LiveOutputEvent] = []
            if !stdoutRemainder.isEmpty {
                collectedLines.append(LiveOutputParser.stripANSI(stdoutRemainder))
                finalEvents.append(contentsOf: parser.feed(line: stdoutRemainder, isStderr: false))
                stdoutRemainder = ""
            }
            if !stderrRemainder.isEmpty {
                collectedLines.append(LiveOutputParser.stripANSI(stderrRemainder))
                finalEvents.append(contentsOf: parser.feed(line: stderrRemainder, isStderr: true))
                stderrRemainder = ""
            }
            return (
                events: finalEvents,
                rawOutput: collectedLines.joined(separator: "\n"),
                scenarios: parser.scenarios,
                passed: parser.summaryPassed,
                failed: parser.summaryFailed,
                skipped: parser.summarySkipped
            )
        }
    }
}

public final class TestRunnerService: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?
    private var activeStdinPipe: Pipe?
    private var cancelled = false

    public init() {}

    public var isRunning: Bool {
        lock.withLock {
            activeProcess?.isRunning == true
        }
    }

    @discardableResult
    public func sendStdin(_ text: String) -> Bool {
        let pipe: Pipe? = lock.withLock { activeStdinPipe }
        guard let pipe, let data = text.data(using: .utf8) else { return false }
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    public func cancel() {
        let (proc, stdinPipe): (Process?, Pipe?) = lock.withLock {
            cancelled = true
            let p = activeStdinPipe
            activeStdinPipe = nil
            return (activeProcess, p)
        }
        try? stdinPipe?.fileHandleForWriting.close()

        guard let proc, proc.isRunning else { return }
        let pid = proc.processIdentifier
        kill(-pid, SIGTERM)
        proc.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            if proc.isRunning {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }

    private func setActiveProcess(_ process: Process?, stdinPipe: Pipe? = nil) {
        lock.withLock {
            activeProcess = process
            activeStdinPipe = stdinPipe
            if process != nil {
                cancelled = false
            }
        }
    }

    private func clearActiveProcessAndReadCancelled() -> Bool {
        let (wasCancelled, stdinPipe): (Bool, Pipe?) = lock.withLock {
            let c = cancelled
            activeProcess = nil
            let p = activeStdinPipe
            activeStdinPipe = nil
            return (c, p)
        }
        try? stdinPipe?.fileHandleForWriting.close()
        return wasCancelled
    }

    public func execute(
        command: BuiltCommand,
        attachStdin: Bool = false,
        onEvent: @escaping @Sendable (LiveOutputEvent) -> Void
    ) async throws -> RunExecutionResult {
        let startedAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.environment = command.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe: Pipe? = attachStdin ? Pipe() : nil
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        setActiveProcess(process, stdinPipe: stdinPipe)

        let collector = StreamCollector()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for event in collector.consume(data, isStderr: false) {
                onEvent(event)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for event in collector.consume(data, isStderr: true) {
                onEvent(event)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                for event in collector.consume(tailOut, isStderr: false) {
                    onEvent(event)
                }
                for event in collector.consume(tailErr, isStderr: true) {
                    onEvent(event)
                }

                let finalState = collector.finalize()
                for event in finalState.events {
                    onEvent(event)
                }

                let wasCancelled = self?.clearActiveProcessAndReadCancelled() ?? false

                let result = RunExecutionResult(
                    exitCode: proc.terminationStatus,
                    wasCancelled: wasCancelled,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    rawOutput: finalState.rawOutput,
                    parsedScenarios: finalState.scenarios,
                    summaryPassed: finalState.passed,
                    summaryFailed: finalState.failed,
                    summarySkipped: finalState.skipped
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                self.setActiveProcess(nil)
                continuation.resume(throwing: error)
            }
        }
    }
}

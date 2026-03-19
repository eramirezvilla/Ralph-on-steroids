import Foundation

// MARK: - Claude Code CLI Wrapper

/// Invokes the Claude Code CLI (`claude --dangerously-skip-permissions --print`)
/// and streams output line-by-line. Handles rate limit detection and auto-retry.
actor ClaudeCodeService {

    // MARK: - Types

    enum ClaudeError: LocalizedError {
        case claudeNotFound
        case processFailure(exitCode: Int32, stderr: String)
        case rateLimitExhausted(retries: Int)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .claudeNotFound: return "Claude CLI not found. Install it or set the path in Settings."
            case .processFailure(let code, let stderr): return "Claude exited with code \(code): \(stderr)"
            case .rateLimitExhausted(let retries): return "Still rate limited after \(retries) retries"
            case .cancelled: return "Cancelled"
            }
        }
    }

    struct RateLimitInfo {
        let waitSeconds: Int
        let message: String
    }

    // MARK: - Configuration

    private var claudePath: String
    private let maxRateLimitRetries: Int

    init(claudePath: String? = nil, maxRateLimitRetries: Int = 3) {
        self.claudePath = claudePath ?? "/usr/local/bin/claude"
        self.maxRateLimitRetries = maxRateLimitRetries
    }

    // MARK: - Public API

    /// Run a prompt and stream output line-by-line
    func run(prompt: String, workingDirectory: URL) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await executeWithRetry(prompt: prompt, workingDirectory: workingDirectory) { line in
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Run a prompt and collect all output into a single string
    func runAndCollect(prompt: String, workingDirectory: URL) async throws -> String {
        var lines: [String] = []
        for try await line in run(prompt: prompt, workingDirectory: workingDirectory) {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Discover the Claude CLI path
    func discoverClaudePath() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty {
                self.claudePath = path
                return path
            }
        } catch {}
        return nil
    }

    // MARK: - Core Execution

    private func executeWithRetry(
        prompt: String,
        workingDirectory: URL,
        onLine: @escaping (String) -> Void
    ) async throws {
        var attempt = 0

        while attempt <= maxRateLimitRetries {
            var collectedOutput = ""

            do {
                try await execute(prompt: prompt, workingDirectory: workingDirectory) { line in
                    collectedOutput += line + "\n"
                    onLine(line)
                }

                // Success — check if output indicates rate limiting
                if let rateLimitInfo = detectRateLimit(in: collectedOutput) {
                    attempt += 1
                    if attempt > maxRateLimitRetries {
                        throw ClaudeError.rateLimitExhausted(retries: maxRateLimitRetries)
                    }
                    onLine("[RATE LIMITED] Waiting \(rateLimitInfo.waitSeconds)s before retry (\(attempt)/\(maxRateLimitRetries))...")
                    try await Task.sleep(for: .seconds(rateLimitInfo.waitSeconds))
                    continue
                }

                return // Success, no rate limit
            } catch let error as ClaudeError {
                throw error
            } catch {
                // Process-level failure — check stderr for rate limits
                if let rateLimitInfo = detectRateLimit(in: collectedOutput) {
                    attempt += 1
                    if attempt > maxRateLimitRetries {
                        throw ClaudeError.rateLimitExhausted(retries: maxRateLimitRetries)
                    }
                    onLine("[RATE LIMITED] Waiting \(rateLimitInfo.waitSeconds)s before retry (\(attempt)/\(maxRateLimitRetries))...")
                    try await Task.sleep(for: .seconds(rateLimitInfo.waitSeconds))
                    continue
                }
                throw error
            }
        }
    }

    private func execute(
        prompt: String,
        workingDirectory: URL,
        onLine: @escaping (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--dangerously-skip-permissions", "--print"]
        process.currentDirectoryURL = workingDirectory

        // Prevent macOS App Nap from suspending the process
        process.qualityOfService = .userInitiated

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write prompt to stdin and close
        if let data = prompt.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // Stream stdout line-by-line
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var buffer = Data()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    // EOF — flush remaining buffer
                    if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                        onLine(line)
                    }
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    return
                }

                buffer.append(data)

                // Split on newlines
                while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[buffer.startIndex..<newlineIndex]
                    if let line = String(data: lineData, encoding: .utf8) {
                        onLine(line)
                    }
                    buffer = Data(buffer[buffer.index(after: newlineIndex)...])
                }
            }

            process.terminationHandler = { _ in
                // Give the readability handler a moment to flush
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    continuation.resume()
                }
            }
        }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ClaudeError.processFailure(exitCode: process.terminationStatus, stderr: stderrString)
        }
    }

    // MARK: - Rate Limit Detection

    /// Matches ralph.sh rate limit patterns (lines 231, 289-325)
    func detectRateLimit(in output: String) -> RateLimitInfo? {
        let patterns = [
            "hit your limit",
            "rate limit",
            "usage limit",
            "limit resets",
            "too many requests",
            "overloaded",
            "Rate limit reached"
        ]

        let lowered = output.lowercased()
        guard patterns.contains(where: { lowered.contains($0.lowercased()) }) else {
            return nil
        }

        // Try to parse "in N minutes" or "in N seconds"
        if let waitSeconds = parseWaitDuration(from: output) {
            return RateLimitInfo(waitSeconds: min(waitSeconds, 3600), message: "Rate limited, waiting \(waitSeconds)s")
        }

        // Try to parse "resets at 10pm" style
        if let waitSeconds = parseResetTime(from: output) {
            return RateLimitInfo(waitSeconds: waitSeconds, message: "Rate limited, waiting \(waitSeconds)s")
        }

        // Default: 15 minutes (matches ralph.sh line 318)
        return RateLimitInfo(waitSeconds: 900, message: "Rate limited, no reset time found — waiting 15m")
    }

    /// Parses "in N minutes" / "in N seconds" — matches ralph.sh parse_in_minutes_seconds()
    private func parseWaitDuration(from output: String) -> Int? {
        let pattern = #"(?:resets? )?in (\d+) (minute|second)s?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let numberRange = Range(match.range(at: 1), in: output),
              let unitRange = Range(match.range(at: 2), in: output),
              let number = Int(output[numberRange]) else {
            return nil
        }

        let unit = output[unitRange].lowercased()
        var seconds = unit == "minute" ? number * 60 : number
        seconds = min(seconds, 3600) // Cap at 1 hour
        return seconds
    }

    /// Parses "resets at 10pm" / "resets 10:00 PM" — matches ralph.sh calculate_wait_until()
    private func parseResetTime(from output: String) -> Int? {
        let pattern = #"resets? (?:at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let hourRange = Range(match.range(at: 1), in: output),
              let ampmRange = Range(match.range(at: 3), in: output),
              var hour = Int(output[hourRange]) else {
            return nil
        }

        let ampm = output[ampmRange].lowercased()
        if ampm == "pm" && hour != 12 { hour += 12 }
        if ampm == "am" && hour == 12 { hour = 0 }

        // Build target date for today at that hour
        var calendar = Calendar.current
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: .now)
        components.hour = hour
        components.minute = 0
        components.second = 0

        guard var target = calendar.date(from: components) else { return nil }

        // If target is in the past, add a day
        if target <= .now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }

        let wait = Int(target.timeIntervalSinceNow)
        // Clamp: 60s to 8 hours (matches ralph.sh)
        return max(60, min(wait, 28800))
    }
}

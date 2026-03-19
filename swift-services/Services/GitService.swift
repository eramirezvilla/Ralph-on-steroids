import Foundation

// MARK: - Git Service

/// Basic git operations via Process. Used for repo validation, branch management,
/// and gathering diff context for quality gates and de-sloppify passes.
struct GitService {

    enum GitError: LocalizedError {
        case notAGitRepo(URL)
        case commandFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .notAGitRepo(let url): return "\(url.path) is not a git repository"
            case .commandFailed(let cmd, let code): return "git \(cmd) failed with exit code \(code)"
            }
        }
    }

    // MARK: - Validation

    func isGitRepo(at path: URL) -> Bool {
        FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path)
    }

    func validateRepo(at path: URL) throws {
        guard isGitRepo(at: path) else {
            throw GitError.notAGitRepo(path)
        }
    }

    // MARK: - Branch Operations

    func currentBranch(at path: URL) async throws -> String {
        try await run(["branch", "--show-current"], at: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func checkout(branch: String, create: Bool = false, at path: URL) async throws {
        var args = ["checkout"]
        if create { args.append("-b") }
        args.append(branch)
        _ = try await run(args, at: path)
    }

    func branchExists(branch: String, at path: URL) async -> Bool {
        do {
            _ = try await run(["rev-parse", "--verify", branch], at: path)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Status & Diff

    func status(at path: URL) async throws -> String {
        try await run(["status", "--porcelain"], at: path)
    }

    func diffStat(at path: URL) async throws -> String {
        try await run(["diff", "--stat"], at: path)
    }

    /// Get the full diff for de-sloppify context
    func diff(at path: URL) async throws -> String {
        try await run(["diff", "HEAD"], at: path)
    }

    /// Get diff stat between two refs (e.g., for phase changes)
    func diffBetween(from: String, to: String = "HEAD", at path: URL) async throws -> String {
        try await run(["diff", from, to], at: path)
    }

    func log(count: Int = 20, at path: URL) async throws -> String {
        try await run(["log", "--oneline", "-\(count)"], at: path)
    }

    /// Get the commit hash before phase started (for diffing phase changes)
    func headCommit(at path: URL) async throws -> String {
        try await run(["rev-parse", "HEAD"], at: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private func run(_ arguments: [String], at path: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = path

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: stdoutData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: stderrData, encoding: .utf8) ?? ""
            throw GitError.commandFailed(arguments.joined(separator: " "), process.terminationStatus)
        }

        return output
    }
}

import Foundation

// MARK: - Quality Gate Service

/// Runs the ECC 6-phase verification loop after each phase completes.
/// Source: everything-claude-code/skills/verification-loop/SKILL.md
///
/// Phases: Build → TypeCheck → Lint → Tests → Security → Diff
struct QualityGateService {

    // MARK: - Types

    enum CheckStatus: String {
        case pass = "PASS"
        case fail = "FAIL"
        case skipped = "SKIPPED"
    }

    struct CheckResult {
        var status: CheckStatus
        var output: String
        var errorCount: Int

        static let skipped = CheckResult(status: .skipped, output: "", errorCount: 0)
    }

    struct Report {
        var build: CheckResult
        var typeCheck: CheckResult
        var lint: CheckResult
        var tests: CheckResult
        var security: CheckResult
        var diffSummary: String

        var isReady: Bool {
            build.status == .pass && typeCheck.status != .fail && tests.status != .fail
        }

        var summary: String {
            """
            VERIFICATION REPORT
            ==================

            Build:     [\(build.status.rawValue)]
            Types:     [\(typeCheck.status.rawValue)] (\(typeCheck.errorCount) errors)
            Lint:      [\(lint.status.rawValue)] (\(lint.errorCount) warnings)
            Tests:     [\(tests.status.rawValue)]
            Security:  [\(security.status.rawValue)] (\(security.errorCount) issues)
            Diff:      \(diffSummary)

            Overall:   \(isReady ? "READY" : "NOT READY")
            """
        }
    }

    enum ProjectType {
        case node       // package.json
        case python     // pyproject.toml or requirements.txt
        case swift      // Package.swift
        case unknown
    }

    // MARK: - Public API

    /// Run the full 6-phase verification
    func run(repoPath: URL) async throws -> Report {
        let projectType = detectProjectType(at: repoPath)
        let packageManager = detectPackageManager(at: repoPath)

        async let buildResult = runBuild(repoPath: repoPath, projectType: projectType, pm: packageManager)
        async let typeResult = runTypeCheck(repoPath: repoPath, projectType: projectType)

        let build = await buildResult
        let typeCheck = await typeResult

        // Run remaining checks in parallel
        async let lintResult = runLint(repoPath: repoPath, projectType: projectType, pm: packageManager)
        async let testResult = runTests(repoPath: repoPath, projectType: projectType, pm: packageManager)
        async let securityResult = runSecurityScan(repoPath: repoPath)
        async let diffResult = runDiffSummary(repoPath: repoPath)

        return Report(
            build: build,
            typeCheck: typeCheck,
            lint: await lintResult,
            tests: await testResult,
            security: await securityResult,
            diffSummary: await diffResult
        )
    }

    // MARK: - Project Detection

    func detectProjectType(at path: URL) -> ProjectType {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.appendingPathComponent("package.json").path) { return .node }
        if fm.fileExists(atPath: path.appendingPathComponent("pyproject.toml").path) { return .python }
        if fm.fileExists(atPath: path.appendingPathComponent("requirements.txt").path) { return .python }
        if fm.fileExists(atPath: path.appendingPathComponent("Package.swift").path) { return .swift }
        return .unknown
    }

    /// Detect Node package manager (npm, pnpm, yarn, bun)
    func detectPackageManager(at path: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.appendingPathComponent("bun.lockb").path) { return "bun" }
        if fm.fileExists(atPath: path.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm" }
        if fm.fileExists(atPath: path.appendingPathComponent("yarn.lock").path) { return "yarn" }
        return "npm"
    }

    // MARK: - Phase 1: Build

    private func runBuild(repoPath: URL, projectType: ProjectType, pm: String) async -> CheckResult {
        switch projectType {
        case .node:
            return await runShell("\(pm) run build", at: repoPath)
        case .python:
            // Python doesn't have a build step typically; check for setup.py
            return .skipped
        case .swift:
            return await runShell("swift build", at: repoPath)
        case .unknown:
            return .skipped
        }
    }

    // MARK: - Phase 2: Type Check

    private func runTypeCheck(repoPath: URL, projectType: ProjectType) async -> CheckResult {
        switch projectType {
        case .node:
            // Check if tsconfig.json exists
            if FileManager.default.fileExists(atPath: repoPath.appendingPathComponent("tsconfig.json").path) {
                return await runShell("npx tsc --noEmit", at: repoPath)
            }
            return .skipped
        case .python:
            return await runShell("pyright .", at: repoPath)
        case .swift:
            // swift build already does type checking
            return .skipped
        case .unknown:
            return .skipped
        }
    }

    // MARK: - Phase 3: Lint

    private func runLint(repoPath: URL, projectType: ProjectType, pm: String) async -> CheckResult {
        switch projectType {
        case .node:
            return await runShell("\(pm) run lint", at: repoPath)
        case .python:
            return await runShell("ruff check .", at: repoPath)
        case .swift:
            return await runShell("swiftlint", at: repoPath)
        case .unknown:
            return .skipped
        }
    }

    // MARK: - Phase 4: Tests

    private func runTests(repoPath: URL, projectType: ProjectType, pm: String) async -> CheckResult {
        switch projectType {
        case .node:
            return await runShell("\(pm) run test", at: repoPath)
        case .python:
            return await runShell("pytest", at: repoPath)
        case .swift:
            return await runShell("swift test", at: repoPath)
        case .unknown:
            return .skipped
        }
    }

    // MARK: - Phase 5: Security Scan

    private func runSecurityScan(repoPath: URL) async -> CheckResult {
        // Check for hardcoded secrets and console.logs
        var issues = 0
        var output = ""

        // Search for potential secrets
        let secretPatterns = ["sk-", "api_key", "secret_key", "password\\s*=", "ANTHROPIC_API_KEY"]
        for pattern in secretPatterns {
            let result = await runShell("grep -rn '\(pattern)' --include='*.ts' --include='*.js' --include='*.py' --include='*.swift' . 2>/dev/null | grep -v node_modules | grep -v '.git' | head -5", at: repoPath)
            if result.status == .pass && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues += result.output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
                output += "Potential secret (\(pattern)):\n\(result.output)\n"
            }
        }

        // Check for console.log in source files
        let consoleResult = await runShell("grep -rn 'console.log' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' src/ 2>/dev/null | head -10", at: repoPath)
        if !consoleResult.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let count = consoleResult.output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
            issues += count
            output += "Console.log statements: \(count)\n\(consoleResult.output)\n"
        }

        return CheckResult(
            status: issues > 0 ? .fail : .pass,
            output: output.isEmpty ? "No security issues found" : output,
            errorCount: issues
        )
    }

    // MARK: - Phase 6: Diff Summary

    private func runDiffSummary(repoPath: URL) async -> String {
        let result = await runShell("git diff --stat HEAD~1 2>/dev/null || git diff --stat", at: repoPath)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shell Runner

    private func runShell(_ command: String, at path: URL) async -> CheckResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = path

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let combined = stdout + (stderr.isEmpty ? "" : "\n" + stderr)

            let errorLines = combined.components(separatedBy: "\n").filter {
                $0.lowercased().contains("error") || $0.lowercased().contains("warning")
            }

            return CheckResult(
                status: process.terminationStatus == 0 ? .pass : .fail,
                output: String(combined.prefix(2000)), // Cap output
                errorCount: errorLines.count
            )
        } catch {
            return CheckResult(status: .fail, output: "Failed to run: \(command)\n\(error.localizedDescription)", errorCount: 1)
        }
    }
}

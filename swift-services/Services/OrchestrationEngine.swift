import Foundation

// MARK: - Orchestration Engine

/// The ralph.sh main() loop reimplemented as a Swift async state machine.
/// Source: ralph.sh lines 754-837 (main), 524-702 (phases)
///
/// Loop: Feature → PRD → [Planning → Execution → QualityGate → Desloppify → Review → FixPlan]* → Complete
@Observable
class OrchestrationEngine {

    // MARK: - State

    enum State: Equatable {
        case idle
        case creatingPRD
        case planning(phaseIndex: Int)
        case executing(phaseIndex: Int, iteration: Int)
        case qualityCheck(phaseIndex: Int)
        case desloppifying(phaseIndex: Int)
        case reviewing(phaseIndex: Int)
        case fixPlanning(phaseIndex: Int)
        case complete
        case failed(String)
        case rateLimited(resumeDate: Date)
    }

    var state: State = .idle
    var prd: PRD?
    var logEntries: [LogEntry] = []
    var metrics: RunMetrics = .init()

    // MARK: - Dependencies

    private let claude: ClaudeCodeService
    private let templates: PromptTemplateEngine
    private let git: GitService
    private let qualityGate: QualityGateService

    init(
        claude: ClaudeCodeService = ClaudeCodeService(),
        templates: PromptTemplateEngine = PromptTemplateEngine(),
        git: GitService = GitService(),
        qualityGate: QualityGateService = QualityGateService()
    ) {
        self.claude = claude
        self.templates = templates
        self.git = git
        self.qualityGate = qualityGate
    }

    // MARK: - Main Entry Point

    /// Start a fresh run from a feature description.
    /// Corresponds to ralph.sh main() (lines 754-837)
    func run(feature: String, repoPath: URL, config: RunConfig) async throws {
        metrics = RunMetrics()
        logEntries = []

        log(.system, "Starting Ralph — Max iterations per phase: \(config.maxIterationsPerPhase)")

        try git.validateRepo(at: repoPath)
        let prdURL = prdFileURL(in: repoPath)

        // === BLOCK 1: PRD Creation ===
        try await createPRD(feature: feature, repoPath: repoPath, prdURL: prdURL)

        // === BLOCK 2+: Phase Loop ===
        try await runPhaseLoop(repoPath: repoPath, prdURL: prdURL, config: config)
    }

    /// Resume from an existing prd.json (for interrupted runs).
    func resume(repoPath: URL, config: RunConfig) async throws {
        metrics = RunMetrics()
        logEntries = []

        let prdURL = prdFileURL(in: repoPath)
        prd = try PRD.load(from: prdURL)

        guard let prd else { throw OrchestrationError.noPRD }

        if prd.isLegacy {
            try await runLegacyLoop(repoPath: repoPath, prdURL: prdURL, config: config)
        } else {
            try await runPhaseLoop(repoPath: repoPath, prdURL: prdURL, config: config)
        }
    }

    // MARK: - BLOCK 1: PRD Creation

    /// Corresponds to ralph.sh do_single_prd() (lines 524-550)
    private func createPRD(feature: String, repoPath: URL, prdURL: URL) async throws {
        state = .creatingPRD
        log(.system, "Creating PRD from feature description...")

        guard let prompt = templates.buildPRDPrompt(feature: feature) else {
            throw OrchestrationError.templateNotFound("prd-single")
        }

        // Invoke Claude — stream output so the user sees progress
        var lineCount = 0
        for try await line in claude.run(prompt: prompt, workingDirectory: repoPath) {
            lineCount += 1
            log(.claude, line)
        }
        log(.system, "Claude finished (\(lineCount) lines of output)")

        // Load the generated prd.json
        guard FileManager.default.fileExists(atPath: prdURL.path) else {
            throw OrchestrationError.prdNotGenerated
        }

        prd = try PRD.load(from: prdURL)
        prd?.orchestration.dualPrdComplete = true
        try prd?.save(to: prdURL)

        let phaseCount = prd?.phases.count ?? 0
        let storyCount = prd?.phases.reduce(0) { $0 + $1.storyCount } ?? 0
        log(.system, "PRD created: \(phaseCount) phases, \(storyCount) stories")
    }

    // MARK: - Phase Loop

    /// Corresponds to ralph.sh main() phase loop (lines 790-836)
    private func runPhaseLoop(repoPath: URL, prdURL: URL, config: RunConfig) async throws {
        guard var prd else { throw OrchestrationError.noPRD }

        let totalPhases = prd.phases.count
        guard totalPhases > 0 else { throw OrchestrationError.noPhases }

        log(.system, "Found \(totalPhases) phases in prd.json")

        while true {
            // Reload PRD (worker may have modified it)
            prd = try PRD.load(from: prdURL)
            self.prd = prd

            let phaseIndex = prd.orchestration.currentPhaseIndex

            // Check completion
            if prd.allPhasesComplete {
                state = .complete
                log(.system, "ALL PHASES COMPLETE!")
                writeRunSummary(to: repoPath)
                return
            }

            guard phaseIndex < totalPhases else {
                state = .complete
                log(.system, "All phases processed.")
                writeRunSummary(to: repoPath)
                return
            }

            let phase = prd.phases[phaseIndex]
            log(.system, "Phase \(phaseIndex + 1)/\(totalPhases): \(phase.title) (status: \(phase.status.rawValue))")

            // Record commit before phase for diffing later
            let prePhaseCommit = try? await git.headCommit(at: repoPath)

            // === BLOCK 2: Planning ===
            if !config.skipPlanning && phase.status != .inProgress && phase.status != .complete {
                try await planPhase(phaseIndex: phaseIndex, phase: phase, repoPath: repoPath, prdURL: prdURL, config: config)
            }

            // === BLOCK 3: Execution ===
            if phase.status != .complete {
                try await executePhase(phaseIndex: phaseIndex, repoPath: repoPath, prdURL: prdURL, config: config)
            }

            // === BLOCK 4: Quality Gate (NEW from ECC) ===
            if config.enableQualityGate {
                try await runQualityCheck(phaseIndex: phaseIndex, repoPath: repoPath, prdURL: prdURL)
            }

            // === BLOCK 5: De-sloppify (NEW from ECC) ===
            if config.enableDesloppify, let preCommit = prePhaseCommit {
                try await runDesloppify(phaseIndex: phaseIndex, prePhaseCommit: preCommit, repoPath: repoPath)
            }

            // === BLOCK 6: Review ===
            if config.enableReview {
                let approved = try await reviewPhase(phaseIndex: phaseIndex, repoPath: repoPath, prdURL: prdURL)

                // === BLOCK 7: Fix Planning (if rejected) ===
                if !approved {
                    try await fixAndRetry(phaseIndex: phaseIndex, repoPath: repoPath, prdURL: prdURL, config: config)
                }
            }

            // === Advance to next phase ===
            self.prd = try PRD.load(from: prdURL)
            try self.prd?.update(at: prdURL) { prd in
                prd.phases[phaseIndex].status = .complete
                let nextIndex = phaseIndex + 1
                if nextIndex < totalPhases {
                    prd.orchestration.currentPhaseIndex = nextIndex
                }
            }

            log(.system, "Phase \(phaseIndex + 1) complete. Advancing.")
        }
    }

    // MARK: - BLOCK 2: Phase Planning

    /// Corresponds to ralph.sh do_phase_planning() / do_single_plan() (lines 554-606)
    private func planPhase(phaseIndex: Int, phase: Phase, repoPath: URL, prdURL: URL, config: RunConfig) async throws {
        // Skip planning for phases with ≤1 story
        if phase.storyCount <= 1 {
            log(.system, "Phase has \(phase.storyCount) story — skipping planning")
            try prd?.update(at: prdURL) { prd in
                prd.phases[phaseIndex].status = .inProgress
                prd.orchestration.status = .executing
            }
            return
        }

        state = .planning(phaseIndex: phaseIndex)
        log(.system, "Planning phase \(phaseIndex + 1): \(phase.title) (\(phase.storyCount) stories)")

        guard let prompt = templates.buildPlanningPrompt(
            phaseIndex: phaseIndex,
            phaseTitle: phase.title,
            repoPath: repoPath
        ) else {
            throw OrchestrationError.templateNotFound("phase-planner")
        }

        // Throttle before invoking
        try await throttle(config.throttleDelay)

        let output = try await claude.runAndCollect(prompt: prompt, workingDirectory: repoPath)
        log(.claude, String(output.prefix(500)) + "...")

        metrics.totalPlanningInstances += 1

        // Update PRD
        try prd?.update(at: prdURL) { prd in
            prd.phases[phaseIndex].planVersion += 1
            prd.phases[phaseIndex].status = .inProgress
            prd.orchestration.status = .executing
        }

        log(.system, "Planning complete. Plan version: \((prd?.phases[phaseIndex].planVersion ?? 0))")
    }

    // MARK: - BLOCK 3: Worker Execution Loop

    /// Corresponds to ralph.sh do_execute_phase() (lines 609-702)
    private func executePhase(phaseIndex: Int, repoPath: URL, prdURL: URL, config: RunConfig) async throws {
        let phaseTitle = prd?.phases[phaseIndex].title ?? "Unknown"
        log(.system, "Executing phase \(phaseIndex + 1): \(phaseTitle)")

        try prd?.update(at: prdURL) { prd in
            prd.phases[phaseIndex].status = .inProgress
            prd.orchestration.status = .executing
        }

        for iteration in 1...config.maxIterationsPerPhase {
            state = .executing(phaseIndex: phaseIndex, iteration: iteration)
            metrics.totalWorkerIterations += 1
            metrics.perPhase[phaseIndex, default: .init()].iterations += 1

            log(.system, "--- Phase \(phaseIndex + 1), Iteration \(iteration)/\(config.maxIterationsPerPhase) ---")

            // Build augmented worker prompt (plan + CLAUDE.md)
            guard let prompt = templates.buildWorkerPrompt(phaseIndex: phaseIndex, repoPath: repoPath) else {
                throw OrchestrationError.templateNotFound("worker-template")
            }

            // Throttle between iterations
            try await throttle(config.throttleDelay)

            // Stream output from Claude
            var fullOutput = ""
            for try await line in claude.run(prompt: prompt, workingDirectory: repoPath) {
                fullOutput += line + "\n"
                log(.claude, line)
            }

            // Check for completion signals
            if fullOutput.contains("<promise>PHASE_COMPLETE</promise>") ||
               fullOutput.contains("<promise>COMPLETE</promise>") {
                log(.system, "Phase \(phaseIndex + 1) completed by worker!")
                return
            }

            // Reload PRD and check if all stories pass
            prd = try PRD.load(from: prdURL)
            if prd?.phases[phaseIndex].allStoriesPass == true {
                log(.system, "All stories in phase \(phaseIndex + 1) pass!")
                return
            }

            try await Task.sleep(for: .seconds(2))
        }

        log(.system, "WARNING: Phase \(phaseIndex + 1) reached max iterations (\(config.maxIterationsPerPhase))")
    }

    // MARK: - BLOCK 4: Quality Gate (NEW from ECC)

    /// Runs 6-phase verification after worker completes.
    /// Source: everything-claude-code/skills/verification-loop/SKILL.md
    private func runQualityCheck(phaseIndex: Int, repoPath: URL, prdURL: URL) async throws {
        state = .qualityCheck(phaseIndex: phaseIndex)
        log(.system, "Running quality gate (build → types → lint → tests → security → diff)...")

        let report = try await qualityGate.run(repoPath: repoPath)
        log(.qualityGate, report.summary)

        // If build or type check fails, invoke build-error-resolver
        if report.build.status == .fail || report.typeCheck.status == .fail {
            log(.system, "Quality gate FAILED on build/types — invoking build error resolver...")

            let resolverPrompt = templates.buildErrorResolverPrompt(
                buildOutput: report.build.output,
                typeCheckOutput: report.typeCheck.output
            )

            let output = try await claude.runAndCollect(prompt: resolverPrompt, workingDirectory: repoPath)
            log(.claude, String(output.prefix(500)) + "...")

            // Re-verify after fix
            let recheck = try await qualityGate.run(repoPath: repoPath)
            log(.qualityGate, "Re-check: " + recheck.summary)

            if !recheck.isReady {
                log(.error, "Quality gate still failing after auto-fix. Continuing anyway.")
            }
        }
    }

    // MARK: - BLOCK 5: De-sloppify (NEW from ECC)

    /// Separate cleanup pass after implementation.
    /// Source: everything-claude-code/skills/autonomous-loops/SKILL.md §5
    private func runDesloppify(phaseIndex: Int, prePhaseCommit: String, repoPath: URL) async throws {
        state = .desloppifying(phaseIndex: phaseIndex)
        log(.system, "Running de-sloppify cleanup pass...")

        // Get diff of all changes in this phase
        let phaseDiff: String
        do {
            phaseDiff = try await git.diffBetween(from: prePhaseCommit, at: repoPath)
        } catch {
            log(.system, "Could not get phase diff for de-sloppify, skipping")
            return
        }

        guard !phaseDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log(.system, "No changes to de-sloppify")
            return
        }

        let prompt = templates.buildDesloppifyPrompt(phaseDiff: String(phaseDiff.prefix(10000)))

        let output = try await claude.runAndCollect(prompt: prompt, workingDirectory: repoPath)
        log(.claude, String(output.prefix(500)) + "...")

        log(.system, "De-sloppify complete")
    }

    // MARK: - BLOCK 6: Phase Review

    /// Corresponds to ralph.sh phase review step using phase-reviewer.md
    private func reviewPhase(phaseIndex: Int, repoPath: URL, prdURL: URL) async throws -> Bool {
        state = .reviewing(phaseIndex: phaseIndex)
        log(.system, "Reviewing phase \(phaseIndex + 1)...")

        guard let prompt = templates.buildReviewPrompt(phaseIndex: phaseIndex) else {
            throw OrchestrationError.templateNotFound("phase-reviewer")
        }

        let output = try await claude.runAndCollect(prompt: prompt, workingDirectory: repoPath)
        log(.review, String(output.prefix(500)) + "...")

        // Reload PRD to check reviewApproved
        prd = try PRD.load(from: prdURL)
        let approved = prd?.phases[phaseIndex].reviewApproved ?? false

        if approved {
            log(.system, "Phase \(phaseIndex + 1) review: APPROVED")
        } else {
            let notes = prd?.phases[phaseIndex].reviewNotes ?? "No notes"
            log(.system, "Phase \(phaseIndex + 1) review: REJECTED — \(notes)")
            metrics.perPhase[phaseIndex, default: .init()].rejections += 1
        }

        return approved
    }

    // MARK: - BLOCK 7: Fix Planning + Re-execution

    /// Corresponds to ralph.sh fix planning and re-execution of failed stories
    private func fixAndRetry(phaseIndex: Int, repoPath: URL, prdURL: URL, config: RunConfig) async throws {
        state = .fixPlanning(phaseIndex: phaseIndex)
        log(.system, "Creating targeted fix plan for failed stories...")

        guard let prompt = templates.buildFixPlannerPrompt(phaseIndex: phaseIndex) else {
            throw OrchestrationError.templateNotFound("phase-fix-planner")
        }

        let output = try await claude.runAndCollect(prompt: prompt, workingDirectory: repoPath)
        log(.claude, String(output.prefix(500)) + "...")

        // Re-execute the phase (only failed stories will be picked up)
        log(.system, "Re-executing phase with fix guidance...")
        try await executePhase(phaseIndex: phaseIndex, repoPath: repoPath, prdURL: prdURL, config: config)
    }

    // MARK: - Legacy Mode

    /// Corresponds to ralph.sh do_legacy_loop() (lines 706-750)
    private func runLegacyLoop(repoPath: URL, prdURL: URL, config: RunConfig) async throws {
        log(.system, "Detected legacy prd.json format (no phases). Running simple loop.")

        // Load CLAUDE.md as the worker prompt
        guard let workerTemplate = templates.loadBundledTemplate(named: "worker-template")
                ?? templates.loadTemplate(at: repoPath.appendingPathComponent("CLAUDE.md")) else {
            throw OrchestrationError.templateNotFound("worker-template")
        }

        for iteration in 1...config.maxIterationsPerPhase {
            state = .executing(phaseIndex: 0, iteration: iteration)
            log(.system, "--- Legacy Iteration \(iteration)/\(config.maxIterationsPerPhase) ---")

            try await throttle(config.throttleDelay)

            var fullOutput = ""
            for try await line in claude.run(prompt: workerTemplate, workingDirectory: repoPath) {
                fullOutput += line + "\n"
                log(.claude, line)
            }

            if fullOutput.contains("<promise>COMPLETE</promise>") {
                state = .complete
                log(.system, "Ralph completed all tasks at iteration \(iteration)!")
                return
            }

            try await Task.sleep(for: .seconds(2))
        }

        state = .failed("Reached max iterations without completing")
        log(.error, "Ralph reached max iterations (\(config.maxIterationsPerPhase)) without completing all tasks.")
    }

    // MARK: - Helpers

    private func prdFileURL(in repoPath: URL) -> URL {
        repoPath.appendingPathComponent("prd.json")
    }

    private func throttle(_ delay: TimeInterval) async throws {
        if delay > 0 {
            log(.system, "(throttle: \(Int(delay))s delay)")
            try await Task.sleep(for: .seconds(delay))
        }
    }

    private func log(_ source: LogEntry.Source, _ message: String) {
        logEntries.append(LogEntry(source: source, message: message))
    }

    private func writeRunSummary(to repoPath: URL) {
        let summary = metrics.toJSON()
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: .prettyPrinted) else { return }
        let summaryURL = repoPath.appendingPathComponent("ralph-run-summary.json")
        try? data.write(to: summaryURL, options: .atomic)
        log(.system, "Run summary written to ralph-run-summary.json")
    }

    // MARK: - Errors

    enum OrchestrationError: LocalizedError {
        case noPRD
        case prdNotGenerated
        case noPhases
        case templateNotFound(String)

        var errorDescription: String? {
            switch self {
            case .noPRD: return "No prd.json found"
            case .prdNotGenerated: return "PRD author did not produce prd.json — Claude may have failed to write the file. Check the log output above for errors."
            case .noPhases: return "prd.json has no phases defined"
            case .templateNotFound(let name): return "Prompt template '\(name)' not found in bundle"
            }
        }
    }
}

import Foundation

// MARK: - Prompt Template Engine

/// Loads .md prompt templates and substitutes {{PLACEHOLDER}} values.
/// Matches ralph.sh generate_prompt() (lines 453-473).
struct PromptTemplateEngine {

    /// Substitute all {{KEY}} placeholders in a template string
    func render(template: String, substitutions: [String: String]) -> String {
        var result = template
        for (key, value) in substitutions {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    /// Load a template from the app bundle by filename (without extension)
    func loadBundledTemplate(named name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Load a template from an arbitrary file path
    func loadTemplate(at path: URL) -> String? {
        try? String(contentsOf: path, encoding: .utf8)
    }

    // MARK: - PRD Creation Prompt

    /// Build the PRD creation prompt from prd-single.md template
    /// Corresponds to ralph.sh do_single_prd() (lines 524-550)
    func buildPRDPrompt(feature: String) -> String? {
        guard let template = loadBundledTemplate(named: "prd-single") else { return nil }
        return render(template: template, substitutions: [
            "FEATURE": feature
        ])
    }

    // MARK: - Phase Planning Prompt

    /// Build the phase planning prompt from phase-planner.md template
    /// Corresponds to ralph.sh do_single_plan() (lines 554-588)
    func buildPlanningPrompt(phaseIndex: Int, phaseTitle: String, repoPath: URL) -> String? {
        guard let template = loadBundledTemplate(named: "phase-planner") else { return nil }
        return render(template: template, substitutions: [
            "PHASE_INDEX": String(phaseIndex),
            "PHASE_TITLE": phaseTitle,
            "LENS": "Create a balanced implementation plan. Consider both simplicity and robustness. Prefer reusing existing patterns while also handling important edge cases. Choose the most practical approach that meets all acceptance criteria.",
            "OUTPUT_FILE": "ralph-plans/phase-\(phaseIndex)-plan-final.md",
            "PLANNER_ID": "Planner (Balanced)"
        ])
    }

    // MARK: - Worker Prompt (Augmented)

    /// Build the augmented worker prompt: [phase plan] + [worker template]
    /// Corresponds to ralph.sh do_execute_phase() prompt building (lines 624-653)
    func buildWorkerPrompt(phaseIndex: Int, repoPath: URL) -> String? {
        // Load base worker template (CLAUDE.md)
        guard let workerTemplate = loadBundledTemplate(named: "worker-template")
                ?? loadTemplate(at: repoPath.appendingPathComponent("CLAUDE.md")) else {
            return nil
        }

        // Try to load the phase plan
        let planPath = repoPath.appendingPathComponent("ralph-plans/phase-\(phaseIndex)-plan-final.md")

        var prompt = ""

        if let planContent = loadTemplate(at: planPath) {
            prompt += "## Phase Implementation Plan\n\n"
            prompt += "The following plan was created for this phase. Use it as implementation guidance.\n\n"
            prompt += planContent
            prompt += "\n\n---\n\n"
        }

        prompt += workerTemplate
        return prompt
    }

    // MARK: - Phase Review Prompt

    /// Build the phase review prompt from phase-reviewer.md template
    func buildReviewPrompt(phaseIndex: Int) -> String? {
        guard let template = loadBundledTemplate(named: "phase-reviewer") else { return nil }
        return render(template: template, substitutions: [
            "PHASE_INDEX": String(phaseIndex)
        ])
    }

    // MARK: - Fix Planning Prompt

    /// Build the fix planning prompt from phase-fix-planner.md template
    func buildFixPlannerPrompt(phaseIndex: Int) -> String? {
        guard let template = loadBundledTemplate(named: "phase-fix-planner") else { return nil }
        return render(template: template, substitutions: [
            "PHASE_INDEX": String(phaseIndex)
        ])
    }

    // MARK: - De-sloppify Prompt (NEW — from ECC)

    /// Build the de-sloppify cleanup prompt
    /// Source: everything-claude-code/skills/autonomous-loops/SKILL.md section 5
    func buildDesloppifyPrompt(phaseDiff: String) -> String {
        """
        # De-sloppify Cleanup Pass

        Review all changes in the working tree from this phase. The git diff of changes is included below.

        ## Remove the following:
        - Tests that verify language/framework behavior rather than business logic
        - Redundant type checks that the type system already enforces
        - Over-defensive error handling for impossible states
        - Console.log / print statements used for debugging
        - Commented-out code
        - Unnecessary TODO comments that were already addressed

        ## Keep:
        - All business logic tests
        - Meaningful error handling for real failure modes
        - Intentional logging (structured logs, error reporting)

        ## After cleanup:
        - Run the test suite to ensure nothing breaks
        - Run typecheck/lint to ensure code is clean
        - Commit cleanup changes with message: "refactor: de-sloppify phase cleanup"

        ---

        ## Current Phase Diff

        ```diff
        \(phaseDiff)
        ```
        """
    }

    // MARK: - Build Error Resolver Prompt (NEW — from ECC)

    /// Build the build error resolver prompt
    /// Source: everything-claude-code/agents/build-error-resolver.md
    func buildErrorResolverPrompt(buildOutput: String, typeCheckOutput: String) -> String {
        """
        # Build Error Resolution

        The quality gate detected build or type errors. Fix them without changing business logic.

        ## Build Output
        ```
        \(buildOutput)
        ```

        ## Type Check Output
        ```
        \(typeCheckOutput)
        ```

        ## Instructions
        1. Read each error carefully
        2. Fix the root cause (not symptoms)
        3. Do NOT add type casts or `any` types to suppress errors
        4. Do NOT change business logic — only fix build/type issues
        5. Run build and typecheck again to verify fixes
        6. Commit fixes with message: "fix: resolve build errors"
        """
    }
}

# Ralph Swift Services

Swift implementation of the ralph.sh orchestration loop for the Mac app. Each file is a self-contained block you can drop into your Xcode project.

## Files

### Models/
- **`PRD.swift`** — Codable data models matching prd.json (PRD, Phase, UserStory, Orchestration, RunConfig, RunMetrics, LogEntry)

### Services/
- **`ClaudeCodeService.swift`** — Process wrapper for `claude --dangerously-skip-permissions --print`. Streams output, detects rate limits, auto-retries.
- **`PromptTemplateEngine.swift`** — Loads .md templates, substitutes `{{PLACEHOLDER}}` values. Includes builders for all ralph prompts + new ECC prompts (de-sloppify, build-error-resolver).
- **`GitService.swift`** — Basic git operations (branch, status, diff, log) via Process.
- **`QualityGateService.swift`** — ECC 6-phase verification: build → types → lint → tests → security → diff. Auto-detects project type and package manager.
- **`MCPManager.swift`** — Reads/writes `~/.claude.json` to manage MCP servers. Includes curated catalog of recommended MCPs.
- **`OrchestrationEngine.swift`** — The main ralph loop as an `@Observable` async state machine. Calls all other services. States: idle → creatingPRD → planning → executing → qualityCheck → desloppifying → reviewing → fixPlanning → complete.

### Prompts/
- **`de-sloppify.md`** — Cleanup pass prompt (NEW from ECC)
- **`build-error-resolver.md`** — Build error fix prompt (NEW from ECC)

## Bundled Resources Needed

Copy these from ralph-enhanced into your Xcode project's Resources:
1. `ralph-enhanced/prompts/prd-single.md`
2. `ralph-enhanced/prompts/phase-planner.md`
3. `ralph-enhanced/prompts/phase-reviewer.md`
4. `ralph-enhanced/prompts/phase-fix-planner.md`
5. `ralph-enhanced/CLAUDE.md` → rename to `worker-template.md`
6. `swift-services/Prompts/de-sloppify.md`
7. `swift-services/Prompts/build-error-resolver.md`

## The Loop

```
1. createPRD(feature)           — Block 1: Generates prd.json with phases/stories
2. for each phase:
   a. planPhase()               — Block 2: Creates implementation plan (if >1 story)
   b. executePhase()            — Block 3: Worker loop (Claude implements stories)
   c. runQualityCheck()         — Block 4: 6-phase verification (NEW from ECC)
   d. runDesloppify()           — Block 5: Cleanup pass (NEW from ECC)
   e. reviewPhase()             — Block 6: Review acceptance criteria
   f. fixAndRetry()             — Block 7: Fix rejected stories and re-execute
3. complete                     — Write run summary
```

## ECC Quality Improvements

| What | Block | Impact |
|------|-------|--------|
| Verification loop (6-phase) | Block 4 | Catches broken builds before advancing |
| De-sloppify pass | Block 5 | Removes LLM sloppiness |
| Build error resolver | Block 4 (on failure) | Auto-fixes build errors |
| Context7 MCP | All blocks | Claude uses current API docs |

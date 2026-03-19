# Ralph Mac App — Implementation Plan for Claude Code

You are implementing a macOS app that wraps the Ralph autonomous coding loop. The Swift service files have already been written and are ready to integrate.

## Setup

1. **Ralph service files**: `~/path-to/ralph-enhanced/swift-services/` (branch: `claude/automate-project-setup-5atqm`)
2. **Xcode project**: `~/path-to/YourApp.xcodeproj` (the user's existing Mac app)

## Phase 1: Copy & Integrate Service Files

1. Read all files in `ralph-enhanced/swift-services/Models/` and `ralph-enhanced/swift-services/Services/`
2. Copy them into the Xcode project's source tree under `Sources/Services/` and `Sources/Models/`
3. Copy prompt templates from these locations into the Xcode project's Resources:
   - `ralph-enhanced/prompts/prd-single.md`
   - `ralph-enhanced/prompts/phase-planner.md`
   - `ralph-enhanced/prompts/phase-reviewer.md`
   - `ralph-enhanced/prompts/phase-fix-planner.md`
   - `ralph-enhanced/CLAUDE.md` → rename to `worker-template.md`
   - `ralph-enhanced/swift-services/Prompts/de-sloppify.md`
   - `ralph-enhanced/swift-services/Prompts/build-error-resolver.md`
4. Verify the project builds with `xcodebuild -scheme YourApp build`

## Phase 2: Wire Up the UI

The app needs these views:

### Main Window — Project Setup
- **Repo picker**: Folder selector → validates it's a git repo via `GitService.isGitRepo()`
- **Feature input**: Multi-line text field for the feature description
- **MCP config panel**: Toggle switches for each MCP from `MCPManager.availableServers()`, env var fields for those that need them
- **Config toggles**: Map to `RunConfig` — max iterations slider, quality gate on/off, de-sloppify on/off, review on/off, throttle delay
- **"Run Ralph" button**: Calls `OrchestrationEngine.run(feature:repoPath:config:)`
- **"Resume" button**: Visible when prd.json exists in selected repo. Calls `OrchestrationEngine.resume(repoPath:config:)`

### Run View — Live Dashboard
- **State indicator**: Shows current `OrchestrationEngine.State` as a phase badge with progress
  - idle → gray
  - creatingPRD → blue "Creating PRD..."
  - planning(N) → blue "Planning Phase N..."
  - executing(N, iter) → green "Executing Phase N (iteration iter)..."
  - qualityCheck(N) → yellow "Quality Gate..."
  - desloppifying(N) → yellow "De-sloppify..."
  - reviewing(N) → orange "Reviewing Phase N..."
  - fixPlanning(N) → orange "Fix Planning..."
  - complete → green checkmark
  - failed(msg) → red with message
  - rateLimited(date) → amber with countdown timer

- **Phase progress**: Horizontal segmented bar showing all phases, colored by status (pending/active/complete/failed). Each segment shows story count.

- **Live log**: Scrolling text view showing `OrchestrationEngine.logEntries`, color-coded by source:
  - `.system` → gray
  - `.claude` → white/default
  - `.qualityGate` → yellow
  - `.review` → orange
  - `.error` → red

- **PRD sidebar** (when prd loaded): Tree view of phases → stories, with pass/fail badges updating in real-time as the engine reloads prd.json

- **Metrics footer**: Duration, total iterations, current phase progress

### Settings View
- Claude CLI path (auto-discovered or manual override)
- Default throttle delay
- Default max iterations

## Phase 3: App Architecture

```
YourApp/
├── YourApp.swift              (App entry point, WindowGroup)
├── Models/
│   └── PRD.swift              (from swift-services)
├── Services/
│   ├── ClaudeCodeService.swift
│   ├── PromptTemplateEngine.swift
│   ├── GitService.swift
│   ├── QualityGateService.swift
│   ├── MCPManager.swift
│   └── OrchestrationEngine.swift
├── Views/
│   ├── ProjectSetupView.swift
│   ├── RunDashboardView.swift
│   ├── LiveLogView.swift
│   ├── PhaseProgressBar.swift
│   ├── PRDSidebarView.swift
│   ├── MCPConfigPanel.swift
│   └── SettingsView.swift
└── Resources/
    ├── prd-single.md
    ├── phase-planner.md
    ├── phase-reviewer.md
    ├── phase-fix-planner.md
    ├── worker-template.md
    ├── de-sloppify.md
    └── build-error-resolver.md
```

## Phase 4: Key Integration Points

### OrchestrationEngine is @Observable
All views bind directly to it:
```swift
@State private var engine = OrchestrationEngine()

// In view body:
switch engine.state {
case .idle: ProjectSetupView(engine: engine)
case .complete: CompletionView(metrics: engine.metrics)
default: RunDashboardView(engine: engine)
}
```

### Running on a background task
The engine runs on a background Task. UI updates happen automatically via @Observable:
```swift
Task {
    try await engine.run(feature: featureText, repoPath: repoURL, config: config)
}
```

### Process requires App Sandbox exceptions
In entitlements, the app needs:
- `com.apple.security.app-sandbox` = NO (or use a helper tool)
- OR create a non-sandboxed helper for Process execution

Since this is a developer tool, simplest approach is to disable App Sandbox entirely.

## Phase 5: Build & Verify

1. `xcodebuild -scheme YourApp build` — must compile clean
2. Manual test: Select a small test repo, enter a trivial feature ("add a hello endpoint"), run Ralph
3. Verify: PRD created → planning → execution → quality gate → review → complete
4. Verify: Rate limit detection shows countdown in UI
5. Verify: Resume works after killing the app mid-run

## Important Notes

- All service files compile as-is for macOS 14+ / Swift 5.9+
- `OrchestrationEngine` uses `@Observable` (requires macOS 14+)
- `ClaudeCodeService` is an `actor` — all calls are `await`
- The engine streams output via `logEntries` — the UI should auto-scroll
- `PromptTemplateEngine.loadBundledTemplate()` uses `Bundle.main` — the .md files MUST be in the app bundle's Resources

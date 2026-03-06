# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs AI coding tools ([Claude Code](https://docs.anthropic.com/en/docs/claude-code) or the [Anthropic API](https://docs.anthropic.com/en/api)) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context. Memory persists via git history, `progress.txt`, and `prd.json`.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## Prerequisites

- One of the following AI backends:
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`) — default; uses 30s throttle by default to reduce rate limits
  - Anthropic API (`--tool api`) — usage-based billing, separate from Claude Code; requires `ANTHROPIC_API_KEY` and `cd scripts && npm install`
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project

## Setup

### Option 1: Copy to your project

Copy the ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph.sh scripts/ralph/
cp -r /path/to/ralph/prompts scripts/ralph/prompts

# Copy the worker prompt template:
cp /path/to/ralph/CLAUDE.md scripts/ralph/CLAUDE.md

chmod +x scripts/ralph/ralph.sh
```

### Option 2: Install skills globally (Claude Code)

Copy the skills to your Claude config for use across all projects:

```bash
cp -r skills/prd ~/.claude/skills/
cp -r skills/ralph ~/.claude/skills/
cp -r skills/dual-prd ~/.claude/skills/
```

### Option 3: Use as Claude Code Marketplace

Add the Ralph marketplace to Claude Code:

```bash
/plugin marketplace add snarktank/ralph
```

Then install the skills:

```bash
/plugin install ralph-skills@ralph-marketplace
```

Available skills after installation:
- `/prd` - Generate Product Requirements Documents
- `/ralph` - Convert PRDs to prd.json format
- `/dual-prd` - Generate PRDs using dual-author synthesis (two perspectives merged into one)

Skills are automatically invoked when you ask Claude to:
- "create a prd", "write prd for", "plan this feature"
- "convert this prd", "turn into ralph format", "create prd.json"
- "dual prd", "create dual prd", "two-author prd"

## Recommended Workflow

Choose your workflow based on feature size:

| Feature size | Stories | Recommended workflow |
|---|---|---|
| Small | 1-3 | `/prd` → `/ralph` → `ralph.sh --skip-dual-prd` |
| Medium | 4-8 | `/dual-prd` → review prd.json → `ralph.sh --skip-dual-prd` (or use `--feature` for single-call PRD) |
| Large | 9+ | `ralph.sh --feature "..."` (fully automated) |

### Path 1: Small Features (1-3 stories)

The original flow. Quick and lightweight.

```
# Step 1: Create a PRD interactively
/prd

# Step 2: Convert to Ralph's JSON format
/ralph

# Step 3: Run Ralph
./ralph.sh --tool claude --skip-dual-prd
```

Ralph auto-detects flat prd.json and runs a simple loop — no phases.

### Path 2: Medium Features (4-8 stories) — Recommended

Interactive dual-author PRD with a chance to review before execution.

```
# Step 1: Create a dual-perspective PRD interactively
/dual-prd

# Step 2: Review the generated prd.json — tweak phases, stories, or ACs if needed

# Step 3: Run Ralph with phased execution
./ralph.sh --tool claude --skip-dual-prd
```

The `/dual-prd` skill asks clarifying questions and writes a phased `prd.json`. You review it before Ralph starts. The orchestrator handles complexity-based planning and execution (no phase review step).

### Path 3: Large Features (9+ stories)

Fully automated end-to-end. No manual steps.

```bash
./ralph.sh --tool claude --feature "Add task priority system with filtering and sorting"
```

Or from a file:

```bash
./ralph.sh --tool claude --feature @tasks/my-feature-spec.md
```

This runs a single PRD call from your feature description, then phases with complexity-based planning and execution without any human intervention. Use this when you want to kick off a run and walk away.

### Skipping Steps

```bash
# Already have a phased prd.json, skip PRD creation
./ralph.sh --tool claude --skip-dual-prd

# Skip both PRD creation and per-phase planning (just execution)
./ralph.sh --tool claude --skip-dual-prd --skip-planning
```

## How Multi-Phase Works

```
Feature Description
     |
     +---> Single PRD call (technical + UX in one pass) ---> prd.json (with phases)

For each phase:
     +--- Complexity Check (story count) ---+
     | 1 story: skip planning               |
     | 2+ stories: single planner           |
     +--------------------------------------+
                    |
              Execution Loop (worker implements stories)
                    |
              Mark phase complete --> Advance to next phase
```

**PRD Creation:** One LLM call takes your feature description, considers both technical depth and user experience, and writes `prd.json` with phases and right-sized user stories.

**Complexity-Based Planning:** Single-story phases skip planning entirely. Phases with two or more stories get a single balanced planner that considers both simplicity and robustness.

**Execution:** The worker loop runs until the phase is complete (all stories pass or PHASE_COMPLETE). The phase is then marked complete and the next phase runs. There is no separate review step.

**Plan Injection:** Phase plans are prepended directly into worker prompts, guaranteeing workers use the plan guidance rather than relying on them to voluntarily read a file.

**Rate Limit Handling:** All AI invocations detect rate limits automatically. When rate limited, Ralph parses the reset time from the error message and waits accordingly, then retries. The `--throttle` flag sets the delay between calls (default for claude: 30s).

**Run Metrics:** Each run produces a `ralph-run-summary.json` with iteration counts and planning instances per phase.

## CLI Reference

```bash
./ralph.sh [OPTIONS] [max_iterations_per_phase]
```

**Common invocations**

```bash
# Claude Code (safe default: 30s between calls to avoid rate limits)
./ralph.sh --tool claude --skip-dual-prd

# With a new feature from scratch
./ralph.sh --tool claude --feature "Add task priority and filtering"

# Anthropic API (separate quota; set ANTHROPIC_API_KEY and run: cd scripts && npm install)
./ralph.sh --tool api --skip-dual-prd
```

**Options**

| Option | Description |
|--------|-------------|
| `--feature "desc"` or `--feature @path` | Feature for PRD creation (single LLM call), or path to file |
| `--skip-dual-prd` | Use existing prd.json |
| `--skip-planning` | Skip planning, go straight to execution |
| `--tool claude\|api` | AI backend (default: claude; 30s throttle by default) |
| `--throttle normal\|conservative\|minimal` | Delay between calls: 5s, 30s, or 60s |

### Using the Anthropic API (`--tool api`)

The API backend uses your own Anthropic API key and has **separate rate limits and usage-based billing** from Claude Code. Useful if you hit Claude Code limits or want to reserve Claude Code for interactive use.

1. Set `ANTHROPIC_API_KEY` (from [console.anthropic.com](https://console.anthropic.com)).
2. Install the wrapper deps: `cd scripts && npm install`
3. Run: `./ralph.sh --tool api [options]`

Optional: `ANTHROPIC_MODEL` (default: `claude-sonnet-4-20250514`).

**Auto-switch on rate limit:** When you run with `--tool claude`, if Ralph hits a Claude Code rate limit and the API is set up (same steps above), it will automatically switch to the Anthropic API for the rest of that run so the job can continue.

## Key Files

| File | Purpose |
|------|---------|
| `ralph.sh` | Orchestrator: state machine that spawns AI instances for PRD creation, planning, and execution |
| `scripts/` | Anthropic API wrapper for `--tool api`; run `npm install` in scripts/ before using |
| `CLAUDE.md` | Worker prompt template for Claude Code and API |
| `prompts/` | Prompt templates for PRD (single), phase planner, and worker |
| `prd.json` | User stories with phases and `passes` status (the task list) |
| `prd.json.example` | Example phased PRD format for reference |
| `progress.txt` | Append-only learnings for future iterations |
| `skills/prd/` | Skill for generating PRDs |
| `skills/ralph/` | Skill for converting PRDs to JSON (supports flat and phased formats) |
| `skills/dual-prd/` | Skill for dual-author PRD creation (interactive version) |
| `ralph-plans/` | Final phase plans (git-tracked, survives interruption) |
| `.ralph-tmp/` | Temporary files for intermediate PRDs, draft plans, and review reports (gitignored) |
| `ralph-run-summary.json` | Run metrics: iterations and planning instances per phase (gitignored) |
| `.claude-plugin/` | Plugin manifest for Claude Code marketplace discovery |
| `flowchart/` | Interactive visualization of how Ralph works |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations.

The `flowchart/` directory contains the source code. To run locally:

```bash
cd flowchart
npm install
npm run dev
```

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new AI instance** (Claude Code or API) with clean context. The only memory between iterations is:
- Git history (commits from previous iterations)
- `progress.txt` (learnings and context)
- `prd.json` (which stories are done)

### Phases (Multi-Phase Mode)

In phased mode, stories are grouped into phases. Each phase has:
- **Complexity-based planning** before execution (skip for 1 story, single planner for 2+)
- Execution until complete, then advance to next phase
- Independent progress tracking
- Plan injection directly into worker prompts

Phase status flow: `pending` → `planning` → `in_progress` → `complete`

### Small Tasks

Each PRD item should be small enough to complete in one context window. If a task is too big, the LLM runs out of context before finishing and produces poor code.

Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

Too big (split these):
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### AGENTS.md Updates Are Critical

After each iteration, Ralph updates the relevant `AGENTS.md` files with learnings. This is key because AI coding tools automatically read these files, so future iterations (and future human developers) benefit from discovered patterns, gotchas, and conventions.

### Feedback Loops

Ralph only works if there are feedback loops:
- Typecheck catches type errors
- Tests verify behavior
- Quality checks (typecheck, lint, test) catch errors
- CI must stay green (broken code compounds across iterations)

### Browser Verification for UI Stories

Frontend stories must include "Verify in browser using dev-browser skill" in acceptance criteria. Ralph will use the dev-browser skill to navigate to the page, interact with the UI, and confirm changes work.

### Stop Condition

**Simple mode:** When all stories have `passes: true`, Ralph outputs `<promise>COMPLETE</promise>` and the loop exits.

**Multi-phase mode:** When all stories in a phase pass, workers output `<promise>PHASE_COMPLETE</promise>`. The orchestrator marks the phase complete and advances to the next phase.

## Debugging

Check current state:

```bash
# See which stories are done (phased format)
cat prd.json | jq '.phases[].userStories[] | {id, title, passes}'

# See which stories are done (legacy flat format)
cat prd.json | jq '.userStories[] | {id, title, passes}'

# See phase status
cat prd.json | jq '.phases[] | {id, title, status}'

# See orchestration state
cat prd.json | jq '.orchestration'

# See learnings from previous iterations
cat progress.txt

# Check git history
git log --oneline -10

# Check temp files from PRD or planning
ls -la .ralph-tmp/
```

## Backward Compatibility

Ralph v2 is fully backward-compatible with v1 prd.json files. If your prd.json has a top-level `userStories` array (no `phases`), Ralph automatically runs in simple mode with the original loop behavior.

## Customizing the Prompt

After copying `CLAUDE.md` to your project, customize it for your project:
- Add project-specific quality check commands
- Include codebase conventions
- Add common gotchas for your stack

## Archiving

Ralph automatically archives previous runs when you start a new feature (different `branchName`). Archives are saved to `archive/YYYY-MM-DD-feature-name/`.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)

# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs AI coding tools (Claude Code or Anthropic API) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

Ralph v2 supports multi-phase orchestration with single-call PRD creation from a feature description, complexity-based planning, phased execution (no separate review step), and rate limit handling.

## Commands

```bash
# Run the flowchart dev server
cd flowchart && npm run dev

# Build the flowchart
cd flowchart && npm run build

# Run Ralph with Claude Code (default; 30s throttle by default to avoid rate limits)
./ralph.sh [max_iterations]

# Multi-phase with PRD from feature (single LLM call)
./ralph.sh --tool claude --feature "feature description"

# Skip PRD creation, use existing prd.json
./ralph.sh --tool claude --skip-dual-prd

# Skip PRD creation and planning (execution only)
./ralph.sh --tool claude --skip-dual-prd --skip-planning

# Throttling: normal (5s), conservative (30s), minimal (60s)
./ralph.sh --tool claude --feature "feature" --throttle conservative

# Anthropic API (separate quota; requires ANTHROPIC_API_KEY and: cd scripts && npm install)
./ralph.sh --tool api --skip-dual-prd
```

## Key Files

- `ralph.sh` - Orchestrator: state machine that spawns AI instances for PRD creation, planning, and execution
- `CLAUDE.md` - Worker instructions for Claude Code and API
- `prompts/` - Prompt templates for PRD (single), phase planner, and worker
- `prd.json.example` - Example phased PRD format
- `skills/prd/` - Skill for generating PRDs
- `skills/ralph/` - Skill for converting PRDs to prd.json (supports flat and phased formats)
- `skills/dual-prd/` - Skill for dual-author PRD creation (interactive)
- `flowchart/` - Interactive React Flow diagram explaining how Ralph works

## PRD Formats

### Phased (recommended for 4+ stories)
Stories grouped into `phases[]`, each with status tracking. Used by multi-phase orchestration (plan → execute → complete → advance).

### Legacy flat (for 1-3 stories)
Top-level `userStories[]` array. Ralph auto-detects and runs simple loop mode.

## Patterns

- Each iteration spawns a fresh AI instance (Claude Code or API) with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Stories should be small enough to complete in one context window
- Always update AGENTS.md with discovered patterns for future iterations
- Workers emit `<promise>PHASE_COMPLETE</promise>` in phased mode, `<promise>COMPLETE</promise>` in legacy mode
- Final phase plans are stored in `ralph-plans/phase-{N}-plan-final.md` (git-tracked, survives interruption)
- Draft plans and merge reports remain in `.ralph-tmp/` (gitignored, ephemeral)
- Workers receive the phase plan prepended to their prompt for guaranteed visibility
- Planning is complexity-based: skip (1 story), single balanced planner (2+ stories)
- Review rejections use targeted fix planning instead of full re-plan — only failed stories are reset
- Rate limits are auto-detected and Ralph waits for the reset time (or "in N minutes") before retrying
- With `--tool claude`, if rate limited and the API is configured, Ralph auto-switches to the Anthropic API for the rest of the run
- `--throttle normal|conservative|minimal` sets delay between instances; Claude Code defaults to 30s
- `--tool api` uses the Anthropic API (usage-based; requires ANTHROPIC_API_KEY and `cd scripts && npm install`)
- All AI processes cd to SCRIPT_DIR before running, so relative paths in prompts work correctly
- Run metrics are written to `ralph-run-summary.json` on completion

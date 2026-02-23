# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs AI coding tools (Amp or Claude Code) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

Ralph v2 supports multi-phase orchestration with dual-author PRD creation, complexity-based planning, phased execution with review gates, rate limit handling, and targeted fix re-execution.

## Commands

```bash
# Run the flowchart dev server
cd flowchart && npm run dev

# Build the flowchart
cd flowchart && npm run build

# Run Ralph with Amp (default)
./ralph.sh [max_iterations]

# Run Ralph with Claude Code
./ralph.sh --tool claude [max_iterations]

# Multi-phase with dual-PRD creation
./ralph.sh --tool claude --feature "feature description"

# Skip dual-PRD, use existing prd.json
./ralph.sh --tool claude --skip-dual-prd

# Skip dual-PRD and planning
./ralph.sh --tool claude --skip-dual-prd --skip-planning

# With throttling to avoid rate limits
./ralph.sh --tool claude --feature "feature" --delay 10

# Conservative mode (30s delay between instances)
./ralph.sh --tool claude --feature "feature" --conservative
```

## Key Files

- `ralph.sh` - Orchestrator: state machine that spawns AI instances for PRD creation, planning, execution, and review
- `prompt.md` - Worker instructions for Amp
- `CLAUDE.md` - Worker instructions for Claude Code
- `prompts/` - Prompt templates for dual-PRD authors, merger, phase planner, phase reviewer, and fix planner
- `prd.json.example` - Example phased PRD format
- `skills/prd/` - Skill for generating PRDs
- `skills/ralph/` - Skill for converting PRDs to prd.json (supports flat and phased formats)
- `skills/dual-prd/` - Skill for dual-author PRD creation (interactive)
- `flowchart/` - Interactive React Flow diagram explaining how Ralph works

## PRD Formats

### Phased (recommended for 4+ stories)
Stories grouped into `phases[]`, each with status tracking and review gates. Used by multi-phase orchestration.

### Legacy flat (for 1-3 stories)
Top-level `userStories[]` array. Ralph auto-detects and runs simple loop mode.

## Patterns

- Each iteration spawns a fresh AI instance (Amp or Claude Code) with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Stories should be small enough to complete in one context window
- Always update AGENTS.md with discovered patterns for future iterations
- Workers emit `<promise>PHASE_COMPLETE</promise>` in phased mode, `<promise>COMPLETE</promise>` in legacy mode
- Final phase plans are stored in `ralph-plans/phase-{N}-plan-final.md` (git-tracked, survives interruption)
- Draft plans and merge reports remain in `.ralph-tmp/` (gitignored, ephemeral)
- Workers receive the phase plan prepended to their prompt for guaranteed visibility
- Planning is complexity-based: skip (1 story), single balanced planner (2+ stories)
- Review rejections use targeted fix planning instead of full re-plan — only failed stories are reset
- Rate limits are auto-detected and Ralph waits for the reset time before retrying
- `--delay N` throttles spawning of instances, `--conservative` uses 30s delays
- All AI processes cd to SCRIPT_DIR before running, so relative paths in prompts work correctly
- Run metrics are written to `ralph-run-summary.json` on completion

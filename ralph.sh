#!/bin/bash
# Ralph Wiggum v2 - Multi-phase autonomous AI agent loop
# Usage: ./ralph.sh [OPTIONS] [max_iterations_per_phase]
#
# Options:
#   --tool amp|claude           AI tool to use (default: amp)
#   --feature "description"     Feature description for dual-PRD creation
#   --feature-file path         File containing feature description
#   --skip-dual-prd             Skip dual-PRD creation, use existing prd.json
#   --skip-planning             Skip planning, go straight to execution
#   --max-plan-retries N        Max re-planning rounds if review fails (default: 2)
#   --delay N                   Seconds to wait between spawning instances (default: 5)
#   --max-retries N             Max retries when rate limited (default: 3)
#   --conservative              Max throttling: 30s delay between instances

set -e

# === ARGUMENT PARSING ===
TOOL="amp"
MAX_ITERATIONS=10
SKIP_DUAL_PRD=false
SKIP_PLANNING=false
FEATURE_DESC=""
FEATURE_FILE=""
MAX_PLAN_RETRIES=2
INSTANCE_DELAY=5
MAX_RATE_LIMIT_RETRIES=3

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    --feature)
      FEATURE_DESC="$2"
      shift 2
      ;;
    --feature=*)
      FEATURE_DESC="${1#*=}"
      shift
      ;;
    --feature-file)
      FEATURE_FILE="$2"
      shift 2
      ;;
    --feature-file=*)
      FEATURE_FILE="${1#*=}"
      shift
      ;;
    --skip-dual-prd)
      SKIP_DUAL_PRD=true
      shift
      ;;
    --skip-planning)
      SKIP_PLANNING=true
      shift
      ;;
    --max-plan-retries)
      MAX_PLAN_RETRIES="$2"
      shift 2
      ;;
    --max-plan-retries=*)
      MAX_PLAN_RETRIES="${1#*=}"
      shift
      ;;
    --delay)
      INSTANCE_DELAY="$2"
      shift 2
      ;;
    --delay=*)
      INSTANCE_DELAY="${1#*=}"
      shift
      ;;
    --max-retries)
      MAX_RATE_LIMIT_RETRIES="$2"
      shift 2
      ;;
    --max-retries=*)
      MAX_RATE_LIMIT_RETRIES="${1#*=}"
      shift
      ;;
    --conservative)
      INSTANCE_DELAY=30
      shift
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# Validate tool choice
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp' or 'claude'."
  exit 1
fi

# Load feature description from file if specified
if [[ -n "$FEATURE_FILE" && -z "$FEATURE_DESC" ]]; then
  if [[ ! -f "$FEATURE_FILE" ]]; then
    echo "Error: Feature file not found: $FEATURE_FILE"
    exit 1
  fi
  FEATURE_DESC=$(cat "$FEATURE_FILE")
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
TEMP_DIR="$SCRIPT_DIR/.ralph-tmp"
PLANS_DIR="$SCRIPT_DIR/ralph-plans"
PROMPTS_DIR="$SCRIPT_DIR/prompts"

mkdir -p "$TEMP_DIR"
mkdir -p "$PLANS_DIR"

# === RUN METRICS (bash 3.2 compatible — no associative arrays) ===
RUN_START_TIME=$(date +%s)
TOTAL_WORKER_ITERATIONS=0
TOTAL_PLANNING_INSTANCES=0
TOTAL_REVIEW_REJECTIONS=0

# Per-phase metrics stored as files in TEMP_DIR (bash 3.2 compatible)
get_phase_metric() {
  local NAME="$1"
  local IDX="$2"
  local FILE="$TEMP_DIR/metric-${NAME}-${IDX}"
  if [ -f "$FILE" ]; then
    cat "$FILE"
  else
    echo "0"
  fi
}

set_phase_metric() {
  local NAME="$1"
  local IDX="$2"
  local VALUE="$3"
  echo "$VALUE" > "$TEMP_DIR/metric-${NAME}-${IDX}"
}

incr_phase_metric() {
  local NAME="$1"
  local IDX="$2"
  local CURRENT
  CURRENT=$(get_phase_metric "$NAME" "$IDX")
  set_phase_metric "$NAME" "$IDX" $((CURRENT + 1))
}

write_run_summary() {
  local RUN_END_TIME
  RUN_END_TIME=$(date +%s)
  local DURATION=$((RUN_END_TIME - RUN_START_TIME))
  local TOTAL_PHASES
  TOTAL_PHASES=$(get_total_phases)
  local PHASES_COMPLETED
  PHASES_COMPLETED=$(jq '[.phases[] | select(.status == "complete")] | length' "$PRD_FILE" 2>/dev/null || echo "0")

  local PER_PHASE_JSON="{"
  local FIRST=true
  for idx in $(seq 0 $((TOTAL_PHASES - 1))); do
    if [ "$FIRST" != "true" ]; then
      PER_PHASE_JSON="${PER_PHASE_JSON},"
    fi
    FIRST=false
    local P_ITER=$(get_phase_metric iterations "$idx")
    local P_REJ=$(get_phase_metric rejections "$idx")
    local P_TYPE=$(get_phase_metric plantype "$idx")
    if [ "$P_TYPE" = "0" ]; then P_TYPE="unknown"; fi
    PER_PHASE_JSON="${PER_PHASE_JSON}\"$idx\":{\"iterations\":${P_ITER},\"rejections\":${P_REJ},\"planType\":\"${P_TYPE}\"}"
  done
  PER_PHASE_JSON="${PER_PHASE_JSON}}"

  cat > "$SCRIPT_DIR/ralph-run-summary.json" <<EOFJSON
{
  "completedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "durationSeconds": $DURATION,
  "totalPhases": $TOTAL_PHASES,
  "phasesCompleted": $PHASES_COMPLETED,
  "totalWorkerIterations": $TOTAL_WORKER_ITERATIONS,
  "totalPlanningInstances": $TOTAL_PLANNING_INSTANCES,
  "totalReviewRejections": $TOTAL_REVIEW_REJECTIONS,
  "perPhase": $PER_PHASE_JSON
}
EOFJSON

  echo "Run summary written to ralph-run-summary.json"
}

# === HELPER FUNCTIONS ===

RATE_LIMIT_PATTERNS="hit your limit|rate limit|usage limit|limit resets|too many requests|overloaded|Rate limit reached"

# Calculate seconds until a given time like "10pm" or "10:00 PM"
calculate_wait_until() {
  local RESET_TIME="$1"
  local NOW
  NOW=$(date +%s)

  # Normalize: extract hour and am/pm
  local HOUR
  HOUR=$(echo "$RESET_TIME" | grep -oE '[0-9]{1,2}' | head -1)
  local AMPM
  AMPM=$(echo "$RESET_TIME" | grep -oiE '(am|pm)' | head -1 | tr '[:upper:]' '[:lower:]')

  # Convert to 24h
  if [[ "$AMPM" == "pm" && "$HOUR" -ne 12 ]]; then
    HOUR=$((HOUR + 12))
  elif [[ "$AMPM" == "am" && "$HOUR" -eq 12 ]]; then
    HOUR=0
  fi

  # Build target timestamp for today
  local TARGET
  TARGET=$(date -v${HOUR}H -v0M -v0S +%s 2>/dev/null || date -d "today ${HOUR}:00:00" +%s 2>/dev/null || echo "0")

  # If target is in the past, it means tomorrow
  if [[ "$TARGET" -le "$NOW" ]]; then
    TARGET=$((TARGET + 86400))
  fi

  local WAIT=$((TARGET - NOW))
  # Clamp: at least 60s, at most 8 hours
  if [[ "$WAIT" -lt 60 ]]; then WAIT=60; fi
  if [[ "$WAIT" -gt 28800 ]]; then WAIT=28800; fi
  echo "$WAIT"
}

# Check if output contains rate limit indicators. Returns 0 if rate limited.
check_rate_limit() {
  local OUTPUT="$1"
  local LABEL="${2:-instance}"

  if echo "$OUTPUT" | grep -qiE "$RATE_LIMIT_PATTERNS"; then
    # Try to parse reset time from output (e.g., "resets 10pm", "resets at 10:00 PM")
    local RESET_HOUR
    RESET_HOUR=$(echo "$OUTPUT" | grep -oiE 'resets? (at )?[0-9]{1,2}(:[0-9]{2})?\s*(am|pm)' | grep -oiE '[0-9]{1,2}(:[0-9]{2})?\s*(am|pm)' | head -1)

    if [[ -n "$RESET_HOUR" ]]; then
      local WAIT_SECS
      WAIT_SECS=$(calculate_wait_until "$RESET_HOUR")
      local WAIT_MINS=$((WAIT_SECS / 60))
      echo ""
      echo "RATE LIMITED on $LABEL. Waiting until $RESET_HOUR (~${WAIT_MINS}m)..."
      sleep "$WAIT_SECS"
    else
      echo ""
      echo "RATE LIMITED on $LABEL. No reset time found — waiting 15 minutes..."
      sleep 900
    fi
    return 0  # was rate limited
  fi
  return 1  # not rate limited
}

run_instance() {
  local PROMPT_FILE="$1"
  if [[ "$TOOL" == "amp" ]]; then
    (cd "$SCRIPT_DIR" && cat "$PROMPT_FILE" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr)
  else
    (cd "$SCRIPT_DIR" && claude --dangerously-skip-permissions --print < "$PROMPT_FILE" 2>&1 | tee /dev/stderr)
  fi
}

# Run an instance with automatic rate limit detection and retry
run_instance_with_retry() {
  local PROMPT_FILE="$1"
  local LABEL="${2:-$(basename "$PROMPT_FILE")}"
  local ATTEMPT=0
  local OUTPUT

  while [[ $ATTEMPT -lt $MAX_RATE_LIMIT_RETRIES ]]; do
    OUTPUT=$(run_instance "$PROMPT_FILE") || true

    if ! check_rate_limit "$OUTPUT" "$LABEL"; then
      # Not rate limited — return output
      echo "$OUTPUT"
      return 0
    fi

    ATTEMPT=$((ATTEMPT + 1))
    echo "Retrying $LABEL (attempt $((ATTEMPT + 1)) of $MAX_RATE_LIMIT_RETRIES)..."
  done

  echo "ERROR: Still rate limited after $MAX_RATE_LIMIT_RETRIES retries on $LABEL"
  echo "$OUTPUT"
  return 1
}

run_instance_bg() {
  local PROMPT_FILE="$1"
  local OUTPUT_FILE="$2"
  if [[ "$TOOL" == "amp" ]]; then
    (cd "$SCRIPT_DIR" && cat "$PROMPT_FILE" | amp --dangerously-allow-all > "$OUTPUT_FILE" 2>&1) &
  else
    (cd "$SCRIPT_DIR" && claude --dangerously-skip-permissions --print < "$PROMPT_FILE" > "$OUTPUT_FILE" 2>&1) &
  fi
  BG_PID=$!
}

# Check background instance output for rate limits, retry if needed
check_bg_rate_limit_and_retry() {
  local PROMPT_FILE="$1"
  local OUTPUT_FILE="$2"
  local LABEL="${3:-$(basename "$PROMPT_FILE")}"

  if [[ -f "$OUTPUT_FILE" ]] && check_rate_limit "$(cat "$OUTPUT_FILE")" "$LABEL"; then
    echo "Retrying $LABEL after rate limit wait..."
    run_instance_bg "$PROMPT_FILE" "$OUTPUT_FILE"
    return 0  # was retried
  fi
  return 1  # no retry needed
}

throttle() {
  if [[ "$INSTANCE_DELAY" -gt 0 ]]; then
    echo "  (throttle: ${INSTANCE_DELAY}s delay)"
    sleep "$INSTANCE_DELAY"
  fi
}

wait_with_tailing() {
  local LABEL_A="$1" OUTPUT_A="$2" PID_A="$3"
  local LABEL_B="$4" OUTPUT_B="$5" PID_B="$6"

  touch "$OUTPUT_A" "$OUTPUT_B"

  tail -f "$OUTPUT_A" 2>/dev/null | awk -v label="$LABEL_A" '{print "  [" label "] " $0; fflush()}' &
  local TAIL_A=$!
  tail -f "$OUTPUT_B" 2>/dev/null | awk -v label="$LABEL_B" '{print "  [" label "] " $0; fflush()}' &
  local TAIL_B=$!

  wait $PID_A || true
  wait $PID_B || true

  sleep 1
  kill $TAIL_A $TAIL_B 2>/dev/null || true
}

get_orchestration_field() {
  local FIELD="$1"
  jq -r ".orchestration.$FIELD // empty" "$PRD_FILE" 2>/dev/null || echo ""
}

get_current_phase_index() {
  jq -r '.orchestration.currentPhaseIndex // 0' "$PRD_FILE" 2>/dev/null || echo "0"
}

get_phase_field() {
  local IDX="$1"
  local FIELD="$2"
  jq -r ".phases[$IDX].$FIELD // empty" "$PRD_FILE" 2>/dev/null || echo ""
}

get_total_phases() {
  jq '.phases | length' "$PRD_FILE" 2>/dev/null || echo "0"
}

all_stories_in_phase_pass() {
  local IDX="$1"
  local FAILING=$(jq "[.phases[$IDX].userStories[] | select(.passes == false)] | length" "$PRD_FILE" 2>/dev/null || echo "1")
  [[ "$FAILING" == "0" ]]
}

all_phases_complete() {
  local INCOMPLETE=$(jq '[.phases[] | select(.status != "complete")] | length' "$PRD_FILE" 2>/dev/null || echo "1")
  [[ "$INCOMPLETE" == "0" ]]
}

has_phases() {
  jq -e '.phases' "$PRD_FILE" > /dev/null 2>&1
}

update_prd_field() {
  local FILTER="$1"
  local TMP="$TEMP_DIR/prd_update.json"
  jq "$FILTER" "$PRD_FILE" > "$TMP" && mv "$TMP" "$PRD_FILE"
}

generate_prompt() {
  local TEMPLATE="$1"
  local OUTPUT="$2"
  local CONTENT
  CONTENT=$(cat "$TEMPLATE")

  # Replace placeholders using bash parameter expansion (safe for all characters)
  if [[ -n "$FEATURE_DESC" ]]; then
    CONTENT="${CONTENT//\{\{FEATURE\}\}/$FEATURE_DESC}"
  fi

  local PHASE_IDX
  PHASE_IDX=$(get_current_phase_index)
  CONTENT="${CONTENT//\{\{PHASE_INDEX\}\}/$PHASE_IDX}"

  local PHASE_TITLE
  PHASE_TITLE=$(get_phase_field "$PHASE_IDX" "title")
  CONTENT="${CONTENT//\{\{PHASE_TITLE\}\}/$PHASE_TITLE}"

  echo "$CONTENT" > "$OUTPUT"
}

# === ARCHIVE PREVIOUS RUN ===

archive_if_needed() {
  if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
    local CURRENT_BRANCH
    CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
    local LAST_BRANCH
    LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

    if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
      local DATE
      DATE=$(date +%Y-%m-%d)
      local FOLDER_NAME
      FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
      local ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

      echo "Archiving previous run: $LAST_BRANCH"
      mkdir -p "$ARCHIVE_FOLDER"
      [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
      [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
      echo "   Archived to: $ARCHIVE_FOLDER"

      echo "# Ralph Progress Log" > "$PROGRESS_FILE"
      echo "Started: $(date)" >> "$PROGRESS_FILE"
      echo "---" >> "$PROGRESS_FILE"
    fi
  fi
}

track_branch() {
  if [ -f "$PRD_FILE" ]; then
    local CURRENT_BRANCH
    CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
    if [ -n "$CURRENT_BRANCH" ]; then
      echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
    fi
  fi
}

init_progress() {
  if [ ! -f "$PROGRESS_FILE" ]; then
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
}

# === DUAL PRD CREATION ===

do_dual_prd() {
  echo ""
  echo "==============================================================="
  echo "  DUAL PRD CREATION"
  echo "==============================================================="

  if [[ -z "$FEATURE_DESC" ]]; then
    echo "Error: No feature description provided."
    echo "Use --feature \"description\" or --feature-file path"
    exit 1
  fi

  # Generate Author A prompt (technical depth)
  generate_prompt "$PROMPTS_DIR/prd-author.md" "$TEMP_DIR/prd-author-a-prompt.md"
  sed -i '' 's|{{LENS}}|Focus on TECHNICAL DEPTH. Prioritize: database schema design, API contracts, data flow, error handling, performance considerations, edge cases in backend logic. Think about what could go wrong technically and what the non-obvious dependencies are.|g' "$TEMP_DIR/prd-author-a-prompt.md"
  sed -i '' 's|{{OUTPUT_FILE}}|.ralph-tmp/prd-v1.md|g' "$TEMP_DIR/prd-author-a-prompt.md"
  sed -i '' 's|{{AUTHOR_ID}}|Author A (Technical)|g' "$TEMP_DIR/prd-author-a-prompt.md"

  # Generate Author B prompt (user experience)
  generate_prompt "$PROMPTS_DIR/prd-author.md" "$TEMP_DIR/prd-author-b-prompt.md"
  sed -i '' 's|{{LENS}}|Focus on USER EXPERIENCE. Prioritize: user workflows, UI edge cases, accessibility, error messages, loading states, empty states, progressive disclosure. Think about what the user actually needs and what the most common user journeys are.|g' "$TEMP_DIR/prd-author-b-prompt.md"
  sed -i '' 's|{{OUTPUT_FILE}}|.ralph-tmp/prd-v2.md|g' "$TEMP_DIR/prd-author-b-prompt.md"
  sed -i '' 's|{{AUTHOR_ID}}|Author B (UX)|g' "$TEMP_DIR/prd-author-b-prompt.md"

  echo "Spawning PRD Author A (technical focus)..."
  run_instance_bg "$TEMP_DIR/prd-author-a-prompt.md" "$TEMP_DIR/prd-author-a-output.txt"
  PID_A=$BG_PID
  echo "  PID: $PID_A"

  throttle

  echo "Spawning PRD Author B (UX focus)..."
  run_instance_bg "$TEMP_DIR/prd-author-b-prompt.md" "$TEMP_DIR/prd-author-b-output.txt"
  PID_B=$BG_PID
  echo "  PID: $PID_B"

  echo "Waiting for both PRD authors to finish..."
  wait_with_tailing "Author A" "$TEMP_DIR/prd-author-a-output.txt" "$PID_A" \
                    "Author B" "$TEMP_DIR/prd-author-b-output.txt" "$PID_B"

  # Check for rate limits and retry if needed
  if check_bg_rate_limit_and_retry "$TEMP_DIR/prd-author-a-prompt.md" "$TEMP_DIR/prd-author-a-output.txt" "PRD Author A"; then
    wait $BG_PID || true
  fi
  if check_bg_rate_limit_and_retry "$TEMP_DIR/prd-author-b-prompt.md" "$TEMP_DIR/prd-author-b-output.txt" "PRD Author B"; then
    wait $BG_PID || true
  fi

  # Verify outputs exist
  if [[ ! -f "$TEMP_DIR/prd-v1.md" ]]; then
    echo "WARNING: PRD Author A did not produce output at .ralph-tmp/prd-v1.md"
    echo "Check $TEMP_DIR/prd-author-a-output.txt for details"
  fi
  if [[ ! -f "$TEMP_DIR/prd-v2.md" ]]; then
    echo "WARNING: PRD Author B did not produce output at .ralph-tmp/prd-v2.md"
    echo "Check $TEMP_DIR/prd-author-b-output.txt for details"
  fi

  echo "Both PRD authors complete."
}

do_prd_merge() {
  echo ""
  echo "==============================================================="
  echo "  PRD MERGE"
  echo "==============================================================="

  generate_prompt "$PROMPTS_DIR/prd-merger.md" "$TEMP_DIR/prd-merger-prompt.md"

  echo "Spawning PRD Merger..."
  throttle
  OUTPUT=$(run_instance_with_retry "$TEMP_DIR/prd-merger-prompt.md" "PRD Merger") || true

  if [ ! -f "$PRD_FILE" ]; then
    echo "ERROR: PRD merger did not produce prd.json"
    exit 1
  fi

  # Mark dual PRD as complete
  update_prd_field '.orchestration.dualPrdComplete = true'

  echo "PRD merge complete. prd.json created with phases."
}

# === PHASE PLANNING ===

do_single_plan() {
  local PHASE_IDX="$1"
  local PHASE_TITLE
  PHASE_TITLE=$(get_phase_field "$PHASE_IDX" "title")

  echo ""
  echo "==============================================================="
  echo "  SINGLE PLANNING: Phase $((PHASE_IDX + 1)) - $PHASE_TITLE"
  echo "==============================================================="

  # Update phase status
  update_prd_field ".phases[$PHASE_IDX].status = \"planning\""

  # Generate single planner prompt with balanced lens
  generate_prompt "$PROMPTS_DIR/phase-planner.md" "$TEMP_DIR/phase-planner-single-prompt.md"
  sed -i '' 's|{{LENS}}|Create a balanced implementation plan. Consider both simplicity and robustness. Prefer reusing existing patterns while also handling important edge cases. Choose the most practical approach that meets all acceptance criteria.|g' "$TEMP_DIR/phase-planner-single-prompt.md"
  sed -i '' "s|{{OUTPUT_FILE}}|ralph-plans/phase-${PHASE_IDX}-plan-final.md|g" "$TEMP_DIR/phase-planner-single-prompt.md"
  sed -i '' 's|{{PLANNER_ID}}|Planner (Balanced)|g' "$TEMP_DIR/phase-planner-single-prompt.md"

  echo "Spawning single Phase Planner..."
  throttle
  OUTPUT=$(run_instance_with_retry "$TEMP_DIR/phase-planner-single-prompt.md" "Phase Planner") || true

  TOTAL_PLANNING_INSTANCES=$((TOTAL_PLANNING_INSTANCES + 1))

  # Increment plan version
  local CURRENT_VERSION
  CURRENT_VERSION=$(get_phase_field "$PHASE_IDX" "planVersion")
  local NEW_VERSION=$((CURRENT_VERSION + 1))
  update_prd_field ".phases[$PHASE_IDX].planVersion = $NEW_VERSION"
  update_prd_field ".phases[$PHASE_IDX].status = \"in_progress\""
  update_prd_field ".orchestration.status = \"executing\""

  echo "Single plan complete. Plan version: $NEW_VERSION"
}

# Route planning based on phase complexity
do_phase_planning() {
  local PHASE_IDX="$1"
  local STORY_COUNT
  STORY_COUNT=$(jq ".phases[$PHASE_IDX].userStories | length" "$PRD_FILE" 2>/dev/null || echo "0")

  if [[ "$STORY_COUNT" -le 1 ]]; then
    echo "Phase has $STORY_COUNT story — skipping planning (acceptance criteria sufficient)."
    set_phase_metric plantype "$PHASE_IDX" "skip"
    update_prd_field ".phases[$PHASE_IDX].status = \"in_progress\""
    update_prd_field ".orchestration.status = \"executing\""
  else
    echo "Phase has $STORY_COUNT stories — using single planner."
    set_phase_metric plantype "$PHASE_IDX" "single"
    do_single_plan "$PHASE_IDX"
  fi
}

# === EXECUTION ===

do_execute_phase() {
  local PHASE_IDX="$1"
  local PHASE_TITLE
  PHASE_TITLE=$(get_phase_field "$PHASE_IDX" "title")

  echo ""
  echo "==============================================================="
  echo "  EXECUTING: Phase $((PHASE_IDX + 1)) - $PHASE_TITLE"
  echo "==============================================================="

  update_prd_field ".phases[$PHASE_IDX].status = \"in_progress\""
  update_prd_field ".orchestration.status = \"executing\""

  # Build augmented worker prompt with phase plan prepended
  local WORKER_PROMPT="$TEMP_DIR/worker-prompt.md"
  local PLAN_FILE="$PLANS_DIR/phase-${PHASE_IDX}-plan-final.md"
  # Fall back to old location if new location doesn't exist
  if [[ ! -f "$PLAN_FILE" ]]; then
    PLAN_FILE="$TEMP_DIR/phase-${PHASE_IDX}-plan-final.md"
  fi

  for i in $(seq 1 $MAX_ITERATIONS); do
    TOTAL_WORKER_ITERATIONS=$((TOTAL_WORKER_ITERATIONS + 1))
    incr_phase_metric iterations "$PHASE_IDX"

    echo ""
    echo "--- Phase $((PHASE_IDX + 1)), Iteration $i of $MAX_ITERATIONS ($TOOL) ---"

    # Prepend phase plan to worker instructions
    if [[ "$TOOL" == "amp" ]]; then
      local BASE_PROMPT="$SCRIPT_DIR/prompt.md"
    else
      local BASE_PROMPT="$SCRIPT_DIR/CLAUDE.md"
    fi

    if [[ -f "$PLAN_FILE" ]]; then
      echo "## Phase Implementation Plan" > "$WORKER_PROMPT"
      echo "" >> "$WORKER_PROMPT"
      echo "The following plan was created for this phase. Use it as implementation guidance." >> "$WORKER_PROMPT"
      echo "" >> "$WORKER_PROMPT"
      cat "$PLAN_FILE" >> "$WORKER_PROMPT"
      echo "" >> "$WORKER_PROMPT"
      echo "---" >> "$WORKER_PROMPT"
      echo "" >> "$WORKER_PROMPT"
      cat "$BASE_PROMPT" >> "$WORKER_PROMPT"
    else
      cp "$BASE_PROMPT" "$WORKER_PROMPT"
    fi

    throttle

    if [[ "$TOOL" == "amp" ]]; then
      OUTPUT=$(cd "$SCRIPT_DIR" && cat "$WORKER_PROMPT" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
    else
      OUTPUT=$(cd "$SCRIPT_DIR" && claude --dangerously-skip-permissions --print < "$WORKER_PROMPT" 2>&1 | tee /dev/stderr) || true
    fi

    # Check for rate limiting — wait and retry this iteration
    if check_rate_limit "$OUTPUT" "Worker (Phase $((PHASE_IDX + 1)), Iter $i)"; then
      echo "Retrying iteration after rate limit wait..."
      # Re-run this iteration after the wait
      if [[ "$TOOL" == "amp" ]]; then
        OUTPUT=$(cd "$SCRIPT_DIR" && cat "$WORKER_PROMPT" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
      else
        OUTPUT=$(cd "$SCRIPT_DIR" && claude --dangerously-skip-permissions --print < "$WORKER_PROMPT" 2>&1 | tee /dev/stderr) || true
      fi
    fi

    # Check for phase completion signal
    if echo "$OUTPUT" | grep -q "<promise>PHASE_COMPLETE</promise>"; then
      echo ""
      echo "Phase $((PHASE_IDX + 1)) completed by worker!"
      return 0
    fi

    # Also check for legacy COMPLETE signal (backward compatibility)
    if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
      echo ""
      echo "Phase $((PHASE_IDX + 1)) completed by worker!"
      return 0
    fi

    # Fallback: check if all stories in phase pass
    if all_stories_in_phase_pass "$PHASE_IDX"; then
      echo ""
      echo "All stories in phase $((PHASE_IDX + 1)) pass!"
      return 0
    fi

    sleep 2
  done

  echo ""
  echo "WARNING: Phase $((PHASE_IDX + 1)) reached max iterations ($MAX_ITERATIONS) without completing."
  return 1
}

# === PHASE REVIEW ===

do_phase_review() {
  local PHASE_IDX="$1"
  local PHASE_TITLE
  PHASE_TITLE=$(get_phase_field "$PHASE_IDX" "title")

  echo ""
  echo "==============================================================="
  echo "  PHASE REVIEW: Phase $((PHASE_IDX + 1)) - $PHASE_TITLE"
  echo "==============================================================="

  update_prd_field ".phases[$PHASE_IDX].status = \"review\""
  update_prd_field ".orchestration.status = \"phase_review\""

  generate_prompt "$PROMPTS_DIR/phase-reviewer.md" "$TEMP_DIR/phase-reviewer-prompt.md"

  echo "Spawning Phase Reviewer..."
  throttle
  OUTPUT=$(run_instance_with_retry "$TEMP_DIR/phase-reviewer-prompt.md" "Phase Reviewer") || true

  local APPROVED
  APPROVED=$(get_phase_field "$PHASE_IDX" "reviewApproved")
  if [[ "$APPROVED" == "true" ]]; then
    echo "Phase $((PHASE_IDX + 1)) APPROVED by reviewer."
    return 0
  else
    echo "Phase $((PHASE_IDX + 1)) review flagged issues."
    return 1
  fi
}

# === TARGETED FIX ===

do_targeted_fix() {
  local PHASE_IDX="$1"
  local PHASE_TITLE
  PHASE_TITLE=$(get_phase_field "$PHASE_IDX" "title")

  echo ""
  echo "==============================================================="
  echo "  TARGETED FIX: Phase $((PHASE_IDX + 1)) - $PHASE_TITLE"
  echo "==============================================================="

  update_prd_field ".phases[$PHASE_IDX].status = \"in_progress\""

  generate_prompt "$PROMPTS_DIR/phase-fix-planner.md" "$TEMP_DIR/phase-fix-planner-prompt.md"

  echo "Spawning Fix Planner..."
  throttle
  OUTPUT=$(run_instance_with_retry "$TEMP_DIR/phase-fix-planner-prompt.md" "Fix Planner") || true

  echo "Targeted fix planning complete."
}

# === LEGACY MODE (flat prd.json without phases) ===

do_legacy_loop() {
  echo "Detected legacy prd.json format (no phases). Running simple loop."
  echo ""

  for i in $(seq 1 $MAX_ITERATIONS); do
    echo ""
    echo "==============================================================="
    echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
    echo "==============================================================="

    throttle

    if [[ "$TOOL" == "amp" ]]; then
      OUTPUT=$(cd "$SCRIPT_DIR" && cat "$SCRIPT_DIR/prompt.md" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
    else
      OUTPUT=$(cd "$SCRIPT_DIR" && claude --dangerously-skip-permissions --print < "$SCRIPT_DIR/CLAUDE.md" 2>&1 | tee /dev/stderr) || true
    fi

    # Check for rate limiting — wait and retry
    if check_rate_limit "$OUTPUT" "Legacy Worker (Iter $i)"; then
      echo "Retrying iteration after rate limit wait..."
      if [[ "$TOOL" == "amp" ]]; then
        OUTPUT=$(cd "$SCRIPT_DIR" && cat "$SCRIPT_DIR/prompt.md" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
      else
        OUTPUT=$(cd "$SCRIPT_DIR" && claude --dangerously-skip-permissions --print < "$SCRIPT_DIR/CLAUDE.md" 2>&1 | tee /dev/stderr) || true
      fi
    fi

    if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
      echo ""
      echo "Ralph completed all tasks!"
      echo "Completed at iteration $i of $MAX_ITERATIONS"
      exit 0
    fi

    echo "Iteration $i complete. Continuing..."
    sleep 2
  done

  echo ""
  echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
  echo "Check $PROGRESS_FILE for status."
  exit 1
}

# === MAIN ORCHESTRATION ===

main() {
  echo "Starting Ralph v2 - Tool: $TOOL - Max iterations per phase: $MAX_ITERATIONS - Delay: ${INSTANCE_DELAY}s"

  # Archive previous run if branch changed
  archive_if_needed

  # === STEP 1: Dual PRD Creation ===
  if [[ "$SKIP_DUAL_PRD" == "false" && -n "$FEATURE_DESC" ]]; then
    do_dual_prd
    do_prd_merge
  elif [[ "$SKIP_DUAL_PRD" == "false" && ! -f "$PRD_FILE" ]]; then
    echo "Error: No prd.json found and no --feature provided."
    echo "Either provide --feature \"description\" or --skip-dual-prd with an existing prd.json"
    exit 1
  fi

  # Track branch and init progress
  track_branch
  init_progress

  # Check if this is a legacy (non-phased) prd.json
  if [ -f "$PRD_FILE" ] && ! has_phases; then
    do_legacy_loop
    return
  fi

  # === STEP 2: Phase Loop ===
  local TOTAL_PHASES
  TOTAL_PHASES=$(get_total_phases)

  if [[ "$TOTAL_PHASES" == "0" ]]; then
    echo "Error: prd.json has no phases defined."
    exit 1
  fi

  echo "Found $TOTAL_PHASES phases in prd.json."

  local PLAN_RETRIES=0
  local LAST_PHASE_IDX=-1

  while true; do
    local PHASE_IDX
    PHASE_IDX=$(get_current_phase_index)

    # Reset retry counter when advancing to a new phase
    if [[ "$PHASE_IDX" != "$LAST_PHASE_IDX" ]]; then
      PLAN_RETRIES=0
      LAST_PHASE_IDX="$PHASE_IDX"
    fi

    # Check if all phases are done
    if all_phases_complete; then
      echo ""
      echo "==============================================================="
      echo "  ALL PHASES COMPLETE!"
      echo "==============================================================="
      write_run_summary
      exit 0
    fi

    # Bounds check
    if [[ "$PHASE_IDX" -ge "$TOTAL_PHASES" ]]; then
      echo "All phases processed."
      write_run_summary
      exit 0
    fi

    local PHASE_STATUS
    PHASE_STATUS=$(get_phase_field "$PHASE_IDX" "status")
    local PHASE_TITLE
    PHASE_TITLE=$(get_phase_field "$PHASE_IDX" "title")

    echo ""
    echo "Phase $((PHASE_IDX + 1))/$TOTAL_PHASES: $PHASE_TITLE (status: $PHASE_STATUS)"

    # === Planning (unless skipped or already in_progress) ===
    if [[ "$SKIP_PLANNING" == "false" && "$PHASE_STATUS" != "in_progress" && "$PHASE_STATUS" != "review" && "$PHASE_STATUS" != "complete" ]]; then
      do_phase_planning "$PHASE_IDX"
    fi

    # === Execution ===
    if [[ "$PHASE_STATUS" != "review" && "$PHASE_STATUS" != "complete" ]]; then
      do_execute_phase "$PHASE_IDX" || true
    fi

    # === Review ===
    if do_phase_review "$PHASE_IDX"; then
      # Approved - mark complete and advance
      update_prd_field ".phases[$PHASE_IDX].status = \"complete\""

      local NEXT_IDX=$((PHASE_IDX + 1))
      if [[ "$NEXT_IDX" -lt "$TOTAL_PHASES" ]]; then
        update_prd_field ".orchestration.currentPhaseIndex = $NEXT_IDX"
        echo "Advancing to phase $((NEXT_IDX + 1))."
      fi
    else
      # Not approved - targeted fix and re-execute (up to max retries)
      PLAN_RETRIES=$((PLAN_RETRIES + 1))
      TOTAL_REVIEW_REJECTIONS=$((TOTAL_REVIEW_REJECTIONS + 1))
      incr_phase_metric rejections "$PHASE_IDX"
      if [[ "$PLAN_RETRIES" -ge "$MAX_PLAN_RETRIES" ]]; then
        echo "WARNING: Phase $((PHASE_IDX + 1)) failed review $PLAN_RETRIES times. Proceeding anyway."
        update_prd_field ".phases[$PHASE_IDX].status = \"complete\""

        local NEXT_IDX=$((PHASE_IDX + 1))
        if [[ "$NEXT_IDX" -lt "$TOTAL_PHASES" ]]; then
          update_prd_field ".orchestration.currentPhaseIndex = $NEXT_IDX"
        fi
      else
        echo "Running targeted fixes for phase $((PHASE_IDX + 1)) (retry $PLAN_RETRIES of $MAX_PLAN_RETRIES)..."

        # Use targeted fix planner instead of full re-plan
        do_targeted_fix "$PHASE_IDX"

        # Re-execute (only stories with passes:false will be worked on)
        do_execute_phase "$PHASE_IDX" || true

        # Will loop back and review again
        continue
      fi
    fi
  done
}

main

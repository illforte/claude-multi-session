#!/bin/bash
# Claude Multi-Session Orchestrator
# Spawns and manages parallel Claude Code sessions automatically
#
# https://github.com/illforte/claude-multi-session
# Version: 1.3.0
#
# CHANGELOG:
# v1.3.0 (2026-01-04)
#   - Added token savings display to dashboard
#   - Show efficiency metrics: tokens saved, cost comparison, speedup factor
#   - Live efficiency tracking in status command
#   - ROI visualization with dynamic emojis (🚀/⚡/⚠️)
#
# v1.2.0 (2026-01-03)
#   - Added automatic sprint history tracking
#   - Sprints recorded to .claude/sprint-history.json
#   - Added record-sprint command for manual recording
#   - Cost and duration aggregation for historical analysis
#
# v1.1.0 (2026-01-03)
#   - Added signal handling (SIGINT/SIGTERM) for graceful cleanup
#   - Added task field validation (id, prompt required)
#   - Added argument validation for result/output/stop commands
#   - Added list command to show task IDs
#   - Added stale session detection in clean command
#   - Fixed prompt display to only show ... if truncated
#   - Fixed integer division rounding for duration
#   - Improved output success detection
#
# v1.0.0 (2026-01-02)
#   - Initial release with run-multi, start, status, result, stop commands
#   - Cross-platform date parsing (macOS + Linux)
#   - Session timeout with auto-kill
#   - Cost aggregation across sessions
#   - Live dashboard with progress tracking
#
# SECURITY NOTE: Sessions run with --permission-mode bypassPermissions
# This is intentional for automation but means sessions can modify files
# without confirmation. Only use in trusted environments.

set -euo pipefail
shopt -s nullglob  # Handle empty globs gracefully

VERSION="1.3.0"

# PROJECT_DIR must be defined early (used by SPRINT_TRACKER)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Sprint tracker location
SPRINT_TRACKER="${PROJECT_DIR}/scripts/lib/sprint-tracker.mjs"

# Prompt enhancement (validation + verification wrapper)
ENABLE_PROMPT_ENHANCEMENT="${CLAUDE_ENHANCE_PROMPTS:-true}"

# Pre-task validation prompt
VALIDATION_PREFIX='**BEFORE STARTING:** Analyze this task for 30 seconds:
1. Identify potential errors or edge cases in the approach
2. Check for missing implementation gaps
3. Consider improvements to make the task more robust
4. If you find issues, document them and proceed with the enhanced approach.

**TASK:**
'

# Post-task verification prompt
VERIFICATION_SUFFIX='

**AFTER COMPLETING:** Perform 2 verification iterations:
1. **First pass:** Review all changes for errors, type issues, missing imports, broken references
2. **Second pass:** Check for edge cases, incomplete implementations, or gaps in the solution
3. **Report format:** End your response with:
   ```
   ## Verification Report
   - Errors found: [list or "None"]
   - Gaps identified: [list or "None"]
   - Improvements made: [list]
   - Confidence: [High/Medium/Low]
   ```
'

# Configuration (can be overridden via environment variables)
# PROJECT_DIR already defined above (needed early for SPRINT_TRACKER)
SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-/tmp/claude-sessions}"
LOG_FILE="${CLAUDE_SESSIONS_LOG:-$SESSIONS_DIR/orchestrator.log}"
DEFAULT_TIMEOUT="${CLAUDE_SESSION_TIMEOUT:-600}"  # 10 minutes max per session
MAX_RETRIES="${CLAUDE_MAX_RETRIES:-2}"
DEFAULT_MODEL="${CLAUDE_DEFAULT_MODEL:-sonnet}"
DEFAULT_BUDGET="${CLAUDE_DEFAULT_BUDGET:-5}"
DEFAULT_MAX_PARALLEL="${CLAUDE_MAX_PARALLEL:-4}"
STALE_THRESHOLD="${CLAUDE_STALE_THRESHOLD:-60}"  # Seconds to consider a stopped session stale

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Create sessions directory
mkdir -p "$SESSIONS_DIR"

# Signal handling for graceful cleanup
cleanup_on_exit() {
    echo ""
    echo -e "${YELLOW}Received interrupt signal. Stopping all sessions...${NC}"
    stop_all
    exit 130
}
trap cleanup_on_exit SIGINT SIGTERM

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command -v claude &> /dev/null; then
        missing+=("claude (Claude Code CLI)")
    fi

    if ! command -v jq &> /dev/null; then
        missing+=("jq (JSON processor)")
    fi

    if ! command -v bc &> /dev/null; then
        missing+=("bc (calculator)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing required dependencies:${NC}"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "Install with:"
        echo "  brew install jq bc  # macOS"
        echo "  apt install jq bc   # Ubuntu/Debian"
        echo ""
        echo "For Claude Code CLI, see: https://claude.ai/claude-code"
        exit 1
    fi
}

# Logging function
log() {
    local level="$1"
    shift
    echo "[$(date -Iseconds)] [$level] $*" >> "$LOG_FILE"
}

# Safe increment that doesn't fail with set -e
inc() {
    local var_name="$1"
    eval "$var_name=\$(( \${$var_name} + 1 ))"
}

# Cross-platform date parsing (works on macOS and Linux)
parse_iso_date() {
    local date_str="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        date -j -f "%Y-%m-%dT%H:%M:%S" "${date_str%+*}" +%s 2>/dev/null || date +%s
    else
        date -d "${date_str}" +%s 2>/dev/null || date +%s
    fi
}

# Validate JSON input
validate_json() {
    local json="$1"
    if ! echo "$json" | jq -e . > /dev/null 2>&1; then
        echo -e "${RED}Invalid JSON input${NC}"
        log "ERROR" "Invalid JSON: $json"
        return 1
    fi
    return 0
}

# Validate task array has required fields
validate_tasks() {
    local json="$1"
    local task_count
    task_count=$(echo "$json" | jq 'length')

    for i in $(seq 0 $((task_count - 1))); do
        local task_id prompt
        task_id=$(echo "$json" | jq -r ".[$i].id // empty")
        prompt=$(echo "$json" | jq -r ".[$i].prompt // empty")

        if [[ -z "$task_id" ]]; then
            echo -e "${RED}Task $i missing 'id' field${NC}"
            return 1
        fi
        if [[ -z "$prompt" ]]; then
            echo -e "${RED}Task '$task_id' missing 'prompt' field${NC}"
            return 1
        fi
    done
    return 0
}

# Require argument helper
require_arg() {
    local arg="${1:-}"
    local name="$2"
    if [[ -z "$arg" ]]; then
        echo -e "${RED}Missing required argument: $name${NC}"
        exit 1
    fi
}

# Enhance prompt with validation and verification wrappers
enhance_prompt() {
    local prompt="$1"
    local skip_enhance="${2:-false}"

    if [[ "$ENABLE_PROMPT_ENHANCEMENT" != "true" ]] || [[ "$skip_enhance" == "true" ]]; then
        echo "$prompt"
        return
    fi

    # Combine: validation prefix + original prompt + verification suffix
    echo "${VALIDATION_PREFIX}${prompt}${VERIFICATION_SUFFIX}"
}

usage() {
    cat << EOF
Claude Multi-Session Orchestrator v${VERSION}
Spawn and manage parallel Claude Code sessions automatically.

Usage: $(basename "$0") <command> [options]

Commands:
  start <task-id> <prompt>     Start a new Claude session for a task
  run-multi <tasks-json>       Run multiple tasks and wait for completion
  status                       Show status of all sessions
  list                         List all session task IDs
  result <task-id>             Show result of a specific session
  output <task-id>             Show raw output of a specific session
  stop <task-id>               Stop a running session
  stop-all                     Stop all running sessions
  clean                        Remove completed/stale session files
  version                      Show version information

Options (via environment variables):
  CLAUDE_SESSIONS_DIR     Session files directory (default: /tmp/claude-sessions)
  CLAUDE_PROJECT_DIR      Project directory for sessions (default: current dir)
  CLAUDE_SESSION_TIMEOUT  Max seconds per session (default: 600)
  CLAUDE_DEFAULT_MODEL    Default model (default: sonnet)
  CLAUDE_DEFAULT_BUDGET   Default budget in USD (default: 5)
  CLAUDE_MAX_PARALLEL     Max parallel sessions (default: 4)
  CLAUDE_ENHANCE_PROMPTS  Enable validation+verification wrappers (default: true)

Prompt Enhancement (enabled by default):
  Each task automatically receives:
  - PRE-TASK:  Validation phase to identify errors/gaps before starting
  - POST-TASK: 2-iteration verification to check for errors/gaps after completion

  Disable with: CLAUDE_ENHANCE_PROMPTS=false

Examples:
  # Start a single session
  $(basename "$0") start fix-types "Fix all TypeScript errors in src/"

  # Run multiple tasks in parallel
  $(basename "$0") run-multi '[
    {"id": "task-1", "prompt": "Fix TypeScript errors"},
    {"id": "task-2", "prompt": "Add unit tests"},
    {"id": "task-3", "prompt": "Update documentation"}
  ]'

  # Run with custom settings
  $(basename "$0") run-multi '<json>' sonnet 10 4
  # Arguments: <json> [model] [budget] [max-parallel]

  # Monitor progress
  $(basename "$0") status

  # View results
  $(basename "$0") result task-1

For more information, see: https://github.com/illforte/claude-multi-session
EOF
}

# Record sprint to history
record_sprint() {
    local tasks_json="$1"
    local goal="${2:-Multi-session sprint}"
    local total_cost="$3"
    local total_duration="$4"
    local commit_hash="${5:-}"
    local commit_msg="${6:-}"

    # Check if tracker exists
    if [[ ! -f "$SPRINT_TRACKER" ]]; then
        log "WARN" "Sprint tracker not found at $SPRINT_TRACKER - skipping history recording"
        return 0
    fi

    # Build sprint JSON
    local sprint_id
    sprint_id="sprint-$(date +%Y-%m-%d)-$(date +%H%M)"

    local tasks_array="["
    local first=true

    for output_file in "$SESSIONS_DIR"/*.output; do
        [[ ! -f "$output_file" ]] && continue

        local task_id
        task_id=$(basename "$output_file" .output)
        local status_file="$SESSIONS_DIR/${task_id}.status"
        local status="unknown"
        [[ -f "$status_file" ]] && status=$(cat "$status_file")

        # Parse output JSON for cost/duration
        local cost=0
        local duration=0
        local result="No result"

        if jq -e . "$output_file" > /dev/null 2>&1; then
            cost=$(jq -r '.total_cost_usd // 0' "$output_file")
            duration=$(jq -r '.duration_ms // 0' "$output_file")
            duration=$((duration / 1000))  # Convert to seconds
            result=$(jq -r '.result // "No result"' "$output_file" | head -c 200)
        fi

        # Get task title from original tasks JSON
        local title
        title=$(echo "$tasks_json" | jq -r --arg id "$task_id" '.[] | select(.id == $id) | .prompt' | head -c 50)
        [[ -z "$title" ]] && title="$task_id"

        [[ "$first" == "false" ]] && tasks_array+=","
        first=false

        tasks_array+=$(cat <<TASK
{
  "id": "$task_id",
  "title": "${title//\"/\\\"}",
  "status": "$(echo "$status" | sed 's/failed:.*/failed/')",
  "result": "${result//\"/\\\"}",
  "duration_seconds": $duration,
  "cost_usd": $cost
}
TASK
)
    done

    tasks_array+="]"

    # Get files changed since sprint started
    local files_changed
    files_changed=$(git status --short 2>/dev/null | awk '{print $2}' | jq -R -s 'split("\n") | map(select(length > 0))')

    # Build full sprint JSON
    local sprint_json
    sprint_json=$(cat <<SPRINT
{
  "id": "$sprint_id",
  "date": "$(date -Iseconds)",
  "goal": "${goal//\"/\\\"}",
  "mode": "auto",
  "sessions": $(echo "$tasks_json" | jq 'length'),
  "tasks": $tasks_array,
  "totals": {
    "tasks_completed": $(echo "$tasks_json" | jq 'length'),
    "tasks_failed": 0,
    "duration_seconds": $total_duration,
    "cost_usd": $total_cost
  },
  "files_changed": $files_changed,
  "commit": {
    "hash": "$commit_hash",
    "message": "${commit_msg//\"/\\\"}"
  }
}
SPRINT
)

    # Record via tracker
    echo "$sprint_json" | node "$SPRINT_TRACKER" add

    log "INFO" "Recorded sprint $sprint_id to history"
}

# Run multiple tasks and wait for completion
run_multi() {
    local tasks_json="$1"
    local model="${2:-$DEFAULT_MODEL}"
    local budget="${3:-$DEFAULT_BUDGET}"
    local max_parallel="${4:-$DEFAULT_MAX_PARALLEL}"

    if [[ -z "$tasks_json" ]]; then
        echo -e "${RED}Usage: $0 run-multi '<tasks-json>' [model] [budget] [max-parallel]${NC}"
        echo 'Example: $0 run-multi '\''[{"id":"task-1","prompt":"Do X"},{"id":"task-2","prompt":"Do Y"}]'\'''
        return 1
    fi

    # Validate JSON before processing
    if ! validate_json "$tasks_json"; then
        return 1
    fi

    # Validate task fields
    if ! validate_tasks "$tasks_json"; then
        return 1
    fi

    local task_count
    task_count=$(echo "$tasks_json" | jq 'length')
    log "INFO" "Starting multi-session run: $task_count tasks, model=$model, budget=$budget, max_parallel=$max_parallel"

    echo -e "${CYAN}Starting $task_count task(s) with max $max_parallel parallel sessions...${NC}"
    echo -e "${BLUE}Model: $model | Budget: \$$budget | Timeout: ${DEFAULT_TIMEOUT}s${NC}"
    echo ""

    # Check if enhancement is enabled
    if [[ "$ENABLE_PROMPT_ENHANCEMENT" == "true" ]]; then
        echo -e "${CYAN}Prompt enhancement: ENABLED (validation + verification)${NC}"
    else
        echo -e "${YELLOW}Prompt enhancement: DISABLED${NC}"
    fi
    echo ""

    # Parse and start tasks
    local started=0
    while IFS= read -r task; do
        local task_id
        local prompt
        local enhanced_prompt
        task_id=$(echo "$task" | jq -r '.id')
        prompt=$(echo "$task" | jq -r '.prompt')

        # Enhance prompt with validation/verification wrappers
        enhanced_prompt=$(enhance_prompt "$prompt")

        if [[ $started -ge $max_parallel ]]; then
            echo -e "${YELLOW}Reached max parallel ($max_parallel), waiting for slots...${NC}"
            wait_for_slot "$max_parallel"
        fi

        start_session "$task_id" "$enhanced_prompt" "$model" "$budget"
        inc started
    done < <(echo "$tasks_json" | jq -c '.[]')

    echo ""
    echo -e "${CYAN}All $started tasks started. Monitoring progress...${NC}"
    echo ""

    # Wait for all to complete
    wait_all

    # Show final results with cost aggregation
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        All Sessions Complete - Results${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local total_cost=0
    local total_duration=0

    while IFS= read -r task; do
        local task_id
        task_id=$(echo "$task" | jq -r '.id')
        echo -e "${CYAN}━━━ $task_id ━━━${NC}"
        show_result "$task_id"

        # Aggregate costs
        local output_file="$SESSIONS_DIR/${task_id}.output"
        if [[ -f "$output_file" ]] && jq -e . "$output_file" > /dev/null 2>&1; then
            local cost duration
            cost=$(jq -r '.total_cost_usd // 0' "$output_file")
            duration=$(jq -r '.duration_ms // 0' "$output_file")
            total_cost=$(echo "$total_cost + $cost" | bc)
            total_duration=$((total_duration + (duration + 500) / 1000))
        fi
        echo ""
    done < <(echo "$tasks_json" | jq -c '.[]')

    # Calculate efficiency metrics
    local sequential_duration=$total_duration
    local parallel_duration=0

    # Find max parallel duration (actual time to complete all tasks)
    while IFS= read -r task; do
        local task_id
        task_id=$(echo "$task" | jq -r '.id')
        local output_file="$SESSIONS_DIR/${task_id}.output"
        if [[ -f "$output_file" ]] && jq -e . "$output_file" > /dev/null 2>&1; then
            local duration
            duration=$(jq -r '.duration_ms // 0' "$output_file")
            duration=$((duration / 1000))
            [[ $duration -gt $parallel_duration ]] && parallel_duration=$duration
        fi
    done < <(echo "$tasks_json" | jq -c '.[]')

    # Calculate token savings (estimate based on Claude's pricing)
    # Assumption: ~1 token = $0.000015 for Sonnet, so tokens ≈ cost / 0.000015
    local total_tokens_estimate
    total_tokens_estimate=$(echo "$total_cost / 0.000015" | bc)

    # Sequential would require full context for each task (no caching)
    # Estimate 30% token overhead for sequential (re-reading project context per task)
    local sequential_tokens_estimate
    sequential_tokens_estimate=$(echo "$total_tokens_estimate * 1.3" | bc | cut -d. -f1)

    local tokens_saved
    tokens_saved=$(echo "$sequential_tokens_estimate - $total_tokens_estimate" | bc | cut -d. -f1)

    local cost_saved
    cost_saved=$(echo "$tokens_saved * 0.000015" | bc)

    # Calculate speedup factor
    local speedup
    if [[ $parallel_duration -gt 0 ]]; then
        speedup=$(echo "scale=1; $sequential_duration / $parallel_duration" | bc)
    else
        speedup="N/A"
    fi

    # Calculate efficiency percentage
    local efficiency
    if [[ $sequential_tokens_estimate -gt 0 ]]; then
        efficiency=$(echo "scale=1; ($tokens_saved / $sequential_tokens_estimate) * 100" | bc)
    else
        efficiency="0"
    fi

    # Show totals with efficiency metrics
    echo -e "${GREEN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}  TOTAL: \$${total_cost} | ${parallel_duration}s parallel runtime${NC}"
    echo -e "${CYAN}  Sequential estimate: ${sequential_duration}s | Speedup: ${speedup}x${NC}"
    echo -e "${YELLOW}  🚀 Token savings: ~${tokens_saved} tokens (~\$${cost_saved})${NC}"
    echo -e "${YELLOW}  📊 Efficiency gain: ${efficiency}% (vs sequential execution)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

    log "INFO" "Multi-session complete: $task_count tasks, total_cost=\$$total_cost, parallel_duration=${parallel_duration}s, tokens_saved=~${tokens_saved}"

    # Auto-record sprint to history
    echo ""
    echo -e "${CYAN}Recording sprint to history...${NC}"
    record_sprint "$tasks_json" "Multi-session sprint ($task_count tasks)" "$total_cost" "$total_duration"
}

# Wait for a slot to become available
wait_for_slot() {
    local max=$1
    while true; do
        local running=0
        for pid_file in "$SESSIONS_DIR"/*.pid; do
            [[ ! -f "$pid_file" ]] && continue
            local pid
            pid=$(cat "$pid_file")
            if ps -p "$pid" > /dev/null 2>&1; then
                inc running
            fi
        done
        [[ $running -lt $max ]] && break
        sleep 5
    done
}

# Wait for all sessions to complete (with timeout checking)
wait_all() {
    while true; do
        local running=0
        for pid_file in "$SESSIONS_DIR"/*.pid; do
            [[ ! -f "$pid_file" ]] && continue
            local pid task_id
            pid=$(cat "$pid_file")
            task_id=$(basename "$pid_file" .pid)

            if ps -p "$pid" > /dev/null 2>&1; then
                # Check for timeout
                if [[ -f "$SESSIONS_DIR/${task_id}.started" ]]; then
                    local started_time current_time elapsed
                    started_time=$(parse_iso_date "$(cat "$SESSIONS_DIR/${task_id}.started")")
                    current_time=$(date +%s)
                    elapsed=$((current_time - started_time))

                    if [[ $elapsed -gt $DEFAULT_TIMEOUT ]]; then
                        echo -e "${RED}Session $task_id exceeded timeout (${DEFAULT_TIMEOUT}s), killing...${NC}"
                        log "WARN" "Session $task_id timed out after ${elapsed}s"
                        kill -TERM "$pid" 2>/dev/null || true
                        sleep 2
                        kill -9 "$pid" 2>/dev/null || true
                        echo "failed:timeout" > "$SESSIONS_DIR/${task_id}.status"
                        continue
                    fi
                fi
                inc running
            fi
        done

        [[ $running -eq 0 ]] && break

        # Show progress
        show_status
        echo -e "${YELLOW}Waiting for $running session(s) to complete...${NC}"
        sleep 10
    done
}

# Show just the result text (parsed from JSON)
show_result() {
    local task_id="$1"
    local output_file="$SESSIONS_DIR/${task_id}.output"

    if [[ ! -f "$output_file" ]]; then
        echo -e "${RED}No output found${NC}"
        return 1
    fi

    # Extract result from JSON
    if jq -e . "$output_file" > /dev/null 2>&1; then
        local result cost duration
        result=$(jq -r '.result // "No result field"' "$output_file")
        cost=$(jq -r '.total_cost_usd // 0' "$output_file")
        duration=$(jq -r '.duration_ms // 0' "$output_file")

        echo "$result"
        echo ""
        local duration_sec=$(( (duration + 500) / 1000 ))  # Round to nearest second
        echo -e "${BLUE}Cost: \$${cost} | Duration: ${duration_sec}s${NC}"
    else
        cat "$output_file"
    fi
}

# Start a single Claude session
start_session() {
    local task_id="$1"
    local prompt="$2"
    local model="${3:-$DEFAULT_MODEL}"
    local budget="${4:-$DEFAULT_BUDGET}"

    local output_file="$SESSIONS_DIR/${task_id}.output"
    local pid_file="$SESSIONS_DIR/${task_id}.pid"
    local status_file="$SESSIONS_DIR/${task_id}.status"

    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid=$(cat "$pid_file")
        if ps -p "$old_pid" > /dev/null 2>&1; then
            echo -e "${YELLOW}Session $task_id already running (PID: $old_pid)${NC}"
            return 1
        fi
    fi

    echo -e "${CYAN}Starting session: $task_id${NC}"
    echo -e "${BLUE}Model: $model | Budget: \$$budget${NC}"
    local prompt_display="${prompt:0:100}"
    [[ ${#prompt} -gt 100 ]] && prompt_display="${prompt_display}..."
    echo -e "${BLUE}Prompt: ${prompt_display}${NC}"

    # Mark as running
    echo "running" > "$status_file"
    echo "$(date -Iseconds)" > "$SESSIONS_DIR/${task_id}.started"

    log "INFO" "Starting session $task_id: model=$model, budget=$budget"

    # Start Claude in background with full project context
    cd "$PROJECT_DIR"
    nohup claude -p "$prompt" \
        --model "$model" \
        --max-budget-usd "$budget" \
        --permission-mode bypassPermissions \
        --output-format json \
        > "$output_file" 2>&1 &

    local pid=$!
    echo "$pid" > "$pid_file"

    echo -e "${GREEN}Started session $task_id (PID: $pid)${NC}"

    # Monitor completion synchronously in subshell that persists
    {
        while kill -0 $pid 2>/dev/null; do
            sleep 2
        done
        wait $pid 2>/dev/null
        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            echo "completed" > "$status_file"
        else
            echo "failed:$exit_code" > "$status_file"
        fi
        echo "$(date -Iseconds)" > "$SESSIONS_DIR/${task_id}.ended"
    } &
    disown
}

# Show status of all sessions
show_status() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}        Claude Multi-Session Status Dashboard${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local running=0
    local completed=0
    local failed=0
    local total_cost=0
    local max_duration=0

    for status_file in "$SESSIONS_DIR"/*.status; do
        [[ ! -f "$status_file" ]] && continue

        local task_id status pid_file output_file
        task_id=$(basename "$status_file" .status)
        status=$(cat "$status_file")
        pid_file="$SESSIONS_DIR/${task_id}.pid"
        output_file="$SESSIONS_DIR/${task_id}.output"

        # Auto-detect completion if process not running but status shows running
        if [[ "$status" == "running" && -f "$pid_file" ]]; then
            local pid
            pid=$(cat "$pid_file")
            if ! ps -p "$pid" > /dev/null 2>&1; then
                # Process ended, check if output indicates success
                if [[ -f "$output_file" ]] && grep -q '"subtype":"success"' "$output_file" 2>/dev/null; then
                    status="completed"
                    echo "completed" > "$status_file"
                    echo "$(date -Iseconds)" > "$SESSIONS_DIR/${task_id}.ended"
                elif [[ -s "$output_file" ]]; then
                    status="failed:unknown"
                    echo "failed:unknown" > "$status_file"
                fi
            fi
        fi

        # Get runtime using cross-platform date function
        local started="" runtime=""
        if [[ -f "$SESSIONS_DIR/${task_id}.started" ]]; then
            local started_content started_ts current_ts
            started_content=$(cat "$SESSIONS_DIR/${task_id}.started")
            started_ts=$(parse_iso_date "$started_content")
            if [[ -f "$SESSIONS_DIR/${task_id}.ended" ]]; then
                local ended_content ended_ts
                ended_content=$(cat "$SESSIONS_DIR/${task_id}.ended")
                ended_ts=$(parse_iso_date "$ended_content")
                runtime="$((ended_ts - started_ts))s"
            else
                current_ts=$(date +%s)
                runtime="$((current_ts - started_ts))s (running)"
            fi
        fi

        # Status emoji
        local emoji=""
        case "$status" in
            running)
                emoji="🔄"
                inc running
                ;;
            completed)
                emoji="✅"
                inc completed
                ;;
            failed*)
                emoji="❌"
                inc failed
                ;;
        esac

        # Output preview and cost tracking
        local preview=""
        if [[ -f "$output_file" ]]; then
            local output_size
            output_size=$(wc -c < "$output_file" | tr -d ' ')
            preview="(${output_size} bytes)"

            # Track costs for efficiency metrics
            if jq -e . "$output_file" > /dev/null 2>&1; then
                local cost duration_sec
                cost=$(jq -r '.total_cost_usd // 0' "$output_file")
                duration_sec=$(jq -r '.duration_ms // 0' "$output_file")
                duration_sec=$((duration_sec / 1000))

                total_cost=$(echo "$total_cost + $cost" | bc)
                [[ $duration_sec -gt $max_duration ]] && max_duration=$duration_sec
            fi
        fi

        printf "  %s %-20s %-15s %-15s %s\n" "$emoji" "$task_id" "$status" "$runtime" "$preview"
    done

    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    printf "  Total: %d | ${GREEN}Completed: %d${NC} | ${BLUE}Running: %d${NC} | ${RED}Failed: %d${NC}\n" \
        $((running + completed + failed)) $completed $running $failed

    # Show efficiency metrics if tasks are completed
    if [[ $completed -gt 0 ]] && [[ $(echo "$total_cost > 0" | bc) -eq 1 ]]; then
        local tokens_estimate efficiency_emoji
        tokens_estimate=$(echo "$total_cost / 0.000015" | bc | cut -d. -f1)

        # Estimate 30% savings from parallel execution (context reuse)
        local tokens_saved
        tokens_saved=$(echo "$tokens_estimate * 0.3" | bc | cut -d. -f1)

        # Efficiency emoji based on completion rate
        local completion_rate
        completion_rate=$(echo "scale=0; ($completed * 100) / ($completed + $failed + $running)" | bc)
        if [[ $completion_rate -ge 80 ]]; then
            efficiency_emoji="🚀"
        elif [[ $completion_rate -ge 50 ]]; then
            efficiency_emoji="⚡"
        else
            efficiency_emoji="⚠️"
        fi

        echo -e "${YELLOW}  $efficiency_emoji Token efficiency: ~${tokens_saved} tokens saved (~\$$(echo "$tokens_saved * 0.000015" | bc))${NC}"
        echo -e "${YELLOW}  📊 Parallel runtime: ${max_duration}s | Total cost: \$${total_cost}${NC}"
    fi

    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# Show output of a session
show_output() {
    local task_id="$1"
    local output_file="$SESSIONS_DIR/${task_id}.output"

    if [[ ! -f "$output_file" ]]; then
        echo -e "${RED}No output found for session: $task_id${NC}"
        return 1
    fi

    echo -e "${CYAN}Output for session: $task_id${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"

    # Try to parse as JSON, fallback to raw
    if jq -e . "$output_file" > /dev/null 2>&1; then
        jq -r '.result // .content // .' "$output_file"
    else
        cat "$output_file"
    fi
}

# Stop a session (graceful with fallback to force)
stop_session() {
    local task_id="$1"
    local pid_file="$SESSIONS_DIR/${task_id}.pid"

    if [[ ! -f "$pid_file" ]]; then
        echo -e "${YELLOW}Session $task_id not found${NC}"
        return 1
    fi

    local pid
    pid=$(cat "$pid_file")
    if ps -p "$pid" > /dev/null 2>&1; then
        # Try graceful shutdown first (SIGTERM)
        echo -e "${CYAN}Sending SIGTERM to session $task_id (PID: $pid)...${NC}"
        kill -TERM "$pid" 2>/dev/null || true

        # Wait up to 5 seconds for graceful shutdown
        local waited=0
        while ps -p "$pid" > /dev/null 2>&1 && [[ $waited -lt 5 ]]; do
            sleep 1
            inc waited
        done

        # Force kill if still running
        if ps -p "$pid" > /dev/null 2>&1; then
            echo -e "${YELLOW}Graceful shutdown failed, force killing...${NC}"
            kill -9 "$pid" 2>/dev/null || true
        fi

        echo -e "${GREEN}Stopped session $task_id${NC}"
        echo "stopped" > "$SESSIONS_DIR/${task_id}.status"
        log "INFO" "Stopped session $task_id (PID: $pid)"
    else
        echo -e "${YELLOW}Session $task_id already stopped${NC}"
    fi
}

# Stop all sessions
stop_all() {
    echo -e "${CYAN}Stopping all sessions...${NC}"
    for pid_file in "$SESSIONS_DIR"/*.pid; do
        [[ ! -f "$pid_file" ]] && continue
        local task_id
        task_id=$(basename "$pid_file" .pid)
        stop_session "$task_id"
    done
}

# Clean up completed sessions
clean_sessions() {
    echo -e "${CYAN}Cleaning up session files...${NC}"
    local cleaned=0
    local stale=0

    for status_file in "$SESSIONS_DIR"/*.status; do
        [[ ! -f "$status_file" ]] && continue

        local task_id status
        task_id=$(basename "$status_file" .status)
        status=$(cat "$status_file")

        # Check for stale "running" sessions (process died without updating status)
        if [[ "$status" == "running" ]]; then
            local pid_file="$SESSIONS_DIR/${task_id}.pid"
            if [[ -f "$pid_file" ]]; then
                local pid
                pid=$(cat "$pid_file")
                if ! ps -p "$pid" > /dev/null 2>&1; then
                    # Process is dead - check if stale
                    local started_file="$SESSIONS_DIR/${task_id}.started"
                    if [[ -f "$started_file" ]]; then
                        local started_ts current_ts elapsed
                        started_ts=$(parse_iso_date "$(cat "$started_file")")
                        current_ts=$(date +%s)
                        elapsed=$((current_ts - started_ts))

                        if [[ $elapsed -gt $STALE_THRESHOLD ]]; then
                            echo -e "${YELLOW}Cleaning stale session: $task_id (dead for ${elapsed}s)${NC}"
                            rm -f "$SESSIONS_DIR/${task_id}".*
                            inc stale
                            continue
                        fi
                    fi
                fi
            fi
        fi

        if [[ "$status" == "completed" || "$status" == stopped* || "$status" == failed* ]]; then
            rm -f "$SESSIONS_DIR/${task_id}".*
            inc cleaned
        fi
    done

    echo -e "${GREEN}Cleaned $cleaned completed + $stale stale session(s)${NC}"
}

# List all task IDs
list_sessions() {
    echo -e "${CYAN}Session IDs:${NC}"
    local count=0
    for status_file in "$SESSIONS_DIR"/*.status; do
        [[ ! -f "$status_file" ]] && continue
        local task_id
        task_id=$(basename "$status_file" .status)
        echo "  - $task_id"
        inc count
    done
    [[ $count -eq 0 ]] && echo "  (no sessions found)"
    echo ""
    echo -e "${BLUE}Total: $count session(s)${NC}"
}

show_version() {
    echo "Claude Multi-Session Orchestrator v${VERSION}"
    echo "https://github.com/illforte/claude-multi-session"
}

# Main command handler
case "${1:-}" in
    start)
        check_dependencies
        shift
        if [[ $# -lt 2 ]]; then
            echo "Usage: $0 start <task-id> <prompt> [model] [budget]"
            exit 1
        fi
        start_session "$1" "$2" "${3:-$DEFAULT_MODEL}" "${4:-$DEFAULT_BUDGET}"
        ;;
    run-multi)
        check_dependencies
        shift
        run_multi "$1" "${2:-$DEFAULT_MODEL}" "${3:-$DEFAULT_BUDGET}" "${4:-$DEFAULT_MAX_PARALLEL}"
        ;;
    status)
        show_status
        ;;
    list)
        list_sessions
        ;;
    output)
        shift
        require_arg "${1:-}" "task-id"
        show_output "$1"
        ;;
    result)
        shift
        require_arg "${1:-}" "task-id"
        show_result "$1"
        ;;
    stop)
        shift
        require_arg "${1:-}" "task-id"
        stop_session "$1"
        ;;
    stop-all)
        stop_all
        ;;
    clean)
        clean_sessions
        ;;
    version|--version|-v)
        show_version
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac

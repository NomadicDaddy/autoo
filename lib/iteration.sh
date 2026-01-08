#!/bin/bash
# lib/iteration.sh - Iteration handling module for aidd-o

# Iteration state variables
export CURRENT_ITERATION=0
export TOTAL_ITERATIONS="${MAX_ITERATIONS:-$DEFAULT_MAX_ITERATIONS}"
export ITERATION_STATUS="idle"
export ITERATION_START_TIME=""
export ITERATION_END_TIME=""

# Project state tracking
export ONBOARDING_COMPLETE=false
export NEW_PROJECT_CREATED=false
export CONSECUTIVE_FAILURES=0

# Iteration phases
readonly PHASE_INIT="init"
readonly PHASE_PLAN="plan"
readonly PHASE_CODE="code"
readonly PHASE_REVIEW="review"
readonly PHASE_VALIDATE="validate"
readonly PHASE_COMPLETE="complete"

# Iteration states
readonly STATE_IDLE="idle"
readonly STATE_RUNNING="running"
readonly STATE_PAUSED="paused"
readonly STATE_COMPLETED="completed"
readonly STATE_FAILED="failed"
readonly STATE_ABORTED="aborted"

# Initialize iteration tracking
init_iterations() {
    CURRENT_ITERATION=0
    TOTAL_ITERATIONS="${MAX_ITERATIONS:-$DEFAULT_MAX_ITERATIONS}"
    ITERATION_STATUS="$STATE_IDLE"
    CONSECUTIVE_FAILURES=0

    log_info "Initialized iteration tracking: max iterations = $TOTAL_ITERATIONS"
}

# Start a new iteration
start_iteration() {
    local phase="${1:-$PHASE_CODE}"

    CURRENT_ITERATION=$((CURRENT_ITERATION + 1))

    if [[ -n "$TOTAL_ITERATIONS" && $CURRENT_ITERATION -gt $TOTAL_ITERATIONS ]]; then
        log_warn "Maximum iterations reached: $TOTAL_ITERATIONS"
        return 1
    fi

    ITERATION_STATUS="$STATE_RUNNING"
    ITERATION_START_TIME=$(date +%s)
    export ITERATION_PHASE="$phase"

    log_info "Starting iteration $CURRENT_ITERATION${TOTAL_ITERATIONS:+ / $TOTAL_ITERATIONS} (phase: $phase)"

    # Update progress
    if [[ -n "$TOTAL_ITERATIONS" ]]; then
        print_progress $CURRENT_ITERATION $TOTAL_ITERATIONS "Iteration"
    fi
}

# End current iteration
end_iteration() {
    local status="${1:-completed}"

    ITERATION_END_TIME=$(date +%s)
    ITERATION_STATUS="$status"

    local duration=$((ITERATION_END_TIME - ITERATION_START_TIME))

    case "$status" in
        "completed")
            log_info "Iteration $CURRENT_ITERATION completed in $(format_duration $duration)"
            ;;
        "failed")
            log_error "Iteration $CURRENT_ITERATION failed after $(format_duration $duration)"
            ;;
        "aborted")
            log_warn "Iteration $CURRENT_ITERATION aborted after $(format_duration $duration)"
            ;;
    esac
}

# Check if should continue iteration
should_continue() {
    if [[ "$ITERATION_STATUS" == "$STATE_ABORTED" ]]; then
        log_warn "Iteration aborted, stopping"
        return 1
    fi

    if [[ -n "$TOTAL_ITERATIONS" && $CURRENT_ITERATION -ge $TOTAL_ITERATIONS ]]; then
        log_info "Maximum iterations reached"
        return 1
    fi

    return 0
}

# Handle iteration failure
handle_failure() {
    local exit_code="$1"

    # Check if exit code is signal termination (124 = SIGINT or timeout kill)
    if [[ $exit_code -eq 124 ]]; then
        if [[ $CONTINUE_ON_TIMEOUT == true ]]; then
            log_warn "Opencode terminated by signal (exit=124); continuing to next iteration (--continue-on-timeout set)"
            # Increment failure counter to track repeated timeouts
            ((CONSECUTIVE_FAILURES++))
            log_error "Timeout #$CONSECUTIVE_FAILURES (exit=$exit_code)"
            # Check if we should quit due to repeated timeouts
            if [[ $QUIT_ON_ABORT -gt 0 && $CONSECUTIVE_FAILURES -ge $QUIT_ON_ABORT ]]; then
                log_error "Reached failure threshold ($QUIT_ON_ABORT) due to repeated timeouts; quitting"
                exit "$exit_code"
            fi
            return
        else
            log_warn "Opencode terminated by signal (exit=124); aborting script"
            exit "$exit_code"
        fi
    fi

    # Increment failure counter
    ((CONSECUTIVE_FAILURES++))
    log_error "Opencode failed (exit=$exit_code); this is failure #$CONSECUTIVE_FAILURES"

    # Check if we should quit or continue
    if [[ $QUIT_ON_ABORT -gt 0 && $CONSECUTIVE_FAILURES -ge $QUIT_ON_ABORT ]]; then
        log_error "Reached failure threshold ($QUIT_ON_ABORT); quitting"
        exit "$exit_code"
    else
        log_info "Continuing to next iteration (threshold: $QUIT_ON_ABORT)"
    fi
}

# Reset failure counter on success
reset_failure_counter() {
    CONSECUTIVE_FAILURES=0
}

# Check if project is new and needs onboarding
check_onboarding_status() {
    local metadata_dir="$1"
    local feature_list_path="$metadata_dir/$DEFAULT_FEATURE_LIST_FILE"

    if [[ -f "$feature_list_path" ]]; then
        # Check if feature_list.json contains actual data (not just template)
        if ! grep -q "{yyyy-mm-dd}" "$feature_list_path" && ! grep -q "{Short name of the feature}" "$feature_list_path"; then
            export ONBOARDING_COMPLETE=true
            log_debug "Onboarding is complete"
        else
            export ONBOARDING_COMPLETE=false
            log_debug "Onboarding incomplete (template still present)"
        fi
    else
        export ONBOARDING_COMPLETE=false
        log_debug "No $DEFAULT_FEATURE_LIST_FILE found, onboarding incomplete"
    fi
}

# Run iteration phase
run_phase() {
    local phase="$1"
    local task="$2"

    log_debug "Running phase: $phase"

    case "$phase" in
        "$PHASE_INIT")
            run_init_phase "$task"
            ;;
        "$PHASE_PLAN")
            run_plan_phase "$task"
            ;;
        "$PHASE_CODE")
            run_code_phase "$task"
            ;;
        "$PHASE_REVIEW")
            run_review_phase "$task"
            ;;
        "$PHASE_VALIDATE")
            run_validate_phase "$task"
            ;;
        *)
            log_error "Unknown phase: $phase"
            return 1
            ;;
    esac
}

# Init phase handler
run_init_phase() {
    local task="$1"
    log_info "Running init phase: $task"

    # Perform initialization tasks
    return 0
}

# Plan phase handler
run_plan_phase() {
    local task="$1"
    log_info "Running plan phase: $task"

    # Request planning from model
    if [[ -n "$INIT_MODEL" ]]; then
        request_completion "$task" "$INIT_MODEL" "You are a planning expert. Create a detailed implementation plan."
    fi

    return 0
}

# Code phase handler
run_code_phase() {
    local task="$1"
    log_info "Running code phase: $task"

    # Request code generation
    if [[ -n "$CODE_MODEL" ]]; then
        request_completion "$task" "$CODE_MODEL" "You are an expert programmer. Generate high-quality, well-documented code."
    else
        request_completion "$task" "$MODEL" "You are an expert programmer. Generate high-quality, well-documented code."
    fi

    return 0
}

# Review phase handler
run_review_phase() {
    local task="$1"
    log_info "Running review phase: $task"

    # Request code review
    request_completion "$task" "$MODEL" "You are a code review expert. Review the code for correctness, style, and potential issues."

    return 0
}

# Validate phase handler
run_validate_phase() {
    local task="$1"
    log_info "Running validate phase: $task"

    # Run tests and validation
    return 0
}

# Run full iteration cycle
run_iteration_cycle() {
    local task="$1"

    # Start iteration
    start_iteration "$PHASE_CODE" || return 1

    # Run through phases
    for phase in "$PHASE_PLAN" "$PHASE_CODE" "$PHASE_REVIEW" "$PHASE_VALIDATE"; do
        if ! run_phase "$phase" "$task"; then
            end_iteration "failed"
            return 1
        fi
    done

    # Complete iteration
    end_iteration "completed"
    return 0
}

# Save iteration state
save_iteration_state() {
    local state_file="$PROJECT_DIR/$DEFAULT_STATE_FILE"

    cat > "$state_file" << EOF
CURRENT_ITERATION=$CURRENT_ITERATION
TOTAL_ITERATIONS=$TOTAL_ITERATIONS
ITERATION_STATUS=$ITERATION_STATUS
ITERATION_PHASE=$ITERATION_PHASE
ITERATION_START_TIME=$ITERATION_START_TIME
ITERATION_END_TIME=$ITERATION_END_TIME
LAST_UPDATE=$(date +%s)
EOF

    log_debug "Iteration state saved to: $state_file"
}

# Load iteration state
load_iteration_state() {
    local state_file="$PROJECT_DIR/$DEFAULT_STATE_FILE"

    if [[ -f "$state_file" ]]; then
        source "$state_file"
        log_info "Loaded iteration state: $CURRENT_ITERATION/$TOTAL_ITERATIONS"
        return 0
    fi

    return 1
}

# Reset iteration state
reset_iteration_state() {
    CURRENT_ITERATION=0
    TOTAL_ITERATIONS="${MAX_ITERATIONS:-$DEFAULT_MAX_ITERATIONS}"
    ITERATION_STATUS="$STATE_IDLE"
    ITERATION_START_TIME=""
    ITERATION_END_TIME=""

    # Remove state file if exists
    rm -f "$PROJECT_DIR/$DEFAULT_STATE_FILE"

    log_info "Iteration state reset"
}

# Get iteration progress percentage
get_iteration_progress() {
    local progress=0
    if [[ $TOTAL_ITERATIONS -gt 0 ]]; then
        progress=$((CURRENT_ITERATION * 100 / TOTAL_ITERATIONS))
    fi
    echo "$progress"
}

# Print iteration summary
print_iteration_summary() {
    print_header "Iteration Summary"

    echo "Current Iteration: $CURRENT_ITERATION${TOTAL_ITERATIONS:+ / $TOTAL_ITERATIONS}"
    echo "Status: $ITERATION_STATUS"
    echo "Phase: ${ITERATION_PHASE:-N/A}"
    if [[ -n "$TOTAL_ITERATIONS" ]]; then
        echo "Progress: $(get_iteration_progress)%"
    fi

    if [[ -n "$ITERATION_START_TIME" && -n "$ITERATION_END_TIME" ]]; then
        local duration=$((ITERATION_END_TIME - ITERATION_START_TIME))
        echo "Last Duration: $(format_duration $duration)"
    fi
}

# Determine which prompt to use based on project state
# Returns: 0=success and sets PROMPT_PATH and PROMPT_TYPE
# Usage: determine_prompt <project_dir> <script_dir> <metadata_dir>
determine_prompt() {
    local project_dir="$1"
    local script_dir="$2"
    local metadata_dir="$3"
    local spec_check_path="$metadata_dir/$DEFAULT_SPEC_FILE"
    local feature_list_check_path="$metadata_dir/$DEFAULT_FEATURE_LIST_FILE"
    local todo_check_path="$metadata_dir/$DEFAULT_TODO_FILE"

    # Check for TODO mode first
    if [[ "$TODO_MODE" == true ]]; then
        # Check if todo.md exists
        if [[ -f "$todo_check_path" ]]; then
            log_info "Using $DEFAULT_TODO_FILE to complete existing work items"
            PROMPT_PATH="$script_dir/$DEFAULT_PROMPTS_DIR/$DEFAULT_TODO_FILE"
            PROMPT_TYPE="todo"
            return 0
        else
            log_error "No $DEFAULT_TODO_FILE found in project directory"
            return 1
        fi
    fi

    if [[ "$ONBOARDING_COMPLETE" == true ]] && [[ -f "$feature_list_check_path" ]]; then
        # Onboarding is complete, ready for coding
        log_info "Onboarding complete, using coding prompt"
        PROMPT_PATH="$script_dir/$DEFAULT_PROMPTS_DIR/coding.md"
        PROMPT_TYPE="coding"
        return 0
    elif [[ "$NEW_PROJECT_CREATED" == true ]] && [[ -n "$SPEC_FILE" ]]; then
        # New project with spec file - use initializer
        log_info "New project detected, using initializer prompt"
        PROMPT_PATH="$script_dir/$DEFAULT_PROMPTS_DIR/initializer.md"
        PROMPT_TYPE="initializer"
        return 0
    elif is_existing_codebase "$project_dir"; then
        # Existing codebase that needs onboarding
        if [[ "$ONBOARDING_COMPLETE" == false ]]; then
            log_info "Detected incomplete onboarding, using onboarding prompt"
        else
            log_info "Detected existing codebase without $DEFAULT_FEATURE_LIST_FILE, using onboarding prompt"
        fi
        PROMPT_PATH="$script_dir/$DEFAULT_PROMPTS_DIR/onboarding.md"
        PROMPT_TYPE="onboarding"
        return 0
    else
        # New project without spec file - use initializer
        log_info "No spec provided, using initializer prompt"
        PROMPT_PATH="$script_dir/$DEFAULT_PROMPTS_DIR/initializer.md"
        PROMPT_TYPE="initializer"
        return 0
    fi
}

# Check if directory is an existing codebase
is_existing_codebase() {
    local dir="$1"
    # Check if directory exists and has files (excluding .git and metadata directories)
    if [[ -d "$dir" ]]; then
        # Build exclude pattern for metadata directories
        local exclude_pattern=""
        for metadata_dir in .git $DEFAULT_METADATA_DIR $LEGACY_METADATA_DIRS .DS_Store node_modules .vscode .idea; do
            exclude_pattern="$exclude_pattern ! -name '$metadata_dir' "
        done

        # Find files/directories excluding metadata directories
        local has_files=$(find "$dir" -mindepth 1 -maxdepth 1 $exclude_pattern -print -quit 2>/dev/null | wc -l)
        if [[ $has_files -gt 0 ]]; then
            return 0  # True - it's an existing codebase
        fi
    fi
    return 1  # False - empty or new directory
}

# Handle abort signal
handle_abort() {
    log_warn "Abort signal received"

    if [[ "$QUIT_ON_ABORT" == "true" ]]; then
        log_info "Quitting on abort as configured"
        ITERATION_STATUS="$STATE_ABORTED"
        end_iteration "aborted"
        exit 1
    else
        log_info "Pausing iteration"
        ITERATION_STATUS="$STATE_PAUSED"
    fi
}

# Register abort handler
trap handle_abort ABRT

# Find or create metadata directory
find_or_create_metadata_dir() {
    local dir="$1"

    if [[ -d "$dir/$DEFAULT_METADATA_DIR" ]]; then
        echo "$dir/$DEFAULT_METADATA_DIR"
        return
    fi

    # Migrate legacy metadata to .aidd as needed
    for legacy_dir in $LEGACY_METADATA_DIRS; do
        if [[ -d "$dir/$legacy_dir" ]]; then
            local legacy="$dir/$legacy_dir"
            local target="$dir/$DEFAULT_METADATA_DIR"
            mkdir -p "$target"
            cp -R "$legacy/." "$target/" 2>/dev/null || true
            log_debug "Migrated $legacy_dir to $DEFAULT_METADATA_DIR"
            echo "$target"
            return
        fi
    done

    mkdir -p "$dir/$DEFAULT_METADATA_DIR"
    log_debug "Created $DEFAULT_METADATA_DIR metadata directory"
    echo "$dir/$DEFAULT_METADATA_DIR"
}

# Get next log index
get_next_log_index() {
    local iterations_dir="$1"
    local max=0
    local f base num

    shopt -s nullglob
    for f in "$iterations_dir"/*.log; do
        base="$(basename "${f%.log}")"
        if [[ "$base" =~ ^[0-9]+$ ]]; then
            num=$((10#$base))
            if (( num > max )); then
                max=$num
            fi
        fi
    done
    shopt -u nullglob

    echo $((max + 1))
}

# Copy artifacts to metadata directory
copy_artifacts() {
    local project_dir="$1"
    local script_dir="$2"
    local project_metadata_dir=$(find_or_create_metadata_dir "$project_dir")

    log_info "Copying artifacts to '$project_metadata_dir'"
    ensure_dir "$project_metadata_dir"

    # Copy all artifacts contents, but don't overwrite existing files
    for artifact in "$script_dir/artifacts"/*; do
        if [[ -e "$artifact" ]]; then
            local basename="$(basename "$artifact")"
            if [[ ! -e "$project_metadata_dir/$basename" ]]; then
                cp -r "$artifact" "$project_metadata_dir/"
                log_debug "Copied artifact: $basename"
            else
                log_debug "Artifact exists, skipping: $basename"
            fi
        fi
    done
}

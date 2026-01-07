#!/usr/bin/env bash

# Default values
MODEL=""
INIT_MODEL_OVERRIDE=""
CODE_MODEL_OVERRIDE=""
SPEC_FILE=""
MAX_ITERATIONS=""  # Empty means unlimited
PROJECT_DIR=""
TIMEOUT="600"  # Default to 600 seconds
IDLE_TIMEOUT="300"  # Default idle output timeout in seconds (increased from 180 to allow for longer AI responses)
NO_CLEAN=false  # Whether to skip log cleaning
QUIT_ON_ABORT="0"  # 0=continue on abort, N=quit after N consecutive failures

NEW_PROJECT_CREATED=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --init-model)
            INIT_MODEL_OVERRIDE="$2"
            shift 2
            ;;
        --code-model)
            CODE_MODEL_OVERRIDE="$2"
            shift 2
            ;;
        --spec)
            SPEC_FILE="$2"
            shift 2
            ;;
        --max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --idle-timeout)
            IDLE_TIMEOUT="$2"
            shift 2
            ;;
        --no-clean)
            NO_CLEAN=true
            shift 1
            ;;
        --quit-on-abort)
            QUIT_ON_ABORT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --project-dir <dir> [--spec <file>] [--max-iterations <num>] [--timeout <seconds>] [--idle-timeout <seconds>] [--model <model>] [--init-model <model>] [--code-model <model>] [--no-clean] [--quit-on-abort <num>]"
            echo ""
            echo "Options:"
            echo "  --project-dir      Project directory (required)"
            echo "  --spec             Specification file (optional for existing codebases, required for new projects)"
            echo "  --max-iterations   Maximum iterations (optional, unlimited if not specified)"
            echo "  --timeout          Timeout in seconds (optional, default: 600)"
            echo "  --idle-timeout     Abort if opencode produces no output for N seconds (optional, default: 300)"
            echo "  --model            Model to use (optional)"
            echo "  --init-model       Model to use for initializer/onboarding prompts (optional, overrides --model)"
            echo "  --code-model       Model to use for coding prompt (optional, overrides --model)"
            echo "  --no-clean         Skip log cleaning on exit (optional)"
            echo "  --quit-on-abort    Quit after N consecutive failures (optional, default: 0=continue indefinitely)"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check required arguments
if [[ -z "$PROJECT_DIR" ]]; then
    echo "Error: Missing required argument --project-dir"
    echo "Use --help for usage information"
    exit 1
fi

# Get absolute path to script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INIT_MODEL_EFFECTIVE="$MODEL"
if [[ -n "$INIT_MODEL_OVERRIDE" ]]; then
    INIT_MODEL_EFFECTIVE="$INIT_MODEL_OVERRIDE"
fi

CODE_MODEL_EFFECTIVE="$MODEL"
if [[ -n "$CODE_MODEL_OVERRIDE" ]]; then
    CODE_MODEL_EFFECTIVE="$CODE_MODEL_OVERRIDE"
fi

INIT_MODEL_ARGS=()
if [[ -n "$INIT_MODEL_EFFECTIVE" ]]; then
    INIT_MODEL_ARGS=(--model "$INIT_MODEL_EFFECTIVE")
fi

CODE_MODEL_ARGS=()
if [[ -n "$CODE_MODEL_EFFECTIVE" ]]; then
    CODE_MODEL_ARGS=(--model "$CODE_MODEL_EFFECTIVE")
fi

NO_ASSISTANT_PATTERN="The model returned no assistant messages"
PROVIDER_ERROR_PATTERN="Provider returned error"

# Exit codes
EXIT_SUCCESS=0
EXIT_NO_ASSISTANT=70
EXIT_IDLE_TIMEOUT=71
EXIT_PROVIDER_ERROR=72

run_opencode_prompt() {
    local project_dir="$1"
    local prompt_path="$2"
    shift 2

    local -a model_args=("$@")
    local saw_no_assistant=false
    local saw_idle_timeout=false
    local saw_provider_error=false

    # Build opencode command with model if specified
    local opencode_cmd="opencode run"
    if [[ ${#model_args[@]} -gt 0 ]]; then
        opencode_cmd="$opencode_cmd ${model_args[@]}"
    fi

    # Use timeout command to enforce timeout
    coproc OPENCODE_PROC { (cd "$project_dir" && timeout "$TIMEOUT" bash -c "cat '$prompt_path' | $opencode_cmd") 2>&1; }

    while true; do
        local line=""
        if IFS= read -r -t "$IDLE_TIMEOUT" line <&"${OPENCODE_PROC[0]}"; then
            echo "$line"
            if [[ "$line" == *"$NO_ASSISTANT_PATTERN"* ]]; then
                saw_no_assistant=true
                echo "aidd-o.sh: detected 'no assistant messages' from model; aborting." >&2
                kill -TERM "$OPENCODE_PROC_PID" 2>/dev/null || true
                break
            fi
            if [[ "$line" == *"$PROVIDER_ERROR_PATTERN"* ]]; then
                saw_provider_error=true
                echo "aidd-o.sh: detected 'provider error' from model; aborting." >&2
                kill -TERM "$OPENCODE_PROC_PID" 2>/dev/null || true
                break
            fi
            continue
        fi

        if kill -0 "$OPENCODE_PROC_PID" 2>/dev/null; then
            saw_idle_timeout=true
            echo "aidd-o.sh: idle timeout (${IDLE_TIMEOUT}s) waiting for opencode output; aborting." >&2
            kill -TERM "$OPENCODE_PROC_PID" 2>/dev/null || true
            break
        fi

        break
    done

    wait "$OPENCODE_PROC_PID" 2>/dev/null
    local exit_code=$?

    if [[ "$saw_no_assistant" == true ]]; then
        return 70
    fi

    if [[ "$saw_idle_timeout" == true ]]; then
        return 71
    fi

    if [[ "$saw_provider_error" == true ]]; then
        return 72
    fi

    return "$exit_code"
}

# Function to find or create metadata directory
find_or_create_metadata_dir() {
    local dir="$1"

    if [[ -d "$dir/.aidd" ]]; then
        echo "$dir/.aidd"
        return
    fi

    # Migrate legacy metadata to .aidd as needed
    if [[ -d "$dir/.autoo" ]]; then
        local legacy="$dir/.autoo"
        local target="$dir/.aidd"
        mkdir -p "$target"
        cp -R "$legacy/." "$target/" 2>/dev/null || true
        echo "$target"
        return
    fi
    if [[ -d "$dir/.automaker" ]]; then
        local legacy="$dir/.automaker"
        local target="$dir/.aidd"
        mkdir -p "$target"
        cp -R "$legacy/." "$target/" 2>/dev/null || true
        echo "$target"
        return
    fi

    mkdir -p "$dir/.aidd"
    echo "$dir/.aidd"
}

# Function to check if directory is an existing codebase
is_existing_codebase() {
    local dir="$1"
    # Check if directory exists and has files (excluding .git and metadata directories)
    if [[ -d "$dir" ]]; then
        # Find files/directories excluding .git, .aidd, .auto, .autok, .automaker, .autoo, and their contents
        local has_files=$(find "$dir" -mindepth 1 -maxdepth 1 \
            ! -name '.git' \
            ! -name '.aidd' \
            ! -name '.auto' \
            ! -name '.autok' \
            ! -name '.automaker' \
            ! -name '.autoo' \
            ! -name '.DS_Store' \
            ! -name 'node_modules' \
            ! -name '.vscode' \
            ! -name '.idea' \
            -print -quit 2>/dev/null | wc -l)
        if [[ $has_files -gt 0 ]]; then
            return 0  # True - it's an existing codebase
        fi
    fi
    return 1  # False - empty or new directory
}

# Check if spec is required (only for new projects or when metadata dir doesn't have spec.txt)
NEEDS_SPEC=false
METADATA_DIR=$(find_or_create_metadata_dir "$PROJECT_DIR")
if [[ ! -d "$PROJECT_DIR" ]] || ! is_existing_codebase "$PROJECT_DIR"; then
    NEEDS_SPEC=true
fi

if [[ "$NEEDS_SPEC" == true && -z "$SPEC_FILE" ]]; then
    echo "Error: Missing required argument --spec (required for new projects or when spec.txt doesn't exist)"
    echo "Use --help for usage information"
    exit 1
fi

# Ensure project directory exists (create if missing)
if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Project directory '$PROJECT_DIR' does not exist; creating it..."
    mkdir -p "$PROJECT_DIR"
    NEW_PROJECT_CREATED=true

    # Copy scaffolding files to the new project directory (including hidden files)
    echo "Copying scaffolding files to '$PROJECT_DIR'..."
    # Copy both regular and hidden files
    find "$SCRIPT_DIR/scaffolding" -mindepth 1 -maxdepth 1 -exec cp -r {} "$PROJECT_DIR/" \;

    # Copy artifacts contents to project's metadata folder
    echo "Copying artifacts to '$METADATA_DIR'..."
    mkdir -p "$METADATA_DIR"
    # Copy all artifacts contents
    find "$SCRIPT_DIR/artifacts" -mindepth 1 -maxdepth 1 -exec cp -r {} "$METADATA_DIR/" \;
else
    # Check if this is an existing codebase
    if is_existing_codebase "$PROJECT_DIR"; then
        echo "Detected existing codebase in '$PROJECT_DIR'"
    fi
fi

# Check if spec file exists (only if provided)
if [[ -n "$SPEC_FILE" && ! -f "$SPEC_FILE" ]]; then
    echo "Error: Spec file '$SPEC_FILE' does not exist"
    exit 1
fi

# Define the paths to check
SPEC_CHECK_PATH="$METADATA_DIR/spec.txt"
FEATURE_LIST_CHECK_PATH="$METADATA_DIR/feature_list.json"

# Iteration transcript logs
ITERATIONS_DIR="$METADATA_DIR/iterations"
mkdir -p "$ITERATIONS_DIR"

get_next_log_index() {
    local max=0
    local f base num

    shopt -s nullglob
    for f in "$ITERATIONS_DIR"/*.log; do
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

# Function to copy artifacts to metadata directory
copy_artifacts() {
    local project_dir="$1"
    local project_metadata_dir=$(find_or_create_metadata_dir "$project_dir")

    echo "Copying artifacts to '$project_metadata_dir'..."
    mkdir -p "$project_metadata_dir"
    # Copy all artifacts contents, but don't overwrite existing files
    for artifact in "$SCRIPT_DIR/artifacts"/*; do
        if [[ -e "$artifact" ]]; then
            local basename="$(basename "$artifact")"
            if [[ ! -e "$project_metadata_dir/$basename" ]]; then
                cp -r "$artifact" "$project_metadata_dir/"
            fi
        fi
    done
}

NEXT_LOG_INDEX="$(get_next_log_index)"

# Initialize onboarding state check (persist across iterations)
ONBOARDING_COMPLETE=false
if [[ -f "$FEATURE_LIST_CHECK_PATH" ]]; then
    # Check if feature_list.json contains actual data (not just template)
    if ! grep -q "{yyyy-mm-dd}" "$FEATURE_LIST_CHECK_PATH" && ! grep -q "{Short name of the feature}" "$FEATURE_LIST_CHECK_PATH"; then
        ONBOARDING_COMPLETE=true
    fi
fi

# Initialize failure counter
CONSECUTIVE_FAILURES=0

echo "Project directory: $PROJECT_DIR"

# Function to clean logs on exit
cleanup_logs() {
    if [[ "$NO_CLEAN" == true ]]; then
        echo "Skipping log cleanup (--no-clean flag set)."
        return
    fi
    echo "Cleaning iteration logs..."
    if [[ -d "$ITERATIONS_DIR" ]] && [[ -n "$(ls -A "$ITERATIONS_DIR" 2>/dev/null)" ]]; then
        node "$SCRIPT_DIR/clean-logs.js" "$ITERATIONS_DIR" --no-backup
        echo "Log cleanup complete."
    fi
}

# Function to handle script exit with proper exit codes
handle_script_exit() {
    local exit_code=$?
    
    case $exit_code in
        0) return ;;  # Success, no message needed
        70) return ;;  # No assistant messages
        71) return ;;  # Idle timeout
        72) return ;;  # Provider error
        124) 
            echo "aidd-o.sh: ERROR: opencode process was terminated by signal (exit=124)"
            return 1  # Treat as error, not abort
            ;;
        130) 
            echo "aidd-o.sh: ERROR: Invalid configuration or system failure (exit=130)"
            return 1  # Treat as error, not abort
            ;;
        *) 
            echo "aidd-o.sh: ERROR: Unknown exit code from opencode (exit=$exit_code)"
            return 1  # Treat unknown as error, not abort
            ;;
    esac
}

# Set trap to handle script exit with proper exit codes
trap handle_script_exit EXIT
# Set trap to clean logs on script exit (both normal and interrupted)
trap cleanup_logs EXIT

# Check for metadata dir/spec.txt
if [[ -z "$MAX_ITERATIONS" ]]; then
    echo "Running unlimited iterations (use Ctrl+C to stop)"
    i=1
    while true; do
        printf -v LOG_FILE "%s/%03d.log" "$ITERATIONS_DIR" "$NEXT_LOG_INDEX"
        NEXT_LOG_INDEX=$((NEXT_LOG_INDEX + 1))

        {
            echo "Iteration $i"
            echo "Transcript: $LOG_FILE"
            echo "Started: $(date -Is 2>/dev/null || date)"
            echo
 
            # Determine which prompt to send based on project state
            if [[ "$ONBOARDING_COMPLETE" == true ]] && [[ -f "$FEATURE_LIST_CHECK_PATH" ]]; then
                # Onboarding is complete, ready for coding
                echo "Onboarding complete, sending coding prompt..."
                run_opencode_prompt "$PROJECT_DIR" "$SCRIPT_DIR/prompts/coding.md" "${CODE_MODEL_ARGS[@]}"
            elif [[ "$NEW_PROJECT_CREATED" == true ]] && [[ -n "$SPEC_FILE" ]]; then
                # New project with spec file - use initializer
                echo "New project detected, copying spec and sending initializer prompt..."
                copy_artifacts "$PROJECT_DIR"
                if [[ -n "$SPEC_FILE" ]]; then
                    cp "$SPEC_FILE" "$SPEC_CHECK_PATH"
                fi
                run_opencode_prompt "$PROJECT_DIR" "$SCRIPT_DIR/prompts/initializer.md" "${INIT_MODEL_ARGS[@]}"
            elif is_existing_codebase "$PROJECT_DIR" ]]; then
                # Existing codebase that needs onboarding
                if [[ "$ONBOARDING_COMPLETE" == false ]]; then
                    echo "Detected incomplete onboarding, resuming onboarding prompt..."
                else
                    echo "Detected existing codebase without feature_list, using onboarding prompt..."
                fi
                copy_artifacts "$PROJECT_DIR"
                run_opencode_prompt "$PROJECT_DIR" "$SCRIPT_DIR/prompts/onboarding.md" "${INIT_MODEL_ARGS[@]}"
            else
                # New project without spec file - use initializer
                echo "No spec provided, sending initializer prompt..."
                copy_artifacts "$PROJECT_DIR"
                run_opencode_prompt "$PROJECT_DIR" "$SCRIPT_DIR/prompts/initializer.md" "${INIT_MODEL_ARGS[@]}"
            fi

            OPENCODE_EXIT_CODE=$?
            if [[ $OPENCODE_EXIT_CODE -ne 0 ]]; then
                # Increment failure counter
                ((CONSECUTIVE_FAILURES++))
                echo "aidd-o.sh: opencode failed (exit=$OPENCODE_EXIT_CODE); this is failure #$CONSECUTIVE_FAILURES." >&2

                # Check if we should quit or continue
                if [[ $QUIT_ON_ABORT -gt 0 && $CONSECUTIVE_FAILURES -ge $QUIT_ON_ABORT ]]; then
                    echo "aidd-o.sh: reached failure threshold ($QUIT_ON_ABORT); quitting." >&2
                    exit "$OPENCODE_EXIT_CODE"
                else
                    echo "aidd-o.sh: continuing to next iteration (threshold: $QUIT_ON_ABORT)." >&2
                fi
            else
                # Reset failure counter on successful iteration
                CONSECUTIVE_FAILURES=0
            fi

            echo
            echo "--- End of iteration $i ---"
            echo "Finished: $(date -Is 2>/dev/null || date)"
            echo
        } 2>&1 | tee "$LOG_FILE"

        ITERATION_EXIT_CODE=${PIPESTATUS[0]}
        if [[ $ITERATION_EXIT_CODE -ne 0 ]]; then
            exit "$ITERATION_EXIT_CODE"
        fi

        ((i++))
    done
else
    echo "Running $MAX_ITERATIONS iterations"
    for ((i=1; i<=MAX_ITERATIONS; i++)); do
        printf -v LOG_FILE "%s/%03d.log" "$ITERATIONS_DIR" "$NEXT_LOG_INDEX"
        NEXT_LOG_INDEX=$((NEXT_LOG_INDEX + 1))

        {
            echo "Iteration $i of $MAX_ITERATIONS"
            echo "Transcript: $LOG_FILE"
            echo "Started: $(date -Is 2>/dev/null || date)"
            echo
 
            # Determine which prompt to send based on project state
            if [[ "$ONBOARDING_COMPLETE" == true ]] && [[ -f "$FEATURE_LIST_CHECK_PATH" ]]; then
                # Onboarding is complete, ready for coding
                echo "Onboarding complete, sending coding prompt..."
                run_opencode_prompt "$PROJECT_DIR" "$SCRIPT_DIR/prompts/coding.md" "${CODE_MODEL_ARGS[@]}"
            elif [[ "$NEW_PROJECT_CREATED" == true ]] && [[ -n "$SPEC_FILE" ]]; then
                # New project with spec file - use initializer
                echo "New project detected, copying spec and sending initializer prompt..."
                copy_artifacts "$PROJECT_DIR"
                if [[ -n "$SPEC_FILE" ]]; then
                    cp "$SPEC_FILE" "$SPEC_CHECK_PATH"
                fi
                run_opencode_prompt "$PROJECT_DIR" "$SCRIPT_DIR/prompts/initializer.md" "${INIT_MODEL_ARGS[@]}"
            elif is_existing_codebase "$PROJECT_DIR" ]]; then
                # Existing codebase that needs onboarding
                if [[ "$ONBOARDING_COMPLETE" == false ]]; then
                    echo "Detected incomplete onboarding, resuming onboarding prompt..."
                else
                    echo "Detected existing codebase without feature_list, using onboarding prompt..."
                fi
                copy_artifacts "$PROJECT_DIR"
                run_opencode_prompt "$PROJECT_DIR" "$SCRIPT_DIR/prompts/onboarding.md" "${INIT_MODEL_ARGS[@]}"
            else
                # New project without spec file - use initializer
                echo "No spec provided, sending initializer prompt..."
                copy_artifacts "$PROJECT_DIR"
                run_opencode_prompt "$PROJECT_DIR" "$SCRIPT_DIR/prompts/initializer.md" "${INIT_MODEL_ARGS[@]}"
            fi

            OPENCODE_EXIT_CODE=$?
            if [[ $OPENCODE_EXIT_CODE -ne 0 ]]; then
                # Increment failure counter
                ((CONSECUTIVE_FAILURES++))
                echo "aidd-o.sh: opencode failed (exit=$OPENCODE_EXIT_CODE); this is failure #$CONSECUTIVE_FAILURES." >&2

                # Check if we should quit or continue
                if [[ $QUIT_ON_ABORT -gt 0 && $CONSECUTIVE_FAILURES -ge $QUIT_ON_ABORT ]]; then
                    echo "aidd-o.sh: reached failure threshold ($QUIT_ON_ABORT); quitting." >&2
                    exit "$OPENCODE_EXIT_CODE"
                else
                    echo "aidd-o.sh: continuing to next iteration (threshold: $QUIT_ON_ABORT)." >&2
                fi
            else
                # Reset failure counter on successful iteration
                CONSECUTIVE_FAILURES=0
            fi

            # If this is not the last iteration, add a separator
            if [[ $i -lt $MAX_ITERATIONS ]]; then
                echo
                echo "--- End of iteration $i ---"
                echo "Finished: $(date -Is 2>/dev/null || date)"
                echo
            else
                echo
                echo "Finished: $(date -Is 2>/dev/null || date)"
                echo
            fi
        } 2>&1 | tee "$LOG_FILE"

        ITERATION_EXIT_CODE=${PIPESTATUS[0]}
        if [[ $ITERATION_EXIT_CODE -ne 0 ]]; then
            exit "$ITERATION_EXIT_CODE"
        fi
    done
fi

#!/bin/bash
# lib/opencode-cli.sh - OpenCode CLI interaction module for aidd-o

# OpenCode CLI command
readonly OPENCODE_CMD="opencode run"

# Error patterns for detection
readonly NO_ASSISTANT_PATTERN="The model returned no assistant messages"
readonly PROVIDER_ERROR_PATTERN="Provider returned error"

# OpenCode-specific exit codes
readonly EXIT_NO_ASSISTANT=70
readonly EXIT_IDLE_TIMEOUT=71
readonly EXIT_PROVIDER_ERROR=72
readonly EXIT_SIGNAL_TERMINATED=124

# Run opencode prompt with timeout and idle detection
# Usage: run_opencode_prompt <project_dir> <prompt_path> [--model <model>] [...]
# Returns: Exit code from opencode or custom exit codes for detected conditions
run_opencode_prompt() {
    local project_dir="$1"
    local prompt_path="$2"
    shift 2

    local -a model_args=("$@")
    local saw_no_assistant=false
    local saw_idle_timeout=false
    local saw_provider_error=false

    local opencode_cmd="$OPENCODE_CMD"
    if [[ ${#model_args[@]} -gt 0 ]]; then
        opencode_cmd="$opencode_cmd ${model_args[*]}"
    fi

    log_debug "Running opencode in: $project_dir"
    log_debug "Prompt: $prompt_path"
    log_debug "Timeout: ${TIMEOUT:-600}s, Idle: ${IDLE_TIMEOUT:-300}s"

    coproc OPENCODE_PROC { (cd "$project_dir" && timeout "${TIMEOUT:-600}" bash -c "cat '$prompt_path' | $opencode_cmd") 2>&1; }

    while true; do
        local line=""
        if IFS= read -r -t "${IDLE_TIMEOUT:-300}" line <&"${OPENCODE_PROC[0]}"; then
            echo "$line"
            if [[ "$line" == *"$NO_ASSISTANT_PATTERN"* ]]; then
                saw_no_assistant=true
                log_warn "Detected 'no assistant messages' from model"
                kill -TERM "$OPENCODE_PROC_PID" 2>/dev/null || true
                break
            fi
            if [[ "$line" == *"$PROVIDER_ERROR_PATTERN"* ]]; then
                saw_provider_error=true
                log_warn "Detected 'provider error' from model"
                kill -TERM "$OPENCODE_PROC_PID" 2>/dev/null || true
                break
            fi
            continue
        fi

        if kill -0 "$OPENCODE_PROC_PID" 2>/dev/null; then
            saw_idle_timeout=true
            log_warn "Idle timeout (${IDLE_TIMEOUT:-300}s) waiting for opencode output"
            kill -TERM "$OPENCODE_PROC_PID" 2>/dev/null || true
            break
        fi

        break
    done

    wait "$OPENCODE_PROC_PID" 2>/dev/null
    local exit_code=$?

    if [[ "$saw_no_assistant" == true ]]; then
        log_debug "Exiting with NO_ASSISTANT code: $EXIT_NO_ASSISTANT"
        return "$EXIT_NO_ASSISTANT"
    fi

    if [[ "$saw_idle_timeout" == true ]]; then
        log_debug "Exiting with IDLE_TIMEOUT code: $EXIT_IDLE_TIMEOUT"
        return "$EXIT_IDLE_TIMEOUT"
    fi

    if [[ "$saw_provider_error" == true ]]; then
        log_debug "Exiting with PROVIDER_ERROR code: $EXIT_PROVIDER_ERROR"
        return "$EXIT_PROVIDER_ERROR"
    fi

    log_debug "Exiting with opencode exit code: $exit_code"
    return "$exit_code"
}

# Check if opencode CLI is available
check_opencode_available() {
    command_exists opencode
}

# Get opencode version
get_opencode_version() {
    if command_exists opencode; then
        opencode --version 2>/dev/null || echo "unknown"
    else
        echo "not installed"
    fi
}

# Execute opencode with a simple prompt (no timeout handling)
# Usage: opencode_simple <project_dir> <prompt_content>
opencode_simple() {
    local project_dir="$1"
    local prompt_content="$2"

    log_debug "Simple opencode execution in: $project_dir"

    (cd "$project_dir" && echo "$prompt_content" | $OPENCODE_CMD) 2>&1
}

#!/bin/bash
# lib/opencode.sh - Opencode interaction module for aidd-o

# API endpoint (can be overridden via config)
export OPENCODE_API_URL="${OPENCODE_API_URL:-http://localhost:8080}"

# Default model configurations (can be overridden via config)
DEFAULT_MODELS=(
    "gpt-4"
    "gpt-4-turbo"
    "claude-3-opus"
    "claude-3-sonnet"
    "claude-3-haiku"
)

# Message types
MSG_TYPE_PLAN="plan"
MSG_TYPE_CODE="code"
MSG_TYPE_REVIEW="review"
MSG_TYPE_STATUS="status"
MSG_TYPE_ERROR="error"

# Send message to opencode
send_message() {
    local message_type="$1"
    local content="$2"
    local model="${3:-$MODEL}"

    log_debug "Sending message type: $message_type to model: $model"

    # Construct JSON payload
    local payload
    payload=$(cat << EOF
{
    "type": "$message_type",
    "content": $(printf '%s' "$content" | jq -Rs .),
    "model": "$model",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

    # Send request to API
    local response
    response=$(curl -s -X POST "$OPENCODE_API_URL/message" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ -n "$response" ]]; then
        echo "$response"
        return 0
    else
        log_error "Failed to send message to opencode"
        return 1
    fi
}

# Request model completion
request_completion() {
    local prompt="$1"
    local model="${2:-$MODEL}"
    local system_prompt="${3:-}"

    log_debug "Requesting completion from model: $model"

    local payload
    if [[ -n "$system_prompt" ]]; then
        payload=$(cat << EOF
{
    "model": "$model",
    "messages": [
        {"role": "system", "content": $(printf '%s' "$system_prompt" | jq -Rs .)},
        {"role": "user", "content": $(printf '%s' "$prompt" | jq -Rs .)}
    ],
    "max_tokens": 4096,
    "temperature": 0.7
}
EOF
        )
    else
        payload=$(cat << EOF
{
    "model": "$model",
    "messages": [
        {"role": "user", "content": $(printf '%s' "$prompt" | jq -Rs .)}
    ],
    "max_tokens": 4096,
    "temperature": 0.7
}
EOF
        )
    fi

    local response
    response=$(curl -s -X POST "$OPENCODE_API_URL/completions" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ -n "$response" ]]; then
        echo "$response"
        return 0
    else
        log_error "Failed to get completion from model: $model"
        return 1
    fi
}

# Extract content from completion response
extract_content() {
    local response="$1"
    echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null
}

# Extract error from response
extract_error() {
    local response="$1"
    echo "$response" | jq -r '.error // empty' 2>/dev/null
}

# Check if model is available
check_model_availability() {
    local model="$1"

    log_debug "Checking availability of model: $model"

    local response
    response=$(curl -s -X GET "$OPENCODE_API_URL/models/$model/status")

    if [[ -n "$response" ]]; then
        local status
        status=$(echo "$response" | jq -r '.status // "unknown"')
        if [[ "$status" == "available" ]]; then
            return 0
        fi
    fi

    return 1
}

# Get list of available models
get_available_models() {
    log_debug "Fetching available models"

    local response
    response=$(curl -s -X GET "$OPENCODE_API_URL/models")

    if [[ -n "$response" ]]; then
        echo "$response" | jq -r '.models[]?.id' 2>/dev/null
    else
        # Fallback to default models
        echo "${DEFAULT_MODELS[@]}"
    fi
}

# Initialize opencode session
init_session() {
    local session_id="${1:-$(generate_session_id)}"

    log_debug "Initializing session: $session_id"

    local response
    response=$(curl -s -X POST "$OPENCODE_API_URL/sessions" \
        -H "Content-Type: application/json" \
        -d "{\"session_id\": \"$session_id\", \"model\": \"$MODEL\"}")

    if [[ -n "$response" ]]; then
        echo "$response" | jq -r '.session_id // empty'
        return 0
    else
        log_error "Failed to initialize session"
        return 1
    fi
}

# End opencode session
end_session() {
    local session_id="$1"

    log_debug "Ending session: $session_id"

    curl -s -X DELETE "$OPENCODE_API_URL/sessions/$session_id" >/dev/null
}

# Generate unique session ID
generate_session_id() {
    echo "session-$(date +%s)-$$"
}

# Stream response from model
stream_completion() {
    local prompt="$1"
    local model="${2:-$MODEL}"
    local callback="${3:-}"

    log_debug "Streaming completion from model: $model"

    local payload
    payload=$(cat << EOF
{
    "model": "$model",
    "messages": [
        {"role": "user", "content": $(printf '%s' "$prompt" | jq -Rs .)}
    ],
    "stream": true
}
EOF
)

    if command_exists curl; then
        curl -s -X POST "$OPENCODE_API_URL/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" | \
            while IFS= read -r line; do
                if [[ -n "$callback" ]]; then
                    eval "$callback \"$line\""
                else
                    echo "$line"
                fi
            done
    fi
}

# Execute code in opencode context
execute_code() {
    local code="$1"
    local language="${2:-bash}"

    log_debug "Executing $language code"

    local payload
    payload=$(cat << EOF
{
    "code": $(printf '%s' "$code" | jq -Rs .),
    "language": "$language",
    "timeout": ${TIMEOUT:-300}
}
EOF
)

    local response
    response=$(curl -s -X POST "$OPENCODE_API_URL/execute" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ -n "$response" ]]; then
        echo "$response"
        return 0
    else
        log_error "Failed to execute code"
        return 1
    fi
}

# Get execution result
get_execution_result() {
    local execution_id="$1"

    local response
    response=$(curl -s -X GET "$OPENCODE_API_URL/execute/$execution_id")

    if [[ -n "$response" ]]; then
        echo "$response"
        return 0
    else
        log_error "Failed to get execution result"
        return 1
    fi
}

# Wait for execution completion
wait_for_completion() {
    local execution_id="$1"
    local max_wait="${2:-60}"
    local interval="${3:-2}"

    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local result
        result=$(get_execution_result "$execution_id")

        local status
        status=$(echo "$result" | jq -r '.status // "unknown"')

        case "$status" in
            "completed")
                echo "$result"
                return 0
                ;;
            "failed"|"error")
                log_error "Execution failed: $(echo "$result" | jq -r '.error // "Unknown error"')"
                return 1
                ;;
            "running"|"pending")
                sleep "$interval"
                waited=$((waited + interval))
                ;;
            *)
                log_warn "Unknown execution status: $status"
                sleep "$interval"
                waited=$((waited + interval))
                ;;
        esac
    done

    log_error "Execution timed out after ${max_wait}s"
    return 1
}

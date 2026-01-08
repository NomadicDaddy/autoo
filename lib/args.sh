#!/bin/bash
# lib/args.sh - Argument parsing module for aidd-o

# Global variables for parsed arguments (exported for use in main script)
export MODEL=""
export INIT_MODEL_OVERRIDE=""
export CODE_MODEL_OVERRIDE=""
export SPEC_FILE=""
export MAX_ITERATIONS=""
export PROJECT_DIR=""
export TIMEOUT=""
export IDLE_TIMEOUT=""
export NO_CLEAN=false
export QUIT_ON_ABORT="0"
export CONTINUE_ON_TIMEOUT=false
export SHOW_FEATURE_LIST=false
export TODO_MODE=false

# Print help/usage information
print_help() {
    cat << EOF
Usage: $0 [OPTIONS]

aidd-o - AI Development Driver: OpenCode

OPTIONS:
    --project-dir DIR       Project directory (required unless --feature-list is specified)
    --spec FILE             Specification file (optional for existing codebases, required for new projects)
    --max-iterations N      Maximum iterations (optional, unlimited if not specified)
    --timeout N             Timeout in seconds (optional, default: 600s)
    --idle-timeout N        Idle timeout in seconds (optional, default: 300s)
    --model MODEL           Model to use (optional)
    --init-model MODEL      Model for initializer/onboarding prompts (optional, overrides --model)
    --code-model MODEL      Model for coding prompts (optional, overrides --model)
    --no-clean              Skip log cleaning on exit (optional)
    --quit-on-abort N       Quit after N consecutive failures (optional, default: 0=continue indefinitely)
    --continue-on-timeout   Continue to next iteration if opencode times out (exit 124) instead of aborting (optional)
     --feature-list          Display project feature list status and exit (optional)
    --todo                  Use TODO mode: look for and complete todo items instead of new features (optional)
    --help                  Show this help message

EXAMPLES:
    $0 --project-dir ./myproject --spec ./spec.txt
    $0 --project-dir ./myproject --model gpt-4 --max-iterations 5
    $0 --project-dir ./myproject --init-model claude --code-model gpt-4 --no-clean
    $0 --project-dir ./myproject --feature-list
    $0 --project-dir ./myproject --todo

For more information, visit: https://github.com/example/aidd-o
EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
                shift
                ;;
            --quit-on-abort)
                QUIT_ON_ABORT="$2"
                shift 2
                ;;
            --continue-on-timeout)
                CONTINUE_ON_TIMEOUT=true
                shift
                ;;
            --feature-list)
                SHOW_FEATURE_LIST=true
                shift
                ;;
            --todo)
                TODO_MODE=true
                shift
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Validate required arguments
validate_args() {
    # Check required --project-dir argument (unless --feature-list or --todo is specified)
    if [[ "$SHOW_FEATURE_LIST" != true && "$TODO_MODE" != true && -z "$PROJECT_DIR" ]]; then
        echo "Error: Missing required argument --project-dir" >&2
        echo "Use --help for usage information"
        return 1
    fi
    
    return 0
}

# Apply defaults for unset arguments
apply_defaults() {
    # Default timeout
    if [[ -z "$TIMEOUT" ]]; then
        TIMEOUT="$DEFAULT_TIMEOUT"
    fi

    # Default idle-timeout
    if [[ -z "$IDLE_TIMEOUT" ]]; then
        IDLE_TIMEOUT="$DEFAULT_IDLE_TIMEOUT"
    fi
}

# Get effective model values
get_effective_models() {
    # Determine effective init model
    if [[ -n "$INIT_MODEL_OVERRIDE" ]]; then
        INIT_MODEL_EFFECTIVE="$INIT_MODEL_OVERRIDE"
    else
        INIT_MODEL_EFFECTIVE="$MODEL"
    fi

    # Determine effective code model
    if [[ -n "$CODE_MODEL_OVERRIDE" ]]; then
        CODE_MODEL_EFFECTIVE="$CODE_MODEL_OVERRIDE"
    else
        CODE_MODEL_EFFECTIVE="$MODEL"
    fi

    # Build model args arrays
    INIT_MODEL_ARGS=()
    if [[ -n "$INIT_MODEL_EFFECTIVE" ]]; then
        INIT_MODEL_ARGS=(--model "$INIT_MODEL_EFFECTIVE")
    fi

    CODE_MODEL_ARGS=()
    if [[ -n "$CODE_MODEL_EFFECTIVE" ]]; then
        CODE_MODEL_ARGS=(--model "$CODE_MODEL_EFFECTIVE")
    fi
}

# Show feature list status
show_feature_list() {
    local project_dir="$1"
    local feature_list_file="$project_dir/$DEFAULT_METADATA_DIR/$DEFAULT_FEATURE_LIST_FILE"

    if [[ ! -f "$feature_list_file" ]]; then
        echo "Error: Feature list not found at: $feature_list_file" >&2
        echo "Run in an existing aidd-o project or specify --project-dir" >&2
        return 1
    fi
    
    # Parse feature_list.json using jq if available
    if ! command_exists jq; then
        echo "Error: 'jq' command is required for --feature-list option" >&2
        echo "Install jq to display feature list: https://stedolan.github.io/jq/" >&2
        return 1
    fi
    
    local features_json
    features_json=$(cat "$feature_list_file")
    
    # Get overall statistics
    local total
    local passing
    local failing
    local open
    local closed
    
    total=$(echo "$features_json" | jq '. | length')
    passing=$(echo "$features_json" | jq '[.[] | select(.passes == true)] | length')
    failing=$(echo "$features_json" | jq '[.[] | select(.passes == false and .status == "open")] | length')
    closed=$(echo "$features_json" | jq '[.[] | select(.status == "resolved")] | length')
    open=$(echo "$features_json" | jq '[.[] | select(.status == "open")] | length')
    
    # Print summary header
    echo ""
    echo "=============================================================================="
    echo "Project Feature List Status: $project_dir"
    echo "=============================================================================="
    echo ""
    printf "%-15s %s\n" "Total Features:" "$total"
    printf "%-15s %s\n" "Passing:" "$passing"
    printf "%-15s %s\n" "Failing:" "$failing"
    printf "%-15s %s\n" "Open:" "$open"
    printf "%-15s %s\n" "Closed:" "$closed"
    printf "%-15s %s\n" "Complete:" "$((passing * 100 / total))%"
    echo ""
    
    # Group by status
    echo "------------------------------------------------------------------------------"
    echo "Features by Status:"
    echo "------------------------------------------------------------------------------"
    echo ""
    
    # Passing features
    echo "✅ PASSING ($passing features):"
    echo ""
    echo "$features_json" | jq -r '.[] | select(.passes == true) | "\(.description)"' | while IFS= read -r line; do
        echo "  • $line"
    done
    echo ""
    
    # Open/failing features
    echo "⚠️  OPEN ($failing features):"
    echo ""
    echo "$features_json" | jq -r '.[] | select(.passes == false and .status == "open") | "\(.description) - [\(.priority)]"' | while IFS= read -r line; do
        echo "  • $line"
    done
    echo ""
    
    # Group by category
    echo "------------------------------------------------------------------------------"
    echo "Features by Category:"
    echo "------------------------------------------------------------------------------"
    echo ""
    
    for category in functional style performance testing devex docs process; do
        local count
        count=$(echo "$features_json" | jq --arg cat "$category" '[.[] | select(.category == $cat)] | length')
        if [[ $count -gt 0 ]]; then
            printf "%-20s %s\n" "$category:" "$count features"
        fi
    done
    echo ""
    
    # Group by priority
    echo "------------------------------------------------------------------------------"
    echo "Features by Priority:"
    echo "------------------------------------------------------------------------------"
    echo ""
    
    for priority in critical high medium low; do
        local count
        count=$(echo "$features_json" | jq --arg pri "$priority" '[.[] | select(.priority == $pri)] | length')
        if [[ $count -gt 0 ]]; then
            printf "%-20s %s\n" "$priority:" "$count features"
        fi
    done
    echo ""
    
    echo "=============================================================================="
    echo ""
    
    return 0
}

# Main entry point for argument parsing
# Usage: source lib/args.sh && init_args "$@"
init_args() {
    parse_args "$@"
    if ! validate_args; then
        return 1
    fi
    apply_defaults
    get_effective_models
    
    # Handle --feature-list option (display and exit)
    if [[ "$SHOW_FEATURE_LIST" == true ]]; then
        show_feature_list "$PROJECT_DIR"
        exit 0
    fi
    
    # Handle --todo option (export mode flag for use by main script)
    # TODO_MODE is handled by determine_prompt() in lib/iteration.sh
    # We just need to pass through and let iteration.sh handle it
    
    return 0
}

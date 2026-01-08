#!/bin/bash
# =============================================================================
# Configuration Constants and Defaults
# =============================================================================
# Exit codes, default values, and pattern constants for error detection

# -----------------------------------------------------------------------------
# Exit Codes
# -----------------------------------------------------------------------------
readonly EXIT_SUCCESS=0              # Successful execution
readonly EXIT_GENERAL_ERROR=1        # General/unspecified error
readonly EXIT_INVALID_ARGS=2         # Invalid command-line arguments
readonly EXIT_NOT_FOUND=3            # File or resource not found
readonly EXIT_PERMISSION_DENIED=4    # Permission denied
readonly EXIT_TIMEOUT=5              # Timeout occurred
readonly EXIT_ABORTED=6              # Operation aborted by user
readonly EXIT_VALIDATION_ERROR=7     # Validation failed
readonly EXIT_OPENCODE_ERROR=8       # OpenCode/API error

# -----------------------------------------------------------------------------
# Default Values
# -----------------------------------------------------------------------------
readonly DEFAULT_MODEL="opencode"            # Default LLM model
readonly DEFAULT_MAX_ITERATIONS=10          # Default max iterations (0 = unlimited)
readonly DEFAULT_TIMEOUT=600                 # Default timeout in seconds (10 minutes)
readonly DEFAULT_IDLE_TIMEOUT=300            # Default idle timeout in seconds (5 minutes)
readonly DEFAULT_NO_CLEAN=0                  # Default: clean up artifacts (0 = false)
readonly DEFAULT_QUIT_ON_ABORT=0             # Default: continue on abort (0 = false)

# -----------------------------------------------------------------------------
# Directory and File Names
# -----------------------------------------------------------------------------
readonly DEFAULT_METADATA_DIR=".aidd"                 # Metadata directory name (hidden)
readonly DEFAULT_PROMPTS_DIR="prompts"                # Prompts directory name
readonly DEFAULT_ITERATIONS_DIR="iterations"           # Iterations directory name
readonly DEFAULT_SCAFFOLDING_DIR="scaffolding"       # Scaffolding directory name
readonly DEFAULT_ARTIFACTS_DIR="artifacts"           # Artifacts directory name
readonly DEFAULT_STATE_FILE=".iteration_state"         # Iteration state file name
readonly DEFAULT_FEATURE_LIST_FILE="feature_list.json" # Feature list file name
readonly DEFAULT_SPEC_FILE="spec.txt"                 # Spec file name
readonly DEFAULT_TODO_FILE="todo.md"                  # Todo file name
readonly DEFAULT_PROJECT_STRUCTURE_FILE="project_structure.md" # Project structure file name
readonly DEFAULT_PIPELINE_FILE="pipeline.json"        # Pipeline file name

# Legacy metadata directory names (for migration)
readonly LEGACY_METADATA_DIRS=".autoo .automaker .auto .autok"  # Old metadata directory names

# -----------------------------------------------------------------------------
# Pattern Constants for Error Detection
# -----------------------------------------------------------------------------
# Regex patterns for detecting common error conditions in output

# OpenCode-specific error patterns
readonly PATTERN_OPENCODE_ERROR="error|failed|exception|crash|panic"
readonly PATTERN_OPENCODE_ABORT="aborted|interrupt|cancelled|canceled"
readonly PATTERN_OPENCODE_TIMEOUT="timeout| timed out| no response"
readonly PATTERN_OPENCODE_VALIDATION="invalid|validation|constraint|required"

# General error patterns
readonly PATTERN_GENERAL_ERROR="ERROR|error:|Error"
readonly PATTERN_WARNING="WARNING|Warning|warning:"
readonly PATTERN_PERMISSION_DENIED="permission denied|access denied|not authorized"
readonly PATTERN_NOT_FOUND="not found|does not exist|no such file"

# Session/connection patterns
readonly PATTERN_SESSION_ENDED="session ended|disconnected|connection lost"
readonly PATTERN_AUTH_ERROR="authentication|auth:|unauthorized|401|403"

# File operation patterns
readonly PATTERN_FILE_ERROR="cannot open|cannot write|cannot read|read-only|write-protected"

# Timeout patterns
readonly PATTERN_TIMEOUT_ERROR="timed out|timeout|deadline exceeded|took too long"

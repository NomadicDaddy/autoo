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
readonly DEFAULT_TIMEOUT=120                 # Default timeout in seconds (2 minutes)
readonly DEFAULT_IDLE_TIMEOUT=300            # Default idle timeout in seconds (5 minutes)
readonly DEFAULT_NO_CLEAN=0                  # Default: clean up artifacts (0 = false)
readonly DEFAULT_QUIT_ON_ABORT=0             # Default: continue on abort (0 = false)

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

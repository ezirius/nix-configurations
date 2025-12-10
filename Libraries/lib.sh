#!/usr/bin/env bash

# Shared library for Nix-Configurations scripts
# Source this file from install.sh, git.sh, partition.sh
# Note: clone.sh cannot use this (runs standalone via curl | bash)
#
# Note: All scripts use 'set -euo pipefail'. If a piped command fails silently,
# check each pipeline stage individually. The -o pipefail option ensures the
# pipeline returns the exit status of the last command to fail.

# =============================================================================
# Direct Execution Guard
# =============================================================================

# Detect if script is being run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "Error: lib.sh is a library and should be sourced, not executed directly."
    echo ""
    echo "Usage: source Libraries/lib.sh"
    echo ""
    echo "This file provides shared functions and variables for:"
    echo "  - install.sh"
    echo "  - git.sh"
    echo "  - partition.sh"
    exit 1
fi

# Prevent double-sourcing
if [[ -n "${_NIX_CONFIG_LIB_LOADED:-}" ]]; then
    return 0
fi
_NIX_CONFIG_LIB_LOADED=true

# =============================================================================
# Configuration
# =============================================================================

# Host definitions
LINUX_HOSTS=("Nithra")
DARWIN_HOSTS=("Maldoria")
ALL_HOSTS=("${LINUX_HOSTS[@]}" "${DARWIN_HOSTS[@]}")

# Primary user (used for home directory paths on live ISO install)
PRIMARY_USER="ezirius"

# Repository name
REPO_NAME="Nix-Configurations"

# =============================================================================
# Colours (disabled if stdout is not a terminal)
# =============================================================================

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    GREEN=''
    YELLOW=''
    RED=''
    NC=''
fi

# =============================================================================
# Platform Detection
# =============================================================================

PLATFORM=$(uname -s)

# =============================================================================
# Functions
# =============================================================================

# Run git commands (natively or via nix-shell if git not installed)
run_git() {
    if command -v git &> /dev/null; then
        git "$@"
    else
        # Use printf %q to safely escape arguments for shell
        nix-shell -p git --run "$(printf 'git %q ' "$@")"
    fi
}

# Ensure git-agecrypt filters are configured
# Sets up key and filters if not already present
ensure_git_agecrypt_filters() {
    # Check if filters are configured AND the binary exists
    local EXISTING_FILTER
    EXISTING_FILTER=$(run_git config --get filter.git-agecrypt.smudge 2>/dev/null || true)
    local FILTER_BINARY
    FILTER_BINARY=$(echo "$EXISTING_FILTER" | awk '{print $1}')
    if [[ -n "$EXISTING_FILTER" ]] && [[ -z "$FILTER_BINARY" || -x "$FILTER_BINARY" ]]; then
        return
    fi
    # Filters not configured OR binary is stale (garbage collected)
    if [[ -n "$FILTER_BINARY" && ! -x "$FILTER_BINARY" ]]; then
        echo -e "${YELLOW}>> Existing git-agecrypt filter is stale, reconfiguring...${NC}"
    fi

    local KEY_PATH="$HOME/.config/git-agecrypt/keys.txt"
    if [ -f "$KEY_PATH" ] && grep -q "AGE-SECRET-KEY-" "$KEY_PATH"; then
        echo -e "${GREEN}>> git-agecrypt key already exists at ${KEY_PATH}${NC}"
    else
        echo -e "${YELLOW}>> git-agecrypt key missing or invalid at ${KEY_PATH}${NC}"
        echo "   Creating directory and prompting for key..."
        mkdir -p "$(dirname "$KEY_PATH")"
        echo ""
        echo "Paste your git-agecrypt age private key (starts with AGE-SECRET-KEY-)."
        echo "This key decrypts git-agecrypt.nix files."
        echo ""
        local KEY_CONTENT
        read -er KEY_CONTENT </dev/tty
        if [[ -z "$KEY_CONTENT" ]]; then
            echo -e "${RED}>> No key provided. Aborting.${NC}"
            exit 1
        fi
        if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
            echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
            exit 1
        fi
        (umask 077 && echo "$KEY_CONTENT" > "$KEY_PATH")
        unset KEY_CONTENT
        echo -e "${GREEN}>> git-agecrypt key saved to ${KEY_PATH}${NC}"
    fi

    echo -e "${YELLOW}>> Configuring git-agecrypt filters...${NC}"
    # Get the directory of the script that sourced this library (BASH_SOURCE[1])
    local REPO_DIR
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    nix-shell -p git-agecrypt --run "cd \"$REPO_DIR\" && git-agecrypt init"
    nix-shell -p git-agecrypt --run "cd \"$REPO_DIR\" && git-agecrypt config add -i \"$KEY_PATH\""
    echo -e "${GREEN}>> git-agecrypt identity configured${NC}"

    if ! run_git config --get filter.git-agecrypt.smudge > /dev/null 2>&1; then
        echo -e "${RED}>> git-agecrypt configuration failed; please configure manually.${NC}"
        exit 1
    fi
}

# Classify hostname and set global variables
# Sets: HOST_TYPE (nixos|known|other), DETECTED_HOST (normalised name or empty)
# Sets: CURRENT_HOST, CURRENT_HOST_LOWER
classify_hostname() {
    CURRENT_HOST=$(hostname)
    CURRENT_HOST="${CURRENT_HOST%.local}"  # Strip .local suffix (macOS)
    CURRENT_HOST_LOWER="${CURRENT_HOST,,}"
    
    if [[ "$CURRENT_HOST_LOWER" == "nixos" ]]; then
        HOST_TYPE="nixos"
        DETECTED_HOST=""
        return
    fi
    
    for host in "${ALL_HOSTS[@]}"; do
        if [[ "${host,,}" == "$CURRENT_HOST_LOWER" ]]; then
            HOST_TYPE="known"
            DETECTED_HOST="$host"
            return
        fi
    done
    
    HOST_TYPE="other"
    DETECTED_HOST=""
}

# Validate platform matches host requirements
# Usage: validate_host_platform "Nithra"
# Returns 0 if valid, 1 if mismatch or unknown host
validate_host_platform() {
    local host="${1,,}"
    
    for h in "${LINUX_HOSTS[@]}"; do
        if [[ "${h,,}" == "$host" ]]; then
            [[ "$PLATFORM" != "Darwin" ]] && return 0
            return 1
        fi
    done
    
    for h in "${DARWIN_HOSTS[@]}"; do
        if [[ "${h,,}" == "$host" ]]; then
            [[ "$PLATFORM" == "Darwin" ]] && return 0
            return 1
        fi
    done
    
    # Unknown host - return failure (caller should handle HOST_TYPE=other separately)
    return 1
}

# Print hostname detection message
# Usage: print_host_message
print_host_message() {
    case "$HOST_TYPE" in
        nixos)
            echo -e "${GREEN}>> Detected NixOS live installer${NC}"
            ;;
        known)
            if [[ "$PLATFORM" == "Darwin" ]]; then
                echo -e "${GREEN}>> Detected ${DETECTED_HOST} (Darwin)${NC}"
            else
                echo -e "${GREEN}>> Detected ${DETECTED_HOST} (NixOS)${NC}"
            fi
            ;;
        other)
            echo -e "${YELLOW}>> Unknown hostname '${CURRENT_HOST}'${NC}"
            ;;
    esac
}

# Validate host argument against specified hosts array
# Usage: validate_host_arg "Nithra" "${LINUX_HOSTS[@]}"
# If no array specified, validates against ALL_HOSTS
# Returns 0 if valid, 1 if invalid
validate_host_arg() {
    local arg="${1:-}"
    [[ -z "$arg" ]] && return 1
    shift
    
    local hosts=("$@")
    [[ ${#hosts[@]} -eq 0 ]] && hosts=("${ALL_HOSTS[@]}")
    
    for host in "${hosts[@]}"; do
        if [[ "${host,,}" == "${arg,,}" ]]; then
            return 0
        fi
    done
    return 1
}

# Normalise host name to capitalised format
# Usage: normalise_host "NITHRA" -> "Nithra"
normalise_host() {
    local host="${1,,}"
    echo "${host^}"
}

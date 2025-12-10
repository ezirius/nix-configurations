#!/usr/bin/env bash

# Clone and set up Nix-Configurations repository
# Run this from a NixOS live installer or an installed system (NixOS/Darwin)
#
# Usage:
#   ./clone.sh
#   curl -sL https://raw.githubusercontent.com/ezirius/Nix-Configurations/main/clone.sh | bash

set -euo pipefail

# Note: 'set -o pipefail' ensures piped commands propagate failures.
# If a command fails unexpectedly, check each pipeline stage individually.

# Require bash 4.0+ for ${var,,} and ${var^} syntax
if ((BASH_VERSINFO[0] < 4)); then
    echo "Error: bash 4.0+ required (you have ${BASH_VERSION})"
    echo "On macOS, run with: nix-shell -p bash --run './clone.sh'"
    exit 1
fi

# Help function
show_help() {
    cat <<'EOF'
Usage: ./clone.sh
       curl -sL https://raw.githubusercontent.com/ezirius/Nix-Configurations/main/clone.sh | bash

Clone and set up the Nix-Configurations repository.

Options:
  -h, --help    Show this help message

This script:
  1. Detects hostname (nixos, nithra, maldoria, or other)
  2. Clones the repository (or resets existing clone)
  3. For known hosts: prompts for keys and decrypts secrets
  4. For unknown hosts: clones only (see README for setup)

Examples:
  ./clone.sh                                    # Run locally
  curl -sL <raw-github-url>/clone.sh | bash    # Remote bootstrap
EOF
}

# Parse arguments
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

# =============================================================================
# Colours (disabled if stdout is not a terminal)
# NOTE: Keep in sync with Libraries/lib.sh (duplicated for standalone usage)
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

REPO_URL="https://github.com/ezirius/Nix-Configurations.git"
SSH_URL="git@github.com:ezirius/Nix-Configurations.git"
KEY_PATH="$HOME/.config/git-agecrypt/keys.txt"
PLATFORM=$(uname -s)

# =============================================================================
# Host definitions
# NOTE: Keep in sync with Libraries/lib.sh (duplicated for standalone usage)
# =============================================================================

LINUX_HOSTS=("Nithra")
DARWIN_HOSTS=("Maldoria")

# =============================================================================
# Functions
# NOTE: Keep in sync with Libraries/lib.sh (duplicated for standalone usage)
# =============================================================================

# Run git commands (natively or via nix-shell if git not installed)
run_git() {
    if command -v git &> /dev/null; then
        git "$@"
    else
        # Use env to pass arguments safely without shell escaping issues
        nix-shell -p git --run "$(printf 'git %q ' "$@")"
    fi
}

# Classify hostname (duplicated from lib.sh for standalone usage)
# Sets: HOST_TYPE (nixos|known|other), DETECTED_HOST (normalised name or empty)
ALL_HOSTS=("${LINUX_HOSTS[@]}" "${DARWIN_HOSTS[@]}")
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

# Classify hostname
classify_hostname

# Print detection message
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
        echo -e "${YELLOW}>> Unknown hostname '${CURRENT_HOST}' (${PLATFORM})${NC}"
        ;;
esac

# Clone to /tmp on live ISO, permanent location on installed system
if [[ "$HOST_TYPE" == "nixos" ]]; then
    CLONE_DIR="/tmp/Nix-Configurations"
else
    CLONE_DIR="$HOME/Documents/Ezirius/Development/GitHub/Nix-Configurations"
fi

echo -e "${GREEN}>> Nix-Configurations Clone Setup${NC}"

# Cleanup on error (not on Ctrl+C or success)
SCRIPT_SUCCESS=false
cleanup() {
    if [[ "$SCRIPT_SUCCESS" != true ]]; then
        echo -e "${RED}>> Setup failed. Partial state may remain at ${CLONE_DIR}${NC}"
    fi
}
trap cleanup EXIT
trap "exit 1" INT TERM

# Check network connectivity
echo -e "${YELLOW}>> Checking network...${NC}"
if ! curl -sI https://github.com --max-time 5 &>/dev/null; then
    echo -e "${RED}>> Error: Cannot reach github.com${NC}"
    echo "   Configure network first, then rerun this script"
    exit 1
fi

# Handle existing directory
if [ -d "$CLONE_DIR" ]; then
    if [ -d "$CLONE_DIR/.git" ]; then
        # Check if it's the correct remote
        CURRENT_REMOTE=$(cd "$CLONE_DIR" && run_git ls-remote --get-url origin 2>/dev/null || true)
        if [ "$CURRENT_REMOTE" = "$REPO_URL" ] || [ "$CURRENT_REMOTE" = "$SSH_URL" ]; then
            echo -e "${YELLOW}>> Repository exists, checking for local changes...${NC}"
            (cd "$CLONE_DIR" && run_git fetch origin)
            
            UNCOMMITTED=$(cd "$CLONE_DIR" && run_git status --porcelain || true)
            UNPUSHED=$(cd "$CLONE_DIR" && run_git rev-list origin/main..HEAD --count 2>/dev/null || echo "0")
            
            if [[ -n "$UNCOMMITTED" || "$UNPUSHED" -gt 0 ]]; then
                echo -e "${RED}>> Local changes detected:${NC}"
                [[ -n "$UNCOMMITTED" ]] && echo "   - Uncommitted changes"
                [[ "$UNPUSHED" -gt 0 ]] && echo "   - ${UNPUSHED} unpushed commit(s)"
                echo ""
                echo -n "Overwrite and lose all local changes? (y/n): "
                read -er CONFIRM < /dev/tty
                if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
                    echo -e "${YELLOW}>> Aborted. No changes made.${NC}"
                    exit 0
                fi
            fi
            
            echo -e "${YELLOW}>> Resetting to origin/main...${NC}"
            (cd "$CLONE_DIR" && run_git reset --hard origin/main)
            # Note: Secrets will be decrypted later in the "Decrypting secrets" section
        else
            echo -e "${RED}>> Directory exists but has different remote${NC}"
            echo ""
            echo -n "Delete existing directory and re-clone? (y/n): "
            read -er CONFIRM < /dev/tty
            if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
                echo -e "${YELLOW}>> Aborted. No changes made.${NC}"
                exit 0
            fi
            cd "$HOME"
            rm -rf "$CLONE_DIR"
            run_git clone "$REPO_URL" "$CLONE_DIR"
        fi
    else
        echo -e "${RED}>> Directory exists but is not a git repo${NC}"
        echo ""
        echo -n "Delete existing directory and re-clone? (y/n): "
        read -er CONFIRM < /dev/tty
        if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
            echo -e "${YELLOW}>> Aborted. No changes made.${NC}"
            exit 0
        fi
        cd "$HOME"
        rm -rf "$CLONE_DIR"
        run_git clone "$REPO_URL" "$CLONE_DIR"
    fi
else
    echo -e "${YELLOW}>> Cloning repository...${NC}"
    mkdir -p "$(dirname "$CLONE_DIR")"
    run_git clone "$REPO_URL" "$CLONE_DIR"
fi
cd "$CLONE_DIR"

echo -e "${YELLOW}>> Working from: ${CLONE_DIR}${NC}"

# Switch remote to SSH on installed systems (not live ISO)
# HTTPS is used for initial clone (no SSH keys on live ISO), but SSH is needed for pushing
if [[ "$HOST_TYPE" != "nixos" ]]; then
    CURRENT_REMOTE=$(run_git ls-remote --get-url origin 2>/dev/null || true)
    if [[ "$CURRENT_REMOTE" == "$REPO_URL" ]]; then
        echo -e "${YELLOW}>> Switching remote from HTTPS to SSH...${NC}"
        run_git remote set-url origin "$SSH_URL"
        echo -e "${GREEN}>> Remote URL: ${SSH_URL}${NC}"
    elif [[ "$CURRENT_REMOTE" == "$SSH_URL" ]]; then
        echo -e "${GREEN}>> Remote already using SSH${NC}"
    fi
fi

# For unknown hosts, skip key setup and decryption
if [[ "$HOST_TYPE" == "other" ]]; then
    SCRIPT_SUCCESS=true
    echo ""
    echo -e "${GREEN}>> Repository cloned to ${CLONE_DIR}${NC}"
    echo ""
    echo -e "${YELLOW}>> This repository is configured for specific hosts (Nithra, Maldoria).${NC}"
    echo -e "${YELLOW}>> To set up your own infrastructure, see README.md: \"Forking for your own use\"${NC}"
    echo ""
    # Warn if remote is still the original repo (user should fork first)
    CURRENT_REMOTE=$(cd "$CLONE_DIR" && run_git ls-remote --get-url origin 2>/dev/null || true)
    if [[ "$CURRENT_REMOTE" == *"ezirius/Nix-Configurations"* ]]; then
        echo -e "${YELLOW}>> Note: You're using the original repository. Fork it first if you plan to make changes.${NC}"
    fi
    exit 0
fi

# Set up git-agecrypt key
echo -e "${YELLOW}>> Setting up git-agecrypt key...${NC}"
mkdir -p "$(dirname "$KEY_PATH")"

if [ -f "$KEY_PATH" ] && grep -q "AGE-SECRET-KEY-" "$KEY_PATH"; then
    echo -e "${GREEN}>> git-agecrypt key already exists at ${KEY_PATH}${NC}"
else
    echo -e "${YELLOW}>> Paste your git-agecrypt age private key (starts with AGE-SECRET-KEY-):${NC}"
    read -er KEY_CONTENT </dev/tty
    if [[ -z "$KEY_CONTENT" ]]; then
        echo -e "${RED}>> Error: No key provided${NC}"
        exit 1
    fi
    if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
        echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
        exit 1
    fi
    # Validate key format before saving (age keys are 59+ chars after prefix)
    KEY_BODY="${KEY_CONTENT#AGE-SECRET-KEY-}"
    if [[ ${#KEY_BODY} -lt 52 ]]; then
        echo -e "${RED}>> Error: Key appears truncated (too short)${NC}"
        exit 1
    fi
    # Verify key can derive a public key before saving
    echo -e "${YELLOW}>> Validating key format...${NC}"
    DERIVED_PUBKEY=$(echo "$KEY_CONTENT" | nix-shell -p age --run "age-keygen -y" 2>/dev/null || true)
    if [[ -z "$DERIVED_PUBKEY" || "$DERIVED_PUBKEY" != age1* ]]; then
        echo -e "${RED}>> Error: Invalid age key (could not derive public key)${NC}"
        exit 1
    fi
    # Check if key matches git-agecrypt.toml before saving
    TOML_FILE="${CLONE_DIR}/git-agecrypt.toml"
    if [[ -f "$TOML_FILE" ]] && ! grep -q "$DERIVED_PUBKEY" "$TOML_FILE"; then
        echo -e "${RED}>> Warning: Your key's public key does not match git-agecrypt.toml${NC}"
        echo "   Your public key: $DERIVED_PUBKEY"
        echo "   Decryption will fail. Check you pasted the correct key."
        echo ""
        echo -n "Continue anyway? (y/n): "
        read -er CONFIRM < /dev/tty
        if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
            echo -e "${YELLOW}>> Aborted.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}>> Key validated and matches configuration${NC}"
    fi
    (umask 077 && echo "$KEY_CONTENT" > "$KEY_PATH")
    unset KEY_CONTENT DERIVED_PUBKEY KEY_BODY
fi

# Set up sops-nix key (different from git-agecrypt key)
# Path depends on platform and whether we're on live ISO
if [[ "$HOST_TYPE" == "nixos" ]]; then
    # Live ISO - use /tmp, will be copied to /mnt by partition.sh
    SOPS_KEY_PATH="/tmp/sops-nix-key.txt"
    SOPS_NEEDS_SUDO=false
elif [[ "$PLATFORM" == "Darwin" ]]; then
    SOPS_KEY_PATH="/var/lib/sops-nix/key.txt"
    SOPS_NEEDS_SUDO=true
else
    SOPS_KEY_PATH="/var/lib/sops-nix/key.txt"
    SOPS_NEEDS_SUDO=true
fi

echo -e "${YELLOW}>> Setting up sops-nix key...${NC}"
if [[ "$SOPS_NEEDS_SUDO" == true ]]; then
    sudo mkdir -p "$(dirname "$SOPS_KEY_PATH")"
    if sudo test -f "$SOPS_KEY_PATH" && sudo grep -q "AGE-SECRET-KEY-" "$SOPS_KEY_PATH"; then
        echo -e "${GREEN}>> sops-nix key already exists at ${SOPS_KEY_PATH}${NC}"
    else
        echo -e "${YELLOW}>> Paste your sops-nix age private key (starts with AGE-SECRET-KEY-):${NC}"
        echo "   (This is a DIFFERENT key from git-agecrypt!)"
        read -er KEY_CONTENT < /dev/tty
        if [[ -z "$KEY_CONTENT" ]]; then
            echo -e "${RED}>> Error: No key provided${NC}"
            exit 1
        fi
        if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
            echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
            exit 1
        fi
        echo "$KEY_CONTENT" | sudo tee "$SOPS_KEY_PATH" > /dev/null
        unset KEY_CONTENT
    fi
    sudo chmod 600 "$SOPS_KEY_PATH"
else
    mkdir -p "$(dirname "$SOPS_KEY_PATH")"
    if [ -f "$SOPS_KEY_PATH" ] && grep -q "AGE-SECRET-KEY-" "$SOPS_KEY_PATH"; then
        echo -e "${GREEN}>> sops-nix key already exists at ${SOPS_KEY_PATH}${NC}"
    else
        echo -e "${YELLOW}>> Paste your sops-nix age private key (starts with AGE-SECRET-KEY-):${NC}"
        echo "   (This is a DIFFERENT key from git-agecrypt!)"
        read -er KEY_CONTENT < /dev/tty
        if [[ -z "$KEY_CONTENT" ]]; then
            echo -e "${RED}>> Error: No key provided${NC}"
            exit 1
        fi
        if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
            echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
            exit 1
        fi
        (umask 077 && echo "$KEY_CONTENT" > "$SOPS_KEY_PATH")
        unset KEY_CONTENT
    fi
fi

# Verify sops key matches .sops.yaml
echo -e "${YELLOW}>> Verifying sops-nix key matches configuration...${NC}"
if [[ "$SOPS_NEEDS_SUDO" == true ]]; then
    SOPS_PUBKEY=$(sudo cat "$SOPS_KEY_PATH" | nix-shell -p age --run "age-keygen -y" 2>/dev/null || true)
else
    SOPS_PUBKEY=$(nix-shell -p age --run "age-keygen -y '${SOPS_KEY_PATH}'" 2>/dev/null || true)
fi
if [[ -n "$SOPS_PUBKEY" ]]; then
    SOPS_YAML="${CLONE_DIR}/.sops.yaml"
    if [[ -f "$SOPS_YAML" ]] && ! grep -q "$SOPS_PUBKEY" "$SOPS_YAML"; then
        echo -e "${RED}>> Warning: Your sops key's public key does not match .sops.yaml${NC}"
        echo "   Your public key: $SOPS_PUBKEY"
        echo "   Decryption will fail. Check you pasted the correct key."
        echo ""
        echo -n "Continue anyway? (y/n): "
        read -er CONFIRM < /dev/tty
        if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
            echo -e "${YELLOW}>> Aborted.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}>> Key matches configuration${NC}"
    fi
fi

# Configure git-agecrypt
echo -e "${YELLOW}>> Configuring git-agecrypt filters...${NC}"
# Check if filters are configured AND the binary exists
EXISTING_FILTER=$(cd "$CLONE_DIR" && run_git config --get filter.git-agecrypt.smudge 2>/dev/null || true)
FILTER_BINARY=$(echo "$EXISTING_FILTER" | awk '{print $1}')
if [[ -z "$EXISTING_FILTER" ]] || [[ -n "$FILTER_BINARY" && ! -x "$FILTER_BINARY" ]]; then
    # Filters not configured OR binary is stale (garbage collected)
    if [[ -n "$FILTER_BINARY" && ! -x "$FILTER_BINARY" ]]; then
        echo -e "${YELLOW}>> Existing git-agecrypt filter is stale, reconfiguring...${NC}"
    fi
    nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt init"
else
    echo -e "${GREEN}>> git-agecrypt filters already configured${NC}"
fi
# Check if identity is already configured
if nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt config list --identity" 2>/dev/null | grep -q "${KEY_PATH}"; then
    echo -e "${GREEN}>> git-agecrypt identity already configured${NC}"
else
    # Add identity
    ADD_OUTPUT=$(nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt config add -i '${KEY_PATH}'" 2>&1) || {
        echo -e "${RED}>> Error: Failed to add git-agecrypt identity${NC}"
        echo "$ADD_OUTPUT"
        exit 1
    }
    echo -e "${GREEN}>> git-agecrypt identity configured${NC}"
fi

# Find and decrypt all git-agecrypt.nix files
echo -e "${YELLOW}>> Decrypting secrets...${NC}"

# First pass: check state of all files
FILES_TO_DECRYPT=()
for SECRETS_FILE in "${CLONE_DIR}"/Private/*/git-agecrypt.nix; do
    if [[ ! -f "$SECRETS_FILE" ]]; then
        continue
    fi
    
    DIR_NAME=$(basename "$(dirname "$SECRETS_FILE")")
    
    # Check if already decrypted (starts with { or #)
    FIRST_CHAR=$(head -c1 "$SECRETS_FILE")
    if [[ "$FIRST_CHAR" == "{" || "$FIRST_CHAR" == "#" ]]; then
        echo -e "${GREEN}>> ${DIR_NAME}: Already decrypted${NC}"
        continue
    fi
    
    # Verify it's encrypted
    FIRST_LINE=$(head -n1 "$SECRETS_FILE")
    if [[ "$FIRST_LINE" != "age-encryption.org/v1" ]]; then
        echo -e "${RED}>> ${DIR_NAME}: Neither encrypted nor valid Nix!${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}>> ${DIR_NAME}: Queued for decryption${NC}"
    FILES_TO_DECRYPT+=("Private/${DIR_NAME}/git-agecrypt.nix")
done

# Batch decrypt all files in a single nix-shell invocation
if [[ ${#FILES_TO_DECRYPT[@]} -gt 0 ]]; then
    echo -e "${YELLOW}>> Decrypting ${#FILES_TO_DECRYPT[@]} file(s)...${NC}"
    # Build the checkout command for all files
    CHECKOUT_CMD="cd '${CLONE_DIR}'"
    for FILE in "${FILES_TO_DECRYPT[@]}"; do
        CHECKOUT_CMD+=" && git checkout -- '${FILE}'"
    done
    nix-shell -p git git-agecrypt --run "$CHECKOUT_CMD"
    
    # Verify all decryptions
    for FILE in "${FILES_TO_DECRYPT[@]}"; do
        SECRETS_FILE="${CLONE_DIR}/${FILE}"
        DIR_NAME=$(basename "$(dirname "$SECRETS_FILE")")
        FIRST_CHAR=$(head -c1 "$SECRETS_FILE")
        if [[ "$FIRST_CHAR" == "{" || "$FIRST_CHAR" == "#" ]]; then
            echo -e "${GREEN}>> ${DIR_NAME}: Decrypted successfully${NC}"
        else
            echo -e "${RED}>> ${DIR_NAME}: Decryption failed${NC}"
            exit 1
        fi
    done
fi

SCRIPT_SUCCESS=true

echo ""
echo -e "${GREEN}>> Setup complete!${NC}"
echo ""
echo -e "${YELLOW}>> IMPORTANT: Run this command now (your shell's directory reference is stale):${NC}"
echo ""
echo "  cd ${CLONE_DIR}"
echo ""
echo "Next steps:"
if [[ "$HOST_TYPE" == "nixos" ]]; then
    echo ""
    echo "  # Partition disk (copies sops key automatically, prompts for LUKS passphrase):"
    echo "  ./partition.sh    # Available hosts: ${LINUX_HOSTS[*]}"
    echo ""
    echo "  # Install NixOS:"
    echo "  ./install.sh"
else
    echo ""
    echo "  # Build and switch configuration:"
    echo "  ./install.sh"
fi


#!/usr/bin/env bash

# Stop on error, including in pipes
set -eo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

KNOWN_HOSTS=("nithra")

# --- 0. RESOLVE SCRIPT LOCATION ---
# Get the directory where this script lives (the repo), regardless of where it's called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${YELLOW}>> Working from: ${SCRIPT_DIR}${NC}"

# --- 1. BOOTSTRAP GIT ---
# We need git to stage files, but git might not be installed yet.
# We use 'nix-shell' to borrow git temporarily if it's missing.

echo -e "${YELLOW}>> Checking Git status...${NC}"

# Function to run git commands (natively or via nix-shell)
run_git() {
    if command -v git &> /dev/null; then
        git "$@"
    else
        # Git missing? Use nix-shell with proper argument escaping
        local args=""
        for arg in "$@"; do
            args="$args '${arg//\'/\'\\\'\'}'"
        done
        nix-shell -p git --run "git $args"
    fi
}

# Unstage changes on error to prevent accidental commits
cleanup_on_error() {
    echo -e "${RED}>> Error encountered; unstaging changes...${NC}"
    run_git reset --quiet || true
}
trap cleanup_on_error ERR

ensure_git_agecrypt_filters() {
    if run_git config --get filter.git-agecrypt.smudge > /dev/null 2>&1; then
        return
    fi

    KEY_PATH="$HOME/.config/git-agecrypt/keys.txt"
    if [ ! -f "$KEY_PATH" ]; then
        echo -e "${RED}>> git-agecrypt filters missing and ${KEY_PATH} not found.${NC}"
        echo "   Configure git-agecrypt manually, then rerun install.sh"
        exit 1
    fi

    echo -e "${YELLOW}>> Configuring git-agecrypt filters...${NC}"
    nix-shell -p git-agecrypt --run "cd \"$SCRIPT_DIR\" && git-agecrypt init"
    nix-shell -p git-agecrypt --run "cd \"$SCRIPT_DIR\" && git-agecrypt config add -i \"$KEY_PATH\""

    if ! run_git config --get filter.git-agecrypt.smudge > /dev/null 2>&1; then
        echo -e "${RED}>> git-agecrypt configuration failed; please configure manually.${NC}"
        exit 1
    fi
}

ensure_sops_key() {
    SOPS_KEY="/var/lib/sops-nix/key.txt"
    if [ ! -f "$SOPS_KEY" ]; then
        echo -e "${RED}>> sops-nix key missing at ${SOPS_KEY}${NC}"
        echo "   Copy your age key there (sudo required), then rerun install.sh"
        exit 1
    fi
}

# Initialize repo if missing
if [ ! -d ".git" ]; then
    echo "Initializing Git repository..."
    run_git init
fi

ensure_git_agecrypt_filters
ensure_sops_key

# Format Nix files before staging
echo -e "${YELLOW}>> Formatting Nix files...${NC}"
if ! nix fmt 2>&1 | grep -v "^warning: Git tree"; then
    echo -e "${YELLOW}>> Formatter returned non-zero (may be ok if no .nix files changed)${NC}"
fi

# Stage files (Critical for Flakes)
echo "Staging files..."
run_git add .

# Verify all secrets are encrypted in staging area
echo -e "${YELLOW}>> Verifying secrets are encrypted...${NC}"
SECRETS_OK=true
for SECRETS_FILE in $(run_git ls-files --cached 'Secrets/*/git-agecrypt.nix' 2>/dev/null); do
    FIRST_LINE=$(run_git show ":${SECRETS_FILE}" 2>/dev/null | head -n1 || true)
    if [[ "$FIRST_LINE" != "age-encryption.org/v1" ]]; then
        echo -e "${RED}>> ERROR: ${SECRETS_FILE} is not encrypted in staging area!${NC}"
        echo "   Expected 'age-encryption.org/v1' header, got: ${FIRST_LINE:0:30}"
        SECRETS_OK=false
    fi
done
if [[ "$SECRETS_OK" != true ]]; then
    echo "   Secrets would be exposed if pushed. Aborting."
    exit 1
fi
echo -e "${GREEN}>> Secrets verified encrypted.${NC}"

# Auto-commit if there are staged changes
if ! run_git diff --cached --quiet; then
    echo -e "${YELLOW}>> Committing staged changes...${NC}"
    run_git commit -m "Automatic commit before deploy"
fi

# Auto-push if there are unpushed commits
if run_git rev-parse --abbrev-ref --symbolic-full-name '@{u}' > /dev/null 2>&1; then
    UNPUSHED=$(run_git rev-list '@{u}..HEAD' --count 2>/dev/null || echo "0")
    if [[ "$UNPUSHED" -gt 0 ]]; then
        echo -e "${YELLOW}>> Pushing ${UNPUSHED} commit(s) to remote...${NC}"
        run_git push
    fi
else
    echo -e "${YELLOW}>> No upstream branch set; skipping push.${NC}"
fi

# --- 2. DETERMINE TARGET ---
if [[ -n "$1" ]]; then
    TARGET="$1"
    echo -e "${GREEN}>> Manual override: ${TARGET}${NC}"
else
    CURRENT_HOST=$(hostname)
    
    if [[ " ${KNOWN_HOSTS[*]} " =~ " ${CURRENT_HOST} " ]]; then
        TARGET="$CURRENT_HOST"
        echo -e "${GREEN}>> Detected known host: ${TARGET}${NC}"
        echo -e "   Auto-building in 5 seconds... ${YELLOW}(Ctrl+C to cancel)${NC}"
        sleep 5
    else
        echo -e "${RED}>> Hostname '${CURRENT_HOST}' is unknown.${NC}"
        echo "   Select configuration to install:"
        select opt in "${KNOWN_HOSTS[@]}"; do
            if [[ -n "$opt" ]]; then
                TARGET="$opt"
                break
            else
                echo "Invalid. Try again."
            fi
        done
    fi
fi

# --- 3. BUILD ---
echo -e "${GREEN}>> Building Flake: ${SCRIPT_DIR}#${TARGET}${NC}"

# We use nix-shell -p git here too because nixos-rebuild might need git internally
# to read the flake if it's not in the system path yet.
if command -v git &> /dev/null; then
    sudo nixos-rebuild switch --flake "${SCRIPT_DIR}#${TARGET}" --show-trace
else
    # Bootstrap build command - run nix-shell as user, only nixos-rebuild as root
    nix-shell -p git --run "sudo nixos-rebuild switch --flake '${SCRIPT_DIR}#${TARGET}' --show-trace"
fi

# --- 4. SYMLINK CONFIG (if not already linked) ---
CONFIG_DIR="$HOME/.config/nixos"
if [ ! -e "$CONFIG_DIR" ]; then
    echo -e "${YELLOW}>> Creating symlink: ${CONFIG_DIR} -> ${SCRIPT_DIR}${NC}"
    mkdir -p "$(dirname "$CONFIG_DIR")"
    ln -s "$SCRIPT_DIR" "$CONFIG_DIR"
elif [ -L "$CONFIG_DIR" ]; then
    CURRENT_LINK=$(readlink "$CONFIG_DIR")
    if [ "$CURRENT_LINK" != "$SCRIPT_DIR" ]; then
        echo -e "${YELLOW}>> Updating symlink: ${CONFIG_DIR} -> ${SCRIPT_DIR}${NC}"
        rm "$CONFIG_DIR"
        ln -s "$SCRIPT_DIR" "$CONFIG_DIR"
    fi
elif [ -d "$CONFIG_DIR" ]; then
    echo -e "${RED}>> Warning: ${CONFIG_DIR} is a directory, not a symlink${NC}"
    echo -e "   Remove it manually if you want automatic symlinking"
fi

echo -e "${GREEN}>> Success! System is live as: ${TARGET}${NC}"

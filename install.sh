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
        # Git missing? Run it via nix-shell (--run handles args with spaces properly)
        nix-shell -p git --run "git $*"
    fi
}

# Initialize repo if missing
if [ ! -d ".git" ]; then
    echo "Initializing Git repository..."
    run_git init
fi

# Stage files (Critical for Flakes)
echo "Staging files..."
run_git add .


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

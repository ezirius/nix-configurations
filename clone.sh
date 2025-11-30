#!/usr/bin/env bash

# Clone and set up Nix-Configurations repository
# Run this from a NixOS live installer
#
# Usage:
#   ./clone.sh [host]
#   curl -sL https://raw.githubusercontent.com/Ezirius/Nix-Configurations/main/clone.sh | bash -s -- [host]

set -euo pipefail

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

REPO_URL="https://github.com/Ezirius/Nix-Configurations.git"
CLONE_DIR="/tmp/Nix-Configurations"
KEY_PATH="$HOME/.config/git-agecrypt/keys.txt"
KNOWN_HOSTS=("Nithra")

# Determine target host
if [[ -n "${1:-}" ]]; then
    # Normalise to "Capitalised" format (e.g., "NITHRA" or "nithra" -> "Nithra")
    TARGET_HOST="${1,,}"
    TARGET_HOST="${TARGET_HOST^}"
elif [[ ! -t 0 ]]; then
    # Running from pipe (curl | bash) - can't use interactive select
    echo -e "${RED}>> Error: No host specified and running non-interactively${NC}"
    echo "   Usage: curl ... | bash -s -- <host>"
    echo "   Available hosts: ${KNOWN_HOSTS[*]}"
    exit 1
else
    echo -e "${YELLOW}>> Select host to install:${NC}"
    select opt in "${KNOWN_HOSTS[@]}"; do
        if [[ -n "$opt" ]]; then
            TARGET_HOST="$opt"
            break
        else
            echo "Invalid selection. Try again."
        fi
    done
fi

echo -e "${GREEN}>> Nix-Configurations Clone Setup (${TARGET_HOST})${NC}"

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
        CURRENT_REMOTE=$(nix-shell -p git --run "cd '${CLONE_DIR}' && git remote get-url origin 2>/dev/null" || true)
        if [ "$CURRENT_REMOTE" = "$REPO_URL" ]; then
            echo -e "${YELLOW}>> Repository exists, fetching latest changes...${NC}"
            nix-shell -p git --run "cd '${CLONE_DIR}' && git fetch origin && git reset --hard origin/main"
        else
            echo -e "${YELLOW}>> Directory exists but has different remote, re-cloning...${NC}"
            rm -rf "$CLONE_DIR"
            nix-shell -p git --run "git clone '${REPO_URL}' '${CLONE_DIR}'"
        fi
    else
        echo -e "${YELLOW}>> Directory exists but is not a git repo, re-cloning...${NC}"
        rm -rf "$CLONE_DIR"
        nix-shell -p git --run "git clone '${REPO_URL}' '${CLONE_DIR}'"
    fi
else
    echo -e "${YELLOW}>> Cloning repository...${NC}"
    nix-shell -p git --run "git clone '${REPO_URL}' '${CLONE_DIR}'"
fi
cd "$CLONE_DIR"

# Set up git-agecrypt key
echo -e "${YELLOW}>> Setting up git-agecrypt key...${NC}"
mkdir -p "$(dirname "$KEY_PATH")"

if [ -f "$KEY_PATH" ] && grep -q "AGE-SECRET-KEY-" "$KEY_PATH"; then
    echo -e "${GREEN}>> git-agecrypt key already exists at ${KEY_PATH}${NC}"
else
    echo -e "${YELLOW}>> Paste your git-agecrypt age private key below, then press Ctrl+D:${NC}"
    echo "   (This key decrypts git-agecrypt.nix files. Starts with AGE-SECRET-KEY-...)"
    cat < /dev/tty > "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    echo ""
fi

# Verify git-agecrypt key exists and looks valid
if [ ! -s "$KEY_PATH" ]; then
    echo -e "${RED}>> Error: git-agecrypt key file is empty${NC}"
    exit 1
fi

if ! grep -q "AGE-SECRET-KEY-" "$KEY_PATH"; then
    echo -e "${RED}>> Error: git-agecrypt key file doesn't contain a valid age secret key${NC}"
    exit 1
fi

# Set up sops-nix key (different from git-agecrypt key)
SOPS_KEY_PATH="/tmp/sops-nix-key.txt"
echo -e "${YELLOW}>> Setting up sops-nix key...${NC}"

if [ -f "$SOPS_KEY_PATH" ] && grep -q "AGE-SECRET-KEY-" "$SOPS_KEY_PATH"; then
    echo -e "${GREEN}>> sops-nix key already exists at ${SOPS_KEY_PATH}${NC}"
else
    echo -e "${YELLOW}>> Paste your sops-nix age private key below, then press Ctrl+D:${NC}"
    echo "   (This key decrypts sops-nix.yaml files. Starts with AGE-SECRET-KEY-...)"
    echo "   (This is a DIFFERENT key from git-agecrypt!)"
    cat < /dev/tty > "$SOPS_KEY_PATH"
    chmod 600 "$SOPS_KEY_PATH"
    echo ""
fi

# Verify sops-nix key exists and looks valid
if [ ! -s "$SOPS_KEY_PATH" ]; then
    echo -e "${RED}>> Error: sops-nix key file is empty${NC}"
    exit 1
fi

if ! grep -q "AGE-SECRET-KEY-" "$SOPS_KEY_PATH"; then
    echo -e "${RED}>> Error: sops-nix key file doesn't contain a valid age secret key${NC}"
    exit 1
fi

# Configure git-agecrypt
echo -e "${YELLOW}>> Configuring git-agecrypt filters...${NC}"
# Only run init if filters not already configured
if ! nix-shell -p git --run "cd '${CLONE_DIR}' && git config --get filter.git-agecrypt.smudge" &>/dev/null; then
    nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt init"
else
    echo -e "${GREEN}>> git-agecrypt filters already configured${NC}"
fi
# Only add identity if not already configured
if ! nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt config list" 2>/dev/null | grep -q "${KEY_PATH}"; then
    nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt config add -i '${KEY_PATH}'"
else
    echo -e "${GREEN}>> git-agecrypt identity already configured${NC}"
fi

# Find secrets file for target host
SECRETS_FILE="${CLONE_DIR}/Secrets/${TARGET_HOST}/git-agecrypt.nix"
if [ ! -f "$SECRETS_FILE" ]; then
    echo -e "${RED}>> Error: Secrets file not found: ${SECRETS_FILE}${NC}"
    echo "   Available hosts:"
    ls -1 "${CLONE_DIR}/Secrets/" 2>/dev/null | sed 's/^/     /'
    exit 1
fi

# Check if secrets are already decrypted or need decryption
FIRST_CHAR=$(head -c1 "$SECRETS_FILE")
if [ "$FIRST_CHAR" = "{" ]; then
    echo -e "${GREEN}>> Secrets already decrypted${NC}"
else
    # Verify secrets are encrypted
    echo -e "${YELLOW}>> Verifying secrets are encrypted in repo...${NC}"
    FIRST_LINE=$(head -n1 "$SECRETS_FILE")
    if [ "$FIRST_LINE" != "age-encryption.org/v1" ]; then
        echo -e "${RED}>> Error: Secrets file is neither encrypted nor valid Nix!${NC}"
        echo "   Expected 'age-encryption.org/v1' or '{', got: ${FIRST_LINE:0:30}"
        exit 1
    fi
    echo -e "${GREEN}>> Secrets are encrypted${NC}"

    # Decrypt secrets
    echo -e "${YELLOW}>> Decrypting secrets...${NC}"
    nix-shell -p git --run "cd '${CLONE_DIR}' && git checkout -- 'Secrets/${TARGET_HOST}/git-agecrypt.nix'"

    # Verify decryption
    FIRST_CHAR=$(head -c1 "$SECRETS_FILE")
    if [ "$FIRST_CHAR" = "{" ]; then
        echo -e "${GREEN}>> Secrets decrypted successfully${NC}"
    else
        echo -e "${RED}>> Error: Secrets file doesn't appear to be decrypted${NC}"
        echo "   Expected Nix attribute set, got: $(head -n1 "$SECRETS_FILE" | head -c50)"
        exit 1
    fi
fi

SCRIPT_SUCCESS=true

echo ""
echo -e "${GREEN}>> Setup complete!${NC}"
echo ""
echo "Next steps:"
echo "  cd ${CLONE_DIR}"
echo ""
echo "  # Partition disk (will prompt for LUKS passphrase):"
echo "  sudo nix --experimental-features 'nix-command flakes' run github:nix-community/disko -- \\"
echo "    --mode disko ${CLONE_DIR}/Hosts/${TARGET_HOST}/disko-config.nix"
echo ""
echo "  # Copy sops-nix key to target system:"
echo "  sudo mkdir -p /mnt/var/lib/sops-nix"
echo "  sudo cp '${SOPS_KEY_PATH}' /mnt/var/lib/sops-nix/key.txt"
echo "  sudo chmod 600 /mnt/var/lib/sops-nix/key.txt"
echo ""
echo "  # Install (flake target is lowercase):"
echo "  sudo nixos-install --flake ${CLONE_DIR}#${TARGET_HOST,,} --no-root-passwd"
echo ""
echo "  # After reboot, set up git-agecrypt for the new user:"
echo "  mkdir -p ~/.config/git-agecrypt"
echo "  # Copy your git-agecrypt key (from password manager or existing machine)"
echo "  # to ~/.config/git-agecrypt/keys.txt"
echo "  chmod 600 ~/.config/git-agecrypt/keys.txt"

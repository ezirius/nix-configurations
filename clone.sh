#!/usr/bin/env bash

# Clone and set up Nix-Configurations repository
# Run this from a NixOS live installer
#
# Usage:
#   ./clone.sh [host]
#   curl -sL https://raw.githubusercontent.com/Ezirius/Nix-Configurations/main/clone.sh | bash -s -- [host]
#
# If host is not specified, defaults to 'nithra'

set -euo pipefail

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

REPO_URL="https://github.com/Ezirius/Nix-Configurations.git"
CLONE_DIR="/tmp/Nix-Configurations"
KEY_PATH="$HOME/.config/git-agecrypt/keys.txt"
TARGET_HOST="${1:-nithra}"

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

# Check if already cloned
if [ -d "$CLONE_DIR/.git" ]; then
    echo -e "${YELLOW}>> Repository already cloned at ${CLONE_DIR}${NC}"
    echo "   Delete it first if you want to re-clone: rm -rf ${CLONE_DIR}"
    exit 1
fi

# Check network connectivity
echo -e "${YELLOW}>> Checking network...${NC}"
if ! ping -c 1 github.com &>/dev/null; then
    echo -e "${RED}>> Error: Cannot reach github.com${NC}"
    echo "   Configure network first, then rerun this script"
    exit 1
fi

# Clone repository
echo -e "${YELLOW}>> Cloning repository...${NC}"
nix-shell -p git --run "git clone '${REPO_URL}' '${CLONE_DIR}'"
cd "$CLONE_DIR"

# Set up age key
echo -e "${YELLOW}>> Setting up git-agecrypt...${NC}"
mkdir -p "$(dirname "$KEY_PATH")"

if [ ! -f "$KEY_PATH" ]; then
    echo -e "${YELLOW}>> Paste your age private key below, then press Ctrl+D:${NC}"
    echo "   (Should start with AGE-SECRET-KEY-...)"
    cat > "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    echo ""
fi

# Verify key exists and looks valid
if [ ! -s "$KEY_PATH" ]; then
    echo -e "${RED}>> Error: Key file is empty${NC}"
    exit 1
fi

if ! grep -q "AGE-SECRET-KEY-" "$KEY_PATH"; then
    echo -e "${RED}>> Error: Key file doesn't contain a valid age secret key${NC}"
    exit 1
fi

echo -e "${GREEN}>> Age key saved to ${KEY_PATH}${NC}"

# Configure git-agecrypt
echo -e "${YELLOW}>> Configuring git-agecrypt filters...${NC}"
nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt init"
nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt config add -i '${KEY_PATH}'"

# Find secrets file for target host
SECRETS_FILE="${CLONE_DIR}/Secrets/${TARGET_HOST^}/git-agecrypt.nix"
if [ ! -f "$SECRETS_FILE" ]; then
    echo -e "${RED}>> Error: Secrets file not found: ${SECRETS_FILE}${NC}"
    echo "   Available hosts:"
    ls -1 "${CLONE_DIR}/Secrets/" 2>/dev/null | sed 's/^/     /'
    exit 1
fi

# Verify secrets are encrypted in repo
echo -e "${YELLOW}>> Verifying secrets are encrypted in repo...${NC}"
FIRST_LINE=$(head -n1 "$SECRETS_FILE")
if [ "$FIRST_LINE" != "age-encryption.org/v1" ]; then
    echo -e "${RED}>> Error: Secrets file is not encrypted!${NC}"
    echo "   Expected 'age-encryption.org/v1', got: ${FIRST_LINE:0:30}"
    exit 1
fi
echo -e "${GREEN}>> Secrets are encrypted${NC}"

# Decrypt secrets
echo -e "${YELLOW}>> Decrypting secrets...${NC}"
nix-shell -p git --run "cd '${CLONE_DIR}' && git checkout -- 'Secrets/${TARGET_HOST^}/git-agecrypt.nix'"

# Verify decryption
FIRST_LINE=$(head -n1 "$SECRETS_FILE")
if [ "$FIRST_LINE" = "# This file is encrypted with git-agecrypt" ]; then
    echo -e "${GREEN}>> Secrets decrypted successfully${NC}"
else
    echo -e "${RED}>> Error: Secrets file doesn't appear to be decrypted${NC}"
    echo "   First line: ${FIRST_LINE:0:50}"
    exit 1
fi

SCRIPT_SUCCESS=true

echo ""
echo -e "${GREEN}>> Setup complete!${NC}"
echo ""
echo "Next steps:"
echo "  cd ${CLONE_DIR}"
echo ""
echo "  # Partition disk (will prompt for LUKS passphrase):"
echo "  sudo nix --experimental-features 'nix-command flakes' run github:nix-community/disko -- --mode disko ${CLONE_DIR}/Hosts/${TARGET_HOST^}/disko-config.nix"
echo ""
echo "  # Copy age key to target system:"
echo "  sudo mkdir -p /mnt/var/lib/sops-nix"
echo "  sudo cp '${KEY_PATH}' /mnt/var/lib/sops-nix/key.txt"
echo "  sudo chmod 600 /mnt/var/lib/sops-nix/key.txt"
echo ""
echo "  # Install:"
echo "  sudo nixos-install --flake ${CLONE_DIR}#${TARGET_HOST} --no-root-passwd"
echo ""
echo "  # After reboot, copy age key for git-agecrypt:"
echo "  mkdir -p ~/.config/git-agecrypt"
echo "  sudo cp /var/lib/sops-nix/key.txt ~/.config/git-agecrypt/keys.txt"
echo "  sudo chown \$(whoami) ~/.config/git-agecrypt/keys.txt"
echo "  chmod 600 ~/.config/git-agecrypt/keys.txt"

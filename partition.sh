#!/usr/bin/env bash

# Partition disk for NixOS installation using disko
# Run this after clone.sh, before nixos-install
#
# Usage:
#   ./partition.sh [host]

set -euo pipefail

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWN_HOSTS=("Nithra")

# Determine target host
if [[ -n "${1:-}" ]]; then
    # Normalise to "Capitalised" format (e.g., "NITHRA" or "nithra" -> "Nithra")
    TARGET_HOST="${1,,}"
    TARGET_HOST="${TARGET_HOST^}"
elif [[ ! -t 0 ]]; then
    # Running from pipe - can't use interactive select
    echo -e "${RED}>> Error: No host specified and running non-interactively${NC}"
    echo "   Usage: ./partition.sh <host>"
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

echo -e "${GREEN}>> Partition Setup (${TARGET_HOST})${NC}"

# Verify disko config exists
DISKO_CONFIG="${SCRIPT_DIR}/Hosts/${TARGET_HOST}/disko-config.nix"
if [[ ! -f "$DISKO_CONFIG" ]]; then
    echo -e "${RED}>> Error: Disko config not found: ${DISKO_CONFIG}${NC}"
    exit 1
fi

# Extract disk device from disko-config.nix
echo -e "${YELLOW}>> Reading disk configuration...${NC}"
SELECTED_DISK=$(grep -oP 'device\s*=\s*"\K/dev/[^"]+' "$DISKO_CONFIG" | head -1)

if [[ -z "$SELECTED_DISK" ]]; then
    echo -e "${RED}>> Error: Could not parse disk device from ${DISKO_CONFIG}${NC}"
    echo "   Expected 'device = \"/dev/xxx\";' in the file"
    exit 1
fi

echo -e "${GREEN}>> Disko configured for: ${SELECTED_DISK}${NC}"

# Verify disk exists
if [[ ! -b "$SELECTED_DISK" ]]; then
    echo -e "${RED}>> Error: Disk ${SELECTED_DISK} not found${NC}"
    echo ""
    echo "Available disks:"
    lsblk -dpno NAME,SIZE,MODEL | while read -r line; do
        echo "  $line"
    done
    echo ""
    echo "Update ${DISKO_CONFIG} with the correct device path."
    exit 1
fi

# Show disk details
SIZE=$(lsblk -dpno SIZE "$SELECTED_DISK" 2>/dev/null || echo "unknown")
MODEL=$(lsblk -dpno MODEL "$SELECTED_DISK" 2>/dev/null | xargs || echo "unknown")
echo ""
echo "Disk details:"
echo "  Device: ${SELECTED_DISK}"
echo "  Size:   ${SIZE}"
echo "  Model:  ${MODEL}"

# Show current partitions
PARTS=$(lsblk -pno NAME,SIZE,FSTYPE "$SELECTED_DISK" 2>/dev/null | tail -n +2 || true)
if [[ -n "$PARTS" ]]; then
    echo "  Current partitions:"
    echo "$PARTS" | while read -r line; do
        echo "    └─ $line"
    done
fi

echo ""
echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║                        WARNING                                 ║${NC}"
echo -e "${RED}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║  This will PERMANENTLY DESTROY all data on:                    ║${NC}"
echo -e "${RED}║                                                                ║${NC}"
printf "${RED}║  %-62s║${NC}\n" "  ${SELECTED_DISK}"
echo -e "${RED}║                                                                ║${NC}"
echo -e "${RED}║  This action is IRREVERSIBLE.                                  ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Require explicit confirmation
echo -n "Type 'yes' to proceed: "
read -r CONFIRM < /dev/tty

if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${YELLOW}>> Aborted. No changes made.${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}>> Wiping existing partitions on ${SELECTED_DISK}...${NC}"
sudo wipefs -a "$SELECTED_DISK"

echo ""
echo -e "${YELLOW}>> Running disko (you will be prompted for LUKS passphrase)...${NC}"
echo ""

sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
    --mode disko "$DISKO_CONFIG"

echo ""
echo -e "${GREEN}>> Partitioning complete!${NC}"
echo ""
echo "Next steps:"
echo "  # Copy sops-nix key to target system:"
echo "  sudo mkdir -p /mnt/var/lib/sops-nix"
echo "  sudo cp /tmp/sops-nix-key.txt /mnt/var/lib/sops-nix/key.txt"
echo "  sudo chmod 600 /mnt/var/lib/sops-nix/key.txt"
echo ""
echo "  # Install (flake target is lowercase):"
echo "  sudo nixos-install --flake ${SCRIPT_DIR}#${TARGET_HOST,,} --no-root-passwd"

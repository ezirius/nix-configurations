#!/usr/bin/env bash

# Partition disk for NixOS installation using disko
# Run this after clone.sh, before nixos-install
#
# Usage:
#   ./partition.sh [host]

set -euo pipefail

# Note: 'set -o pipefail' ensures piped commands propagate failures.
# If a command fails unexpectedly, check each pipeline stage individually.

# Require bash 4.0+ for ${var,,} and ${var^} syntax
if ((BASH_VERSINFO[0] < 4)); then
    echo "Error: bash 4.0+ required (you have ${BASH_VERSION})"
    echo "Run with: nix-shell -p bash --run './partition.sh'"
    exit 1
fi

# Help function
show_help() {
    cat <<'EOF'
Usage: ./partition.sh [host]

Partition disk for NixOS installation using disko.

Arguments:
  host    Target host configuration (optional, interactive if not provided)
          Available: Nithra

Options:
  -h, --help    Show this help message

This script:
  1. Reads disk device from Hosts/<host>/disko-config.nix
  2. Shows disk details and confirmation prompt
  3. Securely erases the disk (TRIM/discard)
  4. Prompts for LUKS passphrase (min 20 chars, all 4 character classes)
  5. Runs disko to partition and encrypt
  6. Copies sops-nix key to /mnt

WARNING: This permanently destroys all data on the target disk!

Prerequisites:
  - Must run from NixOS live installer
  - Run ./clone.sh first

Examples:
  ./partition.sh           # Interactive host selection
  ./partition.sh Nithra    # Partition for Nithra
EOF
}

# Parse arguments
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Libraries/lib.sh
source "${SCRIPT_DIR}/Libraries/lib.sh"

cd "$SCRIPT_DIR"

echo -e "${YELLOW}>> Working from: ${SCRIPT_DIR}${NC}"

# Classify hostname and print message
classify_hostname
print_host_message

# Only allow partition from NixOS live installer
case "$HOST_TYPE" in
    nixos)
        # Continue - this is the expected case
        ;;
    known)
        echo -e "${RED}>> Error: partition.sh must be run from NixOS live installer${NC}"
        echo "   You are on an installed system (${DETECTED_HOST})."
        echo "   This script wipes disks and is only safe from a live ISO."
        exit 1
        ;;
    other)
        echo -e "${RED}>> Error: partition.sh must be run from NixOS live installer${NC}"
        echo "   This script wipes disks and is only safe from a live ISO."
        exit 1
        ;;
esac

# Determine target host
if [[ -n "${1:-}" ]]; then
    # Normalise to "Capitalised" format (e.g., "NITHRA" or "nithra" -> "Nithra")
    TARGET_HOST=$(normalise_host "$1")
    
    # Validate host argument against Linux hosts only
    if ! validate_host_arg "$1" "${LINUX_HOSTS[@]}"; then
        echo -e "${RED}>> Error: '${1}' is not a valid Linux host${NC}"
        echo "   Available hosts: ${LINUX_HOSTS[*]}"
        exit 1
    fi
elif [[ ! -t 0 ]]; then
    # Running from pipe - can't use interactive select
    echo -e "${RED}>> Error: No host specified${NC}"
    echo "   Usage: ./partition.sh <host>"
    echo "   Available hosts: ${LINUX_HOSTS[*]}"
    exit 1
else
    echo -e "${YELLOW}>> Select host to install:${NC}"
    select opt in "${LINUX_HOSTS[@]}"; do
        if [[ -n "$opt" ]]; then
            TARGET_HOST="$opt"
            break
        else
            echo "Invalid selection. Try again."
        fi
    done </dev/tty
fi

echo -e "${GREEN}>> Partition Setup (${TARGET_HOST})${NC}"

# Cleanup warning on error after disk modifications begin
DISK_MODIFIED=false
cleanup_partial_state() {
    if [[ "$DISK_MODIFIED" == true ]]; then
        echo ""
        echo -e "${RED}>> WARNING: Script failed after disk was modified!${NC}"
        echo -e "${RED}>> Disk ${SELECTED_DISK:-unknown} may be in a partial state.${NC}"
        echo "   You may need to re-run this script or manually partition."
    fi
}
trap cleanup_partial_state EXIT
trap "exit 1" INT TERM

# Verify disko config exists
DISKO_CONFIG="${SCRIPT_DIR}/Hosts/${TARGET_HOST}/disko-config.nix"
if [[ ! -f "$DISKO_CONFIG" ]]; then
    echo -e "${RED}>> Error: Disko config not found: ${DISKO_CONFIG}${NC}"
    exit 1
fi

# Extract disk device from disko-config.nix
echo -e "${YELLOW}>> Reading disk configuration...${NC}"

# Try nix eval first (more reliable), fall back to grep if it fails
# The disko config structure is: disko.devices.disk.<name>.device
# --file imports the config, so we access .disko.devices.disk directly
SELECTED_DISK=""
if command -v nix &> /dev/null; then
    SELECTED_DISK=$(nix --extra-experimental-features nix-command eval --file "$DISKO_CONFIG" --raw \
        '(builtins.head (builtins.attrValues .disko.devices.disk)).device' \
        2>/dev/null || true)
fi

# Fallback to grep if nix eval failed
if [[ -z "$SELECTED_DISK" ]]; then
    SELECTED_DISK=$(grep -o 'device = "/dev/[^"]*"' "$DISKO_CONFIG" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
fi

if [[ -z "$SELECTED_DISK" ]]; then
    echo -e "${RED}>> Error: Could not parse disk device from ${DISKO_CONFIG}${NC}"
    echo "   Expected 'device = \"/dev/xxx\";' in the file"
    exit 1
fi

echo -e "${GREEN}>> Disko configured for: ${SELECTED_DISK}${NC}"

# Pre-validate disko configuration syntax
echo -e "${YELLOW}>> Validating disko configuration...${NC}"
if ! nix --extra-experimental-features nix-command eval --file "$DISKO_CONFIG" &>/dev/null; then
    echo -e "${RED}>> Error: Invalid disko configuration syntax${NC}"
    echo "   Run: nix --extra-experimental-features nix-command eval --file '$DISKO_CONFIG'"
    exit 1
fi
echo -e "${GREEN}>> Disko configuration valid${NC}"

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

# Check for mounted partitions on target disk
# Match disk and any partition numbers (e.g., /dev/sda, /dev/sda1, /dev/nvme0n1p1)
MOUNTED_PARTS=$(mount | grep -E "^${SELECTED_DISK}[p0-9]*\s" || true)
if [[ -n "$MOUNTED_PARTS" ]]; then
    echo -e "${RED}>> Error: ${SELECTED_DISK} has mounted partitions${NC}"
    echo ""
    echo "Mounted partitions:"
    echo "$MOUNTED_PARTS" | while read -r line; do
        echo "  $line"
    done
    echo ""
    echo "Unmount all partitions first: sudo umount ${SELECTED_DISK}*"
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
# Calculate box width dynamically based on disk path length
DISK_DISPLAY="  ${SELECTED_DISK}"
BOX_WIDTH=66
# Ensure minimum width for the warning text
if [[ ${#DISK_DISPLAY} -gt 60 ]]; then
    BOX_WIDTH=$((${#DISK_DISPLAY} + 6))
fi
INNER_WIDTH=$((BOX_WIDTH - 2))

# Build horizontal line (same for top, middle, bottom)
HLINE=$(printf '═%.0s' $(seq 1 $BOX_WIDTH))

echo -e "${RED}╔${HLINE}╗${NC}"
printf "${RED}║%-${INNER_WIDTH}s║${NC}\n" "                        WARNING"
echo -e "${RED}╠${HLINE}╣${NC}"
printf "${RED}║%-${INNER_WIDTH}s║${NC}\n" "  This will PERMANENTLY DESTROY all data on:"
printf "${RED}║%-${INNER_WIDTH}s║${NC}\n" ""
printf "${RED}║%-${INNER_WIDTH}s║${NC}\n" "$DISK_DISPLAY"
printf "${RED}║%-${INNER_WIDTH}s║${NC}\n" ""
printf "${RED}║%-${INNER_WIDTH}s║${NC}\n" "  This action is IRREVERSIBLE."
echo -e "${RED}╚${HLINE}╝${NC}"
echo ""

# Require explicit confirmation (risky operation - exact YES required)
echo -n "Type YES to proceed (YES/n): "
read -er CONFIRM < /dev/tty

if [[ "$CONFIRM" != "YES" ]]; then
    echo -e "${YELLOW}>> Aborted. No changes made.${NC}"
    exit 0
fi

echo ""
DISK_MODIFIED=true
echo -e "${YELLOW}>> Securely erasing ${SELECTED_DISK}...${NC}"
if sudo blkdiscard "$SELECTED_DISK" 2>/dev/null; then
    echo -e "${GREEN}>> SSD TRIM/discard complete${NC}"
else
    echo -e "${YELLOW}>> blkdiscard not supported (not an SSD or device doesn't support TRIM)${NC}"
fi

echo -e "${YELLOW}>> Wiping partition signatures on ${SELECTED_DISK}...${NC}"
sudo wipefs -a "$SELECTED_DISK"

echo ""
echo -e "${YELLOW}>> Enter LUKS passphrase for disk encryption:${NC}"
read -rs LUKS_PASS </dev/tty
echo
echo -e "${YELLOW}>> Confirm LUKS passphrase:${NC}"
read -rs LUKS_PASS_CONFIRM </dev/tty
echo

if [[ -z "$LUKS_PASS" ]]; then
    echo -e "${RED}>> Error: Passphrase cannot be empty${NC}"
    exit 1
fi

if [[ ${#LUKS_PASS} -lt 20 ]]; then
    echo -e "${RED}>> Error: Passphrase must be at least 20 characters${NC}"
    exit 1
fi

# Check for character diversity (all 4 classes required)
CLASSES=0
[[ "$LUKS_PASS" =~ [a-z] ]] && CLASSES=$((CLASSES + 1))
[[ "$LUKS_PASS" =~ [A-Z] ]] && CLASSES=$((CLASSES + 1))
[[ "$LUKS_PASS" =~ [0-9] ]] && CLASSES=$((CLASSES + 1))
[[ "$LUKS_PASS" =~ [^a-zA-Z0-9] ]] && CLASSES=$((CLASSES + 1))

if [[ $CLASSES -lt 4 ]]; then
    echo -e "${RED}>> Error: Passphrase must contain all of: lowercase, uppercase, numbers, and symbols${NC}"
    exit 1
fi

if [[ "$LUKS_PASS" != "$LUKS_PASS_CONFIRM" ]]; then
    echo -e "${RED}>> Passphrases do not match!${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}>> Running disko...${NC}"
echo ""

# Pass password via stdin using process substitution to avoid command-line exposure
# The password is written to a file descriptor, not visible in ps output
sudo nix --experimental-features 'nix-command flakes' run github:nix-community/disko -- \
    --mode disko "$DISKO_CONFIG" < <(printf '%s\n%s\n' "$LUKS_PASS" "$LUKS_PASS")

unset LUKS_PASS LUKS_PASS_CONFIRM

DISK_MODIFIED=false  # Disko completed successfully

echo ""
echo -e "${GREEN}>> Partitioning complete!${NC}"

# Copy sops-nix key to target system
SOPS_KEY_PATH="/tmp/sops-nix-key.txt"
if [[ -f "$SOPS_KEY_PATH" ]]; then
    echo ""
    echo -e "${YELLOW}>> Copying sops-nix key to target system...${NC}"
    sudo mkdir -p /mnt/var/lib/sops-nix
    sudo cp "$SOPS_KEY_PATH" /mnt/var/lib/sops-nix/key.txt
    sudo chmod 600 /mnt/var/lib/sops-nix/key.txt
    sudo chown root:root /mnt/var/lib/sops-nix/key.txt
    echo -e "${GREEN}>> Sops-nix key installed${NC}"
else
    echo ""
    echo -e "${YELLOW}>> Warning: Sops-nix key not found at ${SOPS_KEY_PATH}${NC}"
    echo "   You will need to copy it manually before installing:"
    echo "   sudo mkdir -p /mnt/var/lib/sops-nix"
    echo "   sudo cp <your-key-path> /mnt/var/lib/sops-nix/key.txt"
    echo "   sudo chmod 600 /mnt/var/lib/sops-nix/key.txt"
    echo "   sudo chown root:root /mnt/var/lib/sops-nix/key.txt"
fi

echo ""
echo "Next step:"
echo "  ./install.sh ${TARGET_HOST}"


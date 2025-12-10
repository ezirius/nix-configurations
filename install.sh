#!/usr/bin/env bash

# Build and deploy Nix configuration
# Run ./git.sh first to commit and push changes
#
# Usage:
#   ./install.sh [host]

set -euo pipefail

# Note: 'set -o pipefail' ensures piped commands propagate failures.
# If a command fails unexpectedly, check each pipeline stage individually.

# Require bash 4.0+ for ${var,,} and ${var^} syntax
if ((BASH_VERSINFO[0] < 4)); then
    echo "Error: bash 4.0+ required (you have ${BASH_VERSION})"
    echo "On macOS, run with: nix-shell -p bash --run './install.sh'"
    exit 1
fi

# Help function
show_help() {
    cat <<'EOF'
Usage: ./install.sh [host]

Build and deploy Nix configuration for the current system.

Arguments:
  host    Target host configuration (optional, auto-detected if not provided)
          Available: Nithra (NixOS), Maldoria (Darwin)

Options:
  -h, --help    Show this help message

Prerequisites:
  - Run ./git.sh first to commit and push changes
  - On live ISO: run ./clone.sh and ./partition.sh first

Examples:
  ./install.sh              # Auto-detect host and deploy
  ./install.sh Nithra       # Deploy Nithra configuration
  ./install.sh Maldoria     # Deploy Maldoria configuration
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

# Classify hostname and print message
classify_hostname
print_host_message

# Validate hostname and platform
case "$HOST_TYPE" in
    nixos)
        # Ensure running interactively (not piped) - needed for interactive host selection
        if [[ ! -t 0 ]]; then
            echo -e "${RED}>> Error: install.sh must be run interactively on live ISO, not piped${NC}"
            exit 1
        fi
        ;;
    known)
        # Validate platform matches host
        if ! validate_host_platform "$DETECTED_HOST"; then
            if [[ "$PLATFORM" == "Darwin" ]]; then
                echo -e "${RED}>> Error: ${DETECTED_HOST} is a Linux host but you are on Darwin${NC}"
            else
                echo -e "${RED}>> Error: ${DETECTED_HOST} is a Darwin host but you are on Linux${NC}"
            fi
            exit 1
        fi
        ;;
    other)
        echo -e "${RED}>> Error: Unknown hostname '${CURRENT_HOST}'${NC}"
        echo "   Supported hosts: nixos (live ISO), ${ALL_HOSTS[*]}"
        echo "   To add a new host, see README.md: \"Forking for your own use\""
        exit 1
        ;;
esac

cd "$SCRIPT_DIR"

echo -e "${YELLOW}>> Working from: ${SCRIPT_DIR}${NC}"

# Unstage changes on error to prevent accidental partial commits
cleanup_on_error() {
    echo -e "${RED}>> Error encountered; unstaging changes...${NC}"
    run_git reset --quiet 2>/dev/null || true
}
trap cleanup_on_error ERR

ensure_sops_key() {
    if [[ "$PLATFORM" == "Darwin" ]]; then
        SOPS_KEY="/var/lib/sops-nix/key.txt"
        if sudo test -s "$SOPS_KEY" && sudo grep -q "AGE-SECRET-KEY-" "$SOPS_KEY"; then
            echo -e "${GREEN}>> sops-nix key already exists at ${SOPS_KEY}${NC}"
            return
        fi
        
        echo -e "${YELLOW}>> sops-nix key missing or invalid at ${SOPS_KEY}${NC}"
        echo ""
        echo "Paste your sops-nix age private key (starts with AGE-SECRET-KEY-)."
        echo "This key decrypts sops-nix.yaml files."
        echo ""
        read -er KEY_CONTENT </dev/tty
        if [[ -z "$KEY_CONTENT" ]]; then
            echo -e "${RED}>> No key provided. Aborting.${NC}"
            exit 1
        fi
        if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
            echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
            exit 1
        fi
        sudo mkdir -p "$(dirname "$SOPS_KEY")"
        echo "$KEY_CONTENT" | sudo tee "$SOPS_KEY" > /dev/null
        sudo chmod 600 "$SOPS_KEY"
        unset KEY_CONTENT
        echo -e "${GREEN}>> sops-nix key saved to ${SOPS_KEY}${NC}"
    elif [[ "$HOST_TYPE" == "nixos" ]]; then
        # Live ISO - key should be at /mnt (copied by partition.sh)
        SOPS_KEY="/mnt/var/lib/sops-nix/key.txt"
        if ! sudo test -s "$SOPS_KEY" || ! sudo grep -q "AGE-SECRET-KEY-" "$SOPS_KEY"; then
            echo -e "${RED}>> Error: sops-nix key not found at ${SOPS_KEY}${NC}"
            echo "   Run ./partition.sh first (it copies the key from /tmp)"
            exit 1
        fi
        echo -e "${GREEN}>> sops-nix key found at ${SOPS_KEY}${NC}"
    else
        # Installed NixOS system
        SOPS_KEY="/var/lib/sops-nix/key.txt"
        if sudo test -s "$SOPS_KEY" && sudo grep -q "AGE-SECRET-KEY-" "$SOPS_KEY"; then
            echo -e "${GREEN}>> sops-nix key already exists at ${SOPS_KEY}${NC}"
            return
        fi
        
        echo -e "${YELLOW}>> sops-nix key missing or invalid at ${SOPS_KEY}${NC}"
        echo ""
        echo "Paste your sops-nix age private key (starts with AGE-SECRET-KEY-)."
        echo "This key decrypts sops-nix.yaml files."
        echo ""
        read -er KEY_CONTENT </dev/tty
        if [[ -z "$KEY_CONTENT" ]]; then
            echo -e "${RED}>> No key provided. Aborting.${NC}"
            exit 1
        fi
        if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
            echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
            exit 1
        fi
        sudo mkdir -p "$(dirname "$SOPS_KEY")"
        echo "$KEY_CONTENT" | sudo tee "$SOPS_KEY" > /dev/null
        unset KEY_CONTENT
        sudo chmod 600 "$SOPS_KEY"
        echo -e "${GREEN}>> sops-nix key saved to ${SOPS_KEY}${NC}"
    fi
}

# Initialise repo if missing
if [[ ! -d ".git" ]]; then
    echo "Initialising Git repository..."
    run_git init
fi

echo -e "${GREEN}>> NixOS/Darwin Build & Deploy${NC}"

# Validate and determine target host
if [[ "$HOST_TYPE" == "nixos" ]]; then
    # On live ISO: arg or interactive, validate against Linux hosts
    if [[ -n "${1:-}" ]]; then
        if ! validate_host_arg "$1" "${LINUX_HOSTS[@]}"; then
            echo -e "${RED}>> Error: '${1}' is not a valid Linux host${NC}"
            echo "   Available hosts: ${LINUX_HOSTS[*]}"
            exit 1
        fi
    fi
else
    # On known host: arg must match hostname or be omitted
    if [[ -n "${1:-}" ]]; then
        ARG_NORMALISED=$(normalise_host "$1")
        if [[ "$ARG_NORMALISED" != "$DETECTED_HOST" ]]; then
            echo -e "${RED}>> Error: Argument '${1}' does not match hostname '${DETECTED_HOST}'${NC}"
            echo "   On installed systems, omit the argument or use: ./install.sh ${DETECTED_HOST}"
            exit 1
        fi
    fi
fi

ensure_git_agecrypt_filters
ensure_sops_key

# Verify secrets are decrypted
echo -e "${YELLOW}>> Verifying secrets are decrypted...${NC}"
for SECRETS_FILE in "${SCRIPT_DIR}"/Private/*/git-agecrypt.nix; do
    if [[ ! -f "$SECRETS_FILE" ]]; then
        continue
    fi
    HOST_NAME=$(basename "$(dirname "$SECRETS_FILE")")
    FIRST_CHAR=$(head -c1 "$SECRETS_FILE")
    if [[ "$FIRST_CHAR" != "{" && "$FIRST_CHAR" != "#" ]]; then
        echo -e "${RED}>> Error: ${HOST_NAME}/git-agecrypt.nix is not decrypted${NC}"
        echo "   Run: nix-shell -p git git-agecrypt --run \"git checkout -- Private/${HOST_NAME}/git-agecrypt.nix\""
        exit 1
    fi
done
echo -e "${GREEN}>> Secrets decrypted${NC}"

# On live ISO, skip uncommitted changes check (git-agecrypt.nix is decrypted locally)
# On installed systems, require all changes to be committed (except git-agecrypt.nix which is always decrypted locally)
if [[ "$HOST_TYPE" == "nixos" ]]; then
    echo -e "${YELLOW}>> Live ISO: Using local working directory (secrets decrypted locally)${NC}"
    # Ensure nothing is staged (flakes use working directory for tracked files)
    run_git reset --quiet 2>/dev/null || true
else
    # Check for uncommitted changes (staged, unstaged, or untracked)
    # Exclude git-agecrypt.nix files - they're always decrypted locally and show as "changed"
    STAGED=$(run_git diff --cached --name-only 2>/dev/null | grep -v 'git-agecrypt\.nix$' || true)
    UNSTAGED=$(run_git diff --name-only 2>/dev/null | grep -v 'git-agecrypt\.nix$' || true)
    UNTRACKED=$(run_git ls-files --others --exclude-standard 2>/dev/null || true)
    if [[ -n "$STAGED" || -n "$UNSTAGED" || -n "$UNTRACKED" ]]; then
        echo -e "${RED}>> Error: You have uncommitted changes${NC}"
        echo ""
        [[ -n "$STAGED" ]] && echo "Staged:" && echo "$STAGED"
        [[ -n "$UNSTAGED" ]] && echo "Unstaged:" && echo "$UNSTAGED"
        [[ -n "$UNTRACKED" ]] && echo "Untracked:" && run_git ls-files --others --exclude-standard
        echo ""
        echo "   Run ./git.sh to commit changes first, or use 'git stash' to set aside"
        exit 1
    fi
    # No staging needed for installed systems - flakes read tracked files from working tree
    # when all changes are committed. The flake uses the repo path directly.
fi

# --- DETERMINE TARGET ---
if [[ "$HOST_TYPE" == "nixos" ]]; then
    if [[ -n "${1:-}" ]]; then
        TARGET=$(normalise_host "$1")
        echo -e "${GREEN}>> Target: ${TARGET}${NC}"
    else
        # Interactive selection (we already verified -t 0 in HOST_TYPE check above)
        echo "   Select configuration to install:"
        select opt in "${LINUX_HOSTS[@]}"; do
            if [[ -n "$opt" ]]; then
                TARGET="$opt"
                break
            else
                echo "Invalid. Try again."
            fi
        done </dev/tty
    fi
else
    # Known host - use detected hostname
    TARGET="$DETECTED_HOST"
    echo -e "   Auto-building in 5 seconds... ${YELLOW}(Ctrl+C to cancel)${NC}"
    sleep 5
fi

# --- BUILD ---
FLAKE_TARGET="${TARGET,,}"

# Validate home-manager users exist (Darwin only)
if [[ "$PLATFORM" == "Darwin" ]]; then
    echo -e "${YELLOW}>> Validating home-manager users...${NC}"
    HM_USERS=$(nix eval ".#darwinConfigurations.${FLAKE_TARGET}.config.home-manager.users" \
        --apply 'users: builtins.concatStringsSep " " (builtins.attrNames users)' --raw 2>/dev/null || echo '')
    
    MISSING_USERS=()
    for user in $HM_USERS; do
        if ! id "$user" &>/dev/null; then
            MISSING_USERS+=("$user")
        fi
    done
    
    if [[ ${#MISSING_USERS[@]} -gt 0 ]]; then
        echo -e "${RED}>> Error: The following macOS users do not exist:${NC}"
        for user in "${MISSING_USERS[@]}"; do
            echo "   - $user"
        done
        echo ""
        echo "   Create them in System Settings → Users & Groups first"
        exit 1
    fi
    echo -e "${GREEN}>> All home-manager users exist${NC}"
fi

if [[ "$PLATFORM" == "Darwin" ]]; then
    echo -e "${GREEN}>> Rebuilding Darwin: ${SCRIPT_DIR}#${FLAKE_TARGET}${NC}"
    if command -v darwin-rebuild &> /dev/null; then
        sudo darwin-rebuild switch --flake "${SCRIPT_DIR}#${FLAKE_TARGET}"
    else
        echo -e "${YELLOW}>> darwin-rebuild not found, bootstrapping nix-darwin...${NC}"
        sudo nix run nix-darwin -- switch --flake "${SCRIPT_DIR}#${FLAKE_TARGET}"
    fi
elif [[ "$HOST_TYPE" == "nixos" ]]; then
    echo -e "${GREEN}>> Installing NixOS: ${SCRIPT_DIR}#${FLAKE_TARGET}${NC}"
    # Use path: prefix to read from working directory instead of git index.
    # This is required because git-agecrypt.nix files are decrypted locally
    # (the git index contains encrypted versions). The path: prefix tells Nix
    # to use the filesystem directly, where decrypted secrets are available.
    sudo nixos-install --flake "path:${SCRIPT_DIR}#${FLAKE_TARGET}" --no-root-passwd
else
    echo -e "${GREEN}>> Rebuilding: ${SCRIPT_DIR}#${FLAKE_TARGET}${NC}"
    sudo nixos-rebuild switch --flake "${SCRIPT_DIR}#${FLAKE_TARGET}" --show-trace
fi

# Copy repo and keys to installed system (live ISO only)
if [[ "$HOST_TYPE" == "nixos" ]]; then
    DEST_DIR="/mnt/home/${PRIMARY_USER}/Documents/Ezirius/Development/GitHub/${REPO_NAME}"
    echo -e "${YELLOW}>> Copying configuration to installed system...${NC}"
    sudo mkdir -p "$(dirname "$DEST_DIR")"
    sudo cp -a "$SCRIPT_DIR" "$DEST_DIR"
    
    # Copy git-agecrypt key
    AGECRYPT_KEY_SRC="$HOME/.config/git-agecrypt/keys.txt"
    AGECRYPT_KEY_DEST="/mnt/home/${PRIMARY_USER}/.config/git-agecrypt/keys.txt"
    AGECRYPT_KEY_COPIED=false
    if [[ -f "$AGECRYPT_KEY_SRC" ]]; then
        echo -e "${YELLOW}>> Copying git-agecrypt key...${NC}"
        sudo mkdir -p "$(dirname "$AGECRYPT_KEY_DEST")"
        sudo cp "$AGECRYPT_KEY_SRC" "$AGECRYPT_KEY_DEST"
        sudo chmod 600 "$AGECRYPT_KEY_DEST"
        AGECRYPT_KEY_COPIED=true
    else
        echo -e "${YELLOW}>> Warning: git-agecrypt key not found at ${AGECRYPT_KEY_SRC}${NC}"
    fi
    
    # Update git-agecrypt identity path for installed system
    AGECRYPT_CONFIG="$DEST_DIR/.git/git-agecrypt/config"
    if sudo test -f "$AGECRYPT_CONFIG"; then
        sudo sed -i "s|/root/.config/git-agecrypt/keys.txt|/home/${PRIMARY_USER}/.config/git-agecrypt/keys.txt|g" "$AGECRYPT_CONFIG"
    fi
    
    # Set ownership on user's home directory
    USER_UID=$(sudo grep "^${PRIMARY_USER}:" /mnt/etc/passwd | cut -d: -f3)
    USER_GID=$(sudo grep "^${PRIMARY_USER}:" /mnt/etc/passwd | cut -d: -f4)
    if [[ -z "$USER_UID" || -z "$USER_GID" ]]; then
        echo -e "${RED}>> Error: User ${PRIMARY_USER} not found in /mnt/etc/passwd${NC}"
        echo "   The NixOS installation may have failed to create the user."
        exit 1
    fi
    sudo chown -R "${USER_UID}:${USER_GID}" "/mnt/home/${PRIMARY_USER}"
    
    echo -e "${GREEN}>> Configuration copied to ${DEST_DIR}${NC}"
    if [[ "$AGECRYPT_KEY_COPIED" == true ]]; then
        echo -e "${GREEN}>> git-agecrypt key copied${NC}"
    fi
    echo ""
    echo -e "${GREEN}>> Installation complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Reboot into the installed system"
    echo "  2. Configuration is at: ~/Documents/Ezirius/Development/GitHub/${REPO_NAME}"
    echo "  3. Run ./install.sh to apply any future changes"
else
    # --- SYMLINK CONFIG (installed systems only) ---
    CONFIG_DIR="$HOME/.config/nixos"
    mkdir -p "$(dirname "$CONFIG_DIR")"
    
    # Use atomic symlink creation with ln -sfn (force, no-dereference)
    # This avoids TOCTOU race and handles all cases atomically
    if [[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]]; then
        echo -e "${RED}>> Warning: ${CONFIG_DIR} is a directory, not a symlink${NC}"
        echo "   Remove it manually if you want automatic symlinking"
    else
        CURRENT_LINK=$(readlink "$CONFIG_DIR" 2>/dev/null || echo "")
        if [[ "$CURRENT_LINK" != "$SCRIPT_DIR" ]]; then
            echo -e "${YELLOW}>> Creating symlink: ${CONFIG_DIR} -> ${SCRIPT_DIR}${NC}"
            ln -sfn "$SCRIPT_DIR" "$CONFIG_DIR"
        fi
    fi
    
    echo -e "${GREEN}>> Success! System is live as: ${FLAKE_TARGET}${NC}"
fi

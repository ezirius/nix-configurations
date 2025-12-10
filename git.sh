#!/usr/bin/env bash

# Validate configuration, stage, commit, and push changes to GitHub
# Checks: git-agecrypt, remote URL, user identity, commit signing, secrets encryption
#
# Usage:
#   ./git.sh

set -euo pipefail

# Note: 'set -o pipefail' ensures piped commands propagate failures.
# If a command fails unexpectedly, check each pipeline stage individually.

# Require bash 4.0+ for ${var,,} and ${var^} syntax
if ((BASH_VERSINFO[0] < 4)); then
    echo "Error: bash 4.0+ required (you have ${BASH_VERSION})"
    echo "On macOS, run with: nix-shell -p bash --run './git.sh'"
    exit 1
fi

# Help function
show_help() {
    cat <<'EOF'
Usage: ./git.sh [options]

Format, validate, commit, and push Nix configuration changes.

This script:
  1. Configures git-agecrypt if needed
  2. Validates git configuration (SSH remote, signing key, etc.)
  3. Fetches and rebases if remote has new commits
  4. Checks for local changes
  5. Formats Nix files with 'nix fmt'
  6. Stages all changes
  7. Validates flake for all systems
  8. Prompts for commit message
  9. Commits with signature
  10. Verifies secrets are encrypted
  11. Pushes to remote

Options:
  -h, --help    Show this help message
  --amend       Amend the previous commit instead of creating a new one
  --reset       Clear all git history and create a fresh initial commit
                (useful after forking to remove upstream history)

Prerequisites:
  - git-agecrypt key at ~/.config/git-agecrypt/keys.txt
  - Git configured with SSH signing key

Examples:
  ./git.sh           # Run the full commit workflow
  ./git.sh --amend   # Amend the previous commit
  ./git.sh --reset   # Clear history and start fresh
EOF
}

# Parse arguments
AMEND_MODE=false
RESET_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --amend)
            AMEND_MODE=true
            shift
            ;;
        --reset)
            RESET_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run './git.sh --help' for usage"
            exit 1
            ;;
    esac
done

# Cannot use both --amend and --reset
if [[ "$AMEND_MODE" == true && "$RESET_MODE" == true ]]; then
    echo -e "${RED}>> Error: Cannot use --amend and --reset together${NC}"
    exit 1
fi

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Libraries/lib.sh
source "${SCRIPT_DIR}/Libraries/lib.sh"

# Classify hostname and print message
classify_hostname
print_host_message

# Only allow git operations from installed systems
case "$HOST_TYPE" in
    nixos)
        echo -e "${RED}>> Error: git.sh cannot be run from NixOS live installer${NC}"
        echo "   Install to a system first, then run git.sh from there."
        exit 1
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
        echo "   Supported hosts: ${ALL_HOSTS[*]}"
        echo "   To add a new host, see README.md: \"Forking for your own use\""
        exit 1
        ;;
esac

cd "$SCRIPT_DIR"

echo -e "${YELLOW}>> Working from: ${SCRIPT_DIR}${NC}"

# Ensure running interactively (not piped)
if [[ ! -t 0 ]]; then
    echo -e "${RED}>> Error: git.sh must be run interactively, not piped${NC}"
    exit 1
fi

# Ensure this is a git repository
if [[ ! -d ".git" ]]; then
    echo -e "${RED}>> Error: Not a git repository${NC}"
    echo "   Run this script from the repository root"
    exit 1
fi

# Unstage changes on error to prevent accidental commits
cleanup_on_error() {
    echo -e "${RED}>> Error encountered; unstaging changes...${NC}"
    run_git reset --quiet || true
}
trap cleanup_on_error ERR

echo -e "${GREEN}>> Git Commit & Push${NC}"

# --- HANDLE --reset MODE WARNING ---
if [[ "$RESET_MODE" == true ]]; then
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                            WARNING                                 ║${NC}"
    echo -e "${RED}╠════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║  This will PERMANENTLY DELETE all local git history!               ║${NC}"
    echo -e "${RED}║                                                                    ║${NC}"
    echo -e "${RED}║  - All local commits will be removed                               ║${NC}"
    echo -e "${RED}║  - All local branches will be removed                              ║${NC}"
    echo -e "${RED}║  - A new initial commit will be created                            ║${NC}"
    echo -e "${RED}║  - You will be prompted before pushing to remote                   ║${NC}"
    echo -e "${RED}║                                                                    ║${NC}"
    echo -e "${RED}║  Use this after cloning to start fresh with your own repository.  ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -n "Type YES to reset local history: "
    read -er CONFIRM </dev/tty
    if [[ "$CONFIRM" != "YES" ]]; then
        echo -e "${YELLOW}>> Aborted. No changes made.${NC}"
        exit 0
    fi
fi

# --- 1. ENSURE GIT-AGECRYPT CONFIGURED ---
echo -e "${YELLOW}>> Checking git-agecrypt configuration...${NC}"
ensure_git_agecrypt_filters
echo -e "${GREEN}>> git-agecrypt configured correctly${NC}"

# --- 2. VALIDATE GIT CONFIGURATION ---
# Skip for --reset mode (git config will be lost and reconfigured)
if [[ "$RESET_MODE" == false ]]; then
    echo -e "${YELLOW}>> Validating git configuration...${NC}"

    # Check remote URL is SSH (use ls-remote --get-url to respect insteadOf rewrites)
    REMOTE_URL=$(run_git ls-remote --get-url origin 2>/dev/null || echo "")
    if [[ -z "$REMOTE_URL" ]]; then
        echo -e "${RED}>> Error: No remote 'origin' configured${NC}"
        exit 1
    fi
    if [[ "$REMOTE_URL" == https://* ]]; then
        echo -e "${RED}>> Error: Remote uses HTTPS, expected SSH${NC}"
        echo "   Current: $REMOTE_URL"
        echo "   Fix: git remote set-url origin git@github.com:ezirius/Nix-Configurations.git"
        exit 1
    fi
    echo -e "${GREEN}>> Remote URL: SSH${NC}"

    # Check user.name
    USER_NAME=$(run_git config user.name 2>/dev/null || echo "")
    if [[ -z "$USER_NAME" ]]; then
        echo -e "${RED}>> Error: git user.name not configured${NC}"
        echo "   Fix: git config user.name \"Your Name\""
        exit 1
    fi
    echo -e "${GREEN}>> user.name: ${USER_NAME}${NC}"

    # Check user.email
    USER_EMAIL=$(run_git config user.email 2>/dev/null || echo "")
    if [[ -z "$USER_EMAIL" ]]; then
        echo -e "${RED}>> Error: git user.email not configured${NC}"
        echo "   Fix: git config user.email \"you@example.com\""
        exit 1
    fi
    echo -e "${GREEN}>> user.email: ${USER_EMAIL}${NC}"

    # Check commit signing is enabled
    GPG_SIGN=$(run_git config --get commit.gpgsign 2>/dev/null || echo "")
    if [[ "$GPG_SIGN" != "true" ]]; then
        echo -e "${RED}>> Error: Commit signing not enabled${NC}"
        echo "   Fix: git config commit.gpgsign true"
        exit 1
    fi
    echo -e "${GREEN}>> Commit signing: enabled${NC}"

    # Check signing key is configured
    SIGNING_KEY=$(run_git config --get user.signingkey 2>/dev/null || echo "")
    if [[ -z "$SIGNING_KEY" ]]; then
        echo -e "${RED}>> Error: No signing key configured${NC}"
        echo "   Fix: git config user.signingkey <your-key>"
        exit 1
    fi
    echo -e "${GREEN}>> Signing key: configured${NC}"

    # Check gpg.format is ssh (not gpg)
    GPG_FORMAT=$(run_git config --get gpg.format 2>/dev/null || echo "")
    if [[ "$GPG_FORMAT" != "ssh" ]]; then
        echo -e "${RED}>> Error: gpg.format not set to 'ssh'${NC}"
        echo "   Current: ${GPG_FORMAT:-<not set>}"
        echo "   Fix: git config gpg.format ssh"
        exit 1
    fi
    echo -e "${GREEN}>> gpg.format: ssh${NC}"
else
    echo -e "${YELLOW}>> Skipping git configuration validation (--reset mode)${NC}"
fi

# --- 3. FETCH AND REBASE IF NEEDED ---
# Skip for --reset mode (history will be removed anyway)
if [[ "$RESET_MODE" == false ]]; then
    # Do this before any local changes to avoid conflicts
    if run_git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
        UPSTREAM=$(run_git rev-parse --abbrev-ref '@{u}' 2>/dev/null)
        echo -e "${YELLOW}>> Fetching from remote...${NC}"
        run_git fetch origin
        BEHIND=$(run_git rev-list HEAD.."$UPSTREAM" --count 2>/dev/null || echo "0")
        if [[ "$BEHIND" -gt 0 ]]; then
            echo -e "${YELLOW}>> Remote has ${BEHIND} new commit(s)${NC}"
            echo -n "Rebase local changes on top? (y/n): "
            read -er CONFIRM </dev/tty
            if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
                # Stash any local changes before rebasing
                STASHED=false
                if ! run_git diff --quiet || ! run_git diff --cached --quiet; then
                    echo -e "${YELLOW}>> Stashing local changes...${NC}"
                    run_git stash push -m "git.sh: auto-stash before rebase"
                    STASHED=true
                fi
                if ! run_git pull --rebase; then
                    echo -e "${RED}>> Rebase failed. Resolve conflicts and run ./git.sh again${NC}"
                    [[ "$STASHED" == true ]] && echo "   Your changes are stashed. Run 'git stash pop' after resolving."
                    exit 1
                fi
                if [[ "$STASHED" == true ]]; then
                    echo -e "${YELLOW}>> Restoring stashed changes...${NC}"
                    if ! run_git stash pop; then
                        echo -e "${RED}>> Stash pop failed (conflict with rebased changes)${NC}"
                        echo "   Resolve manually: git stash show -p | git apply"
                        exit 1
                    fi
                fi
                echo -e "${GREEN}>> Rebased successfully${NC}"
            else
                echo -e "${RED}>> Aborted. Run 'git pull --rebase' manually when ready${NC}"
                exit 1
            fi
        fi
    fi
fi

# --- 4. CHECK FOR CHANGES ---
echo -e "${YELLOW}>> Checking for changes...${NC}"

HAS_CHANGES=true
if run_git diff --quiet && run_git diff --cached --quiet && [[ -z "$(run_git ls-files --others --exclude-standard)" ]]; then
    HAS_CHANGES=false
fi

# For --amend, we allow proceeding even without changes (to edit commit message)
# For --reset, we always proceed
if [[ "$HAS_CHANGES" == false && "$AMEND_MODE" == false && "$RESET_MODE" == false ]]; then
    echo -e "${YELLOW}>> No changes to commit${NC}"
    
    # Check for unpushed commits
    if run_git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
        UNPUSHED=$(run_git rev-list '@{u}..HEAD' --count 2>/dev/null || echo "0")
        if [[ "$UNPUSHED" -gt 0 ]]; then
            echo -e "${YELLOW}>> ${UNPUSHED} unpushed commit(s) found${NC}"
            echo -n "Push to remote? (y/n): "
            read -er CONFIRM </dev/tty
            if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
                echo -e "${YELLOW}>> Pushing to remote...${NC}"
                run_git push
                echo -e "${GREEN}>> Pushed successfully${NC}"
            fi
        fi
    fi
    exit 0
fi

if [[ "$AMEND_MODE" == true && "$HAS_CHANGES" == false ]]; then
    echo -e "${YELLOW}>> No new changes, but --amend will allow editing the previous commit${NC}"
fi

# --- 5. FORMAT NIX FILES ---
echo -e "${YELLOW}>> Formatting Nix files...${NC}"
# Capture output and exit code separately to detect formatting failures
# Filter out Git tree warnings (expected when working tree differs from index)
set +e
FMT_OUTPUT=$(nix --extra-experimental-features "nix-command flakes" fmt 2>&1)
FMT_EXIT=$?
set -e
# Display output (filtered) if any
if [[ -n "$FMT_OUTPUT" ]]; then
    echo "$FMT_OUTPUT" | grep -v "^warning: Git tree" || true
fi
if [[ $FMT_EXIT -ne 0 ]]; then
    echo -e "${RED}>> Formatting failed${NC}"
    exit 1
fi

# --- 6. DETECT FRESH REPO ---
# git-agecrypt filters only work after first commit exists
# For fresh repos, we must: commit non-secrets first, then add secrets and amend
FRESH_REPO=false
if ! run_git rev-parse HEAD &>/dev/null; then
    FRESH_REPO=true
    echo -e "${YELLOW}>> Fresh repo detected - will use two-step commit for git-agecrypt${NC}"
fi

# --- 7. STAGE CHANGES ---
echo -e "${YELLOW}>> Staging changes...${NC}"
if [[ "$FRESH_REPO" == true ]]; then
    # Fresh repo: stage everything except Private dir first
    # git-agecrypt filters only work after first commit exists
    run_git add . ':!Private'
else
    # Normal: stage everything
    run_git add .
fi

# Warn if Private/ files are being staged (ensure encryption awareness)
PRIVATE_STAGED=$(run_git diff --cached --name-only -- 'Private/' 2>/dev/null || true)
if [[ -n "$PRIVATE_STAGED" ]]; then
    echo -e "${YELLOW}>> Note: Private/ files staged - encryption will be verified after commit${NC}"
fi

# Show what's staged
echo ""
run_git status --short
echo ""

# --- 8. VALIDATE FLAKE ---
# Must validate before committing (needs staged files)
# Note: 'nix flake check' evaluates ALL configurations, which fails cross-platform
# (Darwin can't evaluate Linux derivations with build-time checks like catppuccin).
# Instead, we build the current host's configuration to validate.
# Flake attributes use lowercase hostnames.
FLAKE_HOST="${DETECTED_HOST,,}"
echo -e "${YELLOW}>> Validating flake (${FLAKE_HOST})...${NC}"
if [[ "$PLATFORM" == "Darwin" ]]; then
    BUILD_CMD="nix --extra-experimental-features 'nix-command flakes' build --no-link .#darwinConfigurations.${FLAKE_HOST}.system"
else
    BUILD_CMD="nix --extra-experimental-features 'nix-command flakes' build --no-link .#nixosConfigurations.${FLAKE_HOST}.config.system.build.toplevel"
fi
if ! eval "$BUILD_CMD"; then
    echo ""
    echo -e "${RED}>> Flake validation failed. Aborting.${NC}"
    run_git reset --quiet
    exit 1
fi
echo -e "${GREEN}>> Flake valid${NC}"

# --- 9. PROMPT FOR COMMIT MESSAGE ---
echo ""
echo -n "Commit message: "
read -er COMMIT_MSG </dev/tty

if [[ -z "$COMMIT_MSG" ]]; then
    echo -e "${RED}>> Error: Commit message cannot be empty${NC}"
    run_git reset --quiet
    exit 1
fi

# --- 10. COMMIT ---
if [[ "$RESET_MODE" == true ]]; then
    # Reset history using orphan branch (works whether remote is empty or has history)
    echo -e "${YELLOW}>> Creating orphan branch with clean history...${NC}"
    run_git checkout --orphan temp-reset-branch
    
    echo -e "${YELLOW}>> Configuring git-agecrypt on new branch...${NC}"
    nix-shell -p git-agecrypt --run "git-agecrypt init" &>/dev/null || true
    # Only add key if not already configured
    if ! nix-shell -p git-agecrypt --run "git-agecrypt config" 2>/dev/null | grep -q "keys.txt"; then
        nix-shell -p git-agecrypt --run "git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt" &>/dev/null || true
    fi
    
    echo -e "${YELLOW}>> Staging all files (without secrets for initial commit)...${NC}"
    run_git add . ':!Private'
    
    echo -e "${YELLOW}>> Creating initial commit...${NC}"
    run_git commit -m "$COMMIT_MSG"
    
    echo -e "${YELLOW}>> Adding secrets (git-agecrypt filters now active)...${NC}"
    run_git add Private/
    
    echo -e "${YELLOW}>> Amending commit to include secrets...${NC}"
    run_git commit --amend --no-edit
    
    echo -e "${YELLOW}>> Replacing main branch...${NC}"
    run_git branch -D main 2>/dev/null || true
    run_git branch -m main
    
    echo -e "${GREEN}>> Local history reset complete${NC}"
    
    # Configure remote - sets RESET_REMOTE variable used in section 12 push
    # (push happens after secrets verification)
    echo ""
    RESET_REMOTE=$(run_git ls-remote --get-url origin 2>/dev/null || echo "")
    
    if [[ -z "$RESET_REMOTE" || "$RESET_REMOTE" == "origin" ]]; then
        # No remote configured - prompt for new one
        echo -e "${YELLOW}>> No remote configured. Enter your repository SSH URL${NC}"
        echo "   (e.g., git@github.com:username/Nix-Configurations.git)"
        echo "   Leave empty to skip."
        echo -n "Remote URL: "
        read -er NEW_REMOTE_URL </dev/tty
        
        if [[ -n "$NEW_REMOTE_URL" ]]; then
            run_git remote add origin "$NEW_REMOTE_URL"
            RESET_REMOTE="$NEW_REMOTE_URL"
            echo -e "${GREEN}>> Remote configured: ${NEW_REMOTE_URL}${NC}"
        fi
    else
        echo -e "${YELLOW}>> Current remote: ${RESET_REMOTE}${NC}"
        echo -n "Use this remote? (y/n): "
        read -er CONFIRM </dev/tty
        if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
            echo -e "${YELLOW}>> Enter new repository SSH URL:${NC}"
            echo -n "Remote URL: "
            read -er NEW_REMOTE_URL </dev/tty
            if [[ -n "$NEW_REMOTE_URL" ]]; then
                run_git remote set-url origin "$NEW_REMOTE_URL"
                RESET_REMOTE="$NEW_REMOTE_URL"
                echo -e "${GREEN}>> Remote updated: ${NEW_REMOTE_URL}${NC}"
            else
                RESET_REMOTE=""
            fi
        fi
    fi
elif [[ "$FRESH_REPO" == true ]]; then
    # Fresh repo: two-step commit
    echo -e "${YELLOW}>> Creating initial commit (without secrets)...${NC}"
    run_git commit -m "$COMMIT_MSG"
    
    echo -e "${YELLOW}>> Adding secrets (git-agecrypt filters now active)...${NC}"
    run_git add Private/
    
    echo -e "${YELLOW}>> Amending commit to include secrets...${NC}"
    run_git commit --amend --no-edit
elif [[ "$AMEND_MODE" == true ]]; then
    # Amend previous commit
    echo -e "${YELLOW}>> Amending previous commit...${NC}"
    if [[ "$HAS_CHANGES" == true ]]; then
        run_git commit --amend -m "$COMMIT_MSG"
    else
        # No changes, just update message
        run_git commit --amend -m "$COMMIT_MSG" --allow-empty
    fi
else
    # Normal commit
    echo -e "${YELLOW}>> Committing...${NC}"
    run_git commit -m "$COMMIT_MSG"
fi

# --- 11. VERIFY SECRETS ARE ENCRYPTED ---
echo -e "${YELLOW}>> Verifying secrets are encrypted...${NC}"
SECRETS_OK=true
# Use while read to safely handle filenames (avoids word splitting issues)
while IFS= read -r SECRETS_FILE; do
    [[ -z "$SECRETS_FILE" ]] && continue
    FIRST_LINE=$(run_git show "HEAD:${SECRETS_FILE}" 2>/dev/null | head -n1 || true)
    if [[ "$FIRST_LINE" != "age-encryption.org/v1" ]]; then
        echo -e "${RED}>> ERROR: ${SECRETS_FILE} is not encrypted in commit!${NC}"
        echo "   Expected 'age-encryption.org/v1' header, got: ${FIRST_LINE:0:30}"
        SECRETS_OK=false
    else
        echo -e "${GREEN}>> ${SECRETS_FILE}: Encrypted${NC}"
    fi
done < <(run_git ls-files --cached 'Private/*/git-agecrypt.nix' 2>/dev/null)

if [[ "$SECRETS_OK" != true ]]; then
    echo ""
    echo -e "${RED}>> Secrets are not encrypted! Do NOT push.${NC}"
    echo ""
    echo "To fix:"
    echo "  1. git reset HEAD~1  (undo the commit)"
    echo "  2. nix-shell -p git-agecrypt --run \"git-agecrypt init\""
    echo "  3. nix-shell -p git-agecrypt --run \"git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt\""
    echo "  4. Run ./git.sh again"
    exit 1
fi

# --- 12. PUSH ---
if [[ "$RESET_MODE" == true ]]; then
    # Push with confirmation for --reset mode (RESET_REMOTE set in section 10)
    if [[ -n "$RESET_REMOTE" && "$RESET_REMOTE" != "origin" ]]; then
        echo ""
        # Truncate URL if too long for box
        DISPLAY_REMOTE="$RESET_REMOTE"
        if [[ ${#DISPLAY_REMOTE} -gt 50 ]]; then
            DISPLAY_REMOTE="${DISPLAY_REMOTE:0:47}..."
        fi
        echo -e "${RED}╔════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                       REMOTE PUSH WARNING                          ║${NC}"
        echo -e "${RED}╠════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}║  This will OVERWRITE all history on the remote repository!         ║${NC}"
        echo -e "${RED}║                                                                    ║${NC}"
        printf "${RED}║  Remote: %-58s║${NC}\n" "$DISPLAY_REMOTE"
        echo -e "${RED}║                                                                    ║${NC}"
        echo -e "${RED}║  All existing commits, branches, and tags will be LOST.            ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -n "Type YES to force push and overwrite remote: "
        read -er CONFIRM </dev/tty
        
        if [[ "$CONFIRM" == "YES" ]]; then
            echo -e "${YELLOW}>> Force pushing to remote...${NC}"
            run_git push --force -u origin main
            echo -e "${GREEN}>> Push complete${NC}"
        else
            echo -e "${YELLOW}>> Push skipped. To push later:${NC}"
            echo "   git push --force -u origin main"
        fi
    else
        echo ""
        echo -e "${YELLOW}>> No remote configured. To add one and push:${NC}"
        echo "   git remote add origin git@github.com:username/repo.git"
        echo "   git push -u origin main"
    fi
elif [[ "$AMEND_MODE" == true ]]; then
    # Amend requires force push if already pushed
    if run_git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
        echo -e "${YELLOW}>> Amended commit requires force push${NC}"
        echo -n "Force push to remote? (y/n): "
        read -er CONFIRM </dev/tty
        if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
            echo -e "${YELLOW}>> Force pushing to remote...${NC}"
            run_git push --force-with-lease
            echo -e "${GREEN}>> Pushed successfully${NC}"
        else
            echo "   To push manually: git push --force-with-lease"
        fi
    else
        BRANCH=$(run_git branch --show-current)
        echo -e "${YELLOW}>> No upstream branch set${NC}"
        echo -n "Push and set upstream to origin/${BRANCH}? (y/n): "
        read -er CONFIRM </dev/tty
        if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
            echo -e "${YELLOW}>> Pushing to remote...${NC}"
            run_git push -u origin "$BRANCH"
            echo -e "${GREEN}>> Pushed successfully${NC}"
        else
            echo "   To push manually: git push -u origin ${BRANCH}"
        fi
    fi
elif run_git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
    echo -e "${YELLOW}>> Pushing to remote...${NC}"
    run_git push
    echo -e "${GREEN}>> Pushed successfully${NC}"
else
    BRANCH=$(run_git branch --show-current)
    echo -e "${YELLOW}>> No upstream branch set${NC}"
    echo -n "Push and set upstream to origin/${BRANCH}? (y/n): "
    read -er CONFIRM </dev/tty
    if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
        echo -e "${YELLOW}>> Pushing to remote...${NC}"
        run_git push -u origin "$BRANCH"
        echo -e "${GREEN}>> Pushed successfully${NC}"
    else
        echo "   To push manually: git push -u origin ${BRANCH}"
    fi
fi

echo ""
echo -e "${GREEN}>> Done!${NC}"

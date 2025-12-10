# Nix Configurations

Encrypted declarative Nix infrastructure for NixOS and macOS (nix-darwin).

| Host | Platform | Architecture | Description |
|------|----------|--------------|-------------|
| Nithra | NixOS | x86_64-linux | VPS with LUKS full-disk encryption and initrd SSH unlock |
| Maldoria | macOS (nix-darwin) | aarch64-darwin | Apple Silicon Mac |

**Note:** Throughout this document, `<repo>` refers to your local clone of this repository.

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Daily Operations](#3-daily-operations)
4. [Configuration Changes](#4-configuration-changes)
5. [Secrets Management](#5-secrets-management)
6. [Fresh Installation](#6-fresh-installation)
7. [Disaster Recovery](#7-disaster-recovery)
8. [Security Model](#8-security-model)
9. [Reference](#9-reference)
10. [Forking for Your Own Use](#10-forking-for-your-own-use)

## Quick Reference

```bash
./install.sh              # Rebuild and apply changes
./git.sh                  # Format, validate, commit, push
./git.sh --amend          # Amend the previous commit
./git.sh --reset          # Clear history (for forking)
nix flake update          # Update all inputs
sudo nixos-rebuild switch --rollback  # Rollback to previous
ssh nithra-boot           # LUKS unlock (after reboot)
```

For full command reference, see [Section 9](#9-reference).

---

## 1. Overview

### System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        NITHRA (VPS)                             │
│  ┌───────────────────┐      ┌───────────────────────────────┐  │
│  │ Stage 1: Boot     │      │ Stage 2: Runtime              │  │
│  │ (initrd SSH)      │ ──▶  │ (OpenSSH)                     │  │
│  │                   │      │                               │  │
│  │ - LUKS unlock     │      │ - Normal administration       │  │
│  │ - Port 22         │      │ - Port 22 (SSH)               │  │
│  │ - Root user       │      │ - Port 60000-60010/udp (Mosh) │  │
│  │ - Restricted keys │      │ - User: ezirius               │  │
│  └───────────────────┘      └───────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
        ▲                              ▲
        │ ssh nithra-boot              │ ssh nithra / mosh nithra
        │ (unlock LUKS)                │ (daily use)
        │                              │
┌───────┴──────────────────────────────┴───────┐
│           CLIENT MACHINES                     │
│           (Ipsa, Ipirus, Maldoria)            │
│           - SSH keys for both stages          │
│           - This repo cloned locally          │
└──────────────────────────────────────────────┘
```

### What is This?

- **Nithra**: A VPS with full-disk encryption (LUKS)
- **Ipsa, Ipirus, Maldoria**: Client machines that manage and access nithra
- **Two-stage boot**: initrd SSH for LUKS unlock, then OpenSSH for normal access
- **Declarative config**: Entire system defined in Nix, version controlled in Git

### Boot Flow

1. VPS powers on
2. initrd SSH starts (Stage 1)
3. Client SSHs in (`ssh nithra-boot`), enters LUKS passphrase
4. System decrypts and boots
5. OpenSSH starts (Stage 2)
6. Client SSHs in (`ssh nithra`) for normal use

---

## 2. Prerequisites

### Software Requirements

**Bash 4.0+** is required for all scripts (`install.sh`, `git.sh`, `clone.sh`, `partition.sh`).

| Platform | Bash Version | Notes |
|----------|--------------|-------|
| NixOS live ISO | 5.x ✓ | Works out of the box |
| NixOS installed | 5.x ✓ | Works out of the box |
| macOS (system) | 3.2 ✗ | Too old - install Nix first |
| macOS (with Nix) | 5.x ✓ | Nix provides modern bash |

**On macOS, install Nix before running any scripts:**

```bash
# 1. Install Nix (provides bash 5.x and nix-shell)
curl -L https://nixos.org/nix/install | sh

# 2. Restart terminal or source Nix profile
. ~/.nix-profile/etc/profile.d/nix.sh

# 3. Now clone.sh will work
curl -sL https://raw.githubusercontent.com/ezirius/Nix-Configurations/main/clone.sh | bash
```

**Note:** When piping `curl | bash` on macOS, the system's `/bin/bash` (3.2) is used initially. If bash 4.0+ is not in PATH, clone.sh will fail with a clear error message. After Nix is installed and in PATH, the scripts will work correctly.

All scripts support `--help` for usage information:
```bash
./install.sh --help
./git.sh --help
./clone.sh --help
./partition.sh --help
```

### Backup Checklist

Store securely in password manager:

- [ ] **Age private key (sops-nix)** - Contents of `/var/lib/sops-nix/key.txt`
- [ ] **Age private key (git-agecrypt)** - Contents of `~/.config/git-agecrypt/keys.txt` (may be different from sops-nix key)
- [ ] **LUKS passphrase** - Disk encryption password (**unrecoverable if lost**)
- [ ] **VPS credentials** - Provider control panel login (for VNC access)

SSH keys live on client machines (Ipsa, Ipirus, Maldoria) - backed up separately.

### Client SSH Config

Add to `~/.ssh/config` on Ipsa/Ipirus/Maldoria:

```
Host nithra
    HostName <static-ip>
    User ezirius
    IdentityFile ~/.ssh/<client>_nithra_ezirius_login
    HostKeyAlgorithms ssh-ed25519
    Ciphers chacha20-poly1305@openssh.com
    MACs hmac-sha2-512-etm@openssh.com
    KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org

Host nithra-boot
    HostName <static-ip>
    User root
    IdentityFile ~/.ssh/<client>_nithra_root_boot
    HostKeyAlgorithms ssh-ed25519
    Ciphers chacha20-poly1305@openssh.com
    MACs hmac-sha2-512-etm@openssh.com
    KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
    # Different host key than nithra (initrd SSH vs OpenSSH)
```

**Note:** First connection to each host will prompt to accept the host key. initrd SSH (boot) and OpenSSH (runtime) intentionally use different keys, so you'll need to accept both. This prevents an attacker who compromises one from impersonating the other.

**Mosh usage:** `mosh nithra` works out of the box - UDP ports 60000-60010 are open on the server firewall.

**ProxyJump example:** If you need to access Nithra through a jump host (e.g., from a restricted network):
```
Host jump-host
    HostName jump.example.com
    User jumpuser
    IdentityFile ~/.ssh/jump_key

Host nithra-via-jump
    HostName <static-ip>
    User ezirius
    IdentityFile ~/.ssh/<client>_nithra_ezirius_login
    ProxyJump jump-host
    HostKeyAlgorithms ssh-ed25519
    Ciphers chacha20-poly1305@openssh.com
    MACs hmac-sha2-512-etm@openssh.com
    KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
```

### Required Knowledge

- Basic Nix/NixOS concepts (flakes, modules, options)
- SSH key-based authentication
- Linux command line familiarity
- Git basics (clone, commit, push)

---

## 3. Daily Operations

### Rebuild System

```bash
cd <repo>
./install.sh
```

The script automatically:
1. Ensures git-agecrypt and sops-nix keys are configured
2. On live ISO: uses `path:` prefix to read from working directory (secrets decrypted locally)
3. On installed systems: requires all changes to be committed first
4. Detects hostname (fails if not a known host or NixOS installer)
5. Validates home-manager users exist (Darwin only - create missing users in System Settings → Users & Groups)
6. Runs `nixos-rebuild switch --flake .#<host>` (validates during build)
7. Creates symlink to `~/.config/nixos` if repo is elsewhere

**Note:** Run `./git.sh` first to format, validate, commit, and push changes.

**What to watch for:**
- Build errors appear immediately - fix and re-run
- Activation warnings are usually safe but worth noting
- If switch fails mid-activation, system may be in inconsistent state - rollback immediately

**Note:** Use `git` for version control, not `jj` (jujutsu). jj doesn't support `.gitattributes` filters required by git-agecrypt.

### Update System

```bash
cd <repo>
nix flake update          # Update all inputs (nixpkgs, home-manager, etc.)
./install.sh              # Apply updates
```

**Warning:** Updates can introduce breaking changes. Always test in a new terminal and keep the original session open for rollback.

Update single input (safer):
```bash
nix flake lock --update-input nixpkgs
./install.sh
```

### Check Current Generation

```bash
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
```

### Compare Generations

```bash
# See what changed between current and previous generation
nix store diff-closures /run/booted-system /nix/var/nix/profiles/system
```

### Check if Reboot Required

```bash
booted=$(readlink /run/booted-system/kernel)
current=$(readlink /nix/var/nix/profiles/system/kernel)
[ "$booted" != "$current" ] && echo "Reboot required" || echo "No reboot required"
```

### Reboot Safely

1. Keep current SSH session open (safety net)
2. `sudo reboot`
3. SSH to initrd: `ssh nithra-boot`
4. Enter LUKS passphrase when prompted
5. Wait 30-60 seconds for boot
6. Verify: `ssh nithra`

### Test After Deploy

After running `./install.sh`, always test in a **new terminal** before closing the original:

```bash
# New terminal
ssh nithra
whoami                    # Should be: ezirius
echo $SHELL               # Should be: /run/current-system/sw/bin/zsh
sudo whoami               # Should be: root (tests sudo + password)
```

### Format Nix Files

```bash
nix fmt                   # Uses nixfmt-rfc-style (runs automatically in git.sh)
```

### Validate Configuration

```bash
cd <repo>
nix flake check                              # Validates flake structure (same-platform only)
nixos-rebuild build --flake .#nithra         # Test build without switching
```

> **Note:** `nix flake check` can only evaluate configurations for the current platform. Darwin cannot evaluate NixOS configs (and vice versa) when using platform-specific modules like catppuccin. Use `./git.sh` which validates only the current host's configuration.

---

## 4. Configuration Changes

### Add SSH Key for Login

On NixOS, SSH login keys are stored in git-agecrypt.nix because they're needed at Nix evaluation time. On Darwin, they're stored in `Public/Maldoria/keys.nix` (they're public keys, not secrets) and written via activation script.

1. Edit `Private/Nithra/git-agecrypt.nix`

2. Add to `loginKeysPub` (following naming convention `<from>_nithra_<user>_login`):
   ```nix
   loginKeysPub = {
     # ... existing keys ...
     newmachine_nithra_ezirius_login = "ssh-ed25519 AAAA...";
   };
   ```

3. Add to `Hosts/Nithra/default.nix` in the `authorizedKeys.keys` list:
   ```nix
   users.users.<user>.openssh.authorizedKeys.keys = [
     # ... existing keys ...
     secrets.loginKeysPub.newmachine_nithra_ezirius_login
   ];
   ```

4. `./install.sh`

### Add SSH Key for Boot Unlock

1. Edit `Private/Nithra/git-agecrypt.nix`

2. Add a new key to `bootKeysPub` (following naming convention `<from>_nithra_root_boot`):
   ```nix
   bootKeysPub = {
     # ... existing keys ...
     newmachine_nithra_root_boot = ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="systemd-tty-ask-password-agent --watch" ssh-ed25519 AAAA...'';
   };
   ```

3. Add to `Hosts/Nithra/default.nix` in the `boot.initrd.network.ssh.authorizedKeys` list:
   ```nix
   boot.initrd.network.ssh.authorizedKeys = [
     # ... existing keys ...
     secrets.bootKeysPub.newmachine_nithra_root_boot
   ];
   ```

4. `./install.sh`

**Note:** initrd SSH keys are restricted to only run `systemd-tty-ask-password-agent` - they cannot execute other commands.

### Add New User

1. Create directory structure:
   ```
   Homes/<name>/
   ├── <host>-account.nix  # System user config (NixOS only)
   └── <host>-home.nix     # Home-manager config
   ```

2. Generate password hash:
   ```bash
   nix-shell -p mkpasswd --run "mkpasswd -m sha-512"
   ```

3. Add password to `Private/Nithra/sops-nix.yaml`:
   ```bash
   cd <repo>
   sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Private/Nithra/sops-nix.yaml"
   ```
   Add: `<name>Password: "<hash from step 2>"`

4. Add sops reference in `Hosts/Nithra/default.nix`:
   ```nix
   sops.secrets.<name>Password.neededForUsers = true;
   ```

5. Import user in `Hosts/Nithra/default.nix`:
   ```nix
   imports = [
     ...
     ../../Homes/<name>
   ];
   ```

6. Add home-manager in `flake.nix`:
   ```nix
   home-manager.users.<name> = import ./Homes/<name>/<host>-home.nix;
   ```

7. `./install.sh`

### Add System Package

Edit `Hosts/Nithra/default.nix`:
```nix
environment.systemPackages = builtins.attrValues {
  inherit (pkgs)
    ...
    newpackage
    ;
};
```

### Add User Package (via home-manager)

Edit `Homes/<user>/<host>-home.nix`. First ensure `pkgs` is in the function arguments:
```nix
{ pkgs, ... }:
{
  home.packages = builtins.attrValues {
    inherit (pkgs)
      newpackage
      ;
  };
}
```

Or enable a program module (preferred when available):
```nix
programs.newprogram = {
  enable = true;
  # program-specific settings
};
```

### Configure Git Commit Signing

Git commits are signed with SSH keys for verified badges on GitHub.

**Nithra (NixOS):**
1. Generate signing key: `ssh-keygen -t ed25519 -C "nithra_github_ezirius_sign" -f /tmp/nithra_sign`
2. Add private key to `Private/Nithra/sops-nix.yaml`
3. Add public key to GitHub → Settings → SSH and GPG keys → New SSH key → Key type: **Signing Key**
4. The Nix config (`Hosts/Nithra/default.nix` and `Homes/ezirius/nithra-home.nix`) handles deployment and git config

**Maldoria (macOS with 1Password):**
1. Create signing key in 1Password (SSH Key item type)
2. Add public key to `Private/Maldoria/sops-nix.yaml` (deployed to `~/.ssh/` for 1Password matching)
3. Add same public key to GitHub → Settings → SSH and GPG keys → New SSH key → Key type: **Signing Key** (for commit verification)
4. The Nix config handles deployment and git config
5. Ensure `SSH_AUTH_SOCK` points to 1Password's agent (configured in `Homes/ezirius/maldoria-home.nix`)

**Testing signing:**
```bash
echo "test" | ssh-keygen -Y sign -f ~/.ssh/<host>_github_ezirius_sign -n git
```

If this fails on Maldoria, check 1Password's SSH agent is active:
```bash
echo $SSH_AUTH_SOCK  # Should contain "1Password"
ssh-add -L           # Should list keys from 1Password
```

### Configure SSH Server (Darwin)

Maldoria runs an SSH server for remote access, using public keys stored in `Public/Maldoria/keys.nix` and written via activation script.

**Architecture:**
- SSH login public keys stored in `Public/Maldoria/keys.nix` (not secrets - they're public)
- Activation script writes `~/.ssh/authorized_keys` directly
- nix-darwin lacks `users.users.<name>.openssh.authorizedKeys`, hence the activation script approach

**Configuration in `Hosts/Maldoria/default.nix`:**
```nix
# Import public keys
pubkeys = import ../../Public/Maldoria/keys.nix;

# SSH server
services.openssh = {
  enable = true;
  settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    AllowUsers = [ "ezirius" ];
  };
};

# Write authorized_keys via activation script
system.activationScripts.postActivation.text = ''
  rm -f ${homeDir}/.ssh/authorized_keys
  cat > ${homeDir}/.ssh/authorized_keys << 'EOF'
${pubkeys.loginKeysPub.ipsa_maldoria_ezirius_login}
${pubkeys.loginKeysPub.ipirus_maldoria_ezirius_login}
EOF
  chown ${username}:staff ${homeDir}/.ssh/authorized_keys
  chmod 600 ${homeDir}/.ssh/authorized_keys
'';
```

### Configure Firewall (Darwin)

macOS Application Firewall controls incoming connections (outgoing is unrestricted).

```nix
networking.applicationFirewall = {
  enable = true;
  enableStealthMode = true;  # Don't respond to probes
  allowSigned = true;        # Allow Apple-signed apps
  allowSignedApp = false;    # Prompt for third-party apps
};
```

### Configure Touch ID for Sudo (Darwin)

```nix
security.pam.services.sudo_local.touchIdAuth = true;
```

### Add New Host

1. Create `Hosts/<hostname>/default.nix` (and `disko-config.nix` for NixOS hosts)
2. Create `Private/<hostname>/git-agecrypt.nix` (copy and modify from existing host)
3. Create `Private/<hostname>/sops-nix.yaml` for runtime secrets
4. Add to `flake.nix`:
   ```nix
   # For NixOS:
   nixosConfigurations.<hostname> = nixpkgs.lib.nixosSystem {
     modules = [ ... ];
   };
   # For Darwin:
   darwinConfigurations.<hostname> = nix-darwin.lib.darwinSystem {
     modules = [ ... ];
   };
   ```
5. Add to `Libraries/lib.sh` host arrays (sourced by `install.sh`, `git.sh`, and `partition.sh`) and to `clone.sh` (standalone)
6. Update `.sops.yaml` with host's age public key (for sops-nix)
7. Update `git-agecrypt.toml` with host's age public key (for git-agecrypt)
8. Update `.gitattributes` with path to new host's `git-agecrypt.nix`

---

## 5. Secrets Management

### Architecture

Two-layer system due to NixOS evaluation constraints:

| Layer | Tool | File | When Decrypted | NixOS Use Case | Darwin Use Case |
|-------|------|------|----------------|----------------|-----------------|
| 1 | git-agecrypt | `Private/<host>/git-agecrypt.nix` | Git checkout (smudge filter) | Network, initrd SSH host key, initrd SSH authorised keys, SSH login pubkeys | Nithra connection info (IP, host keys) |
| 2 | sops-nix | `Private/<host>/sops-nix.yaml` | System activation | Passwords, OpenSSH host key, GitHub SSH keys | SSH key pubkeys (for 1Password matching) |

**Platform difference:** On NixOS, SSH login pubkeys must be in git-agecrypt because `authorizedKeys.keys` needs values at Nix evaluation time. On Darwin, nix-darwin lacks `authorizedKeys` support, so login pubkeys are stored in `Public/Maldoria/keys.nix` (they're public) and written via activation script.

**Why two layers?** Layer 1 secrets are needed during Nix evaluation (e.g., boot kernel params) or in initrd (before sops-nix runs). Layer 2 secrets are decrypted at runtime by sops-nix. See the comments in `Private/Nithra/git-agecrypt.nix` for detailed explanation.

### Key Naming Convention

All keys follow the format: `[from]_[to]_[user]_[type]`

| Component | Description | Examples |
|-----------|-------------|----------|
| `from` | Machine where the key resides | `ipsa`, `maldoria`, `nithra` |
| `to` | Target machine, service, or `all` | `nithra`, `github`, `all` |
| `user` | Username or `all` | `ezirius`, `root`, `all` |
| `type` | Key purpose | `login`, `boot`, `nix-configurations`, `sign` |

**Note:** For host keys (which identify a machine to others), use `<machine>_all_all_<type>` - the machine identifies itself (`from`) to all clients (`to`) for all users (`user`).

**Examples:**
- `ipsa_nithra_ezirius_login` - SSH key on Ipsa to login to Nithra as ezirius
- `maldoria_nithra_root_boot` - SSH key on Maldoria to unlock Nithra boot (initrd SSH)
- `nithra_github_ezirius_nix-configurations` - SSH key on Nithra for pushing to GitHub
- `maldoria_github_ezirius_sign` - SSH key on Maldoria for signing Git commits
- `nithra_github_ezirius_sign` - SSH key on Nithra for signing Git commits
- `nithra_all_all_boot` - Nithra's initrd SSH host key (identifies Nithra to all clients)
- `nithra_all_all_login` - Nithra's OpenSSH host key (identifies Nithra to all clients)

### git-agecrypt.nix Encryption Behavior

**IMPORTANT:** `git-agecrypt.nix` is **always decrypted in your working directory** - this is correct and expected!

| Location | State | Why |
|----------|-------|-----|
| Working directory | **Plaintext** | Required for Nix to import and evaluate |
| Git commits/remote | **Encrypted** | git-agecrypt encrypts via clean filter on commit |

To verify encryption is working:
```bash
# Local file (should be readable plaintext)
head Private/Nithra/git-agecrypt.nix

# In git (should show age-encryption.org/v1 header, not plaintext Nix)
git show HEAD:Private/Nithra/git-agecrypt.nix | head -5
```

If you can read the local file but `git show` displays the age header (not plaintext Nix), git-agecrypt is working correctly.

### Age Key Locations

| Path | Owner | Purpose |
|------|-------|---------|
| `/var/lib/sops-nix/key.txt` | root | sops-nix (automatic decryption at activation) - requires `sudo` to read/edit |
| `~/.config/git-agecrypt/keys.txt` | user | git-agecrypt (decrypt git-agecrypt.nix on checkout) |

**Key sharing model:**
- **git-agecrypt key**: One key shared across all hosts (same key on Nithra, Maldoria, etc.)
- **sops-nix key**: One key shared across all hosts (same key, but different from git-agecrypt)
- Both keys must be backed up — they decrypt different secret files

Permissions: `600`

Key format:
```
# created: 2024-01-01T00:00:00Z
# public key: age1...
AGE-SECRET-KEY-1...
```

### Edit git-agecrypt Secrets

```bash
cd <repo>

# First time setup in a fresh clone
nix-shell -p git-agecrypt --run "git-agecrypt init"
nix-shell -p git-agecrypt --run "git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt"

# Edit (auto-decrypts on read, auto-encrypts on commit)
vim Private/Nithra/git-agecrypt.nix
```

File auto-decrypts on checkout, auto-encrypts on commit via `.gitattributes` filter.

### Edit sops-nix Secrets

**Nithra (NixOS):**
```bash
cd <repo>
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Private/Nithra/sops-nix.yaml"
```

**Maldoria (macOS):**
```bash
cd <repo>
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Private/Maldoria/sops-nix.yaml"
```

Opens in `$EDITOR`. File auto-encrypts on save.

### git-agecrypt.nix Contents

The file includes detailed comments explaining why each secret is needed. Structure:

```nix
{
  network = {
    nithraIp = "x.x.x.x";           # Static IP from VPS provider
    nithraGateway = "x.x.x.x";      # Gateway from VPS provider
    nithraPrefixLength = 24;        # CIDR prefix (e.g., 24 = /24)
    nithraNetmask = "255.255.255.0"; # Kernel params require string format
  };
  bootKeysPub = {
    # Each key prefixed with restrictions and command
    # Named: <from>_nithra_root_boot
    ipsa_nithra_root_boot = ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="systemd-tty-ask-password-agent --watch" ssh-ed25519 AAAA...'';
    maldoria_nithra_root_boot = ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="systemd-tty-ask-password-agent --watch" ssh-ed25519 AAAA...'';
  };
  loginKeysPub = {
    # Named: <from>_nithra_<user>_login
    ipsa_nithra_ezirius_login = "ssh-ed25519 AAAA...";
    maldoria_nithra_ezirius_login = "ssh-ed25519 AAAA...";
  };
  hostKeys = {
    # Only initrd SSH key here (needed at build time for initrd)
    # OpenSSH host key is in sops-nix.yaml (deployed at activation)
    nithra_all_all_boot = "-----BEGIN OPENSSH PRIVATE KEY-----...";
  };
  hostKeysPub = {
    # Public keys for known_hosts (used by Maldoria to verify Nithra)
    nithra_all_all_boot = "ssh-ed25519 AAAA...";   # initrd SSH host key
    nithra_all_all_login = "ssh-ed25519 AAAA...";  # OpenSSH host key
  };
}
```

### sops-nix.yaml Contents

**Nithra (NixOS) - contains private keys:**
```yaml
rootPassword: $6$...          # SHA-512 hash from mkpasswd
eziriusPassword: $6$...       # SHA-512 hash from mkpasswd
nithra_all_all_login: |        # OpenSSH host key (deployed to /etc/ssh/)
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
nithra_github_ezirius_nix-configurations: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
nithra_github_ezirius_sign: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
```

**Maldoria (macOS) - contains public keys for 1Password matching:**
```yaml
maldoria_github_ezirius_nix-configurations: ssh-ed25519 AAAA...
maldoria_github_ezirius_sign: ssh-ed25519 AAAA...
maldoria_nithra_root_boot: ssh-ed25519 AAAA...
maldoria_nithra_ezirius_login: ssh-ed25519 AAAA...
```

On Maldoria, sops deploys public keys to `~/.ssh/`. 1Password's SSH agent matches these to private keys stored in its vault and provides them on demand. These are keys for connecting FROM Maldoria TO other hosts (Nithra, GitHub).

**Note:** SSH login public keys (for connecting TO Maldoria) are stored separately in `Public/Maldoria/keys.nix` (they're public) and written via activation script, since nix-darwin lacks `authorizedKeys` support. On NixOS, SSH login public keys are in git-agecrypt.nix because `authorizedKeys.keys` needs values at Nix evaluation time.

### .sops.yaml Structure

```yaml
keys:
  - &shared age1...           # Shared key (same key used for all hosts)
creation_rules:
  - path_regex: Private/.*/sops-nix\.yaml$
    key_groups:
      - age:
          - *shared           # Reference to anchor
```

### Generate New Age Key

If you need a new age key (new machine, key compromise):

```bash
# Generate new key
nix-shell -p age --run "age-keygen -o new-age-key.txt"

# View public key (needed for .sops.yaml)
nix-shell -p age --run "age-keygen -y new-age-key.txt"
```

Then re-encrypt all secrets with the new key (see Disaster Recovery).

---

## 6. Fresh Installation

### Prerequisites Checklist

Have these ready before starting:

| Secret | Source | Description |
|--------|--------|-------------|
| Age key (git-agecrypt) | Password manager | Decrypts git-agecrypt.nix on checkout |
| Age key (sops-nix) | Password manager | Decrypts sops-nix.yaml at runtime (different key!) |
| LUKS passphrase | Password manager / create new | Disk encryption password |
| VPS credentials | Provider account | Control panel login for VNC |
| This repo | GitHub | git@github.com:ezirius/Nix-Configurations.git |

### Step 1: Boot NixOS ISO

1. Mount NixOS Minimal ISO via VPS control panel
2. Boot into ISO
3. Configure network (adjust IP/prefix for your provider):

```bash
# Replace with your actual IP, prefix, and gateway
sudo ip addr add <static-ip>/<prefix> dev ens18
sudo ip route add default via <gateway>
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf

# Verify connectivity
curl -sI https://github.com --max-time 5 && echo "Network OK"
```

### Step 2: Run Clone Script

The `clone.sh` script automates repository setup, age key configuration, and secrets decryption:

```bash
# Download and run clone script (no arguments needed)
curl -sL https://raw.githubusercontent.com/ezirius/Nix-Configurations/main/clone.sh | bash
```

The script will:
1. Detect hostname and print appropriate message
2. Check network connectivity
3. Clone the repository to `/tmp/Nix-Configurations` (live ISO) or `~/Documents/...` (installed system)
4. Prompt you to paste your **git-agecrypt** age private key
5. Prompt you to paste your **sops-nix** age private key (saved to `/tmp/sops-nix-key.txt`, copied to `/mnt` by `partition.sh`)
6. Configure git-agecrypt filters
7. Verify secrets are encrypted, then decrypt them
8. Print next steps (partition + install on live ISO, just install on installed systems)

**Manual alternative:** If the curl command fails, see the manual steps in the script comments or clone manually:
```bash
nix-shell -p git --run "git clone https://github.com/ezirius/Nix-Configurations.git /tmp/Nix-Configurations"
```

### Step 3: Partition and Format

```bash
cd /tmp/Nix-Configurations

# Run partition script (will prompt for LUKS passphrase)
# Host argument is optional - omit for interactive selection
./partition.sh Nithra
```

The script will:
1. Read the disk device from `disko-config.nix`
2. Verify the disk exists
3. Show disk details and require "yes" confirmation
4. Wipe and partition the disk

**Important:** Remember the LUKS passphrase you enter - it's **unrecoverable** if forgotten. You'll need it for every boot.

### Step 4: Verify sops-nix Key

The `partition.sh` script automatically copies the sops-nix key to `/mnt/var/lib/sops-nix/key.txt`. If you see a warning that the key wasn't found, copy it manually:

```bash
sudo mkdir -p /mnt/var/lib/sops-nix
sudo cp /tmp/sops-nix-key.txt /mnt/var/lib/sops-nix/key.txt
sudo chmod 600 /mnt/var/lib/sops-nix/key.txt
```

### Step 5: Install

```bash
./install.sh Nithra
```

- Takes 10-20 minutes depending on connection
- The script runs `nixos-install` with `--no-root-passwd` (root password is managed via sops-nix)
- If it fails, check secrets are decrypted: `head Private/Nithra/git-agecrypt.nix`
- If it fails partway, you can re-run the same command - it will resume where it left off

### Step 6: Reboot and Unlock

```bash
sudo reboot
```

After reboot:

1. **Stage 1 (initrd SSH):**
   ```bash
   ssh root@<ip>
   # Accept host key on first connection
   # Passphrase prompt appears immediately - enter LUKS passphrase
   # Connection closes automatically after successful unlock
   ```

2. **Wait 30-60 seconds** for system to boot

3. **Stage 2 (OpenSSH):**
   ```bash
   ssh ezirius@<ip>
   # Accept host key on first connection (different from initrd SSH key)
   ```

### Step 7: Post-Install Setup

The `install.sh` script automatically copies the repository and git-agecrypt key to the installed system. After reboot, the configuration is already at `<repo>` (the path configured in `install.sh`).

The repository is ready to use - secrets are decrypted, git-agecrypt is configured, and the identity path is updated for the new system.

To apply future changes:
```bash
./git.sh      # Format, validate, commit, and push
./install.sh  # Rebuild and switch
```

### Step 8: Verify Installation

```bash
# Check services
systemctl status sshd
systemctl status fail2ban

# Check secrets decrypted
sudo ls -la /run/secrets/

# Check user
whoami                    # ezirius
groups                    # ezirius wheel
echo $SHELL               # /run/current-system/sw/bin/zsh

# Check sudo
sudo whoami               # root

# Check mosh
mosh --version
```

---

## 7. Disaster Recovery

### Rollback via SSH

If SSH still works:
```bash
sudo nixos-rebuild switch --rollback
```

Or select specific generation:
```bash
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
sudo nix-env --switch-generation <number> --profile /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

### Rollback via Boot Menu

If OpenSSH broken but system boots (initrd SSH still works for unlock):

1. SSH to initrd (`ssh nithra-boot`), unlock LUKS
2. At systemd-boot menu (via VNC), press arrow keys to select previous generation
3. Once booted, access via VNC, login as ezirius, fix config and redeploy

### Rollback via VNC

If network broken:

1. Access VNC via VPS provider control panel
2. Login as ezirius locally (console login)
3. `sudo nixos-rebuild switch --rollback`

### Recovery from Live ISO

If system won't boot at all:

**Note:** Device paths below (`/dev/sda1`, `/dev/sda2`, `pool`) may differ based on your disko configuration. Check `Hosts/<host>/disko-config.nix` for actual values.

```bash
# 1. Boot NixOS ISO, configure network (see Fresh Installation Step 1)

# 2. Unlock LUKS (adjust device path as needed)
sudo cryptsetup luksOpen /dev/sda2 crypted
# Enter LUKS passphrase

# 3. Activate LVM
sudo vgchange -ay pool

# 4. Mount filesystems (adjust paths as needed)
sudo mkdir -p /mnt/{home,nix,var/log,boot}
sudo mount -o subvol=@ /dev/pool/root /mnt
sudo mount -o subvol=@home /dev/pool/root /mnt/home
sudo mount -o subvol=@nix /dev/pool/root /mnt/nix
sudo mount -o subvol=@log /dev/pool/root /mnt/var/log
sudo mount /dev/sda1 /mnt/boot

# 5. Enter system
sudo nixos-enter --root /mnt

# 6. Rollback
nixos-rebuild switch --rollback

# 7. Or rebuild from config (if fixed)
nixos-rebuild switch --flake <repo>#nithra
```

### Re-encrypt Secrets with New Age Key

If age key is compromised or migrating to a new key:

```bash
# 1. Generate new key
nix-shell -p age --run "age-keygen -o /tmp/new-age-key.txt"

# 2. Get new public key
nix-shell -p age --run "age-keygen -y /tmp/new-age-key.txt"
# Copy output for next step

# 3. Update .sops.yaml with new public key
vim .sops.yaml  # Replace the age1... public key

# 4. Re-encrypt sops secrets
# (Must have OLD key to decrypt, will encrypt with NEW key from .sops.yaml)
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run \
  "sops updatekeys Private/Nithra/sops-nix.yaml"

# 5. Update git-agecrypt configuration
# Replace key and reconfigure
cp /tmp/new-age-key.txt ~/.config/git-agecrypt/keys.txt
chmod 600 ~/.config/git-agecrypt/keys.txt
git config --unset-all filter.git-agecrypt.smudge
git config --unset-all filter.git-agecrypt.clean
nix-shell -p git-agecrypt --run "git-agecrypt init"
nix-shell -p git-agecrypt --run "git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt"

# 6. Re-encrypt git-agecrypt secrets (touch to trigger re-encryption on commit)
git checkout -- Private/Nithra/git-agecrypt.nix
# Make a trivial edit (add/remove whitespace) and commit

# 7. Deploy new key to server
sudo cp /tmp/new-age-key.txt /var/lib/sops-nix/key.txt
sudo chmod 600 /var/lib/sops-nix/key.txt

# 8. Update password manager backup with new key

# 9. Securely delete temporary key file
# Note: shred may not be effective on SSD/btrfs due to wear leveling and COW
shred -u /tmp/new-age-key.txt 2>/dev/null || rm /tmp/new-age-key.txt
```

### Lost LUKS Passphrase

**Unrecoverable.** Data is encrypted and cannot be accessed without the passphrase. Options:

1. Reinstall from scratch using Fresh Installation guide
2. Restore from backups (if any exist outside the encrypted volume)

### Generate New SSH Host Keys

If host keys are compromised or you need fresh keys:

```bash
# Generate both keys (empty passphrase)
nix-shell -p openssh --run "
  ssh-keygen -t ed25519 -N '' -f /tmp/boot_host_key
  ssh-keygen -t ed25519 -N '' -f /tmp/login_host_key
"

# Display private keys
echo "=== hostKeys.nithra_all_all_boot (for git-agecrypt.nix) ===" && cat /tmp/boot_host_key
echo "=== nithra_all_all_login (for sops-nix.yaml) ===" && cat /tmp/login_host_key

# Clean up temporary files
rm /tmp/boot_host_key /tmp/boot_host_key.pub
rm /tmp/login_host_key /tmp/login_host_key.pub

# Update secrets:
# 1. Add boot key to Private/Nithra/git-agecrypt.nix → hostKeys.nithra_all_all_boot
# 2. Add login key to Private/Nithra/sops-nix.yaml → nithra_all_all_login

# After updating both secrets files, deploy and clear client known_hosts
./install.sh
ssh-keygen -R <ip>        # On each client machine
ssh-keygen -R nithra      # Also remove by hostname if used
ssh-keygen -R nithra-boot
```

### Reinstall Bootloader

From inside `nixos-enter`:
```bash
nixos-rebuild boot --flake <repo>#nithra
```

### Emergency Access Methods

| Method | Command | When |
|--------|---------|------|
| SSH | `ssh nithra` | Normal access |
| Mosh | `mosh nithra` | Unstable/high-latency connection |
| initrd SSH | `ssh nithra-boot` | LUKS unlock at boot |
| VNC | Provider control panel | Network broken, SSH broken |

### Common Issues

**SSH connection refused after deploy:**
- New config may have broken SSH
- Use VNC to access and rollback: `sudo nixos-rebuild switch --rollback`

**LUKS unlock hangs/times out:**
- Check initrd SSH host key matches known_hosts
- Remove old key: `ssh-keygen -R <ip>` then retry

**System boots but can't login:**
- Boot previous generation from systemd-boot menu (VNC)
- Check if sops secrets decrypted: `sudo ls /run/secrets/`
- If empty, age key may be missing or wrong at `/var/lib/sops-nix/key.txt`

**Sudo password rejected:**
- Password hash may be wrong in sops-nix.yaml
- Boot previous generation and fix hash
- Generate new hash: `nix-shell -p mkpasswd --run "mkpasswd -m sha-512"`

**Shell not working (falls back to sh):**
- Check `programs.zsh.enable = true` in `Homes/ezirius/nithra-account.nix`

**Host key verification failed:**
- initrd SSH and OpenSSH have different host keys (by design)
- After reinstall or key rotation: `ssh-keygen -R <ip>` on client, then reconnect
- May need to remove both `nithra` and `nithra-boot` entries

**git-agecrypt not decrypting:**
- Check key configured: `git config --get-regexp agecrypt`
- Check key exists: `ls -la ~/.config/git-agecrypt/keys.txt`
- Reinstall filters, then re-add identity:
  ```bash
  nix-shell -p git-agecrypt --run "git-agecrypt init"
  nix-shell -p git-agecrypt --run "git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt"
  ```
- Force re-checkout: `git checkout -- Private/Nithra/git-agecrypt.nix`

**Build fails with "git-agecrypt.nix: No such file":**
- File exists but is encrypted/binary
- Ensure git-agecrypt is configured and re-checkout the file

**Locked out by fail2ban:**
- Access via VNC (fail2ban only affects network)
- Check status: `sudo fail2ban-client status sshd`
- Unban IP: `sudo fail2ban-client set sshd unbanip <your-ip>`
- Check banned IPs: `sudo fail2ban-client get sshd banned`

**Can't connect after VPS provider maintenance:**
- Provider may have changed IP or network config
- Access via VNC to diagnose
- Check `ip addr` and compare with git-agecrypt.nix network settings

**nixos-rebuild takes forever / hangs:**
- Large updates may take 30+ minutes
- Check network connectivity: `ping 1.1.1.1`
- If stuck on "building", check disk space: `df -h`
- Can safely Ctrl+C and re-run `./install.sh`

**Git signing fails on Maldoria (1Password):**
- Check `SSH_AUTH_SOCK` points to 1Password: `echo $SSH_AUTH_SOCK`
- Should be: `$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`
- If wrong, check `home.sessionVariables` in `Homes/ezirius/maldoria-home.nix` and restart terminal
- List available keys: `ssh-add -L` (should show keys from 1Password)
- Test signing: `echo "test" | ssh-keygen -Y sign -f ~/.ssh/maldoria_github_ezirius_sign -n git`
- Ensure the key exists in 1Password as an "SSH Key" item type (not just a note)

**git-agecrypt encrypts with wrong key:**
- git-agecrypt caches encrypted files in `.git/git-agecrypt/`
- If the cache was created with a different key, it will keep using the wrong encryption
- Fix: delete cache and reinitialize:
  ```bash
  rm -rf .git/git-agecrypt/
  nix-shell -p git-agecrypt --run "git-agecrypt init"
  ```
- Verify encryption: `git show HEAD:Private/<host>/git-agecrypt.nix | head -5`
- If still failing, manually encrypt and add:
  ```bash
  nix-shell -p age --run "age -e -r <pubkey> -o /tmp/encrypted.nix Private/<host>/git-agecrypt.nix"
  git hash-object -w /tmp/encrypted.nix  # outputs <hash>
  git update-index --add --cacheinfo 100644,<hash>,Private/<host>/git-agecrypt.nix
  ```

---

## 8. Security Model

### Two-Stage Access

```
┌─────────────────────────────────────────────────────────┐
│ Stage 1: Boot (initrd SSH)                              │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ Purpose: LUKS unlock only                           │ │
│ │ Port: 22                                            │ │
│ │ User: root                                          │ │
│ │ Keys: command="systemd-tty-ask-password-agent"       │ │
│ │ Timeout: Disabled (waits indefinitely)              │ │
│ └─────────────────────────────────────────────────────┘ │
│                         │                               │
│                         ▼                               │
│ Stage 2: Runtime (OpenSSH)                              │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ Purpose: Administration                             │ │
│ │ Ports: 22/tcp (SSH), 60000-60010/udp (Mosh)         │ │
│ │ User: ezirius only (root disabled)                  │ │
│ │ Auth: Public key only (passwords disabled)          │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### SSH Hardening

| Setting | Value | Effect |
|---------|-------|--------|
| PermitRootLogin | no | Root cannot SSH |
| PasswordAuthentication | no | Keys only |
| KbdInteractiveAuthentication | no | No keyboard auth |
| AllowUsers | ezirius | Whitelist |
| AuthenticationMethods | publickey | Keys only |
| X11Forwarding | no | No X11 |
| AllowTcpForwarding | no | No tunnels |
| AllowAgentForwarding | no | No agent |
| AllowStreamLocalForwarding | no | No sockets |
| HostKeyAlgorithms | ssh-ed25519 | Ed25519 only |
| Ciphers | chacha20-poly1305@openssh.com, aes256-gcm@openssh.com | Strongest cipher + Blink fallback |
| MACs | hmac-sha2-512-etm@openssh.com | Strongest MAC |
| KexAlgorithms | mlkem768x25519-sha256, sntrup761x25519-sha512, curve25519-sha256 | Post-quantum with fallbacks |
| MaxStartups | 10:30:60 | Rate limit unauthenticated |

### Kernel Hardening

| Category | Settings |
|----------|----------|
| Memory | protectKernelImage, kptr_restrict=2 |
| Debug | dmesg_restrict=1, perf_event_paranoid=3 |
| Process | ptrace_scope=2, unprivileged_bpf_disabled=1 |
| BPF | bpf_jit_harden=2 |
| Network | No redirects, no source routing, SYN cookies, RP filter |

### Additional Protections

- **fail2ban** - Brute-force protection (`maxretry=3`, bans start at 1h, double on repeat offence up to 168h/1 week max)
- **Firewall** - SSH implicit, Mosh explicit, all else blocked
- **LUKS** - Full disk encryption (AES with hardware acceleration via aesni_intel)
- **Separate host keys** - Different keys for initrd SSH and OpenSSH (if one is compromised, attacker can't impersonate the other stage)
- **Managed host keys** - No auto-generated keys, initrd SSH key in git-agecrypt.nix, OpenSSH key in sops-nix.yaml

---

## 9. Reference

### Repository Structure

```
<repo>/
├── flake.nix                 # Entry point, nixosConfigurations, formatter
├── flake.lock                # Pinned input versions
├── install.sh                # Deploy script (ensures keys, stages, builds)
├── git.sh                    # Git script (formats, validates, stages, commits, pushes)
├── clone.sh                  # Fresh install script (clone, decrypt, setup) - standalone
├── partition.sh              # Disk partitioning script (wipes disk, runs disko)
├── .gitignore                # Excludes .DS_Store
├── .gitattributes            # git-agecrypt filter for git-agecrypt.nix files
├── .sops.yaml                # sops-nix age key configuration
├── git-agecrypt.toml         # git-agecrypt recipient configuration
├── AGENTS.md                 # AI agent instructions
├── README.md                 # This file
├── Libraries/
│   └── lib.sh                # Shared bash functions (sourced by install.sh, git.sh, partition.sh)
├── Hosts/
│   ├── Common/
│   │   └── default.nix       # Shared OS settings (all hosts)
│   ├── Maldoria/
│   │   └── default.nix       # Darwin host config (sops refs, packages)
│   └── Nithra/
│       ├── default.nix       # NixOS host config (network, boot, sops refs)
│       └── disko-config.nix  # Disk layout (GPT, LUKS, LVM, Btrfs)
├── Homes/
│   ├── Common/
│   │   ├── common-all-home.nix      # All users, all hosts
│   │   └── common-ezirius-home.nix  # Ezirius only, all hosts
│   ├── ezirius/
│   │   ├── maldoria-home.nix   # Home-manager for Maldoria (macOS)
│   │   ├── nithra-account.nix  # System user (groups, shell, auth) - NixOS
│   │   └── nithra-home.nix     # Home-manager for Nithra (NixOS)
│   └── root/
│       ├── nithra-account.nix  # Root user config - NixOS
│       └── nithra-home.nix     # Root home-manager - NixOS
├── Public/
│   ├── Common/
│   │   ├── configurations.nix  # user.{name, email}
│   │   └── keys.nix            # GitHub host pubkeys
│   ├── Maldoria/
│   │   └── keys.nix            # loginKeysPub (inbound), hostKeysPub (Nithra's for known_hosts)
│   └── Nithra/
│       ├── configurations.nix  # nameservers
│       └── keys.nix            # bootKeysPub, loginKeysPub
└── Private/
    ├── Common/
    │   └── git-agecrypt.nix    # Encrypted: locale.timeZone, network.nithraIp
    ├── Maldoria/
    │   ├── git-agecrypt.nix    # Encrypted: Maldoria-specific secrets
    │   └── sops-nix.yaml       # Encrypted: SSH key pubkeys (for 1Password matching)
    └── Nithra/
        ├── git-agecrypt.nix    # Encrypted: network, initrd SSH host key
        └── sops-nix.yaml       # Encrypted: passwords, OpenSSH host key, GitHub SSH keys
```

### Storage Layout

```
/dev/sda
├── sda1: ESP (1GB, FAT32) → /boot
└── sda2: LUKS
    └── LVM "pool"
        ├── swap (4GB)
        └── root (Btrfs, remaining space)
            ├── @ → /
            ├── @home → /home
            ├── @nix → /nix
            └── @log → /var/log

Mount options: compress=zstd,noatime,discard=async
LUKS: allowDiscards=true (SSD TRIM passthrough)
```

### Network

| Setting | Value |
|---------|-------|
| IP/Gateway/Prefix | See git-agecrypt.nix |
| DNS | 1.1.1.1, 8.8.8.8 |
| Interface | ens18 (VirtIO) |
| DHCP | Disabled |

### Packages

See the actual config files for current package lists (these change frequently):

- **System packages**: `Hosts/<host>/default.nix` → `environment.systemPackages`
- **User packages**: `Homes/<user>/<host>-home.nix` → `home.packages`
- **Program modules**: `Homes/<user>/<host>-home.nix` → `programs.*`

### Flake Inputs

| Input | Source | Purpose |
|-------|--------|---------|
| nixpkgs | [nixos-unstable](https://github.com/NixOS/nixpkgs) | Package repository |
| disko | [nix-community/disko](https://github.com/nix-community/disko) | Declarative disk partitioning (NixOS) |
| home-manager | [nix-community/home-manager](https://github.com/nix-community/home-manager) | User environment management |
| sops-nix | [Mic92/sops-nix](https://github.com/Mic92/sops-nix) | Runtime secrets decryption |
| nix-darwin | [LnL7/nix-darwin](https://github.com/LnL7/nix-darwin) | macOS system configuration |

All inputs follow nixpkgs (`inputs.nixpkgs.follows = "nixpkgs"`) to avoid version conflicts.

### Automatic Maintenance

| Task | Schedule | Description |
|------|----------|-------------|
| Garbage Collection | Monday 06:00 | Deletes derivations older than 30 days |
| Store Optimisation | Automatic | Hard-links duplicate files in /nix/store |
| Btrfs Scrub | Monthly | Verifies checksums on `/` filesystem |
| Journal Rotation | Continuous | Limits to 500MB, deletes entries older than 1 month |

### Locale

| Setting | Nithra | Maldoria |
|---------|--------|----------|
| Timezone | `secrets.locale.timeZone` | `secrets.locale.timeZone` |
| Locale | `secrets.locale.defaultLocale` | macOS managed |

### Boot

| Setting | Value |
|---------|-------|
| Bootloader | systemd-boot |
| Max Generations | 10 |
| LUKS Timeout | Disabled (indefinite) |
| Initrd | systemd-based |
| Network Reset | flushBeforeStage2 |

### Maldoria (Darwin) Specifics

| Setting | Value |
|---------|-------|
| Platform | macOS (nix-darwin) |
| Architecture | aarch64-darwin (Apple Silicon) |
| Storage | APFS (managed by macOS) |
| Network | DHCP (managed by macOS) |
| Firewall | Application Firewall (incoming only) |

**Security:**
- Application Firewall with stealth mode
- SSH server (keys only, no root, AllowUsers ezirius)
- Touch ID for sudo authentication
- 1Password SSH agent for key management

**1Password Integration:**
- SSH agent: `$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`
- Public keys for outbound connections (Nithra, GitHub) deployed to `~/.ssh/` via sops
- Private keys remain in 1Password vault
- Agent matches public keys to vault entries automatically

**Key differences from NixOS:**

| Aspect | NixOS (Nithra) | Darwin (Maldoria) |
|--------|----------------|-------------------|
| SSH login keys | git-agecrypt.nix | Public/keys.nix (activation script) |
| SSH private keys | sops-nix (files) | 1Password vault |
| Firewall | nftables + fail2ban | Application Firewall |
| User creation | Declarative | Manual (System Settings) |
| Disk encryption | LUKS | FileVault (managed by macOS) |

### Remote Desktop (Virtual Display)

Headless remote GUI via RustDesk, running in virtual X display `:1`. Physical display shows TTY only.

**Services:**
| Service | Description |
|---------|-------------|
| `virtual-desktop` | Xvnc on display `:1` (localhost only) |
| `virtual-i3` | i3 window manager in virtual display |
| `virtual-rustdesk` | RustDesk capturing virtual display |

**Initial Setup:** RustDesk requires manual configuration on first run. Access via VNC to set the permanent password and note the RustDesk ID for client connections.

**i3 Keybinds:** See `Homes/ezirius/nithra-home.nix` → `xsession.windowManager.i3.config` for current keybinds. Uses `alt` modifier with vim-style navigation.

### Key File Locations

| File | Purpose |
|------|---------|
| `/var/lib/sops-nix/key.txt` | Age private key (sops-nix) |
| `~/.config/git-agecrypt/keys.txt` | Age private key (git-agecrypt) |
| `/run/secrets/*` | sops-nix decrypted secrets (tmpfs, runtime only) |
| (in initrd, via Nix store) | initrd SSH host key |
| `/etc/ssh/ssh_host_ed25519_key` | OpenSSH host key |
| `/home/ezirius/.ssh/<host>_github_ezirius_nix-configurations` | GitHub SSH key (Nithra: private key, Maldoria: public key for 1Password) |
| `/home/ezirius/.ssh/<host>_github_ezirius_sign` | Git signing key (Nithra: private key, Maldoria: public key for 1Password) |

### Quick Reference Commands

```bash
# Deploy changes
./install.sh

# Commit and push (without rebuilding)
./git.sh

# Amend the previous commit
./git.sh --amend

# Clear git history (for forking to empty repo)
./git.sh --reset

# Update all packages
nix flake update && ./install.sh

# Edit sops secrets
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Private/Nithra/sops-nix.yaml"

# Check current generation
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# Rollback
sudo nixos-rebuild switch --rollback

# Check if reboot needed
[ "$(readlink /run/booted-system/kernel)" = "$(readlink /nix/var/nix/profiles/system/kernel)" ] || echo "Reboot required"

# Format nix files
nix fmt

# Validate without building
nix flake check
```

---

## 10. Forking for Your Own Use

This repository is configured for specific hosts (Nithra, Maldoria) and a specific user (ezirius). If you want to use this as a template for your own infrastructure, follow these steps.

### Overview

You will need to:
1. Remove the platform you don't need (Darwin or NixOS)
2. Rename or delete hosts
3. Rename or delete users
4. Generate your own encryption keys
5. Create your own secrets
6. Update configuration files

### Step 1: Create Your Repository and Clone

```bash
# 1. Create a new repository on GitHub (can be empty or initialised - doesn't matter)

# 2. Clone the original repository locally:
git clone https://github.com/ezirius/Nix-Configurations.git
cd Nix-Configurations
```

Note: `clone.sh` will detect an unknown hostname and clone without attempting to decrypt secrets. We clone the original first to get all the files, then later use `./git.sh --reset` to clear the history before pushing to your own repository.

### Step 2: Remove Unwanted Platform

**If you only need Linux (NixOS):**
```bash
rm -rf Hosts/Maldoria/
rm -rf Private/Maldoria/
rm -rf Public/Maldoria/
rm -f Homes/ezirius/maldoria-home.nix
```

Then edit `flake.nix` to remove `darwinConfigurations` and nix-darwin input.

**If you only need Darwin (macOS):**
```bash
rm -rf Hosts/Nithra/
rm -rf Private/Nithra/
rm -rf Public/Nithra/
rm -f Homes/ezirius/nithra-home.nix
rm -f Homes/ezirius/nithra-account.nix
rm -rf Homes/root/
```

Then edit `flake.nix` to remove `nixosConfigurations` and disko input.

### Step 3: Rename Hosts

Rename the remaining host directory to your hostname:
```bash
# Example: Rename Nithra to MyServer
mv Hosts/Nithra Hosts/MyServer
mv Private/Nithra Private/MyServer
mv Public/Nithra Public/MyServer
mv Homes/ezirius/nithra-home.nix Homes/ezirius/myserver-home.nix
mv Homes/ezirius/nithra-account.nix Homes/ezirius/myserver-account.nix  # NixOS only
```

Update host arrays in:
- `Libraries/lib.sh`: Update `LINUX_HOSTS` or `DARWIN_HOSTS`
- `clone.sh`: Update `LINUX_HOSTS` or `DARWIN_HOSTS` (duplicated for standalone use)

Update `flake.nix`:
- Rename configuration key (e.g., `nixosConfigurations.nithra` → `nixosConfigurations.myserver`)
- Update imports to use new paths

### Step 4: Rename or Delete Users

**To rename the user (e.g., ezirius → alice):**
```bash
mv Homes/ezirius Homes/alice
mv Homes/Common/common-ezirius-home.nix Homes/Common/common-alice-home.nix
```

Update references in:
- `Homes/Common/common-alice-home.nix`: Update imports if needed
- `Homes/alice/*-home.nix`: Update `home.username`
- `Homes/alice/*-account.nix`: Update user definition (NixOS only)
- `Hosts/*/default.nix`: Update username variables, sops paths, SSH config
- `Public/Common/configurations.nix`: Update `user.name` and `user.email`
- `Libraries/lib.sh`: Update `PRIMARY_USER`
- `flake.nix`: Update `home-manager.users.<name>` references

**To delete root home-manager config (if not needed):**
```bash
rm -rf Homes/root/
```

Remove imports from `Hosts/*/default.nix` and `flake.nix`.

### Step 5: Generate Your Own Keys

**git-agecrypt key:**
```bash
mkdir -p ~/.config/git-agecrypt
age-keygen -o ~/.config/git-agecrypt/keys.txt
chmod 600 ~/.config/git-agecrypt/keys.txt

# Note the public key (starts with age1...)
age-keygen -y ~/.config/git-agecrypt/keys.txt
```

**sops-nix key:**
```bash
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt
sudo chmod 600 /var/lib/sops-nix/key.txt

# Note the public key
sudo age-keygen -y /var/lib/sops-nix/key.txt
```

### Step 6: Update Encryption Configuration

**git-agecrypt.toml:**
Replace the recipient public key with your git-agecrypt public key:
```toml
[[recipients]]
recipient = "age1your-public-key-here"
files = ["Private/*/git-agecrypt.nix"]
```

**.sops.yaml:**
Replace the age public key with your sops-nix public key:
```yaml
keys:
  - &shared age1your-sops-public-key-here
creation_rules:
  - path_regex: Private/.*/sops-nix\.yaml$
    key_groups:
      - age:
          - *shared
```

**.gitattributes:**
Update paths if you renamed hosts:
```
Private/MyServer/git-agecrypt.nix filter=git-agecrypt diff=git-agecrypt
Private/Common/git-agecrypt.nix filter=git-agecrypt diff=git-agecrypt
```

### Step 7: Create Your Secrets

**Private/Common/git-agecrypt.nix** (shared across all hosts):
```nix
{
  locale = {
    timeZone = "Europe/London";
    defaultLocale = "en_GB.UTF-8";
  };
  # Add other shared secrets as needed
}
```

**Private/MyServer/git-agecrypt.nix** (host-specific):
```nix
{
  network = {
    myserverIp = "YOUR_IP";
    myserverGateway = "YOUR_GATEWAY";
  };
  # Add other host-specific secrets as needed (see existing files for structure)
}
```

**Private/MyServer/sops-nix.yaml:**
```bash
# Create and edit (will encrypt on save)
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops Private/MyServer/sops-nix.yaml
```

Add your secrets (passwords, SSH keys, etc.) - see Section 5 for structure.

### Step 8: Configure git-agecrypt

```bash
nix-shell -p git-agecrypt --run "git-agecrypt init"
nix-shell -p git-agecrypt --run "git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt"
```

### Step 9: Update Host Configuration

Edit `Hosts/MyServer/default.nix`:
- Update `networking.hostName`
- Update network configuration to use your secrets
- Update sops secret paths
- Update user references

### Step 10: Test and Deploy

```bash
# Validate configuration
nix flake check

# Clear history and push to your repository
# This removes all upstream commits and creates a fresh initial commit
# You'll be prompted for the remote URL and confirmation before pushing
./git.sh --reset

# Deploy
./install.sh
```

### Checklist

- [ ] Created repository on GitHub (empty or initialised - either works)
- [ ] Removed unwanted platform (Darwin/NixOS)
- [ ] Renamed host directories and files
- [ ] Renamed/deleted users
- [ ] Updated host arrays in `lib.sh` and `clone.sh`
- [ ] Generated git-agecrypt key
- [ ] Generated sops-nix key
- [ ] Updated `git-agecrypt.toml` with your public key
- [ ] Updated `.sops.yaml` with your public key
- [ ] Updated `.gitattributes` with correct paths
- [ ] Created `Private/Common/git-agecrypt.nix` (shared secrets)
- [ ] Created `Private/<host>/git-agecrypt.nix`
- [ ] Created `Private/<host>/sops-nix.yaml`
- [ ] Configured git-agecrypt filters
- [ ] Updated `flake.nix` with new host/user names
- [ ] Updated `Public/Common/configurations.nix` with your details
- [ ] Tested with `nix flake check`
- [ ] Committed and deployed

---

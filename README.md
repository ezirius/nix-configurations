# Nithra NixOS Configuration

Encrypted declarative NixOS infrastructure for a Proxmox VE VPS with LUKS full-disk encryption and remote unlock via Dropbear SSH.

| Item | Value |
|------|-------|
| Hostname | nithra |
| Architecture | x86_64-linux |
| NixOS Channel | nixos-unstable |
| State Version | 24.11 |

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

---

## 1. Overview

### System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        NITHRA (VPS)                             │
│  ┌───────────────────┐      ┌───────────────────────────────┐  │
│  │ Stage 1: Boot     │      │ Stage 2: Runtime              │  │
│  │ (Dropbear SSH)    │ ──▶  │ (OpenSSH)                     │  │
│  │                   │      │                               │  │
│  │ - LUKS unlock     │      │ - Normal administration       │  │
│  │ - Port 22         │      │ - Port 22 (SSH)               │  │
│  │ - Root user       │      │ - Port 60000-61000/udp (Mosh) │  │
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

- **Nithra**: A Proxmox VE VPS with full-disk encryption (LUKS)
- **Ipsa, Ipirus, Maldoria**: Client machines that manage and access nithra
- **Two-stage boot**: Dropbear SSH in initrd for LUKS unlock, then OpenSSH for normal access
- **Declarative config**: Entire system defined in Nix, version controlled in Git

### Boot Flow

1. VPS powers on
2. Dropbear SSH starts in initrd (Stage 1)
3. Client SSHs in (`ssh nithra-boot`), enters LUKS passphrase
4. System decrypts and boots
5. OpenSSH starts (Stage 2)
6. Client SSHs in (`ssh nithra`) for normal use

---

## 2. Prerequisites

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
    IdentityFile ~/.ssh/id_ed25519

Host nithra-boot
    HostName <static-ip>
    User root
    IdentityFile ~/.ssh/id_ed25519
    # Different host key than nithra (Dropbear vs OpenSSH)
```

**Note:** First connection to each host will prompt to accept the host key. Dropbear (boot) and OpenSSH (runtime) intentionally use different keys, so you'll need to accept both. This prevents an attacker who compromises one from impersonating the other.

**Mosh usage:** `mosh nithra` works out of the box - UDP ports 60000-61000 are open on the server firewall.

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
1. Formats all `.nix` files with `nix fmt`
2. Stages all git files (required for flakes)
3. Verifies secrets are encrypted
4. Validates flake with `nix flake check`
5. Commits and pushes changes
6. Detects hostname or prompts for selection
7. Runs `nixos-rebuild switch --flake .#<host>` with `--show-trace`
8. Creates symlink to `~/.config/nixos` if repo is elsewhere

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
3. SSH to Dropbear: `ssh nithra-boot`
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
nix fmt                   # Uses nixfmt-rfc-style (runs automatically in install.sh)
```

### Validate Configuration

```bash
cd <repo>
nix flake check                              # Validates flake structure
nixos-rebuild build --flake .#nithra         # Test build without switching
```

---

## 4. Configuration Changes

### Add SSH Key for Login

SSH login keys are stored in git-agecrypt.nix (not sops) because they're needed at Nix evaluation time.

1. Edit `Secrets/Nithra/git-agecrypt.nix`

2. Add to `sshPubKeys`:
   ```nix
   sshPubKeys = {
     # ... existing keys ...
     newmachine = "ssh-ed25519 AAAA...";
   };
   ```

3. Add to `Hosts/Nithra/default.nix` in the `authorizedKeys.keys` list:
   ```nix
   users.users.<user>.openssh.authorizedKeys.keys = [
     # ... existing keys ...
     secrets.sshPubKeys.newmachine
   ];
   ```

4. `./install.sh`

### Add SSH Key for Boot Unlock

1. Edit `Secrets/Nithra/git-agecrypt.nix`

2. Add to `dropbear.authorizedKeys`:
   ```nix
   ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="cryptsetup-askpass" ssh-ed25519 AAAA...''
   ```

3. `./install.sh`

**Note:** Dropbear keys are restricted to only run `cryptsetup-askpass` - they cannot execute other commands.

### Add New User

1. Create directory structure:
   ```
   Users/<name>/
   ├── default.nix    # System user config
   └── home.nix       # Home-manager config
   ```

2. Generate password hash:
   ```bash
   nix-shell -p mkpasswd --run "mkpasswd -m sha-512"
   ```

3. Add password to `Secrets/Nithra/sops-nix.yaml`:
   ```bash
   cd <repo>
   sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Secrets/Nithra/sops-nix.yaml"
   ```
   Add: `<name>-password: "<hash from step 2>"`

4. Add sops reference in `Hosts/Nithra/default.nix`:
   ```nix
   sops.secrets.<name>-password.neededForUsers = true;
   ```

5. Import user in `Hosts/Nithra/default.nix`:
   ```nix
   imports = [
     ...
     ../../Users/<name>
   ];
   ```

6. Add home-manager in `flake.nix`:
   ```nix
   home-manager.users.<name> = import ./Users/<name>/home.nix;
   ```

7. `./install.sh`

### Add System Package

Edit `Modules/Core/default.nix`:
```nix
environment.systemPackages = builtins.attrValues {
  inherit (pkgs)
    ...
    newpackage
    ;
};
```

### Add User Package (via home-manager)

Edit `Users/<user>/home.nix`. First ensure `pkgs` is in the function arguments:
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

### Add New Host

1. Create `Hosts/<hostname>/default.nix` and `disko-config.nix`
2. Create `Secrets/<hostname>/git-agecrypt.nix` (copy and modify from Nithra)
3. Create `Secrets/<hostname>/sops-nix.yaml` for runtime secrets
4. Add to `flake.nix`:
   ```nix
   nixosConfigurations.<hostname> = nixpkgs.lib.nixosSystem {
     modules = [ ... ];
   };
   ```
5. Add to `install.sh`, `clone.sh`, and `partition.sh` `KNOWN_HOSTS` arrays
6. Update `.sops.yaml` with host's age public key

---

## 5. Secrets Management

### Architecture

Two-layer system due to NixOS evaluation constraints:

| Layer | Tool | File | When Decrypted | Use Case |
|-------|------|------|----------------|----------|
| 1 | git-agecrypt | `Secrets/<host>/git-agecrypt.nix` | Git checkout (eval time) | Network config, host keys, Dropbear keys, SSH login pubkeys |
| 2 | sops-nix | `Secrets/<host>/sops-nix.yaml` | System activation | User passwords, GitHub SSH private key |

**Why two layers?** Layer 1 secrets are needed during Nix evaluation (e.g., boot kernel params) or in initrd (before sops-nix runs). Layer 2 secrets are decrypted at runtime by sops-nix. See the comments in `Secrets/Nithra/git-agecrypt.nix` for detailed explanation.

### git-agecrypt.nix Encryption Behavior

**IMPORTANT:** `git-agecrypt.nix` is **always decrypted in your working directory** - this is correct and expected!

| Location | State | Why |
|----------|-------|-----|
| Working directory | **Plaintext** | Required for Nix to import and evaluate |
| Git commits/remote | **Encrypted** | git-agecrypt encrypts via clean filter on commit |

To verify encryption is working:
```bash
# Local file (should be readable plaintext)
head Secrets/Nithra/git-agecrypt.nix

# In git (should be binary/gibberish)
git show HEAD:Secrets/Nithra/git-agecrypt.nix | head -5
```

If you can read the local file but `git show` displays binary, git-agecrypt is working correctly.

### Age Key Locations

| Path | Owner | Purpose |
|------|-------|---------|
| `/var/lib/sops-nix/key.txt` | root | sops-nix (automatic decryption at activation) |
| `~/.config/git-agecrypt/keys.txt` | user | git-agecrypt (decrypt git-agecrypt.nix on checkout) |

- These may be **different keys** - each system has its own age keypair
- Permissions: `600`
- **Back up BOTH keys securely** - losing either means re-creating those secrets

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
vim Secrets/Nithra/git-agecrypt.nix
```

File auto-decrypts on checkout, auto-encrypts on commit via `.gitattributes` filter.

### Edit sops-nix Secrets

```bash
cd <repo>
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Secrets/Nithra/sops-nix.yaml"
```

Opens in `$EDITOR`. File auto-encrypts on save.

### git-agecrypt.nix Contents

The file includes detailed comments explaining why each secret is needed. Structure:

```nix
{
  network = {
    ip = "x.x.x.x";           # Static IP from VPS provider
    gateway = "x.x.x.x";      # Gateway from VPS provider
    prefixLength = 24;        # CIDR prefix (e.g., 24 = /24)
    netmask = "255.255.255.0"; # Kernel params require string format
  };
  dropbear.authorizedKeys = [
    # Each key prefixed with restrictions and command
    ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="cryptsetup-askpass" ssh-ed25519 AAAA... comment''
  ];
  sshPubKeys = {
    machine1 = "ssh-ed25519 AAAA...";  # SSH login keys (one per client machine)
    machine2 = "ssh-ed25519 AAAA...";
  };
  hostKeys = {
    boot = "-----BEGIN OPENSSH PRIVATE KEY-----...";   # Dropbear (initrd)
    login = "-----BEGIN OPENSSH PRIVATE KEY-----...";  # OpenSSH (runtime)
  };
}
```

### sops-nix.yaml Contents

```yaml
root-password: $6$...          # SHA-512 hash from mkpasswd
ezirius-password: $6$...       # SHA-512 hash from mkpasswd
github-ssh-key-nithra: |       # Private key for GitHub push/pull
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
```

**Note:** SSH login public keys are in git-agecrypt.nix (not sops) because sops paths don't exist at Nix evaluation time.

### .sops.yaml Structure

```yaml
keys:
  - &nithra age15z...         # Anchor for nithra's public key
creation_rules:
  - path_regex: Secrets/.*/sops-nix\.yaml$
    key_groups:
      - age:
          - *nithra           # Reference to anchor
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
| This repo | GitHub | git@github.com:Ezirius/Nix-Configurations.git |

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
# Download and run clone script
# Note: Host must be specified when piping (interactive selection doesn't work)
curl -sL https://raw.githubusercontent.com/Ezirius/Nix-Configurations/main/clone.sh | bash -s -- Nithra
```

The script will:
1. Check network connectivity
2. Clone the repository to `/tmp/Nix-Configurations`
3. Prompt you to paste your **git-agecrypt** age private key
4. Prompt you to paste your **sops-nix** age private key (different key!)
5. Configure git-agecrypt filters
6. Verify secrets are encrypted, then decrypt them
7. Print next steps

**Manual alternative:** If the curl command fails, see the manual steps in the script comments or clone manually:
```bash
nix-shell -p git --run "git clone https://github.com/Ezirius/Nix-Configurations.git /tmp/Nix-Configurations"
```

### Step 3: Partition and Format

```bash
cd /tmp/Nix-Configurations

# Run partition script (will prompt for LUKS passphrase)
./partition.sh Nithra
```

The script will:
1. Read the disk device from `disko-config.nix`
2. Verify the disk exists
3. Show disk details and require "yes" confirmation
4. Wipe and partition the disk

**Important:** Remember the LUKS passphrase you enter - it's **unrecoverable** if forgotten. You'll need it for every boot.

### Step 4: Copy sops-nix Key to Target

```bash
# Disko mounts filesystems at /mnt
# Copy the sops-nix key (saved by clone.sh to /tmp/sops-nix-key.txt)
sudo mkdir -p /mnt/var/lib/sops-nix
sudo cp /tmp/sops-nix-key.txt /mnt/var/lib/sops-nix/key.txt
sudo chmod 600 /mnt/var/lib/sops-nix/key.txt
```

### Step 5: Install

```bash
sudo nixos-install --flake /tmp/Nix-Configurations#nithra --no-root-passwd
```

- Takes 10-20 minutes depending on connection
- `--no-root-passwd` because root password is managed via sops-nix
- If it fails, check secrets are decrypted: `head Secrets/Nithra/git-agecrypt.nix`
- If it fails partway, you can re-run the same command - it will resume where it left off

### Step 6: Reboot and Unlock

```bash
sudo reboot
```

After reboot:

1. **Stage 1 (Dropbear):**
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
   # Accept host key on first connection (different from Dropbear key)
   ```

### Step 7: Post-Install Setup

```bash
# Clone repo to permanent location (git is now installed)
git clone git@github.com:Ezirius/Nix-Configurations.git ~/Nix-Configurations
cd ~/Nix-Configurations

# Configure git-agecrypt for future edits
# Note: git-agecrypt key is DIFFERENT from sops-nix key
# Copy your git-agecrypt key from password manager or existing machine
mkdir -p ~/.config/git-agecrypt
vim ~/.config/git-agecrypt/keys.txt  # Paste git-agecrypt key
chmod 600 ~/.config/git-agecrypt/keys.txt
nix-shell -p git-agecrypt --run "git-agecrypt init"
nix-shell -p git-agecrypt --run "git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt"

# Force decrypt git-agecrypt.nix
git checkout -- Secrets/Nithra/git-agecrypt.nix

# Verify config works
./install.sh    # Should complete without errors
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

If OpenSSH broken but system boots (Dropbear still works for unlock):

1. SSH to Dropbear (`ssh nithra-boot`), unlock LUKS
2. At systemd-boot menu (via VNC), press arrow keys to select previous generation
3. Once booted, access via VNC, login as ezirius, fix config and redeploy

### Rollback via VNC

If network broken:

1. Access VNC via VPS provider control panel
2. Login as ezirius locally (console login)
3. `sudo nixos-rebuild switch --rollback`

### Recovery from Live ISO

If system won't boot at all:

```bash
# 1. Boot NixOS ISO, configure network (see Fresh Installation Step 1)

# 2. Unlock LUKS
sudo cryptsetup luksOpen /dev/sda2 crypted
# Enter LUKS passphrase

# 3. Activate LVM
sudo vgchange -ay pool

# 4. Mount filesystems
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
  "sops updatekeys Secrets/Nithra/sops-nix.yaml"

# 5. Update git-agecrypt configuration
# Replace key and reconfigure
cp /tmp/new-age-key.txt ~/.config/git-agecrypt/keys.txt
chmod 600 ~/.config/git-agecrypt/keys.txt
git config --unset-all filter.git-agecrypt.smudge
git config --unset-all filter.git-agecrypt.clean
nix-shell -p git-agecrypt --run "git-agecrypt init"
nix-shell -p git-agecrypt --run "git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt"

# 6. Re-encrypt git-agecrypt secrets (touch to trigger re-encryption on commit)
git checkout -- Secrets/Nithra/git-agecrypt.nix
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

# Display private keys - copy these to git-agecrypt.nix
echo "=== hostKeys.boot ===" && cat /tmp/boot_host_key
echo "=== hostKeys.login ===" && cat /tmp/login_host_key

# Clean up temporary files
rm /tmp/boot_host_key /tmp/boot_host_key.pub
rm /tmp/login_host_key /tmp/login_host_key.pub

# After updating git-agecrypt.nix, deploy and clear client known_hosts
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
| Dropbear | `ssh nithra-boot` | LUKS unlock at boot |
| VNC | Provider control panel | Network broken, SSH broken |

### Common Issues

**SSH connection refused after deploy:**
- New config may have broken SSH
- Use VNC to access and rollback: `sudo nixos-rebuild switch --rollback`

**LUKS unlock hangs/times out:**
- Check Dropbear host key matches known_hosts
- Remove old key: `ssh-keygen -R <ip>` then retry

**System boots but can't login:**
- Boot previous generation from systemd-boot menu (VNC)
- Check if sops secrets decrypted: `sudo ls /run/secrets/`
- If empty, age key may be missing or wrong at `/var/lib/sops-nix/key.txt`

**Sudo password rejected:**
- Password hash may be wrong in secrets.yaml
- Boot previous generation and fix hash
- Generate new hash: `nix-shell -p mkpasswd --run "mkpasswd -m sha-512"`

**Shell not working (falls back to sh):**
- Check `programs.zsh.enable = true` in `Users/Ezirius/default.nix`

**Host key verification failed:**
- Dropbear and OpenSSH have different host keys (by design)
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
- Force re-checkout: `git checkout -- Secrets/Nithra/git-agecrypt.nix`

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

---

## 8. Security Model

### Two-Stage Access

```
┌─────────────────────────────────────────────────────────┐
│ Stage 1: Boot (Dropbear)                                │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ Purpose: LUKS unlock only                           │ │
│ │ Port: 22                                            │ │
│ │ User: root                                          │ │
│ │ Keys: command="cryptsetup-askpass" restricted       │ │
│ │ Timeout: Disabled (waits indefinitely)              │ │
│ └─────────────────────────────────────────────────────┘ │
│                         │                               │
│                         ▼                               │
│ Stage 2: Runtime (OpenSSH)                              │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ Purpose: Administration                             │ │
│ │ Ports: 22/tcp (SSH), 60000-61000/udp (Mosh)         │ │
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

### Kernel Hardening

| Category | Settings |
|----------|----------|
| Memory | protectKernelImage, kptr_restrict=2 |
| Debug | dmesg_restrict=1, perf_event_paranoid=3 |
| Process | ptrace_scope=2, unprivileged_bpf_disabled=1 |
| BPF | bpf_jit_harden=2 |
| Network | No redirects, no source routing, SYN cookies, RP filter |

### Additional Protections

- **fail2ban** - Brute-force protection (auto-bans IPs after failed attempts)
- **Firewall** - SSH implicit, Mosh explicit, all else blocked
- **LUKS** - Full disk encryption (AES with hardware acceleration via aesni_intel)
- **Separate host keys** - Different keys for Dropbear and OpenSSH (if one is compromised, attacker can't impersonate the other stage)
- **Managed host keys** - No auto-generated keys, all keys version-controlled in git-agecrypt.nix

---

## 9. Reference

### Repository Structure

```
<repo>/
├── flake.nix                 # Entry point, nixosConfigurations, formatter
├── flake.lock                # Pinned input versions
├── install.sh                # Deploy script (formats, validates, stages, commits, pushes, builds)
├── clone.sh                  # Fresh install script (clone, decrypt, setup)
├── partition.sh              # Disk partitioning script (wipes disk, runs disko)
├── .gitignore                # Excludes .DS_Store, opencode.json
├── .gitattributes            # git-agecrypt filter for git-agecrypt.nix files
├── .sops.yaml                # sops-nix age key configuration
├── git-agecrypt.toml         # git-agecrypt recipient configuration
├── AGENTS.md                 # AI agent instructions
├── README.md                 # This file
├── Hosts/Nithra/
│   ├── default.nix           # Host config (network, boot, sops refs)
│   └── disko-config.nix      # Disk layout (GPT, LUKS, LVM, Btrfs)
├── Modules/Core/
│   └── default.nix           # Shared config (SSH, firewall, packages, hardening)
├── Secrets/Nithra/
│   ├── git-agecrypt.nix      # Encrypted: network, dropbear keys, SSH login pubkeys, host keys
│   └── sops-nix.yaml         # Encrypted: passwords, GitHub SSH private key
└── Users/{root,Ezirius}/
    ├── default.nix           # System user (groups, shell, auth)
    └── home.nix              # Home-manager (programs, dotfiles)
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
| Interface | ens18 (Proxmox VirtIO) |
| DHCP | Disabled |

### Packages

**System** (`Modules/Core/default.nix`):
curl, git, htop, jujutsu (for other repositories - not this one, see Daily Operations note), mosh, opencode, vim

**User** (ezirius via home-manager programs):
- zsh (with completion, autosuggestion, syntax-highlighting)
- git (with user.name, user.email configured)
- jujutsu (with user.name, user.email configured)
- ssh (with GitHub host key and identity configured)

**Root** (via home-manager):
- EDITOR=vim

### Flake Inputs

| Input | Source | Purpose |
|-------|--------|---------|
| nixpkgs | [nixos-unstable](https://github.com/NixOS/nixpkgs) | Package repository |
| disko | [nix-community/disko](https://github.com/nix-community/disko) | Declarative disk partitioning |
| home-manager | [nix-community/home-manager](https://github.com/nix-community/home-manager) | User environment management |
| sops-nix | [Mic92/sops-nix](https://github.com/Mic92/sops-nix) | Runtime secrets decryption |

All inputs follow nixpkgs (`inputs.nixpkgs.follows = "nixpkgs"`) to avoid version conflicts.

### Automatic Maintenance

| Task | Schedule | Description |
|------|----------|-------------|
| Garbage Collection | Weekly | Deletes derivations older than 30 days |
| Store Optimisation | Automatic | Hard-links duplicate files in /nix/store |
| Btrfs Scrub | Monthly | Verifies checksums on `/` filesystem |
| Journal Rotation | Continuous | Limits to 500MB, deletes entries older than 1 month |

### Locale

| Setting | Value |
|---------|-------|
| Timezone | Africa/Johannesburg |
| Locale | en_GB.UTF-8 |

### Boot

| Setting | Value |
|---------|-------|
| Bootloader | systemd-boot |
| Max Generations | 10 |
| LUKS Timeout | Disabled (indefinite) |
| Initrd | systemd-based |
| Network Reset | flushBeforeStage2 |

### Key File Locations

| File | Purpose |
|------|---------|
| `/var/lib/sops-nix/key.txt` | Age private key (sops-nix) |
| `~/.config/git-agecrypt/keys.txt` | Age private key (git-agecrypt) |
| `/run/secrets/*` | sops-nix decrypted secrets (tmpfs, runtime only) |
| (in initrd, via Nix store) | Dropbear host key |
| `/etc/ssh/ssh_host_ed25519_key` | OpenSSH host key |
| `/home/ezirius/.ssh/id_ed25519` | GitHub SSH private key (sops-managed) |

### Quick Reference Commands

```bash
# Deploy changes
./install.sh

# Update all packages
nix flake update && ./install.sh

# Edit sops secrets
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Secrets/Nithra/sops-nix.yaml"

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

*Last updated: 2025-11-30*

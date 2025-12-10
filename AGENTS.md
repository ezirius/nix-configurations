# Nix Configurations - Agent Instructions

## Agent Rules

- Be concise
- Use British English spelling (e.g. colour, organisation, licence)
- Use metric units
- **Always ask for explicit approval before making any file changes** - describe proposed changes first, wait for user confirmation, then implement
- Never read files in the `Private/` directory (contains encrypted secrets)
- Never read files known to contain sensitive information, including:
  - Private keys (SSH, GPG, age, etc.)
  - Passwords or password hashes
  - API keys or tokens
  - Certificates
  - Environment files with credentials (.env)
  - Encryption keys
  - Authentication credentials
  - Personal identification information
- Before pushing to GitHub, check for exposed sensitive information in all modified files (while still following the rules above)
- Use past tense in commit messages (e.g. "Added feature" not "Add feature")
- Always check the current date before providing technical advice to ensure information is not outdated
- When uncertain, search reliable and unbiased sources (official documentation, reputable sources) before making claims
- When presenting multiple options, always number them so the user can respond by number
- Always use Catppuccin Mocha theme (or the closest equivalent) when configuring applications - this includes colour schemes, syntax highlighting, terminal colours, and UI themes
- Always enable vim/vi keybindings where supported (shells, editors, pagers, tmux, readline, etc.)

## Critical Facts

1. **Git staging required** - Flakes only see staged files. On live ISO (`HOST_TYPE=nixos`), `./install.sh` uses `path:` prefix to read from working directory directly. On installed systems, it requires all changes to be committed first. `nix flake check` never auto-stages.

2. **Two secrets layers:**
   - `Private/<host>/git-agecrypt.nix` (and `Private/Common/git-agecrypt.nix` for shared secrets) → git-agecrypt → needed at eval/build time (network config, initrd SSH host key, initrd SSH authorised keys, SSH login pubkeys on NixOS)
   - `Private/<host>/sops-nix.yaml` → sops-nix → decrypted at activation time (passwords, OpenSSH host key, GitHub SSH keys on NixOS; SSH private key pubkeys for 1Password matching on Darwin)
   
   **Platform difference:** NixOS needs login pubkeys in git-agecrypt (`authorizedKeys.keys` requires eval-time values). Darwin stores login pubkeys in `Public/Maldoria/keys.nix` (they're public) and writes `authorized_keys` via activation script. Darwin's sops-nix.yaml contains public keys that 1Password uses to identify which private keys to provide from its vault.

3. **git-agecrypt.nix is DECRYPTED LOCALLY - this is correct!** Locally it's plaintext (required for Nix to import it); git-agecrypt encrypts on commit.

4. **Remote LUKS server** - Breaking SSH/network config locks out the user. Always warn before such changes.

   **Client machines:** Ipsa, Ipirus, and Maldoria are client machines that connect to Nithra. SSH keys for these machines are stored in git-agecrypt.nix.

5. **git-agecrypt.nix is a Nix file** - Imported directly with `import ../../Private/<host>/git-agecrypt.nix`, not via sops. Values accessed as `secrets.network.nithraIp`, etc.

6. **Use git for this repo, not jj** - jj doesn't support .gitattributes filters, so git-agecrypt won't encrypt. jj is fine for other repositories.

7. **Secrets placement principle** - All system-identifying information (IPs, keys, etc.) is sensitive. Prefer sops-nix over git-agecrypt when possible. Use git-agecrypt only when values are needed at Nix evaluation time or build time (before sops-nix runs).

8. **SSH hardening** - Both Nithra and Maldoria use hardened SSH algorithms: `chacha20-poly1305@openssh.com` cipher (with `aes256-gcm@openssh.com` fallback for Blink Shell), `hmac-sha2-512-etm@openssh.com` MAC, and post-quantum KEX (`mlkem768x25519-sha256`) with fallbacks for Blink Shell compatibility.

9. **fail2ban incremental bans** - SSH brute-force protection with `maxretry=3`, starting at 1h ban, doubling on repeat offence up to 168h (1 week) maximum.

## Quick Reference

See `README.md` for detailed procedures. Key naming convention: `[from]_[to]_[user]_[type]`

**Key configuration files:**
- `.sops.yaml` - sops-nix age public key (for encrypting sops-nix.yaml)
- `git-agecrypt.toml` - git-agecrypt age public key (for encrypting git-agecrypt.nix)

**Essential commands:**
```bash
./clone.sh                                # Bootstrap: clone repo with git-agecrypt
./git.sh                                  # Format, validate, commit, and push
./git.sh --amend                          # Amend the previous commit
./git.sh --reset                          # Clear history (for forking to empty repo)
./install.sh [host]                       # Build and switch
./partition.sh [host]                     # Partition disk using disko config
nix flake check                           # Validate flake (requires git add first; same-platform only)
```

## Code Patterns

### Packages (correct)
```nix
environment.systemPackages = builtins.attrValues {
  inherit (pkgs)
    curl
    git
    vim
    ;
};
```

### Packages (wrong - do not use)
```nix
environment.systemPackages = with pkgs; [ curl git vim ];
```

### Home-manager packages
```nix
{ pkgs, ... }:
{
  home.packages = builtins.attrValues {
    inherit (pkgs) package1 package2;
  };
}
```

### Sops secret reference
```nix
# In Hosts/Nithra/default.nix:
sops.secrets.mySecret = { };
sops.secrets.myPassword.neededForUsers = true;  # For user passwords

# In Hosts/<host>/default.nix or Homes/<user>/<host>-account.nix (note: needs config in function args):
{ config, ... }:
{
  users.users.<user>.hashedPasswordFile = config.sops.secrets.<user>Password.path;
}
```

### SSH login key from git-agecrypt (NixOS)
```nix
# In Hosts/Nithra/default.nix:
users.users.<user>.openssh.authorizedKeys.keys = [
  secrets.loginKeysPub.ipsa_nithra_ezirius_login
  secrets.loginKeysPub.ipirus_nithra_ezirius_login
  secrets.loginKeysPub.maldoria_nithra_ezirius_login
];
```

**Note:** On NixOS, SSH login keys must be in git-agecrypt.nix (not sops) because `authorizedKeys.keys` needs values at Nix evaluation time.

### SSH login key from Public/ (Darwin)
```nix
# In Hosts/Maldoria/default.nix:
# Public keys stored in Public/Maldoria/keys.nix (not secrets - they're public)
pubkeys = import ../../Public/Maldoria/keys.nix;

# Write authorized_keys via activation script (after sops-nix runs)
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

**Note:** On Darwin, nix-darwin lacks `users.users.<name>.openssh.authorizedKeys`. SSH login public keys are stored in `Public/Maldoria/keys.nix` (not secrets - they're public) and written via activation script.

### GitHub SSH private key from sops
```nix
# In Hosts/Nithra/default.nix:
sops.secrets.nithra_github_ezirius_nix-configurations = {
  owner = "ezirius";
  path = "/home/ezirius/.ssh/nithra_github_ezirius_nix-configurations";
  mode = "0600";
};
```

**Note:** Files referencing `config.sops.secrets.*` need `config` in their function arguments.

### i3status (home-manager)
```nix
programs.i3status = {
  enable = true;
  enableDefault = false;  # Disable battery/wifi/volume for VPS
  modules = {
    cpu_usage = { position = 1; settings = { format = "CPU: %usage"; }; };
    "disk /" = { position = 2; settings = { format = "Disk: %avail"; }; };
    "ethernet ens18" = { position = 3; settings = { format_up = "E: %ip"; }; };
  };
};
```

**Note:** Module names include instance identifiers (e.g. `"disk /"`, `"ethernet ens18"`). Modules without instances: `cpu_usage`, `memory`, `load`.

### XDG config file (home-manager)
```nix
# For apps without home-manager modules, use xdg.configFile
xdg.configFile."appname/config.json".text = builtins.toJSON {
  setting1 = "value";
  setting2 = true;
};
```

**Note:** This creates `~/.config/appname/config.json` managed by home-manager.

### Catppuccin theming (via catppuccin/nix module)
```nix
# In flake.nix: catppuccin input is added and passed to home-manager
# In home configs, enable globally:
catppuccin = {
  enable = true;
  flavor = "mocha";
  accent = "mauve";
};

# Supported apps are themed automatically (fzf, bat, btop, delta, starship, ghostty, etc.)
# For unsupported apps (i3, i3status), use manual Catppuccin Mocha colours
```

### Vim mode enablement
```nix
# zsh
programs.zsh.initExtra = ''
  bindkey -v  # vi mode
'';

# tmux
programs.tmux.keyMode = "vi";

# readline (bash, other readline apps)
programs.readline.variables.editing-mode = "vi";

# less (no vim mode available, uses standard navigation)
```

## Formatter

The formatter in `flake.nix` excludes `Private/` because git-agecrypt files are encrypted - formatting would corrupt them. This is intentional and required.

## Handling Secrets Modifications

Since you cannot read `Private/` files, when the user needs to modify secrets:

1. **Describe the change needed** - Tell the user exactly what to add/modify and where
2. **Provide the exact format** - Show the Nix or YAML syntax they should use
3. **Reference README procedures** - Point to `README.md` Section 4 'Configuration Changes' or Section 5 'Secrets Management' for detailed steps
4. **Remind about encryption** - For sops-nix.yaml, remind them to use the sops command; for git-agecrypt.nix, it auto-encrypts on commit

**Example response for adding a new SSH login key:**
> "To add this key, edit `Private/Nithra/git-agecrypt.nix` and add to `loginKeysPub`:
> ```nix
> newmachine_nithra_ezirius_login = "ssh-ed25519 AAAA...";
> ```
> Then add the reference in `Hosts/Nithra/default.nix`. See README Section 4.1 'Add SSH Key for Login' for full steps."

## Confirmation Patterns

Scripts use different confirmation levels based on operation severity:

| Level | Prompt | Use Case |
|-------|--------|----------|
| Standard | `(y/n)` | Reversible operations (rebase, push) |
| Destructive | `Type YES` | Irreversible operations (reset local history) |
| Multi-stage | Multiple `YES` | Operations with multiple irreversible steps |

**Example: `./git.sh --reset`** uses two-level confirmation:
1. First `YES`: Before resetting local git history
2. Second `YES`: Before force pushing to remote (overwrites remote history)

This pattern ensures users explicitly acknowledge each destructive action.

## Do NOT

- Use `with pkgs;` pattern - use `builtins.attrValues { inherit (pkgs) ...; }`
- On NixOS, forget that SSH login keys are in git-agecrypt.nix (sops paths don't exist at eval time); on Darwin, use `Public/` keys with activation scripts
- Remove users from `AllowUsers` without confirming alternative access exists
- Disable `fail2ban` or firewall without explicit permission
- Hardcode IPs - use `git-agecrypt.nix` network values
- Add line number references in documentation - they break when code changes
- Run `nix flake update` without warning about potential breaking changes
- Create new files unless absolutely necessary - prefer editing existing files
- Implement functionality in scripts that should be declarative in the flake - scripts are for bootstrapping and orchestration only

## Common Mistakes

### Forgetting to stage before `nix flake check`
```bash
# Wrong - flake won't see unstaged changes
vim Hosts/Nithra/default.nix
nix flake check  # Fails or uses stale version

# Correct - stage first
vim Hosts/Nithra/default.nix
git add .
nix flake check
```

### Using jj instead of git
jj (jujutsu) doesn't support `.gitattributes` filters. git-agecrypt relies on these filters to encrypt/decrypt secrets. **Always use git for this repository.** jj is fine for other repositories.

### Editing git-agecrypt.nix on the wrong machine
git-agecrypt.nix files are decrypted locally using the key at `~/.config/git-agecrypt/keys.txt`. If you edit on a machine without the key configured, you'll commit plaintext secrets. Always verify git-agecrypt is configured:
```bash
git config --get filter.git-agecrypt.smudge
```

### Forgetting `config` in function arguments when using sops paths
```nix
# Wrong - config not available
{ pkgs, ... }:
{
  users.users.ezirius.hashedPasswordFile = config.sops.secrets.eziriusPassword.path;
}

# Correct - config in arguments
{ config, pkgs, ... }:
{
  users.users.ezirius.hashedPasswordFile = config.sops.secrets.eziriusPassword.path;
}
```

### Using sops paths for NixOS SSH login keys
On NixOS, `authorizedKeys.keys` is evaluated at build time, before sops-nix runs. Use git-agecrypt.nix instead:
```nix
# Wrong - sops path doesn't exist at eval time
users.users.ezirius.openssh.authorizedKeys.keys = [
  config.sops.secrets.myKey.path  # This is a path, not a key value!
];

# Correct - use git-agecrypt value
users.users.ezirius.openssh.authorizedKeys.keys = [
  secrets.loginKeysPub.ipsa_nithra_ezirius_login
];
```

### Piped command failures going unnoticed
All scripts use `set -euo pipefail`, but complex pipelines can still mask failures. If a command seems to succeed but produces wrong output, check each pipeline stage individually.

### Running partition.sh on an installed system
`partition.sh` only works on the NixOS live ISO. Running it on an installed system (Nithra, Maldoria, or any other) will exit with an error. This is intentional - partitioning should only happen during fresh installation.

## Repository Structure

See `README.md` for full repository structure, common tasks, and detailed documentation.

**Shared code:** `Libraries/lib.sh` contains common bash functions sourced by `git.sh`, `install.sh`, and `partition.sh`. Note: `clone.sh` is standalone (runs via `curl | bash`) and duplicates necessary functions.

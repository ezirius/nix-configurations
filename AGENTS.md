# NixOS Configuration - Nithra Infrastructure

## Agent Rules

- Be concise
- Use British English spelling (e.g. colour, organisation, licence)
- Use metric units
- Never make changes without explicit user approval
- Never read files or directories containing "secret" or "secrets" in the path (case-insensitive rule)
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
- Run `git-agecrypt init` followed by `git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt` after cloning to ensure secrets decrypt
- Before deploying, always push to GitHub first
- Before deploying, suggest running `nix flake check` to validate
- Note: `./install.sh` automatically runs `nix fmt` before staging

## Critical Facts

1. **Git staging required** - Flakes only see staged files. `./install.sh` auto-stages, but `nix flake check` does not.

2. **Two secrets layers:**
   - `Secrets/Nithra/git-agecrypt.nix` → git-agecrypt → needed at eval/boot time (network, host keys, SSH login pubkeys)
   - `Secrets/Nithra/sops-nix.yaml` → sops-nix → decrypted at runtime (passwords, GitHub SSH private key)

3. **git-agecrypt.nix is DECRYPTED LOCALLY - this is correct!**
   - Locally (working directory): **Always plaintext** - this is expected and required for Nix to import it
   - In git commits/remote: **Encrypted** - git-agecrypt encrypts on commit via clean filter
   - To verify encryption in git: `git show HEAD:Secrets/Nithra/git-agecrypt.nix | head -5` (should show binary)

4. **sops-nix.yaml** - User must edit this file manually (encrypted with sops).

5. **Remote LUKS server** - Breaking SSH/network config locks out the user. Always warn before such changes.

6. **git-agecrypt.nix is a Nix file** - Imported directly with `import ../../Secrets/Nithra/git-agecrypt.nix`, not via sops. Values accessed as `secrets.network.ip`, etc.

7. **Use git, not jj** - jj doesn't support .gitattributes filters, so git-agecrypt won't encrypt.

8. **git-agecrypt needs existing commit** - When initialising a fresh repo, add files except secrets first, commit, then add secrets:
   ```bash
   git add . ':!Secrets'
   git commit -m "Initial commit"
   git add Secrets/
   git commit --amend -m "Initial commit"
   ```

## Quick Reference

| To change... | Edit file |
|--------------|-----------|
| System packages | `Modules/Core/default.nix` → `environment.systemPackages` |
| User packages | `Users/<user>/home.nix` → `home.packages` or `programs.*` |
| SSH keys (login) | `Secrets/Nithra/git-agecrypt.nix` → `sshPubKeys.*` + `Hosts/Nithra/default.nix` |
| GitHub SSH key | `Secrets/Nithra/sops-nix.yaml` + `Hosts/Nithra/default.nix` (deployed to `~/.ssh/id_ed25519`) |
| SSH keys (boot unlock) | `Secrets/Nithra/git-agecrypt.nix` → `dropbear.authorizedKeys` |
| Network/IP | `Secrets/Nithra/git-agecrypt.nix` → `network.*` |
| Firewall ports | `Modules/Core/default.nix` → `networking.firewall` |
| SSH hardening | `Modules/Core/default.nix` → `services.openssh.settings` |
| Timezone/locale | `Modules/Core/default.nix` |
| New user | `Users/<name>/` + `Hosts/Nithra/default.nix` + `flake.nix` |
| New host | `Hosts/<name>/` + `flake.nix` + `install.sh` + `.gitattributes` |

## Commands

```bash
./install.sh                              # Build and switch (auto-stages git)
nix flake check                           # Validate flake (requires git add first)
nix fmt                                   # Format all .nix files
nixos-rebuild build --flake .#nithra      # Test build without switching
nix flake update                          # Update all inputs (warn user first)
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
sops.secrets.my-secret = { };
sops.secrets.my-password.neededForUsers = true;  # For user passwords

# In Users/<user>/default.nix (note: needs config in function args):
{ config, ... }:
{
  users.users.<user>.hashedPasswordFile = config.sops.secrets.<user>-password.path;
}
```

### SSH login key from git-agecrypt
```nix
# In Secrets/Nithra/git-agecrypt.nix:
{
  sshPubKeys = {
    machine1 = "ssh-ed25519 AAAA...";
    machine2 = "ssh-ed25519 AAAA...";
  };
}

# In Hosts/Nithra/default.nix:
users.users.<user>.openssh.authorizedKeys.keys = [
  secrets.sshPubKeys.machine1
  secrets.sshPubKeys.machine2
];
```

**Note:** SSH login keys must be in git-agecrypt.nix (not sops) because `authorizedKeys.keyFiles` references absolute paths that don't exist at evaluation time. Using `authorizedKeys.keys` with git-agecrypt values avoids this issue.

### GitHub SSH private key from sops
```nix
# In Hosts/Nithra/default.nix:
sops.secrets.github-ssh-key-nithra = {
  owner = "ezirius";
  path = "/home/ezirius/.ssh/id_ed25519";
  mode = "0600";
};
```

**Note:** Files referencing `config.sops.secrets.*` need `config` in their function arguments.

## Do NOT

- Use `with pkgs;` pattern - use `builtins.attrValues { inherit (pkgs) ...; }`
- Forget that SSH login keys are in git-agecrypt.nix, not sops (sops paths don't exist at eval time)
- Remove users from `AllowUsers` without confirming alternative access exists
- Disable `fail2ban` or firewall without explicit permission
- Hardcode IPs - use `git-agecrypt.nix` network values
- Add line number references in documentation - they break when code changes
- Run `nix flake update` without warning about potential breaking changes
- Create new files unless absolutely necessary - prefer editing existing files

## Repository Structure

See `README.md` for full repository structure, common tasks, and detailed documentation.

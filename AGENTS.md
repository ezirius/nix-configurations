# NixOS Configuration - Nithra Infrastructure

## Agent Rules

- Be concise
- Use British English spelling (e.g. colour, organisation, licence)
- Use metric units
- Never make changes without explicit user approval
- Never write new files without explicit user permission
- Ask before modifying: secrets files, SSH config, firewall rules, user auth
- Proceed without asking: formatting, comments, package additions, documentation
- Cannot edit encrypted files - if `sops-nix.yaml` needs changes, user must edit it manually
- Cannot run commands on remote server - only edit local config files
- After editing `.nix` files, remind user to run `nix fmt`
- Before user deploys, suggest running `nix flake check` to validate

## Critical Facts

1. **Git staging required** - Flakes only see staged files. `./install.sh` auto-stages, but `nix flake check` does not.

2. **Two secrets layers:**
   - `secrets/nithra/git-agecrypt.nix` → git-agecrypt → needed at eval/boot time (network, host keys)
   - `secrets/nithra/sops-nix.yaml` → sops-nix → decrypted at runtime (passwords, SSH pubkeys)

3. **git-agecrypt.nix is DECRYPTED LOCALLY - this is correct!**
   - Locally (working directory): **Always plaintext** - this is expected and required for Nix to import it
   - In git commits/remote: **Encrypted** - git-agecrypt encrypts on commit via clean filter
   - If agent can read the file contents, it means git-agecrypt is working correctly
   - To verify encryption in git: `git show HEAD:secrets/nithra/git-agecrypt.nix | head -5` (should show binary)

4. **sops-nix.yaml** - Agent cannot edit this file (encrypted with sops, not git-agecrypt).

5. **Remote LUKS server** - Breaking SSH/network config locks out the user. Always warn before such changes.

6. **git-agecrypt.nix is a Nix file** - Imported directly with `import ../../secrets/nithra/git-agecrypt.nix`, not via sops. Values accessed as `secrets.network.ip`, etc.

7. **Use git, not jj** - jj doesn't support .gitattributes filters, so git-agecrypt won't encrypt.

8. **git-agecrypt needs existing commit** - When initialising a fresh repo, add files except secrets first, commit, then add secrets:
   ```bash
   git add . ':!secrets'
   git commit -m "Initial commit"
   git add secrets/
   git commit --amend -m "Initial commit"
   ```

## Quick Reference

| To change... | Edit file |
|--------------|-----------|
| System packages | `modules/core/default.nix` → `environment.systemPackages` |
| User packages | `users/<user>/home.nix` → `home.packages` or `programs.*` |
| SSH keys (login) | `secrets/nithra/sops-nix.yaml` + `hosts/nithra/default.nix` + `users/<user>/default.nix` |
| GitHub SSH key | `secrets/nithra/sops-nix.yaml` + `hosts/nithra/default.nix` (deployed to `~/.ssh/id_ed25519`) |
| SSH keys (boot unlock) | `secrets/nithra/git-agecrypt.nix` → `dropbear.authorizedKeys` |
| Network/IP | `secrets/nithra/git-agecrypt.nix` → `network.*` |
| Firewall ports | `modules/core/default.nix` → `networking.firewall` |
| SSH hardening | `modules/core/default.nix` → `services.openssh.settings` |
| Timezone/locale | `modules/core/default.nix` |
| New user | `users/<name>/` + `hosts/nithra/default.nix` + `flake.nix` |
| New host | `hosts/<name>/` + `flake.nix` + `install.sh` + `.gitattributes` |

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
# In hosts/nithra/default.nix:
sops.secrets.my-secret = { };
sops.secrets.my-password.neededForUsers = true;  # For user passwords

# In users/<user>/default.nix (note: needs config in function args):
{ config, ... }:
{
  users.users.<user>.hashedPasswordFile = config.sops.secrets.<user>-password.path;
}
```

### SSH key from sops
```nix
# In hosts/nithra/default.nix:
sops.secrets.ssh-pubkey-user-machine = { };

# In users/<user>/default.nix:
users.users.<user>.openssh.authorizedKeys.keyFiles = [
  config.sops.secrets.ssh-pubkey-user-machine.path
];
```

### GitHub SSH private key from sops
```nix
# In hosts/nithra/default.nix:
sops.secrets.github-ssh-key-nithra = {
  owner = "ezirius";
  path = "/home/ezirius/.ssh/id_ed25519";
  mode = "0600";
};
```

**Note:** Files referencing `config.sops.secrets.*` need `config` in their function arguments.

## Do NOT

- Use `with pkgs;` pattern - use `builtins.attrValues { inherit (pkgs) ...; }`
- Edit `git-agecrypt.nix` without user providing decrypted content
- Remove users from `AllowUsers` without confirming alternative access exists
- Disable `fail2ban` or firewall without explicit permission
- Hardcode IPs - use `git-agecrypt.nix` network values
- Add line number references in documentation - they break when code changes
- Run `nix flake update` without warning about potential breaking changes
- Create new files unless absolutely necessary - prefer editing existing files

## Repository Structure

See `README.md` for full repository structure, common tasks, and detailed documentation.

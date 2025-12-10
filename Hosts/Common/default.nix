# Shared host configuration for all machines
{ pkgs, ... }:
{
  # --- NIX SETTINGS ---
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.gc = {
    automatic = true;
    options = "--delete-older-than 30d";
  };

  # --- SHELL ---
  programs.zsh.enable = true;

  # --- SYSTEM PACKAGES ---
  environment.systemPackages = builtins.attrValues {
    inherit (pkgs)
      # --- Essential ---
      curl # HTTP client - command-line URL transfer (vs wget: less features)

      # --- Remote Access ---
      mosh # Mobile shell - UDP-based, survives IP changes (vs SSH: TCP, drops on network change)

      # --- Modern Replacements ---
      gdu # Disk usage - interactive TUI, can delete (vs du: non-interactive)
      procs # Process viewer - colour output, tree view (vs ps: minimal formatting)
      sd # String replacer - literal syntax (vs sed: regex escaping required)

      # --- Development Tools ---
      jaq # JSON processor - jq-compatible, faster (vs jq: slower on large files)

      # --- System Administration ---
      rsync # File sync - delta transfers, propagates deletions (vs cp: full copy only)

      # --- Network Diagnostics ---
      dog # DNS client - coloured output, DoH/DoT support (vs dig: plain output)
      ;
  };
}

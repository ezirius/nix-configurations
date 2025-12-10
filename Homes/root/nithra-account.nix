{ config, pkgs, ... }:
{
  # Root user password managed by sops-nix
  users.users.root = {
    shell = pkgs.zsh;
    hashedPasswordFile = config.sops.secrets.rootPassword.path;
  };
}

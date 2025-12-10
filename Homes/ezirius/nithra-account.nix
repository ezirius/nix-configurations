{ config, pkgs, ... }:
{
  users.users.ezirius = {
    isNormalUser = true;
    description = "Ezirius";
    extraGroups = [
      "wheel"
      "video"
    ];
    shell = pkgs.zsh;
    hashedPasswordFile = config.sops.secrets.eziriusPassword.path;
    # SSH login keys set in Hosts/Nithra/default.nix (from Public/Nithra/keys.nix)
  };
}

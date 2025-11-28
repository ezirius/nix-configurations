{ config, pkgs, ... }:
{
  users.users.ezirius = {
    isNormalUser = true;
    description = "Ezirius";
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
    hashedPasswordFile = config.sops.secrets.ezirius-password.path;
    openssh.authorizedKeys.keyFiles = [
      config.sops.secrets.ssh-pubkey-ezirius-ipsa.path
      config.sops.secrets.ssh-pubkey-ezirius-ipirus.path
      config.sops.secrets.ssh-pubkey-ezirius-maldoria.path
    ];
  };
  programs.zsh.enable = true; # System-wide zsh for user shell
}
